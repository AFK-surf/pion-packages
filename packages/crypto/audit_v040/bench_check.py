"""RT-crypto-v040 benchmark reproduction + workload-sizing gate for the two v0.4.0 KDF benchmarks.

(Adapted from audit_v030/bench_check.py, which stays untouched.)

1. Builds the repository's own `packages/crypto/bench` programs (Pion --release, Go x/crypto) into
   /private/tmp/rt-crypto-v040-bench (go.mod/go.sum/main.go are copied there; the worktree is never
   written), checks stdout SHA-256 parity and reruns `scripts/bench_compare.py --warmup 1 --rounds 5`
   for pbkdf2_sha256 and scrypt exactly as `bench/run_bench.sh` (BENCH 13 / 14) does.
2. Measures each binary's fixed process cost (spawn + runtime init + exit, via its usage path) and
   its share of the Go end-to-end time.
3. Re-measures the same workloads scaled up in-process (`audit_v040/oracle bench <mode> <n>` vs
   `audit_v040/go bench <mode> <n>`, identical inputs and identical stdout SHA-256 as the repository
   bench at the same n) so that start-up is < 5% of either side: the honest Pion/Go ratio.
4. Gate: a head-to-head row is misleading when its Pion/Go ratio overstates the
   in-process (start-up-free) ratio by 2x or more, which happens when the Go side is mostly process
   start-up. Fix = raise the iteration counts in bench/{pion_bench,go} (and the README table) until
   both sides run >> 10 ms of real work; nothing here needs to change. (The ratio-of-ratios is used
   rather than the raw start-up share because it stays stable on a loaded machine.)

Usage: python3 bench_check.py   (exit 0 = no misleading row; needs run_audit.sh build first)
"""
import hashlib
import json
import os
import shutil
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(PKG))
OUT = "/private/tmp/rt-crypto-v040-bench"
MODES = [  # mode, bench_compare size flag, gated, scaled n, scaled size flag
    ("pbkdf2_sha256", ["--ops", "500000"], True, 4000000, ["--ops", "4000000"]),
    ("scrypt", ["--ops", "4"], True, 32, ["--ops", "32"]),
]
ORACLE = os.environ.get("RT_ORACLE", "/private/tmp/rt-crypto-v040-out/bin/oracle_native_rel")
GO_ORACLE = os.environ.get("RT_GO_ORACLE", "/private/tmp/rt-crypto-v040-out/bin/go_oracle")
SAMPLES = int(os.environ.get("RT_BENCH_SAMPLES", "15"))


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def wall_ms(cmd, n):
    xs = []
    for _ in range(n):
        t = time.perf_counter()
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        xs.append((time.perf_counter() - t) * 1000.0)
    return statistics.median(xs)


def main():
    env = dict(os.environ)
    env["PATH"] = os.path.expanduser("~/.pion/bin") + os.pathsep + env.get("PATH", "")
    env["PION_CACHE_DIR"] = OUT + "-cas"
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(os.path.join(OUT, "go"))
    pion = os.path.join(OUT, "pion_bench")
    gob = os.path.join(OUT, "go_bench")
    run(["pionc", "build", "--release", "-o", pion, os.path.join(PKG, "bench", "pion_bench")], env=env,
        stdout=subprocess.DEVNULL)
    for f in ("go.mod", "go.sum", "main.go"):
        src = os.path.join(PKG, "bench", "go", f)
        if os.path.exists(src):
            shutil.copy(src, os.path.join(OUT, "go", f))
    genv = dict(env, GOFLAGS="-mod=mod", GOPROXY=env.get("GOPROXY", "off"))
    run(["go", "build", "-o", gob, "."], cwd=os.path.join(OUT, "go"), env=genv)

    noop_pion = wall_ms([pion, "rt-noop"], SAMPLES)
    noop_go = wall_ms([gob, "rt-noop"], SAMPLES)
    print("fixed process cost (usage path, median of %d): pion %.2f ms, go %.2f ms" % (SAMPLES, noop_pion, noop_go))
    print("| workload | stdout sha256 | pion median | go median | repo ratio (Pion/Go speed) | go fixed-cost share |")
    print("| --- | --- | ---: | ---: | ---: | ---: |")
    ok = True
    scaled = []
    for mode, size, gated, sn, ssize in MODES:
        hp = hashlib.sha256(subprocess.run([pion, mode], stdout=subprocess.PIPE).stdout).hexdigest()
        hg = hashlib.sha256(subprocess.run([gob, mode], stdout=subprocess.PIPE).stdout).hexdigest()
        if hp != hg:
            print("| %s | MISMATCH pion %s go %s | | | | | | FAIL |" % (mode, hp[:12], hg[:12]))
            ok = False
            continue
        js = os.path.join(OUT, "bench_%s.json" % mode)
        run([sys.executable, os.path.join(ROOT, "scripts", "bench_compare.py"), "--title", "rt-v040 " + mode,
             "--impl", "pion=%s %s" % (pion, mode), "--impl", "go_xcrypto=%s %s" % (gob, mode),
             "--baseline", "go_xcrypto", "--warmup", "1", "--rounds", "5"] + size +
            ["--json-out", js, "--md-out", os.path.join(OUT, "bench_%s.md" % mode)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        data = json.load(open(js))
        med = {}
        for r in data["results"]:
            med[r["name"]] = r["median_ms"]
        p_med, g_med = med["pion"], med["go_xcrypto"]
        # Direct timing for the share (same method as the fixed-cost measurement).
        g_dir = wall_ms([gob, mode], max(5, SAMPLES // 2))
        share = noop_go / g_dir
        print("| %s | %s | %.3f ms | %.3f ms | %.3fx | %.0f%% |" % (
            mode, hp[:16], p_med, g_med, g_med / p_med, share * 100))
        scaled.append((mode, sn, ssize, g_med / p_med, gated))
    print()
    print("scaled in-process re-measurement (bench_compare --warmup 1 --rounds 5, stdout SHA-256 checked):")
    print("| workload | n | pion median | go median | pion rate | go rate | honest ratio | repo ratio | overstated by | gate |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
    for mode, sn, ssize, repo_ratio, gated in scaled:
        js = os.path.join(OUT, "scaled_%s.json" % mode)
        run([sys.executable, os.path.join(ROOT, "scripts", "bench_compare.py"), "--title", "rt-v040 scaled " + mode,
             "--impl", "pion=%s bench %s %d" % (ORACLE, mode, sn), "--impl", "go_xcrypto=%s bench %s %d" % (GO_ORACLE, mode, sn),
             "--baseline", "go_xcrypto", "--warmup", "1", "--rounds", "5"] + ssize +
            ["--json-out", js, "--md-out", os.path.join(OUT, "scaled_%s.md" % mode)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        med = {r["name"]: r["median_ms"] for r in json.load(open(js))["results"]}
        p_med, g_med = med["pion"], med["go_xcrypto"]
        if ssize[0] == "--bytes":
            rate = lambda ms: "%.1f MB/s" % (int(ssize[1]) / (ms / 1000.0) / 1e6)
        else:
            rate = lambda ms: "%.2f us/op" % (ms * 1000.0 / int(ssize[1]))
        honest = g_med / p_med
        infl = repo_ratio / honest
        bad = gated and infl >= 2.0
        ok = ok and not bad
        print("| %s | %d | %.1f ms | %.1f ms | %s | %s | %.3fx | %.3fx | %.1fx | %s |" % (
            mode, sn, p_med, g_med, rate(p_med), rate(g_med), honest, repo_ratio, infl,
            "FAIL (misleading)" if bad else ("PASS" if gated else "info")))
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
