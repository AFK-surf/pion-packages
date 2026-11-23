#!/usr/bin/env python3
"""RT-xpath differential runner.

usage: run_diff.py --corpus C.json --out DIR --impl name=CMD [--impl ...] [--ref pion_name]
  CMD is a command prefix; the PACK path is appended.  The first --impl named like --ref
  (default: the first impl) is the subject; every other impl is an oracle.
Writes DIR/<impl>.out (raw stdout), DIR/summary.txt and DIR/odd_one_out.txt (queries where all
oracles agree with each other but the subject differs).  Impls whose names start with `pion`
must produce byte-identical stdout (4-mode check): any difference exits 1.
"""
import argparse
import hashlib
import json
import os
import re
import shlex
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import packlib  # noqa: E402


def norm(r):
    lines = r.split("\n")
    head = lines[0]
    if head.startswith("NUM "):
        v = struct.unpack(">d", bytes.fromhex(head[4:]))[0]
        return "NUM NaN" if v != v else head
    if head.startswith("NODES ") and any(l.startswith("  namespace ") for l in lines[1:]):
        return "\n".join([head] + sorted(lines[1:]))
    return r


def spec_ok(got, want):
    """`STRNUM <hex> <example>`: got must be `STR <plain decimal>` naming exactly that double with
    the minimal number of significant digits (W3C XPath 1.0 section 4.2); otherwise exact match."""
    if not want.startswith("STRNUM "):
        return got == want
    _, hx, example = want.split(" ", 2)
    if not got.startswith("STR ") or not re.fullmatch(r"-?[0-9]+\.[0-9]+", got[4:]):
        return False
    s = got[4:]
    if struct.pack(">d", float(s)).hex() != hx:
        return False
    digits = lambda t: len(t.replace("-", "").replace(".", "").strip("0"))
    return digits(s) <= digits(example)


def pretty(r):
    if r.startswith("NUM ") and r != "NUM NaN":
        return r + "  (%r)" % struct.unpack(">d", bytes.fromhex(r[4:20]))[0]
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--impl", action="append", required=True)
    ap.add_argument("--ref", default=None)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--gate-spec", action="store_true", help="exit 1 if the subject misses any spec expectation")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    groups = json.load(open(a.corpus))
    pack, flat = packlib.build([(g["xml"], g["ns"], g["q"], g.get("vars", [])) for g in groups])
    pack_path = os.path.join(a.out, "corpus.pack")
    open(pack_path, "wb").write(pack)
    impls = [i.split("=", 1) for i in a.impl]
    ref = a.ref or impls[0][0]
    results, raw = {}, {}
    spec_bad = 0
    for name, cmd in impls:
        p = subprocess.run(shlex.split(cmd) + [pack_path], capture_output=True, timeout=a.timeout)
        raw[name] = p.stdout
        open(os.path.join(a.out, name + ".out"), "wb").write(p.stdout)
        res = packlib.parse_output(p.stdout.decode("utf-8", "replace"))
        status = "rc=%d" % p.returncode
        if len(res) != len(flat):
            status += " INCOMPLETE %d/%d" % (len(res), len(flat))
            res += ["<missing>"] * (len(flat) - len(res))
        results[name] = [norm(r) for r in res]
        print("  %-10s %s sha256=%s" % (name, status, hashlib.sha256(p.stdout).hexdigest()[:16]))
    bad_modes = 0
    pions = [n for n, _ in impls if n.startswith("pion")]
    for n in pions[1:]:
        if raw[n] != raw[pions[0]]:
            bad_modes += 1
            print("  4-MODE MISMATCH: %s differs from %s" % (n, pions[0]))
    if len(pions) > 1 and not bad_modes:
        print("  4-mode: %s byte-identical over %d queries" % ("/".join(pions), len(flat)))
    # Python-computed W3C expectations (number fuzz group) act as an extra oracle "spec".
    spec = []
    for g in groups:
        spec += g.get("spec", [None] * len(g["q"]))
    if any(v is not None for v in spec):
        results["spec"] = spec
        impls = impls + [("spec", None)]
        sp = [i for i, v in enumerate(spec) if v is not None]
        bad = [i for i in sp if not spec_ok(results[ref][i], spec[i])]
        spec_bad = len(bad)
        print("  %s vs spec (Python W3C number model): agree %d / %d" % (ref, len(sp) - len(bad), len(sp)))
        with open(os.path.join(a.out, "spec_mismatch.txt"), "w") as f:
            for i in bad:
                f.write("### %s\n  %s: %s\n  spec: %s\n" % (flat[i][1], ref, pretty(results[ref][i]), pretty(spec[i])))
    oracles = [n for n, _ in impls if not n.startswith("pion") and n != "spec"]
    lines, odd = [], []
    for o in oracles:
        agree = sum(1 for i in range(len(flat)) if results[o][i] == results[ref][i])
        lines.append("%s vs %s: agree %d / %d" % (ref, o, agree, len(flat)))
    if len(oracles) >= 2:
        for i, (xml, q) in enumerate(flat):
            ovals = [results[o][i] for o in oracles]
            if all(v == ovals[0] for v in ovals) and ovals[0] != results[ref][i] and "<missing>" not in ovals:
                odd.append(i)
        lines.append("%s is the odd one out (all oracles agree, subject differs): %d" % (ref, len(odd)))
    print("\n".join("  " + l for l in lines))
    with open(os.path.join(a.out, "odd_one_out.txt"), "w") as f:
        for i in odd:
            f.write("### %s\n  %s: %s\n" % (flat[i][1], ref, pretty(results[ref][i]).replace("\n", "\n    ")))
            for o in oracles:
                f.write("  %s: %s\n" % (o, pretty(results[o][i]).replace("\n", "\n    ")))
    with open(os.path.join(a.out, "all_diffs.txt"), "w") as f:
        for i, (xml, q) in enumerate(flat):
            vals = {n: results[n][i] for n, _ in impls if results[n][i] is not None}
            if "spec" in vals and spec_ok(results[ref][i], vals["spec"]):
                vals["spec"] = results[ref][i]
            if len(set(vals.values())) > 1:
                f.write("### %s\n" % q)
                for n, v in vals.items():
                    f.write("  %s: %s\n" % (n, pretty(v).replace("\n", "\n    ")))
    open(os.path.join(a.out, "summary.txt"), "w").write("\n".join(lines) + "\n")
    sys.exit(1 if bad_modes or (a.gate_spec and spec_bad) else 0)


if __name__ == "__main__":
    main()
