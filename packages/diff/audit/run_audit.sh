#!/bin/sh
# One-shot red-team audit: Pion `packages/diff` vs real Rust `imara-diff v0.2.0`.
#
#   sh packages/diff/audit/run_audit.sh [--quick] [OUT_DIR]
#
# 1. builds the Rust oracle (imara-diff =0.2.0, --release) and the Pion runner (--release)
# 2. re-derives every expected value of src/redteam_test.pion from the oracle and checks it is unchanged
# 3. runs `pionc test packages/diff/audit` (p0_/p1_/p2_ tests are EXPECTED to fail = evidence)
# 4. differential fuzz (5 families x N cases x {Histogram, Myers} x {hunks, raw, slices, unified ctx 0/1/3/25})
# 5. merge3 vs `git merge-file -p`
# 6. robustness probes + adversarial benchmarks through scripts/bench_compare.py (skipped with --quick)
# Everything is written under OUT_DIR (default /tmp/diff-redteam); the worktree stays clean.
set -eu
QUICK=0
if [ "${1:-}" = "--quick" ]; then QUICK=1; shift; fi
OUT=${1:-/tmp/diff-redteam}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$OUT"
CASES=1000; MERGES=1000
if [ $QUICK = 1 ]; then CASES=200; MERGES=200; fi

echo "==> [1/6] build"
cargo build --release -q --manifest-path "$HERE/harness/rust_oracle/Cargo.toml" --target-dir "$OUT/rust-target"
ORACLE="$OUT/rust-target/release/imara_oracle"
pionc build --release "$HERE/harness/pion_runner" -o "$OUT/pion_runner"
RUNNER="$OUT/pion_runner"
echo "    oracle: $ORACLE (imara-diff $(grep -A1 'name = "imara-diff"' "$HERE/harness/rust_oracle/Cargo.lock" 2>/dev/null | sed -n 2p | tr -d ' ' || echo '=0.2.0'))"
echo "    runner: $RUNNER (packages/diff @ $(git -C "$ROOT" rev-parse --short HEAD))"

echo "==> [2/6] expected values of the red-team tests come from the oracle"
python3 "$HERE/gen_redteam_tests.py" "$ORACLE" "$OUT/redteam_test.regen.pion"
pionc fmt "$OUT/redteam_test.regen.pion" >/dev/null 2>&1 || true
if cmp -s "$OUT/redteam_test.regen.pion" "$HERE/src/redteam_test.pion"; then
  echo "    OK: src/redteam_test.pion == oracle regeneration"
else
  echo "    WARN: src/redteam_test.pion differs from a fresh oracle regeneration:"
  diff "$HERE/src/redteam_test.pion" "$OUT/redteam_test.regen.pion" | head -20 || true
fi

echo "==> [3/6] pionc test packages/diff/audit (failures are the evidence)"
pionc test "$HERE" > "$OUT/redteam_tests.log" 2>&1 || true
grep '^test diff_redteam_audit::' "$OUT/redteam_tests.log" || true
tail -1 "$OUT/redteam_tests.log"

echo "==> [4/6] differential fuzz vs imara-diff ($CASES cases per family)"
python3 "$HERE/fuzz.py" --oracle "$ORACLE" --runner "$RUNNER" --cases "$CASES" --out "$OUT/fuzz"

echo "==> [5/6] merge3 vs git merge-file ($MERGES cases)"
python3 "$HERE/merge_fuzz.py" --runner "$RUNNER" --cases "$MERGES" --out "$OUT/merge"

if [ $QUICK = 1 ]; then
  echo "==> [6/6] skipped (--quick)"
  exit 0
fi

echo "==> [6/6] robustness probes + adversarial benchmarks"
python3 "$HERE/gen_adversarial.py" "$OUT/corpus"
python3 "$HERE/gen_adversarial.py" "$OUT/corpus" --probes
python3 "$HERE/gen_hash_flood.py" "$OUT/corpus" 80000
for f in "$OUT"/corpus/probe_*.before; do
  n=$(basename "$f" .before)
  for algo in histogram myers; do
    python3 - "$ORACLE" "$RUNNER" "$OUT/corpus/$n" "$algo" <<'PY'
import subprocess, sys, time, resource, hashlib
oracle, runner, base, algo = sys.argv[1:]
res = {}
for name, b in (("rust", oracle), ("pion", runner)):
    t = time.perf_counter()
    p = subprocess.run([b, "bench", base + ".before", base + ".after", algo, "1", "3"], capture_output=True)
    res[name] = (time.perf_counter() - t, p.returncode, hashlib.sha256(p.stdout).hexdigest()[:12], p.stdout)
same = res["rust"][3] == res["pion"][3]
note = ""
if not same:
    extra = res["pion"][3].replace(b"\n\\ No newline at end of file", b"")
    note = " (only the no-newline marker)" if extra == res["rust"][3] else ""
print(f"    {base.rsplit('/',1)[1]:36s} {algo:9s} rust {res['rust'][0]*1000:8.1f} ms rc={res['rust'][1]}  pion {res['pion'][0]*1000:8.1f} ms rc={res['pion'][1]}  output {'IDENTICAL' if same else 'DIFFERS' + note}")
PY
  done
done
sh "$HERE/bench_adversarial.sh" "$ORACLE" "$RUNNER" "$OUT/corpus" "$OUT/bench"
echo ""
echo "Results: $OUT (fuzz/summary.json, merge/merge_summary.json, bench/*.md, redteam_tests.log)"
