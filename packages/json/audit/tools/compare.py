#!/usr/bin/env python3
"""Line-by-line differential: compare.py <cases> pion=<out> ref=<out> [--show N] [--name NAME]

`ERR <kind>` and `ERR` compare equal (accept/reject is what is compared, not error kinds).
Prints a summary with up to N examples per divergence class and exits 1 if any line differs.
"""
import sys
from collections import defaultdict

args = [a for a in sys.argv[1:]]
show = 8
name = ""
if "--show" in args:
    i = args.index("--show"); show = int(args[i + 1]); del args[i:i + 2]
if "--name" in args:
    i = args.index("--name"); name = args[i + 1]; del args[i:i + 2]
cases = open(args[0]).read().split("\n")
(pn, pf), (rn, rf) = (a.split("=", 1) for a in args[1:3])
P = open(pf).read().split("\n")
Q = open(rf).read().split("\n")


def norm(x):
    return "ERR" if x.startswith("ERR") else x


def show_input(c):
    h = c.split("\t")
    try:
        t = bytes.fromhex(h[0]).decode("utf-8", "backslashreplace")
    except ValueError:
        t = h[0]
    t = t if len(t) < 90 else t[:60] + f"...<{len(t)} chars>"
    return repr(t) + (f" [{h[1]}]" if len(h) > 1 else "")


def cls(p, q):
    if norm(p) == "ERR" and norm(q) != "ERR":
        return f"{pn} rejects, {rn} accepts"
    if norm(p) != "ERR" and norm(q) == "ERR":
        return f"{pn} accepts, {rn} rejects"
    return "different value"


if cases and cases[-1] == "":
    cases.pop()
total = len(cases)
diffs = defaultdict(list)
for i, c in enumerate(cases):
    p, q = P[i], Q[i]
    if norm(p) != norm(q):
        diffs[cls(p, q)].append((c, p, q))
n = sum(len(v) for v in diffs.values())
print(f"  {name}: {total - n}/{total} agree ({pn} vs {rn})")
for k, v in diffs.items():
    print(f"    {len(v)} x {k}")
    for c, p, q in v[:show]:
        print(f"      in={show_input(c)}")
        print(f"         {pn}={p[:100]}  {rn}={q[:100]}")
sys.exit(1 if n else 0)
