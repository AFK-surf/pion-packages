#!/bin/sh
# RT-vcard red-team audit runner for packages/vcard.
#   sh packages/vcard/audit/run_audit.sh [tests|diff|wasm|dos|bench|all]   (default: all = tests diff wasm dos)
# Exit 0 iff every stage finds no defect; exit 1 otherwise (all stages still run).
# Builds, oracle binaries, corpora and caches live in /private/tmp/rt-vcard-*; the worktree stays clean.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/go/bin:$PATH"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
W=/private/tmp/rt-vcard-work
BIN=$W/bin
mkdir -p "$BIN"
STEP=${1:-all}
RESULT=0
mark() { echo "  [$1] $2"; [ "$1" = FAIL ] && RESULT=1; return 0; }

build_driver() {
  pionc build --release -o "$BIN/driver" "$SCRIPT_DIR/driver" || { echo "driver build failed"; exit 2; }
}

build_oracles() {
  (cd "$SCRIPT_DIR/diff/go" && GOFLAGS=-mod=readonly go build -o "$BIN/go_oracle" .) || { echo "go oracle build failed"; exit 2; }
  CARGO_TARGET_DIR=$W/rust-target cargo build -q --release --locked \
    --manifest-path "$SCRIPT_DIR/diff/rust/Cargo.toml" || { echo "calcard oracle build failed"; exit 2; }
  cp "$W/rust-target/release/rt-vcard-calcard-oracle" "$BIN/calcard_oracle"
}

summarize_tests() { # <json> <pkg>
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
pkg = sys.argv[2]
ts = [t for t in d["tests"] if t["pkg"] == pkg]
bad = [t["name"] for t in ts if not t["ok"]]
print("  %s: %d/%d passed" % (pkg, len(ts) - len(bad), len(ts)))
for n in bad:
    print("    FAIL " + n)
sys.exit(1 if bad or not ts else 0)
PY
}

do_tests() {
  echo "==> pionc fmt/check/test: audit package (vcard + base64 suites run as dependencies)"
  pionc fmt --check "$SCRIPT_DIR" "$SCRIPT_DIR/driver" && mark PASS "fmt --check" || mark FAIL "fmt --check"
  pionc check --json "$SCRIPT_DIR" > "$W/check.json" && pionc check --json "$SCRIPT_DIR/driver" >> "$W/check.json" \
    && mark PASS "check" || mark FAIL "check"
  pionc test --json "$SCRIPT_DIR" > "$W/test.json" 2> "$W/test.stderr"
  summarize_tests "$W/test.json" vcard && mark PASS "upstream vcard suite" || mark FAIL "upstream vcard suite"
  if summarize_tests "$W/test.json" vcard_redteam_audit; then
    mark PASS "red-team tests"
  else
    grep "pion panic" "$W/test.stderr" | sed "s|$SCRIPT_DIR/||; s/^/    /"
    mark FAIL "red-team tests (each failing p0/p1/p2 test is a defect)"
  fi
}

do_diff() {
  build_driver
  build_oracles
  echo "==> differential corpus: Pion vs spec expectations (go-vcard v0.1.0 / calcard 0.3.14 informative)"
  python3 "$SCRIPT_DIR/diff/cases.py" "$W/cases.txt"
  "$BIN/driver" dump "$W/cases.txt" > "$W/pion.txt"
  "$BIN/driver" rt "$W/cases.txt" > "$W/pion_rt.txt"
  "$BIN/go_oracle" "$W/cases.txt" > "$W/go.txt"
  "$BIN/calcard_oracle" "$W/cases.txt" > "$W/calcard.txt"
  PYTHONDONTWRITEBYTECODE=1 python3 "$SCRIPT_DIR/diff/compare.py" "$W/pion.txt" "$W/pion_rt.txt" "$W/go.txt" "$W/calcard.txt" \
    && mark PASS "differential" || mark FAIL "differential (Pion != spec)"
}

do_wasm() {
  echo "==> 4-mode consistency: native/wasm32 x debug/release, clean PION_CACHE_DIR"
  export PION_CACHE_DIR=/private/tmp/rt-vcard-4mode-cache
  rm -rf "$PION_CACHE_DIR"
  [ -f "$W/cases.txt" ] || python3 "$SCRIPT_DIR/diff/cases.py" "$W/cases.txt"
  [ -f "$W/dos/d2_fold_200k.vcf" ] || python3 "$SCRIPT_DIR/diff/gen_dos.py" "$W/dos"
  ref=""; ok=1
  for mode in native_dbg native_rel wasm_dbg wasm_rel; do
    flags=""
    case $mode in *rel) flags="--release" ;; esac
    case $mode in wasm*) flags="$flags --target wasm32" ;; esac
    out=$W/4mode-$mode.txt; : > "$out"; rc=0
    for args in "dump $W/cases.txt" "rt $W/cases.txt" "parse $W/dos/d2_fold_200k.vcf" "parse $W/dos/d3_props_50k.vcf" \
      "parse $W/dos/d4_params_50k.vcf" "media $W/dos/d5_photo_8m.vcf" "parse $W/dos/d1_qp_37500.vcf" "fmt $W/dos/b2_heavy_fold.vcf"; do
      # shellcheck disable=SC2086
      pionc run $flags "$SCRIPT_DIR/driver" -- $args >> "$out" 2>> "$W/4mode-$mode.err" || rc=$?
    done
    sha=$(shasum -a 256 < "$out" | cut -c1-64)
    printf '  %-10s rc=%s lines=%s sha256=%s\n' "$mode" "$rc" "$(wc -l < "$out" | tr -d ' ')" "$sha"
    [ "$rc" = 0 ] || ok=0
    if [ -z "$ref" ]; then ref=$sha; elif [ "$sha" != "$ref" ]; then ok=0; fi
  done
  [ $ok = 1 ] && mark PASS "4-mode byte-identical, 0 trap" || mark FAIL "4-mode mismatch or non-zero exit"
}

do_dos() {
  build_driver
  [ -x "$BIN/go_oracle" ] || build_oracles
  echo "==> DoS / complexity probes"
  sh "$SCRIPT_DIR/dos.sh" "$BIN/driver" "$BIN/go_oracle" "$W" && mark PASS "DoS gates" || mark FAIL "DoS gates (G1/G2/G3)"
}

do_bench() {
  echo "==> reproduce packages/vcard/bench (W1/W2/W3) via scripts/bench_compare.py"
  sh "$PKG_DIR/bench/run_bench.sh" | grep -E '^(===|\| `|_SHA)' || mark FAIL "bench"
}

case $STEP in
  tests) do_tests ;;
  diff) do_diff ;;
  wasm) do_wasm ;;
  dos) do_dos ;;
  bench) do_bench ;;
  all) do_tests; do_diff; do_wasm; do_dos ;;
  *) echo "usage: run_audit.sh [tests|diff|wasm|dos|bench|all]" >&2; exit 2 ;;
esac
echo "==> worktree status (must be empty):"
git -C "$REPO_ROOT" status --porcelain --ignored
echo "==> RT-vcard result: $([ $RESULT = 0 ] && echo 'CLEAN (exit 0)' || echo 'DEFECTS FOUND (exit 1)')"
exit $RESULT
