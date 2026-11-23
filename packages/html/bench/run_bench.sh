#!/bin/sh
# Head-to-head benchmark runner for packages/html:
#   Pion Native (--release) vs Rust scraper/html5ever & ammonia (--release) vs Go golang.org/x/net/html.
# All temporary build artifacts and generated corpora are kept in /private/tmp/pion-html-bench.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/pion-html-bench"
BIN_DIR="$OUT_DIR/bin"
PAGES="$OUT_DIR/mixed_pages.html"
UGC="$OUT_DIR/ugc_xss.html"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic HTML5 & UGC/XSS corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"
PAGES_BYTES=$(wc -c < "$PAGES" | tr -d ' ')
UGC_BYTES=$(wc -c < "$UGC" | tr -d ' ')
PARSE_TOTAL_BYTES=$((PAGES_BYTES * 20))
SANITIZE_TOTAL_BYTES=$((UGC_BYTES * 20))

echo "==> Building Pion Native benchmarks (--release)"
pionc build --release -o "$BIN_DIR/pion_parse" "$BENCH_DIR/pion_parse"
pionc build --release -o "$BIN_DIR/pion_select" "$BENCH_DIR/pion_select"
pionc build --release -o "$BIN_DIR/pion_sanitize" "$BENCH_DIR/pion_sanitize"

echo "==> Building Rust scraper + ammonia benchmarks (--release, Cargo in /private/tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/bench_parse" "$BIN_DIR/rust_parse"
cp "$OUT_DIR/rust-target/release/bench_select" "$BIN_DIR/rust_select"
cp "$OUT_DIR/rust-target/release/bench_sanitize" "$BIN_DIR/rust_sanitize"

echo "==> Building Go golang.org/x/net/html benchmark (in /private/tmp)"
rm -rf "$OUT_DIR/go-proj"
mkdir -p "$OUT_DIR/go-proj"
cp "$BENCH_DIR/go/go.mod" "$BENCH_DIR/go/main.go" "$OUT_DIR/go-proj/"
(
  cd "$OUT_DIR/go-proj"
  go mod tidy
  go build -o "$BIN_DIR/go_parse" .
)

echo ""
echo "=== BENCH 1: HTML5 Document Parse + Text/Link Extraction (20 rounds, $PARSE_TOTAL_BYTES B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "HTML Bench 1: HTML5 Document Parse + Text/Link Extraction (20 rounds)" \
  --impl "pion=$BIN_DIR/pion_parse $PAGES" \
  --impl "rust_scraper=$BIN_DIR/rust_parse $PAGES" \
  --impl "go_net_html=$BIN_DIR/go_parse $PAGES" \
  --baseline rust_scraper \
  --warmup 1 --rounds 5 --bytes "$PARSE_TOTAL_BYTES" \
  --md-out "$OUT_DIR/parse.md" --json-out "$OUT_DIR/parse.json"

echo ""
echo "=== BENCH 2: CSS Selector Query on Large DOM (50 rounds x 5 selectors = 250 queries) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "HTML Bench 2: CSS Selector Query on Large DOM (250 complex queries)" \
  --impl "pion=$BIN_DIR/pion_select $PAGES" \
  --impl "rust_scraper=$BIN_DIR/rust_select $PAGES" \
  --baseline rust_scraper \
  --warmup 1 --rounds 5 --ops 250 \
  --md-out "$OUT_DIR/select.md" --json-out "$OUT_DIR/select.json"

echo ""
echo "=== BENCH 3: HTML XSS Sanitization Throughput (20 rounds, $SANITIZE_TOTAL_BYTES B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "HTML Bench 3: HTML XSS Sanitization Throughput (20 rounds)" \
  --impl "pion=$BIN_DIR/pion_sanitize $UGC" \
  --impl "rust_ammonia=$BIN_DIR/rust_sanitize $UGC" \
  --baseline rust_ammonia \
  --warmup 1 --rounds 5 --bytes "$SANITIZE_TOTAL_BYTES" \
  --md-out "$OUT_DIR/sanitize.md" --json-out "$OUT_DIR/sanitize.json"
