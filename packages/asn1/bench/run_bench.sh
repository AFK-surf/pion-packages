#!/bin/sh
# Head-to-head benchmark runner for packages/asn1:
# Pion Native (packages/asn1) vs Go 1.27 (crypto/x509 + encoding/pem + encoding/asn1)
# vs Rust (x509-parser + der + pem --release --locked).
# All build artifacts and temporary inputs are placed in /private/tmp/w10-asn1.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/w10-asn1/bench"
BIN_DIR="$OUT_DIR/bin"
PEM_FILE="$OUT_DIR/certs_100.pem"
DER_FILE="$OUT_DIR/certs_100.derbin"

mkdir -p "$BIN_DIR"

echo "==> Generating 100 multi-algorithm OpenSSL X.509 v3 certificates"
python3 "$BENCH_DIR/gen_corpus.py" "$PEM_FILE" "$DER_FILE"
PEM_RAW_BYTES=$(wc -c < "$PEM_FILE" | tr -d ' ')
PEM_TOTAL_BYTES=$(( PEM_RAW_BYTES * 100 ))
DER_RAW_BYTES=$(wc -c < "$DER_FILE" | tr -d ' ')
DER_TOTAL_BYTES=$(( (DER_RAW_BYTES - 400) * 500 ))

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Go benchmark (go1.27)"
rm -rf "$OUT_DIR/go-build"
cp -R "$BENCH_DIR/go" "$OUT_DIR/go-build"
(cd "$OUT_DIR/go-build" && go build -o "$BIN_DIR/go_bench" .)

echo "==> Building Rust benchmark (--release --locked, target in /private/tmp/w10-asn1)"
rm -rf "$OUT_DIR/rust-build"
cp -R "$BENCH_DIR/rust" "$OUT_DIR/rust-build"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$OUT_DIR/rust-build/Cargo.toml"
cp "$OUT_DIR/rust-target/release/asn1_bench_rust" "$BIN_DIR/rust_bench"

echo ""
echo "=== WORKLOAD 1: Real PEM Cert Chain Full Parse (100 certs x 100 = 10,000 certs) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "ASN.1/X.509: PEM Cert Chain Full Parse (10,000 multi-algo v3 certs)" \
  --impl "pion=$BIN_DIR/pion_bench pem_chain $PEM_FILE" \
  --impl "go_x509=$BIN_DIR/go_bench pem_chain $PEM_FILE" \
  --impl "rust_x509=$BIN_DIR/rust_bench pem_chain $PEM_FILE" \
  --baseline go_x509 \
  --warmup 1 --rounds 5 --ops 10000 --bytes "$PEM_TOTAL_BYTES" \
  --md-out "$OUT_DIR/w1_pem_chain.md" --json-out "$OUT_DIR/w1_pem_chain.json"

echo ""
echo "=== WORKLOAD 2: Pure DER X.509 v3 Parse + SAN Hostname Verify (50,000 certs) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "ASN.1/X.509: Pure DER Parse + 3x SAN Hostname Verify (50,000 certs)" \
  --impl "pion=$BIN_DIR/pion_bench der_x509_host $DER_FILE" \
  --impl "go_x509=$BIN_DIR/go_bench der_x509_host $DER_FILE" \
  --impl "rust_x509=$BIN_DIR/rust_bench der_x509_host $DER_FILE" \
  --baseline go_x509 \
  --warmup 1 --rounds 5 --ops 50000 --bytes "$DER_TOTAL_BYTES" \
  --md-out "$OUT_DIR/w2_der_x509_host.md" --json-out "$OUT_DIR/w2_der_x509_host.json"

echo ""
echo "=== WORKLOAD 3: Generic ASN.1 DER TLV Encode + Decode Roundtrip (100,000 structures) ==="
TLV_BYTES=$("$BIN_DIR/pion_bench" der_tlv_roundtrip | awk -F= '/^encoded_bytes=/{print $2}')
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "ASN.1 DER: Generic TLV Encode + Decode Roundtrip (100,000 structures)" \
  --impl "pion=$BIN_DIR/pion_bench der_tlv_roundtrip" \
  --impl "go_asn1=$BIN_DIR/go_bench der_tlv_roundtrip" \
  --impl "rust_der=$BIN_DIR/rust_bench der_tlv_roundtrip" \
  --baseline go_asn1 \
  --warmup 1 --rounds 5 --ops 100000 --bytes "$TLV_BYTES" \
  --md-out "$OUT_DIR/w3_der_tlv.md" --json-out "$OUT_DIR/w3_der_tlv.json"
