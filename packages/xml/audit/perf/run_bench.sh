#!/bin/sh
# Head-to-head adversarial benchmarks: pion `xml` vs roxmltree 0.21.2 / quick-xml 0.42.0 (--release),
# through scripts/bench_compare.py (strictly interleaved, stdout SHA-256 must match).
#
#   sh perf/run_bench.sh BIN_DIR ADV_DIR ADV_QUICK_DIR OUT_DIR [ROUNDS]
#
# BIN_DIR holds pion_perf / rust_perf; ADV_DIR the full gen_adversarial.py set plus
# bench/gen_data.py's mixed_corpus.xml; ADV_QUICK_DIR the --quick set (for ns_deep_2000.xml,
# which roxmltree needs ~23 s/run for at 5000 levels).
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../../.." && pwd)
BIN=$1
ADV=$2
ADVQ=$3
OUT=$4
ROUNDS=${5:-5}
mkdir -p "$OUT"

bench() {
  # bench KEY TITLE PION_MODE RUST_MODE FILE INNER_ROUNDS
  key=$1; title=$2; pm=$3; rm=$4; file=$5; n=$6
  bytes=$(( $(wc -c < "$file") * n ))
  printf '\n### %s\n\n' "$title"
  python3 "$ROOT/scripts/bench_compare.py" \
    --title "$title" \
    --impl "pion=$BIN/pion_perf $pm $file $n" \
    --impl "rust=$BIN/rust_perf $rm $file $n" \
    --baseline rust --warmup 1 --rounds "$ROUNDS" --bytes "$bytes" \
    --md-out "$OUT/$key.md" --json-out "$OUT/$key.json" > "$OUT/$key.log" 2>&1 \
    || { cat "$OUT/$key.log"; return 1; }
  sed -n '/^| Implementation/,$p' "$OUT/$key.md"
}

# Fairness: the shipped Bench 1 walks the DOM through the zero-alloc indexed accessors
# (`node_kind_at`/`attr_value_len_raw`), not the public Node API a user calls.
bench fair_dom_indexed "Mixed corpus, DOM, pion indexed accessors (as packages/xml/bench) vs roxmltree" dom dom "$ADV/mixed_corpus.xml" 10
bench fair_dom_public "Mixed corpus, DOM, pion public Node API (descendants/attributes/text) vs roxmltree" dom_api dom "$ADV/mixed_corpus.xml" 10
bench fair_reader "Mixed corpus, Reader vs quick-xml Reader" rd rd "$ADV/mixed_corpus.xml" 10
bench merge "P0-1 Text/CDATA alternation x20000 (DOM) vs roxmltree" dom dom "$ADV/merge_20000.xml" 1
bench ns_alt "1,000 prefixes, 200k elements cycling prefixes (DOM) vs roxmltree" dom dom "$ADV/ns_1000_alt.xml" 1
bench ns_deep "2,000-deep scopes each declaring a prefix, leaf uses outermost (DOM) vs roxmltree" dom dom "$ADVQ/ns_deep_2000.xml" 1
bench attrs_dom "200 elements x 1,000 attributes (DOM) vs roxmltree" dom dom "$ADV/attrs_200x1000.xml" 1
bench attrs_rd "200 elements x 1,000 attributes (Reader) vs quick-xml" rd rd "$ADV/attrs_200x1000.xml" 1
bench dtd_ents "20,000 internal entities + 20,000 references (DOM, allow_dtd) vs roxmltree" dom_dtd dom_dtd "$ADV/dtd_entities_20000.xml" 1
bench text_refs_dom "16 MiB text dense in entity/char refs (DOM) vs roxmltree" dom dom "$ADV/text_16m_refs.xml" 1
bench text_refs_rd "16 MiB text dense in entity/char refs (Reader) vs quick-xml" rd rd "$ADV/text_16m_refs.xml" 1
bench text_16m "16 MiB single text node (DOM) vs roxmltree" dom dom "$ADV/text_16m.xml" 1
bench siblings "100k sibling elements (DOM) vs roxmltree" dom dom "$ADV/siblings_100k.xml" 1
bench deep "50,000-deep nesting (DOM, limits raised) vs roxmltree" dom dom "$ADV/deep_50000.xml" 1
