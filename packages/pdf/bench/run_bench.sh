#!/bin/sh
# Head-to-head benchmark runner for packages/pdf:
# Pion Native (--release) vs Rust pdf-writer + flate2 (--release),
# with third-party Rust `lopdf` structural parsing verification on all generated PDFs.
# All build artifacts, Cargo target/, and dumped PDFs are isolated in /tmp.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/pion-pdf-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
pionc fmt --check "$BENCH_DIR/pion_bench"
pionc check --json "$BENCH_DIR/pion_bench"
pionc build --release -o "$BIN_DIR/pion_pdf_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust pdf-writer + flate2 + lopdf benchmark (--release, isolated in /tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/pdf-bench-rust" "$BIN_DIR/rust_pdf_bench"

echo ""
echo "==> Generating sample PDFs and verifying with third-party Rust lopdf parser"
"$BIN_DIR/pion_pdf_bench" report100 "$OUT_DIR/pion_report100.pdf" >/dev/null
"$BIN_DIR/rust_pdf_bench" report100 "$OUT_DIR/rust_report100.pdf" >/dev/null
"$BIN_DIR/pion_pdf_bench" images_flate "$OUT_DIR/pion_images_flate.pdf" >/dev/null
"$BIN_DIR/rust_pdf_bench" images_flate "$OUT_DIR/rust_images_flate.pdf" >/dev/null
"$BIN_DIR/pion_pdf_bench" images_rle "$OUT_DIR/pion_images_rle.pdf" >/dev/null
"$BIN_DIR/rust_pdf_bench" images_rle "$OUT_DIR/rust_images_rle.pdf" >/dev/null

"$BIN_DIR/rust_pdf_bench" lopdf_verify "$OUT_DIR/pion_report100.pdf" 100
"$BIN_DIR/rust_pdf_bench" lopdf_verify "$OUT_DIR/rust_report100.pdf" 100
"$BIN_DIR/rust_pdf_bench" lopdf_verify "$OUT_DIR/pion_images_flate.pdf" 10
"$BIN_DIR/rust_pdf_bench" lopdf_verify "$OUT_DIR/rust_images_flate.pdf" 10
"$BIN_DIR/rust_pdf_bench" lopdf_verify "$OUT_DIR/pion_images_rle.pdf" 10
"$BIN_DIR/rust_pdf_bench" lopdf_verify "$OUT_DIR/rust_images_rle.pdf" 10

ls -lh "$OUT_DIR"/*.pdf

echo ""
echo "=== BENCH 1: 100-Page Vector + Text Report (/FlateDecode) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "PDF 1.4: 100-Page Vector + Text Report (/FlateDecode)" \
  --impl "pion=$BIN_DIR/pion_pdf_bench report100" \
  --impl "rust_pdf_writer=$BIN_DIR/rust_pdf_bench report100" \
  --baseline rust_pdf_writer \
  --warmup 1 --rounds 5 --ops 100 \
  --md-out "$OUT_DIR/bench_report100.md" --json-out "$OUT_DIR/bench_report100.json"

echo ""
echo "=== BENCH 2: 10-Page 800x600 RGBA Image Export (/FlateDecode) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "PDF 1.4: 10-Page 800x600 Image Export (/FlateDecode)" \
  --impl "pion=$BIN_DIR/pion_pdf_bench images_flate" \
  --impl "rust_pdf_writer=$BIN_DIR/rust_pdf_bench images_flate" \
  --baseline rust_pdf_writer \
  --warmup 1 --rounds 5 --bytes 14400000 \
  --md-out "$OUT_DIR/bench_images_flate.md" --json-out "$OUT_DIR/bench_images_flate.json"

echo ""
echo "=== BENCH 3: 10-Page 800x600 RGBA Image Export (/RunLengthDecode) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "PDF 1.4: 10-Page 800x600 Image Export (/RunLengthDecode)" \
  --impl "pion=$BIN_DIR/pion_pdf_bench images_rle" \
  --impl "rust_pdf_writer=$BIN_DIR/rust_pdf_bench images_rle" \
  --baseline rust_pdf_writer \
  --warmup 1 --rounds 5 --bytes 14400000 \
  --md-out "$OUT_DIR/bench_images_rle.md" --json-out "$OUT_DIR/bench_images_rle.json"
