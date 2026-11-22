#!/usr/bin/env python3
"""Hash-flooding corpus for Pion's interner (`intern_before_window` / `intern_after_window`).

Pion hashes each line with an unseeded 32-bit FNV-1a variant over little-endian 4-byte words,
then probes a linear open-addressing table keyed by that hash. FNV's multiply is invertible
mod 2^32, so for any first word w0 we can solve for the second word w1 that lands on the
same pre-newline state => unlimited *full 32-bit* collisions for 9-byte lines `w0 w1 \\n`.
Only printable-ASCII solutions are kept so the input stays valid UTF-8 for imara-diff's &str API.

usage: gen_hash_flood.py OUT_DIR [N]
"""
import os, random, sys

P = 16777619
PINV = pow(P, -1, 1 << 32)
H0 = 0x811C9DC5
M = 0xFFFFFFFF

def word(b):
    return b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24

def pion_hash(line: bytes) -> int:
    """Reference model of the Pion line hash (for self-check)."""
    h, i, n = H0, 0, len(line)
    while i + 4 <= n - 0 and i < n - 3:
        w = word(line[i:i + 4])
        x = w ^ 0x0A0A0A0A
        if ((x - 0x01010101) & (~x) & 0x80808080) & M:
            break
        h = ((h ^ w) * P) & M
        i += 4
    while i < n:
        c = line[i]; h = ((h ^ c) * P) & M; i += 1
        if c == 10:
            break
    return (h ^ ((h >> 16) & 0xFFFF)) & M

def main():
    out = sys.argv[1]; n = int(sys.argv[2]) if len(sys.argv) > 2 else 40000
    os.makedirs(out, exist_ok=True)
    r = random.Random(20261123)
    target = None  # state after w1, shared by all lines
    lines, seen = [], set()
    ok = set(range(0x21, 0x7F))
    while len(lines) < n:
        w0 = bytes(r.choice(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz") for _ in range(4))
        h1 = ((H0 ^ word(w0)) * P) & M
        if target is None:
            w1 = b"zzzz"; target = ((h1 ^ word(w1)) * P) & M
        else:
            v = ((target * PINV) & M) ^ h1
            w1 = bytes([(v >> s) & 0xFF for s in (0, 8, 16, 24)])
            if any(c not in ok for c in w1):
                continue
        line = w0 + w1
        if line in seen:
            continue
        seen.add(line); lines.append(line)
    hs = {pion_hash(l + b"\n") for l in lines[:1000]}
    assert len(hs) == 1, f"model mismatch: {len(hs)} distinct hashes"
    before = b"\n".join(lines) + b"\n"
    after = b"// header\n" + b"\n".join(lines[: n // 2] + lines[n // 2 + 1:]) + b"\n"
    open(os.path.join(out, "hashflood.before"), "wb").write(before)
    open(os.path.join(out, "hashflood.after"), "wb").write(after)
    # control: same shape, ordinary distinct lines
    ctrl = [b"%08d" % (i * 7919 % 10**8) for i in range(n)]
    open(os.path.join(out, "hashctrl.before"), "wb").write(b"\n".join(ctrl) + b"\n")
    open(os.path.join(out, "hashctrl.after"), "wb").write(b"// header\n" + b"\n".join(ctrl[: n // 2] + ctrl[n // 2 + 1:]) + b"\n")
    print(f"{n} lines sharing hash {next(iter(hs)):#010x}")

if __name__ == "__main__":
    main()
