#!/bin/sh
# Head-to-head benchmark runner for packages/dns:
# Pion Native (--release) vs Go 1.27 miekg/dns vs Rust hickory-proto 0.24.2 (--release).
# All build artifacts, Cargo/Go lockfiles, and corpora are isolated in /private/tmp.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/pion-dns-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic DNS corpus -> $OUT_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$OUT_DIR"

CORPUS="$OUT_DIR/corpus.bin"
CORPUS_BYTES=$(($(wc -c < "$CORPUS" | tr -d ' ') * 200))

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_dns_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Go miekg/dns benchmark (isolated in /private/tmp, locked go.sum)"
rm -rf "$OUT_DIR/go-proj"
mkdir -p "$OUT_DIR/go-proj"
cp "$BENCH_DIR/go/go.mod" "$BENCH_DIR/go/go.sum" "$BENCH_DIR/go/main.go" "$OUT_DIR/go-proj/"
(cd "$OUT_DIR/go-proj" && go build -mod=readonly -o "$BIN_DIR/go_dns_bench" .)

echo "==> Building Rust hickory-proto 0.24.2 benchmark (--release --locked, isolated in /private/tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/Cargo.lock" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/dns-bench-rust" "$BIN_DIR/rust_dns_bench"

echo ""
echo "=== BENCH 1: Mixed DNS Response Batch Decode (200,000 packets) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "DNS Mixed Response Batch Decode (200k packets: A/AAAA/CNAME/MX/TXT/SRV/SOA/OPT)" \
  --impl "pion=$BIN_DIR/pion_dns_bench decode $CORPUS" \
  --impl "go_miekg_dns=$BIN_DIR/go_dns_bench decode $CORPUS" \
  --impl "rust_hickory=$BIN_DIR/rust_dns_bench decode $CORPUS" \
  --baseline rust_hickory \
  --warmup 1 --rounds 5 --ops 200000 --bytes "$CORPUS_BYTES" \
  --md-out "$OUT_DIR/bench_decode.md" --json-out "$OUT_DIR/bench_decode.json"

echo ""
echo "=== BENCH 2: Batch DNS Response Encode with Compression (200,000 packets) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "DNS Mixed Response Batch Encode with Compression (200k packets)" \
  --impl "pion=$BIN_DIR/pion_dns_bench encode $CORPUS" \
  --impl "go_miekg_dns=$BIN_DIR/go_dns_bench encode $CORPUS" \
  --impl "rust_hickory=$BIN_DIR/rust_dns_bench encode $CORPUS" \
  --baseline rust_hickory \
  --warmup 1 --rounds 5 --ops 200000 --bytes "$CORPUS_BYTES" \
  --md-out "$OUT_DIR/bench_encode.md" --json-out "$OUT_DIR/bench_encode.json"

echo ""
echo "=== BENCH 3: High-Frequency DNS Query Build + Encode + Decode Roundtrip (500,000 ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "DNS Query Build + Encode + Decode Roundtrip (500k ops)" \
  --impl "pion=$BIN_DIR/pion_dns_bench query_rt" \
  --impl "go_miekg_dns=$BIN_DIR/go_dns_bench query_rt" \
  --impl "rust_hickory=$BIN_DIR/rust_dns_bench query_rt" \
  --baseline rust_hickory \
  --warmup 1 --rounds 5 --ops 500000 \
  --md-out "$OUT_DIR/bench_query_rt.md" --json-out "$OUT_DIR/bench_query_rt.json"
