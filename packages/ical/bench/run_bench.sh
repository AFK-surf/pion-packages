#!/bin/sh
# Head-to-head benchmark runner for packages/ical:
# Pion Native (--release) vs Rust (rrule 0.14 + icalendar 0.16, --release --locked).
# All build artifacts and corpora are isolated in /tmp/bench-ical-work.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/bench-ical-work"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic iCalendar & RRULE corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$OUT_DIR"

ICS_CORPUS="$OUT_DIR/enterprise_4k.ics"
RRULE_CORPUS="$OUT_DIR/rrule_suite.txt"
RSET_CORPUS="$OUT_DIR/rruleset_suite.txt"

ICS_BYTES=$(wc -c < "$ICS_CORPUS" | tr -d ' ')

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_ical_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust rrule+icalendar benchmark (--release --locked, isolated in /tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/Cargo.lock" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/ical-bench-rust" "$BIN_DIR/rust_ical_bench"

echo ""
echo "=== W1: Enterprise .ics Parse + Serialize Roundtrip (4,000 VEVENTs, folded + UTF-8) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Enterprise .ics Parse + Serialize Roundtrip (4,000 VEVENTs)" \
  --impl "pion=$BIN_DIR/pion_ical_bench ics_roundtrip $ICS_CORPUS" \
  --impl "rust_icalendar=$BIN_DIR/rust_ical_bench ics_roundtrip $ICS_CORPUS" \
  --baseline rust_icalendar \
  --warmup 1 --rounds 5 --bytes "$ICS_BYTES" \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== W2: Complex RRULE Expansion (80 rules: BYDAY ordinals, BYSETPOS, WKST, leap, 58k occs) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Complex RRULE Expansion (80 rules, 58,000 occurrences)" \
  --impl "pion=$BIN_DIR/pion_ical_bench rrule_expand $RRULE_CORPUS" \
  --impl "rust_rrule=$BIN_DIR/rust_ical_bench rrule_expand $RRULE_CORPUS" \
  --baseline rust_rrule \
  --warmup 1 --rounds 5 --ops 58000 \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== W3: RRuleSet Window Query Batch (200 sets x 2 RRULEs + 4 RDATEs + 6 EXDATEs, 2y window) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: RRuleSet Window Query Batch (200 sets, 2-year window)" \
  --impl "pion=$BIN_DIR/pion_ical_bench rruleset_window $RSET_CORPUS" \
  --impl "rust_rrule=$BIN_DIR/rust_ical_bench rruleset_window $RSET_CORPUS" \
  --baseline rust_rrule \
  --warmup 1 --rounds 5 --ops 200 \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"
