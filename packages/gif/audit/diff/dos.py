#!/usr/bin/env python3
"""DoS / bomb probes for packages/gif (inputs written by `gif_audit gen_dos <dir>`).

usage: dos.py <native|wasm> <dos_dir> <runner...>

Each probe has a verdict requirement and a wall-clock budget. On `native` (release build) a probe that
crashes, returns the wrong verdict, or overruns its budget is a FAIL (exit 1). On `wasm` the same probes
run for information only (node + wasm32 memory limits differ); only crashes on small probes are reported.
"""
import os
import re
import signal
import subprocess
import sys
import time


def run(cmd, timeout):
    """Run under /usr/bin/time (macOS -l / GNU -v) in its own process group; kill the group on timeout.
    Returns (stdout, stderr, rc, seconds, max_rss_mib or None, timed_out)."""
    wrap = ["/usr/bin/time", "-l" if sys.platform == "darwin" else "-v"] if os.path.exists("/usr/bin/time") else []
    t0 = time.time()
    p = subprocess.Popen(wrap + cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
        timed_out = False
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        out, err = p.communicate()
        timed_out = True
    dt = time.time() - t0
    rss = None
    m = re.search(r"(\d+)\s+maximum resident set size", err)
    if m:
        rss = int(m.group(1)) / 1048576
    m = re.search(r"Maximum resident set size \(kbytes\): (\d+)", err)
    if m:
        rss = int(m.group(1)) / 1024
    return out, err, p.returncode, dt, rss, timed_out

# (file, runner mode + args, accepted verdicts, budget seconds, finding id when it fails)
PROBES = [
    ("canvas_65535sq.gif", ["time"], ["ERR LimitExceeded"], 0.5, "control"),
    ("frames_bomb_1024sq_4096f.gif", ["time"], ["ERR LimitExceeded"], 2.0, "control"),
    ("canvas_4096sq_bomb.gif", ["time"], ["OK 1"], 2.0, "control"),
    ("subframe_bomb_1x1_1f_4096sq.gif", ["time"], None, 2.0, "control"),
    # 256 frames x (4096x4096 sub-frame on a 1x1 canvas): 4 GiB of LZW index work for 4 bytes of canvas.
    ("subframe_bomb_1x1_256f_4096sq.gif", ["time"], None, 1.5, "P2-1"),
    # standalone lzw_decode, max_output = Int max ("no limit")
    ("lzw_bomb_1000MiB.lzw", ["lzwtime", "2", "2147483647"], ["OK 1048576000"], 20.0, "control"),
    ("lzw_bomb_1088MiB.lzw", ["lzwtime", "2", "2147483647"], ["OK 1140850688", "ERR LimitExceeded"], 20.0, "P1-2"),
]
WASM_SKIP = ("lzw_bomb_1000MiB.lzw", "lzw_bomb_1088MiB.lzw")


def main():
    target, d = sys.argv[1], sys.argv[2]
    runner = sys.argv[3:]
    bad = 0
    for f, args, want, budget, fid in PROBES:
        if target == "wasm" and f in WASM_SKIP:
            continue
        path = d + "/" + f
        cmd = runner + [args[0], path] + args[1:]
        limit = budget + 10 if target == "native" else budget * 20
        out, err, rc, dt, rss_mib, timed_out = run(cmd, limit)
        if timed_out:
            verdict = "TIMEOUT (killed after %.0fs)" % limit
        else:
            last = [l for l in out.strip().splitlines() if l.startswith(("OK", "ERR"))]
            verdict = last[-1].split(" us=")[0] if last else "CRASH rc=%d %s" % (
                rc, ([l for l in err.strip().splitlines() if "panic" in l or "rror" in l] or [""])[0][:60])
        ok_verdict = (want is None and not verdict.startswith(("CRASH", "TIMEOUT"))) or (
            want is not None and verdict in want)
        ok = ok_verdict and dt <= budget
        status = "ok  " if ok else ("FAIL" if target == "native" else "info")
        if target == "native" and not ok:
            bad += 1
        print("  %s %-36s %-30s %8.3fs (budget %4.1fs)  maxRSS %s  [%s]" % (
            status, f, verdict[:30], dt, budget, "%7.0f MiB" % rss_mib if rss_mib else "      ? MiB", fid))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
