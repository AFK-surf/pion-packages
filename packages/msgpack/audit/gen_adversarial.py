#!/usr/bin/env python3
"""Adversarial MessagePack inputs for the packages/msgpack red-team audit.

usage: gen_adversarial.py <out_dir>

hashdos_<n>.msgpack  map of n uint64 keys whose packages/msgpack key hash
                     (mix64(k ^ 0x3030..30), an unseeded SplitMix64 finalizer, src/decode.pion)
                     has its low 24 bits all zero, so every key lands in the same
                     linear-probing cluster of the duplicate-key table.
random_<n>.msgpack   same shape with random uint64 keys (control).
frames_<size>.msgpack concatenated tiny frames {"k": i&127} filling <size> bytes (decode_prefix stream).
ints_1m / f32_1m / f64_1m  flat arrays of 1,048,575 numbers.
rpc_mixed_1m         ~1 MiB of RPC records mixing invalid-UTF-8 bin blobs and str fields.
deep100_x10k         array of 10,000 elements, each nested 100 deep (exercises the >64 iterative path).
strmap_10k           map with 10,000 distinct str keys (benign reject_duplicate_keys workload).
"""
import os
import random
import struct
import sys

M64 = (1 << 64) - 1
C_GOLD = 0x9E3779B97F4A7C15
M1 = 0xBF58476D1CE4E5B9
M2 = 0x94D049BB133111EB
UINT_SALT = 0x3030303030303030


def mix64(x):
    z = (x + C_GOLD) & M64
    z = ((z ^ (z >> 30)) * M1) & M64
    z = ((z ^ (z >> 27)) * M2) & M64
    return z ^ (z >> 31)


def unxorshift(z, s):
    x = z
    for _ in range(64 // s + 1):
        x = z ^ (x >> s)
    return x & M64


def inv_mix64(h):
    z = unxorshift(h, 31)
    z = (z * pow(M2, -1, 1 << 64)) & M64
    z = unxorshift(z, 27)
    z = (z * pow(M1, -1, 1 << 64)) & M64
    z = unxorshift(z, 30)
    return (z - C_GOLD) & M64


def enc_uint(u):
    if u <= 0x7F:
        return bytes([u])
    if u <= 0xFF:
        return b"\xcc" + bytes([u])
    if u <= 0xFFFF:
        return b"\xcd" + struct.pack(">H", u)
    if u <= 0xFFFFFFFF:
        return b"\xce" + struct.pack(">I", u)
    return b"\xcf" + struct.pack(">Q", u)


def enc_str(b):
    n = len(b)
    if n <= 31:
        return bytes([0xA0 | n]) + b
    if n <= 0xFF:
        return b"\xd9" + bytes([n]) + b
    if n <= 0xFFFF:
        return b"\xda" + struct.pack(">H", n) + b
    return b"\xdb" + struct.pack(">I", n) + b


def enc_bin(b):
    n = len(b)
    if n <= 0xFF:
        return b"\xc4" + bytes([n]) + b
    if n <= 0xFFFF:
        return b"\xc5" + struct.pack(">H", n) + b
    return b"\xc6" + struct.pack(">I", n) + b


def head(n, fix, b16, b32):
    if n <= 15:
        return bytes([fix | n])
    if n <= 0xFFFF:
        return bytes([b16]) + struct.pack(">H", n)
    return bytes([b32]) + struct.pack(">I", n)


def map_head(n):
    return head(n, 0x80, 0xDE, 0xDF)


def arr_head(n):
    return head(n, 0x90, 0xDC, 0xDD)


def hashdos_keys(n, rng):
    keys, seen = [], set()
    while len(keys) < n:
        h = rng.getrandbits(40) << 24  # low 24 bits zero
        k = inv_mix64(h) ^ UINT_SALT
        assert mix64(k ^ UINT_SALT) == h
        if k not in seen:
            seen.add(k)
            keys.append(k)
    return keys


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    rng = random.Random(0x4D50)

    def w(name, data):
        with open(os.path.join(out, name), "wb") as f:
            f.write(data)

    for n in (4096, 16384, 65535, 131072, 262144):
        ks = hashdos_keys(n, rng)
        w("hashdos_%d.msgpack" % n, map_head(n) + b"".join(enc_uint(k) + b"\x00" for k in ks))
        rs = rng.sample(range(1 << 62), n)
        w("random_%d.msgpack" % n, map_head(n) + b"".join(enc_uint(k | (1 << 63)) + b"\x00" for k in rs))

    for size in (16384, 65536, 262144, 1048576, 2097152, 2228224):
        buf = bytearray()
        i = 0
        while len(buf) + 4 <= size:
            buf += b"\x81\xa1k" + bytes([i & 0x7F])
            i += 1
        while len(buf) < size:
            buf += b"\xc0"
        w("frames_%d.msgpack" % size, bytes(buf))

    n = 1048575
    w("ints_1m.msgpack", arr_head(n) + b"".join(enc_uint((i * 2654435761) & 0xFFFFFFFF) for i in range(n)))
    w("f32_1m.msgpack", arr_head(n) + b"".join(b"\xca" + struct.pack(">f", i * 0.5) for i in range(n)))
    w("f64_1m.msgpack", arr_head(n) + b"".join(b"\xcb" + struct.pack(">d", i * 0.1) for i in range(n)))

    recs = []
    size = 0
    i = 0
    while size < 1 << 20:
        blob = bytes(rng.getrandbits(8) | 0x80 for _ in range(48))  # never valid UTF-8 starts
        rec = map_head(4) + enc_str(b"id") + enc_uint(i) + enc_str(b"blob") + enc_bin(blob) \
            + enc_str(b"name") + enc_str(("user-%d-é✓" % i).encode()) + enc_str(b"tags") \
            + arr_head(2) + enc_str(b"alpha") + enc_str("βeta".encode())
        recs.append(rec)
        size += len(rec)
        i += 1
    w("rpc_mixed_1m.msgpack", arr_head(len(recs)) + b"".join(recs))

    deep = b"\x91" * 100 + b"\x01"
    w("deep100_x10k.msgpack", arr_head(10000) + deep * 10000)

    keys = ["key-%06d" % i for i in range(10000)]
    w("strmap_10k.msgpack", map_head(10000) + b"".join(enc_str(k.encode()) + enc_uint(i) for i, k in enumerate(keys)))


if __name__ == "__main__":
    main()
