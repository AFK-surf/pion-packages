#!/bin/sh
# Head-to-head benchmark runner for packages/bzip2:
# Pion Native (--release) vs Rust bzip2 0.6.1 (libbz2-rs-sys 0.2.7, --release).
# All build artifacts, Cargo lockfile, and corpora are isolated in a temporary directory.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pion-bzip2-bench.XXXXXX")
trap 'rm -rf "$OUT_DIR"' EXIT
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

if [ -z "$PIONC_BIN" ] || [ ! -x "$PIONC_BIN" ]; then
  echo "FAIL: pionc not found on PATH or at \$HOME/.pion/bin/pionc" >&2
  exit 1
fi

echo "==> Generating deterministic structured text/JSON/log corpus (~768 KiB) -> $OUT_DIR"
python3 - "$OUT_DIR" <<'PYEOF'
import os, sys

out_dir = sys.argv[1]
raw_path = os.path.join(out_dir, "corpus.bin")

# Deterministic 768 KiB structured JSON/HTTP/log payload (realistic compressible text)
chunks = []
state = 0x9E3779B97F4A7C15
methods = ["GET", "POST", "PUT", "DELETE", "PATCH"]
paths = [
    "/api/v2/packages/bzip2/versions",
    "/api/v2/registry/index/compression-archive",
    "/api/v2/builds/linux-x86_64/artifacts",
    "/api/v2/telemetry/events/ingest",
    "/docs/specs/bzip2-bwt-huffman.html",
]
statuses = [200, 200, 200, 201, 204, 304, 400, 404, 500]
regions = ["us-east-1", "eu-central-1", "ap-northeast-1", "ap-southeast-1"]

total = 0
target = 768 * 1024
idx = 0
while total < target:
    state = (state * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
    m = methods[(state >> 16) % len(methods)]
    p = paths[(state >> 24) % len(paths)]
    st = statuses[(state >> 32) % len(statuses)]
    reg = regions[(state >> 40) % len(regions)]
    lat = ((state >> 8) % 4500) / 10.0
    sz = 128 + ((state >> 48) % 16384)
    line = (
        f'{{"id":{idx},"ts":"2026-11-24T{(idx//3600)%24:02d}:{(idx//60)%60:02d}:{idx%60:02d}Z",'
        f'"region":"{reg}","method":"{m}","path":"{p}?page={idx%32}&sort=desc",'
        f'"status":{st},"latency_ms":{lat:.1f},"bytes":{sz},'
        f'"ua":"pion-http/0.1.0 (wasm32; pure-pion)","cache":"{"HIT" if (idx%3) else "MISS"}"}}\n'
    ).encode("utf-8")
    chunks.append(line)
    total += len(line)
    idx += 1

raw = b"".join(chunks)[:target]
with open(raw_path, "wb") as f:
    f.write(raw)
print(f"  corpus.bin: {len(raw)} bytes ({idx} records)")
PYEOF

RAW_FILE="$OUT_DIR/corpus.bin"
BZ_FILE="$OUT_DIR/corpus.bz2"
RAW_SIZE=$(wc -c < "$RAW_FILE" | tr -d ' ')

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_bzip2_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust bzip2 0.6.1 benchmark (--release, isolated in /tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --offline \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml" 2>/dev/null || \
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/bzip2-bench-rust" "$BIN_DIR/rust_bzip2_bench"

echo "==> Verifying byte-exact SHA-256 parity on compress (L6) and decompress"
"$BIN_DIR/pion_bzip2_bench" compress 6 "$RAW_FILE" 1 "$OUT_DIR/pion_l6.bz2"
"$BIN_DIR/rust_bzip2_bench" compress 6 "$RAW_FILE" 1 "$OUT_DIR/rust_l6.bz2"
cp "$OUT_DIR/rust_l6.bz2" "$BZ_FILE"
"$BIN_DIR/pion_bzip2_bench" decompress "$BZ_FILE" 1 "$OUT_DIR/pion_dec.bin"
"$BIN_DIR/rust_bzip2_bench" decompress "$BZ_FILE" 1 "$OUT_DIR/rust_dec.bin"

python3 - "$OUT_DIR" <<'PYEOF'
import hashlib, os, sys

out_dir = sys.argv[1]
def sha(name):
    data = open(os.path.join(out_dir, name), "rb").read()
    return len(data), hashlib.sha256(data).hexdigest()

raw_len, raw_sha = sha("corpus.bin")
pbz_len, pbz_sha = sha("pion_l6.bz2")
rbz_len, rbz_sha = sha("rust_l6.bz2")
pdec_len, pdec_sha = sha("pion_dec.bin")
rdec_len, rdec_sha = sha("rust_dec.bin")

assert pbz_sha == rbz_sha, f"compress L6 SHA-256 mismatch: pion={pbz_sha} != rust={rbz_sha}"
assert pdec_sha == raw_sha, f"pion decompress SHA-256 mismatch: {pdec_sha} != {raw_sha}"
assert rdec_sha == raw_sha, f"rust decompress SHA-256 mismatch: {rdec_sha} != {raw_sha}"
print(f"  compress   L6: {raw_len} B -> {pbz_len} B | byte-exact sha256:{pbz_sha[:16]}...")
print(f"  decompress L6: {pbz_len} B -> {pdec_len} B | byte-exact sha256:{raw_sha[:16]}...")
PYEOF

echo ""
echo "=== BENCH 1: Compress Level 6 (768 KiB x 3 = 2.25 MiB) ==="
COMP_BYTES=$((RAW_SIZE * 3))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "bzip2 Compress L6: Structured JSON Logs (768 KiB x 3)" \
  --impl "pion_bzip2=$BIN_DIR/pion_bzip2_bench compress 6 $RAW_FILE 3" \
  --impl "rust_bzip2=$BIN_DIR/rust_bzip2_bench compress 6 $RAW_FILE 3" \
  --baseline rust_bzip2 \
  --warmup 1 --rounds 5 --bytes "$COMP_BYTES" \
  --md-out "$OUT_DIR/bench_compress.md" --json-out "$OUT_DIR/bench_compress.json"

echo ""
echo "=== BENCH 2: Decompress Level 6 (768 KiB x 10 = 7.50 MiB) ==="
DECOMP_BYTES=$((RAW_SIZE * 10))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "bzip2 Decompress L6: Structured JSON Logs (768 KiB x 10)" \
  --impl "pion_bzip2=$BIN_DIR/pion_bzip2_bench decompress $BZ_FILE 10" \
  --impl "rust_bzip2=$BIN_DIR/rust_bzip2_bench decompress $BZ_FILE 10" \
  --baseline rust_bzip2 \
  --warmup 1 --rounds 5 --bytes "$DECOMP_BYTES" \
  --md-out "$OUT_DIR/bench_decompress.md" --json-out "$OUT_DIR/bench_decompress.json"
