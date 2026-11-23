#!/usr/bin/env python3
"""measure.py <label> <timeout_s> <cmd...>: run cmd, print rc / wall / peak RSS (MiB) / first stdout line."""
import platform
import resource
import subprocess
import sys
import time

label, timeout, cmd = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
t0 = time.time()
try:
    p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    wall = time.time() - t0
    rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    rss = rss / 1048576.0 if platform.system() == "Darwin" else rss / 1024.0
    rc = "SIGNAL %d" % -p.returncode if p.returncode < 0 else str(p.returncode)
    out = p.stdout.decode(errors="replace").strip().split("\n")[0][:150]
    if not out:
        out = "(stderr) " + p.stderr.decode(errors="replace").strip().split("\n")[-1][:120]
    print("%-44s rc=%-9s wall=%6.2fs peak_rss=%7.1f MiB  %s" % (label + ":", rc, wall, rss, out))
except subprocess.TimeoutExpired:
    print("%-44s rc=TIMEOUT wall>%.0fs" % (label + ":", timeout))
