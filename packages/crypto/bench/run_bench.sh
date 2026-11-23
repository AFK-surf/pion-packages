#!/bin/sh
# 4-mode wasm_smoke parity check and head-to-head benchmark runner for packages/crypto:
# Pure Pion (Native --release) vs Go stdlib (+ golang.org/x/crypto/chacha20poly1305).
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
pionc build -o "$BIN_DIR/smoke_native_dbg" "$BENCH_DIR/../wasm_smoke"
pionc build --release -o "$BIN_DIR/smoke_native_rel" "$BENCH_DIR/../wasm_smoke"
pionc build --target wasm32 -o "$BIN_DIR/smoke_wasm_dbg.wasm" "$BENCH_DIR/../wasm_smoke"
pionc build --release --target wasm32 -o "$BIN_DIR/smoke_wasm_rel.wasm" "$BENCH_DIR/../wasm_smoke"

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

echo "==> Building Go benchmark (isolated in /tmp)"
cp "$BENCH_DIR/go/go.mod" "$OUT_DIR/go-build/go.mod"
if [ -f "$BENCH_DIR/go/go.sum" ]; then
  cp "$BENCH_DIR/go/go.sum" "$OUT_DIR/go-build/go.sum"
fi
cp "$BENCH_DIR/go/main.go" "$OUT_DIR/go-build/main.go"
(cd "$OUT_DIR/go-build" && go mod tidy && go build -o "$BIN_DIR/go_crypto_bench" .)

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

echo ""
echo "=== BENCH 5: X25519 (200 key exchanges) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Crypto Bench 5: X25519 (200 key exchanges)" \
  --impl "pion=$BIN_DIR/pion_crypto_bench x25519" \
  --impl "go_stdlib=$BIN_DIR/go_crypto_bench x25519" \
  --baseline go_stdlib \
  --warmup 1 --rounds 5 --ops 200 \
  --md-out "$OUT_DIR/bench_x25519.md" --json-out "$OUT_DIR/bench_x25519.json"

echo ""
echo "=== BENCH 6: HKDF-SHA256 (20,000 x 64 B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Crypto Bench 6: HKDF-SHA256 (20,000 x 64 B)" \
  --impl "pion=$BIN_DIR/pion_crypto_bench hkdf256" \
  --impl "go_stdlib=$BIN_DIR/go_crypto_bench hkdf256" \
  --baseline go_stdlib \
  --warmup 1 --rounds 5 --ops 20000 \
  --md-out "$OUT_DIR/bench_hkdf256.md" --json-out "$OUT_DIR/bench_hkdf256.json"

echo ""
echo "=== BENCH 7: ChaCha20-Poly1305 AEAD (4 MiB seal + open) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Crypto Bench 7: ChaCha20-Poly1305 AEAD (4 MiB seal + open)" \
  --impl "pion=$BIN_DIR/pion_crypto_bench chacha20" \
  --impl "go_xcrypto=$BIN_DIR/go_crypto_bench chacha20" \
  --baseline go_xcrypto \
  --warmup 1 --rounds 5 --bytes 8388608 \
  --md-out "$OUT_DIR/bench_chacha20.md" --json-out "$OUT_DIR/bench_chacha20.json"

echo ""
echo "=== BENCH 8: NIST P-256 ES256 (50 sign + 50 verify) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Crypto Bench 8: NIST P-256 ES256 (50 sign + 50 verify)" \
  --impl "pion=$BIN_DIR/pion_crypto_bench p256" \
  --impl "go_stdlib=$BIN_DIR/go_crypto_bench p256" \
  --baseline go_stdlib \
  --warmup 1 --rounds 5 --ops 100 \
  --md-out "$OUT_DIR/bench_p256.md" --json-out "$OUT_DIR/bench_p256.json"

echo ""
echo "=== BENCH 9: AES-256-GCM AEAD (4 MiB seal + open) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Crypto Bench 9: AES-256-GCM AEAD (4 MiB seal + open)" \
  --impl "pion=$BIN_DIR/pion_crypto_bench aes256gcm" \
  --impl "go_stdlib=$BIN_DIR/go_crypto_bench aes256gcm" \
  --baseline go_stdlib \
  --warmup 1 --rounds 5 --bytes 8388608 \
  --md-out "$OUT_DIR/bench_aes256gcm.md" --json-out "$OUT_DIR/bench_aes256gcm.json"

echo ""
echo "=== BENCH 10: AES-256-GCM AEAD Small Packets (2,000 x 256 B seal + open) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Crypto Bench 10: AES-256-GCM Small Packets (2,000 x 256 B seal + open)" \
  --impl "pion=$BIN_DIR/pion_crypto_bench aes256gcm_small" \
  --impl "go_stdlib=$BIN_DIR/go_crypto_bench aes256gcm_small" \
  --baseline go_stdlib \
  --warmup 1 --rounds 5 --ops 4000 \
  --md-out "$OUT_DIR/bench_aes256gcm_small.md" --json-out "$OUT_DIR/bench_aes256gcm_small.json"

echo ""
echo "=== BENCH 11: NIST P-256 ECDH (50 key exchanges) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Crypto Bench 11: NIST P-256 ECDH (50 key exchanges)" \
  --impl "pion=$BIN_DIR/pion_crypto_bench p256_ecdh" \
  --impl "go_stdlib=$BIN_DIR/go_crypto_bench p256_ecdh" \
  --baseline go_stdlib \
  --warmup 1 --rounds 5 --ops 50 \
  --md-out "$OUT_DIR/bench_p256_ecdh.md" --json-out "$OUT_DIR/bench_p256_ecdh.json"

echo ""
echo "=== BENCH 12: NIST P-256 Pubkey Validation (200 uncompressed + 200 compressed) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Crypto Bench 12: NIST P-256 Pubkey Validation (200 uncompressed + 200 compressed)" \
  --impl "pion=$BIN_DIR/pion_crypto_bench p256_validate" \
  --impl "go_stdlib=$BIN_DIR/go_crypto_bench p256_validate" \
  --baseline go_stdlib \
  --warmup 1 --rounds 5 --ops 400 \
  --md-out "$OUT_DIR/bench_p256_validate.md" --json-out "$OUT_DIR/bench_p256_validate.json"
