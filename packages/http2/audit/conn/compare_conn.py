#!/usr/bin/env python3
"""Side-by-side: Pion Connection::feed vs a real Go x/net/http2 Server on the same attack bytes.

usage: compare_conn.py <scenarios.txt> <pion_probe> <conn_go> [--md out.md]
A Pion abort is recorded as CRASH and the probe restarted on the next scenario.
"""
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "diff"))
from compare import run_pion  # noqa: E402


def verdict(p, g):
    if p.startswith("CRASH"):
        return "**P0: Pion process aborts**"
    p_ok = p.startswith("ACCEPTED")
    g_rej = "GOAWAY" in g or re.search(r"RST\(\d+:(?!NO_ERROR)", g) is not None or ":431)" in g
    if p_ok and g_rej:
        return "**Pion accepts, Go rejects**"
    if not p_ok and not g_rej:
        return "**Pion rejects, Go accepts**"
    if not p_ok:
        # every Pion error is connection-fatal (H2Error carries no stream id)
        return "both reject" + ("" if "GOAWAY" in g else " (Go: stream-level only, Pion: whole connection)")
    return "both accept"


def main():
    args = sys.argv[1:]
    md = None
    if "--md" in args:
        i = args.index("--md")
        md = args[i + 1]
        del args[i : i + 2]
    scen, probe, go = args
    names = [l.split("\t", 1)[0] for l in open(scen).read().splitlines()]
    pion, crashes = run_pion(probe, "conn", scen, len(names))
    gout = subprocess.run([go, scen], capture_output=True, text=True).stdout.splitlines()
    G = dict(l.split("\t", 1) for l in gout)
    rows = ["| scenario | Pion `Connection::feed` | Go x/net/http2 Server | verdict |", "|---|---|---|---|"]
    for i, n in enumerate(names):
        p = pion[i].split("\t", 1)[1] if pion[i] is not None else "CRASH: " + crashes.get(i, "")
        g = G.get(n, "?")
        rows.append(f"| `{n}` | {p} | {g} | {verdict(p, g)} |")
    text = f"# Connection-level differential ({len(names)} scenarios, MaxConcurrentStreams=4)\n\n" + "\n".join(rows) + "\n"
    print(text)
    if md:
        open(md, "w").write(text)


if __name__ == "__main__":
    main()
