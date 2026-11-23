#!/bin/sh
# Head-to-head benchmark runner for packages/msgpack:
# Pion Native (packages/msgpack) vs Rust (rmpv 1.3.1 --release) vs Go (vmihailenco/msgpack/v5 v5.4.1).
# All build artifacts and temporary corpora live in /private/tmp so git worktree stays 100% clean.
set -eu

export PATH="${HOME}/.pion/bin:${HOME}/.cargo/bin:${PATH}"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/pion-msgpack-bench"
BIN_DIR="$OUT_DIR/bin"
RPC_CORPUS="$OUT_DIR/rpc_2000.msgpack"
LARGE_CORPUS="$OUT_DIR/large_16m.msgpack"

mkdir -p "$BIN_DIR"

echo "==> Generating MessagePack corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_corpus.py" rpc "$RPC_CORPUS" 2000
python3 "$BENCH_DIR/gen_corpus.py" large "$LARGE_CORPUS" 64
RPC_BYTES=$(wc -c < "$RPC_CORPUS" | tr -d ' ')
LARGE_BYTES=$(wc -c < "$LARGE_CORPUS" | tr -d ' ')
TOTAL_RPC_BYTES=$((RPC_BYTES * 40))
TOTAL_LARGE_BYTES=$((LARGE_BYTES * 4))
echo "    rpc_2000.msgpack: ${RPC_BYTES} B (40x = ${TOTAL_RPC_BYTES} B)"
echo "    large_16m.msgpack: ${LARGE_BYTES} B (4x = ${TOTAL_LARGE_BYTES} B)"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust rmpv 1.3.1 benchmark (--release, target in /private/tmp)"
rm -rf "$OUT_DIR/rust-build"
cp -R "$BENCH_DIR/rust" "$OUT_DIR/rust-build"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-build/Cargo.toml"
cp "$OUT_DIR/rust-target/release/msgpack_bench_rust" "$BIN_DIR/rust_bench"

echo "==> Building Go vmihailenco/msgpack/v5 benchmark (copying module to /private/tmp)"
rm -rf "$OUT_DIR/go-build"
cp -R "$BENCH_DIR/go" "$OUT_DIR/go-build"
(cd "$OUT_DIR/go-build" && go mod tidy && go build -o "$BIN_DIR/go_bench" .)

echo ""
echo "=== WORKLOAD 1: Nested RPC/Telemetry Decode (40 x 2,000 = 80,000 records) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "MessagePack: Nested RPC/Telemetry Decode (80k records)" \
  --impl "pion=$BIN_DIR/pion_bench decode-rpc $RPC_CORPUS" \
  --impl "rust_rmpv=$BIN_DIR/rust_bench decode-rpc $RPC_CORPUS" \
  --impl "go_vmihailenco=$BIN_DIR/go_bench decode-rpc $RPC_CORPUS" \
  --baseline go_vmihailenco \
  --warmup 1 --rounds 5 --ops 80000 --bytes "$TOTAL_RPC_BYTES" \
  --md-out "$OUT_DIR/decode_rpc.md" --json-out "$OUT_DIR/decode_rpc.json"

echo ""
echo "=== WORKLOAD 2: Nested RPC/Telemetry Encode (50,000 records) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "MessagePack: Nested RPC/Telemetry Encode (50k records)" \
  --impl "pion=$BIN_DIR/pion_bench encode-rpc" \
  --impl "rust_rmpv=$BIN_DIR/rust_bench encode-rpc" \
  --impl "go_vmihailenco=$BIN_DIR/go_bench encode-rpc" \
  --baseline go_vmihailenco \
  --warmup 1 --rounds 5 --ops 50000 \
  --md-out "$OUT_DIR/encode_rpc.md" --json-out "$OUT_DIR/encode_rpc.json"

echo ""
echo "=== WORKLOAD 3: Large bin + str + array Decode (4 x ~16 MiB = ~64 MiB) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "MessagePack: Large bin + str + array Decode (~64 MiB)" \
  --impl "pion=$BIN_DIR/pion_bench decode-large $LARGE_CORPUS" \
  --impl "rust_rmpv=$BIN_DIR/rust_bench decode-large $LARGE_CORPUS" \
  --impl "go_vmihailenco=$BIN_DIR/go_bench decode-large $LARGE_CORPUS" \
  --baseline go_vmihailenco \
  --warmup 1 --rounds 5 --bytes "$TOTAL_LARGE_BYTES" \
  --md-out "$OUT_DIR/decode_large.md" --json-out "$OUT_DIR/decode_large.json"
