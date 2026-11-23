#!/bin/sh
# One-command red-team audit of packages/regex against Rust `regex =1.11.1`.
#   sh packages/regex/audit/run_audit.sh           # everything (~6-8 min on an M-series Mac)
#   sh packages/regex/audit/run_audit.sh --quick   # smaller fuzz + stress subset (~2 min)
# All artifacts go to $AUDIT_OUT (default /private/tmp/pion-regex-audit: the *real* path, the
# wasm32 runner does not follow the /tmp symlink). The git worktree stays clean.
# Exit code: 0 if the audit ran to completion (findings are in the output), 2 on tooling errors.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="${AUDIT_OUT:-/private/tmp/pion-regex-audit}"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1
mkdir -p "$OUT"
FUZZ_N=20000
STRESS_ONLY=""
if [ "$QUICK" -eq 1 ]; then
  FUZZ_N=3000
fi

echo "==> [1/7] build Pion drivers (debug + --release) and Rust oracles (regex =1.11.1, Cargo.lock pinned)"
pionc build -o "$OUT/pion_driver_dbg" "$HERE/diff/pion_driver" >/dev/null || exit 2
pionc build --release -o "$OUT/pion_driver_rel" "$HERE/diff/pion_driver" >/dev/null || exit 2
pionc build --release -o "$OUT/pion_stress" "$HERE/stress/pion_stress" >/dev/null || exit 2
CARGO_TARGET_DIR="$OUT/rust-target" cargo build --quiet --release --locked \
  --manifest-path "$HERE/diff/rust_oracle/Cargo.toml" || exit 2
CARGO_TARGET_DIR="$OUT/rust-target" cargo build --quiet --release --locked \
  --manifest-path "$HERE/stress/rust_stress/Cargo.toml" || exit 2
ORACLE="$OUT/rust-target/release/regex-audit-oracle"
RSTRESS="$OUT/rust-target/release/regex-audit-stress"

echo "==> [2/7] red-team tests (red tests FAIL while the defect exists; control tests must pass)"
pionc test --json -p regex_audit "$HERE" 2>/dev/null | tail -1 | python3 -c '
import json, sys
d = json.load(sys.stdin)
red = [t for t in d["tests"] if not t["name"].startswith("control")]
ctl = [t for t in d["tests"] if t["name"].startswith("control")]
print("red-team: %d tests, %d FAIL (evidence), %d pass | control: %d/%d pass" % (
    len(red), sum(not t["ok"] for t in red), sum(t["ok"] for t in red),
    sum(t["ok"] for t in ctl), len(ctl)))
for t in d["tests"]:
    print(("  FAIL " if not t["ok"] else "  pass ") + t["name"])
'

echo "==> [3/7] P0-1 --release miscompile: probe x4 build modes + minimal pionc repro"
for mode in "" "--release"; do
  for tgt in "" "--target wasm32"; do
    # shellcheck disable=SC2086
    r=$(pionc run $mode $tgt "$HERE/release_probe" 2>&1 | grep -E "FAIL|release_probe_failures" | tr '\n' ' ')
    # shellcheck disable=SC2086
    m=$(pionc run $mode $tgt "$HERE/compiler_repro/app" 2>&1 | tail -1)
    echo "  [${mode:-debug} ${tgt:-native}] regex probe: $r| minimal repro: $m"
  done
done

echo "==> [4/7] differential vs Rust regex 1.11.1 (curated, fuzz, capture-fuzz, RegexSet)"
python3 "$HERE/cases/gen_cases.py" curated > "$OUT/curated.cases"
python3 "$HERE/cases/gen_cases.py" fuzz 1 "$FUZZ_N" > "$OUT/fuzz.cases"
python3 "$HERE/cases/gen_cases.py" capfuzz 3 "$FUZZ_N" > "$OUT/capfuzz.cases"
python3 "$HERE/cases/gen_cases.py" sets 7 3000 > "$OUT/sets.cases"
for c in curated fuzz capfuzz sets; do
  printf '  %-8s ' "$c"
  python3 "$HERE/diff/run_diff.py" "$OUT/pion_driver_dbg" "$ORACLE" "$OUT/$c.cases" "$OUT/$c" --timeout 120 || exit 2
done
for c in curated fuzz capfuzz sets; do
  echo "  --- root-cause buckets: $c (details: $OUT/$c.mismatch.txt)"
  python3 "$HERE/diff/classify.py" "$OUT/$c.mismatch.txt" --examples 1 | cut -c1-220 | sed 's/^/    /'
done

echo "==> [5/7] build-mode consistency of the Pion transcripts (reference: native debug)"
for c in curated fuzz; do
  python3 "$HERE/diff/cmp_builds.py" "$OUT/$c.cases" "$OUT/pion_driver_dbg" \
    "pionc run --target wasm32 $HERE/diff/pion_driver --" "wasm32-debug" | sed 's/^/  /'
  python3 "$HERE/diff/cmp_builds.py" "$OUT/$c.cases" "$OUT/pion_driver_dbg" \
    "pionc run --release --target wasm32 $HERE/diff/pion_driver --" "wasm32-release" | sed 's/^/  /'
  python3 "$HERE/diff/cmp_builds.py" "$OUT/$c.cases" "$OUT/pion_driver_dbg" \
    "$OUT/pion_driver_rel" "native-release" | sed 's/^/  /'
done

echo "==> [6/7] compile bombs, nesting, DFA thrash, PikeVM cliffs, big RegexSet (Pion vs Rust)"
if [ "$QUICK" -eq 1 ]; then
  STRESS_ONLY="--only rep"
fi
# shellcheck disable=SC2086
python3 "$HERE/stress/run_stress.py" "$OUT/stress" "$OUT/pion_stress" "$RSTRESS" --timeout 60 \
  --md "$OUT/stress/stress.md" $STRESS_ONLY || exit 2
echo "    table: $OUT/stress/stress.md"

echo "==> [7/7] wasm32 nesting depth probe (--release, nest_limit raised to 1e6)"
for n in 250 400 600 1000; do
  python3 -c "import sys; open(sys.argv[1], 'w').write('(' * $n + 'a' + ')' * $n)" "$OUT/nest_$n.txt"
  r=$(pionc run --release --target wasm32 "$HERE/stress/pion_stress" -- compile_nl "$OUT/nest_$n.txt" 2>&1 \
    | grep -m1 -E 'RangeError|compile=')
  echo "  depth $n: $r"
done
exit 0
