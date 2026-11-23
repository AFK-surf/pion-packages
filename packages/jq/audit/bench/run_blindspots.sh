#!/bin/sh
# Bench-fairness probe for packages/jq: slow paths the shipped bench/ (W1-W3) does not exercise,
# plus a process-startup floor, run through scripts/bench_compare.py (warmup 1, interleaved
# rounds, mandatory stdout SHA-256 equality). Both sides run the same one-case corpus through
# the audit runners (audit/diff/pion_runner, audit/diff/go), so stdout is byte-identical.
#
#   sh packages/jq/audit/bench/run_blindspots.sh <pion_runner_bin> <gojq_oracle_bin> <out_dir>
set -eu

PION=$1
GOJQ=$2
OUT=$3
ROUNDS=${BENCH_ROUNDS:-5}
# gojq is slower than its 3 s default case timeout on B7 (its gsub is quadratic): lift it.
export RT_TIMEOUT_MS=${RT_TIMEOUT_MS:-120000}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../../.." && pwd)
mkdir -p "$OUT"

case_file() { # name query input
  python3 -c 'import json,sys; json.dump([[sys.argv[2], sys.argv[3]]], open(sys.argv[1], "w"))' "$OUT/$1.json" "$2" "$3"
}

BIGOBJ=$(python3 -c 'import json; print(json.dumps({"k%d" % i: i for i in range(20000)}, separators=(",", ":")))')

case_file B0_startup_floor '.' 'null'
case_file B1_wide_array_update_20k '[range(20000)] | .[] |= . * 2 | add' 'null'
case_file B2_wide_array_assign_20k '[range(20000)] | .[] = 1 | add' 'null'
case_file B3_object_update_5k '[range(5000) | {key: tostring, value: .}] | from_entries | .[] |= . + 1 | [.[]] | add' 'null'
case_file B4_to_from_entries_20k 'to_entries | from_entries | length' "$BIGOBJ"
case_file B5_indices_overlap_50k '"a" * 50000 | indices("aa") | length' 'null'
case_file B6_has_lookup_2k_on_20k '. as $o | [range(2000) | "k\(.)" | select(. as $k | $o | has($k))] | length' "$BIGOBJ"
case_file B7_regex_gsub_100k '"ab" * 50000 | gsub("a"; "x") | length' 'null'

for b in B0_startup_floor B1_wide_array_update_20k B2_wide_array_assign_20k B3_object_update_5k \
         B4_to_from_entries_20k B5_indices_overlap_50k B6_has_lookup_2k_on_20k B7_regex_gsub_100k; do
  echo ""
  echo "=== $b ==="
  python3 "$ROOT/scripts/bench_compare.py" --title "$b" \
    --impl "pion=$PION $OUT/$b.json" --impl "gojq=$GOJQ run $OUT/$b.json" \
    --baseline gojq --warmup 1 --rounds "$ROUNDS" \
    --md-out "$OUT/$b.md" --json-out "$OUT/$b.result.json"
done
