#!/usr/bin/env python3
"""Three-way differential over gen_vectors.py output.

usage: diff_vectors.py <vectors.tsv> <bin_dir> <work_dir>

Runs  pion (native release) with opts  -, ts0, canon, dup
      rust_probe (rmpv 1.3.1, no timestamp type -> compared with pion ts0)
      go_probe   (vmihailenco v5.4.1, decodes ext -1 to time.Time -> compared with pion -)
and   pion native-debug / wasm32-debug / wasm32-release for byte-identical output (4-mode check).
Prints every disagreement, grouped by category.
"""
import collections
import os
import subprocess
import sys

RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        sys.exit("command failed (%d): %s\n%s" % (r.returncode, " ".join(cmd), r.stderr[-2000:]))
    return r.stdout.splitlines()


def pion_cmds(bin_dir):
    return {
        "native-release": [os.path.join(bin_dir, "pion_probe")],
        "native-debug": [os.path.join(bin_dir, "pion_probe_debug")],
        "wasm32-debug": ["node", RT, os.path.join(bin_dir, "pion_probe_debug.wasm")],
        "wasm32-release": ["node", RT, os.path.join(bin_dir, "pion_probe_release.wasm")],
    }


def split(line):
    if line.startswith("OK "):
        parts = line.split(" ")
        return "OK", parts[1], parts[2] if len(parts) > 2 else ""
    return "ERR", line[4:], ""


def main():
    tsv, bin_dir, work = sys.argv[1:4]
    os.makedirs(work, exist_ok=True)
    vecs = [l.rstrip("\n").split("\t") for l in open(tsv) if l.strip()]
    hexf = os.path.join(work, "vectors.hex")
    with open(hexf, "w") as f:
        f.write("".join(v[2] + "\n" for v in vecs))

    P = pion_cmds(bin_dir)
    out = {}
    for opt in ("-", "ts0", "canon", "dup", "compact"):
        out["pion", opt] = run(P["native-release"] + ["tree", opt, hexf])
    out["rust"] = run([os.path.join(bin_dir, "rust_probe"), "tree", "-", hexf])
    out["go"] = run([os.path.join(bin_dir, "go_probe"), "tree", "-", hexf])

    # 4-mode consistency
    mism = 0
    for mode in ("native-debug", "wasm32-debug", "wasm32-release"):
        for opt in ("-", "ts0", "canon", "dup", "compact"):
            got = run(P[mode] + ["tree", opt, hexf])
            for i, (a, b) in enumerate(zip(out["pion", opt], got)):
                if a != b:
                    mism += 1
                    print("4MODE MISMATCH %s opts=%s %s: native-release=%s %s=%s" % (mode, opt, vecs[i][1], a, mode, b))
            if len(got) != len(out["pion", opt]):
                mism += 1
                print("4MODE line-count mismatch %s %s" % (mode, opt))
    print("4-mode check (native release/debug, wasm32 debug/release x 5 option sets x %d vectors): %d mismatches"
          % (len(vecs), mism))

    diffs = collections.defaultdict(list)
    for i, (cat, name, h) in enumerate(vecs):
        pd, pt, pe = split(out["pion", "-"][i])
        p0d, p0t, p0e = split(out["pion", "ts0"][i])
        rd, rt, re_ = split(out["rust"][i])
        gd, gt, _ = split(out["go"][i])
        row = "%-28s %s\n      pion=%s\n      pion(ts0)=%s\n      rust=%s\n      go  =%s" % (
            name, h[:80], out["pion", "-"][i][:160], out["pion", "ts0"][i][:160], out["rust"][i][:160], out["go"][i][:160])
        if (p0d, p0t if p0d == "OK" else "") != (rd, rt if rd == "OK" else ""):
            diffs[cat, "pion(ts0) vs rust: decision/tree"].append(row)
        elif p0d == "OK" and p0e != re_:
            diffs[cat, "pion(ts0) vs rust: re-encoding"].append(row + "\n      pion-enc=%s rust-enc=%s" % (p0e, re_))
        if (pd, pt if pd == "OK" else "") != (gd, gt if gd == "OK" else ""):
            diffs[cat, "pion vs go: decision/tree"].append(row)
        if cat in ("canon", "ts", "int"):
            cd = out["pion", "canon"][i]
            diffs[cat, "pion require_canonical verdicts (info)"].append("%-28s %s -> %s" % (name, h[:40], cd[:100]))
        if cat == "dup":
            diffs[cat, "pion reject_duplicate_keys verdicts (info)"].append("%-28s -> %s" % (name, out["pion", "dup"][i][:100]))
        if cat == "float":
            diffs[cat, "pion compact_floats re-encoding (info)"].append("%-28s -> %s" % (name, out["pion", "compact"][i][:100]))

    # canonical self-consistency: every Pion re-encoding must pass Pion's own strict decoder
    reenc = [split(l)[2] for l in out["pion", "-"] if l.startswith("OK ")]
    rf = os.path.join(work, "reenc.hex")
    with open(rf, "w") as f:
        f.write("".join(x + "\n" for x in reenc))
    bad = [(x, r) for x, r in zip(reenc, run(P["native-release"] + ["tree", "strict", rf])) if not r.startswith("OK ")]
    bad = [(x, r) for x, r in bad if "duplicate" not in r]
    print("canonical self-check: %d Pion re-encodings, %d rejected by DecodeOptions::strict()" % (len(reenc), len(bad)))
    for x, r in bad[:20]:
        print("   ", x[:60], "->", r)

    for (cat, kind), rows in sorted(diffs.items()):
        print("\n## [%s] %s: %d" % (cat, kind, len(rows)))
        for r in rows:
            print("  " + r)


if __name__ == "__main__":
    main()
