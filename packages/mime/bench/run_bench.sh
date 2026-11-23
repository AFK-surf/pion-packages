#!/bin/sh
# Head-to-head benchmark runner for packages/mime:
# Pion Native (--release) vs Go 1.27 stdlib (mime / mime/multipart / mime/quotedprintable)
# and Rust (mime 0.3.17 + infer 0.16.0, --release --locked).
# All build artifacts and corpora are isolated in /private/tmp/w10-mime/bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/w10-mime/bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic MIME corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$OUT_DIR"

MP_CORPUS="$OUT_DIR/multipart_50mb.bin"
HF_CORPUS="$OUT_DIR/headers_full.txt"
MT_CORPUS="$OUT_DIR/headers_mt.txt"
QP_CORPUS="$OUT_DIR/qp_16mb.bin"
SN_CORPUS="$OUT_DIR/sniff_100k.bin"

MP_BYTES=$(wc -c < "$MP_CORPUS" | tr -d ' ')
HF_BYTES=$(($(wc -c < "$HF_CORPUS" | tr -d ' ') * 200))
MT_BYTES=$(($(wc -c < "$MT_CORPUS" | tr -d ' ') * 200))
QP_BYTES=$(wc -c < "$QP_CORPUS" | tr -d ' ')
SN_BYTES=$(($(wc -c < "$SN_CORPUS" | tr -d ' ') * 1000))

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_mime_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Go 1.27 stdlib benchmark (isolated in /private/tmp, locked go.sum)"
rm -rf "$OUT_DIR/go-proj"
mkdir -p "$OUT_DIR/go-proj"
cp "$BENCH_DIR/go/go.mod" "$BENCH_DIR/go/go.sum" "$BENCH_DIR/go/main.go" "$OUT_DIR/go-proj/"
(cd "$OUT_DIR/go-proj" && go build -mod=readonly -o "$BIN_DIR/go_mime_bench" .)

echo "==> Building Rust mime+infer benchmark (--release --locked, isolated in /private/tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/Cargo.lock" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/mime-bench-rust" "$BIN_DIR/rust_mime_bench"

echo ""
echo "=== BENCH 1: 50 MB multipart/form-data Parse (10x5MB binary + 200 form fields) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Multipart/form-data Parse (50 MB: 10x5MB binary + 200 fields)" \
  --impl "pion=$BIN_DIR/pion_mime_bench multipart $MP_CORPUS" \
  --impl "go_stdlib=$BIN_DIR/go_mime_bench multipart $MP_CORPUS" \
  --baseline go_stdlib \
  --warmup 1 --rounds 5 --bytes "$MP_BYTES" \
  --md-out "$OUT_DIR/bench_multipart.md" --json-out "$OUT_DIR/bench_multipart.json"

echo ""
echo "=== BENCH 2a: 200k Mixed Content-Type / Content-Disposition / RFC 2047 Header Parse ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Mixed MIME Headers Batch Parse (200k ops: Media-Type + RFC 2231/5987 + RFC 2047)" \
  --impl "pion=$BIN_DIR/pion_mime_bench headers_full $HF_CORPUS" \
  --impl "go_stdlib=$BIN_DIR/go_mime_bench headers_full $HF_CORPUS" \
  --baseline go_stdlib \
  --warmup 1 --rounds 5 --ops 200000 --bytes "$HF_BYTES" \
  --md-out "$OUT_DIR/bench_headers_full.md" --json-out "$OUT_DIR/bench_headers_full.json"

echo ""
echo "=== BENCH 2b: 200k Content-Type Media-Type Parse (Pion vs Go 1.27 vs Rust mime 0.3) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Content-Type Media-Type Batch Parse (200k ops)" \
  --impl "pion=$BIN_DIR/pion_mime_bench headers_mt $MT_CORPUS" \
  --impl "go_stdlib=$BIN_DIR/go_mime_bench headers_mt $MT_CORPUS" \
  --impl "rust_mime=$BIN_DIR/rust_mime_bench headers_mt $MT_CORPUS" \
  --baseline rust_mime \
  --warmup 1 --rounds 5 --ops 200000 --bytes "$MT_BYTES" \
  --md-out "$OUT_DIR/bench_headers_mt.md" --json-out "$OUT_DIR/bench_headers_mt.json"

echo ""
echo "=== BENCH 3a: 16 MB Quoted-Printable Decode ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Quoted-Printable Decode (16 MB UTF-8 + soft-wrap)" \
  --impl "pion=$BIN_DIR/pion_mime_bench qp $QP_CORPUS" \
  --impl "go_stdlib=$BIN_DIR/go_mime_bench qp $QP_CORPUS" \
  --baseline go_stdlib \
  --warmup 1 --rounds 5 --bytes "$QP_BYTES" \
  --md-out "$OUT_DIR/bench_qp.md" --json-out "$OUT_DIR/bench_qp.json"

echo ""
echo "=== BENCH 3b: 100k Magic-Byte MIME Sniffing (Pion vs Rust infer) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Magic-Byte MIME Sniffing (100k ops, 20 binary formats)" \
  --impl "pion=$BIN_DIR/pion_mime_bench sniff $SN_CORPUS" \
  --impl "rust_infer=$BIN_DIR/rust_mime_bench sniff $SN_CORPUS" \
  --baseline rust_infer \
  --warmup 1 --rounds 5 --ops 100000 --bytes "$SN_BYTES" \
  --md-out "$OUT_DIR/bench_sniff.md" --json-out "$OUT_DIR/bench_sniff.json"
