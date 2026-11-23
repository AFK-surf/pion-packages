#!/usr/bin/env python3
"""Run one command once: wall time, exit status / signal, peak RSS, first line of stdout.

usage: oneshot.py <label> <timeout_s> <cmd...>
"""
import os
import signal
import subprocess
import sys
import time

label, timeout = sys.argv[1], float(sys.argv[2])
cmd = sys.argv[3:]
t0 = time.time()
p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
status = None
try:
    out, err = p.communicate(timeout=timeout)
except subprocess.TimeoutExpired:
    p.kill()
    out, err = p.communicate()
    status = "TIMEOUT>%ds" % timeout
wall = time.time() - t0
rc = p.returncode
if status is None:
    status = ("SIGNAL %s" % signal.Signals(-rc).name) if rc < 0 else ("exit %d" % rc)
import resource
rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / (1024 * 1024)  # macOS: bytes
first = (out.decode(errors="replace").strip().split("\n") or [""])[0][:90]
print("| %s | %.2f s | %s | %.1f MiB | `%s` |" % (label, wall, status, rss, first))
