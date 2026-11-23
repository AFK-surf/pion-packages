#!/usr/bin/env python3
"""Compile-bomb / deep-nesting / DFA-thrash / adversarial-performance scenarios:
Pion (`stress/pion_stress`) vs Rust `regex =1.11.1` (`stress/rust_stress`).

usage: run_stress.py <out_dir> <pion_bin> <rust_bin> [--only substr] [--timeout S] [--md file]

For every scenario both binaries run with the same pattern/haystack files; we record
exit status (signal = crash), wall time, peak RSS (/usr/bin/time -l on macOS, -v on Linux)
and whether stdout is byte-identical. Each scenario is run once (plus `iters` inside).
"""
import hashlib
import json
import os
import random
import platform
import re
import subprocess
import sys
import time

OUT, PION, RUST = sys.argv[1], sys.argv[2], sys.argv[3]
ARGS = sys.argv[4:]
ONLY = ARGS[ARGS.index("--only") + 1] if "--only" in ARGS else None
TIMEOUT = float(ARGS[ARGS.index("--timeout") + 1]) if "--timeout" in ARGS else 60.0
MD = ARGS[ARGS.index("--md") + 1] if "--md" in ARGS else None
os.makedirs(OUT, exist_ok=True)


def wfile(name, data):
    p = os.path.join(OUT, name)
    if not os.path.exists(p):
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(data)
    return p


rng = random.Random(20261123)


def rand_text(n, alphabet):
    return "".join(rng.choice(alphabet) for _ in range(n))


def corpus_words(n_lines):
    words = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "Sherlock", "Holmes",
             "error", "warning", "naïve", "café", "中文", "日本語", "Привет", "αβγ", "🚀", "word",
             "words", "sword", "keyword", "wordy", "data", "status=503", "id_42", "x1y2"]
    return "\n".join(" ".join(rng.choice(words) for _ in range(rng.randint(5, 14))) for _ in range(n_lines)) + "\n"


def hays():
    return {
        "bin01": wfile("hay_bin01.txt", "\n".join(rand_text(200, "01") for _ in range(5000)) + "\n"),
        "lower": wfile("hay_lower.txt", "\n".join(rand_text(200, "abcdefghijklmnopqrstuvwxyz") for _ in range(5000)) + "\n"),
        "words": wfile("hay_words.txt", corpus_words(40000)),
        "entropy": wfile("hay_entropy.txt", rand_text(4_000_000, "".join(chr(c) for c in range(33, 127)))),
        "xs": wfile("hay_xs.txt", "x" * 20000),
        "uni": wfile("hay_uni.txt", "".join(rng.choice(["中文", "日本語", "Привет", "αβγ", " ", "abc", "🚀", "١٢٣", "\n"]) for _ in range(400000))),
        "empty": wfile("hay_empty.txt", ""),
    }


def scenarios():
    S = []
    # ---- compile-time bombs (expect fast CompiledTooBig / NestLimit errors, never OOM/SIGSEGV)
    for name, pat in [
        ("rep a{1000000000}", "a{1000000000}"),
        ("rep a{0,1000000}", "a{0,1000000}"),
        ("rep ((a{100}){100}){100}", "((a{100}){100}){100}"),
        ("rep (?:a{1000}){1000}", "(?:a{1000}){1000}"),
        ("rep \\w{1000}", r"\w{1000}"),
        ("rep \\p{L}{200}", r"\p{L}{200}"),
        ("rep [\\s\\S]{20000}", r"[\s\S]{20000}"),
        ("rep (?i)\\w{100}", r"(?i)\w{100}"),
        ("rep .{65536}", ".{65536}"),
        ("rep a{4294967296}", "a{4294967296}"),
        ("rep a{2147483648}", "a{2147483648}"),
        ("rep a{99999999999999999999}", "a{99999999999999999999}"),
    ]:
        S.append(dict(name="compile: " + name, mode="compile", pat=pat))
    for n in (300, 5000, 20000, 200000):
        S.append(dict(name=f"nest: ( x{n}", mode="compile", pat="(" * n + "a" + ")" * n))
        S.append(dict(name=f"nest: (?: x{n}", mode="compile", pat="(?:" * n + "a" + ")" * n))
        S.append(dict(name=f"nest: [ x{n}", mode="compile", pat="[" * n + "a" + "]" * n))
        S.append(dict(name=f"nest: (?i: x{n}", mode="compile", pat="(?i:" * n + "a" + ")" * n))
        S.append(dict(name=f"nest: unclosed ( x{n}", mode="compile", pat="(" * n))
        S.append(dict(name=f"nest-nl: ( x{n} nest_limit=1e6", mode="compile_nl", pat="(" * n + "a" + ")" * n))
        S.append(dict(name=f"nest-nl: a** x{n} nest_limit=1e6", mode="compile_nl", pat="(?:" * n + "a" + ")*" * n))
        S.append(dict(name=f"wide: a|...|a x{n}", mode="compile", pat="|".join(["a"] * n)))
        S.append(dict(name=f"wide: (a)(a).. x{n}", mode="compile", pat="(a)" * n))
        S.append(dict(name=f"chain: a?a?.. x{n}", mode="compile", pat="a?" * n))
        S.append(dict(name=f"chain: (?:a*)* nested x{n}", mode="compile", pat="(?:" * n + "a*" + ")*" * n))
    for n in (5000, 20000, 40000):
        S.append(dict(name=f"class: [a x{n}] (duplicate class items)", mode="compile", pat="[" + "a" * n + "]"))
    S.append(dict(name="class: [ab..] 20000 distinct-ish items", mode="compile", pat="[" + "ab" * 10000 + "]"))
    S.append(dict(name="literal: 1 MiB literal pattern", mode="compile", pat="ab" * (1 << 19)))
    # ---- runtime: DFA state explosion / cache thrash (correctness + linearity)
    H = hays()
    S += [
        dict(name="dfa-thrash: .*[01]{20} find", mode="find", pat=".*[01]{20}", hay=H["bin01"], iters=1),
        dict(name="dfa-thrash: [01]*1[01]{20} find", mode="find", pat="[01]*1[01]{20}", hay=H["bin01"], iters=1),
        dict(name="dfa-thrash: [a-z]*a[a-z]{18} find", mode="find", pat="[a-z]*a[a-z]{18}", hay=H["lower"], iters=1),
        dict(name="dfa-thrash: [a-q][^u-z]{13}x is_match", mode="is_match", pat="[a-q][^u-z]{13}x", hay=H["lower"], iters=1),
        dict(name="dfa-thrash: (?s).*1[01]{12} is_match", mode="is_match", pat="(?s).*1[01]{12}$", hay=H["bin01"], iters=1),
        # adversarial perf
        dict(name="perf: high-entropy literal miss 'zqxjk'", mode="find", pat="zqxjk", hay=H["entropy"], iters=5),
        dict(name="perf: high-entropy alt miss", mode="find", pat="zqxjk|vbnmq|plokij", hay=H["entropy"], iters=5),
        dict(name="perf: prefix literal + class 'Sherlock [A-Z]\\w+'", mode="find", pat=r"Sherlock [A-Z]\w+", hay=H["words"], iters=5),
        dict(name="perf: \\p{L}+ on Unicode", mode="find", pat=r"\p{L}+", hay=H["uni"], iters=3),
        dict(name="perf: \\w+ on Unicode", mode="find", pat=r"\w+", hay=H["uni"], iters=3),
        dict(name="perf: \\bword\\b (PikeVM in Pion)", mode="find", pat=r"\bword\b", hay=H["words"], iters=3),
        dict(name="perf: \\b\\w+\\b (PikeVM in Pion)", mode="find", pat=r"\b\w+\b", hay=H["words"], iters=1),
        dict(name="perf: (?i)sherlock|holmes", mode="find", pat="(?i)sherlock|holmes", hay=H["words"], iters=3),
        dict(name="perf: non-one-pass captures (a|ab)(c|bcd)?", mode="caps", pat="(\\w+?)(o|ox)( ?)", hay=H["words"], iters=1),
        dict(name="perf: one-pass captures (\\w+) (\\w+)", mode="caps", pat=r"([a-z]+) ([a-z]+)", hay=H["words"], iters=1),
        dict(name="perf: captures with \\b (PikeVM)", mode="caps", pat=r"\b(\w+)@?(\d*)\b", hay=H["words"], iters=1),
        dict(name="redos: (x+x+)+y on x*20000", mode="find", pat="(x+x+)+y", hay=H["xs"], iters=1),
        dict(name="redos: (x*)*$ captures on x*20000", mode="caps", pat="(x*)*y", hay=H["xs"], iters=1),
        dict(name="redos: (?:x|x)*y on x*20000", mode="find", pat="(?:x|xx)*y", hay=H["xs"], iters=1),
        dict(name="redos: \\b(x+)+\\b! on x*20000", mode="find", pat=r"\b(x+)+\b!", hay=H["xs"], iters=1),
        dict(name="empty-match iteration: '' on Unicode", mode="find", pat="", hay=H["uni"], iters=1),
    ]
    # ---- big RegexSet
    words = sorted({rand_text(rng.randint(4, 9), "abcdefghijklmnopqrstuvwxyz") for _ in range(2000)})
    for n in (16, 200, 500):
        pats = []
        for i in range(n):
            k = i % 5
            w = words[i]
            pats.append([w, f"{w[:3]}[a-z]{{2,5}}", rf"\b{w[:4]}\w*", f"(?i){w[:4]}", f"{w[:2]}.*{w[-2:]}"][k])
        S.append(dict(name=f"set: {n} rules (incl. \\b) x 40k lines", mode="set", pat="\n".join(pats) + "\n", hay=H["words"], iters=1))
        pats_nb = [p for p in pats if "\\b" not in p]
        S.append(dict(name=f"set: {len(pats_nb)} rules (no \\b) x 40k lines", mode="set", pat="\n".join(pats_nb) + "\n", hay=H["words"], iters=1))
    return S


def run(binary, mode, patf, hay, iters):
    cmd = [binary, mode, patf] + ([hay, str(iters)] if hay else [])
    if platform.system() == "Darwin":
        cmd = ["/usr/bin/time", "-l"] + cmd
    else:
        cmd = ["/usr/bin/time", "-v"] + cmd
    t0 = time.perf_counter()
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return dict(status=f"TIMEOUT>{TIMEOUT:.0f}s", ms=TIMEOUT * 1000, rss=None, out="")
    ms = (time.perf_counter() - t0) * 1000
    err = p.stderr.decode("utf-8", "replace")
    rss = None
    m = re.search(r"(\d+)\s+maximum resident set size", err)
    if m:
        rss = int(m.group(1)) / (1 << 20)
    m = re.search(r"Maximum resident set size \(kbytes\): (\d+)", err)
    if m:
        rss = int(m.group(1)) / 1024
    status = "ok"
    sig = re.search(r"terminated by signal (\d+)|Command terminated by signal (\d+)", err)
    if p.returncode != 0 or sig:
        status = f"CRASH(rc={p.returncode}{', sig=' + (sig.group(1) or sig.group(2)) if sig else ''})"
    detail = [l for l in err.splitlines() if l.startswith("error")]
    return dict(status=status, ms=ms, rss=rss, out=p.stdout.decode("utf-8", "replace").strip(),
                err=(detail[0][:120] if detail else ""))


def main():
    rows = []
    for i, sc in enumerate(scenarios()):
        if ONLY and ONLY not in sc["name"]:
            continue
        patf = wfile("pat_" + hashlib.sha256(sc["pat"].encode()).hexdigest()[:16] + ".txt", sc["pat"])
        hay = sc.get("hay")
        iters = sc.get("iters", 1)
        rp = run(PION, sc["mode"], patf, hay, iters)
        rr = run(RUST, sc["mode"], patf, hay, iters)
        same = rp["out"] == rr["out"] and rp["status"] == "ok" and rr["status"] == "ok"
        row = dict(name=sc["name"], pion=rp, rust=rr, identical=same)
        rows.append(row)
        f = lambda r: f"{r['status']:>8} {r['ms']:9.1f}ms {('%.1fMiB' % r['rss']) if r['rss'] else '-':>9} {r['out'][:60]}"
        print(f"{'OK ' if same else 'DIF'} {sc['name']}\n    pion {f(rp)} {rp.get('err','')}\n    rust {f(rr)} {rr.get('err','')}", flush=True)
    if MD:
        with open(MD, "w", encoding="utf-8") as fh:
            fh.write("| scenario | pion status | pion ms | pion RSS | rust status | rust ms | rust RSS | pion/rust time | stdout identical |\n")
            fh.write("| --- | --- | ---: | ---: | --- | ---: | ---: | ---: | :---: |\n")
            for r in rows:
                p, q = r["pion"], r["rust"]
                ratio = (p["ms"] / q["ms"]) if q["ms"] else 0
                rs = lambda x: ("%.1f MiB" % x) if x else "-"
                fh.write(f"| `{r['name']}` | {p['status']} | {p['ms']:.1f} | {rs(p['rss'])} | {q['status']} | {q['ms']:.1f} | {rs(q['rss'])} | {ratio:.2f}x | {'yes' if r['identical'] else '**NO**'} |\n")
    json.dump(rows, open(os.path.join(OUT, "stress.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
