#!/bin/sh
# Head-to-head benchmark runner for packages/jwt:
# Pion Native vs Rust jsonwebtoken (=12.0.0, --release) vs Go golang-jwt/jwt/v5 (v5.3.1).
# All build artifacts, Cargo.lock, go.sum, and corpus files are isolated in /tmp.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-jwt-bench"
BIN_DIR="$OUT_DIR/bin"
CORPUS="$OUT_DIR/tokens_50000.txt"

mkdir -p "$BIN_DIR" "$OUT_DIR/rust-build/src" "$OUT_DIR/go-build"

echo "==> Generating deterministic 50,000-token corpus (25k HS256 + 25k HS512)"
python3 "$BENCH_DIR/gen_data.py" "$CORPUS" 50000

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_jwt_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust jsonwebtoken benchmark (--release, isolated in /tmp)"
cp "$BENCH_DIR/rust/Cargo.toml" "$OUT_DIR/rust-build/Cargo.toml"
cp "$BENCH_DIR/rust/src/main.rs" "$OUT_DIR/rust-build/src/main.rs"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-build/Cargo.toml"
cp "$OUT_DIR/rust-target/release/jwt-bench-rust" "$BIN_DIR/rust_jwt_bench"

echo "==> Building Go golang-jwt/jwt/v5 benchmark (isolated in /tmp)"
cp "$BENCH_DIR/go/go.mod" "$OUT_DIR/go-build/go.mod"
cp "$BENCH_DIR/go/main.go" "$OUT_DIR/go-build/main.go"
(cd "$OUT_DIR/go-build" && go mod tidy && go build -o "$BIN_DIR/go_jwt_bench" .)

echo ""
echo "=== BENCH 1: Sign / Encode 50,000 JWTs (25k HS256 + 25k HS512) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "JWT Bench 1: Sign / Encode 50,000 JWTs (25k HS256 + 25k HS512)" \
  --impl "pion=$BIN_DIR/pion_jwt_bench sign" \
  --impl "rust_jsonwebtoken=$BIN_DIR/rust_jwt_bench sign" \
  --impl "go_golang_jwt=$BIN_DIR/go_jwt_bench sign" \
  --baseline rust_jsonwebtoken \
  --warmup 1 --rounds 5 --ops 50000 \
  --md-out "$OUT_DIR/bench_sign.md" --json-out "$OUT_DIR/bench_sign.json"

echo ""
echo "=== BENCH 2: Verify / Decode 50,000 JWTs (25k HS256 + 25k HS512 + Claims Validation) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "JWT Bench 2: Verify / Decode 50,000 JWTs (25k HS256 + 25k HS512)" \
  --impl "pion=$BIN_DIR/pion_jwt_bench verify $CORPUS" \
  --impl "rust_jsonwebtoken=$BIN_DIR/rust_jwt_bench verify $CORPUS" \
  --impl "go_golang_jwt=$BIN_DIR/go_jwt_bench verify $CORPUS" \
  --baseline rust_jsonwebtoken \
  --warmup 1 --rounds 5 --ops 50000 \
  --md-out "$OUT_DIR/bench_verify.md" --json-out "$OUT_DIR/bench_verify.json"
