#!/usr/bin/env python3
"""Sparse-read workload: N GNU PAX 1.0 sparse files (realsize 1 MiB, 64 x 4 KiB data fragments).

  gen_sparse.py <out.tar> [N=400]
"""
import sys


def rec(k, v):
    base = len(k) + len(v) + 3
    n = base + len(str(base))
    if base + len(str(n)) != n:
        n = base + len(str(n))
    return f"{n} {k}={v}\n".encode()


def block(name, tf, size):
    b = bytearray(512)
    b[0:len(name)] = name.encode()
    b[100:108] = b"0000644\x00"
    b[108:116] = b"0001750\x00"
    b[116:124] = b"0001750\x00"
    b[124:136] = b"%011o\x00" % size
    b[136:148] = b"14524770400\x00"
    b[156:157] = tf
    b[257:265] = b"ustar\x0000"
    s = sum(32 if 148 <= i < 156 else b[i] for i in range(512))
    b[148:156] = b"%06o\x00 " % s
    return bytes(b)


def pad(b):
    return b + bytes((512 - len(b) % 512) % 512)


def main():
    out, n = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 400
    frag, nfrag, real = 4096, 64, 1 << 20
    parts = []
    for i in range(n):
        m = f"{nfrag}\n" + "".join(f"{k * 16384}\n{frag}\n" for k in range(nfrag))
        body = pad(m.encode()) + bytes(((i + k) & 255) for k in range(frag * nfrag))
        recs = rec("GNU.sparse.major", "1") + rec("GNU.sparse.minor", "0") + \
            rec("GNU.sparse.name", f"sparse/{i:05d}.img") + rec("GNU.sparse.realsize", str(real))
        parts += [block(f"PaxHeaders/{i}", b"x", len(recs)), pad(recs), block(f"GNUSparseFile.0/{i:05d}.img", b"0", len(body)), pad(body)]
    parts.append(bytes(1024))
    open(out, "wb").write(b"".join(parts))
    print(f"wrote {out}: {n} sparse entries, {sum(map(len, parts))} bytes")


if __name__ == "__main__":
    main()
