#!/usr/bin/env python3
"""Root-cause triage of Pion-vs-oracle next-chain mismatches.

usage: triage.py <probe_bin> <corpus.txt> <pion.out> croner|robfig <oracle.out>

For every mismatching case, rewrite the expression so that Pion is asked the oracle's documented
semantics, re-run Pion, and check that the mismatch disappears.  A mismatch that survives every
rewrite is UNEXPLAINED and printed (these are the ones that would be real Pion bugs).
  croner  C1: DOW item "a/s" -> croner/Vixie expand to a..7 step s (7 = Sunday);
              Pion expands to a..6. Rewrite "a/s" -> "a-7/s".
          C3: croner textually replaces "-sun" by "-7" ("SUN-SUN", "0-SUN" = every day);
              Pion reads SUN as 0 ("0-SUN" = Sunday only). Rewrite "-SUN" -> "-7".
  robfig  C2: a DOM/DOW field "*/1" (or a list containing "*", "*/1", "?") sets robfig's starBit
              (Vixie DOM_STAR/DOW_STAR: field *starts* with '*') -> AND semantics.
              Pion/croner only treat the exact field "*"/"?" as star. Rewrite field -> "*".
"""
import re
import subprocess
import sys
import tempfile

from compare import parse

ITEM = re.compile(r"^([A-Za-z]{3}|\d+)/(\d+)$")


def fields(expr):
    return expr.split()


def rewrite_croner(opts, expr):
    f = fields(expr)
    i = 4 if len(f) == 5 else 5
    items = []
    for it in f[i].split(","):
        m = ITEM.match(it)
        if m:
            it = "%s-7/%s" % (m.group(1), m.group(2))
        # C3: croner rewrites the text "-sun" to "-7" before parsing ("SUN-SUN" == 0-7 == every day)
        it = re.sub(r"-sun", "-7", it, flags=re.I)
        items.append(it)
    f[i] = ",".join(items)
    return " ".join(f)


def rewrite_robfig(opts, expr):
    f = fields(expr)
    off = 0 if len(f) == 5 else 1
    for i in (2 + off, 4 + off):
        its = f[i].split(",")
        if any(x in ("*", "*/1", "?") for x in its):
            f[i] = "*"
    return " ".join(f)


def main():
    probe, corpus, pion_out, oracle, oracle_out = sys.argv[1:6]
    cases = [l.rstrip("\n") for l in open(corpus) if l.strip()]
    pion = [parse(l) for l in open(pion_out)]
    orc = [parse(l) for l in open(oracle_out)]
    mism = []
    for c, p, o in zip(cases, pion, orc):
        if o[0] in ("SKIP", "HANG") or p[0] != "OK" or o[0] != "OK":
            continue
        n = min(len(p[2]), len(o[2]))
        if p[2][:n] != o[2][:n] or (o[1] != "-" and p[1] != o[1]):
            mism.append((c, o))
    rw = rewrite_croner if oracle == "croner" else rewrite_robfig
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as t:
        for c, _ in mism:
            f = c.split("\t")
            f[1] = rw(f[0], f[1])
            t.write("\t".join(f) + "\n")
        path = t.name
    out = subprocess.run([probe, "diff", path], capture_output=True, text=True).stdout.splitlines()
    unexplained = []
    horizon = 5 * 366 * 86400
    for (c, o), line in zip(mism, out):
        p = parse(line)
        n = min(len(p[2]), len(o[2]))
        ok = p[2][:n] == o[2][:n] and (o[1] == "-" or p[1] == o[1])
        if not ok and oracle == "robfig" and p[2][:n] != o[2][:n]:
            # robfig gives up after start+5y; accept "-" when Pion's answer is beyond that.
            k = next(i for i in range(n) if p[2][i] != o[2][i])
            prev = int(c.split("\t")[2]) if k == 0 else int(p[2][k - 1])
            ok = o[2][k] == "-" and p[2][k] != "-" and int(p[2][k]) - prev > horizon
        if not ok:
            unexplained.append((c, p[2], o[2]))
    rule = "C1/C3 (DOW a/s upper bound 7, -SUN=7)" if oracle == "croner" else "C2 (*/1 or star-in-list => starBit)"
    print("triage pion vs %s: %d mismatches, %d explained by %s, %d UNEXPLAINED" % (
        oracle, len(mism), len(mism) - len(unexplained), rule, len(unexplained)))
    for c, p, o in unexplained[:20]:
        print("   UNEXPLAINED %s\n      pion=%s\n      %s=%s" % (c.replace("\t", " | "), p, oracle, o))


if __name__ == "__main__":
    main()
