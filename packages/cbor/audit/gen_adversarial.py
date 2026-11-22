#!/usr/bin/env python3
"""Adversarial CBOR payloads for performance / DoS benchmarks.

usage: gen_adversarial.py <outdir>
Every payload stays inside fxamacker/cbor default limits (MaxArrayElements /
MaxMapPairs = 131072, MaxNestedLevels = 32) so both decoders accept it.
"""
import os
import random
import struct
import sys


def head(major, n):
    m = major << 5
    if n < 24:
        return bytes([m | n])
    if n <= 0xFF:
        return bytes([m | 24, n])
    if n <= 0xFFFF:
        return bytes([m | 25]) + struct.pack(">H", n)
    if n <= 0xFFFFFFFF:
        return bytes([m | 26]) + struct.pack(">I", n)
    return bytes([m | 27]) + struct.pack(">Q", n)


def uint(n):
    return head(0, n)


def shell_killer_order(n):
    """Key order that drives Shell's original n/2,n/4,... gap sequence to Theta(n^2):
    even slots hold the large half, odd slots the small half (n a power of two)."""
    order = [0] * n
    half = n // 2
    for i in range(half):
        order[2 * i] = half + i
        order[2 * i + 1] = i
    return order


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    rnd = random.Random(8949)
    N = 131072  # == fxamacker default MaxMapPairs == Pion default max_elements

    def w(name, data):
        with open(os.path.join(out, name), "wb") as f:
            f.write(data)

    # A. map with N distinct uint keys (random order) -> duplicate-key checking cost
    keys = list(range(N))
    rnd.shuffle(keys)
    w("map_131072_uint_random.cbor", head(5, N) + b"".join(uint(k) + b"\xf6" for k in keys))
    # A2. same, indefinite-length map
    w("map_131072_uint_indef.cbor", b"\xbf" + b"".join(uint(k) + b"\xf6" for k in keys) + b"\xff")
    # A3. 16384-pair map (smaller, so the quadratic run still finishes quickly)
    k2 = list(range(16384))
    rnd.shuffle(k2)
    w("map_16384_uint_random.cbor", head(5, 16384) + b"".join(uint(k) + b"\xf6" for k in k2))
    # B. deterministic-encode sort attack: Shell-sort killer order (uint keys, fast path)
    w("map_131072_uint_shellkiller.cbor",
      head(5, N) + b"".join(uint(k) + b"\xf6" for k in shell_killer_order(N)))
    # B2. same order with byte-string keys (slow path: encode_map_slow / CTAP2)
    w("map_131072_bstr_shellkiller.cbor",
      head(5, N) + b"".join(head(2, 4) + struct.pack(">I", k) + b"\xf6" for k in shell_killer_order(N)))
    # B3. 16384-pair variants (finish quickly enough for 5 interleaved bench_compare rounds)
    M = 16384
    w("map_16384_uint_shellkiller.cbor",
      head(5, M) + b"".join(uint(k) + b"\xf6" for k in shell_killer_order(M)))
    w("map_16384_bstr_shellkiller.cbor",
      head(5, M) + b"".join(head(2, 4) + struct.pack(">I", k) + b"\xf6" for k in shell_killer_order(M)))
    w("map_16384_uint_indef.cbor", b"\xbf" + b"".join(uint(k) + b"\xf6" for k in k2) + b"\xff")
    # C. large payloads
    w("bstr_64MiB.cbor", head(2, 64 << 20) + bytes(rnd.getrandbits(8) for _ in range(1 << 16)) * 1024)
    w("tstr_64MiB.cbor", head(3, 64 << 20) + (b"abcdefgh\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80" * ((64 << 20) // 17 + 1))[: 64 << 20])
    # D. flat arrays at the element limit
    w("array_131072_f64.cbor", head(4, N) + b"".join(b"\xfb" + struct.pack(">d", rnd.random()) for _ in range(N)))
    w("array_131072_uint64.cbor", head(4, N) + b"".join(uint(rnd.getrandbits(64)) for _ in range(N)))
    # E. indefinite byte string, 1M 1-byte chunks (chunk concatenation cost)
    w("indef_bstr_1M_chunks.cbor", b"\x5f" + b"\x41\x61" * (1 << 20) + b"\xff")
    w("indef_tstr_1M_chunks.cbor", b"\x7f" + b"\x61\x61" * (1 << 20) + b"\xff")
    # F. text-keyed map (typical JSON-like), 131072 keys, random order
    tk = ["k%07d" % i for i in range(N)]
    rnd.shuffle(tk)
    w("map_131072_text_random.cbor", head(5, N) + b"".join(head(3, len(s)) + s.encode() + b"\x01" for s in tk))


if __name__ == "__main__":
    main()
