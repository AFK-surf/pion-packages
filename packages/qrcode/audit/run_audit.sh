#!/bin/sh
# Red-team audit of packages/qrcode (RT-qrcode): one command reproduces every piece of evidence in
# REPORT.md.
#
#   sh packages/qrcode/audit/run_audit.sh [all|build|tests|diff|wasm|probe|bench]
#
# References (Rust --release, audit/diff/rust): Nayuki qrcodegen 1.8.0 (encoder + reference
# penalty), rqrr 0.11.0 (independent quirc-derived decoder), qrcode 0.14.1 (W12 baseline),
# fast_qr 0.14.0 (modern fast encoder). Needs pionc ($HOME/.pion/bin), node (wasm32 runtime),
# cargo (crates cached or network) and python3. Every build artefact and corpus goes to $AUDIT_OUT
# (default /tmp/rt-qrcode), never into the git worktree.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT=${AUDIT_OUT:-/tmp/rt-qrcode}
BIN="$OUT/bin"
DATA="$OUT/out"
WHAT=${1:-all}
ROUNDS=${BENCH_ROUNDS:-5}
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
PY="python3 -I $AUDIT_DIR/diff/qrdiff.py"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PION_CACHE_DIR=${PION_CACHE_DIR:-$OUT/cas}
mkdir -p "$BIN" "$DATA"

step() { printf '\n==== %s ====\n' "$*"; }

build() {
  step "build: pion oracle (native release/debug + wasm32 release/debug)"
  pionc build --release -o "$BIN/oracle" "$AUDIT_DIR/oracle"
  pionc build -o "$BIN/oracle_debug" "$AUDIT_DIR/oracle"
  pionc build --release --target wasm32 -o "$BIN/oracle.wasm" "$AUDIT_DIR/oracle"
  pionc build --target wasm32 -o "$BIN/oracle_debug.wasm" "$AUDIT_DIR/oracle"
  step "build: rust references (qrcodegen / rqrr / qrcode 0.14.1 / fast_qr, --release --locked)"
  rm -rf "$OUT/rust-build" && cp -R "$AUDIT_DIR/diff/rust" "$OUT/rust-build"
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --release --locked --quiet --manifest-path "$OUT/rust-build/Cargo.toml"
  cp "$OUT/rust-target/release/oracle_rust" "$BIN/oracle_rust"
}

run_tests() {
  step "pionc test: audit/redteam_test.pion (p1_/p2_ FAIL = evidence; control_* must PASS)"
  pionc test --json "$AUDIT_DIR" > "$OUT/tests.json" 2> "$OUT/tests.stderr" || true
  python3 - "$OUT/tests.json" "$OUT/tests.stderr" <<'EOF'
import json, re, sys
t = open(sys.argv[1]).read()
d = json.loads(t[t.find('{"ok"'):])
mine = [x for x in d["tests"] if x["name"].startswith(("p0_", "p1_", "p2_", "control_"))]
print(f"audit tests={len(mine)} passed={sum(x['ok'] for x in mine)} failed={sum(not x['ok'] for x in mine)}")
bad = 0
for x in mine:
    print(("PASS " if x["ok"] else "FAIL ") + x["name"])
    if x["ok"] != x["name"].startswith("control_"):
        bad += 1
print("panic messages:")
for line in open(sys.argv[2]):
    print("  " + re.sub(r"^.*/(redteam_test\.pion|pion_rt\.c)", r"\1", line.rstrip()))
if bad:
    print(f"UNEXPECTED: {bad} test(s) changed state (a fixed finding or a broken control)")
    sys.exit(1)
EOF
}

run_diff() {
  step "corpus: 160 (v,ec) x 8 masks at capacity, every mode at max/max+1, edge payloads, random mixed"
  $PY gen "$DATA"
  "$BIN/oracle" enc "$DATA/enc.tsv" > "$DATA/enc_pion.out"
  "$BIN/oracle_rust" enc "$DATA/enc.tsv" > "$DATA/enc_gen.out"
  step "encoder: Pion vs Nayuki qrcodegen (fixed mask => must be pixel-identical)"
  $PY enc "$DATA"
  step "auto mask: Pion's choice scored with the reference (qrcodegen) N1..N4"
  $PY masks "$DATA"
  step "optimiser: Pion optimize_segments vs exact O(n^2) optimum (12000 strings x 3 tiers)"
  "$BIN/oracle" seg "$DATA/seg.tsv" > "$DATA/seg_pion.out"
  $PY seg "$DATA"
  step "interop: decoders {pion, rqrr} x encoders {pion, qrcodegen} x {r0, r90, r180, r270, mirror}"
  $PY mats "$DATA"
  for s in pion gen; do
    "$BIN/oracle" dec "$DATA/mat_$s.tsv" > "$DATA/dec_pion_of_$s.out"
    "$BIN/oracle_rust" dec "$DATA/mat_$s.tsv" > "$DATA/dec_rqrr_of_$s.out"
  done
  $PY interop "$DATA"
  echo "(rqrr's SimpleGrid path does no rotation search: its r90/r180/r270 errors are expected)"
  step "RS error injection: k random byte errors in EVERY block of qrcodegen symbols"
  $PY mkinject "$DATA"
  "$BIN/oracle" dec "$DATA/inject.tsv" > "$DATA/inject_pion.out"
  "$BIN/oracle_rust" dec "$DATA/inject.tsv" > "$DATA/inject_rqrr.out"
  $PY inject "$DATA"
  step "hostile bitstreams (RS-valid symbols from qrcodegen::encode_codewords) + 4000 fuzz symbols"
  $PY mkhostile "$DATA"
  "$BIN/oracle_rust" cw "$DATA/cw.tsv" > "$DATA/hostile_mat.tsv"
  "$BIN/oracle" dec "$DATA/hostile_mat.tsv" > "$DATA/hostile_pion.out"
  "$BIN/oracle_rust" dec "$DATA/hostile_mat.tsv" > "$DATA/hostile_rqrr.out"
  $PY hostile "$DATA"
}

run_wasm() {
  step "4-mode consistency: native release/debug + wasm32 release/debug over every corpus"
  cat "$DATA/mat_gen.tsv" "$DATA/inject.tsv" "$DATA/hostile_mat.tsv" > "$DATA/all_dec.tsv"
  cp "$DATA/enc.tsv" "$DATA/all_enc.tsv"
  rc=0
  for f in enc dec; do
    "$BIN/oracle" $f "$DATA/all_$f.tsv" > "$DATA/m_nr_$f.out"
    "$BIN/oracle_debug" $f "$DATA/all_$f.tsv" > "$DATA/m_nd_$f.out"
    node "$WASM_RT" "$BIN/oracle.wasm" $f "$DATA/all_$f.tsv" > "$DATA/m_wr_$f.out"
    node "$WASM_RT" "$BIN/oracle_debug.wasm" $f "$DATA/all_$f.tsv" > "$DATA/m_wd_$f.out"
    for m in nr nd wr wd; do
      printf '%s %-3s lines=%s sha256=%s\n' $f $m "$(wc -l < "$DATA/m_${m}_$f.out" | tr -d ' ')" \
        "$(shasum -a 256 "$DATA/m_${m}_$f.out" | cut -c1-16)"
    done
    for m in nd wr wd; do cmp -s "$DATA/m_nr_$f.out" "$DATA/m_${m}_$f.out" || rc=1; done
  done
  [ $rc = 0 ] && echo "4-mode outputs: byte-identical" || { echo "4-mode outputs: DIFFER"; return 1; }
}

run_probe() {
  step "render probes (native + wasm32): hostile scale / module_size / quiet_zone (134 = runtime abort)"
  for p in "svg_qz 1000000" "svg_ms 1000000" "svg_ms 100000000" "rgba 100" "rgba 1000" "rgba 2000" \
    "pgm 1000" "pgm 2000" "ascii 3000" "term 3000"; do
    set -- $p
    for m in native wasm; do
      if [ $m = native ]; then
        "$BIN/oracle" render "$1" "$2" > "$OUT/probe.txt" 2>&1 && rc=0 || rc=$?
      else
        node "$WASM_RT" "$BIN/oracle.wasm" render "$1" "$2" > "$OUT/probe.txt" 2>&1 && rc=0 || rc=$?
      fi
      r=$(grep -E 'len=|panic|viewBox|RuntimeError|unreachable' "$OUT/probe.txt" | sed -E 's/.*(viewBox="[^"]*").*/\1/' | cut -c1-90 | head -2 | tr '\n' ' ')
      printf '%-6s %-6s %-10s rc=%-4s %s\n' $m "$1" "$2" $rc "$r"
    done
  done
  step "optimiser scaling: auto encode of n mixed bytes (DataTooLong path), pion vs qrcode 0.14.1"
  for n in 3000 10000 102400 1048576; do
    tp=$( { /usr/bin/time -p "$BIN/oracle" bench dp $n > /dev/null; } 2>&1 | awk '/^user/{u=$2} /^sys/{s=$2} END{printf "%.2f", u+s}')
    tr=$( { /usr/bin/time -p "$BIN/oracle_rust" bench dp qrcode014 $n > /dev/null; } 2>&1 | awk '/^user/{u=$2} /^sys/{s=$2} END{printf "%.2f", u+s}')
    printf 'n=%-8s pion_cpu=%ss qrcode014_cpu=%ss\n' $n "$tp" "$tr"
  done
}

run_bench() {
  step "fairness benchmarks (bench_compare.py --rounds $ROUNDS; stdout = summed module count, SHA-256 gated)"
  uptime
  for m in w1 w2; do
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "qrcode fairness $m" \
      --impl "pion=$BIN/oracle bench $m" \
      --impl "rust_qrcode014=$BIN/oracle_rust bench $m qrcode014" \
      --impl "rust_qrcodegen=$BIN/oracle_rust bench $m qrcodegen" \
      --impl "rust_fast_qr=$BIN/oracle_rust bench $m fast_qr" \
      --baseline rust_qrcode014 --warmup 1 --rounds "$ROUNDS" \
      --md-out "$DATA/bench_$m.md" --json-out "$DATA/bench_$m.json" 2>&1 | grep -E '^\| |SHA|mismatch|ERROR' || true
  done
  # qrcodegen / fast_qr have no mixed-mode optimiser and pick larger versions on these payloads,
  # so only optimiser-equipped encoders can pass the SHA gate here.
  python3 "$ROOT_DIR/scripts/bench_compare.py" --title "qrcode fairness real (mixed-case payloads)" \
    --impl "pion=$BIN/oracle bench real" \
    --impl "rust_qrcode014=$BIN/oracle_rust bench real qrcode014" \
    --baseline rust_qrcode014 --warmup 1 --rounds "$ROUNDS" \
    --md-out "$DATA/bench_real.md" --json-out "$DATA/bench_real.json" 2>&1 | grep -E '^\| |SHA|mismatch|ERROR' || true
}

case "$WHAT" in
  all) build; run_tests; run_diff; run_wasm; run_probe; run_bench ;;
  build) build ;;
  tests) run_tests ;;
  diff) run_diff ;;
  wasm) run_wasm ;;
  probe) run_probe ;;
  bench) run_bench ;;
  *) echo "usage: $0 [all|build|tests|diff|wasm|probe|bench]" >&2; exit 2 ;;
esac
