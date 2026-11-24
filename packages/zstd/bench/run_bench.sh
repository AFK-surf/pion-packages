#!/bin/sh
# Bidirectional parity & dual-corpus head-to-head benchmark runner for packages/zstd:
# Pion Native (--release) vs Pure Safe Rust `ruzstd` (--release) & Official `zstd` (--release).
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pion-zstd-bench.XXXXXX")
trap 'rm -rf "$OUT_DIR"' EXIT
BIN_DIR="$OUT_DIR/bin"
CORPUS_DIR="$OUT_DIR/corpus"
mkdir -p "$BIN_DIR" "$CORPUS_DIR"

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  if command -v pionc >/dev/null 2>&1; then
    PIONC_BIN=$(command -v pionc)
  elif [ -x "${HOME:-}/.pion/bin/pionc" ]; then
    PIONC_BIN="${HOME}/.pion/bin/pionc"
  fi
fi
if [ -z "$PIONC_BIN" ] || [ ! -x "$PIONC_BIN" ]; then
  echo "FAIL: pionc not found" >&2
  exit 1
fi

echo "==> Generating deterministic corpora -> $CORPUS_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$CORPUS_DIR"

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_zstd_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust ruzstd + zstd benchmark (--release, isolated in /tmp)"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
if [ -f "$BENCH_DIR/rust/Cargo.lock" ]; then
  cp "$BENCH_DIR/rust/Cargo.lock" "$OUT_DIR/rust-proj/"
fi
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml" 2>/dev/null || \
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/zstd-bench-rust" "$BIN_DIR/rust_zstd_bench"

echo "==> Running comprehensive bidirectional byte-exact parity suite"
python3 - "$BIN_DIR" "$CORPUS_DIR" "$OUT_DIR" <<'PYEOF'
import hashlib, os, struct, subprocess, sys

bin_dir, corpus_dir, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
pion_bin = os.path.join(bin_dir, "pion_zstd_bench")
rust_bin = os.path.join(bin_dir, "rust_zstd_bench")

def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()

corpora = sorted(os.listdir(corpus_dir))
pass_count = 0

# Direction 1: Official zstd (-1, -3, -9, -19, with & without --check) -> Pion decompress
for cname in corpora:
    raw_path = os.path.join(corpus_dir, cname)
    raw_sha = sha(raw_path)
    for lvl in [1, 3, 9, 19]:
        for chk_flag in [[], ["--check"]]:
            zst_path = os.path.join(out_dir, f"ref_{cname}_l{lvl}_{len(chk_flag)}.zst")
            dec_path = os.path.join(out_dir, f"pion_dec_{cname}.bin")
            subprocess.run(["zstd", "-q", "-f", f"-{lvl}"] + chk_flag + [raw_path, "-o", zst_path], check=True)
            subprocess.run([pion_bin, "decompress", zst_path, "1", dec_path], check=True, stdout=subprocess.DEVNULL)
            assert sha(dec_path) == raw_sha, f"FAIL zstd -{lvl} {chk_flag} -> pion on {cname}"
            pass_count += 1

# Multi-frame concatenation + Skippable Frame -> Pion decompress
f1 = os.path.join(out_dir, "ref_cjk_utf8.bin_l3_1.zst")
f2 = os.path.join(out_dir, "ref_rle_64k.bin_l9_0.zst")
f3 = os.path.join(out_dir, "ref_one_byte.bin_l19_1.zst")
skip_frame = struct.pack("<II", 0x184D2A57, 12) + b"SKIP_PAYLOAD"
mf_path = os.path.join(out_dir, "multi_skip.zst")
with open(mf_path, "wb") as out_f:
    out_f.write(open(f1, "rb").read())
    out_f.write(skip_frame)
    out_f.write(open(f2, "rb").read())
    out_f.write(open(f3, "rb").read())
mf_expected = (
    open(os.path.join(corpus_dir, "cjk_utf8.bin"), "rb").read()
    + open(os.path.join(corpus_dir, "rle_64k.bin"), "rb").read()
    + open(os.path.join(corpus_dir, "one_byte.bin"), "rb").read()
)
mf_dec = os.path.join(out_dir, "pion_mf_dec.bin")
subprocess.run([pion_bin, "decompress", mf_path, "1", mf_dec], check=True, stdout=subprocess.DEVNULL)
assert hashlib.sha256(open(mf_dec, "rb").read()).hexdigest() == hashlib.sha256(mf_expected).hexdigest()
pass_count += 1

# Direction 2: Pion compress (level 0, 1, 3, 6, with & without checksum) -> Official zstd -d & Rust ruzstd
for cname in corpora:
    raw_path = os.path.join(corpus_dir, cname)
    raw_sha = sha(raw_path)
    for lvl in [0, 1, 3, 6]:
        for mode in ["compress", "compress_chk"]:
            pzst = os.path.join(out_dir, f"pion_{cname}_{mode}_l{lvl}.zst")
            zdec = os.path.join(out_dir, f"zstd_dec_{cname}.bin")
            rdec = os.path.join(out_dir, f"ruzstd_dec_{cname}.bin")
            subprocess.run([pion_bin, mode, str(lvl), raw_path, "1", pzst], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["zstd", "-q", "-d", "-f", pzst, "-o", zdec], check=True)
            assert sha(zdec) == raw_sha, f"FAIL pion {mode} L{lvl} -> zstd -d on {cname}"
            subprocess.run([rust_bin, "ruzstd_dec", pzst, "1", rdec], check=True, stdout=subprocess.DEVNULL)
            assert sha(rdec) == raw_sha, f"FAIL pion {mode} L{lvl} -> ruzstd on {cname}"
            pass_count += 2

print(f"PASS: bidirectional parity verified ({pass_count} byte-exact cross-checks, 0 mismatches)")

# Report compression ratios on dual corpora
for cname in ["web_1m.bin", "binlog_1m.bin"]:
    raw_sz = os.path.getsize(os.path.join(corpus_dir, cname))
    ref_l3 = os.path.getsize(os.path.join(out_dir, f"ref_{cname}_l3_0.zst"))
    pion_l3 = os.path.getsize(os.path.join(out_dir, f"pion_{cname}_compress_l3.zst"))
    pion_l6 = os.path.getsize(os.path.join(out_dir, f"pion_{cname}_compress_l6.zst"))
    print(f"  Ratio {cname} ({raw_sz} B): zstd-L3={ref_l3} B ({ref_l3*100/raw_sz:.2f}%), pion-L3={pion_l3} B ({pion_l3*100/raw_sz:.2f}%), pion-L6={pion_l6} B ({pion_l6*100/raw_sz:.2f}%)")
PYEOF

# Prepare official zstd -3 files for decompression benchmarks
WEB_RAW="$CORPUS_DIR/web_1m.bin"
WEB_ZST="$OUT_DIR/web_1m_l3.zst"
BIN_RAW="$CORPUS_DIR/binlog_1m.bin"
BIN_ZST="$OUT_DIR/binlog_1m_l3.zst"
zstd -q -f -3 "$WEB_RAW" -o "$WEB_ZST"
zstd -q -f -3 "$BIN_RAW" -o "$BIN_ZST"
WEB_SIZE=$(wc -c < "$WEB_RAW" | tr -d ' ')
BIN_SIZE=$(wc -c < "$BIN_RAW" | tr -d ' ')

echo ""
echo "=== BENCH 1: Web HTML/CSS/JS/JSON Decompress (1 MiB x 10 = 10 MiB, official zstd -3) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "zstd Decompress: Web HTML/CSS/JS/JSON (1 MiB x 10)" \
  --impl "pion_zstd=$BIN_DIR/pion_zstd_bench decompress $WEB_ZST 10" \
  --impl "rust_ruzstd=$BIN_DIR/rust_zstd_bench ruzstd_dec $WEB_ZST 10" \
  --impl "rust_zstd=$BIN_DIR/rust_zstd_bench zstd_dec $WEB_ZST 10" \
  --baseline rust_ruzstd \
  --warmup 1 --rounds 5 --bytes "$((WEB_SIZE * 10))" \
  --md-out "$OUT_DIR/bench_web_dec.md" --json-out "$OUT_DIR/bench_web_dec.json"

echo ""
echo "=== BENCH 2: Web HTML/CSS/JS/JSON Compress L3 (1 MiB x 5 = 5 MiB) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "zstd Compress L3: Web HTML/CSS/JS/JSON (1 MiB x 5)" \
  --impl "pion_zstd=$BIN_DIR/pion_zstd_bench compress 3 $WEB_RAW 5" \
  --impl "rust_zstd=$BIN_DIR/rust_zstd_bench zstd_comp 3 $WEB_RAW 5" \
  --baseline rust_zstd \
  --warmup 1 --rounds 5 --bytes "$((WEB_SIZE * 5))" \
  --md-out "$OUT_DIR/bench_web_comp.md" --json-out "$OUT_DIR/bench_web_comp.json"

echo ""
echo "=== BENCH 3: Structured Binary Log Decompress (1 MiB x 10 = 10 MiB, official zstd -3) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "zstd Decompress: Structured Binary Log (1 MiB x 10)" \
  --impl "pion_zstd=$BIN_DIR/pion_zstd_bench decompress $BIN_ZST 10" \
  --impl "rust_ruzstd=$BIN_DIR/rust_zstd_bench ruzstd_dec $BIN_ZST 10" \
  --impl "rust_zstd=$BIN_DIR/rust_zstd_bench zstd_dec $BIN_ZST 10" \
  --baseline rust_ruzstd \
  --warmup 1 --rounds 5 --bytes "$((BIN_SIZE * 10))" \
  --md-out "$OUT_DIR/bench_bin_dec.md" --json-out "$OUT_DIR/bench_bin_dec.json"

echo ""
echo "=== BENCH 4: Structured Binary Log Compress L3 (1 MiB x 5 = 5 MiB) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "zstd Compress L3: Structured Binary Log (1 MiB x 5)" \
  --impl "pion_zstd=$BIN_DIR/pion_zstd_bench compress 3 $BIN_RAW 5" \
  --impl "rust_zstd=$BIN_DIR/rust_zstd_bench zstd_comp 3 $BIN_RAW 5" \
  --baseline rust_zstd \
  --warmup 1 --rounds 5 --bytes "$((BIN_SIZE * 5))" \
  --md-out "$OUT_DIR/bench_bin_comp.md" --json-out "$OUT_DIR/bench_bin_comp.json"
