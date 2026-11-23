#!/bin/sh
# Head-to-head benchmark & binary interop runner for packages/avro:
# Pion Native (packages/avro, dynamic AvroValue) vs Go (github.com/hamba/avro/v2, typed structs).
# All build artifacts and temporary files are placed in /private/tmp/w15-avro-bench.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="${BENCH_OUT:-/private/tmp/w15-avro-bench}"
BIN_DIR="$OUT_DIR/bin"
W2_BIN="$OUT_DIR/w2_v1_50k.bin"

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Go hamba/avro/v2 benchmark (locked go.sum)"
rm -rf "$OUT_DIR/go-build"
cp -R "$BENCH_DIR/go" "$OUT_DIR/go-build"
(cd "$OUT_DIR/go-build" && go build -mod=readonly -o "$BIN_DIR/go_bench" .)

echo ""
echo "==> Verifying Schema Fingerprint & Binary Interoperability (Pion <-> Go hamba/avro/v2)"
FP_PION=$("$BIN_DIR/pion_bench" fp _)
FP_GO=$("$BIN_DIR/go_bench" fp _)
echo "  Pion: $FP_PION"
echo "  Go:   $FP_GO"
if [ "$FP_PION" != "$FP_GO" ]; then
  echo "FAIL: Rabin-64 schema fingerprint mismatch!" >&2
  exit 1
fi

"$BIN_DIR/pion_bench" gen_v1 "$OUT_DIR/pion_v1_50k.bin" 50000
"$BIN_DIR/go_bench" gen_v1 "$OUT_DIR/go_v1_50k.bin" 50000
V1_P2G=$("$BIN_DIR/go_bench" decode_v1 "$OUT_DIR/pion_v1_50k.bin" 50000)
V1_G2P=$("$BIN_DIR/pion_bench" decode_v1 "$OUT_DIR/go_v1_50k.bin" 50000)
echo "  V1 50k Pion -> Go: $V1_P2G"
echo "  V1 50k Go -> Pion: $V1_G2P"
if [ "$V1_P2G" != "$V1_G2P" ]; then
  echo "FAIL: Bidirectional V1 binary datum interop mismatch!" >&2
  exit 1
fi
cp "$OUT_DIR/go_v1_50k.bin" "$W2_BIN"
W2_BYTES=$(wc -c < "$W2_BIN" | tr -d ' ')

echo "==> Verifying bidirectional .avro OCF (deflate) interop (5,000 records, 5 blocks)"
"$BIN_DIR/pion_bench" write_ocf "$OUT_DIR/pion_out.avro" 5000
"$BIN_DIR/go_bench" write_ocf "$OUT_DIR/go_out.avro" 5000
INTEROP_P2G=$("$BIN_DIR/go_bench" read_ocf "$OUT_DIR/pion_out.avro")
INTEROP_G2P=$("$BIN_DIR/pion_bench" read_ocf "$OUT_DIR/go_out.avro")
echo "  Pion -> Go: $INTEROP_P2G"
echo "  Go -> Pion: $INTEROP_G2P"
if [ "$INTEROP_P2G" != "$INTEROP_G2P" ]; then
  echo "FAIL: Bidirectional OCF interop mismatch!" >&2
  exit 1
fi

echo ""
echo "=== W1: Avro Binary Encode + Decode Roundtrip (50,000 nested records) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Avro W1: Binary Encode + Decode Roundtrip (50,000 nested records)" \
  --impl "pion=$BIN_DIR/pion_bench w1 50000" \
  --impl "go_hamba_any=$BIN_DIR/go_bench w1_any 50000" \
  --impl "go_hamba_struct=$BIN_DIR/go_bench w1 50000" \
  --baseline go_hamba_any \
  --warmup 1 --rounds 5 --ops 50000 --bytes "$W2_BYTES" \
  --md-out "$OUT_DIR/w1.md" --json-out "$OUT_DIR/w1.json"

echo ""
echo "=== W2: Schema Evolution Batch Decode Writer v1 -> Reader v2 (50,000 records) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Avro W2: Schema Evolution v1 -> v2 Batch Decode (50,000 records)" \
  --impl "pion=$BIN_DIR/pion_bench w2 $W2_BIN 50000" \
  --impl "go_hamba_any=$BIN_DIR/go_bench w2_any $W2_BIN 50000" \
  --impl "go_hamba_struct=$BIN_DIR/go_bench w2 $W2_BIN 50000" \
  --baseline go_hamba_any \
  --warmup 1 --rounds 5 --ops 50000 --bytes "$W2_BYTES" \
  --md-out "$OUT_DIR/w2.md" --json-out "$OUT_DIR/w2.json"

echo ""
echo "=== W3: .avro OCF Deflate Multi-Block Write + Read (50,000 records, 50 blocks) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Avro W3: .avro OCF Deflate Write + Read Roundtrip (50,000 records)" \
  --impl "pion=$BIN_DIR/pion_bench w3 50000" \
  --impl "go_hamba_any=$BIN_DIR/go_bench w3_any 50000" \
  --impl "go_hamba_struct=$BIN_DIR/go_bench w3 50000" \
  --baseline go_hamba_any \
  --warmup 1 --rounds 5 --ops 50000 --bytes "$W2_BYTES" \
  --md-out "$OUT_DIR/w3.md" --json-out "$OUT_DIR/w3.json"
