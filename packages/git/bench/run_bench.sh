#!/bin/sh
# Head-to-head benchmark runner for packages/git:
# Pion Native (packages/git) vs Rust gix (gix-object / gix-pack / gix-index / gix-packetline --release --locked).
# All build artifacts and temporary inputs go to /tmp/w12-git-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/w12-git-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic real git CLI corpora -> $OUT_DIR"
CORPUS_INFO=$(python3 "$BENCH_DIR/gen_corpus.py" "$OUT_DIR")
echo "  $CORPUS_INFO"
W1_BYTES=$(printf '%s\n' "$CORPUS_INFO" | sed -n 's/.*w1_pack=\([0-9]*\).*/\1/p')
W2_BYTES=$(printf '%s\n' "$CORPUS_INFO" | sed -n 's/.*w2_bundle=\([0-9]*\).*/\1/p')
W3_V2=$(printf '%s\n' "$CORPUS_INFO" | sed -n 's/.*w3_idx_v2=\([0-9]*\).*/\1/p')
W3_V4=$(printf '%s\n' "$CORPUS_INFO" | sed -n 's/.*w3_idx_v4=\([0-9]*\).*/\1/p')
W3_PKT=$(printf '%s\n' "$CORPUS_INFO" | sed -n 's/.*w3_pkt=\([0-9]*\).*/\1/p')
W3_BYTES=$((W3_V2 + W3_V4 + W3_PKT))

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust gix benchmark (--release --locked, target in /tmp/w12-git-bench)"
rm -rf "$OUT_DIR/rust-build"
cp -R "$BENCH_DIR/rust" "$OUT_DIR/rust-build"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build -q --release --locked \
  --manifest-path "$OUT_DIR/rust-build/Cargo.toml"
cp "$OUT_DIR/rust-target/release/git_bench_rust" "$BIN_DIR/rust_bench"

echo ""
echo "=== WORKLOAD 1: Real Git Packfile v2 Full Unpack + OFS_DELTA Resolve + SHA-1 Verify (x5 iters) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Packfile v2 Full Unpack + Delta Resolve + SHA-1 (x5 iters)" \
  --impl "pion=$BIN_DIR/pion_bench w1 $OUT_DIR/w1.pack 5" \
  --impl "rust_gix=$BIN_DIR/rust_bench w1 $OUT_DIR/w1.pack 5" \
  --baseline rust_gix \
  --warmup 1 --rounds 5 --bytes "$((W1_BYTES * 5))" \
  --md-out "$OUT_DIR/w1.md" --json-out "$OUT_DIR/w1.json"

echo ""
echo "=== WORKLOAD 2: Large Tree (200x150) + Commit (2,000) Parse & Canonical Re-encode (x3 iters) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Tree (200x150) + Commit (2,000) Parse & Re-encode (x3 iters)" \
  --impl "pion=$BIN_DIR/pion_bench w2 $OUT_DIR/w2_objects.bundle 3" \
  --impl "rust_gix=$BIN_DIR/rust_bench w2 $OUT_DIR/w2_objects.bundle 3" \
  --baseline rust_gix \
  --warmup 1 --rounds 5 --bytes "$((W2_BYTES * 3))" \
  --md-out "$OUT_DIR/w2.md" --json-out "$OUT_DIR/w2.json"

echo ""
echo "=== WORKLOAD 3: .git/index v2+v4 (2,000 files each) + 10,000 pkt-line Decode (x5 iters) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: .git/index v2+v4 (4k entries) + 10k pkt-line Decode (x5 iters)" \
  --impl "pion=$BIN_DIR/pion_bench w3 $OUT_DIR/w3_index_v2.bin $OUT_DIR/w3_index_v4.bin $OUT_DIR/w3_pktline.bin 5" \
  --impl "rust_gix=$BIN_DIR/rust_bench w3 $OUT_DIR/w3_index_v2.bin $OUT_DIR/w3_index_v4.bin $OUT_DIR/w3_pktline.bin 5" \
  --baseline rust_gix \
  --warmup 1 --rounds 5 --bytes "$((W3_BYTES * 5))" \
  --md-out "$OUT_DIR/w3.md" --json-out "$OUT_DIR/w3.json"
