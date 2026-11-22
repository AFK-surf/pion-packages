#!/bin/sh
# Head-to-head benchmark runner for packages/semver (Pion Native vs Rust dtolnay/semver --release).
# All build artifacts and temporary inputs are placed in /tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-semver-bench"
BIN_DIR="$OUT_DIR/bin"
VERSIONS_FILE="$OUT_DIR/versions_20k.txt"
REQS_FILE="$OUT_DIR/reqs_2k.txt"
VER_ITERS="${1:-20}"
REQ_VER_LIMIT="${2:-500}"
REQ_ITERS="${3:-5}"

mkdir -p "$BIN_DIR"

echo "==> Generating 20,000 SemVer versions + 2,000 Cargo VersionReqs -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$VERSIONS_FILE" "$REQS_FILE" 20000 2000
VER_BYTES=$(wc -c < "$VERSIONS_FILE" | tr -d ' ')
TOTAL_VER_BYTES=$((VER_BYTES * VER_ITERS))
TOTAL_VER_OPS=$((20000 * VER_ITERS))
TOTAL_REQ_OPS=$((2000 * REQ_VER_LIMIT * REQ_ITERS))

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_semver" "$BENCH_DIR/pion_semver"

echo "==> Building Rust semver benchmark (--release, build & lockfile in /tmp)"
rm -rf "$OUT_DIR/rust_src"
mkdir -p "$OUT_DIR/rust_src"
cp -R "$BENCH_DIR/rust_semver/Cargo.toml" "$BENCH_DIR/rust_semver/src" "$OUT_DIR/rust_src/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust_src/Cargo.toml"
cp "$OUT_DIR/rust-target/release/semver-bench-rust" "$BIN_DIR/rust_semver"

echo ""
echo "=== Bench 1: Version::parse + sort + to_string (20,000 versions x ${VER_ITERS} iters = ${TOTAL_VER_OPS} ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Bench 1: Version::parse + sort + format (20k x ${VER_ITERS} = ${TOTAL_VER_OPS} ops)" \
  --impl "pion=$BIN_DIR/pion_semver version $VERSIONS_FILE $VER_ITERS" \
  --impl "rust_semver=$BIN_DIR/rust_semver version $VERSIONS_FILE $VER_ITERS" \
  --baseline rust_semver \
  --warmup 1 --rounds 5 --ops "$TOTAL_VER_OPS" --bytes "$TOTAL_VER_BYTES" \
  --md-out "$OUT_DIR/bench1_version.md" --json-out "$OUT_DIR/bench1_version.json"

echo ""
echo "=== Bench 2: VersionReq::parse + matches matrix (2,000 reqs x ${REQ_VER_LIMIT} vers x ${REQ_ITERS} iters = ${TOTAL_REQ_OPS} matches) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Bench 2: VersionReq::parse + matches (2k x ${REQ_VER_LIMIT} x ${REQ_ITERS} = ${TOTAL_REQ_OPS} ops)" \
  --impl "pion=$BIN_DIR/pion_semver req $REQS_FILE $VERSIONS_FILE $REQ_VER_LIMIT $REQ_ITERS" \
  --impl "rust_semver=$BIN_DIR/rust_semver req $REQS_FILE $VERSIONS_FILE $REQ_VER_LIMIT $REQ_ITERS" \
  --baseline rust_semver \
  --warmup 1 --rounds 5 --ops "$TOTAL_REQ_OPS" \
  --md-out "$OUT_DIR/bench2_req.md" --json-out "$OUT_DIR/bench2_req.json"
