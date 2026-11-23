#!/usr/bin/env python3
"""Three-way RRULE differential: Pion vs python-dateutil vs Rust rrule 0.14.0.

usage: compare.py RULES PION DATEUTIL RUST [--examples N] [--json OUT]

Classes per rule:
  agree            all three byte-identical
  consensus_diff   dateutil == rust, pion differs (strongest evidence of a Pion bug)
  pion_err_only    pion ERR while both references expand  (over-strict validation)
  pion_ok_only     pion expands while both references reject (missing validation)
  ref_split        dateutil != rust (references disagree; reported, not counted against Pion)
"""
import json
import sys
from collections import Counter, defaultdict


def load(p):
    with open(p) as f:
        return [l.rstrip("\n") for l in f if l.strip()]


def first_diff(a, b):
    sa = a.split(":", 1)[1].split(",") if ":" in a else []
    sb = b.split(":", 1)[1].split(",") if ":" in b else []
    for i in range(max(len(sa), len(sb))):
        x = sa[i] if i < len(sa) else "<none>"
        y = sb[i] if i < len(sb) else "<none>"
        if x != y:
            return i, x, y
    return None


def root_cause(rule, pion, ref):
    """Heuristic root-cause bucket for a consensus_diff (see REPORT.md)."""
    r = rule.split("|")[1]
    keys = dict(kv.split("=", 1) for kv in r.split(";") if "=" in kv)
    f = keys.get("FREQ")
    byday = keys.get("BYDAY", "")
    has_ord = any(c.isdigit() for c in byday)
    pn = int(pion.split(" ")[1].split(":")[0]) if pion.startswith("OK") else -1
    rn = int(ref.split(" ")[1].split(":")[0]) if ref.startswith("OK") else -1
    if f == "YEARLY" and "BYMONTHDAY" in keys and "BYMONTH" not in keys and "BYWEEKNO" not in keys and "BYYEARDAY" not in keys:
        return "RC1_yearly_bymonthday_not_expanded"
    if f in ("MONTHLY", "YEARLY") and has_ord and ("BYMONTHDAY" in keys or "BYYEARDAY" in keys):
        return "RC2_byday_ordinal_dropped_when_filtering"
    if f in ("SECONDLY", "MINUTELY") and pn < rn:
        return "RC3_subdaily_premature_exhaustion"
    if f == "YEARLY" and "BYWEEKNO" in keys:
        return "RC4_byweekno_week_year_vs_calendar_year"
    if f == "WEEKLY" and "BYSETPOS" in keys:
        return "RC5_weekly_bysetpos_partial_first_week(dateutil-quirk)"
    return "RC9_other"


def main():
    args = sys.argv[1:]
    nex = 3
    jout = None
    if "--examples" in args:
        i = args.index("--examples"); nex = int(args[i + 1]); del args[i:i + 2]
    if "--json" in args:
        i = args.index("--json"); jout = args[i + 1]; del args[i:i + 2]
    rules, pion, du, rs = (load(p) for p in args[:4])
    assert len(rules) == len(pion) == len(du) == len(rs), (len(rules), len(pion), len(du), len(rs))
    cls = Counter()
    bycat = defaultdict(Counter)
    ex = defaultdict(list)
    rc = Counter()
    for r, p, d, s in zip(rules, pion, du, rs):
        cat = r.split("|")[3] if r.count("|") >= 3 else "?"
        if p == d == s:
            c = "agree"
        elif d == s:
            if p == "ERR":
                c = "pion_err_only"
            elif d == "ERR":
                c = "pion_ok_only"
            else:
                c = "consensus_diff"
        else:
            c = "ref_split"
        cls[c] += 1
        if c == "consensus_diff":
            rc[root_cause(r, p, d)] += 1
        bycat[cat][c] += 1
        if c != "agree" and len(ex[(cat, c)]) < nex:
            item = {"rule": r, "pion": p[:200], "dateutil": d[:200], "rust": s[:200]}
            if c == "consensus_diff":
                item["first_diff"] = first_diff(p, d)
            ex[(cat, c)].append(item)
    total = len(rules)
    print("total=%d" % total)
    for k in ["agree", "consensus_diff", "pion_err_only", "pion_ok_only", "ref_split"]:
        print("%-16s %5d  (%.1f%%)" % (k, cls[k], 100.0 * cls[k] / total))
    print()
    print("consensus_diff root causes:")
    for k, v in sorted(rc.items()):
        print("  %-56s %5d" % (k, v))
    print()
    print("%-28s %6s %6s %6s %6s %6s" % ("category", "agree", "cdiff", "perr", "pok", "split"))
    for cat in sorted(bycat):
        b = bycat[cat]
        print("%-28s %6d %6d %6d %6d %6d" % (cat, b["agree"], b["consensus_diff"], b["pion_err_only"], b["pion_ok_only"], b["ref_split"]))
    print()
    for (cat, c), items in sorted(ex.items()):
        if c == "ref_split":
            continue
        print("## %s / %s" % (cat, c))
        for it in items:
            print("  rule    :", it["rule"])
            if "first_diff" in it and it["first_diff"]:
                i, x, y = it["first_diff"]
                print("  first diff @%d: pion=%s ref=%s" % (i, x, y))
            print("  pion    :", it["pion"][:160])
            print("  dateutil:", it["dateutil"][:160])
    if jout:
        with open(jout, "w") as f:
            json.dump({"total": total, "classes": cls, "by_category": bycat, "root_causes": rc,
                       "examples": {"%s/%s" % k: v for k, v in ex.items()}}, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
