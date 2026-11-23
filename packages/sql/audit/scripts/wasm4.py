#!/usr/bin/env python3
"""Run every differential input of security.py / differential.py through the 4 build modes of the driver
(native release / native debug / wasm32 release / wasm32 debug) and require byte-identical stdout, 0 traps."""
import hashlib
import subprocess

import differential as d
from common import MODES, hexfile

SEC = [
    "SELECT - -1, '\n1; DROP TABLE secret; --'", "SELECT a FROM t WHERE b = - -1 OR a = 2",
    "SELECT 1 /* /* */; DROP TABLE secret; -- */", "SELECT $a$; DROP TABLE secret; SELECT $a$",
    "SELECT e'\\' FROM (SELECT 1 AS e); DROP TABLE secret; --'", "SELECT 1 AS [x; DROP TABLE secret; SELECT 2 AS y]",
    "WITH \"SECRET\" AS (SELECT 1 AS id) SELECT * FROM SECRET", "SELECT E'\\x41\\u0041\\101\\0'", "SELECT 'é名\U0001F600'",
]

runs = []
for dialect, corpus in (("postgres", d.PG + SEC), ("sqlite", d.SQLITE + SEC), ("generic", d.PG + d.SQLITE + SEC)):
    f = hexfile(corpus)
    runs += [(f"probe {dialect}", ["probe", dialect, f]), (f"split {dialect}", ["split", f])]
runs.append(("pexpr postgres", ["pexpr", "postgres", hexfile(d.PREC)]))

bad = 0
for name, args in runs:
    digests = {}
    for mode, cmd in MODES.items():
        r = subprocess.run(cmd + args, capture_output=True)
        digests[mode] = (r.returncode, hashlib.sha256(r.stdout).hexdigest()[:16], len(r.stdout))
    same = len({v for v in digests.values()}) == 1 and all(v[0] == 0 for v in digests.values())
    bad += not same
    print(f"  {'ok  ' if same else 'DIFF'} {name}: " + "; ".join(f"{m} rc={v[0]} sha={v[1]} {v[2]}B" for m, v in digests.items()))
print(f"  {len(runs) - bad}/{len(runs)} differential runs byte-identical across the 4 build modes")
