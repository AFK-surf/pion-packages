#!/usr/bin/env python3
"""Three-way differential driver: Pion `packages/wasm` vs Rust wasmparser 0.221.3 vs V8.

usage: diff.py <corpus_dir> <harness_bin> <oracle_bin> <v8_validate.mjs> [--timeout S]

The corpus dir holds `<i>.wasm` plus `manifest.tsv` (`i<TAB>name<TAB>expect`).
Writes `<corpus_dir>/results.tsv` and prints a summary.  A Pion process that aborts
(panic / trap) or exceeds the per-file timeout is recorded as CRASH / TIMEOUT for the file
it was processing and the harness is restarted on the next file.
"""
import os
import subprocess
import sys
import time
from collections import Counter


def load_tsv(text):
    out = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        try:
            out[int(parts[0])] = parts[1:]
        except ValueError:
            pass
    return out


def run_pion(d, harness, ids, timeout, prefix=()):
    res = {}
    todo = sorted(ids)
    pos = 0
    while pos < len(todo):
        start = todo[pos]
        end = todo[-1] + 1
        try:
            p = subprocess.run(list(prefix) + [harness, "check", d, str(start), str(end)], capture_output=True,
                               text=True, errors="replace", timeout=timeout)
            out, err, rc = p.stdout, p.stderr, p.returncode
        except subprocess.TimeoutExpired as e:
            out = (e.stdout or b"").decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
            err, rc = "TIMEOUT", -999
        got = load_tsv(out)
        res.update(got)
        if rc == 0:
            break
        done = [i for i in todo[pos:] if i in got]
        last = max(done) if done else start - 1
        nxt = [i for i in todo[pos:] if i > last]
        if not nxt:
            break
        victim = nxt[0]
        why = "TIMEOUT" if rc == -999 else "CRASH:" + " ".join(err.strip().splitlines()[-1:])[:150]
        res[victim] = [why, "RE:NA", "WAT:NA"]
        pos = todo.index(victim) + 1
    return res


def main():
    d, harness, oracle, v8 = sys.argv[1:5]
    timeout = 60
    if "--timeout" in sys.argv:
        timeout = int(sys.argv[sys.argv.index("--timeout") + 1])
    man = load_tsv(open(os.path.join(d, "manifest.tsv")).read())
    ids = sorted(man)
    n = ids[-1] + 1
    t0 = time.time()
    pion = run_pion(d, harness, ids, timeout)
    t1 = time.time()
    rust = load_tsv(subprocess.run([oracle, "check", d, "0", str(n)], capture_output=True, text=True,
                                   errors="replace").stdout)
    t2 = time.time()
    v8r = load_tsv(subprocess.run(["node", v8, d, "0", str(n)], capture_output=True, text=True).stdout)
    t3 = time.time()

    cls = Counter()
    rows = []
    for i in ids:
        name, expect = man[i][0], man[i][1] if len(man[i]) > 1 else "?"
        pv = pion.get(i, ["MISSING", "RE:NA", "WAT:NA"])
        rv = rust.get(i, ["MISSING", "MISSING", "NA", "NA"])
        vv = v8r.get(i, ["MISSING"])[0]
        p_ok = pv[0] == "OK"
        w_ok = rv[0] == "OK"
        v_ok = vv == "OK"
        if pv[0].startswith("CRASH") or pv[0] == "TIMEOUT":
            c = "PION_" + pv[0].split(":")[0]
        elif p_ok and not w_ok and not v_ok:
            c = "PION_ACCEPTS_INVALID"
        elif p_ok and not w_ok and v_ok:
            c = "PION_ACCEPTS_NON_WASM2"  # V8 ships the post-2.0 proposal; wasmparser WASM2 rejects
        elif not p_ok and w_ok and v_ok:
            c = "PION_REJECTS_VALID"
        elif not p_ok and w_ok and not v_ok:
            c = "PION_REJECTS_WASM2_VALID_V8_REJECTS"
        elif p_ok == w_ok:
            c = "AGREE_VALID" if p_ok else "AGREE_INVALID"
        else:
            c = "OTHER"
        cls[c] += 1
        re_ = rv[2] if len(rv) > 2 else "NA"
        wat = rv[3] if len(rv) > 3 else "NA"
        if w_ok:
            cls["valid:re:" + re_.split(":")[0]] += 1
            cls["valid:wat:" + wat.split(":")[0]] += 1
        rows.append([str(i), name, expect, c, pv[0], rv[0], rv[1] if len(rv) > 1 else "?", vv, re_, wat])
    with open(os.path.join(d, "results.tsv"), "w") as f:
        f.write("i\tname\texpect\tclass\tpion\twasmparser_wasm2\twasmparser_default\tv8\treencode\twat\n")
        for r in rows:
            f.write("\t".join(r) + "\n")
    print(f"corpus={d} files={len(ids)} pion_s={t1 - t0:.1f} rust_s={t2 - t1:.1f} v8_s={t3 - t2:.1f}")
    for k in sorted(cls):
        print(f"  {k:45} {cls[k]}")


if __name__ == "__main__":
    main()
