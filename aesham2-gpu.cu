#include <thrust/version.h>
#include <thrust/device_ptr.h>
#include <thrust/sort.h>

#include <cpuid.h>
#include <wmmintrin.h>
#include <emmintrin.h>

#include <cstdint>
#include <cstdio>
#include <cinttypes>

// Macro to catch CUDA errors in CUDA runtime calls
#define CUDA_SAFE_CALL(call) \
do { \
    cudaError_t err = call; \
    if (cudaSuccess != err) { \
        fprintf (stderr, "Cuda error in file '%s' in line %i : %s.", \
                 __FILE__, __LINE__, cudaGetErrorString(err) ); \
        exit(EXIT_FAILURE); \
    } \
} while (0)

inline struct timespec time_diff(struct timespec start, struct timespec end) {
    struct timespec diff;
    if ((end.tv_nsec-start.tv_nsec)<0) {
        diff.tv_sec = end.tv_sec-start.tv_sec-1;
        diff.tv_nsec = 1000000000+end.tv_nsec-start.tv_nsec;
    } else {
        diff.tv_sec = end.tv_sec-start.tv_sec;
        diff.tv_nsec = end.tv_nsec-start.tv_nsec;
    }
    return diff;
}

inline void fprint_time(FILE *stream, struct timespec t) {
    fprintf(stream, "%3ld.%09ld", t.tv_sec, t.tv_nsec);
}

struct timespec program_start_time;

inline void fprint_timestamp(FILE *stream) {
    struct timespec current_time;
    clock_gettime(CLOCK_REALTIME, &current_time);
    struct timespec diff = time_diff(program_start_time, current_time);
    fprint_time(stream, diff);
    fprintf(stream, ": ");
}

using aes_block = uint4;

uint HOST_TBOX[4][256];
__constant__ uint CUDA_TBOX[4][256];
__shared__ uint TBOX[4][256];
aes_block HOST_ROUND_KEYS[2][15];
__constant__ aes_block CUDA_ROUND_KEYS[2][15];
__shared__ aes_block ROUND_KEYS[2][15];

__host__ __device__ inline uint bswap32(uint inp) {
#ifndef __CUDA_ARCH__
    return __builtin_bswap32(inp);
#else
    return __byte_perm(inp, 0, 0x0123);
#endif
}

__host__ __device__ inline aes_block aes_enc(uint64_t inp, const int key) {
#ifndef __CUDA_ARCH__
#define ROUND_KEYS HOST_ROUND_KEYS
#define TBOX HOST_TBOX
#endif

    aes_block state = {0,0,bswap32(inp >> 32ull),bswap32((uint)inp)};
    state.x ^= ROUND_KEYS[key][0].x;
    state.y ^= ROUND_KEYS[key][0].y;
    state.z ^= ROUND_KEYS[key][0].z;
    state.w ^= ROUND_KEYS[key][0].w;
#pragma unroll
    for (int i = 1; i < 14; i++) {
        state = {
            TBOX[0][(state.x) & 0xff] ^ TBOX[1][(state.y >> 8) & 0xff] ^ TBOX[2][(state.z >> 16) & 0xff] ^ TBOX[3][(state.w >> 24) & 0xff],
            TBOX[0][(state.y) & 0xff] ^ TBOX[1][(state.z >> 8) & 0xff] ^ TBOX[2][(state.w >> 16) & 0xff] ^ TBOX[3][(state.x >> 24) & 0xff],
            TBOX[0][(state.z) & 0xff] ^ TBOX[1][(state.w >> 8) & 0xff] ^ TBOX[2][(state.x >> 16) & 0xff] ^ TBOX[3][(state.y >> 24) & 0xff],
            TBOX[0][(state.w) & 0xff] ^ TBOX[1][(state.x >> 8) & 0xff] ^ TBOX[2][(state.y >> 16) & 0xff] ^ TBOX[3][(state.z >> 24) & 0xff],
        };
        state.x ^= ROUND_KEYS[key][i].x;
        state.y ^= ROUND_KEYS[key][i].y;
        state.z ^= ROUND_KEYS[key][i].z;
        state.w ^= ROUND_KEYS[key][i].w;
    }
    // Final round: no mixing, just SubBytes and ShiftRows
    state = {
        (TBOX[3][(state.x) & 0xff] & 0xff) ^ (TBOX[0][(state.y >> 8) & 0xff] & 0xff00) ^ (TBOX[1][(state.z >> 16) & 0xff] & 0xff0000) ^ (TBOX[2][(state.w >> 24) & 0xff] & 0xff000000),
        (TBOX[3][(state.y) & 0xff] & 0xff) ^ (TBOX[0][(state.z >> 8) & 0xff] & 0xff00) ^ (TBOX[1][(state.w >> 16) & 0xff] & 0xff0000) ^ (TBOX[2][(state.x >> 24) & 0xff] & 0xff000000),
        (TBOX[3][(state.z) & 0xff] & 0xff) ^ (TBOX[0][(state.w >> 8) & 0xff] & 0xff00) ^ (TBOX[1][(state.x >> 16) & 0xff] & 0xff0000) ^ (TBOX[2][(state.y >> 24) & 0xff] & 0xff000000),
        (TBOX[3][(state.w) & 0xff] & 0xff) ^ (TBOX[0][(state.x >> 8) & 0xff] & 0xff00) ^ (TBOX[1][(state.y >> 16) & 0xff] & 0xff0000) ^ (TBOX[2][(state.z >> 24) & 0xff] & 0xff000000),
    };
    state.x ^= ROUND_KEYS[key][14].x;
    state.y ^= ROUND_KEYS[key][14].y;
    state.z ^= ROUND_KEYS[key][14].z;
    state.w ^= ROUND_KEYS[key][14].w;
    state = {
        bswap32(state.w),
        bswap32(state.z),
        bswap32(state.y),
        bswap32(state.x),
    };
    return state;
#ifndef __CUDA_ARCH__
#undef ROUND_KEYS
#undef TBOX
#endif
}

// AES Keygen on CPU

bool __get_cpuid_aes() {
    unsigned int a,b,c,d;
    if (!__get_cpuid(0x1, &a, &b, &c, &d)) {
        return false;
    }
    return (bool) (c & bit_AES);
}

#define IS_ALIGNED(v, a) ((((uintptr_t) v) & ((a)-1)) == 0)

__host__ inline __m128i aes128_keyexpand(__m128i key) {
    key = _mm_xor_si128(key, _mm_slli_si128(key, 4));
    key = _mm_xor_si128(key, _mm_slli_si128(key, 4));
    return _mm_xor_si128(key, _mm_slli_si128(key, 4));
}

#define KEYEXP128_H(K1, K2, I, S) _mm_xor_si128(aes128_keyexpand(K1), \
        _mm_shuffle_epi32(_mm_aeskeygenassist_si128(K2, I), S))

#define KEYEXP256(K1, K2, I)  KEYEXP128_H(K1, K2, I, 0xff)
#define KEYEXP256_2(K1, K2) KEYEXP128_H(K1, K2, 0x00, 0xaa)

__host__ inline void aes_keygen(__m128i rk[], const void* cipherKey) {
    assert(IS_ALIGNED(cipherKey, 16));
    const void *cipherKey2 = (const char *) cipherKey + 16;

    /* 256 bit key setup */
    rk[0] = _mm_load_si128((const __m128i*) cipherKey);
    rk[1] = _mm_load_si128((const __m128i*) cipherKey2);
    rk[2] = KEYEXP256(rk[0], rk[1], 0x01);
    rk[3] = KEYEXP256_2(rk[1], rk[2]);
    rk[4] = KEYEXP256(rk[2], rk[3], 0x02);
    rk[5] = KEYEXP256_2(rk[3], rk[4]);
    rk[6] = KEYEXP256(rk[4], rk[5], 0x04);
    rk[7] = KEYEXP256_2(rk[5], rk[6]);
    rk[8] = KEYEXP256(rk[6], rk[7], 0x08);
    rk[9] = KEYEXP256_2(rk[7], rk[8]);
    rk[10] = KEYEXP256(rk[8], rk[9], 0x10);
    rk[11] = KEYEXP256_2(rk[9], rk[10]);
    rk[12] = KEYEXP256(rk[10], rk[11], 0x20);
    rk[13] = KEYEXP256_2(rk[11], rk[12]);
    rk[14] = KEYEXP256(rk[12], rk[13], 0x40);
}

__host__ inline void aes_tbox_gen() {
    uint4 key_value = {0,0,0,0};
    __m128i key = _mm_load_si128((const __m128i *) &key_value);
    for (int k = 0; k < 4; k++) {
        for (int v = 0; v < 256; v++) {
            uint4 inp_value = {0x52525252,0x52525252,0x52525252,0x52525252};
            if (k == 0) {
                inp_value.x = 0x52525200 | (v << 0);
            } else if (k == 1) {
                inp_value.y = 0x52520052 | (v << 8);
            } else if (k == 2) {
                inp_value.z = 0x52005252 | (v << 16);
            } else if (k == 3) {
                inp_value.w = 0x00525252 | (v << 24);
            }
            __m128i inp = _mm_load_si128((const __m128i *) &inp_value);
            __m128i out = _mm_aesenc_si128(inp, key);
            uint4 out_value = {0,0,0,0};
            _mm_store_si128((__m128i *) &out_value, out);
            HOST_TBOX[k][v] = out_value.x;
            assert(out_value.y == 0);
            assert(out_value.z == 0);
            assert(out_value.w == 0);
        }
    }
}

#define MEM_BITS 24
#define FILTER_BITS 6
#define BUCKET_BITS 14

#define FILTER_MASK (((1 << FILTER_BITS) - 1) << BUCKET_BITS)
#define BUCKET_MASK ((1 << BUCKET_BITS) - 1)
#define NUM_BUCKETS (1 << BUCKET_BITS)
#define MEM_SIZE (1 << MEM_BITS)

struct aes_pair {
    aes_block A, B;
};

__device__ aes_pair aes[MEM_SIZE];
__device__ uint64_t nonces[MEM_SIZE];
__device__ unsigned int buckets[MEM_SIZE];

__global__ void compute_aes_kernel(uint64_t nonceStart) {
    __shared__ unsigned int next_index;
    if (threadIdx.x == 0) {
        memcpy(TBOX, CUDA_TBOX, sizeof(TBOX));
        memcpy(ROUND_KEYS, CUDA_ROUND_KEYS, sizeof(CUDA_ROUND_KEYS));
        next_index = MEM_SIZE / gridDim.x * blockIdx.x;
    }

    unsigned int last_index = MEM_SIZE / gridDim.x * (blockIdx.x + 1);

    __syncthreads();

    for (uint64_t nonce = nonceStart + blockIdx.x * blockDim.x + threadIdx.x;
            true;
            nonce += blockDim.x * gridDim.x
        ) {
        aes_block A = aes_enc(nonce, 0);
        aes_block B = aes_enc(nonce, 1);
        uint diff = A.x - B.x;
        if ((diff & FILTER_MASK) == 0) {
            unsigned int ind = atomicAdd(&next_index, 1u);
            if (ind < last_index) {
                aes[ind].A = A;
                aes[ind].B = B;
                nonces[ind] = nonce;
                buckets[ind] = __brev(diff & BUCKET_MASK) >> (32 - BUCKET_BITS);
            } else {
                return;
            }
        }
    }
}

__constant__ unsigned int difficulty;

__device__ inline aes_block add_aes_block(aes_block l, aes_block r) {
    aes_block res;
    asm ("add.cc.u32      %0, %4, %8;\n\t"
         "addc.cc.u32     %1, %5, %9;\n\t"
         "addc.cc.u32     %2, %6, %10;\n\t"
         "addc.u32        %3, %7, %11;\n\t"
         : "=r"(res.x), "=r"(res.y), "=r"(res.z), "=r"(res.w)
         : "r"(l.x), "r"(l.y), "r"(l.z), "r"(l.w),
           "r"(r.x), "r"(r.y), "r"(r.z), "r"(r.w));
    return res;
}

__device__ inline uint hamming_distance(aes_block l, aes_block r) {
    return __popc(l.x ^ r.x) + __popc(l.y ^ r.y) + __popc(l.z ^ r.z) + __popc(l.w ^ r.w);
}

__device__ unsigned int num_results = 0;
__device__ uint64_t nonce1, nonce2;

__device__ bool check_pair(const unsigned int i, const unsigned int j) {
    aes_block l = add_aes_block(aes[i].A, aes[j].B);
    aes_block r = add_aes_block(aes[i].B, aes[j].A);
    if (hamming_distance(l, r) <= 128 - difficulty) {
        // Yay we're done! Set the output
        unsigned int res_num = atomicAdd(&num_results, 1);
        if (res_num == 0) {
            nonce1 = nonces[i];
            nonce2 = nonces[j];
        }
        return true;
    }
    return false;
}

__global__ void check_pairs_kernel() {
    uint start_index = MEM_SIZE / gridDim.x * blockIdx.x;
    uint end_index = MEM_SIZE / gridDim.x * (blockIdx.x + 1);
    for (uint i = start_index + threadIdx.x; num_results == 0 && i < end_index; i += blockDim.x) {
        for (uint j = i + 1; j < end_index && buckets[j] == buckets[i]; j ++) {
            if (check_pair(i, j)) {
                return;
            }
        }
    }
}

namespace thrust {
template <typename T> device_ptr<T> device_symbol(const void* symbol) {
    void *tmp;
    CUDA_SAFE_CALL(cudaGetSymbolAddress(&tmp, symbol));
    return device_ptr<T>((T*) tmp);
}
}

uint64_t host_nonce1, host_nonce2;

void go() {
    static uint64_t nonce_start = 0;
    while (true) {

        fprint_timestamp(stderr);
        fprintf(stderr, "START: Computing AES from %" PRIu64 "\n", nonce_start);

        compute_aes_kernel<<<256, 256>>>(nonce_start);
        CUDA_SAFE_CALL(cudaDeviceSynchronize());
        nonce_start += (uint64_t(MEM_SIZE) << FILTER_BITS) * 4; // *4 to be conservative

        fprint_timestamp(stderr);
        fprintf(stderr, "FINISH: Computed AES up to %" PRIu64 "\n", nonce_start);

        fprint_timestamp(stderr);
        fprintf(stderr, "START: Bucketing %u items into %u buckets\n", MEM_SIZE, NUM_BUCKETS);

        thrust::sort_by_key (
                thrust::device_symbol<unsigned int>(buckets),
                thrust::device_symbol<unsigned int>(buckets) + MEM_SIZE,
                thrust::make_zip_iterator(thrust::make_tuple(thrust::device_symbol<aes_pair>(aes), thrust::device_symbol<uint64_t>(nonces)))
                );
        CUDA_SAFE_CALL(cudaDeviceSynchronize());

        fprint_timestamp(stderr);
        fprintf(stderr, "FINISH: Bucketed items\n");

        fprint_timestamp(stderr);
        fprintf(stderr, "START: Finding collisions: %u items in %u buckets (~%u each) with ~%llu checks\n", MEM_SIZE, NUM_BUCKETS, MEM_SIZE / NUM_BUCKETS, ((unsigned long long) MEM_SIZE) * (MEM_SIZE / NUM_BUCKETS));

        check_pairs_kernel<<<256, 256>>>();
        CUDA_SAFE_CALL(cudaDeviceSynchronize());

        unsigned int is_done;
        CUDA_SAFE_CALL(cudaMemcpyFromSymbol(&is_done, num_results, sizeof(num_results)));
        if (is_done) {
            fprint_timestamp(stderr);
            fprintf(stderr, "FINISH: Found a collision!\n");

            CUDA_SAFE_CALL(cudaMemcpyFromSymbol(&host_nonce1, nonce1, sizeof(nonce1)));
            CUDA_SAFE_CALL(cudaMemcpyFromSymbol(&host_nonce2, nonce2, sizeof(nonce2)));
            break;
        }

        fprint_timestamp(stderr);
        fprintf(stderr, "FINISH: Found no collisions\n");
    }
}

void print128(aes_block val) {
    uint8_t *v = (uint8_t *) &val;
    for (int i = 0; i < 16; i++) { fprintf(stderr, "%02x", v[i]); } fprintf(stderr, "\n");
}

void parse_hex(const char s[], uint8_t v[]) {
    while (*s) {
        sscanf(s, "%2hhx", v);
        s += 2;
        v ++;
    }
}

int main(int argc, char *argv[]) {
    clock_gettime(CLOCK_REALTIME, &program_start_time);

    if (!__get_cpuid_aes()) {
        fprintf(stderr, "AES-NI not supported on this CPU!\n");
        return 1;
    }

    if (argc != 4) {
        printf("Usage: aesham2 SEED SEED2 DIFFICULTY\n");
        return 1;
    }

    char *seed1 = argv[1];
    char *seed2 = argv[2];

    uint8_t A[32] __attribute__((aligned(16)));
    uint8_t B[32] __attribute__((aligned(16)));
    memset(A, 0, sizeof(A));
    memset(B, 0, sizeof(B));

    parse_hex(seed1, A);
    parse_hex(seed2, B);

    aes_keygen((__m128i*) HOST_ROUND_KEYS[0], A);
    aes_keygen((__m128i*) HOST_ROUND_KEYS[1], B);
    CUDA_SAFE_CALL(cudaMemcpyToSymbol(CUDA_ROUND_KEYS, HOST_ROUND_KEYS, sizeof(CUDA_ROUND_KEYS)));

    aes_tbox_gen();
    CUDA_SAFE_CALL(cudaMemcpyToSymbol(CUDA_TBOX, HOST_TBOX, sizeof(CUDA_TBOX)));

    unsigned int host_difficulty = atoi(argv[3]);
    CUDA_SAFE_CALL(cudaMemcpyToSymbol(difficulty, &host_difficulty, sizeof(difficulty)));

    go();

    printf("%lu %lu\n", host_nonce1, host_nonce2);
    return 0;
}

// vim: set et ts=4 sts=4 sw=4 cindent:
