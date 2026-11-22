#!/bin/sh
# Head-to-head benchmark runner for packages/websocket:
# Pion Native vs Rust tungstenite (--release) vs Go coder/websocket.
# All build artifacts are placed in /tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-websocket-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_ws_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust tungstenite benchmark (--release, target in /tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust/Cargo.toml"
cp "$OUT_DIR/rust-target/release/websocket-bench-rust" "$BIN_DIR/rust_ws_bench"

echo "==> Building Go coder/websocket benchmark"
(cd "$BENCH_DIR/go" && go build -o "$BIN_DIR/go_ws_bench" .)

echo ""
echo "=== WORKLOAD: 50,000 Masked Frames (~50.8 MB Mixed Text+Binary+Fragmented+Ping) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WebSocket: 50k Masked Frames Encode + Stream Decode (~50.8 MB)" \
  --impl "pion=$BIN_DIR/pion_ws_bench" \
  --impl "rust_tungstenite=$BIN_DIR/rust_ws_bench" \
  --impl "go_coder_ws=$BIN_DIR/go_ws_bench" \
  --baseline rust_tungstenite \
  --warmup 1 --rounds 5 --ops 50000 --bytes 50880000 \
  --md-out "$OUT_DIR/ws_bench.md" --json-out "$OUT_DIR/ws_bench.json"
