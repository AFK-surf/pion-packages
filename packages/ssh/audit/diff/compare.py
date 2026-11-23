#!/usr/bin/env python3
"""Classify Pion vs Go x/crypto/ssh differential results.

usage: compare.py <corpus.tsv> <pion.txt> <go.txt>

Every corpus line has one result line per oracle ("<label>\t<result>"). Results are compared exactly;
disagreements are grouped by (kind, pion verdict, go verdict) with a few examples each. Disagreements
where Go accepts an algorithm Pion does not implement (nistp384/521, sk-*, ssh-dss, certificates in
known_hosts) are counted as `feature-gap`, not as parser bugs.
"""
import collections
import sys

corpus_path, pion_path, go_path = sys.argv[1:4]


def load(p):
    out = {}
    order = []
    with open(p, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            k, _, v = line.partition("\t")
            out[k] = v
            order.append(k)
    return out, order


kinds = {}
inputs = {}
with open(corpus_path) as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3:
            kinds[parts[0]] = parts[1]
            inputs[parts[0]] = parts[2] + ("\t" + parts[3] if len(parts) > 3 else "")

pion, order = load(pion_path)
go, _ = load(go_path)
missing = [k for k in kinds if k not in pion or k not in go]
if missing:
    print("MISSING results for %d vectors (first: %s)" % (len(missing), missing[:3]))

UNSUPPORTED = ("nistp384", "nistp521", "sk-", "ssh-dss", "-cert-v01@openssh.com")


def verdict(v):
    return v.split(" ", 1)[0]


same = 0
groups = collections.defaultdict(list)
by_kind = collections.Counter()
for k in order:
    kind = kinds.get(k, "?")
    by_kind[kind] += 1
    p, g = pion.get(k, "<none>"), go.get(k, "<none>")
    if p == g:
        same += 1
        continue
    pv, gv = verdict(p), verdict(g)
    if pv == gv == "REJECT":
        same += 1  # both refuse; only the error text differs
        continue
    tag = "parser"
    if gv == "OK" and pv in ("ERR", "REJECT") and any(u in g for u in UNSUPPORTED) and kind != "certchk":
        tag = "feature-gap"
    if kind == "kh" and gv == "OK" and pv == "OK" and p.split()[2:] == g.split()[2:]:
        tag = "pattern-count"  # Pion drops empty comma-separated patterns; Go keeps them
    groups[(tag, kind, pv, gv)].append(k)

total = len(order)
print("vectors=%d  identical=%d  differing=%d  (%s)" % (
    total, same, total - same, ", ".join("%s=%d" % kv for kv in sorted(by_kind.items()))))
for (tag, kind, pv, gv), ks in sorted(groups.items(), key=lambda x: (x[0][0], -len(x[1]))):
    t = sum(k.startswith("t_") for k in ks)
    print("  [%-13s] %-7s pion=%-6s go=%-6s : %5d  (targeted %d)" % (tag, kind, pv, gv, len(ks), t))
    shown = [k for k in ks if k.startswith("t_")][:4] + [k for k in ks if k.startswith("m_")][:2]
    for k in shown:
        print("      %-34s pion: %s" % (k, pion.get(k, "")[:90]))
        print("      %-34s go  : %s" % ("", go.get(k, "")[:90]))
