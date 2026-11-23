#!/bin/sh
# Benchmark fairness review for packages/xpath/bench (RT-xpath).
#   sh run_blindspots.sh BIN_DIR OUT_DIR [ROUNDS]
# 1. re-runs the shipped W1/W2/W3 (bench/run_bench.sh, unchanged) to check the README numbers;
# 2. prices the XML parse share of W1/W3 (same binaries, 0 query rounds);
# 3. blind-spot workloads the shipped bench never exercises, pion vs sxd-xpath 0.4.2 vs
#    libxml2 2.9 (C, -O2) through the audit runners, SHA-256 verified by scripts/bench_compare.py.
set -eu
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
BIN=$1
OUT=$2
ROUNDS=${3:-5}
SHIPPED=/private/tmp/w15-xpath-bench
mkdir -p "$OUT"
CMP="python3 $ROOT_DIR/scripts/bench_compare.py --warmup 1 --rounds $ROUNDS"

echo "---- (1) shipped bench/run_bench.sh (writes only to $SHIPPED)"
if [ "${SKIP_SHIPPED:-0}" != 1 ]; then
  sh "$ROOT_DIR/packages/xpath/bench/run_bench.sh" > "$OUT/shipped.log" 2>&1
fi
grep -E '^\| `(pion|rust_sxd)`' "$SHIPPED"/bench_w*.md | sed 's/^/  /'

echo "---- (2) XML parse share: the shipped binaries with 0 query rounds"
for w in w1 w3; do
  $CMP --title "parse-only $w" --baseline rust_sxd \
    --impl "pion=$SHIPPED/bin/pion_xpath $w $SHIPPED/data/$w.xml 0" \
    --impl "rust_sxd=$SHIPPED/bin/rust_xpath $w $SHIPPED/data/$w.xml 0" \
    --md-out "$OUT/parse_$w.md" --json-out "$OUT/parse_$w.json" > "$OUT/parse_$w.log" 2>&1
  grep -E '^\| `' "$OUT/parse_$w.md" | sed "s/^/  $w /"
done

echo "---- (3) blind-spot workloads (pion vs sxd-xpath vs libxml2)"
python3 -I "$AUDIT_DIR/bench/gen_packs.py" "$OUT/packs" "$SHIPPED/data/w1.xml" > /dev/null
for p in ${PACKS:-parse_only_w1 b1_string_values b2_reverse_axes b3_general_descendant b4_nodeset_compare b5_namespaces}; do
  if $CMP --title "$p" --baseline sxd \
      --impl "pion=$BIN/pion_rel $OUT/packs/$p.pack" \
      --impl "sxd=$BIN/sxd $OUT/packs/$p.pack" \
      --impl "libxml2=$BIN/libxml2 $OUT/packs/$p.pack" \
      --md-out "$OUT/$p.md" --json-out "$OUT/$p.json" > "$OUT/$p.log" 2>&1; then
    grep -E '^\| `' "$OUT/$p.md" | sed "s/^/  $p /"
  else
    echo "  $p: bench_compare FAILED (see $OUT/$p.log)"; tail -3 "$OUT/$p.log" | sed 's/^/    /'
  fi
done
