#!/bin/sh
# Head-to-head benchmark runner for packages/email:
# - W1: 5,000 multi-part MIME emails (Pion Native vs Rust mail-parser)
# - W2: 100,000 RFC 5322 address-list + date parses (Pion Native vs Go net/mail)
# - W3: 2,000 email builds + DKIM relaxed/relaxed Ed25519 sign/verify (Pion Native vs Go crypto/ed25519)
# All build artifacts and corpora are isolated in /tmp/w13-email-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/w13-email-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic email corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$OUT_DIR"

W1_CORPUS="$OUT_DIR/w1_emails.bin"
W2_CORPUS="$OUT_DIR/w2_addr_dates.txt"
W1_BYTES=$(($(wc -c < "$W1_CORPUS" | tr -d ' ') * 20))
W2_BYTES=$(($(wc -c < "$W2_CORPUS" | tr -d ' ') * 200))

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_email_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust mail-parser benchmark (--release --locked, isolated in $OUT_DIR)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/Cargo.lock" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/email-bench-rust" "$BIN_DIR/rust_email_bench"

echo "==> Building Go net/mail + emersion/go-msgauth v0.7.0 benchmark (isolated in $OUT_DIR)"
rm -rf "$OUT_DIR/go-proj"
mkdir -p "$OUT_DIR/go-proj"
cp "$BENCH_DIR/go/go.mod" "$BENCH_DIR/go/go.sum" "$BENCH_DIR/go/main.go" "$OUT_DIR/go-proj/"
(cd "$OUT_DIR/go-proj" && go build -mod=readonly -o "$BIN_DIR/go_email_bench" .)

echo ""
echo "=== W1: 5,000 Multi-Part MIME Emails Parse & Body/Attachment Hash (Pion vs Rust mail-parser) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: 5,000 Multi-Part MIME Emails Parse (Pion vs Rust mail-parser)" \
  --impl "pion=$BIN_DIR/pion_email_bench w1_mime $W1_CORPUS" \
  --impl "rust_mail_parser=$BIN_DIR/rust_email_bench w1_mime $W1_CORPUS" \
  --baseline rust_mail_parser \
  --warmup 1 --rounds 5 --ops 5000 --bytes "$W1_BYTES" \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== W2: 100,000 Complex RFC 5322 Address-List + Date Parses (Pion vs Go net/mail) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: 100,000 RFC 5322 Address-List & Date Parses (Pion vs Go net/mail)" \
  --impl "pion=$BIN_DIR/pion_email_bench w2_addr_date $W2_CORPUS" \
  --impl "go_net_mail=$BIN_DIR/go_email_bench w2_addr_date $W2_CORPUS" \
  --baseline go_net_mail \
  --warmup 1 --rounds 5 --ops 100000 --bytes "$W2_BYTES" \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== W3: 2,000 Email Build + DKIM relaxed/relaxed Ed25519 Sign/Verify (Pion vs Go go-msgauth v0.7.0) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: 2,000 Email Build + DKIM Ed25519 Sign/Verify (Pion vs Go go-msgauth)" \
  --impl "pion=$BIN_DIR/pion_email_bench w3_dkim" \
  --impl "go_msgauth=$BIN_DIR/go_email_bench w3_dkim" \
  --baseline go_msgauth \
  --warmup 1 --rounds 5 --ops 2000 \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"
