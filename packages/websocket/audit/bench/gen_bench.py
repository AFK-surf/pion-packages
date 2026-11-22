#!/usr/bin/env python3
"""Generate adversarial benchmark wire streams (masked client->server frames).

usage: gen_bench.py <out_dir>
Writes <workload>.ws files; every runner prints `msgs=<n>` and `digest=<d>` where the
digest folds, per binary message, its length and the bytes at 0, len/2 and len-1
(text messages contribute their count only: Pion returns String, not bytes)."""
import os, struct, sys

def frame(op, payload, fin=True, key=b"\x37\xfa\x21\x3d"):
    n = len(payload)
    b0 = (0x80 if fin else 0) | op
    if n < 126:
        hdr = bytes([b0, 0x80 | n])
    elif n <= 0xFFFF:
        hdr = bytes([b0, 0x80 | 126]) + struct.pack(">H", n)
    else:
        hdr = bytes([b0, 0x80 | 127]) + struct.pack(">Q", n)
    k = (key * (n // 4 + 1))[:n]
    body = (int.from_bytes(payload, "little") ^ int.from_bytes(k, "little")).to_bytes(n, "little") if n else b""
    return hdr + key + body

def binpay(n, seed):
    base = bytes(((i * 37 + seed) & 0xFF) for i in range(4096))
    return (base * (n // 4096 + 1))[:n]

def textpay(n):
    unit = "WS:世界🌍123".encode()  # 16 bytes
    return (unit * (n // 16 + 1))[:n]

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
W = {}
W["big_64k"] = (b"".join(frame(2, binpay(65536, i)) for i in range(2048)), 2048)
W["big_1m"] = (b"".join(frame(2, binpay(1 << 20, i)) for i in range(128)), 128)
W["big_16m"] = (b"".join(frame(2, binpay(16 << 20, i)) for i in range(8)), 8)
W["text_1m"] = (b"".join(frame(1, textpay(1 << 20)) for i in range(128)), 128)
frag = frame(2, b"0123456789", fin=False) + b"".join(frame(0, b"0123456789", fin=False) for _ in range(9998)) + frame(0, b"0123456789")
W["frag_storm"] = (frag * 100, 100)
W["tiny_1m"] = (frame(2, b"0123456789abcdef") * 1_000_000, 1_000_000)
W["drip_20k"] = (frame(2, b"0123456789abcdef") * 20_000, 20_000)
for name, (wire, msgs) in W.items():
    with open(os.path.join(out, name + ".ws"), "wb") as f:
        f.write(wire)
    print(f"{name} bytes={len(wire)} msgs={msgs}")
