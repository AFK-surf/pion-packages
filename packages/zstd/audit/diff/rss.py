#!/usr/bin/env python3
"""Run a command and measure it: (stdout+stderr, exit code, wall seconds, peak RSS bytes of the command itself).
Linux: max VmHWM of /proc/<pid>/status sampled every millisecond, counted only after the child has exec'd (before
that /proc/<pid> is the forked Python parent; wait4's ru_maxrss would also count the parent's inherited pages). macOS: ru_maxrss of wait4.
usage as a script: rss.py <cmd...>  -> prints `<seconds> <rss_bytes> <exit>`"""
import os
import subprocess
import sys
import time


def run(argv):
    t0 = time.time()
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    status = "/proc/%d/status" % p.pid
    if not os.path.exists(status):  # macOS
        out = p.stdout.read()
        _, st, ru = os.wait4(p.pid, 0)
        return out.decode(errors="replace"), os.waitstatus_to_exitcode(st), time.time() - t0, ru.ru_maxrss
    out = bytearray()
    peak = 0
    me = os.readlink("/proc/self/exe")
    os.set_blocking(p.stdout.fileno(), False)
    while True:
        try:
            chunk = p.stdout.read()
            if chunk:
                out += chunk
        except BlockingIOError:
            pass
        try:
            # until the child has exec'd, /proc/<pid> still describes the forked Python parent (its VmHWM
            # included): only samples taken once the executable has changed count
            if os.readlink("/proc/%d/exe" % p.pid) != me:
                for ln in open(status):
                    if ln.startswith("VmHWM:"):
                        peak = max(peak, int(ln.split()[1]) * 1024)
        except (OSError, ValueError):
            pass
        if p.poll() is not None:
            break
        time.sleep(0.001)
    os.set_blocking(p.stdout.fileno(), True)
    out += p.stdout.read() or b""
    return out.decode(errors="replace"), p.returncode, time.time() - t0, peak


if __name__ == "__main__":
    o, rc, s, r = run(sys.argv[1:])
    print("%.3f %d %d" % (s, r, rc))
