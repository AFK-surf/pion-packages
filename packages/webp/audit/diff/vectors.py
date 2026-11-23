#!/usr/bin/env python3
"""Check `webp_audit digest` of every file listed in vectors/EXPECTED. usage: vectors.py <vectors_dir> <pion_cmd...>"""
import os
import subprocess
import sys


def abort_msg(stderr, rc):
    """First `pion panic` line (native and wasm runtimes word it differently), else the last stderr line."""
    lines = stderr.strip().splitlines()
    for ln in lines:
        if "pion panic" in ln:
            return ln.strip()
    return lines[-1].strip() if lines else "rc=%d" % rc


def main():
    d, cmd = sys.argv[1], sys.argv[2:]
    bad = 0
    for line in open(os.path.join(d, "EXPECTED")):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        name, want = line.split(" ", 1)
        want = want.strip()
        r = subprocess.run(cmd + ["digest", os.path.join(d, name)], capture_output=True, text=True, timeout=120)
        got = r.stdout.strip().split(" ", 1)[1] if r.stdout.strip() else ""
        if r.returncode != 0 or not got:
            got = "CRASH " + abort_msg(r.stderr, r.returncode)[:80]
        ok = got.startswith("ERR") if want == "ERR" else got == want
        print("  %s %-42s got %s" % ("ok  " if ok else "FAIL", name, got[:90] + ("" if ok else "  want " + want[:60])))
        bad += 0 if ok else 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
