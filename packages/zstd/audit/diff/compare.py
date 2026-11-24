#!/usr/bin/env python3
"""RT-zstd differential comparison. usage: compare.py <corpus_dir> <pion_results_dir> <oracle_results_dir> <group>

Inputs: <corpus>/<group>.json (index from gen.py), <pion>/pion_<group>.txt (one `OK <len> <fnv>` / `ERR <variant>`
line per record, default limits), <pion>/pion_<group>_lim.txt (`<name>\t<line>` for records with custom limits),
<oracle>/oracle_<group>.txt (`<ruzstd>\t<libzstd>` per record).

Gates (exit 1 = P0):
  valid    every record decodes to its raw input byte for byte (or fails where the index says `err`)
  crafted  Pion matches the RFC expectation (`want`) and, for `ok`, the expected content; the model must agree too
  fuzz     Pion == the independent model (OK/ERR and content) on every input, Pion never returns OK with content
           different from libzstd, and every Pion-vs-libzstd OK/ERR difference falls into a class listed below
Lines `FINDING <id> <name>` name the REPORT.md finding a divergence belongs to.
"""
import json
import os
import sys

corpus, pres, ores, group = sys.argv[1:5]


def lines(p):
    if not os.path.exists(p):
        return []
    return [l.rstrip("\n") for l in open(p)]


idx = [json.loads(l) for l in open(os.path.join(corpus, group + ".json"))]
pion = lines(os.path.join(pres, "pion_%s.txt" % group))
lim = {}
for l in lines(os.path.join(pres, "pion_%s_lim.txt" % group)):
    k, v = l.split("\t", 1)
    lim[k] = v
orc = lines(os.path.join(ores, "oracle_%s.txt" % group))
if len(pion) != len(idx) or (orc and len(orc) != len(idx)):
    print("  RECORD COUNT MISMATCH: index %d, pion %d, oracle %d" % (len(idx), len(pion), len(orc)))
    sys.exit(1)

p0 = 0


def ok_of(s):
    return s.startswith("OK")


def exp_line(r):
    return "OK %d %s" % (r["len"], r["fnv"]) if "fnv" in r else None


def short(s):
    return s if len(s) < 60 else s[:57] + "..."


# libzstd / ruzstd result classes Pion may differ from (all documented in REPORT.md)
def explain(r, p, z):
    """Why Pion (p) and libzstd (z) disagree on OK/ERR for record r, or None when unexplained. Every class is an
    INFO item of REPORT.md; Pion must agree with the independent RFC model in all of them."""
    m = r.get("model", "")
    if p != m and not (ok_of(p) and ok_of(m)):
        return None
    if not ok_of(p) and ok_of(z):
        kind = p.split()[1]
        if kind == "LimitExceeded":
            return "I-1 default ZstdLimits stricter than libzstd (8 MiB window vs 128 MiB, 64 MiB output, 1024 frames)"
        if kind == "InvalidOffset":
            return "I-2 offset > Window_Size rejected (RFC 8878 3.1.1.1.2); libzstd and ruzstd do not check"
        if kind == "InvalidBitstream":
            return "I-3 Huffman / FSE stream not exactly consumed or missing its 1-bit; libzstd 1.5.7 fast decoder tolerates it"
        if kind == "UnexpectedEof" and "size0" in r["name"]:
            return "I-3 Compressed_Block of size 0; libzstd treats it as empty"
        return None
    if ok_of(p) and not ok_of(z):
        if "Literals" in z:
            return "I-4 4-stream literals with Regenerated_Size < 6 accepted (RFC allows); libzstd requires >= 6"
        return None
    return None


if group == "valid":
    good = bad = 0
    ostats = {"ruzstd": [0, 0], "libzstd": [0, 0]}
    notes = {}
    for i, r in enumerate(idx):
        p = lim.get(r["name"], pion[i]) if r.get("limits") else pion[i]
        want = exp_line(r) if r["want"] == "ok" and not (r.get("limits") is None and "default-limits" in r["name"]) else None
        if r["want"] == "ok":
            fine = p == exp_line(r)
        else:
            fine = not ok_of(p)
        if fine:
            good += 1
        else:
            bad += 1
            p0 += 1
            print("  FAIL %-60s pion=%s want=%s" % (r["name"][:60], short(p), r["want"]))
        if "model" in r and r["want"] == "ok" and not r.get("limits") and r["model"] != exp_line(r):
            print("  MODEL %-58s model=%s" % (r["name"][:58], short(r["model"])))
            p0 += 1
        if orc:
            ru, lz = orc[i].split("\t")
            for who, v in (("ruzstd", ru), ("libzstd", lz)):
                if r["want"] == "ok" and v == exp_line(r):
                    ostats[who][0] += 1
                else:
                    ostats[who][1] += 1
                    notes.setdefault(who, []).append("%s: %s" % (r["name"], short(v)))
    print("  valid: Pion %d/%d byte-exact (%d with raised limits)" % (good, len(idx),
                                                                      sum(1 for r in idx if r.get("limits"))))
    for who in ostats:
        print("  %s: %d/%d byte-exact under its own defaults" % (who, ostats[who][0], len(idx)))
        for n in notes.get(who, [])[:6]:
            print("    %s" % n)
    feats = {}
    for r in idx:
        for f in r.get("feat", []):
            feats[f] = feats.get(f, 0) + 1
    print("  format features exercised (model-decoded records): " +
          ", ".join("%s %d" % (k, v) for k, v in sorted(feats.items())))

elif group == "crafted":
    n = {"ok": 0, "err": 0, "info": 0}
    agree = {"ruzstd": 0, "libzstd": 0}
    tab = []
    for i, r in enumerate(idx):
        p = lim.get(r["name"], pion[i]) if r.get("limits") else pion[i]
        ru, lz = orc[i].split("\t") if orc else ("-", "-")
        w = r["want"]
        m = r["model"]
        status = "PASS"
        if w == "ok":
            n["ok"] += 1
            if p != exp_line(r):
                status = "FAIL"
            if m != exp_line(r):
                status = "MODEL-BUG"
        elif w == "err":
            n["err"] += 1
            if ok_of(p):
                status = "FAIL"
            if ok_of(m):
                status = "MODEL-BUG"
        else:
            n["info"] += 1
            status = "INFO" if (ok_of(p) == ok_of(m) and (not ok_of(p) or p == m)) else "FAIL"
        if status != "PASS" and status != "INFO":
            p0 += 1
        if not r.get("limits"):
            for who, v in (("ruzstd", ru), ("libzstd", lz)):
                if w is None or (w == "ok" and v == exp_line(r)) or (w == "err" and not ok_of(v)):
                    agree[who] += 1
        tab.append((status, r["name"], w, p, m, ru, lz))
    for st, name, w, p, m, ru, lz in tab:
        show = st != "PASS" or (w is not None and not tab[0] is None and (
            (w == "ok" and not (ok_of(lz) and ok_of(ru))) or (w == "err" and (ok_of(lz) or ok_of(ru)))))
        if st == "INFO" or show:
            print("  %-9s %-44s want=%-4s pion=%-26s model=%-26s ruzstd=%-22s libzstd=%s" % (
                st, name[:44], w or "-", short(p)[:26], short(m)[:26], short(ru)[:22], short(lz)[:40]))
    nl = sum(1 for r in idx if not r.get("limits"))
    print("  crafted: %d cases (%d must decode, %d must fail, %d compared only): Pion %d/%d as the RFC requires" % (
        len(idx), n["ok"], n["err"], n["info"], sum(1 for t in tab if t[0] in ("PASS", "INFO")), len(idx)))
    print("  oracles on the %d default-limit cases: ruzstd %d agree, libzstd %d agree (differences listed above)" % (
        nl, agree["ruzstd"], agree["libzstd"]))

else:
    cls = {}
    pm_bad = 0
    for i, r in enumerate(idx):
        p = pion[i]
        m = r["model"]
        ru, lz = orc[i].split("\t") if orc else ("-", "-")
        if ok_of(p) != ok_of(m) or (ok_of(p) and p != m):
            pm_bad += 1
            p0 += 1
            if pm_bad <= 10:
                print("  PION!=MODEL %s pion=%s model=%s libzstd=%s" % (r["name"], p, m, short(lz)))
        if ok_of(p) and ok_of(lz) and p != lz:
            p0 += 1
            print("  CONTENT!=LIBZSTD %s pion=%s libzstd=%s" % (r["name"], p, lz))
        if ok_of(p) != ok_of(lz):
            why = explain(r, p, lz) or "UNEXPLAINED pion=%s libzstd=%s" % (p.split()[0] + (
                " " + p.split()[1] if not ok_of(p) else ""), "OK" if ok_of(lz) else "ERR")
            if why.startswith("UNEXPLAINED"):
                p0 += 1
            c = cls.setdefault(why, [])
            c.append(r["name"])
        if ok_of(p) and not ok_of(ru) and ok_of(lz):
            cls.setdefault("ruzstd-only failure (ruzstd %s)" % ru.split()[1][:40] if len(ru.split()) > 1 else "ruzstd", []).append(r["name"])
    n_ok = sum(1 for x in pion if ok_of(x))
    print("  fuzz: %d inputs, Pion OK %d / ERR %d; Pion == independent model on %d/%d" % (
        len(idx), n_ok, len(idx) - n_ok, len(idx) - pm_bad, len(idx)))
    agree = sum(1 for i in range(len(idx)) if orc and ok_of(pion[i]) == ok_of(orc[i].split("\t")[1]))
    print("  Pion == libzstd (OK/ERR and content) on %d/%d; differences by class:" % (agree, len(idx)))
    for k, v in sorted(cls.items(), key=lambda kv: -len(kv[1])):
        print("    %5d  %s  (e.g. %s)" % (len(v), k, ", ".join(v[:3])))
print("P0 %d" % p0)
sys.exit(1 if p0 else 0)
