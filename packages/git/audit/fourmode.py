#!/usr/bin/env python3
"""RT-git 4-mode consistency: every differential batch (`<work>/pion-*.bin`, written by difftest.py)
is replayed through the Pion oracle in native_dbg / native_rel / wasm_dbg / wasm_rel.
A crash (native abort / wasm trap) is recorded per record and the run resumes at the next record,
so every vector is exercised in every mode. Records must yield identical result lines in all modes.

Usage: python3 fourmode.py <work_dir>
"""
import glob
import hashlib
import os
import re
import subprocess
import sys

AUDIT = os.path.dirname(os.path.abspath(__file__))
MODES = {
    "native_dbg": [],
    "native_rel": ["--release"],
    "wasm_dbg": ["--target", "wasm32"],
    "wasm_rel": ["--release", "--target", "wasm32"],
}


def count_records(path):
    data = open(path, "rb").read()
    pos = n = 0
    while pos + 4 <= len(data):
        pos += 4 + int.from_bytes(data[pos:pos + 4], "big")
        n += 1
    return n


def run_mode(flags, mode, batch, nrec):
    res = [None] * nrec
    crashes = 0
    start = 0
    while start < nrec:
        cmd = ["pionc", "run"] + flags + [AUDIT, "--", mode, batch, str(start)]
        p = subprocess.run(cmd, capture_output=True, timeout=1800)
        got = start
        for ln in p.stdout.decode("utf-8", "replace").splitlines():
            m = re.match(r"^(\d+) (.*)$", ln)
            if m:
                res[int(m.group(1))] = m.group(2)
                got = int(m.group(1)) + 1
        if got >= nrec:
            break
        # record `got` crashed (no line printed for it)
        res[got] = "CRASH"
        crashes += 1
        start = got + 1
    return res, crashes


def main():
    work = sys.argv[1] if len(sys.argv) > 1 else "/tmp/rt-git-work"
    os.environ["PATH"] = os.path.expanduser("~/.pion/bin") + ":" + os.environ["PATH"]
    print("| Batch | Records | " + " | ".join(MODES) + " | Crashes (per mode) | Verdict |")
    print("| --- | ---: |" + " --- |" * len(MODES) + " ---: | --- |")
    bad = 0
    total = 0
    for batch in sorted(glob.glob(os.path.join(work, "pion-*.bin"))):
        mode = os.path.basename(batch)[5:-4]
        nrec = count_records(batch)
        total += nrec
        cells, outs, crashes = [], [], []
        for name, flags in MODES.items():
            res, c = run_mode(flags, mode, batch, nrec)
            blob = "\n".join(str(r) for r in res).encode()
            outs.append(blob)
            crashes.append(c)
            cells.append(hashlib.sha256(blob).hexdigest()[:12])
        same = all(o == outs[0] for o in outs)
        bad += 0 if same else 1
        print(f"| `{mode}` | {nrec} | " + " | ".join(cells) + f" | {'/'.join(map(str, crashes))} | {'identical' if same else '**DIFF**'} |", flush=True)
    print(f"\nTotal records replayed per mode: {total}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
