#!/usr/bin/env python3
"""Compare Pion probe output against croner / robfig / Quartz oracle outputs.

usage: compare.py <corpus.txt> <pion.out> <oracle_name>=<oracle.out> ...

Each output has one line per corpus line: "ERR" | "SKIP" | "OK m=<0|1|-> N <t...> [P <t...>]".
Mismatches are bucketed:
  accept/reject      one side parses, the other rejects
  matches()          m= differs
  next-chain         first differing next_after occurrence
  oracle-cap         oracle returned no occurrence but Pion's is beyond the oracle's documented
                     search horizon (robfig: start+5y, croner: year 5000) -- informational only
Prints counts + up to --show samples per bucket.
"""
import collections
import datetime
import sys


def iso(v):
    if v == "-":
        return "-"
    return (datetime.datetime(1970, 1, 1) + datetime.timedelta(seconds=int(v))).strftime("%Y-%m-%dT%H:%M:%S")


def parse(line):
    line = line.rstrip("\n")
    if line in ("ERR", "SKIP", "BADSTART", "BADLINE", "HANG"):
        return line, None, []
    toks = line.split()
    m = toks[1][2:]
    nxt = []
    i = 3
    while i < len(toks) and toks[i] != "P":
        nxt.append(toks[i])
        i += 1
    return "OK", m, nxt


def main():
    corpus = [l.rstrip("\n") for l in open(sys.argv[1]) if l.strip()]
    pion = [parse(l) for l in open(sys.argv[2])]
    show = 8
    rc = 0
    for spec in sys.argv[3:]:
        name, path = spec.split("=", 1)
        orc = [parse(l) for l in open(path)]
        assert len(orc) == len(pion) == len(corpus), (name, len(orc), len(pion), len(corpus))
        buckets = collections.defaultdict(list)
        compared = 0
        for c, p, o in zip(corpus, pion, orc):
            if o[0] == "SKIP":
                continue
            compared += 1
            f = c.split("\t")
            start = int(f[2])
            if p[0] != o[0]:
                buckets["accept/reject: pion=%s %s=%s" % (p[0], name, o[0])].append((c, "", ""))
                continue
            if p[0] != "OK":
                continue
            if o[1] != "-" and p[1] != o[1]:
                buckets["matches()"].append((c, "pion m=" + p[1], name + " m=" + o[1]))
            for k in range(min(len(p[2]), len(o[2]))):
                if p[2][k] != o[2][k]:
                    prev = start if k == 0 else int(p[2][k - 1])
                    pv = p[2][k]
                    horizon = {"robfig": 5 * 366 * 86400}.get(name)
                    if o[2][k] == "-" and pv != "-" and horizon and int(pv) - prev > horizon:
                        buckets["oracle-cap (informational)"].append((c, "pion=" + pv, name + "=-"))
                    else:
                        buckets["next-chain"].append((c, "pion[%d]=%s" % (k, iso(pv)), "%s[%d]=%s" % (name, k, iso(o[2][k]))))
                    break
        print("== pion vs %s: %d compared, %d mismatching" % (
            name, compared, sum(len(v) for k, v in buckets.items() if "informational" not in k)))
        for k, v in sorted(buckets.items()):
            print("  [%s] %d" % (k, len(v)))
            for c, a, b in v[:show]:
                cc = c.split("\t")
                print("      %-58s start=%s %s %s" % (cc[0] + " | " + cc[1], iso(cc[2]), a, b))
        if any("informational" not in k for k in buckets):
            rc = 1
    sys.exit(0)


if __name__ == "__main__":
    main()
