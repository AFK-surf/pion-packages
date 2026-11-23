#!/bin/sh
# Head-to-head benchmark runner for packages/flate:
# Pion Native (--release) vs Rust flate2 (rust_backend / miniz_oxide, --release) vs Go compress/gzip + hash/{crc32,adler32}.
# All build artifacts, Cargo lockfile, and corpora are isolated in /tmp.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-flate-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic 2 MiB mixed corpus & pre-compressed .gz -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"

RAW_DATA="$OUT_DIR/corpus.bin"
GZ_DATA="$OUT_DIR/corpus.gz"
RAW_SIZE=$(wc -c < "$RAW_DATA" | tr -d ' ')

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_flate_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust flate2 (rust_backend / miniz_oxide) benchmark (--release, isolated in /tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/flate-bench-rust" "$BIN_DIR/rust_flate_bench"

echo "==> Building Go compress/gzip benchmark"
(cd "$BENCH_DIR/go" && go build -o "$BIN_DIR/go_flate_bench" .)

echo ""
echo "==> Verifying 3-way compression ratios & cross-implementation SHA-256 interoperability"
"$BIN_DIR/pion_flate_bench" compress6 "$RAW_DATA" 1 "$OUT_DIR/pion_l6.gz" >/dev/null
"$BIN_DIR/rust_flate_bench" compress6 "$RAW_DATA" 1 "$OUT_DIR/rust_l6.gz" >/dev/null
"$BIN_DIR/go_flate_bench"   compress6 "$RAW_DATA" 1 "$OUT_DIR/go_l6.gz"   >/dev/null
"$BIN_DIR/pion_flate_bench" compress1 "$RAW_DATA" 1 "$OUT_DIR/pion_l1.gz" >/dev/null
"$BIN_DIR/rust_flate_bench" compress1 "$RAW_DATA" 1 "$OUT_DIR/rust_l1.gz" >/dev/null
"$BIN_DIR/go_flate_bench"   compress1 "$RAW_DATA" 1 "$OUT_DIR/go_l1.gz"   >/dev/null

python3 - "$RAW_DATA" "$OUT_DIR" "$BIN_DIR" <<'PYEOF'
import gzip, hashlib, os, subprocess, sys

raw_path, out_dir, bin_dir = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(raw_path, "rb").read()
raw_sha = hashlib.sha256(raw).hexdigest()
print(f"Original corpus: {len(raw)} B (sha256:{raw_sha[:16]}...)")

for label, fname in [
    ("pion (level 6)", "pion_l6.gz"),
    ("rust_miniz_oxide (level 6)", "rust_l6.gz"),
    ("go_gzip (level 6)", "go_l6.gz"),
    ("pion (level 1)", "pion_l1.gz"),
    ("rust_miniz_oxide (level 1)", "rust_l1.gz"),
    ("go_gzip (level 1)", "go_l1.gz"),
]:
    p = os.path.join(out_dir, fname)
    gz = open(p, "rb").read()
    dec = gzip.decompress(gz)
    sha = hashlib.sha256(dec).hexdigest()
    assert sha == raw_sha, f"Python gzip decompress mismatch for {label}!"
    # Also verify Pion decompresses every other implementation's .gz identically
    proc = subprocess.run([os.path.join(bin_dir, "pion_flate_bench"), "decompress", p, "1"],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    # stdout has "total_bytes=...\n<payload>\n"
    first_nl = proc.stdout.index(b"\n")
    pion_dec = proc.stdout[first_nl + 1 : -1]
    assert hashlib.sha256(pion_dec).hexdigest() == raw_sha, f"Pion decompress mismatch for {label}!"
    print(f"  {label:28s}: {len(gz):7d} B ({len(gz)*100.0/len(raw):5.2f}%) | Python+Pion roundtrip SHA-256 OK")
PYEOF

echo ""
echo "=== BENCH 1: GZIP/DEFLATE Decompress (2 MiB x 10 = 20 MiB) ==="
DEC_BYTES=$((RAW_SIZE * 10))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "GZIP/DEFLATE Decompress (2 MiB mixed corpus x 10)" \
  --impl "pion=$BIN_DIR/pion_flate_bench decompress $GZ_DATA 10" \
  --impl "rust_miniz_oxide=$BIN_DIR/rust_flate_bench decompress $GZ_DATA 10" \
  --impl "go_gzip=$BIN_DIR/go_flate_bench decompress $GZ_DATA 10" \
  --baseline rust_miniz_oxide \
  --warmup 1 --rounds 5 --bytes "$DEC_BYTES" \
  --md-out "$OUT_DIR/bench_decompress.md" --json-out "$OUT_DIR/bench_decompress.json"

echo ""
echo "=== BENCH 2: GZIP/DEFLATE Compress Level 6 (2 MiB x 4 = 8 MiB) ==="
C6_BYTES=$((RAW_SIZE * 4))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "GZIP/DEFLATE Compress Level 6 (2 MiB mixed corpus x 4)" \
  --impl "pion=$BIN_DIR/pion_flate_bench compress6 $RAW_DATA 4" \
  --impl "rust_miniz_oxide=$BIN_DIR/rust_flate_bench compress6 $RAW_DATA 4" \
  --impl "go_gzip=$BIN_DIR/go_flate_bench compress6 $RAW_DATA 4" \
  --baseline rust_miniz_oxide \
  --warmup 1 --rounds 5 --bytes "$C6_BYTES" \
  --md-out "$OUT_DIR/bench_compress6.md" --json-out "$OUT_DIR/bench_compress6.json"

echo ""
echo "=== BENCH 3: GZIP/DEFLATE Compress Level 1 (2 MiB x 6 = 12 MiB) ==="
C1_BYTES=$((RAW_SIZE * 6))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "GZIP/DEFLATE Compress Level 1 (2 MiB mixed corpus x 6)" \
  --impl "pion=$BIN_DIR/pion_flate_bench compress1 $RAW_DATA 6" \
  --impl "rust_miniz_oxide=$BIN_DIR/rust_flate_bench compress1 $RAW_DATA 6" \
  --impl "go_gzip=$BIN_DIR/go_flate_bench compress1 $RAW_DATA 6" \
  --baseline rust_miniz_oxide \
  --warmup 1 --rounds 5 --bytes "$C1_BYTES" \
  --md-out "$OUT_DIR/bench_compress1.md" --json-out "$OUT_DIR/bench_compress1.json"

echo ""
echo "=== BENCH 4: CRC-32 (IEEE) + Adler-32 Checksum (2 MiB x 32 = 64 MiB) ==="
CS_BYTES=$((RAW_SIZE * 32))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "CRC-32 (IEEE) + Adler-32 Checksum (2 MiB x 32 = 64 MiB)" \
  --impl "pion=$BIN_DIR/pion_flate_bench checksum $RAW_DATA 32" \
  --impl "rust_crc_adler=$BIN_DIR/rust_flate_bench checksum $RAW_DATA 32" \
  --impl "go_crc_adler=$BIN_DIR/go_flate_bench checksum $RAW_DATA 32" \
  --baseline rust_crc_adler \
  --warmup 1 --rounds 5 --bytes "$CS_BYTES" \
  --md-out "$OUT_DIR/bench_checksum.md" --json-out "$OUT_DIR/bench_checksum.json"
