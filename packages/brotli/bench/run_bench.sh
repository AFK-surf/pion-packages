#!/bin/sh
# Head-to-head benchmark runner for packages/brotli:
# Pion Native (--release) vs Rust brotli (--release) vs C libbrotlidec (-O3, optional).
# All build artifacts, Cargo lockfile, and corpora are isolated in /tmp.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-brotli-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  if command -v pionc >/dev/null 2>&1; then
    PIONC_BIN=$(command -v pionc)
  elif [ -x "${HOME:-}/.pion/bin/pionc" ]; then
    PIONC_BIN="${HOME}/.pion/bin/pionc"
  fi
fi

echo "==> Generating deterministic corpora (Web HTML/CSS/JS/JSON, WOFF2 font payload, 512 small packets) -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"

WEB_RAW="$OUT_DIR/web.bin"
WEB_BR="$OUT_DIR/web.br"
WOFF2_RAW="$OUT_DIR/woff2.bin"
WOFF2_BR="$OUT_DIR/woff2.br"
SMALL_RAW="$OUT_DIR/small_raw.bin"
SMALL_BATCH="$OUT_DIR/small_batch.bin"

WEB_SIZE=$(wc -c < "$WEB_RAW" | tr -d ' ')
WOFF2_SIZE=$(wc -c < "$WOFF2_RAW" | tr -d ' ')
SMALL_SIZE=$(wc -c < "$SMALL_RAW" | tr -d ' ')

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_brotli_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust brotli benchmark (--release, isolated in /tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/brotli-bench-rust" "$BIN_DIR/rust_brotli_bench"

HAS_C=0
if [ -d "/opt/homebrew/include/brotli" ] && [ -f "/opt/homebrew/lib/libbrotlidec.dylib" ]; then
  echo "==> Building C libbrotlidec benchmark (-O3)"
  cc -O3 -I/opt/homebrew/include "$BENCH_DIR/c/brotli_bench.c" \
    -L/opt/homebrew/lib -lbrotlidec -Wl,-rpath,/opt/homebrew/lib \
    -o "$BIN_DIR/c_brotli_bench"
  HAS_C=1
fi

echo "==> Verifying full-byte SHA-256 against reference raw corpora"
"$BIN_DIR/pion_brotli_bench" decode "$WEB_BR" 1 "$OUT_DIR/pion_web.out"
"$BIN_DIR/pion_brotli_bench" decode "$WOFF2_BR" 1 "$OUT_DIR/pion_woff2.out"
"$BIN_DIR/rust_brotli_bench" decode "$WEB_BR" 1 "$OUT_DIR/rust_web.out"
"$BIN_DIR/rust_brotli_bench" decode "$WOFF2_BR" 1 "$OUT_DIR/rust_woff2.out"
if [ "$HAS_C" -eq 1 ]; then
  "$BIN_DIR/c_brotli_bench" decode "$WEB_BR" 1 "$OUT_DIR/c_web.out"
  "$BIN_DIR/c_brotli_bench" decode "$WOFF2_BR" 1 "$OUT_DIR/c_woff2.out"
fi

python3 - "$OUT_DIR" "$HAS_C" <<'PYEOF'
import hashlib, os, sys

out_dir, has_c = sys.argv[1], int(sys.argv[2])
for name in ["web", "woff2"]:
    ref = open(os.path.join(out_dir, f"{name}.bin"), "rb").read()
    ref_sha = hashlib.sha256(ref).hexdigest()
    impls = ["pion", "rust"] + (["c"] if has_c else [])
    for impl in impls:
        got = open(os.path.join(out_dir, f"{impl}_{name}.out"), "rb").read()
        got_sha = hashlib.sha256(got).hexdigest()
        assert got_sha == ref_sha, f"SHA-256 mismatch for {impl} on {name}: {got_sha} != {ref_sha}"
    print(f"  {name:6s}: {len(ref):8d} B | all impls match raw sha256:{ref_sha[:16]}...")
PYEOF

C_WEB_ARG=""
C_WOFF2_ARG=""
C_SMALL_ARG=""

echo ""
echo "=== BENCH 1: Web HTML/CSS/JS/JSON Decompress (2 MiB x 10 = 20 MiB) ==="
WEB_BYTES=$((WEB_SIZE * 10))
if [ "$HAS_C" -eq 1 ]; then
  python3 "$ROOT_DIR/scripts/bench_compare.py" \
    --title "Brotli Decompress: Web HTML/CSS/JS/JSON (2 MiB q6 x 10)" \
    --impl "pion=$BIN_DIR/pion_brotli_bench decode $WEB_BR 10" \
    --impl "rust_brotli=$BIN_DIR/rust_brotli_bench decode $WEB_BR 10" \
    --impl "c_brotlidec=$BIN_DIR/c_brotli_bench decode $WEB_BR 10" \
    --baseline rust_brotli \
    --warmup 1 --rounds 5 --bytes "$WEB_BYTES" \
    --md-out "$OUT_DIR/bench_web.md" --json-out "$OUT_DIR/bench_web.json"
else
  python3 "$ROOT_DIR/scripts/bench_compare.py" \
    --title "Brotli Decompress: Web HTML/CSS/JS/JSON (2 MiB q6 x 10)" \
    --impl "pion=$BIN_DIR/pion_brotli_bench decode $WEB_BR 10" \
    --impl "rust_brotli=$BIN_DIR/rust_brotli_bench decode $WEB_BR 10" \
    --baseline rust_brotli \
    --warmup 1 --rounds 5 --bytes "$WEB_BYTES" \
    --md-out "$OUT_DIR/bench_web.md" --json-out "$OUT_DIR/bench_web.json"
fi

echo ""
echo "=== BENCH 2: WOFF2 Binary Font Payload Decompress (1 MiB q11 x 10 = 10 MiB) ==="
WOFF2_BYTES=$((WOFF2_SIZE * 10))
if [ "$HAS_C" -eq 1 ]; then
  python3 "$ROOT_DIR/scripts/bench_compare.py" \
    --title "Brotli Decompress: WOFF2 Font Payload (1 MiB q11 x 10)" \
    --impl "pion=$BIN_DIR/pion_brotli_bench decode $WOFF2_BR 10" \
    --impl "rust_brotli=$BIN_DIR/rust_brotli_bench decode $WOFF2_BR 10" \
    --impl "c_brotlidec=$BIN_DIR/c_brotli_bench decode $WOFF2_BR 10" \
    --baseline rust_brotli \
    --warmup 1 --rounds 5 --bytes "$WOFF2_BYTES" \
    --md-out "$OUT_DIR/bench_woff2.md" --json-out "$OUT_DIR/bench_woff2.json"
else
  python3 "$ROOT_DIR/scripts/bench_compare.py" \
    --title "Brotli Decompress: WOFF2 Font Payload (1 MiB q11 x 10)" \
    --impl "pion=$BIN_DIR/pion_brotli_bench decode $WOFF2_BR 10" \
    --impl "rust_brotli=$BIN_DIR/rust_brotli_bench decode $WOFF2_BR 10" \
    --baseline rust_brotli \
    --warmup 1 --rounds 5 --bytes "$WOFF2_BYTES" \
    --md-out "$OUT_DIR/bench_woff2.md" --json-out "$OUT_DIR/bench_woff2.json"
fi

echo ""
echo "=== BENCH 3: Small Packet Batch Decompress (512 HTTP/JSON/HTML pkts x 10 = 5,120 pkts) ==="
SMALL_BYTES=$((SMALL_SIZE * 10))
if [ "$HAS_C" -eq 1 ]; then
  python3 "$ROOT_DIR/scripts/bench_compare.py" \
    --title "Brotli Decompress: Small Packet Batch (512 pkts q5 x 10)" \
    --impl "pion=$BIN_DIR/pion_brotli_bench batch $SMALL_BATCH 10" \
    --impl "rust_brotli=$BIN_DIR/rust_brotli_bench batch $SMALL_BATCH 10" \
    --impl "c_brotlidec=$BIN_DIR/c_brotli_bench batch $SMALL_BATCH 10" \
    --baseline rust_brotli \
    --warmup 1 --rounds 5 --bytes "$SMALL_BYTES" --ops 5120 \
    --md-out "$OUT_DIR/bench_small.md" --json-out "$OUT_DIR/bench_small.json"
else
  python3 "$ROOT_DIR/scripts/bench_compare.py" \
    --title "Brotli Decompress: Small Packet Batch (512 pkts q5 x 10)" \
    --impl "pion=$BIN_DIR/pion_brotli_bench batch $SMALL_BATCH 10" \
    --impl "rust_brotli=$BIN_DIR/rust_brotli_bench batch $SMALL_BATCH 10" \
    --baseline rust_brotli \
    --warmup 1 --rounds 5 --bytes "$SMALL_BYTES" --ops 5120 \
    --md-out "$OUT_DIR/bench_small.md" --json-out "$OUT_DIR/bench_small.json"
fi
