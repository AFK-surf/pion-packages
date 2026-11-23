#!/usr/bin/env python3
"""Run every scenario of cases/dos_cases.txt in the 4 build modes.

usage: run_dos.py <dos_cases.txt> <timeout_s> <wasm_rt.mjs> <native_dbg> <native_rel> <wasm_dbg> <wasm_rel>

Prints one "CHECK <PASS|FAIL> <id> <severity> <desc> | <mode>=<status> ..." line per scenario.
status: ok / err:<kind> (both fine), or SIGSEGV / SIGBUS / SIGABRT / RangeError / trap /
timeout / exit<N> (failures).
"""
import signal
import subprocess
import sys
import time


def classify(cmd, timeout):
    t0 = time.time()
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, "timeout>%ds" % timeout
    dt = time.time() - t0
    out = p.stdout.decode("utf-8", "replace")
    err = p.stderr.decode("utf-8", "replace")
    if p.returncode < 0:
        try:
            name = signal.Signals(-p.returncode).name
        except ValueError:
            name = "signal%d" % -p.returncode
        return False, name
    if p.returncode != 0:
        if "RangeError" in err:
            return False, "RangeError"
        if "RuntimeError" in err or "unreachable" in err:
            return False, "trap"
        if p.returncode in (139, 134, 138):
            return False, {139: "SIGSEGV", 134: "SIGABRT", 138: "SIGBUS"}[p.returncode]
        return False, "exit%d" % p.returncode
    line = [l for l in out.splitlines() if l.startswith("RESULT ")]
    if not line:
        return False, "no-result"
    return True, "%s(%.1fs)" % (line[-1][7:].split(" ")[0], dt)


def main():
    cases, timeout, rt = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    modes = [
        ("native_dbg", [sys.argv[4]]),
        ("native_rel", [sys.argv[5]]),
        ("wasm_dbg", ["node", "--stack-size=984", rt, sys.argv[6]]),
        ("wasm_rel", ["node", "--stack-size=984", rt, sys.argv[7]]),
    ]
    for raw in open(cases, encoding="utf-8"):
        if raw.startswith("#") or not raw.strip():
            continue
        cid, sev, desc, args = raw.rstrip("\n").split("\t")
        res = []
        all_ok = True
        for name, base in modes:
            ok, st = classify(base + ["dos"] + args.split(" "), timeout)
            all_ok = all_ok and ok
            res.append("%s=%s" % (name, st))
        print("CHECK %s %s %s %s | %s" % ("PASS" if all_ok else "FAIL", cid, sev, desc, " ".join(res)), flush=True)


if __name__ == "__main__":
    main()
