#!/bin/sh
# Head-to-head benchmark runner for packages/preflate:
# Pion Native (--release) vs Rust preflate-rs (=0.7.6, --release).
# All build artifacts, Cargo lockfile, and corpora are isolated in /tmp.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pion-preflate-bench.XXXXXX")
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
  echo "error: pionc not found on PATH or at \$HOME/.pion/bin/pionc" >&2
  exit 1
fi

echo "==> Generating deterministic raw DEFLATE workloads (L1, L6, L9) -> $OUT_DIR"
python3 - "$OUT_DIR" <<'PYEOF'
import hashlib, os, sys, zlib

out_dir = sys.argv[1]

# Deterministic ~942 KiB (964,166 B) structured JSON/log corpus (realistic compressible workload).
lines = []
services = ["auth-gw", "edge-proxy", "ingest-api", "billing-worker", "search-idx", "cache-node"]
levels = ["INFO", "INFO", "INFO", "WARN", "DEBUG", "ERROR"]
paths = [
    "/v2/events/batch",
    "/v2/users/profile",
    "/v2/search/query?q=deflate+preflate&limit=50",
    "/v2/assets/blob/sha256",
    "/v2/metrics/ingest",
    "/healthz",
]
state = 0x123456789ABCDEF0
for i in range(6000):
    state = (state * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
    svc = services[(state >> 16) % len(services)]
    lvl = levels[(state >> 24) % len(levels)]
    path = paths[(state >> 32) % len(paths)]
    lat_us = 120 + ((state >> 40) % 18500)
    status = 200 if (state & 31) != 0 else (503 if (state & 63) == 32 else 404)
    req_id = f"{(state >> 8) & 0xFFFFFFFF:08x}-{i:05d}"
    lines.append(
        f'{{"ts":"2026-11-24T10:{(i // 100) % 60:02d}:{i % 60:02d}.{(i * 137) % 1000:03d}Z",'
        f'"svc":"{svc}","lvl":"{lvl}","req":"{req_id}","path":"{path}",'
        f'"status":{status},"lat_us":{lat_us},"bytes":{256 + (i * 29) % 4096}}}\n'
    )

plain = "".join(lines).encode("utf-8")
open(os.path.join(out_dir, "corpus.txt"), "wb").write(plain)
print(f"  plain corpus: {len(plain)} B (sha256:{hashlib.sha256(plain).hexdigest()[:16]}...)")

for level in (1, 6, 9):
    comp = zlib.compressobj(level=level, method=zlib.DEFLATED, wbits=-15)
    raw_def = comp.compress(plain) + comp.flush()
    path = os.path.join(out_dir, f"corpus_l{level}.deflate")
    open(path, "wb").write(raw_def)
    sha = hashlib.sha256(raw_def).hexdigest()
    open(os.path.join(out_dir, f"corpus_l{level}.sha256"), "w").write(sha + "\n")
    print(f"  zlib L{level} raw deflate: {len(raw_def):7d} B (ratio {len(raw_def)/len(plain)*100:5.2f}%, sha256:{sha[:16]}...)")
PYEOF

PLAIN_SIZE=$(wc -c < "$OUT_DIR/corpus.txt" | tr -d ' ')

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_preflate_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust preflate-rs benchmark (--release, isolated in /tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/preflate-bench-rust" "$BIN_DIR/rust_preflate_bench"

echo "==> Checking correction-stream sizes and byte-exact reconstruction against original DEFLATE"
for LVL in 1 6 9; do
  DEF="$OUT_DIR/corpus_l${LVL}.deflate"
  EXP_SHA=$(cat "$OUT_DIR/corpus_l${LVL}.sha256")
  echo "--- zlib L${LVL} ---"
  "$BIN_DIR/pion_preflate_bench" "$DEF" 1 "$OUT_DIR/pion_l${LVL}.stats" > "$OUT_DIR/pion_l${LVL}.out"
  "$BIN_DIR/rust_preflate_bench" "$DEF" 1 "$OUT_DIR/rust_l${LVL}.stats" > "$OUT_DIR/rust_l${LVL}.out"
  cat "$OUT_DIR/pion_l${LVL}.stats"
  cat "$OUT_DIR/rust_l${LVL}.stats"
  python3 - "$EXP_SHA" "$OUT_DIR/pion_l${LVL}.out" "$OUT_DIR/rust_l${LVL}.out" <<'PYEOF'
import hashlib, sys
exp, p_path, r_path = sys.argv[1], sys.argv[2], sys.argv[3]
for name, path in [("pion", p_path), ("rust_preflate_rs", r_path)]:
    got = hashlib.sha256(open(path, "rb").read()).hexdigest()
    assert got == exp, f"{name} SHA-256 mismatch: {got} != {exp}"
print(f"  verified byte-exact match with original DEFLATE: sha256:{exp}")
PYEOF
done

ITERS=3
TOTAL_PLAIN=$((PLAIN_SIZE * ITERS))

for LVL in 1 6 9; do
  DEF="$OUT_DIR/corpus_l${LVL}.deflate"
  EXP_SHA=$(cat "$OUT_DIR/corpus_l${LVL}.sha256")
  echo ""
  echo "=== BENCH: Preflate Analyze + Reencode Roundtrip (zlib L${LVL}, ${PLAIN_SIZE} B plain x ${ITERS}) ==="
  python3 "$ROOT_DIR/scripts/bench_compare.py" \
    --title "Preflate Analyze + Reencode Roundtrip (zlib L${LVL}, ${PLAIN_SIZE} B plain x ${ITERS})" \
    --impl "pion=$BIN_DIR/pion_preflate_bench $DEF $ITERS" \
    --impl "rust_preflate_rs=$BIN_DIR/rust_preflate_bench $DEF $ITERS" \
    --baseline rust_preflate_rs \
    --expect-sha256 "$EXP_SHA" \
    --warmup 1 --rounds 5 --bytes "$TOTAL_PLAIN" \
    --md-out "$OUT_DIR/bench_l${LVL}.md" --json-out "$OUT_DIR/bench_l${LVL}.json"
done
