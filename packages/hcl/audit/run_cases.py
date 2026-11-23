#!/usr/bin/env python3
"""Run a driver over a case TSV, surviving crashes.

usage: run_cases.py OUT CASES.tsv -- CMD... (CMD gets `cases <file>` appended)

Cases run in chunks of CHUNK lines per process. If a chunk's process dies (signal, panic,
wasm trap, non-zero exit, timeout) the chunk is bisected until each crashing case runs alone;
a case whose own process dies is recorded as `id<TAB>CRASH<TAB>rc=<code> <first stderr line>`.
"""
import os
import subprocess
import sys
import tempfile

TIMEOUT = int(os.environ.get("HCL_AUDIT_CASE_TIMEOUT", "120"))
CHUNK = int(os.environ.get("HCL_AUDIT_CHUNK", "500"))


def run(cmd, path):
    try:
        p = subprocess.run(cmd + ["cases", path], capture_output=True, timeout=TIMEOUT)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return "timeout", b"", b"timeout"


def run_lines(cmd, tmp, chunk, out):
    """Run `chunk` in one process; on a crash bisect until the crashing cases are isolated."""
    open(tmp, "wb").write(b"\n".join(chunk) + b"\n")
    rc, stdout, stderr = run(cmd, tmp)
    if rc == 0 and stdout.count(b"\n") == len(chunk):
        out.append(stdout)
        return 0
    if len(chunk) == 1:
        cid = chunk[0].split(b"\t", 1)[0]
        msg = (stderr.strip().split(b"\n") or [b""])[0][:160]
        out.append(cid + b"\tCRASH\trc=" + str(rc).encode() + b" " + msg + b"\n")
        return 1
    mid = len(chunk) // 2
    return run_lines(cmd, tmp, chunk[:mid], out) + run_lines(cmd, tmp, chunk[mid:], out)


def main():
    out_path, cases_path = sys.argv[1], sys.argv[2]
    cmd = sys.argv[sys.argv.index("--") + 1:]
    lines = [l for l in open(cases_path, "rb").read().split(b"\n") if l and not l.startswith(b"#")]
    crashes = 0
    out = []
    with tempfile.TemporaryDirectory() as td:
        tmp = os.path.join(td, "chunk.tsv")
        for start in range(0, len(lines), CHUNK):
            crashes += run_lines(cmd, tmp, lines[start:start + CHUNK], out)
    open(out_path, "wb").write(b"".join(out))
    if crashes:
        print(f"  {crashes} case(s) crashed the driver: {' '.join(cmd)}", file=sys.stderr)


if __name__ == "__main__":
    main()
