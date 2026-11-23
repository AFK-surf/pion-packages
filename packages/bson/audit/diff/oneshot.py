"""Run one command with a timeout; print label, exit status (signal name on abort), wall time, the
process's own peak RSS and the first output line.   usage: oneshot.py <label> <timeout_s> <cmd...>"""
import os
import signal
import subprocess
import sys
import tempfile
import time

label, tmo, cmd = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
out = tempfile.TemporaryFile()
t0 = time.time()
p = subprocess.Popen(cmd, stdout=out, stderr=subprocess.STDOUT)
status, ru = None, None
while True:
    pid, st, r = os.wait4(p.pid, os.WNOHANG)
    if pid:
        status, ru = st, r
        break
    if time.time() - t0 > tmo:
        p.kill()
        _, st, r = os.wait4(p.pid, 0)
        status, ru = "TIMEOUT", r
        break
    time.sleep(0.005)
dt = time.time() - t0
if status != "TIMEOUT":
    if os.WIFSIGNALED(status):
        status = signal.Signals(os.WTERMSIG(status)).name
    else:
        status = os.WEXITSTATUS(status)
        status = "134(SIGABRT)" if status == 134 else str(status)
rss = ru.ru_maxrss / (1024.0 * 1024.0 if sys.platform == "darwin" else 1024.0)
out.seek(0)
lines = out.read().decode("utf-8", "replace").strip().splitlines()
first = lines[0][:110] if lines else ""
print("  %-46s exit=%-12s %8.3fs  rss=%7.1f MiB  %s" % (label, status, dt, rss, first))
