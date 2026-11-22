#!/usr/bin/env python3
"""Run the Pion and Rust (`url v2.5.9`) differential drivers over each suite and
report every mismatch, triaged with a third WHATWG implementation (Node.js `URL`,
backed by Ada) as tie-breaker.
Usage: compare.py <cases_dir> <pion_bin> <rust_bin> <out_dir> [node_driver.mjs]

Triage of a Pion/Rust mismatch:
  PION_BUG        Rust == Node != Pion   (two independent WHATWG impls agree against Pion)
  RUST_DEVIATION  Pion == Node != Rust   (Pion is right; known rust-url deviation)
  STATUS          same resulting URL, but setter success/failure result differs from Rust
  NATIVE_API      rust-url native API (`set_scheme`, `set_host`, ...): no WHATWG oracle
  THREE_WAY       all three differ (manual review)

Writes <out_dir>/summary.json and <out_dir>/<suite>.mismatch.txt (human-readable).
A Pion crash or hang on a case is isolated by re-running the remaining cases one by
one and is reported as a mismatch of kind CRASH / TIMEOUT.
"""

import json
import os
import subprocess
import sys

FIELDS = ["status", "href", "protocol", "username", "password", "host", "hostname", "port",
          "pathname", "search", "hash", "origin", "opaque"]
TIMEOUT = 120


def dec(line):
    return [bytes.fromhex(x).decode("utf-8", "replace") if x != "~" else None
            for x in line.split("\t")]


def run(binary, data, timeout=TIMEOUT):
    p = subprocess.run([binary], input=data, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode("ascii", "replace").splitlines()


def run_pion_safe(binary, lines):
    """Run all cases; if the process dies early, isolate the culprit and continue."""
    out = []
    i = 0
    while i < len(lines):
        chunk = "\n".join(lines[i:]) + "\n"
        try:
            rc, res = run(binary, chunk.encode())
        except subprocess.TimeoutExpired:
            rc, res = -999, []
        out.extend(res)
        i += len(res)
        if i >= len(lines):
            break
        # case i crashed / hung: run it alone to classify it
        try:
            rc1, r1 = run(binary, (lines[i] + "\n").encode(), timeout=20)
            kind = "CRASH(rc=%d)" % rc1 if not r1 else None
        except subprocess.TimeoutExpired:
            kind = "TIMEOUT"
        if kind is None:  # works alone: memory/state issue; keep it
            out.extend(r1)
        else:
            out.append(kind.encode().hex())
        i += 1
    return out


def view(line, op):
    """Comparable part of a result line: setter results are dropped for S (Node
    setters never report failure), everything else compared verbatim."""
    d = dec(line)
    if op == "S" and len(d) >= len(FIELDS):
        return d[-len(FIELDS):]
    return d


def triage(op, r, p, n):
    if n is None or dec(n) == ["NA"]:
        return "NATIVE_API"
    vr, vp, vn = view(r, op), view(p, op), view(n, op)
    if vr == vp:
        return "STATUS"
    if vr == vn:
        return "PION_BUG"
    if vp == vn:
        return "RUST_DEVIATION"
    return "THREE_WAY"


def describe(fields_in, r, p):
    rd, pd = dec(r), dec(p)
    op = fields_in[0]
    diffs = []
    if op in ("P", "J") and len(rd) == len(FIELDS) and len(pd) == len(FIELDS):
        for k, a, b in zip(FIELDS, rd, pd):
            if a != b:
                diffs.append(k)
    elif op == "S":
        n = len(rd) - len(FIELDS)
        names = fields_in[2::2]
        for j in range(max(len(rd), len(pd))):
            a = rd[j] if j < len(rd) else None
            b = pd[j] if j < len(pd) else None
            if a != b:
                if j < n:
                    diffs.append("result(%s)" % names[j])
                elif 0 <= j - n < len(FIELDS):
                    diffs.append(FIELDS[j - n])
                else:
                    diffs.append("shape")
    else:
        diffs.append("value")
    return rd, pd, sorted(set(diffs))


def main():
    cases_dir, pion_bin, rust_bin, out_dir = sys.argv[1:5]
    node_js = sys.argv[5] if len(sys.argv) > 5 else None
    os.makedirs(out_dir, exist_ok=True)
    # `roundtrip` is a single-implementation property suite (see roundtrip.py)
    suites = sorted(f[:-3] for f in os.listdir(cases_dir)
                    if f.endswith(".in") and f != "roundtrip.in")
    summary = {}
    for s in suites:
        with open(os.path.join(cases_dir, s + ".in")) as f:
            lines = [l for l in f.read().splitlines() if l]
        rc, rust_out = run(rust_bin, ("\n".join(lines) + "\n").encode())
        assert rc == 0 and len(rust_out) == len(lines), "rust driver failed on " + s
        pion_out = run_pion_safe(pion_bin, lines)
        node_out = [None] * len(lines)
        if node_js:
            p = subprocess.run(["node", node_js], input=("\n".join(lines) + "\n").encode(),
                               capture_output=True, timeout=TIMEOUT)
            assert p.returncode == 0, p.stderr
            node_out = p.stdout.decode().splitlines()
            assert len(node_out) == len(lines)
        mism = []
        by_op = {}
        by_field = {}
        by_triage = {}
        for ln, r, p, n in zip(lines, rust_out, pion_out, node_out):
            op = bytes.fromhex(ln.split("\t")[0]).decode()
            by_op.setdefault(op, [0, 0])[0] += 1
            if r == p:
                continue
            by_op[op][1] += 1
            fin = dec(ln)
            rd, pd, diffs = describe(fin, r, p)
            t = triage(op, r, p, n)
            by_triage[t] = by_triage.get(t, 0) + 1
            for d in diffs:
                by_field[d] = by_field.get(d, 0) + 1
            mism.append({"case": fin, "rust": rd, "pion": pd, "diff": diffs, "triage": t,
                         "node": dec(n) if n is not None else None})
        summary[s] = {
            "cases": len(lines),
            "mismatches": len(mism),
            "by_op": {k: {"cases": v[0], "mismatches": v[1]} for k, v in sorted(by_op.items())},
            "by_triage": by_triage,
            "by_field": dict(sorted(by_field.items(), key=lambda kv: -kv[1])),
        }
        with open(os.path.join(out_dir, s + ".mismatch.txt"), "w", encoding="utf-8") as f:
            for m in mism:
                f.write("CASE  %s\n" % json.dumps(m["case"], ensure_ascii=True))
                f.write("DIFF  [%s] %s\n" % (m["triage"], ", ".join(m["diff"])))
                f.write("RUST  %s\n" % json.dumps(m["rust"], ensure_ascii=False))
                f.write("PION  %s\n" % json.dumps(m["pion"], ensure_ascii=False))
                f.write("NODE  %s\n\n" % json.dumps(m["node"], ensure_ascii=False))
        print("%-9s %6d cases  %5d mismatches  %s" % (s, len(lines), len(mism),
                                                       json.dumps(by_triage)))
    with open(os.path.join(out_dir, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1, sort_keys=True)
    total = sum(v["mismatches"] for v in summary.values())
    print("TOTAL mismatches: %d / %d cases" % (total, sum(v["cases"] for v in summary.values())))


if __name__ == "__main__":
    main()
