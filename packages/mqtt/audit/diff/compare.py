#!/usr/bin/env python3
"""Join labels.tsv with Pion / Go paho / Rust rumqttc verdict files.

usage: compare.py <labels.tsv> <pion.txt> <go.txt> <rust.txt> <out_dir>

Prints a per-family table and writes:
  out_dir/pion_vs_spec.tsv     vectors where Pion contradicts an accept/reject/incomplete label
  out_dir/pion_strict.tsv      vectors labelled `strict` that Pion accepts
  out_dir/three_way.tsv        vectors where the three decoders disagree (verdict or type/used/pid)
"""

import collections
import os
import sys


def load(path):
    out = {}
    with open(path) as f:
        for line in f:
            parts = line.rstrip("\n").split(" ", 5)
            if len(parts) < 5 or not parts[0].isdigit():
                continue
            out[int(parts[0])] = (parts[1], parts[2], parts[3], parts[4], parts[5] if len(parts) > 5 else "")
    return out


def main():
    labels_path, pion_p, go_p, rust_p, out_dir = sys.argv[1:6]
    os.makedirs(out_dir, exist_ok=True)
    pion, go, rust = load(pion_p), load(go_p), load(rust_p)
    rows = []
    with open(labels_path) as f:
        next(f)
        for line in f:
            i, ver, fam, exp, note, hx = line.rstrip("\n").split("\t")
            rows.append((int(i), int(ver), fam, exp, note, hx))

    fam_stats = collections.OrderedDict()
    spec_bad, strict_acc, three = [], [], []
    tot = collections.Counter()

    def conform(verdict, exp):
        if exp == "accept":
            return verdict == "ok"
        if exp == "reject":
            return verdict == "reject"
        if exp == "incomplete":
            return verdict == "incomplete"
        return True

    for i, ver, fam, exp, note, hx in rows:
        p, g, r = pion.get(i), go.get(i), rust.get(i)
        st = fam_stats.setdefault(fam, collections.Counter())
        st["n"] += 1
        for name, res in (("pion", p), ("go", g), ("rust", r)):
            if res is None or res[0] == "na":
                continue
            st[name + "_n"] += 1
            tot[name + "_n"] += 1
            if res[0] == "panic":
                st[name + "_panic"] += 1
                tot[name + "_panic"] += 1
            if exp in ("accept", "reject", "incomplete"):
                st[name + "_lab"] += 1
                tot[name + "_lab"] += 1
                if not conform(res[0], exp):
                    st[name + "_bad"] += 1
                    tot[name + "_bad"] += 1
            if exp == "strict" and res[0] == "ok":
                st[name + "_strict_ok"] += 1
                tot[name + "_strict_ok"] += 1
        if p and exp in ("accept", "reject", "incomplete") and not conform(p[0], exp):
            spec_bad.append((i, ver, fam, exp, note, p, hx))
        if p and exp == "strict" and p[0] == "ok":
            strict_acc.append((i, ver, fam, exp, note, p, hx))
        live = [x for x in (p, g, r) if x and x[0] != "na"]
        if len({x[:4] for x in live}) > 1:
            three.append((i, ver, fam, exp, note, p, g, r, hx))

    def cell(st, name):
        n = st[name + "_n"]
        if not n:
            return "n/a"
        lab = st[name + "_lab"]
        bad = st[name + "_bad"]
        s = "%d/%d" % (lab - bad, lab) if lab else "-"
        extra = []
        if st[name + "_strict_ok"]:
            extra.append("strict-acc %d" % st[name + "_strict_ok"])
        if st[name + "_panic"]:
            extra.append("PANIC %d" % st[name + "_panic"])
        return s + (" (" + ", ".join(extra) + ")" if extra else "")

    print("| family | vectors | Pion spec-conform | Go paho (v5) | Rust rumqttc |")
    print("| --- | ---: | --- | --- | --- |")
    for fam, st in fam_stats.items():
        print("| %s | %d | %s | %s | %s |" % (fam, st["n"], cell(st, "pion"), cell(st, "go"), cell(st, "rust")))
    print("| **total** | %d | %s | %s | %s |" % (len(rows), cell(tot, "pion"), cell(tot, "go"), cell(tot, "rust")))
    print()
    print("pion_spec_violations=%d pion_strict_accepts=%d three_way_disagreements=%d" %
          (len(spec_bad), len(strict_acc), len(three)))

    with open(os.path.join(out_dir, "pion_vs_spec.tsv"), "w") as f:
        f.write("id\tver\tfamily\texpect\tnote\tpion\thex\n")
        for i, ver, fam, exp, note, p, hx in spec_bad:
            f.write("%d\t%d\t%s\t%s\t%s\t%s\t%s\n" % (i, ver, fam, exp, note, " ".join(p).strip(), hx))
    with open(os.path.join(out_dir, "pion_strict.tsv"), "w") as f:
        f.write("id\tver\tfamily\texpect\tnote\tpion\thex\n")
        for i, ver, fam, exp, note, p, hx in strict_acc:
            f.write("%d\t%d\t%s\t%s\t%s\t%s\t%s\n" % (i, ver, fam, exp, note, " ".join(p).strip(), hx))
    with open(os.path.join(out_dir, "three_way.tsv"), "w") as f:
        f.write("id\tver\tfamily\texpect\tnote\tpion\tgo\trust\thex\n")
        for i, ver, fam, exp, note, p, g, r, hx in three:
            fmt = lambda x: " ".join(x).strip() if x else "-"
            f.write("%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" % (i, ver, fam, exp, note, fmt(p), fmt(g), fmt(r), hx))


if __name__ == "__main__":
    main()
