#!/bin/sh
# Adversarial head-to-head benchmarks using the package's own (unmodified) bench drivers in `batch` mode.
#   sh run_adv.sh [out_dir]      (default /private/tmp/rt-jsonschema/adv)
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../../.." && pwd)
PKG_BENCH="$HERE/../../bench"
OUT=${1:-/private/tmp/rt-jsonschema/adv}
NODE_PKG=${NODE_PKG:-/private/tmp/rt-jsonschema/node_pkg}
mkdir -p "$OUT/bin"
python3 -I "$HERE/gen_adv.py" "$OUT" || exit 2
pionc build --release -o "$OUT/bin/pion_jsonschema" "$PKG_BENCH/pion_bench" >/dev/null || exit 2
CARGO_TARGET_DIR="$OUT/rust-target" cargo build --quiet --locked --release --offline \
  --manifest-path "$PKG_BENCH/rust_bench/Cargo.toml" || exit 2
cp "$OUT/rust-target/release/jsonschema_bench_rust" "$OUT/bin/rust_jsonschema"
for w in "a1:20:wide objects, 1000 keys, additionalProperties" \
         "a2:20:unevaluatedProperties, 300-key objects" \
         "a3:20:uniqueItems, 2000-element arrays of objects" \
         "a4:50:recursive \$ref tree depth 40" \
         "a5:20:W1 MCP schema, 5000 distinct instances (startup amortised)"; do
  id=${w%%:*}; rest=${w#*:}; it=${rest%%:*}; title=${rest#*:}
  n=$(wc -l < "$OUT/${id}_instances.jsonl" | tr -d ' ')
  ops=$((n * it))
  echo "=== $id: $title ($ops validations) ==="
  python3 "$ROOT/scripts/bench_compare.py" --title "$id: $title" \
    --impl "pion=$OUT/bin/pion_jsonschema batch $OUT/${id}_schema.json $OUT/${id}_instances.jsonl $it" \
    --impl "rust_jsonschema=$OUT/bin/rust_jsonschema batch $OUT/${id}_schema.json $OUT/${id}_instances.jsonl $it" \
    --impl "node_ajv=NODE_PATH=$NODE_PKG/node_modules node $PKG_BENCH/node_bench/bench.js batch $OUT/${id}_schema.json $OUT/${id}_instances.jsonl $it" \
    --baseline rust_jsonschema --warmup 1 --rounds 5 --ops "$ops" \
    --md-out "$OUT/bench_$id.md" --json-out "$OUT/bench_$id.json" 2>&1 | grep -E "^\||SHA|MISMATCH|mismatch|differ|Error" 
done
echo "=== fairness: fixed vs steady-state cost of the package's own W1/W2 (README sizes) ==="
python3 -I "$PKG_BENCH/gen_data.py" "$OUT/w" 500 200 200 > /dev/null || exit 2
python3 -I "$HERE/steady_state.py" "$OUT/bin" "$OUT/w" "$NODE_PKG/node_modules" "$PKG_BENCH" 2000
