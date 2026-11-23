#!/usr/bin/env python3
"""Deterministic malformed RTP/RTCP/SRTP/SRTCP corpus for the packages/rtp red-team fuzz.

usage: gen_corpus.py <pion_cases.txt> <rust_cases.txt> <out.txt> <n_per_kind> <seed>
Each output line is "<kind> <hex>", kind in rtp | rtcp | srtp | srtcp. Seeds are the interop
plaintexts / ciphertexts (cm80 + gcm keys, which the probe's fuzz mode uses), mutated with bit
flips, boundary bytes, truncation / extension, length-field tampering and splicing."""
import random, sys

def load(paths):
    seeds = {"rtp": [], "rtcp": [], "srtp": [], "srtcp": []}
    for p in paths:
        for line in open(p):
            f = line.split()
            if len(f) != 5:
                continue
            case, prof, kind, plain, wire = f
            seeds[kind].append(bytes.fromhex(plain))
            if prof in ("cm80", "gcm"):
                seeds["s" + kind].append(bytes.fromhex(wire))
    return seeds

BOUND = [0x00, 0x01, 0x0F, 0x10, 0x1F, 0x20, 0x3F, 0x40, 0x7F, 0x80, 0xBE, 0xC0, 0xDE, 0xFE, 0xFF]

def mutate(r, kind, b):
    b = bytearray(b)
    for _ in range(r.choice([1, 1, 1, 2, 3, 5])):
        op = r.randrange(11)
        n = len(b)
        if op == 0 and n:  # bit flip
            i = r.randrange(n); b[i] ^= 1 << r.randrange(8)
        elif op == 1 and n:  # boundary byte
            b[r.randrange(n)] = r.choice(BOUND)
        elif op == 2 and n:  # truncate
            del b[r.randrange(n):]
        elif op == 3:  # extend
            b += bytes(r.randrange(256) for _ in range(r.choice([1, 2, 3, 4, 7, 16])))
        elif op == 4 and n >= 4:  # 16-bit length field tamper (RTCP length / RTP ext words / seq)
            i = r.choice([2] + ([n - 2] if n > 2 else []) + [r.randrange(n - 1)])
            v = r.choice([0, 1, 2, 3, 0x7FFF, 0x8000, 0xFFFF, r.randrange(65536)])
            b[i:i + 2] = v.to_bytes(2, "big")
        elif op == 5 and n:  # first byte: V/P/X/CC/RC
            b[0] = (b[0] & 0xC0) | r.randrange(64) if r.random() < 0.8 else r.randrange(256)
        elif op == 6 and n >= 2:  # PT / M
            b[1] = r.choice([0x60, 0xE0, 0xC8, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCC, 0x40, 0x5F, 0xDF, r.randrange(256)])
        elif op == 7 and n >= 16 and kind in ("rtp", "srtp"):  # force extension block with odd contents
            b[0] |= 0x10
            off = 12 + 4 * (b[0] & 0x0F)
            if off + 4 <= n:
                b[off:off + 2] = r.choice([b"\xbe\xde", b"\x10\x00", b"\x10\x0f", b"\x12\x34"])
                b[off + 2:off + 4] = r.randrange(0, 8).to_bytes(2, "big")
        elif op == 8 and n:  # padding bit + pad byte
            b[0] |= 0x20; b[-1] = r.choice([0, 1, 3, 4, 255, r.randrange(256)])
        elif op == 9 and n:  # random region
            i = r.randrange(n); k = min(n - i, r.randrange(1, 9))
            b[i:i + k] = bytes(r.randrange(256) for _ in range(k))
        elif op == 10 and n >= 8:  # splice duplicate (compound amplification)
            i = r.randrange(n); b += b[i:]
    return bytes(b)

def main():
    pion, rust, out, per, seed = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
    r = random.Random(seed)
    seeds = load([pion, rust])
    lines = []
    for kind in ("rtp", "rtcp", "srtp", "srtcp"):
        pool = seeds[kind]
        for i in range(per):
            s = r.choice(pool)
            b = s if i % 10 == 0 else mutate(r, kind, s)
            if i % 97 == 0:
                b = bytes(r.randrange(256) for _ in range(r.randrange(0, 40)))
            lines.append("%s %s" % (kind, b.hex()))
    open(out, "w").write("\n".join(lines) + "\n")
    print("corpus: %d lines -> %s" % (len(lines), out))

main()
