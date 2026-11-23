"""DoS / complexity / crash probes: Pion vs Rust html5ever(scraper)/ammonia vs Go x/net/html.

Each probe = (name, generator, op). Every implementation runs once as a separate process under
/usr/bin/time -l (wall seconds + peak RSS); the per-process timeout is TIMEOUT seconds.
Scaling probes are run at N and 2N so the growth ratio (≈2 linear, ≈4 quadratic) is visible.
Usage: dos.py [--quick] [--json out.json]
"""
import json, os, re, signal, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, PION, RUST, GO

TIMEOUT = int(os.environ.get("DOS_TIMEOUT", "60"))


def timed(cmd):
    t0 = time.time()
    p = subprocess.Popen(["/usr/bin/time", "-l"] + cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         start_new_session=True)
    try:
        so, se = p.communicate(timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)  # kill /usr/bin/time AND the probe it spawned
        p.communicate()
        return {"status": f"TIMEOUT>{TIMEOUT}s", "secs": TIMEOUT, "rss_mb": None, "out": ""}
    dt = time.time() - t0
    r = subprocess.CompletedProcess(cmd, p.returncode, so, se)
    m = re.search(rb"(\d+)\s+maximum resident set size", r.stderr)
    rss = round(int(m.group(1)) / 1048576, 1) if m else None
    out = r.stdout.decode(errors="replace").strip()[:120]
    status = "ok" if r.returncode == 0 else f"CRASH rc={r.returncode}"
    if r.returncode < 0 or r.returncode > 128:
        status = f"CRASH signal {r.returncode}"
    return {"status": status, "secs": round(dt, 3), "rss_mb": rss, "out": out}


def nested(tag, n, close=True):
    return f"<{tag}>" * n + "x" + (f"</{tag}>" * n if close else "")


def probes(scale):
    N = 50000 * scale
    P = [
        ("nested_div_50k", lambda k: nested("div", N * k), "parse"),
        ("nested_div_then_stray_end_span", lambda k: "<div>" * (N * k // 2) + "</span>" * (N * k // 2), "parse"),
        ("unclosed_b_50k", lambda k: "<b>" * (N * k) + "x", "parse"),
        ("adoption_clone_amplify_MxN", lambda k: "<i>" * (500 * k) + "<b>" * 500 + "</i>" * (500 * k), "parse"),
        ("adoption_clone_amplify_sanitize", lambda k: "<i>" * (500 * k) + "<b>" * 500 + "</i>" * (500 * k), "san"),
        ("nested_table_tr_td_50k", lambda k: "<table><tr><td>" * (N * k // 3), "parse"),
        ("attr_dup_100KB", lambda k: "<a " + "a=a " * (25000 * k) + ">", "parse"),
        ("attr_distinct_50k", lambda k: "<a " + "".join(f"a{i}=1 " for i in range(N * k // 2)) + ">", "parse"),
        ("amp_entities_100KB", lambda k: "&amp;" * (20000 * k), "parse"),
        ("bare_amps_100KB", lambda k: "&" * (100000 * k), "parse"),
        ("bare_lt_100KB", lambda k: "<" * (100000 * k), "parse"),
        ("comment_10MB", lambda k: "<!--" + "a-" * (5000000 * k) + "-->", "parse"),
        ("nested_a_50k", lambda k: "<a>" * (N * k), "parse"),
        ("nested_p_in_span", lambda k: "<span>" * (N * k // 2) + "<p>" * (N * k // 2), "parse"),
        ("nested_div_sanitize", lambda k: nested("div", N * k // 2), "san"),
        ("stray_end_sanitize", lambda k: "<div>" * (N * k // 2) + "</span>" * (N * k // 2), "san"),
        ("deep_div_selector_backtrack_d60",
         lambda k: "<div>" * (60 * k) + "<p>x</p>",
         "sel:section div div div div div p"),
        ("wide_selector_backtrack_d40_w",
         lambda k: ("<div>" * (40 * k) + "<p>x</p>" + "</div>" * (40 * k)) * 50,
         "sel:section div div div div p"),
        ("sibling_selector_backtrack",
         lambda k: "<div>" + "<p></p>" * (2000 * k) + "</div>",
         "sel:h1 ~ p ~ p ~ p"),
    ]
    return P


def main():
    quick = "--quick" in sys.argv
    res = []
    for name, gen, op in probes(1):
        row = {"probe": name, "op": op}
        for k in ((1,) if quick else (1, 2)):
            src = gen(k)
            path = os.path.join(TMP, f"dos_{name}_{k}.html")
            open(path, "w").write(src)
            row[f"bytes_x{k}"] = len(src.encode())
            impls = [("pion", [PION, "one", path, op])]
            if op in ("parse", "frag", "san") or op.startswith("sel:"):
                impls.append(("rust", [RUST, "one", path, op]))
            if op in ("parse", "frag"):
                impls.append(("go", [GO, "one", path, op]))
            for impl, cmd in impls:
                row[f"{impl}_x{k}"] = timed(cmd)
            os.unlink(path)
        res.append(row)
        def fmt(r):
            return f"{r['status']:>14s} {r['secs']:8.3f}s {str(r['rss_mb']):>7s}MB" if r else "-"
        print(f"{name:38s} {op:32s} bytes={row['bytes_x1']}")
        for impl in ("pion", "rust", "go"):
            if f"{impl}_x1" in row:
                line = f"   {impl:5s} x1: {fmt(row[impl + '_x1'])} {row[impl + '_x1']['out'][:50]}"
                if f"{impl}_x2" in row:
                    a, b = row[impl + "_x1"]["secs"], row[impl + "_x2"]["secs"]
                    line += f" | x2: {fmt(row[impl + '_x2'])} growth={b / max(a, 1e-3):.1f}"
                print(line)
        sys.stdout.flush()
    if "--json" in sys.argv:
        json.dump(res, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
