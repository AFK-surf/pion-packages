#!/bin/sh
# Head-to-head benchmark runner for packages/vcard:
# Pion Native (--release) vs Go emersion/go-vcard v0.1.0.
# All build artifacts and corpora are isolated in /private/tmp/w16-vcard-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/w16-vcard-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic vCard corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$OUT_DIR"

W1_CORPUS="$OUT_DIR/w1_enterprise_4k.vcf"
W2_CORPUS="$OUT_DIR/w2_roundtrip_2k.vcf"
W3_CORPUS="$OUT_DIR/w3_escaped_binary_1k.vcf"

W1_BYTES=$(wc -c < "$W1_CORPUS" | tr -d ' ')
W2_BYTES=$(wc -c < "$W2_CORPUS" | tr -d ' ')
W3_BYTES=$(wc -c < "$W3_CORPUS" | tr -d ' ')

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_vcard_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Go emersion/go-vcard benchmark (isolated in $OUT_DIR)"
(cd "$BENCH_DIR/go" && go build -mod=readonly -o "$BIN_DIR/go_vcard_bench" .)

echo ""
echo "=== W1: Enterprise 4,000-vCard Multi-Card Parse (folded UTF-8, CJK/Emoji, ADR/TEL/EMAIL/ORG, RFC 6868) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Enterprise 4,000-vCard Multi-Card Parse" \
  --impl "pion=$BIN_DIR/pion_vcard_bench w1_parse $W1_CORPUS" \
  --impl "go_vcard=$BIN_DIR/go_vcard_bench w1_parse $W1_CORPUS" \
  --baseline go_vcard \
  --warmup 1 --rounds 5 --bytes "$W1_BYTES" \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== W2: Parse + Structured Extraction + 75-Octet Folded Roundtrip (2,000 vCards) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Parse + Structured Extraction + 75-Octet Folded Roundtrip (2,000 vCards)" \
  --impl "pion=$BIN_DIR/pion_vcard_bench w2_roundtrip $W2_CORPUS" \
  --impl "go_vcard=$BIN_DIR/go_vcard_bench w2_roundtrip $W2_CORPUS" \
  --baseline go_vcard \
  --warmup 1 --rounds 5 --bytes "$W2_BYTES" \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== W3: High Escape Density + Base64 Avatar Parse & Normalized Roundtrip (1,000 vCards) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: High Escape Density + Base64 Avatar Parse & Normalized Roundtrip (1,000 vCards)" \
  --impl "pion=$BIN_DIR/pion_vcard_bench w3_escaped_binary $W3_CORPUS" \
  --impl "go_vcard=$BIN_DIR/go_vcard_bench w3_escaped_binary $W3_CORPUS" \
  --baseline go_vcard \
  --warmup 1 --rounds 5 --bytes "$W3_BYTES" \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"
