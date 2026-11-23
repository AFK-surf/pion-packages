#!/usr/bin/env python3
"""Compare Pion driver vs Go kin-openapi oracle transcripts against the corpus' spec verdicts.

usage: run_diff.py cases.jsonl pion.tsv go.tsv [--quiet]
Per field (load / valid / each op) a disagreement is classified:
  PION-WRONG   Pion != spec verdict (`expect`), whatever Go says
  GO-WRONG     Pion == spec, Go != spec
  DIVERGE      no spec verdict (`expect` null or a `*` field) and Pion != Go
Prints one line per disagreeing case and a summary; exit 0 (findings are data, not tool errors).
"""
import json
import sys


def fields(line_rest):
    parts = line_rest.split("\t")
    while len(parts) < 3:
        parts.append("")
    load, valid, ops = parts[0], parts[1], parts[2]
    return [load, valid] + (ops.split("|") if ops else [])


def load_tsv(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line:
            continue
        cid, _, rest = line.partition("\t")
        out[cid] = rest
    return out


def main():
    cases_p, pion_p, go_p = sys.argv[1:4]
    quiet = "--quiet" in sys.argv
    cases = [json.loads(l) for l in open(cases_p, encoding="utf-8") if l.strip()]
    pion, go = load_tsv(pion_p), load_tsv(go_p)
    counts = {"PION-WRONG": 0, "GO-WRONG": 0, "DIVERGE": 0, "AGREE": 0}
    for c in cases:
        cid = c["id"]
        p = pion.get(cid, "MISSING")
        g = go.get(cid, "MISSING")
        pf, gf = fields(p), fields(g)
        ef = fields(c["expect"]) if c.get("expect") is not None else None
        n = max(len(pf), len(gf), len(ef) if ef else 0)
        tags = set()
        for i in range(n):
            pv = pf[i] if i < len(pf) else "∅"
            gv = gf[i] if i < len(gf) else "∅"
            ev = ef[i] if ef and i < len(ef) else "*"
            if ev.endswith("*"):  # prefix wildcard: `load=*`, `op:listUsers*`, `*`
                if not pv.startswith(ev[:-1]):
                    tags.add("PION-WRONG")
                elif ev == "*" and pv != gv:
                    tags.add("DIVERGE")
            else:
                if pv != ev:
                    tags.add("PION-WRONG")
                elif gv != ev:
                    tags.add("GO-WRONG")
        if not tags:
            counts["AGREE"] += 1
            continue
        tag = "PION-WRONG" if "PION-WRONG" in tags else ("DIVERGE" if "DIVERGE" in tags else "GO-WRONG")
        counts[tag] += 1
        if not quiet or tag == "PION-WRONG":
            print(f"{tag:10s} {cid}")
            print(f"    pion  : {p}")
            print(f"    go    : {g}")
            if ef:
                print(f"    expect: {c['expect']}")
            print(f"    why   : {c.get('why', '')}")
    print("SUMMARY " + " ".join(f"{k}={v}" for k, v in counts.items()) + f" total={len(cases)}")


if __name__ == "__main__":
    main()
