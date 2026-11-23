#!/bin/sh
# Red-team audit of packages/jq (RT-jq): one command reproduces every piece of evidence in REPORT.md.
#
#   sh packages/jq/audit/run_audit.sh [all|build|tests|expect|diff|dos|wasm|bench]
#
# Pion `packages/jq` vs Go `github.com/itchyny/gojq v0.12.17` (library, audit/diff/go) vs
# `jq 1.7.x` (system binary, optional tie-breaker). Needs: pionc ($HOME/.pion/bin), node (wasm32
# runtime), go (gojq + yaml.v3 from the module cache or network), python3, optionally jq.
# Every build artefact, corpus and result goes to $AUDIT_OUT (default /tmp/rt-jq-audit), never
# into the git worktree.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT=${AUDIT_OUT:-/tmp/rt-jq-audit}
BIN="$OUT/bin"
WHAT=${1:-all}
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
JQ=${JQ:-$(command -v jq || true)}
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export GOFLAGS=${GOFLAGS:--mod=mod}
export GOCACHE=${GOCACHE:-$OUT/gocache}
mkdir -p "$BIN" "$OUT"

step() { printf '\n==== %s ====\n' "$*"; }

build() {
  step "build: pion runner (native debug/release + wasm32 debug/release)"
  pionc build --release -o "$BIN/pion_rel" "$AUDIT_DIR/diff/pion_runner"
  pionc build -o "$BIN/pion_dbg" "$AUDIT_DIR/diff/pion_runner"
  pionc build --release --target wasm32 -o "$BIN/pion_wasm_rel.wasm" "$AUDIT_DIR/diff/pion_runner"
  pionc build --target wasm32 -o "$BIN/pion_wasm_dbg.wasm" "$AUDIT_DIR/diff/pion_runner"
  step "build: gojq v0.12.17 oracle"
  rm -rf "$OUT/go-build" && cp -R "$AUDIT_DIR/diff/go" "$OUT/go-build"
  (cd "$OUT/go-build" && go build -o "$BIN/gojq_oracle" .)
}

run_tests() {
  step "pionc test: audit/redteam_test.pion (p0_/p1_/p2_ FAIL = evidence; control_* must PASS)"
  # pionc exits non-zero when a test fails; that is the expected outcome here.
  pionc test --json "$AUDIT_DIR" > "$OUT/tests.json" 2> "$OUT/tests.stderr" || true
  python3 - "$OUT/tests.json" "$OUT/tests.stderr" <<'EOF'
import json, re, sys
t = open(sys.argv[1]).read()
d = json.loads(t[t.find('{"ok"'):])
mine = [x for x in d["tests"] if x["pkg"] == "jq_redteam_audit"]
print(f"audit tests={len(mine)} passed={sum(x['ok'] for x in mine)} failed={sum(not x['ok'] for x in mine)}")
bad = 0
for x in mine:
    print(("PASS " if x["ok"] else "FAIL ") + x["name"])
    if x["ok"] != x["name"].startswith("control_"):
        bad += 1
print("first failing assertion of each evidence test:")
for m in re.finditer(r"redteam_test\.pion:(\d+): (.*)", open(sys.argv[2]).read()):
    print(f"  line {m.group(1)}: {m.group(2)[:240]}")
if bad:
    print(f"UNEXPECTED: {bad} test(s) with the wrong outcome (evidence passing or control failing)")
    sys.exit(1)
EOF
}

run_expect() {
  step "cross-check every expect() in redteam_test.pion against pion / gojq / jq"
  python3 -I "$AUDIT_DIR/diff/check_expectations.py" "$AUDIT_DIR/redteam_test.pion" "$BIN/pion_rel" "$BIN/gojq_oracle" $JQ
}

corpus() {
  "$BIN/gojq_oracle" yaml "$(go env GOMODCACHE)/github.com/itchyny/gojq@v0.12.17/cli/test.yaml" > "$OUT/gojq_suite.json"
  python3 -I "$AUDIT_DIR/diff/gen_corpus.py" --yaml "$OUT/gojq_suite.json" > "$OUT/corpus.json"
}

run_diff() {
  step "corpus: hand-written vectors + builtin x input + seeded fuzzer + gojq cli/test.yaml"
  corpus
  step "3-way differential (native_rel) vs gojq v0.12.17 vs jq"
  python3 -I "$AUDIT_DIR/diff/run_diff.py" --corpus "$OUT/corpus.json" \
    --pion "native_rel=$BIN/pion_rel" --gojq "$BIN/gojq_oracle" ${JQ:+--jq "$JQ"} --out "$OUT/diff"
}

run_wasm() {
  step "4-mode consistency: native_rel / native_dbg / wasm_dbg / wasm_rel over the same corpus"
  [ -f "$OUT/corpus.json" ] || corpus
  python3 -I "$AUDIT_DIR/diff/run_diff.py" --corpus "$OUT/corpus.json" \
    --pion "native_rel=$BIN/pion_rel" --pion "native_dbg=$BIN/pion_dbg" \
    --pion "wasm_dbg=node $WASM_RT $BIN/pion_wasm_dbg.wasm" --pion "wasm_rel=node $WASM_RT $BIN/pion_wasm_rel.wasm" \
    --gojq "$BIN/gojq_oracle" --out "$OUT/diff4"
  step "4-mode DoS / deep-nesting battery (stack cases)"
  python3 -I "$AUDIT_DIR/dos/run_dos.py" --out "$OUT/dos4" --timeout 30 \
    --only "$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import run_dos; print(",".join(c[0] for c in run_dos.CASES if c[3] == "stack" or c[0].startswith("bomb_")))' "$AUDIT_DIR/dos")" \
    --pion "native_rel=$BIN/pion_rel" --pion "native_dbg=$BIN/pion_dbg" \
    --pion "wasm_dbg=node $WASM_RT $BIN/pion_wasm_dbg.wasm" --pion "wasm_rel=node $WASM_RT $BIN/pion_wasm_rel.wasm"
}

run_dos() {
  step "DoS / complexity / bomb battery: native_rel vs gojq (each case isolated, RSS-capped)"
  python3 -I "$AUDIT_DIR/dos/run_dos.py" --pion "native_rel=$BIN/pion_rel" --gojq "$BIN/gojq_oracle" \
    --out "$OUT/dos" --timeout "${DOS_TIMEOUT:-20}"
}

run_bench() {
  step "bench fairness: slow paths the shipped bench/ does not cover (scripts/bench_compare.py)"
  sh "$AUDIT_DIR/bench/run_blindspots.sh" "$BIN/pion_rel" "$BIN/gojq_oracle" "$OUT/bench"
}

case "$WHAT" in
  build) build ;;
  tests) run_tests ;;
  expect) run_expect ;;
  diff) run_diff ;;
  dos) run_dos ;;
  wasm) run_wasm ;;
  bench) run_bench ;;
  all) build; run_tests; run_expect; run_diff; run_dos; run_wasm; run_bench ;;
  *) echo "usage: $0 [all|build|tests|expect|diff|dos|wasm|bench]" >&2; exit 2 ;;
esac
step "done: results in $OUT"
