#!/bin/sh
# Red-team audit of packages/promql (feat/pkg-promql @ 3cd9f63) against the official Go
# implementation github.com/prometheus/prometheus v0.302.1 (promql/parser + promql.Engine).
#
#   sh packages/promql/audit/run_audit.sh
#
# Needs: pionc ($HOME/.pion/bin), node (Wasm32 runtime), go >= 1.24, python3.
# Everything is built and written under $AUDIT_OUT (default /private/tmp/rt-promql-audit);
# the git worktree is never written to. The Go oracle is built with -mod=readonly from the
# locked audit/go/go.mod + go.sum.
#
# Every finding of REPORT.md is one or more "CHECK PASS|FAIL <id> ..." lines. Exit status is
# 0 only when every check passes, so a fix branch can re-run this file unchanged.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt-promql-audit}
BIN="$OUT/bin"
TIMEOUT=${DOS_TIMEOUT:-10}
export PATH="$HOME/.pion/bin:$PATH"
export PION_CACHE_DIR="$OUT/pion-cache"
export PYTHONDONTWRITEBYTECODE=1
export GOFLAGS=-mod=readonly
RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
CHECKS="$OUT/checks.txt"

mkdir -p "$BIN" "$OUT/corpus"
: > "$CHECKS"
section() { printf '\n=== %s ===\n' "$1"; }
record() { tee -a "$CHECKS"; }
check() { # check <PASS|FAIL> <id> <severity> <description...>
  st=$1; id=$2; sev=$3; shift 3
  echo "CHECK $st $id $sev $*" | record
}

section "0. Build (serial): probe + wasm_smoke x {native,wasm32} x {debug,release}, Go oracle"
echo "pionc: $(pionc --version 2>&1 | head -1)   go: $(go version)   node: $(node --version)"
echo "package under audit: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
pionc build -o "$BIN/probe_dbg" "$SCRIPT_DIR/probe"
pionc build --release -o "$BIN/probe_rel" "$SCRIPT_DIR/probe"
pionc build --target wasm32 -o "$BIN/probe_dbg.wasm" "$SCRIPT_DIR/probe"
pionc build --target wasm32 --release -o "$BIN/probe_rel.wasm" "$SCRIPT_DIR/probe"
pionc build -o "$BIN/smoke_dbg" "$PKG_DIR/wasm_smoke"
pionc build --release -o "$BIN/smoke_rel" "$PKG_DIR/wasm_smoke"
pionc build --target wasm32 -o "$BIN/smoke_dbg.wasm" "$PKG_DIR/wasm_smoke"
pionc build --target wasm32 --release -o "$BIN/smoke_rel.wasm" "$PKG_DIR/wasm_smoke"
rm -rf "${OUT:?}/go-build"
cp -R "$SCRIPT_DIR/go" "$OUT/go-build"
(cd "$OUT/go-build" && go build -mod=readonly -o "$BIN/oracle" .)
python3 "$SCRIPT_DIR/gen_corpus.py" "$SCRIPT_DIR/cases/parse_corpus.txt" "$OUT/corpus" 2000
cat "$OUT/corpus/hand.tsv" "$OUT/corpus/mut.tsv" > "$OUT/corpus/all.tsv"
python3 "$SCRIPT_DIR/gen_eval.py" "$SCRIPT_DIR/cases/eval_cases.txt" "$OUT/corpus/eval.tsv"
echo "parse corpus: $(wc -l < "$OUT/corpus/hand.tsv" | tr -d ' ') hand-written + $(wc -l < "$OUT/corpus/mut.tsv" | tr -d ' ') mutants"

run_mode() { # run_mode <mode> <args...>
  m=$1; shift
  case $m in
    native_dbg) "$BIN/probe_dbg" "$@" ;;
    native_rel) "$BIN/probe_rel" "$@" ;;
    wasm_dbg) node "$RT" "$BIN/probe_dbg.wasm" "$@" ;;
    wasm_rel) node "$RT" "$BIN/probe_rel.wasm" "$@" ;;
  esac
}

section "1. Parser + format_expr / prettify_expr differential vs Go promql/parser v0.302.1"
"$BIN/oracle" parse "$OUT/corpus/all.tsv" > "$OUT/parse.go"
for m in native_dbg native_rel wasm_dbg wasm_rel; do
  run_mode $m parse "$OUT/corpus/all.tsv" > "$OUT/parse.$m" || echo "  probe $m crashed on parse corpus"
done
: > "$OUT/parse.details"
python3 "$SCRIPT_DIR/compare_parse.py" "$OUT/corpus/all.tsv" "$OUT/parse.native_rel" "$OUT/parse.go" parse \
  --details "$OUT/parse.details" | tee "$OUT/parse.summary" | grep '^CHECK' | record
grep -v '^CHECK' "$OUT/parse.summary" || true
echo "  all mismatches: $OUT/parse.details"

section "2. Evaluator semantics vs Go promql.Engine (in-memory TSDB head)"
"$BIN/oracle" eval "$OUT/corpus/eval.tsv" > "$OUT/eval.go"
for m in native_dbg native_rel wasm_dbg wasm_rel; do
  run_mode $m eval "$OUT/corpus/eval.tsv" > "$OUT/eval.$m" || echo "  probe $m crashed on eval cases"
done
python3 "$SCRIPT_DIR/compare_eval.py" "$OUT/corpus/eval.tsv" "$OUT/eval.native_rel" "$OUT/eval.go" \
  "$SCRIPT_DIR/cases/eval_groups.txt" --details "$OUT/eval.details" > "$OUT/eval.summary"
grep '^CHECK' "$OUT/eval.summary" | record
grep -v '^CHECK' "$OUT/eval.summary" | cut -c1-240 || true

section "3. DoS / crash probes (4 modes each, ${TIMEOUT}s timeout)"
python3 "$SCRIPT_DIR/run_dos.py" "$SCRIPT_DIR/cases/dos_cases.txt" "$TIMEOUT" "$RT" \
  "$BIN/probe_dbg" "$BIN/probe_rel" "$BIN/probe_dbg.wasm" "$BIN/probe_rel.wasm" | record

section "4. 4-mode consistency (native/wasm32 x debug/release)"
for k in parse eval; do
  n=$(for m in native_dbg native_rel wasm_dbg wasm_rel; do shasum -a 256 < "$OUT/$k.$m" | cut -d' ' -f1; done | sort -u | wc -l | tr -d ' ')
  (cd "$OUT" && shasum -a 256 $k.native_dbg $k.native_rel $k.wasm_dbg $k.wasm_rel | sed 's/^/  /')
  if [ "$n" = 1 ]; then check PASS 4MODE.$k - "$k differential output byte-identical in all 4 modes ($(wc -l < "$OUT/$k.native_rel" | tr -d ' ') lines)"
  else check FAIL 4MODE.$k - "$k differential output differs between modes"; fi
done
SMOKE_OK=1
for m in dbg rel; do
  "$BIN/smoke_$m" > "$OUT/smoke.native_$m" || SMOKE_OK=0
  node "$RT" "$BIN/smoke_$m.wasm" > "$OUT/smoke.wasm_$m" || SMOKE_OK=0
done
n=$(cat "$OUT"/smoke.native_dbg "$OUT"/smoke.native_rel "$OUT"/smoke.wasm_dbg "$OUT"/smoke.wasm_rel | sort -u | wc -l | tr -d ' ')
echo "  wasm_smoke stdout: $(cat "$OUT/smoke.native_rel") sha256:$(shasum -a 256 < "$OUT/smoke.native_rel" | cut -d' ' -f1)"
if [ "$SMOKE_OK" = 1 ] && [ "$n" = 1 ]; then check PASS 4MODE.smoke - "wasm_smoke exits 0 with identical stdout in all 4 modes"
else check FAIL 4MODE.smoke - "wasm_smoke failed or differs between modes"; fi

section "5. Benchmark fairness (packages/promql/bench, read-only review + timing)"
GOB="$PKG_DIR/bench/go_bench/main.go"
if grep -q '"github.com/prometheus/prometheus/promql"' "$GOB"; then
  check PASS F19 P2 "bench W3 Go baseline evaluates through promql.Engine"
else
  check FAIL F19 P2 "bench W3 'go_promql' baseline is a hand-written loop (no promql.Engine), copying Pion's own 2.x extrapolation formula"
fi
rm -rf "${OUT:?}/bench-go"
cp -R "$PKG_DIR/bench/go_bench" "$OUT/bench-go"
(cd "$OUT/bench-go" && go build -mod=readonly -o "$BIN/bench_go" .)
pionc build --release -o "$BIN/bench_pion" "$PKG_DIR/bench/pion_bench"
python3 - "$BIN" <<'PY'
import statistics, subprocess, sys, time
b = sys.argv[1]
def med(cmd, n=5):
    ts = []
    for _ in range(n):
        t = time.perf_counter(); subprocess.run(cmd, stdout=subprocess.DEVNULL, check=True); ts.append(time.perf_counter() - t)
    return statistics.median(ts) * 1000
for label, cmd in (("pion   (bench/pion_bench w3 200)", [b + "/bench_pion", "w3", "200"]),
                   ("go loop(bench/go_bench   w3 200)", [b + "/bench_go", "w3", "200"]),
                   ("go promql.Engine (audit oracle w3engine 200, incl. TSDB setup)", [b + "/oracle", "w3engine", "200"])):
    print("  W3 %-62s median %8.2f ms (5 runs)" % (label, med(cmd)))
PY

section "Summary"
P=$(grep -c '^CHECK PASS' "$CHECKS" || true)
F=$(grep -c '^CHECK FAIL' "$CHECKS" || true)
for s in P0 P1 P2; do
  printf '  %s: %s failing checks (%s)\n' "$s" "$(grep -c "^CHECK FAIL [^ ]* $s " "$CHECKS" || true)" \
    "$(grep "^CHECK FAIL [^ ]* $s " "$CHECKS" | awk '{print $3}' | sed 's/\..*//' | sort -u | tr '\n' ' ')"
done
echo "  total: $P PASS, $F FAIL   (all check lines: $CHECKS)"
if [ "$F" -gt 0 ]; then
  echo "RESULT: FAIL ($F open checks)"
  exit 1
fi
echo "RESULT: PASS"
