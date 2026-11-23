#!/usr/bin/env python3
"""Three-way differential harness: packages/jq (Pion) vs gojq v0.12.17 vs jq 1.7.x.

usage: run_diff.py --corpus C.json --pion BIN [--pion BIN2 ...] --gojq ORACLE [--jq jq] --out DIR

* every Pion binary is run over the whole corpus (one process, streaming one JSON
  line per case; a crashed process is restarted after the crashing case, which is
  recorded as {"crash": <exit status>});
* gojq runs via audit/diff/go (`oracle run`), jq via one subprocess per case;
* verdicts per case:
    match       Pion output text == gojq output text (or both errored)
    fmt         same JSON values, different number spelling
    bug         Pion differs from gojq AND jq agrees with gojq  (confirmed defect)
    gojq-only   Pion differs from gojq but agrees with jq       (gojq-specific behaviour)
    split       all three disagree / jq unavailable
    errmsg      only error-message strings differ (inside try/catch)
  plus mode-consistency across Pion binaries (`modes_consistent`).
"""
import argparse, json, os, subprocess, sys, time
from collections import Counter, defaultdict


def run_stream(cmd, corpus, tmpdir, tag):
    """Run a streaming runner, restarting after crashes. Returns (results, times)."""
    results, times = [None] * len(corpus), [0.0] * len(corpus)
    start = 0
    while start < len(corpus):
        path = os.path.join(tmpdir, f"{tag}.chunk.json")
        with open(path, "w") as f:
            json.dump(corpus[start:], f)
        p = subprocess.Popen(cmd + [path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        i, t = start, time.time()
        for raw in p.stdout:
            now = time.time()
            try:
                results[i] = json.loads(raw.decode("utf-8"))
            except UnicodeDecodeError:
                # the runner emitted bytes that are not valid UTF-8 (itself a defect)
                results[i] = {"invalid_utf8": raw[:300].hex()}
            except Exception:
                results[i] = {"err": "unparseable runner line: " + repr(raw[:200])}
            times[i] = now - t
            t, i = now, i + 1
            if i >= len(corpus):
                break
        rc = p.wait()
        if i < len(corpus):
            err = p.stderr.read()[-400:].decode("utf-8", "replace")
            results[i] = {"crash": rc, "stderr": err}
            times[i] = time.time() - t
            print(f"  [{tag}] CRASH rc={rc} at case {i}: {json.dumps(corpus[i])[:160]}", file=sys.stderr)
            i += 1
        start = i
    return results, times


def run_jq(jq, corpus):
    out = []
    for q, inp in corpus:
        try:
            p = subprocess.run([jq, "-c", "-S", q], input=inp.encode(), capture_output=True, timeout=3)
            if p.returncode != 0:
                out.append({"err": p.stderr.decode(errors="replace")[:300]})
            else:
                txt = p.stdout[:1 << 20].decode(errors="replace")
                out.append({"ok": [l for l in txt.split("\n") if l != ""]})
        except subprocess.TimeoutExpired:
            out.append({"timeout": True})
    return out


def loads_all(xs):
    try:
        return [json.loads(x) for x in xs]
    except Exception:
        return None


def same(a, b):
    if a is None or b is None:
        return False
    if "ok" in a and "ok" in b:
        return a["ok"] == b["ok"] or loads_all(a["ok"]) == loads_all(b["ok"])
    return ("err" in a) and ("err" in b)


def classify(q, p, g, j):
    if "crash" in p:
        return "crash"
    if "invalid_utf8" in p:
        return "invalid_utf8"
    if "ok" in p and "ok" in g:
        if p["ok"] == g["ok"]:
            return "match"
        lp, lg = loads_all(p["ok"]), loads_all(g["ok"])
        if lp is not None and lp == lg:
            return "fmt"
        if "catch" in q and lp is not None and lg is not None and len(lp) == len(lg):
            diff = [(x, y) for x, y in zip(lp, lg) if x != y]
            if diff and all(isinstance(x, str) and isinstance(y, str) for x, y in diff):
                return "errmsg"
    elif "err" in p and "err" in g:
        return "match"
    elif "timeout" in g:
        return "gojq-timeout"
    if j is None:
        return "split"
    if same(p, j):
        return "gojq-only"
    if same(g, j):
        return "bug"
    return "split"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--pion", action="append", required=True, help="NAME=BIN")
    ap.add_argument("--gojq", required=True)
    ap.add_argument("--jq", default=None)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    corpus = [tuple(c[:2]) for c in json.load(open(a.corpus))]
    tags = [c[2] if len(c) > 2 else "misc" for c in json.load(open(a.corpus))]
    print(f"corpus: {len(corpus)} cases", file=sys.stderr)

    pions = {}
    for spec in a.pion:
        name, binp = spec.split("=", 1)
        cmd = binp.split()
        t0 = time.time()
        pions[name] = run_stream(cmd, corpus, a.out, name)
        print(f"  pion[{name}] {time.time() - t0:.1f}s", file=sys.stderr)
    t0 = time.time()
    gojq, _ = run_stream([a.gojq, "run"], corpus, a.out, "gojq")
    print(f"  gojq {time.time() - t0:.1f}s", file=sys.stderr)
    jqr = None
    if a.jq:
        t0 = time.time()
        jqr = run_jq(a.jq, corpus)
        print(f"  jq {time.time() - t0:.1f}s", file=sys.stderr)

    primary = list(pions)[0]
    P, PT = pions[primary]
    verdicts = Counter()
    by_tag = defaultdict(Counter)
    rows = []
    mode_mismatch = []
    for i, (q, inp) in enumerate(corpus):
        j = jqr[i] if jqr else None
        v = classify(q, P[i], gojq[i], j)
        verdicts[v] += 1
        by_tag[tags[i]][v] += 1
        outs = {n: pions[n][0][i] for n in pions}
        if len({json.dumps(o, sort_keys=True) for o in outs.values()}) > 1:
            mode_mismatch.append({"i": i, "q": q, "in": inp, "outs": outs})
        rows.append({"i": i, "tag": tags[i], "q": q, "in": inp, "verdict": v, "pion": P[i], "gojq": gojq[i],
                     "jq": j, "pion_s": round(PT[i], 4)})
    with open(os.path.join(a.out, "results.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    with open(os.path.join(a.out, "mode_mismatch.json"), "w") as f:
        json.dump(mode_mismatch, f, ensure_ascii=False, indent=1)
    summary = {"cases": len(corpus), "verdicts": dict(verdicts),
               "by_tag": {k: dict(v) for k, v in sorted(by_tag.items())},
               "modes": list(pions), "mode_mismatches": len(mode_mismatch),
               "crashes": {n: sum(1 for r in pions[n][0] if "crash" in r) for n in pions},
               "slowest_pion": sorted(({"s": round(PT[i], 3), "q": corpus[i][0][:120], "in": corpus[i][1][:40]}
                                       for i in range(len(corpus))), key=lambda x: -x["s"])[:15]}
    with open(os.path.join(a.out, "summary.json"), "w") as f:
        json.dump(summary, f, ensure_ascii=False, indent=1)
    print(json.dumps({k: summary[k] for k in ("cases", "verdicts", "mode_mismatches", "crashes")}, indent=1))


if __name__ == "__main__":
    main()
