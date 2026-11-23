#!/usr/bin/env python3
"""Adversarial .avro OCF generator for the DoS probes in run_audit.sh.

usage: gen_ocf.py <outdir>
"""
import json
import os
import sys
import zlib

SYNC = bytes(range(0xA0, 0xB0))


def zz(n):
    return (n << 1) ^ (n >> 63)


def varint(u):
    out = bytearray()
    while u >= 0x80:
        out.append((u & 0x7F) | 0x80)
        u >>= 7
    out.append(u)
    return bytes(out)


def lng(n):
    return varint(zz(n))


def bstr(b):
    return lng(len(b)) + b


def header(schema, codec="null"):
    meta = [(b"avro.schema", json.dumps(schema).encode()), (b"avro.codec", codec.encode())]
    out = b"Obj\x01" + lng(len(meta))
    for k, v in meta:
        out += bstr(k) + bstr(v)
    return out + b"\x00" + SYNC


def block(count, payload):
    return lng(count) + lng(len(payload)) + payload + SYNC


def raw_deflate(data):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    arr_null = {"type": "array", "items": "null"}
    # 1 datum per block = one 1,000,000-item array<null> (allowed: max_elements is per block reader)
    body = lng(1_000_000) + b"\x00"
    for k in (1, 8, 32, 64):
        with open(os.path.join(out, "amp_%d.avro" % k), "wb") as f:
            f.write(header(arr_null) + block(1, body) * k)
    # same amplification through deflate (each block ~20 bytes compressed)
    with open(os.path.join(out, "amp_deflate_64.avro"), "wb") as f:
        f.write(header(arr_null, "deflate") + block(1, raw_deflate(body)) * 64)
    # deflate bomb: one `bytes` datum of 512 MiB zeros (rejected by max_bytes = 64 MiB)
    big = 512 * 1024 * 1024
    z = zlib.compressobj(9, zlib.DEFLATED, -15)
    comp = z.compress(lng(big))
    chunk = b"\x00" * (1 << 24)
    for _ in range(big // len(chunk)):
        comp += z.compress(chunk)
    comp += z.flush()
    with open(os.path.join(out, "bomb_512m.avro"), "wb") as f:
        f.write(header("bytes", "deflate") + block(1, comp))
    # 8 legit-but-huge blocks, 60 MiB each (under max_bytes): total retained = 480 MiB from ~0.5 MB
    n60 = 60 * 1024 * 1024
    z = zlib.compressobj(9, zlib.DEFLATED, -15)
    comp60 = z.compress(lng(n60))
    for _ in range(n60 // (1 << 20)):
        comp60 += z.compress(b"\x00" * (1 << 20))
    comp60 += z.flush()
    with open(os.path.join(out, "bomb_8x60m.avro"), "wb") as f:
        f.write(header("bytes", "deflate") + block(1, comp60) * 8)
    for name in sorted(os.listdir(out)):
        print("  %-22s %10d bytes" % (name, os.path.getsize(os.path.join(out, name))))


if __name__ == "__main__":
    main()
