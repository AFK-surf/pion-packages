#!/usr/bin/env python3
"""3-way decode/verify differential: pion vs ref.py (RFC reference) vs webrtc-rs stun 0.8.

  compare.py <pion.out> <ref.out> <rust.out> [--md out.md] [--show N]

Fields: D (decode), FP, MI, M2 (MI-SHA256), XA (first XOR-MAPPED-ADDRESS).
* pion vs ref: every field must match; mismatches are grouped by field and label family.
* pion vs rust: FP / MI / XA where both decoded (stun 0.8 decodes lazily: no typed checks, no MI-SHA256).
* SECURITY: any vector where pion says FP/MI/M2 = true but a reference does not.
"""
import collections
import sys


def load(p):
    out = {}
    for line in open(p):
        f = line.rstrip("\n").split("\t")
        out[f[0]] = dict(x.split("=", 1) for x in f[1:])
    return out


def fam(label):
    if label.startswith("mut"):
        return "mut*_" + label.split("_", 1)[1].split("_")[0]
    return label.rsplit("_", 1)[0] if label.startswith(("enc", "valid_enc")) else label


def main():
    a = sys.argv[1:]
    md = a[a.index("--md") + 1] if "--md" in a else None
    show = int(a[a.index("--show") + 1]) if "--show" in a else 6
    pion, ref, rust = load(a[0]), load(a[1]), load(a[2])
    lines = []
    p = lines.append
    p("vectors: %d (pion %d, ref %d, rust %d)" % (len(ref), len(pion), len(ref), len(rust)))
    # pion vs ref
    diff = collections.defaultdict(list)
    for k, r in ref.items():
        for fld in ("D", "FP", "MI", "M2", "XA"):
            if pion[k][fld] != r[fld]:
                diff[fld].append(k)
    same = sum(1 for k in ref if all(pion[k][f] == ref[k][f] for f in ("D", "FP", "MI", "M2", "XA")))
    p("pion == ref (all 5 fields): %d / %d" % (same, len(ref)))
    for fld, ks in sorted(diff.items()):
        groups = collections.Counter(k if not k.startswith("mut") else "mut*" for k in ks)
        p("  field %s differs on %d vectors" % (fld, len(ks)))
        for k in [x for x in ks if not x.startswith("mut")][:show] + [x for x in ks if x.startswith("mut")][:2]:
            p("    %-40s pion=%s ref=%s" % (k, pion[k][fld][:70], ref[k][fld][:70]))
    # pion vs rust
    both = [k for k in ref if pion[k]["D"] != "err" and rust[k]["D"] != "err"]
    rd = collections.defaultdict(list)
    for k in both:
        for fld in ("FP", "MI", "XA"):
            if pion[k][fld] != rust[k][fld]:
                rd[fld].append(k)
    acc = collections.Counter((pion[k]["D"] != "err", rust[k]["D"] != "err") for k in ref)
    p("decode acceptance pion/rust: both ok=%d, pion-only=%d, rust-only=%d, both err=%d" % (acc[(True, True)], acc[(True, False)], acc[(False, True)], acc[(False, False)]))
    p("pion vs rust on %d vectors both decode: FP diff=%d MI diff=%d XA diff=%d" % (len(both), len(rd["FP"]), len(rd["MI"]), len(rd["XA"])))
    for fld, ks in sorted(rd.items()):
        for k in [x for x in ks if not x.startswith("mut")][:show] + [x for x in ks if x.startswith("mut")][:2]:
            p("    %-40s %s pion=%s rust=%s" % (k, fld, pion[k][fld][:60], rust[k][fld][:60]))
    # security
    sec, api = [], []
    for k in ref:
        for fld in ("FP", "MI", "M2"):
            bad = []
            if pion[k][fld] == "true" and ref[k][fld] != "true":
                bad.append((k, fld, "ref", ref[k][fld]))
            if fld != "M2" and pion[k][fld] == "true" and rust[k][fld] != "true" and rust[k]["D"] != "err":
                bad.append((k, fld, "rust", rust[k][fld]))
            # verify_* alone said true but decode_message rejects the packet (framing broken after the
            # integrity attribute): the ICE path never accepts these -> API-contract note (P2-12)
            (api if pion[k]["D"] == "err" else sec).extend(bad)
    p("SECURITY: pion accepts integrity/fingerprint a reference rejects, on a message pion decodes: %d" % len(sec))
    for s in sec[:show]:
        p("    %s %s (%s says %s)" % s)
    p("API note (P2-12): verify_* = true on a message decode_message rejects (post-MI framing broken): %d" % len(api))
    for s in api[:3]:
        p("    %s %s (%s says %s)" % s)
    rust_panics = [k for k in rust if "panic" in rust[k].values()]
    p("rust oracle panics (caught): %d %s" % (len(rust_panics), rust_panics[:3]))
    text = "\n".join(lines)
    print(text)
    if md:
        open(md, "w").write("```\n" + text + "\n```\n")


if __name__ == "__main__":
    main()
