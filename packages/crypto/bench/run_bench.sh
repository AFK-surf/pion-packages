#!/bin/sh
# 4-mode wasm_smoke parity check and head-to-head benchmark runner for packages/crypto:
# Pure Pion (Native --release) vs Go stdlib (crypto/sha256, crypto/sha512, crypto/hmac, crypto/ed25519).
# All build artifacts are isolated in /tmp/pion-crypto-bench (zero worktree pollution).
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-crypto-bench"
BIN_DIR="$OUT_DIR/bin"
WASM_RT="${PION_WASM_RT:-$HOME/.pion/share/pion/pion_wasm_rt.mjs}"
export PATH="$HOME/.pion/bin:$PATH"

mkdir -p "$BIN_DIR" "$OUT_DIR/go-build"

echo "==> 4-mode cross-target verification (Native debug/release + Wasm32 debug/release)"
pionc build -o "$BIN_DIR/smoke_native_dbg" "$BENCH_DIR/wasm_smoke"
pionc build --release -o "$BIN_DIR/smoke_native_rel" "$BENCH_DIR/wasm_smoke"
pionc build --target wasm32 -o "$BIN_DIR/smoke_wasm_dbg.wasm" "$BENCH_DIR/wasm_smoke"
pionc build --release --target wasm32 -o "$BIN_DIR/smoke_wasm_rel.wasm" "$BENCH_DIR/wasm_smoke"

"$BIN_DIR/smoke_native_dbg" > "$OUT_DIR/smoke_native_dbg.out"
"$BIN_DIR/smoke_native_rel" > "$OUT_DIR/smoke_native_rel.out"
node "$WASM_RT" "$BIN_DIR/smoke_wasm_dbg.wasm" > "$OUT_DIR/smoke_wasm_dbg.out"
node "$WASM_RT" "$BIN_DIR/smoke_wasm_rel.wasm" > "$OUT_DIR/smoke_wasm_rel.out"

python3 - "$OUT_DIR" <<'PY'
import hashlib, os, sys
out = sys.argv[1]
modes = ["smoke_native_dbg", "smoke_native_rel", "smoke_wasm_dbg", "smoke_wasm_rel"]
hashes = {}
for m in modes:
    data = open(os.path.join(out, m + ".out"), "rb").read()
    h = hashlib.sha256(data).hexdigest()
    hashes[m] = h
    print(f"  {m:18s}: {len(data):5d} B  sha256={h}")
if len(set(hashes.values())) != 1:
    print("FAIL: 4-mode stdout mismatch!", file=sys.stderr)
    sys.exit(1)
print("PASS: all 4 modes byte-for-byte identical!")
PY

echo ""
echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_crypto_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Go stdlib benchmark (isolated in /tmp)"
cp "$BENCH_DIR/go/go.mod" "$OUT_DIR/go-build/go.mod"
cp "$BENCH_DIR/go/main.go" "$OUT_DIR/go-build/main.go"
(cd "$OUT_DIR/go-build" && go build -o "$BIN_DIR/go_crypto_bench" .)

echo ""
echo "=== BENCH 1: SHA-256 (16 MiB streaming) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Crypto Bench 1: SHA-256 (16 MiB streaming)" \
  --impl "pion=$BIN_DIR/pion_crypto_bench sha256" \
  --impl "go_stdlib=$BIN_DIR/go_crypto_bench sha256" \
  --baseline go_stdlib \
  --warmup 1 --rounds 5 --bytes 16777216 \
  --md-out "$OUT_DIR/bench_sha256.md" --json-out "$OUT_DIR/bench_sha256.json"

echo ""
echo "=== BENCH 2: SHA-512 (16 MiB streaming) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Crypto Bench 2: SHA-512 (16 MiB streaming)" \
  --impl "pion=$BIN_DIR/pion_crypto_bench sha512" \
  --impl "go_stdlib=$BIN_DIR/go_crypto_bench sha512" \
  --baseline go_stdlib \
  --warmup 1 --rounds 5 --bytes 16777216 \
  --md-out "$OUT_DIR/bench_sha512.md" --json-out "$OUT_DIR/bench_sha512.json"

echo ""
echo "=== BENCH 3: HMAC-SHA256 (50,000 x 256 B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Crypto Bench 3: HMAC-SHA256 (50,000 x 256 B)" \
  --impl "pion=$BIN_DIR/pion_crypto_bench hmac256" \
  --impl "go_stdlib=$BIN_DIR/go_crypto_bench hmac256" \
  --baseline go_stdlib \
  --warmup 1 --rounds 5 --ops 50000 \
  --md-out "$OUT_DIR/bench_hmac256.md" --json-out "$OUT_DIR/bench_hmac256.json"

echo ""
echo "=== BENCH 4: Ed25519 (200 sign + 200 strict verify) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Crypto Bench 4: Ed25519 (200 sign + 200 verify)" \
  --impl "pion=$BIN_DIR/pion_crypto_bench ed25519" \
  --impl "go_stdlib=$BIN_DIR/go_crypto_bench ed25519" \
  --baseline go_stdlib \
  --warmup 1 --rounds 5 --ops 400 \
  --md-out "$OUT_DIR/bench_ed25519.md" --json-out "$OUT_DIR/bench_ed25519.json"
