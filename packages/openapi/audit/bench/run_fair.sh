#!/bin/sh
# Benchmark-fairness audit for packages/openapi/bench (W1/W2/W3 vs Go kin-openapi v0.131.0).
#   sh run_fair.sh <out_dir>
# Re-runs the package's own W1/W2/W3 drivers (unchanged sources, built out of tree) and adds work-equivalence
# variants: Pion W1 + Validator::from_doc vs Go W1 (same stdout SHA), and Go-only overhead probes that remove
# the work Pion's drivers never do (doc.Validate, http.NewRequest, FindRoute) to split the reported ratios.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG=$(CDPATH= cd -- "$HERE/../.." && pwd)
ROOT=$(CDPATH= cd -- "$PKG/../.." && pwd)
OUT=$1
BIN="$OUT/bin"
mkdir -p "$BIN"
pionc build --release -o "$BIN/pion_bench" "$PKG/bench/pion_bench" > /dev/null || exit 2
pionc build --release -o "$BIN/pion_fair" "$HERE/pion_fair" > /dev/null || exit 2
(cd "$PKG/bench/go_bench" && go build -o "$BIN/go_bench" .) || exit 2
(cd "$HERE/go_fair" && go build -o "$BIN/go_fair" .) || exit 2

cmp_run() { # <title> <ops> --impl ... [--baseline name]
  t=$1
  ops=$2
  shift 2
  md="$OUT/$(echo "$t" | tr -c 'A-Za-z0-9\n' '_').md"
  python3 -I "$ROOT/scripts/bench_compare.py" --title "$t" "$@" --warmup 1 --rounds 5 --ops "$ops" \
    --md-out "$md" > "$OUT/last.log" 2>&1 || { tail -20 "$OUT/last.log"; return 1; }
  echo "### $t"
  grep '^|' "$md"
}

echo "--- package claims, re-run with the package's own drivers ---"
cmp_run "W1 parse+validate" 10 --impl "pion=$BIN/pion_bench w1 10" --impl "go_kin=$BIN/go_bench w1 10" --baseline go_kin
cmp_run "W2 routing" 50000 --impl "pion=$BIN/pion_bench w2 50000" --impl "go_kin=$BIN/go_bench w2 50000" --baseline go_kin
cmp_run "W3 request validation" 10000 --impl "pion=$BIN/pion_bench w3 10000" --impl "go_kin=$BIN/go_bench w3 10000" --baseline go_kin
echo "--- work-equivalence variants ---"
cmp_run "W1full: pion parse+validate+Validator::from_doc vs go load+Validate" 10 \
  --impl "pion_full=$BIN/pion_fair w1full" --impl "go_kin=$BIN/go_bench w1 10" --baseline go_kin
cmp_run "W1 go LoadFromData only (no doc.Validate)" 10 --impl "go_load=$BIN/go_fair w1load"
cmp_run "W2 go http.NewRequest only (no FindRoute)" 50000 --impl "go_reqonly=$BIN/go_fair w2reqonly"
cmp_run "W3 go NewRequest+FindRoute only (no ValidateRequest)" 10000 --impl "go_route=$BIN/go_fair w3route"
