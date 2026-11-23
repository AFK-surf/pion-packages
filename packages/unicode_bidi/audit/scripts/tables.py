"""Table audit over all 0..=0x10FFFF scalar values:
  * Bidi_Class: Pion vs Rust `unicode-bidi =0.3.18` vs Unicode 16.0.0 DerivedBidiClass.txt
    (explicit entries + @missing defaults);
  * BidiBrackets (BD16, incl. canonical equivalents U+2329/232A <-> U+3008/3009): Pion vs Rust vs UCD;
  * BidiMirroring (L4): Pion vs Rust `unicode-bidi-mirroring =0.4.0` vs UCD BidiMirroring.txt.
Writes $AUDIT_TMP/ucd_diff.json (code points whose Pion class differs from UCD 16).
Usage: tables.py [--json out.json]"""
import json, os, re, subprocess, sys, unicodedata
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, UCD, PION, RUST, CLASSES

LONG = {"Left_To_Right": "L", "Right_To_Left": "R", "Arabic_Letter": "AL", "European_Terminator": "ET",
        "Boundary_Neutral": "BN"}


def cp_of(i):
    return i if i < 0xD800 else i + 0x800


def rng(s):
    a = s.split("..")
    return int(a[0], 16), int(a[-1], 16)


def ucd_classes():
    cls = bytearray(b"J" * 0x110000)
    lines = open(os.path.join(UCD, "DerivedBidiClass.txt")).read().splitlines()
    for l in lines:
        m = re.match(r"# @missing: ([0-9A-F.]+); (\w+)", l)
        if m:
            lo, hi = rng(m.group(1))
            v = 65 + CLASSES.index(LONG.get(m.group(2), m.group(2)))
            cls[lo:hi + 1] = bytes([v]) * (hi - lo + 1)
    for l in lines:
        l = l.split("#")[0].strip()
        if l:
            r, v = [x.strip() for x in l.split(";")]
            lo, hi = rng(r)
            cls[lo:hi + 1] = bytes([65 + CLASSES.index(v)]) * (hi - lo + 1)
    return bytes(cls[:0xD800] + cls[0xE000:])


def main():
    empty = os.path.join(TMP, "empty")
    open(empty, "w").close()
    for impl, exe in (("pion", PION), ("rust", RUST)):
        for mode in ("cls", "tab"):
            subprocess.run([exe, mode, empty, os.path.join(TMP, f"{impl}.{mode}")], check=True)
    p = open(os.path.join(TMP, "pion.cls"), "rb").read()
    r = open(os.path.join(TMP, "rust.cls"), "rb").read()
    u = ucd_classes()
    rep = {}
    rep["class_pion_vs_rust_mismatch"] = sum(1 for a, b in zip(p, r) if a != b)
    diff = [i for i in range(len(p)) if p[i] != u[i]]
    runs = []
    for i in diff:
        c = cp_of(i)
        if runs and runs[-1][1] == c - 1 and runs[-1][2] == (p[i], u[i]):
            runs[-1][1] = c
        else:
            runs.append([c, c, (p[i], u[i])])
    rep["class_pion_vs_ucd16_mismatch_codepoints"] = len(diff)
    rep["class_pion_vs_ucd16_ranges"] = [f"U+{a:04X}..U+{b:04X} pion={CLASSES[x - 65]} ucd16={CLASSES[y - 65]}"
                                         for a, b, (x, y) in runs]
    json.dump([cp_of(i) for i in diff], open(os.path.join(TMP, "ucd_diff.json"), "w"))
    print(f"  Bidi_Class  pion==rust on all {len(p)} scalars: {rep['class_pion_vs_rust_mismatch'] == 0}")
    print(f"  Bidi_Class  pion vs UCD 16.0.0: {len(diff)} code points differ in {len(runs)} ranges")
    by = {}
    for a, b, (x, y) in runs:
        k = f"{CLASSES[x - 65]}->{CLASSES[y - 65]}"
        by.setdefault(k, []).append(f"{a:04X}..{b:04X}" if a != b else f"{a:04X}")
    for k, v in by.items():
        print(f"      pion/rust={k.split('->')[0]:3s} UCD16={k.split('->')[1]:3s}: {len(v):3d} ranges e.g. {', '.join(v[:8])}")
    # brackets + mirroring
    def tab(f):
        B, M = {}, {}
        for l in open(f):
            t = l.split()
            if t[0] == "B":
                B[int(t[1])] = (t[2], int(t[3]))
            else:
                M[int(t[1])] = int(t[2])
        return B, M
    pb, pm = tab(os.path.join(TMP, "pion.tab"))
    rb, rm = tab(os.path.join(TMP, "rust.tab"))
    ub, um = {}, {}
    for l in open(os.path.join(UCD, "BidiBrackets.txt")):
        s = l.split("#")[0].strip()
        if s:
            a, b, t = [x.strip() for x in s.split(";")]
            a, b = int(a, 16), int(b, 16)
            op = a if t == "o" else b
            d = unicodedata.decomposition(chr(op))
            sk = int(d, 16) if d and " " not in d and not d.startswith("<") else op
            ub[a] = (t, sk)
    for l in open(os.path.join(UCD, "BidiMirroring.txt")):
        s = l.split("#")[0].strip()
        if s:
            a, b = s.split(";")
            um[int(a, 16)] = int(b, 16)
    rep["brackets"] = dict(ucd=len(ub), pion_eq_ucd=pb == ub, pion_eq_rust=pb == rb)
    rep["mirroring"] = dict(ucd=len(um), pion=len(pm), rust=len(rm), pion_eq_ucd=pm == um,
                            rust_missing=[f"U+{c:04X}" for c in sorted(set(um) - set(rm))])
    print(f"  BidiBrackets ({len(ub)} entries): pion==UCD16 {pb == ub}  pion==rust {pb == rb}")
    print(f"  BidiMirroring: UCD16={len(um)} pion={len(pm)} (==UCD16 {pm == um}) rust-mirroring-0.4.0={len(rm)}"
          f" (missing {len(set(um) - set(rm))}: {', '.join(rep['mirroring']['rust_missing'][:6])} ...)")
    if "--json" in sys.argv:
        json.dump(rep, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
