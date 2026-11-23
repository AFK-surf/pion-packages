#!/usr/bin/env python3
"""Flatten the official JSON-Schema-Test-Suite into differential cases (JSONL).

usage: gen_suite.py <suite_root> <out_dir>
Writes <out_dir>/suite_<group>.jsonl for groups:
  core2020   tests/draft2020-12/*.json          (refRemote.json excluded: needs HTTP remotes)
  core7      tests/draft7/*.json                (refRemote.json excluded)
  opt2020    tests/draft2020-12/optional/*.json (non-format optional behaviour)
  opt7       tests/draft7/optional/*.json
  fmt2020    tests/draft2020-12/optional/format/*.json  (format assertion ON)
  fmt7       tests/draft7/optional/format/*.json         (format assertion ON)
Every case carries the suite's expected verdict in "expect".
"""
import json
import os
import sys

root, out_dir = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)

GROUPS = [
    ("core2020", "draft2020-12", "2020-12", False, False),
    ("core7", "draft7", "7", False, False),
    ("opt2020", "draft2020-12/optional", "2020-12", False, False),
    ("opt7", "draft7/optional", "7", False, False),
    ("fmt2020", "draft2020-12/optional/format", "2020-12", True, True),
    ("fmt7", "draft7/optional/format", "7", True, True),
]

for name, sub, draft, fmt, _ in GROUPS:
    d = os.path.join(root, "tests", sub)
    n = 0
    with open(os.path.join(out_dir, f"suite_{name}.jsonl"), "w") as out:
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".json") or fn == "refRemote.json":
                continue
            with open(os.path.join(d, fn)) as f:
                groups = json.load(f)
            for gi, g in enumerate(groups):
                for ti, t in enumerate(g["tests"]):
                    case = {
                        "id": f"{name}/{fn}#{gi}.{ti}",
                        "draft": draft,
                        "fmt": fmt,
                        "schema": g["schema"],
                        "instance": t["data"],
                        "expect": "V" if t["valid"] else "I",
                        "desc": f'{g["description"]} :: {t["description"]}',
                    }
                    out.write(json.dumps(case, ensure_ascii=False) + "\n")
                    n += 1
    print(f"  {name}: {n} cases")
