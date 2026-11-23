#!/usr/bin/env python3
"""3-way differential: Pion probe vs Go x/net/http2 vs Rust h2 (HPACK) / Go Framer (frames).

usage: compare.py hpack|frames <corpus.txt> <pion_probe> <go_runner> [<h2_runner>] [--md out.md] [--dump pion.out]

The Pion probe is run case-by-case-resumable: when it aborts (process panic) the case it was on is
recorded as CRASH and the probe is restarted on the next case, so one P0 does not hide the rest.

Classification per case (Go is the primary oracle; h2 is reported alongside):
  agree            Pion == Go (== h2 when given)
  CRASH            Pion process aborted
  pion_accepts     Pion OK, Go ERR          (a block/frame no reference accepts)
  pion_rejects     Pion ERR, Go OK
  value_mismatch   both OK, different output
For HPACK, cases where only h2 differs are tallied separately (h2 fuses HTTP semantics into HPACK:
lowercase/token names, CTL-free values, 5-octet integer limit, :method/:status parsing).
"""
import collections
import os
import re
import subprocess
import sys


def run_lines(cmd):
    p = subprocess.run(cmd, capture_output=True)
    return p.returncode, p.stdout.decode("latin-1").splitlines(), p.stderr.decode("latin-1")


def run_pion(probe, mode, corpus, n):
    """`probe` may be a path or a list (e.g. ["node", rt.mjs, probe.wasm]) for the wasm32 builds.

    Abort isolation: when the probe dies, the next case is re-run *alone*; only if it aborts alone is it
    recorded as an abort (an aborting process may lose buffered stdout, e.g. node under load, which
    would otherwise blame an innocent earlier case). A trailing partial line is discarded.
    """
    prefix = probe if isinstance(probe, list) else [probe]
    lines_all = open(corpus, encoding="latin-1").read().splitlines()
    out, crashes, skip = [], {}, 0
    while skip < n:
        p = subprocess.run(prefix + [mode, corpus, str(skip)], capture_output=True)
        text = p.stdout.decode("latin-1")
        lines = text.split("\n")
        lines = lines[:-1]  # last element is "" (complete) or a partial line (aborted mid-write)
        out.extend(lines)
        skip += len(lines)
        if p.returncode == 0 and skip >= n:
            break
        if skip >= n:
            break
        tmp = corpus + ".one"
        with open(tmp, "w", encoding="latin-1") as f:
            f.write(lines_all[skip] + "\n")
        q = subprocess.run(prefix + [mode, tmp, "0"], capture_output=True)
        os.remove(tmp)
        if q.returncode == 0 and q.stdout.endswith(b"\n"):
            out.append(q.stdout.decode("latin-1").rstrip("\n"))
        else:
            err = q.stderr.decode("latin-1").strip().splitlines()
            crashes[skip] = err[0] if err else f"rc={q.returncode}"
            out.append(None)
        skip += 1
    return out, crashes


ERR_RE = re.compile(r"ERR\([^)]*\)")


def raw(line):
    return None if line is None else line.split("\t", 1)[1]


def body(line):
    """Outcome with error reasons stripped (reasons are kept only for the examples)."""
    return None if line is None else ERR_RE.sub("ERR", line.split("\t", 1)[1])


def why(line, crash=None):
    if line is None:
        return "CRASH: " + re.sub(r"-?\d+", "N", crash or "")
    b = line.split("\t", 1)[1]
    m = re.search(r"ERR\(([^)]*)\)", b)
    if m:
        return "ERR: " + re.sub(r"\d+", "N", m.group(1))[:80]
    if "ERR" in b:
        return "ERR"
    return "OK"


def focus(P, G, H, width=110):
    """Cut all outputs at the first position where Pion and Go diverge (keeps reports readable)."""
    k = 0
    while k < min(len(P), len(G)) and P[k] == G[k]:
        k += 1
    st = max(0, k - 30)
    cut = lambda s: ("…" if st else "") + s[st : st + width] if s is not None else None
    return cut(P), cut(G), cut(H)


def main():
    args = sys.argv[1:]
    md = dump = None
    if "--dump" in args:
        i = args.index("--dump")
        dump = args[i + 1]
        del args[i : i + 2]
    if "--md" in args:
        i = args.index("--md")
        md = args[i + 1]
        del args[i : i + 2]
    mode, corpus, probe, go = args[:4]
    h2 = args[4] if len(args) > 4 else None
    names = [l.split("\t", 1)[0] for l in open(corpus, encoding="latin-1").read().splitlines()]
    n = len(names)
    os.environ["DIFF_REASON"] = "1"
    pion, crashes = run_pion(probe, mode, corpus, n)
    _, gol, _ = run_lines([go, mode, corpus])
    h2l = run_lines([h2, mode, corpus])[1] if h2 else None
    assert len(pion) == n and len(gol) == n, (len(pion), len(gol), n)

    cls = collections.Counter()
    fam = collections.defaultdict(collections.Counter)
    examples = collections.defaultdict(list)
    tri = collections.Counter()
    trifam = collections.defaultdict(collections.Counter)
    triex = collections.defaultdict(list)
    for i, name in enumerate(names):
        P, G = body(pion[i]), body(gol[i])
        H = body(h2l[i]) if h2l else None
        family = name.split("_")[0]
        if P is None:
            c = "CRASH"
        elif P == G:
            c = "agree"
        else:
            pe, ge = P.endswith("ERR") or P == "ERR", G.endswith("ERR") or G == "ERR"
            # compare per-block prefix: first divergence decides
            pb, gb = P.split("|"), G.split("|")
            c = "value_mismatch"
            for a, b in zip(pb, gb):
                if a != b:
                    if a == "ERR":
                        c = "pion_rejects"
                    elif b == "ERR":
                        c = "pion_accepts"
                    break
            _ = (pe, ge)
        cls[c] += 1
        fam[family][c] += 1
        if c != "agree" and len(examples[c]) < 12:
            examples[c].append((name, raw(pion[i]) if P is not None else "CRASH: " + crashes.get(i, ""), raw(gol[i]), raw(h2l[i]) if h2l else None))
        if H is not None and P is not None:
            # h2 does not track never-indexed on decode ("TODO" in h2 decoder.rs): compare without '!'
            Pn, Gn, Hn = P.replace("!", ""), G.replace("!", ""), H.replace("!", "")
            if Pn == Gn == Hn:
                pat = "P=G=H"
            elif Pn == Gn:
                pat = "P=G!=H"
            elif Pn == Hn:
                pat = "P=H!=G"
            elif Gn == Hn:
                pat = "G=H!=P"
            else:
                pat = "all_differ"
            tri[pat] += 1
            trifam[family][pat] += 1
            if pat != "P=G=H" and len(triex[pat]) < 6:
                triex[pat].append((name, raw(pion[i]), raw(gol[i]), raw(h2l[i])))
        elif H is not None:
            tri["CRASH"] += 1
            trifam[family]["CRASH"] += 1

    rep = []
    rep.append(f"# {mode} differential: {n} cases (Pion vs Go x/net/http2" + (" vs Rust h2 0.4.20)" if h2 else ")"))
    rep.append("")
    rep.append("| class | cases |")
    rep.append("|---|---:|")
    for k in ["agree", "CRASH", "pion_accepts", "pion_rejects", "value_mismatch"]:
        rep.append(f"| {k} | {cls[k]} |")
    rep.append("")
    rep.append("| family | " + " | ".join(["agree", "CRASH", "pion_accepts", "pion_rejects", "value_mismatch"]) + " |")
    rep.append("|---|" + "---:|" * 5)
    for f in sorted(fam):
        rep.append(f"| {f} | " + " | ".join(str(fam[f][k]) for k in ["agree", "CRASH", "pion_accepts", "pion_rejects", "value_mismatch"]) + " |")
    for c, ex in examples.items():
        rep.append("")
        rep.append(f"## {c} (first {len(ex)})")
        for name, P, G, H in ex:
            a, b, h = focus(P or "", G or "", H)
            rep.append(f"- `{name}`  pion=`{a}`  go=`{b}`" + (f"  h2=`{h}`" if H is not None else ""))
    if h2:
        pats = ["P=G=H", "P=G!=H", "P=H!=G", "G=H!=P", "all_differ", "CRASH"]
        rep.append("")
        rep.append("## 3-way (never-indexed flag ignored for h2)")
        rep.append("")
        rep.append("| family | " + " | ".join(pats) + " |")
        rep.append("|---|" + "---:|" * len(pats))
        for f in sorted(trifam):
            rep.append(f"| {f} | " + " | ".join(str(trifam[f][k]) for k in pats) + " |")
        rep.append(f"| **total** | " + " | ".join(str(tri[k]) for k in pats) + " |")
        for pat, ex in triex.items():
            rep.append("")
            rep.append(f"### {pat} (first {len(ex)})")
            for name, P, G, H in ex:
                a, b, h = focus(P, G, H)
                rep.append(f"- `{name}` pion=`{a}` go=`{b}` h2=`{h}`")
    # Root-cause clusters for every case where Pion != Go, keyed by the three error reasons.
    clusters = collections.Counter()
    first = {}
    for i, name in enumerate(names):
        P, G = body(pion[i]), body(gol[i])
        if P is not None and P == G:
            continue
        key = (why(pion[i], crashes.get(i)), why(gol[i]), why(h2l[i]) if h2l else "-")
        clusters[key] += 1
        first.setdefault(key, name)
    rep.append("")
    rep.append("## Root-cause clusters where Pion != Go (reason of first failing block; digits -> N)")
    rep.append("")
    rep.append("| cases | example | pion | go | h2 |")
    rep.append("|---:|---|---|---|---|")
    for key, v in clusters.most_common():
        rep.append(f"| {v} | `{first[key]}` | {key[0]} | {key[1]} | {key[2]} |")
    if dump:
        with open(dump, "w") as f:
            for i, name in enumerate(names):
                f.write(name + "\t" + (raw(pion[i]) if pion[i] is not None else "CRASH(" + crashes.get(i, "") + ")") + "\n")
    text = "\n".join(rep) + "\n"
    print(text)
    if md:
        open(md, "w").write(text)


if __name__ == "__main__":
    main()
