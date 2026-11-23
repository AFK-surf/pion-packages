"""Compare Pion (`dump` + `rt`) against the spec expectations in cases.py; show both oracles.

usage: compare.py <pion_dump> <pion_rt> <go_dump> <calcard_dump>
Exit 1 iff Pion disagrees with the spec expectation on any case (parse or roundtrip).
The oracles are informative: their agreement with the expectation is reported, never gating.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cases import ALL  # noqa: E402


def load(path):
    out = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            cid, _, rest = line.partition(" ")
            out[cid] = rest
    return out


def values_only(s):
    """Drop groups/params so typed-param oracles (calcard) can be compared on names + values."""
    if not s.startswith("OK "):
        return "ERR"
    body = s[3:]
    cards = re.findall(r"\{([^{}]*)\}", body)
    res = []
    for c in cards:
        props = []
        for p in c.split(" ") if c else []:
            head, _, val = p.partition("|")
            name = head.split(";")[0].split(".")[-1]
            props.append(name + "|" + val)
        res.append("{" + " ".join(sorted(props)) + "}")
    return "OK " + "".join(res)


def main():
    pion, rt, go, cc = (load(p) for p in sys.argv[1:5])
    fails = 0
    agree = {"go": 0, "calcard": 0}
    rows = []
    for cid, _raw, exp, note in ALL:
        got = pion.get(cid, "<missing>")
        got_rt = rt.get(cid, "<missing>")
        exp_rt = exp if exp.startswith("OK") else None
        bad_parse = got != exp
        bad_rt = (got_rt != exp) if exp_rt else (not got_rt.startswith("ERR"))
        ev = values_only(exp)
        o_go = values_only(go.get(cid, "ERR")) == ev
        o_cc = values_only(cc.get(cid, "ERR")) == ev
        agree["go"] += o_go
        agree["calcard"] += o_cc
        if bad_parse or bad_rt:
            fails += 1
            rows.append((cid, note, exp, got, got_rt, bad_parse, bad_rt, o_go, o_cc))
    n = len(ALL)
    print("cases=%d  pion_mismatch=%d  oracle agreement with spec: go-vcard %d/%d, calcard %d/%d"
          % (n, fails, agree["go"], n, agree["calcard"], n))
    for cid, note, exp, got, got_rt, bp, br, og, oc in rows:
        print("FAIL %s (%s)%s%s  [oracles agree with spec: go=%s calcard=%s]"
              % (cid, note, " parse" if bp else "", " roundtrip" if br else "", "y" if og else "n", "y" if oc else "n"))
        print("   expect: %s" % exp[:220])
        if bp:
            print("   pion  : %s" % got[:220])
        if br:
            print("   rt    : %s" % got_rt[:220])
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
