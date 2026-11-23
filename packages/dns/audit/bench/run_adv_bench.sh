#!/bin/sh
# Adversarial head-to-head benchmarks for packages/dns (red-team audit).
# pion (--release) vs Go miekg/dns v1.1.63 vs Rust hickory-proto =0.24.2
# (--release, --locked), via scripts/bench_compare.py (strictly interleaved,
# mandatory stdout SHA-256 equality). Artifacts live in $RT_DIR only.
set -eu
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../../.." && pwd)
RT_DIR=${RT_DIR:-/private/tmp/rt-dns}
BIN="$RT_DIR/bin"; DATA="$RT_DIR/bench"; RES="$RT_DIR/bench-results"
WARMUP=${WARMUP:-1}; ROUNDS=${ROUNDS:-5}
mkdir -p "$BIN" "$DATA" "$RES"

echo "==> build"
pionc build --release -o "$BIN/pion_bench" "$HERE/pion_bench"
rm -rf "$RT_DIR/bench-go" && mkdir -p "$RT_DIR/bench-go"
cp "$HERE/go/go.mod" "$HERE/go/go.sum" "$HERE/go/main.go" "$RT_DIR/bench-go/"
(cd "$RT_DIR/bench-go" && GOCACHE="$RT_DIR/gocache" GOFLAGS=-mod=mod go build -o "$BIN/go_bench" .)
rm -rf "$RT_DIR/bench-rust" && mkdir -p "$RT_DIR/bench-rust"
cp -R "$HERE/rust/Cargo.toml" "$HERE/rust/Cargo.lock" "$HERE/rust/src" "$RT_DIR/bench-rust/"
CARGO_TARGET_DIR="$RT_DIR/rust-target" cargo build --release --locked --manifest-path "$RT_DIR/bench-rust/Cargo.toml"
cp "$RT_DIR/rust-target/release/dns-audit-bench-rust" "$BIN/rust_bench"

echo "==> inputs"
"$BIN/go_bench" gen plain 1 "$DATA/plain_1.txt"
"$BIN/go_bench" gen plain 500 "$DATA/plain_500.txt"
"$BIN/go_bench" gen plain 2000 "$DATA/plain_2000.txt"
"$BIN/go_bench" gen collide 2000 "$DATA/collide_2000.txt"
"$BIN/go_bench" gen collide 2750 "$DATA/collide_2750.txt"
"$BIN/go_bench" gen plain 2750 "$DATA/plain_2750.txt"

run() { # id title mode input rounds ops
  python3 "$ROOT/scripts/bench_compare.py" --title "$2" \
    --impl "pion=$BIN/pion_bench $3 $DATA/$4.txt $5" \
    --impl "go_miekg_dns=$BIN/go_bench $3 $DATA/$4.txt $5" \
    --impl "rust_hickory=$BIN/rust_bench $3 $DATA/$4.txt $5" \
    --baseline rust_hickory --warmup "$WARMUP" --rounds "$ROUNDS" --ops "$6" \
    --md-out "$RES/$1.md" --json-out "$RES/$1.json"
}
run A1 "A1 small response encode (1 question + 1 A, 1,000,000 msgs) - fixed per-message cost" encode plain_1 1000000 1000000
run A2 "A2 large response encode, 500 distinct owners (~10 KiB), 4,000 msgs" encode plain_500 4000 4000
run A3 "A3 large response encode, 2,000 distinct owners (~43 KiB, crosses 14-bit pointer limit), 1,000 msgs" encode plain_2000 1000 1000
run A4 "A4 HASH-COLLISION encode, 2,000 owners crafted to share pion's suffix-hash low 14 bits, 1,000 msgs" encode collide_2000 1000 1000
run A5 "A5 control for A6: 2,750 plain owners (~62 KiB), 1,000 msgs" encode plain_2750 1000 1000
run A6 "A6 HASH-COLLISION max-size encode, 2,750 crafted owners (~62 KiB), 1,000 msgs" encode collide_2750 1000 1000
run A7 "A7 large response decode, 2,000 owners, 1,000 msgs" decode plain_2000 1000 1000

# Diagnostic (pion only, not a cross-library comparison): A1 with compression
# disabled isolates the fixed cost of WireWriter's compression set-up
# (4 Int arrays of 64/64/128/128 slots + hashing) on every encode_message.
python3 "$ROOT/scripts/bench_compare.py" --title "D1 pion A1 with EncodeOptions::uncompressed() (diagnostic)" \
  --impl "pion_uncompressed=$BIN/pion_bench encode-uncompressed $DATA/plain_1.txt 1000000" \
  --warmup "$WARMUP" --rounds "$ROUNDS" --ops 1000000 \
  --md-out "$RES/D1.md" --json-out "$RES/D1.json"
