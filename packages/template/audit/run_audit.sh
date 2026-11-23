#!/bin/sh
# Red-team audit of packages/template: one command runs every piece of evidence.
#
#   sh packages/template/audit/run_audit.sh [all|tests|diff|wasm|dos|bench]
#
# Pion `packages/template` vs Rust `minijinja =3.1.0` (--release), Native and Wasm32.
# Needs: pionc ($HOME/.pion/bin), cargo (minijinja 3.1.0 cached or network), node, python3.
# All build artefacts, Cargo lockfiles and generated corpora go to $AUDIT_OUT
# (default: /private/tmp/pion-template-audit — a real path, required by the wasm32 runner),
# never into the git worktree.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/pion-template-audit}
BIN="$OUT/bin"
WHAT=${1:-all}
ROUNDS=${BENCH_ROUNDS:-5}
DOS_TIMEOUT=${DOS_TIMEOUT:-10}
DOS_RSS_MIB=${DOS_RSS_MIB:-3072}
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
mkdir -p "$BIN"

step() { printf '\n==== %s ====\n' "$*"; }

build() {
  step "build: pion probe (native --release, wasm32 --release)"
  pionc build --release -o "$BIN/probe_pion" "$AUDIT_DIR/probe"
  pionc build --release --target wasm32 -o "$BIN/probe_pion.wasm" "$AUDIT_DIR/probe"
  step "build: rust minijinja =3.1.0 mirror (--release; project copied to \$AUDIT_OUT)"
  rm -rf "$OUT/rust-diff" && mkdir -p "$OUT/rust-diff"
  cp -R "$AUDIT_DIR/diff/rust/Cargo.toml" "$AUDIT_DIR/diff/rust/src" "$OUT/rust-diff/"
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --release --quiet \
    --manifest-path "$OUT/rust-diff/Cargo.toml"
  cp "$OUT/rust-target/release/diff_rust" "$BIN/diff_rust"
  python3 "$AUDIT_DIR/diff/gen_corpus.py" "$OUT"
}

run_tests() {
  step "pionc test: audit/tests/redteam_test.pion (FAIL = evidence; control_* must PASS)"
  # pionc exits non-zero when a test fails; that is the expected outcome here.
  pionc test --json -p template_redteam_audit "$AUDIT_DIR" > "$OUT/tests.json" 2> "$OUT/tests.stderr" || true
  python3 - "$OUT/tests.json" <<'PY'
import json, sys
t = open(sys.argv[1]).read()
d = json.loads(t[t.find('{"ok"'):])
print(f"total={d['total']} passed={d['passed']} failed={d['failed']}")
for x in d["tests"]:
    print(("PASS " if x["ok"] else "FAIL ") + x["name"])
PY
  echo "(assertion messages: $OUT/tests.stderr)"
}

run_diff() {
  step "differential: pion native vs rust minijinja 3.1.0 ($(tr -cd '\036' < "$OUT/corpus.txt" | wc -c | tr -d ' ') cases)"
  "$BIN/probe_pion" diff "$OUT/corpus.txt" > "$OUT/pion.out"
  "$BIN/diff_rust" diff "$OUT/corpus.txt" > "$OUT/rust.out"
  python3 "$AUDIT_DIR/diff/compare.py" "$OUT/pion.out" "$OUT/rust.out" --md "$OUT/diff.md"
}

run_wasm() {
  step "wasm32 vs native: whole corpus in one wasm instance"
  if node "$WASM_RT" "$BIN/probe_pion.wasm" diff "$OUT/corpus.txt" > "$OUT/wasm.out" 2> "$OUT/wasm.err"; then
    echo "wasm32 whole-corpus run: ok"
  else
    echo "wasm32 whole-corpus run ABORTED: $(head -1 "$OUT/wasm.err")"
  fi
  step "wasm32 vs native: one process per case (isolates traps)"
  python3 "$AUDIT_DIR/diff/run_isolated.py" "$OUT/corpus.txt" "$OUT/wasm_iso.records" \
    "pion_wasm32=node $WASM_RT $BIN/probe_pion.wasm" --timeout 20 > "$OUT/wasm_iso.log"
  grep -v ' OK(\| ERR(' "$OUT/wasm_iso.log" || true
  "$BIN/probe_pion" diff "$OUT/corpus.txt" > "$OUT/pion.out"
  "$BIN/diff_rust" diff "$OUT/corpus.txt" > "$OUT/rust.out"
  python3 "$AUDIT_DIR/diff/compare.py" "$OUT/pion.out" "$OUT/rust.out" --wasm "$OUT/wasm_iso.records" \
    | sed -n '/native vs pion wasm32/,$p'
}

run_dos() {
  step "DoS / stack / memory: one process per case, ${DOS_TIMEOUT}s + ${DOS_RSS_MIB} MiB watchdog"
  echo "default Environment on both sides (pion: fuel 10M, max_output 16 MiB, max_depth 64)"
  python3 "$AUDIT_DIR/diff/run_isolated.py" "$OUT/dos.txt" "$OUT/dos_native.records" \
    "pion_native=$BIN/probe_pion" \
    "pion_wasm32=node $WASM_RT $BIN/probe_pion.wasm" \
    "rust_minijinja=$BIN/diff_rust" \
    --timeout "$DOS_TIMEOUT" --rss-mib "$DOS_RSS_MIB" --md "$OUT/dos.md"
}

bench_one() { # case
  python3 "$ROOT_DIR/scripts/bench_compare.py" \
    --title "template adversarial: $1" \
    --impl "pion=$BIN/probe_pion one $OUT/bench.txt $1" \
    --impl "rust_minijinja=$BIN/diff_rust one $OUT/bench.txt $1" \
    --baseline rust_minijinja --warmup 1 --rounds "$ROUNDS" --ops 1 \
    --md-out "$OUT/bench_$1.md" --json-out "$OUT/bench_$1.json"
}

run_bench() {
  step "adversarial benchmarks (process per run incl. compile; stdout SHA-256 must match)"
  for c in bench_loop_200k bench_html_escape_50k bench_macro_50k bench_filters_50k \
    bench_attr_lookup_100k bench_sort_20k bench_unique_20k bench_set_concat_20k; do
    bench_one "$c"
  done
}

build
case "$WHAT" in
  all) run_tests; run_diff; run_wasm; run_dos; run_bench ;;
  tests) run_tests ;;
  diff) run_diff ;;
  wasm) run_wasm ;;
  dos) run_dos ;;
  bench) run_bench ;;
  *) echo "unknown target: $WHAT" >&2; exit 2 ;;
esac
step "done; artefacts in $OUT"
git -C "$ROOT_DIR" status --porcelain --ignored
