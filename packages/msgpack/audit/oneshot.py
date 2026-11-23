#!/usr/bin/env python3
"""Run one command with a wall-clock timeout; print elapsed, exit status and peak RSS.

usage: oneshot.py <label> <timeout_s> <cmd...>
"""
import resource
import subprocess
import sys
import time

label, timeout = sys.argv[1], float(sys.argv[2])
cmd = sys.argv[3:]
t0 = time.time()
try:
    p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    rc = p.returncode
    out = p.stdout.decode("utf-8", "replace").strip().splitlines()
    first = out[0][:60] if out else ""
except subprocess.TimeoutExpired:
    rc, first = "TIMEOUT", ""
dt = time.time() - t0
rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
rss_mib = rss / (1024 * 1024) if sys.platform == "darwin" else rss / 1024
status = "rc=%s" % rc
if isinstance(rc, int) and rc < 0:
    status += " (signal %d%s)" % (-rc, ", SIGSEGV" if rc == -11 else "")
print("%-62s %9.3f s  %-24s peakRSS=%.1f MiB  %s" % (label, dt, status, rss_mib, first))
