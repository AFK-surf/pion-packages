#!/usr/bin/env python3
"""Adversarial GlobSet benchmark: Pion vs real Rust globset (same rules, same paths, stdout hash-checked).
usage: adversarial_bench.py <pion_driver> <rust_oracle> <out_dir> [--quick]
Times are user+sys CPU ms (the shared host is loaded, wall time is not comparable).
Each run is killed at TIME_LIMIT wall seconds or RSS_LIMIT bytes and reported as such."""
import hashlib, json, os, random, signal, statistics, subprocess, sys, time

TIME_LIMIT = 60.0
RSS_LIMIT = 6 * 1024**3
ROUNDS = 3


def paths_real(n, seed=1, tail=""):
    r = random.Random(seed)
    dirs = ["src", "lib", "pkg", "vendor", "node_modules", "target", "build", "docs", "tests", "cmd", "internal", "app"]
    subs = ["core", "util", "net", "io", "ui", "db", "auth", "api", "model", "view", "cache", "x%d"]
    exts = ["rs", "go", "py", "js", "ts", "c", "h", "md", "json", "toml", "txt", "o"]
    out = []
    for i in range(n):
        d = [r.choice(dirs)] + [(lambda s: s % r.randrange(50) if "%" in s else s)(r.choice(subs)) for _ in range(r.randint(1, 6))]
        out.append("/".join(d) + f"/file{r.randrange(5000)}{tail}.{r.choice(exts)}")
    return out


def complex_rules(n, seed=2):
    """Real-world-shaped wildcard rules none of which fit a literal/ext/prefix fast table."""
    r = random.Random(seed)
    words = ["core", "util", "net", "io", "ui", "db", "auth", "api", "model", "view", "cache", "file", "test", "gen", "tmp"]
    out = []
    for i in range(n):
        a, b = r.choice(words), r.choice(words)
        out.append(r.choice([
            f"**/{a}*/**/*{b}{i}*.rs", f"src/*/{a}*/**/file{i}*", f"**/{a}/*{i}/*.[ch]", f"*/{b}?/**/{a}{i}.*",
            f"{{src,lib}}/**/{a}{i}*/*.{{rs,go}}", f"**/*{a}*{b}*{i}", f"pkg/**/[a-f]*{i}/*.py", f"**/{b}/**/{a}/**/x{i}*",
        ]))
    return out


def workloads(quick):
    base = paths_real(5000)
    w = []
    sizes = [100, 500, 2000] if quick else [100, 500, 2000, 5000]
    for n in sizes:
        w.append((f"complex_rules_{n}", complex_rules(n), base if n <= 500 else base[:1000], 1))
    for n in ([500] if quick else [500, 2000]):
        w.append((f"complex_rules_{n}_cjk_paths", [x for x in complex_rules(n) if "?" not in x and "[" not in x], paths_real(5000 if n <= 500 else 1000, 3, "中文"), 1))
    for n in ([2000] if quick else [2000, 20000]):
        w.append((f"long_prefix_{n}", [f"org{i}/monorepo/services/backend/components/generated/module{i}/**" for i in range(n)], base[:5000], 1))
        w.append((f"long_suffix_{n}", [f"**/components/generated/module{i}/internal/implementation/details.rs" for i in range(n)], base[:5000], 1))
    n = 3000
    hit = "src/core/hit.rs"
    rules = []
    for i in range(n):
        rules.append(["*.rs", "src/**", "**/hit.rs", "**/*.rs", f"s*{'' if i % 2 else '*'}"][i % 5])
    w.append(("all_rules_hit_3000x", rules, [hit] * 2000, 1))
    a = "a" * 5000
    w.append(("redos_star_a_x12_5k_path", ["*a" * 12 + "*b"], [a] * 200, 1))
    w.append(("redos_star_a_x50_5k_path", ["*a" * 50 + "*b"], [a] * 20, 1))
    w.append(("redos_doublestar_x12", ["**/a/" * 12 + "b"], ["/".join(["a"] * 1000)] * 50, 1))
    w.append(("brace_bomb_20_groups", ["{a,b}" * 20], ["ab" * 10, "a" * 20, "c" * 20] * 3000, 1))
    w.append(("brace_bomb_nested_90", ["{a," * 90 + "b" + "}" * 90], ["a", "b", "c"] * 5000, 1))
    w.append(("dfa_cap_blowup_x200", [f"**/a{'?' * 14}{i}" for i in range(200)], base[:3000], 1))
    return w


def run(cmd, out_path):
    t0 = time.perf_counter()
    with open(out_path, "wb") as out:
        p = subprocess.Popen(cmd, stdout=out, stderr=subprocess.DEVNULL)
    peak, status, ru = 0, "ok", None
    next_rss = 0.0
    while True:
        pid, st, ru = os.wait4(p.pid, os.WNOHANG)
        if pid:
            if st != 0:
                status = status if status != "ok" else f"exit:{os.waitstatus_to_exitcode(st)}"
            break
        now = time.perf_counter() - t0
        if now > next_rss:
            next_rss = now + 0.05
            r = subprocess.run(["ps", "-o", "rss=", "-p", str(p.pid)], capture_output=True, text=True).stdout.strip()
            if r:
                peak = max(peak, int(r) * 1024)
        if now > TIME_LIMIT or peak > RSS_LIMIT:
            status = "TIMEOUT" if now > TIME_LIMIT else "OOM_GUARD"
            os.kill(p.pid, signal.SIGKILL)  # not p.kill(): it polls and would reap before wait4
            _, st, ru = os.wait4(p.pid, 0)
            p.returncode = -9
            break
        time.sleep(0.002)
    ms = (ru.ru_utime + ru.ru_stime) * 1000
    rss = max(peak, ru.ru_maxrss if sys.platform == "darwin" else ru.ru_maxrss * 1024)
    return ms, rss, status, hashlib.sha256(open(out_path, "rb").read()).hexdigest()


def measure(tool, mode, rf, pf, od):
    res = []
    for _ in range(ROUNDS):
        r = run([tool, "bench", mode, rf, pf, "1"], os.path.join(od, "o.txt"))
        res.append(r)
        if r[2] != "ok" or r[0] > 8000:  # long runs: one round is enough
            break
    bad = [x for x in res if x[2] != "ok"]
    if bad:
        return dict(ms=bad[0][0], rss=max(x[1] for x in res), status=bad[0][2], hash=None)
    return dict(ms=statistics.median(x[0] for x in res), rss=max(x[1] for x in res), status="ok", hash=res[0][3])


def fmt(x):
    if x["status"] != "ok":
        return f"**{x['status']}** (>{x['ms']:.0f} CPU ms, {x['rss'] / 1048576:.0f} MiB)"
    return f"{x['ms']:.1f} ms / {x['rss'] / 1048576:.1f} MiB"


def main():
    pion, rust, od = sys.argv[1:4]
    quick = "--quick" in sys.argv
    os.makedirs(od, exist_ok=True)
    rows = []
    lines = ["| workload | rules | phase | Pion | Rust globset | time Pion/Rust | RSS Pion/Rust | stdout |", "|---|---:|---|---:|---:|---:|---:|---|"]
    for name, rules, paths, _ in workloads(quick):
        rf, pf = os.path.join(od, "rules.txt"), os.path.join(od, "paths.txt")
        open(rf, "w").write("\n".join(rules) + "\n")
        open(pf, "w").write("\n".join(paths) + "\n")
        for mode in ("build", "match"):
            p = measure(pion, mode, rf, pf, od)
            r = measure(rust, mode, rf, pf, od)
            tr = p["ms"] / r["ms"] if r["ms"] else 0
            mr = p["rss"] / r["rss"] if r["rss"] else 0
            same = "n/a" if not (p["hash"] and r["hash"]) else ("same" if p["hash"] == r["hash"] else "DIFF")
            prefix = ">" if p["status"] != "ok" else ""
            lines.append(f"| {name} | {len(rules)} | {mode} | {fmt(p)} | {fmt(r)} | {prefix}{tr:.2f}× | {mr:.2f}× | {same} |")
            rows.append(dict(name=name, rules=len(rules), paths=len(paths), mode=mode, pion=p, rust=r, time_ratio=tr, rss_ratio=mr, stdout=same))
            print(lines[-1], flush=True)
    json.dump(rows, open(os.path.join(od, "bench.json"), "w"), indent=1)
    open(os.path.join(od, "bench.md"), "w").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
