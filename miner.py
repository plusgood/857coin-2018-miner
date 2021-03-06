#!/usr/bin/env python2

from __future__ import print_function, division

import urllib2
import json
from hashlib import sha256 as H
from Crypto.Cipher import AES
from Crypto.Random import random
import time
from struct import pack, unpack
import requests
import subprocess

NODE_URL = "http://6857coin.csail.mit.edu"

"""
    This is a bare-bones miner compatible with 6857coin, minus the final proof of
    work check. We have left lots of opportunities for optimization. Partial
    credit will be awarded for successfully mining any block that appends to
    a tree rooted at the genesis block. Full credit will be awarded for mining
    a block that adds to the main chain. Note that the faster you solve the proof
    of work, the better your chances are of landing in the main chain.

    Feel free to modify this code in any way, or reimplement it in a different
    language or on specialized hardware.

    Good luck!
"""


def solve_block(b):
    """
    Iterate over random nonce triples until a valid proof of work is found
    for the block

    Expects a block dictionary `b` with difficulty, version, parentid,
    timestamp, and root (a hash of the block data).

    """
    d = b["difficulty"]
    b["nonces"] = [rand_nonce()]
    seed1, seed2 = compute_seeds(b)

    """
    A = AES.new(seed1.digest())
    B = AES.new(seed2.digest())
    ABs = []
    while True:
        n1 = rand_nonce()
        i = pack('>QQ', 0, long(n1))

        # TODO: make sure n1 != n2... in the unlikely event

        #   Compute Ai, Bi
        #   Parse the ciphers as big-endian unsigned integers
        Ai = unpack_uint128(A.encrypt(i))
        Bi = unpack_uint128(B.encrypt(i))

        for n2, Aj, Bj in ABs:
            MSK = (1 << 128) - 1
            dist = bin(((Ai + Bj) & MSK) ^ ((Aj + Bi) & MSK)).count('1')
            if dist <= 128 - d:
                b["nonces"][1:3] = [n1, n2]
                return

        ABs.append((n1, Ai, Bi))
    """

    proc = subprocess.Popen(['./aesham2'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=None)
    print("Starting solve on seeds:")
    print(seed1.hexdigest())
    print(seed2.hexdigest())
    proc.stdin.write(seed1.hexdigest() + '\n')
    proc.stdin.write(seed2.hexdigest() + '\n')
    proc.stdin.write(str(d) + '\n')
    proc.stdin.close()

    proc.wait()
    n1 = long(proc.stdout.readline())
    n2 = long(proc.stdout.readline())
    b["nonces"][1:3] = [n1, n2]

    # Verify
    A = AES.new(seed1.digest())
    B = AES.new(seed2.digest())
    i = pack('>QQ', 0, long(b["nonces"][1]))
    j = pack('>QQ', 0, long(b["nonces"][2]))
    Ai = unpack_uint128(A.encrypt(i))
    Aj = unpack_uint128(A.encrypt(j))
    Bi = unpack_uint128(B.encrypt(i))
    Bj = unpack_uint128(B.encrypt(j))
    MSK = (1 << 128) - 1
    dist = bin(((Ai + Bj) & MSK) ^ ((Aj + Bi) & MSK)).count('1')
    if dist <= 128 - d:
        print("Verification succeeded")
    else:
        print("Verification failed, submitting anyways")


def main():
    """
    Repeatedly request next block parameters from the server, then solve a block
    containing our team name.

    We will construct a block dictionary and pass this around to solving and
    submission functions.
    """
    block_contents = "andrewhe,baula,werryju"
    while True:
        #   Next block's parent, version, difficulty
        next_header = get_next()
        #   Construct a block with our name in the contents that appends to the
        #   head of the main chain
        new_block = make_block(next_header, block_contents)
        #   Solve the POW
        print("Solving block...")
        print(new_block)
        solve_block(new_block)
        #   Send to the server
        add_block(new_block, block_contents)


def get_next():
    """
       Parse JSON of the next block info
           difficulty      uint64
           parentid        HexString
           version         single byte
    """
    return json.loads(urllib2.urlopen(NODE_URL + "/next").read())


def add_block(h, contents):
    """
       Send JSON of solved block to server.
       Note that the header and block contents are separated.
            header:
                difficulty      uint64
                parentid        HexString
                root            HexString
                timestampe      uint64
                version         single byte
            block:          string
    """
    add_block_request = {"header": h, "block": contents}
    print("Sending block to server...")
    print(json.dumps(add_block_request))
    r = requests.post(NODE_URL + "/add", data=json.dumps(add_block_request))
    print(r)
    if r.status_code != requests.codes.ok:
        print(r.content)


def hash_block_to_hex(b):
    """
    Computes the hex-encoded hash of a block header. First builds an array of
    bytes with the correct endianness and length for each arguments. Then hashes
    the concatenation of these bytes and encodes to hexidecimal.

    Not used for mining since it includes all 3 nonces, but serves as the unique
    identifier for a block when querying the explorer.
    """
    packed_data = []
    packed_data.extend(b["parentid"].decode('hex'))
    packed_data.extend(b["root"].decode('hex'))
    packed_data.extend(pack('>Q', long(b["difficulty"])))
    packed_data.extend(pack('>Q', long(b["timestamp"])))
    #   Bigendian 64bit unsigned
    for n in b["nonces"]:
        #   Bigendian 64bit unsigned
        packed_data.extend(pack('>Q', long(n)))
    packed_data.append(chr(b["version"]))
    if len(packed_data) != 105:
        print("invalid length of packed data")
    h = H()
    h.update(''.join(packed_data))
    b["hash"] = h.digest().encode('hex')
    return b["hash"]


def compute_seeds(b):
    """
    Computes the AES keys seed1, seed2 of a block header.
    """

    packed_data = []
    packed_data.extend(b["parentid"].decode('hex'))
    packed_data.extend(b["root"].decode('hex'))
    packed_data.extend(pack('>Q', long(b["difficulty"])))
    packed_data.extend(pack('>Q', long(b["timestamp"])))
    packed_data.extend(pack('>Q', long(b["nonces"][0])))
    packed_data.append(chr(b["version"]))
    if len(packed_data) != 89:
        print("invalid length of packed data")
    h = H()
    h.update(''.join(packed_data))
    seed = h

    data2 = seed.digest()

    if len(data2) != 32:
        print("invalid length of packed data")
    h = H()
    h.update(data2)
    seed2 = h

    return seed, seed2


def unpack_uint128(x):
    h, l = unpack('>QQ', x)
    return (h << 64) + l


def hash_to_hex(data):
    """Returns the hex-encoded hash of a byte string."""
    h = H()
    h.update(data)
    return h.digest().encode('hex')


def make_block(next_info, contents):
    """
    Constructs a block from /next header information `next_info` and sepcified
    contents.
    """
    block = {
        "version": next_info["version"],
        #   for now, root is hash of block contents (team name)
        "root": hash_to_hex(contents),
        "parentid": next_info["parentid"],
        #   nanoseconds since unix epoch
        "timestamp": long(time.time()*1000*1000*1000),
        "difficulty": next_info["difficulty"]
    }
    return block


def rand_nonce():
    """
    Returns a random uint64
    """
    return random.getrandbits(64)


if __name__ == "__main__":
    main()
