"""DoS / complexity / crash probes: Pion (native release) vs Rust cssparser =0.35.0 (generic AST oracle),
lightningcss 1.0.0-alpha.72 and Node css-tree@3.1.0.

Every implementation runs once per probe as its own process under /usr/bin/time -l (wall seconds + peak
RSS, TIMEOUT per process). Scaling probes run at N and 2N: growth ≈2 is linear, ≈4 quadratic.
Usage: dos.py [--quick] [--json out.json]
"""
import json, os, re, signal, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, PION, RUST, NODE_ORACLE, NODE_MODULES

TIMEOUT = int(os.environ.get("DOS_TIMEOUT", "60"))


def timed(cmd):
    t0 = time.time()
    p = subprocess.Popen(["/usr/bin/time", "-l"] + cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         start_new_session=True, env=dict(os.environ, NODE_PATH=NODE_MODULES))
    try:
        so, se = p.communicate(timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return {"status": f"TIMEOUT>{TIMEOUT}s", "secs": TIMEOUT, "rss_mb": None, "out": ""}
    dt = time.time() - t0
    m = re.search(rb"(\d+)\s+maximum resident set size", se)
    rss = round(int(m.group(1)) / 1048576, 1) if m else None
    out = so.decode(errors="replace").strip()[:70]
    status = "ok" if p.returncode == 0 else f"CRASH rc={p.returncode}"
    if p.returncode == 0 and out.startswith("ERR"):
        status = "error-result"
    if p.returncode != 0:
        tail = se.decode(errors="replace")
        if "stack overflow" in tail or "has overflowed its stack" in tail:
            status = "CRASH stack-overflow (SIGABRT)"
        elif p.returncode in (-11, 139) or "Segmentation" in tail:
            status = "CRASH SIGSEGV"
    return {"status": status, "secs": round(dt, 3), "rss_mb": rss, "out": out}


def rep(s, n):
    return s * n


# (name, generator(k) -> str, [(impl, mode)]); k = 1 or 2 (size multiplier)
PARSE = [("pion", "parse"), ("rust", "sheet"), ("lcss", "lparse"), ("node", "parse")]
TOK = [("pion", "tokn"), ("rust", "tokcount"), ("node", "tokcount")]
MIN = [("pion", "min"), ("lcss", "lmin")]


def probes(N):
    return [
        ("nested_curly_50k", lambda k: rep("a{", N * k) + rep("}", N * k), PARSE + TOK),
        ("nested_paren_in_value_50k", lambda k: ".a{width:" + rep("(", N * k) + "1px" + rep(")", N * k) + "}", PARSE),
        ("nested_square_50k", lambda k: ".a{x:" + rep("[", N * k) + rep("]", N * k) + "}", PARSE),
        ("nested_media_50k", lambda k: rep("@media all{", N * k) + rep("}", N * k), PARSE),
        ("nested_is_selector_50k", lambda k: rep(":is(", N * k) + "a" + rep(")", N * k) + "{x:y}", PARSE),
        ("nested_calc_50k", lambda k: ".a{width:" + rep("calc(1px + ", N * k) + "1px" + rep(")", N * k) + "}", PARSE + MIN),
        ("nested_depth_250_x_2k_rules", lambda k: rep(rep("a{", 250) + "b:c;" + rep("}", 250), 200 * k), PARSE + MIN),
        ("many_custom_props_1rule", lambda k: ".a{" + "".join(f"--v{i}: {i}px ;" for i in range(N * 2 * k)) + "}", PARSE + MIN),
        ("many_decls_1rule", lambda k: ".a{" + rep("color:red;", N * 2 * k) + "}", PARSE + MIN),
        ("huge_selector_list", lambda k: ",".join(f".s{i} > a:hover" for i in range(N * k)) + "{x:y}", PARSE + MIN),
        ("many_short_rules_minify", lambda k: rep(".a{b:0px}", N * 2 * k), MIN + PARSE),
        ("unclosed_comment_10MB", lambda k: "/*" + rep("a*", 2_500_000 * k), TOK + PARSE),
        ("unclosed_string_10MB", lambda k: ".a{content:'" + rep("a", 5_000_000 * k), TOK + PARSE),
        ("escape_run_1MB", lambda k: ".a{content:x" + rep("\\41 ", 250_000 * k) + "}", TOK + PARSE),
        ("bad_url_remnants", lambda k: rep("url(a b", N * k), TOK + PARSE),
        ("unicode_range_like", lambda k: rep("u+a ", N * 4 * k), TOK),
        ("stray_close_braces", lambda k: rep("}", N * 4 * k) + "a{b:c}", PARSE),
        ("top_level_semicolons", lambda k: rep("a;", N * 4 * k) + "b{c:d}", PARSE),
        ("deep_not_selector_255_x_rules", lambda k: rep(rep(":not(", 120) + "a" + rep(")", 120) + "{x:y}", 400 * k), PARSE + MIN),
        ("realistic_6MB_tailwind_like", lambda k: "".join(
            f".c{i}{{display:flex;margin:0px auto;padding:.5rem 1rem;color:#fff}}\n@media (min-width:768px){{.md\\:c{i}{{width:calc(100% - 2rem)}}}}\n"
            for i in range(45_000 * k)), PARSE + MIN + TOK),
    ]


def cmd(impl, mode, path):
    if impl == "pion":
        return [PION, "one", path, mode]
    if impl in ("rust", "lcss"):
        return [RUST, "one", path, mode]
    return ["node", NODE_ORACLE, "one", path, mode]


def main():
    quick = "--quick" in sys.argv
    N = 50000
    sizes = [1] if quick else [1, 2]
    res = {}
    print(f"{'probe':38s} {'impl/mode':16s} {'k':>2s} {'status':32s} {'secs':>8s} {'RSS MB':>8s}  growth  result")
    for name, g, impls in probes(N):
        paths = {}
        for k in sizes:
            path = os.path.join(TMP, f"dos_{name}_{k}.css")
            with open(path, "w") as f:
                f.write(g(k))
            paths[k] = path
        for impl, mode in impls:
            prev = None
            for k in sizes:
                r = timed(cmd(impl, mode, paths[k]))
                growth = ""
                if prev and prev["status"] == "ok" and r["status"] == "ok" and prev["secs"] > 0.05:
                    growth = f"{r['secs'] / prev['secs']:.1f}x"
                print(f"{name:38s} {impl + '/' + mode:16s} {k:2d} {r['status']:32s} {r['secs']:8.3f} {str(r['rss_mb']):>8s}  {growth:6s}  {r['out'][:40]}")
                res[f"{name}/{impl}/{mode}/{k}"] = dict(r, growth=growth)
                prev = r
        for p in paths.values():
            os.unlink(p)
    if len(sys.argv) > 2 and "--json" in sys.argv:
        json.dump(res, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
