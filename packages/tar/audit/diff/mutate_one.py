#!/usr/bin/env python3
"""Re-create mutation #i of `go_tar/pion_tar mutate <file> <seed> ..` as a file (for triage).

  mutate_one.py <file> <seed> <i> <out>
"""
import sys

M = (1 << 64) - 1


def xs(x):
    x ^= (x << 13) & M
    x ^= x >> 7
    x ^= (x << 17) & M
    return x


def fix(b, off):
    s = sum(32 if 148 <= i < 156 else b[off + i] for i in range(512))
    b[off + 148:off + 156] = (b"%06o" % s) + b"\x00 "


def main():
    src, seed, idx, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    data = open(src, "rb").read()
    n = len(data)
    st = seed or 88172645463325252
    for i in range(idx + 1):
        m = bytearray(data)
        st = xs(st)
        k = st % 4 + 1
        log = []
        for _ in range(k):
            st = xs(st)
            pos = st % n
            st = xs(st)
            m[pos] = st & 255
            st = xs(st)
            fixed = st % 3 != 0 and (pos // 512 + 1) * 512 <= n
            if fixed:
                fix(m, pos // 512 * 512)
            log.append((pos, m[pos], fixed))
    open(out, "wb").write(m)
    print("mutations (pos, byte, checksum fixed):", log)


if __name__ == "__main__":
    main()
