#!/bin/sh
# Benchmark-fairness re-run for packages/cedar (called by ../run_audit.sh --bench, or directly).
#   W2/W3: published Pion binary vs published Rust binary vs Rust with per-request work hoisted
#          exactly as the Pion driver does (all three must print the same SHA-256).
#   W4-W6: blind-spot workloads (JSON entity load, large sets, like-heavy), Pion vs Rust.
# Everything is built under $AUDIT_OUT (default /private/tmp/rt-cedar-audit); worktree stays clean.
set -eu
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AUDIT=$(CDPATH= cd -- "$HERE/.." && pwd)
PKG=$(CDPATH= cd -- "$AUDIT/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$PKG/../.." && pwd)
OUT="${AUDIT_OUT:-/private/tmp/rt-cedar-audit}"
B="$OUT/bench"
mkdir -p "$B"
PION_CACHE_DIR="$OUT/pion-cache-native" pionc build --release -o "$B/pion_bench" "$PKG/bench/pion_bench" >/dev/null
PION_CACHE_DIR="$OUT/pion-cache-native" pionc build --release -o "$B/pion_fair" "$HERE/pion" >/dev/null
CARGO_TARGET_DIR="$OUT/cargo-bench" cargo build -q --release --locked --manifest-path "$PKG/bench/rust_bench/Cargo.toml"
CARGO_TARGET_DIR="$OUT/cargo" cargo build -q --release --locked --manifest-path "$AUDIT/rust/Cargo.toml" --bin bench_fair
RB="$OUT/cargo-bench/release/cedar_rust_bench"
RF="$OUT/cargo/release/bench_fair"
cmp() { # title ops impl...
  t=$1; ops=$2; shift 2
  python3 "$REPO_ROOT/scripts/bench_compare.py" --title "$t" --warmup 1 --rounds 5 --ops "$ops" "$@" \
    --md-out "$B/$(echo "$t" | cut -c1-2).md" | sed -n '/^|/p;/sha256\|SHA/p'
}
echo "### W2 (3,000 requests) - published vs fair Rust"
cmp "W2" 3000 --impl "pion=$B/pion_bench w2 3000" --impl "rust_published=$RB w2 3000" --impl "rust_fair=$RF w2f 3000" --baseline rust_fair
echo "### W3 (2,000 requests) - published vs fair Rust"
cmp "W3" 2000 --impl "pion=$B/pion_bench w3 2000" --impl "rust_published=$RB w3 2000" --impl "rust_fair=$RF w3f 2000" --baseline rust_fair
echo "### W4 JSON entity load (2,000-entity DAG x 20 rounds)"
cmp "W4" 20 --impl "pion=$B/pion_fair w4 20" --impl "rust=$RF w4 20" --baseline rust
echo "### W5 large-set predicates (1,000-element sets, 2,000 requests)"
cmp "W5" 2000 --impl "pion=$B/pion_fair w5 2000" --impl "rust=$RF w5 2000" --baseline rust
echo "### W6 like-heavy (12 policies, 5,000 requests)"
cmp "W6" 5000 --impl "pion=$B/pion_fair w6 5000" --impl "rust=$RF w6 5000" --baseline rust
