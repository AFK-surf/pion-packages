#!/usr/bin/env python3
"""Cross-check every `expect(q, input, [want...])` in audit/redteam_test.pion against
Pion, gojq v0.12.17 and jq 1.7.x.

usage: check_expectations.py redteam_test.pion PION_RUNNER GOJQ_ORACLE [jq]

For p0_/p1_/p2_ tests every expectation must be met by gojq AND jq (the reference
behaviour) and missed by Pion (the evidence). For control_ tests all three must meet it.
Exit status 1 on any violated invariant.
"""
import json, re, subprocess, sys, tempfile

src = open(sys.argv[1]).read()
pion, gojq = sys.argv[2], sys.argv[3]
jq = sys.argv[4] if len(sys.argv) > 4 else None

LIT = r'"(?:[^"\\]|\\.)*"'
cases = []
for t in re.finditer(r'test "([^"]+)" \{(.*?)\n\}', src, re.S):
    name, body = t.group(1), t.group(2)
    for m in re.finditer(r'expect\(\s*(' + LIT + r')\s*,\s*(' + LIT + r')\s*,\s*\[((?:\s*' + LIT + r'\s*,?)*)\]\s*,?\s*\)', body, re.S):
        q, inp = json.loads(m.group(1)), json.loads(m.group(2))
        want = [json.loads(x) for x in re.findall(LIT, m.group(3))]
        cases.append((name, q, inp, want))

with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
    json.dump([[q, inp] for _, q, inp, _ in cases], f)
    path = f.name


def stream(cmd):
    out = subprocess.run(cmd + [path], capture_output=True).stdout.decode("utf-8", "replace").splitlines()
    return [json.loads(l) for l in out]


def norm(xs):
    try:
        return [json.loads(x) for x in xs]
    except Exception:
        return None


P, G = stream([pion]), stream([gojq, "run"])
bad = 0
for i, (name, q, inp, want) in enumerate(cases):
    w = norm(want)
    p_ok = "ok" in P[i] and P[i]["ok"] == want
    g_ok = "ok" in G[i] and norm(G[i]["ok"]) == w
    j_ok = None
    if jq:
        r = subprocess.run([jq, "-c", "-S", q], input=inp.encode(), capture_output=True)
        j_ok = r.returncode == 0 and norm([l for l in r.stdout.decode("utf-8", "replace").split("\n") if l]) == w
    evidence = name.startswith(("p0_", "p1_", "p2_"))
    ok = (not p_ok and g_ok and j_ok is not False) if evidence else (p_ok and g_ok and j_ok is not False)
    bad += not ok
    flag = "ok " if ok else "BAD"
    print(f"{flag} {name:62s} pion={'Y' if p_ok else 'n'} gojq={'Y' if g_ok else 'n'} jq={'-' if j_ok is None else ('Y' if j_ok else 'n')}  {q[:70]!r}")
print(f"{len(cases)} expectations, {bad} violating the evidence/control invariant")
sys.exit(1 if bad else 0)
