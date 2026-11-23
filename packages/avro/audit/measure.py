#!/usr/bin/env python3
"""Run one command with a timeout and report exit status, wall time, peak RSS and its first line.

usage: measure.py <label> <timeout_s> <cmd> [args...]
Prints:  <label>: rc=<rc|TIMEOUT|SIGNAL n> wall=<s> peak_rss=<MiB> out=<first stdout line>
"""
import os
import platform
import re
import subprocess
import sys
import time


def main():
    label, timeout = sys.argv[1], float(sys.argv[2])
    cmd = sys.argv[3:]
    tflag = "-l" if platform.system() == "Darwin" else "-v"
    t0 = time.time()
    try:
        p = subprocess.run(["/usr/bin/time", tflag] + cmd, capture_output=True, timeout=timeout)
        wall = time.time() - t0
        err = p.stderr.decode(errors="replace")
        rc = p.returncode
        if rc < 0:
            rcs = "SIGNAL %d" % -rc
        elif rc > 128 and ("Command terminated by signal" in err or "Segmentation" in err):
            rcs = "SIGNAL %d" % (rc - 128)
        else:
            rcs = str(rc)
        m = re.search(r"(\d+)\s+maximum resident set size", err)  # macOS: bytes
        if m:
            rss = int(m.group(1)) / 1048576.0
        else:
            m = re.search(r"Maximum resident set size \(kbytes\): (\d+)", err)  # GNU time: KiB
            rss = int(m.group(1)) / 1024.0 if m else -1
        if rc != 0 and ("Command terminated by signal" in err):
            rcs = "SIGNAL " + err.split("Command terminated by signal")[1].split()[0]
        out = p.stdout.decode(errors="replace").strip().split("\n")[0][:140]
        if not out:
            tail = [l for l in err.strip().split("\n") if l and "  " not in l[:8]]
            out = "(stderr) " + (tail[0][:120] if tail else "")
        print("%-58s rc=%-9s wall=%7.2fs peak_rss=%8.1f MiB  out=%s" % (label + ":", rcs, wall, rss, out))
    except subprocess.TimeoutExpired:
        print("%-58s rc=TIMEOUT  wall>%6.0fs" % (label + ":", timeout))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
