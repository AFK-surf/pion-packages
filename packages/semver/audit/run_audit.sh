#!/bin/sh
# One-shot red-team audit of packages/semver against dtolnay/semver =1.0.28.
#
#   sh packages/semver/audit/run_audit.sh            # differential + matrix + tests + perf
#   SKIP_PERF=1 sh packages/semver/audit/run_audit.sh
#
# All builds, corpora and outputs go to $AUDIT_OUT (default /tmp/pion-semver-audit); the git
# worktree stays clean. Exit status is 0 only when every differential case is byte-identical
# and every audit test passes (i.e. once all findings in REPORT.md are fixed).
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT="${AUDIT_OUT:-/tmp/pion-semver-audit}"
BIN="$OUT/bin"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$BIN"
status=0

echo "==> [build] Pion differential driver (--release)"
pionc build --release -o "$BIN/pion_audit" "$AUDIT_DIR"

echo "==> [build] Rust oracle: dtolnay/semver =1.0.28 (--release, sources + lockfile in $OUT)"
rm -rf "$OUT/rust_src"
mkdir -p "$OUT/rust_src"
cp -R "$AUDIT_DIR/oracle_rust/Cargo.toml" "$AUDIT_DIR/oracle_rust/src" "$OUT/rust_src/"
CARGO_TARGET_DIR="$OUT/rust-target" cargo build -q --release --manifest-path "$OUT/rust_src/Cargo.toml"
cp "$OUT/rust-target/release/semver-audit-oracle" "$BIN/rust_oracle"
grep -A1 'name = "semver"' "$OUT/rust_src/Cargo.lock" | tr '\n' ' '
echo

echo ""
echo "==> [1/4] Differential fuzz corpus (parse / format / errors / matches / ordering)"
python3 "$AUDIT_DIR/tools/gen_corpus.py" "$OUT/corpus.txt" "${AUDIT_SEED:-20261123}" "${AUDIT_SCALE:-1}"
"$BIN/pion_audit" diff "$OUT/corpus.txt" > "$OUT/pion.out"
"$BIN/rust_oracle" diff "$OUT/corpus.txt" > "$OUT/rust.out"
if python3 "$AUDIT_DIR/tools/diff_report.py" "$OUT/corpus.txt" "$OUT/pion.out" "$OUT/rust.out" 3 > "$OUT/diff_report.txt"; then
  echo "differential: all cases identical"
else
  status=1
fi
grep -E '^(cases|mismatches|## )' "$OUT/diff_report.txt" || true
echo "(full counterexamples: $OUT/diff_report.txt)"

echo ""
echo "==> [2/4] Exhaustive VersionReq::matches matrices (precompiled interval fast path)"
python3 "$AUDIT_DIR/tools/gen_matrix.py" "$OUT/m_small_reqs.txt" "$OUT/m_small_vers.txt" 200000
M=9223372036854775807
MATRIX_NUMS="0,$((M - 1)),$M" MATRIX_VNUMS="0,1,$((M - 1)),$M" \
  python3 "$AUDIT_DIR/tools/gen_matrix.py" "$OUT/m_max_reqs.txt" "$OUT/m_max_vers.txt" 100000
for m in small max; do
  "$BIN/pion_audit" matrix "$OUT/m_${m}_reqs.txt" "$OUT/m_${m}_vers.txt" > "$OUT/m_${m}.pion"
  "$BIN/rust_oracle" matrix "$OUT/m_${m}_reqs.txt" "$OUT/m_${m}_vers.txt" > "$OUT/m_${m}.rust"
  if cmp -s "$OUT/m_${m}.pion" "$OUT/m_${m}.rust"; then
    echo "matrix[$m]: identical ($(shasum -a 256 "$OUT/m_${m}.rust" | cut -c1-16))"
  else
    echo "matrix[$m]: MISMATCH (diff $OUT/m_${m}.pion $OUT/m_${m}.rust)"
    status=1
  fi
done

echo ""
echo "==> [3/4] Audit tests (expected-correct assertions; FAIL = finding still open)"
if pionc test --json "$AUDIT_DIR" > "$OUT/test.json" 2> "$OUT/test.stderr"; then :; else status=1; fi
python3 - "$OUT/test.json" <<'EOF'
import json, sys
raw = open(sys.argv[1]).read().strip().splitlines()
j = json.loads(raw[-1])
tests = [t for t in j.get("tests", []) if t.get("pkg") == "semver_audit"]
for t in tests:
    print(("PASS " if t["ok"] else "FAIL ") + t["name"])
print(f"audit tests: {sum(t['ok'] for t in tests)}/{len(tests)} passing")
EOF

if [ "${SKIP_PERF:-0}" = "1" ]; then
  echo "==> [4/4] perf skipped (SKIP_PERF=1)"
  exit $status
fi

echo ""
echo "==> [4/4] Adversarial performance (bench_compare.py, warmup 1, 5 interleaved rounds, SHA-256 checked)"
python3 "$AUDIT_DIR/tools/gen_perf.py" "$OUT/perf"
P="$OUT/perf"
bench() {
  name=$1
  shift
  python3 "$ROOT_DIR/scripts/bench_compare.py" --title "$name" \
    --impl "pion=$BIN/pion_audit perf $*" --impl "rust_semver=$BIN/rust_oracle perf $*" \
    --baseline rust_semver --warmup 1 --rounds 5 --md-out "$OUT/perf_$name.md" > "$OUT/perf_$name.log" 2>&1 || {
    echo "perf[$name]: bench_compare failed (see $OUT/perf_$name.log)"
    return 0
  }
  echo "--- $name"
  grep -E '^\| `' "$OUT/perf_$name.md" || cat "$OUT/perf_$name.log"
}
bench long_pre_parse version "$P/long_pre.txt" 5
bench scale_10k version "$P/scale_10000.txt" 2000
bench scale_100k version "$P/scale_100000.txt" 200
bench scale_1m version "$P/scale_1000000.txt" 20
bench long_pre_cmp cmp "$P/long_cmp.txt" 20
bench req32_parse req "$P/req32.txt" 3
bench req32_match_release match "$P/req32.txt" 3 1.5.5
bench req32_match_pre match "$P/req32.txt" 3 1.5.5-alpha.3
bench dirty_version version "$P/dirty.txt" 10
bench dirty_req req "$P/dirty.txt" 10
exit $status
