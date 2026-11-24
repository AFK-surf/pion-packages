#!/usr/bin/env python3
"""Resource-bomb runner: `dos.py <dos.json> <runner...>` runs `<runner> time <file> 1` once per bomb, in its own
process, and reports verdict, wall ms and peak RSS (os.wait4). Budget per parse: the bomb's `budget_ms` and 512 MiB.

Exit status: 0 all within budget; 1 a P0 breach (or an unclassified breach / wrong verdict / crash); prints
`open <finding>` for breaches that belong to a REPORT.md finding. DOS_ADVISORY=0 only prints (wasm32 information run).
"""
import json
import os
import re
import select
import sys
import time

RSS_BUDGET = 512 * 1024 * 1024
TIMEOUT_S = 300


def measure(cmd):
    r, w = os.pipe()
    t0 = time.monotonic()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        os.dup2(w, 1)
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, 2)
        try:
            os.execvp(cmd[0], cmd)
        finally:
            os._exit(127)
    os.close(w)
    chunks = []
    deadline = t0 + TIMEOUT_S
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            os.kill(pid, 9)
            os.wait4(pid, 0)
            os.close(r)
            return "TIMEOUT", TIMEOUT_S * 1000.0, 0
        rd, _, _ = select.select([r], [], [], min(left, 1.0))
        if rd:
            b = os.read(r, 65536)
            if not b:
                break
            chunks.append(b)
    _, status, ru = os.wait4(pid, 0)
    wall = (time.monotonic() - t0) * 1000.0
    os.close(r)
    rss = ru.ru_maxrss if sys.platform == "darwin" else ru.ru_maxrss * 1024
    out = b"".join(chunks).decode("utf-8", "replace").strip()
    if os.WIFSIGNALED(status) or os.WEXITSTATUS(status) != 0:
        return "CRASH(%s) %s" % (status, out[-80:]), wall, rss
    return out, wall, rss


def main():
    items = json.load(open(sys.argv[1]))
    runner = sys.argv[2:]
    advisory = os.environ.get("DOS_ADVISORY", "1") != "0"
    rc = 0
    worst = (0.0, "")
    for it in items:
        out, wall, rss = measure(runner + ["time", it["path"], "1"])
        verdict = out.split(" us=")[0]
        us = int(out.split(" us=")[1]) if " us=" in out else int(wall * 1000)
        ms = us / 1000.0
        ok_verdict = re.fullmatch("(%s)( .*)?" % it["verdict"], verdict) is not None
        breach = ms > it["budget_ms"] or rss > RSS_BUDGET
        tag = "ok"
        if not ok_verdict:
            tag = "FAIL (P0): verdict %r, want %r" % (verdict, it["verdict"])
            if advisory:
                rc = 1
        elif breach:
            if it["finding"]:
                tag = "open %s: %.0f ms > %d ms budget" % (it["finding"], ms, it["budget_ms"])
                if it["finding"].startswith("P0") and advisory:
                    rc = 1
            else:
                tag = "FAIL (P0, unclassified): %.0f ms / %.1f MiB over budget" % (ms, rss / 1048576.0)
                if advisory:
                    rc = 1
        if ms > worst[0]:
            worst = (ms, it["name"])
        print("  %-30s %9d B  %-26s %10.1f ms/parse  %7.1f MiB  %s" % (it["name"], it["bytes"], verdict[:26], ms, rss / 1048576.0, tag))
    print("  worst: %s %.1f ms" % (worst[1], worst[0]))
    sys.exit(rc)


if __name__ == "__main__":
    main()
