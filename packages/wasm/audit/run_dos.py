#!/usr/bin/env python3
"""Time + peak-RSS runner for DoS probes and the W1-W3 profile.

usage: run_dos.py <probe_dir> <harness_bin> <oracle_bin> [--timeout S] [--only name,...]

For each probe: Pion `harness time <f> 1 validate` vs Rust `oracle time <f> 1`
(wasmparser WASM2 validation).  Wall ms from the in-process clock, peak RSS via wait4().
"""
import os
import subprocess
import sys
import time


def run(cmd, timeout):
    t0 = time.time()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = t0 + timeout
    while True:
        pid, status, ru = os.wait4(p.pid, os.WNOHANG)
        if pid:
            break
        if time.time() > deadline:
            p.kill()
            pid, status, ru = os.wait4(p.pid, 0)
            return "TIMEOUT>%ds" % timeout, ru.ru_maxrss, time.time() - t0
        time.sleep(0.01)
    out = p.stdout.read().decode("utf-8", "replace").strip().splitlines()
    err = p.stderr.read().decode("utf-8", "replace").strip().splitlines()
    rss = ru.ru_maxrss if sys.platform == "darwin" else ru.ru_maxrss * 1024
    line = out[-1] if out else ("EXIT %d %s" % (os.waitstatus_to_exitcode(status), err[-1:] if err else ""))
    return line, rss, time.time() - t0


def main():
    d, harness, oracle = sys.argv[1:4]
    timeout = int(sys.argv[sys.argv.index("--timeout") + 1]) if "--timeout" in sys.argv else 300
    only = sys.argv[sys.argv.index("--only") + 1].split(",") if "--only" in sys.argv else None
    names = [l.split("\t")[1] for l in open(os.path.join(d, "manifest.tsv")) if l.strip()]
    print("| probe | size | Pion wall | Pion RSS | Pion result | wasmparser wall | wasmparser RSS | ratio |")
    print("|---|---:|---:|---:|---|---:|---:|---:|")
    for n in names:
        if only and n not in only:
            continue
        f = os.path.join(d, n + ".wasm")
        pl, prss, pw = run([harness, "time", f, "1", "validate"], timeout)
        rl, rrss, rw = run([oracle, "time", f, "1"], timeout)
        pres = pl.split("result=")[-1][:60]
        print(f"| `{n}` | {os.path.getsize(f):,} B | {pw * 1000:,.0f} ms | {prss / 1048576:,.1f} MiB | {pres} | "
              f"{rw * 1000:,.0f} ms | {rrss / 1048576:,.1f} MiB | {pw / max(rw, 1e-3):,.1f}x |", flush=True)


if __name__ == "__main__":
    main()
