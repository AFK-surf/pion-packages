#!/usr/bin/env python3
"""Pathological-input scaling benchmark: Rust pulldown-cmark 0.13.1 vs Pion (direct + Event-API paths).

usage: patho_bench.py <rust_ref_bin> <pion_harness_bin> <work_dir> [--sizes 1000,2000,4000,8000] [--timeout 30] [--only name,...]
For every generator and size N: wall time (min of R runs), peak RSS, exit status, and whether the
HTML outputs are byte-identical.  Reports the empirical scaling exponent k (time ~ N^k) between the
two largest completed sizes and the Pion/Rust slowdown at the largest size.
"""
import json, math, os, platform, subprocess, sys, time

RUST, PION, WORK = sys.argv[1:4]
arg = lambda k, d: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else d
SIZES = [int(x) for x in arg("--sizes", "1000,2000,4000,8000,16000").split(",")]
TIMEOUT = float(arg("--timeout", "30"))
ONLY = set(arg("--only", "").split(",")) - {""}
os.makedirs(WORK, exist_ok=True)

CM, GFM, SMART = 0, 7, 23
G = {  # name: (mask, generator)  -- first block = cmark's test/pathological_tests.py
    "nested_strong_emph": (CM, lambda n: "*a **a " * n + "b" + " a** a*" * n),
    "emph_closers_no_openers": (CM, lambda n: "a_ " * n),
    "emph_openers_no_closers": (CM, lambda n: "_a " * n),
    "link_closers_no_openers": (CM, lambda n: "a]" * n),
    "link_openers_no_closers": (CM, lambda n: "[a" * n),
    "mismatched_openers_closers": (CM, lambda n: "*a_ " * n),
    "openers_closers_mult_of_3": (CM, lambda n: "a**b" + "c* " * n),
    "link_openers_emph_closers": (CM, lambda n: "[ a_" * n),
    "pattern_[(](": (CM, lambda n: "[ (](" * n),
    "nested_brackets": (CM, lambda n: "[" * n + "a" + "]" * n),
    "nested_block_quotes": (CM, lambda n: "> " * n + "a\n"),
    "backticks_increasing": (CM, lambda n: "".join("e" + "`" * i for i in range(1, int(math.sqrt(n) * 4)))),
    "unclosed_links_A": (CM, lambda n: "[a](<b" * n),
    "unclosed_links_B": (CM, lambda n: "[a](b" * n),
    "unclosed_comments": (CM, lambda n: "</" + "<!--" * n),
    "many_link_refs_lookups": (CM, lambda n: "".join(f"[l{i}]: /u{i}\n" for i in range(n)) + "\n" + " ".join(f"[l{i}]" for i in range(n)) + "\n"),
    "nested_inline_links": (CM, lambda n: "[" * n + "a" + "](b)" * n),
    "nested_images": (CM, lambda n: "![" * n + "a" + "](b)" * n),
    "deep_list_inline": (CM, lambda n: "- " * n + "a\n"),
    "deep_ordered_inline": (CM, lambda n: "1. " * n + "a\n"),
    "deep_list_lines": (CM, lambda n: "".join(" " * (2 * (i % 200)) + "- a\n" for i in range(n))),
    "html_block_start_spam": (CM, lambda n: "<div>\n" * n),
    "inline_html_unclosed": (CM, lambda n: "<a " * n),
    "entities": (CM, lambda n: "&amp;&#x41;&#65;&nbsp;" * n),
    "escapes": (CM, lambda n: "\\*\\_\\[" * n),
    "hard_breaks": (CM, lambda n: "a  \n" * n),
    "setext_long_para": (CM, lambda n: "a\n" * n + "===\n"),
    "code_span_unmatched_runs": (CM, lambda n: "`" * n + "a"),
    "code_spans_many": (CM, lambda n: "`a` " * n),
    "emph_many_balanced": (CM, lambda n: "*a* **b** " * n),
    "underscore_intraword": (CM, lambda n: "a_b" * n),
    "link_dest_parens": (CM, lambda n: "[a](" + "(" * n + ")" * n + ")"),
    "link_title_unclosed": (CM, lambda n: '[a](b "' * n),
    "autolink_angle_unclosed": (CM, lambda n: "<http://a" * n),
    "ref_def_label_long_unclosed": (CM, lambda n: "[" + "a" * n + "\n"),
    "many_ref_defs_unused": (CM, lambda n: "".join(f"[d{i}]: /x\n" for i in range(n))),
    # GFM extensions
    "table_rows": (GFM, lambda n: "|a|b|\n|-|-|\n" + "|x|y|\n" * n),
    "table_wide": (GFM, lambda n: "|a" * n + "|\n" + "|-" * n + "|\n" + "|x" * n + "|\n"),
    "table_rows_overflow_cells": (GFM, lambda n: "|a|\n|-|\n" + ("|x" * 50 + "|\n") * (n // 10)),
    "table_header_no_delim": (GFM, lambda n: "|a|b|\n" * n),
    "table_escaped_pipes": (GFM, lambda n: "|a|\n|-|\n" + "|" + "\\|" * n + "|\n"),
    "strike_unclosed": (GFM, lambda n: "~~a " * n),
    "strike_single_unclosed": (GFM, lambda n: "~a " * n),
    "strike_nested": (GFM, lambda n: "~~a " * n + "b" + " a~~" * n),
    "tasklist_many": (GFM, lambda n: "- [x] a\n" * n),
    "smart_quotes_unmatched": (SMART, lambda n: "'a \"b " * n),
    "smart_quotes_nested": (SMART, lambda n: "\"'" * n + "a" + "'\"" * n),
    "smart_dashes": (SMART, lambda n: "--- -- ... " * n),
    "cjk_emph": (GFM, lambda n: "中**文**字*字*" * n),
    "mixed_star_underscore_tilde": (GFM, lambda n: "*_~" * n),
}


def run(cmd, path):
    best, rss, rc, out = None, 0, 0, b""
    reps = 3
    for _ in range(reps):
        t0 = time.perf_counter()
        p = subprocess.Popen(cmd + [path] if False else cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            out, _ = p.communicate(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            p.kill()
            p.communicate()
            return None, rss, "timeout", b""
        _, status, ru = os.wait4(p.pid, 0) if False else (0, p.returncode, None)
        dt = time.perf_counter() - t0
        rc = p.returncode
        best = dt if best is None else min(best, dt)
        if rc != 0 or dt > 2.0:
            break
    return best, rss, rc, out


def rss_of(cmd):
    # peak RSS via wait4 on a separate run (bytes)
    p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        _, _, ru = os.wait4(p.pid, 0)
    except ChildProcessError:
        return 0
    m = ru.ru_maxrss
    return m if platform.system() == "Darwin" else m * 1024


def main():
    results = []
    for name, (mask, gen) in G.items():
        if ONLY and name not in ONLY:
            continue
        rows = []
        dead = set()
        for n in SIZES:
            src = gen(n)
            path = os.path.join(WORK, f"{name}.md")
            open(path, "w", encoding="utf-8").write(src)
            row = {"n": n, "bytes": len(src.encode())}
            outs = {}
            for impl, cmd in (("rust", [RUST, "html", path, str(mask)]),
                              ("pion_direct", [PION, "direct", path, str(mask)]),
                              ("pion_events", [PION, "events", path, str(mask)])):
                if impl in dead:
                    row[impl] = {"skipped": True}
                    continue
                t, _, rc, out = run(cmd, path)
                r = {"s": t, "rc": rc}
                if rc == 0 and t is not None and t < 5:
                    r["rss"] = rss_of(cmd)
                row[impl] = r
                outs[impl] = out
                if rc != 0 or t is None or t > TIMEOUT / 3:
                    dead.add(impl)
            if "rust" in outs and "pion_direct" in outs and row["pion_direct"].get("rc") == 0:
                row["same_html"] = outs["rust"] == outs["pion_direct"]
            rows.append(row)
        res = {"name": name, "mask": mask, "rows": rows}
        for impl in ("rust", "pion_direct", "pion_events"):
            ok = [r for r in rows if r[impl].get("rc") == 0 and r[impl].get("s")]
            if len(ok) >= 2:
                a, b = ok[-2], ok[-1]
                ta, tb = max(a[impl]["s"], 1e-3), max(b[impl]["s"], 1e-3)
                res[f"k_{impl}"] = round(math.log(tb / ta) / math.log(b["bytes"] / a["bytes"]), 2)
        last = rows[-1]
        if last["rust"].get("s") and last["pion_direct"].get("s"):
            res["slowdown_direct"] = round(last["pion_direct"]["s"] / last["rust"]["s"], 1)
        fails = [(r["n"], impl, r[impl]["rc"]) for r in rows for impl in ("pion_direct", "pion_events")
                 if r[impl].get("rc") not in (0, None)]
        res["pion_failures"] = fails
        results.append(res)
        lr = rows[-1]
        fmt = lambda x: "—" if not x or x.get("s") is None else f"{x['s'] * 1000:9.1f}ms"
        print(f"{name:32s} N={lr['n']:6d} {lr['bytes']:9d}B rust={fmt(lr['rust'])} direct={fmt(lr['pion_direct'])} "
              f"events={fmt(lr['pion_events'])} k(rust/dir/evt)={res.get('k_rust')}/{res.get('k_pion_direct')}/{res.get('k_pion_events')} "
              f"x{res.get('slowdown_direct')} {'FAIL ' + str(fails) if fails else ''}", flush=True)
    json.dump(results, open(os.path.join(WORK, "patho_results.json"), "w"), indent=1)


main()
