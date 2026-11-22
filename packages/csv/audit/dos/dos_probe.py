#!/usr/bin/env python3
"""O(n^2) / DoS scaling probe: time Pion `csv` and Rust `csv =1.4.0` on adversarial inputs of size N and 4N.

  python3 dos_probe.py [OUTDIR] [SCALE]

A linear parser shows t(4N)/t(N) ~= 4; quadratic ~= 16. Each timing is the best of 3 runs of the
release binaries bench/pion_adv and tools/rust_ref (rust_bench, ByteRecord), so process start-up is included
(both sides equally); N is chosen so that the 4N run takes >= ~50 ms.
"""
import os
import subprocess
import sys
import time

BIN = os.environ.get("AUDIT_BIN", "/tmp/pion-csv-audit/bin")
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-csv-audit/dos"
SCALE = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
os.makedirs(OUT, exist_ok=True)

H = b"h\n"
PATTERNS = [
    # name, mode, generator(n) -> bytes, base n
    ("one 8 MB quoted field of doubled quotes", "default", lambda n: H + b'"' + b'""' * n + b'"\n', 1_000_000),
    ("10k-column rows (a,a,a,...)", "default",
     lambda n: (b",".join([b"h"] * 10000) + b"\n") + (b",".join([b"a"] * 10000) + b"\n") * n, 100),
    ("comment-line flood (Trim::All + comment)", "trim_comment", lambda n: H + b"# c,c,c\n" * n + b"x\n", 1_000_000),
    ("blank-line flood", "default", lambda n: H + b"\n" * n + b"x\n", 4_000_000),
    ("escape flood in one field", "escape", lambda n: H + b'"' + b'\\"' * n + b'"\n', 1_000_000),
    ("text after closing quote, every field", "default",
     lambda n: (b",".join([b"h"] * 1000) + b"\n") + (b",".join([b'"q"tail'] * 1000) + b"\n") * n, 100),
    ("1M one-byte records", "default", lambda n: H + b"a\n" * n, 1_000_000),
]


def best(cmd):
    ts = []
    for _ in range(3):
        t = time.perf_counter()
        p = subprocess.run(cmd, capture_output=True)
        ts.append(time.perf_counter() - t)
        if p.returncode != 0:
            return None, p.stdout.decode()[:200]
    return min(ts), p.stdout


def main():
    print("| pattern | N | Pion t(N) ms | Pion t(4N) ms | Pion ratio | Rust t(N) ms | Rust t(4N) ms | Rust ratio | outputs equal |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---|")
    for name, mode, gen, n in PATTERNS:
        n = max(1, int(n * SCALE))
        row = []
        outs = []
        for k in (n, 4 * n):
            path = os.path.join(OUT, "dos_%s_%d.csv" % (mode, k))
            with open(path, "wb") as f:
                f.write(gen(k))
            tp, op = best([os.path.join(BIN, "pion_adv"), mode, path])
            tr, orr = best([os.path.join(BIN, "rust_bench"), mode, "byte", path])
            row.append((tp, tr))
            outs.append(op == orr)
            os.unlink(path)
        f = lambda t: "%.1f" % (t * 1000) if t else "ERR"
        r = lambda a, b: "%.2f" % (b / a) if a and b else "-"
        print("| %s | %d | %s | %s | **%s** | %s | %s | %s | %s |" % (
            name, n, f(row[0][0]), f(row[1][0]), r(row[0][0], row[1][0]),
            f(row[0][1]), f(row[1][1]), r(row[0][1], row[1][1]), all(outs)))


if __name__ == "__main__":
    main()
