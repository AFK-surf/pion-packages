#!/bin/sh
# Head-to-head benchmark runner for packages/ssh:
# Pion Native (--release) vs Go golang.org/x/crypto/ssh (v0.38.0).
# All build artifacts are isolated in /tmp/bench-ssh-pion.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/bench-ssh-pion"
BIN_DIR="$OUT_DIR/bin"

rm -rf "$OUT_DIR"
mkdir -p "$BIN_DIR" "$OUT_DIR/go-build"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_ssh_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Go golang.org/x/crypto/ssh benchmark (isolated in /tmp)"
cp "$BENCH_DIR/go/go.mod" "$OUT_DIR/go-build/go.mod"
if [ -f "$BENCH_DIR/go/go.sum" ]; then
  cp "$BENCH_DIR/go/go.sum" "$OUT_DIR/go-build/go.sum"
fi
cp "$BENCH_DIR/go/main.go" "$OUT_DIR/go-build/main.go"
(cd "$OUT_DIR/go-build" && go build -o "$BIN_DIR/go_ssh_bench" .)

echo ""
echo "=== W1: 20,000x authorized_keys Parse + SHA-256 Fingerprint ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "SSH W1: 20,000x authorized_keys Parse + SHA-256 Fingerprint" \
  --impl "pion=$BIN_DIR/pion_ssh_bench w1" \
  --impl "go_x_crypto_ssh=$BIN_DIR/go_ssh_bench w1" \
  --baseline go_x_crypto_ssh \
  --warmup 1 --rounds 5 --ops 20000 \
  --md-out "$OUT_DIR/w1.md" --json-out "$OUT_DIR/w1.json"

echo ""
echo "=== W2: 5,000x known_hosts (|1| HMAC-SHA1) + 1,000x OpenSSH Cert Ed25519 CA Verify ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "SSH W2: 5,000x known_hosts (|1| HMAC-SHA1) + 1,000x Cert Ed25519 Verify" \
  --impl "pion=$BIN_DIR/pion_ssh_bench w2" \
  --impl "go_x_crypto_ssh=$BIN_DIR/go_ssh_bench w2" \
  --baseline go_x_crypto_ssh \
  --warmup 1 --rounds 5 --ops 6000 \
  --md-out "$OUT_DIR/w2.md" --json-out "$OUT_DIR/w2.json"

echo ""
echo "=== W3: 1,000x SSHSIG Ed25519 Verify + 50,000x Binary Packet Roundtrip ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "SSH W3: 1,000x SSHSIG Ed25519 Verify + 50,000x Binary Packet Roundtrip" \
  --impl "pion=$BIN_DIR/pion_ssh_bench w3" \
  --impl "go_x_crypto_ssh=$BIN_DIR/go_ssh_bench w3" \
  --baseline go_x_crypto_ssh \
  --warmup 1 --rounds 5 --ops 51000 \
  --md-out "$OUT_DIR/w3.md" --json-out "$OUT_DIR/w3.json"
