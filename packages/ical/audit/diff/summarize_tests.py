#!/usr/bin/env python3
"""Summarise `pionc test --json` for the audit: p*/control counts, or one package."""
import json
import sys

lines = [l for l in sys.stdin if l.startswith("{")]
d = json.loads(lines[-1])
if "--pkg" in sys.argv:
    pkg = sys.argv[sys.argv.index("--pkg") + 1]
    ts = [t for t in d["tests"] if t["pkg"] == pkg]
    print("%s: %d/%d passed" % (pkg, sum(t["ok"] for t in ts), len(ts)))
    sys.exit(0 if all(t["ok"] for t in ts) else 1)
ts = [t for t in d["tests"] if t["pkg"] == "ical_redteam_audit"]
deps = [t for t in d["tests"] if t["pkg"] != "ical_redteam_audit"]
bad = 0
for prefix in ("p0_", "p1_", "p2_", "control_"):
    g = [t for t in ts if t["name"].startswith(prefix)]
    fails = sum(not t["ok"] for t in g)
    print("%-9s %2d tests  FAIL=%2d  PASS=%2d" % (prefix, len(g), fails, len(g) - fails))
    for t in g:
        print("   %s %s" % ("FAIL" if not t["ok"] else "pass", t["name"]))
    if prefix == "control_" and fails:
        bad = 1
    if prefix != "control_" and fails != len(g):
        bad = 1  # a finding that no longer reproduces must be re-triaged
print("deps (time + ical): %d/%d passed" % (sum(t["ok"] for t in deps), len(deps)))
sys.exit(bad)
