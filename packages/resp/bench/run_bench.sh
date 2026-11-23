#!/bin/sh
# Head-to-head benchmark runner for packages/resp:
# Pion Native (`packages/resp`, `--release`) vs Rust (`redis-protocol 6.0.0`, `--release`).
# All build artifacts and corpora live in /tmp/w13-resp-bench so git worktree stays 100% clean.
set -eu

export PATH="${HOME}/.pion/bin:${HOME}/.cargo/bin:${PATH}"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/w13-resp-bench"
BIN_DIR="$OUT_DIR/bin"
W1_CORPUS="$OUT_DIR/w1_resp3_200k.bin"

mkdir -p "$BIN_DIR"

echo "==> Generating W1 RESP3 corpus (200,000 mixed frames) -> $W1_CORPUS"
python3 "$BENCH_DIR/gen_data.py" "$W1_CORPUS" 200000
W1_BYTES=$(wc -c < "$W1_CORPUS" | tr -d ' ')
echo "    w1_resp3_200k.bin: ${W1_BYTES} B"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust redis-protocol 6.0.0 benchmark (--release, target in $OUT_DIR)"
rm -rf "$OUT_DIR/rust-build"
cp -R "$BENCH_DIR/rust" "$OUT_DIR/rust-build"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$OUT_DIR/rust-build/Cargo.toml"
cp "$OUT_DIR/rust-target/release/resp_bench_rust" "$BIN_DIR/rust_bench"

echo ""
echo "=== W1: 200,000 Mixed RESP3 Responses Streaming Decode (137B chunks) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "RESP3: 200k Mixed Responses Streaming Decode (137B chunks)" \
  --impl "pion=$BIN_DIR/pion_bench w1 $W1_CORPUS" \
  --impl "rust_redis_protocol=$BIN_DIR/rust_bench w1 $W1_CORPUS" \
  --baseline rust_redis_protocol \
  --warmup 1 --rounds 5 --ops 200000 --bytes "$W1_BYTES" \
  --md-out "$OUT_DIR/w1.md" --json-out "$OUT_DIR/w1.json"

echo ""
echo "=== W2: 500,000 Pipelined Commands Encode + Decode Roundtrip (SET/GET/HSET/MGET) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "RESP: 500k Pipelined Commands Encode + Decode Roundtrip" \
  --impl "pion=$BIN_DIR/pion_bench w2" \
  --impl "rust_redis_protocol=$BIN_DIR/rust_bench w2" \
  --baseline rust_redis_protocol \
  --warmup 1 --rounds 5 --ops 500000 \
  --md-out "$OUT_DIR/w2.md" --json-out "$OUT_DIR/w2.json"

echo ""
echo "=== W3: 2,000,000 Cluster key_slot ({hash_tag}) + 500,000 MOVED Redirect Parse ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Redis Cluster: 2M key_slot + 500k MOVED Redirect Parse" \
  --impl "pion=$BIN_DIR/pion_bench w3" \
  --impl "rust_redis_protocol=$BIN_DIR/rust_bench w3" \
  --baseline rust_redis_protocol \
  --warmup 1 --rounds 5 --ops 2000000 \
  --md-out "$OUT_DIR/w3.md" --json-out "$OUT_DIR/w3.json"
