#!/bin/sh
# Benchmark fairness + adversarial head-to-head: Pion packages/lua (--release) vs gopher-lua v1.1.1.
# usage: run_bench.sh <bin_dir> <out_dir> [rounds]
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../../.." && pwd)
BIN=$1; OUT=$2; ROUNDS=${3:-5}
S="$HERE/scripts"
mkdir -p "$OUT"
cmp() { # title, md name, impl args...
  title=$1; name=$2; shift 2
  python3 "$ROOT/scripts/bench_compare.py" --title "$title" "$@" --warmup 1 --rounds "$ROUNDS" \
    --md-out "$OUT/$name.md" --json-out "$OUT/$name.json"
}
echo "### W3 fairness: 2000 x (fresh VM + compile + exec)"
cmp "W3 (as shipped): Go NewState() loads all libs" w3_full --baseline go_full --ops 2000 \
  --impl "pion=$BIN/bench_pion fresh $S/w3.lua 2000" --impl "go_full=$BIN/bench_go fresh_full $S/w3.lua 2000"
cmp "W3 fair: Go SkipOpenLibs + base/table/string/math (== Pion subset)" w3_lean --baseline go_lean --ops 2000 \
  --impl "pion=$BIN/bench_pion fresh $S/w3.lua 2000" --impl "go_lean=$BIN/bench_go fresh_lean $S/w3.lua 2000"
cmp "W3 floor: Go SkipOpenLibs + base only" w3_bare --baseline go_bare --ops 2000 \
  --impl "pion=$BIN/bench_pion fresh $S/w3.lua 2000" --impl "go_bare=$BIN/bench_go fresh_bare $S/w3.lua 2000"
cmp "W3 precompiled chunk reuse: Pion compile once + exec_chunk vs Go Compile once + NewFunctionFromProto" w3_chunk --baseline go_chunk --ops 2000 \
  --impl "pion=$BIN/bench_pion chunk $S/w3.lua 2000" --impl "go_chunk=$BIN/bench_go chunk_lean $S/w3.lua 2000"
cmp "W3-heavier (200-iter loop + format/concat per request), fresh lean" w3h_lean --baseline go_lean --ops 500 \
  --impl "pion=$BIN/bench_pion fresh $S/w3_heavier.lua 500" --impl "go_lean=$BIN/bench_go fresh_lean $S/w3_heavier.lua 500"
for w in a1_hash_big a2_int_hash_stride a3_closure_calls a4_gsub_big a5_sort_patterns a6_concat_build a7_byte_scan a8_method_oop; do
  echo "### $w"
  cmp "$w" "$w" --baseline go_lean \
    --impl "pion=$BIN/bench_pion run $S/$w.lua" --impl "go_lean=$BIN/bench_go run_lean $S/$w.lua"
done
