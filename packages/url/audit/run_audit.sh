#!/bin/sh
# Red-team audit of packages/url (Pion) vs Rust url v2.5.9 (+ idna 1.1.0), with Node.js
# `URL` (Ada) as a third WHATWG tie-breaker and Unicode IdnaTestV2.txt as the UTS #46 oracle.
#
#   sh packages/url/audit/run_audit.sh          # full run (~2-3 min on an M-series Mac)
#   QUICK=1 sh packages/url/audit/run_audit.sh  # skip the adversarial throughput benchmarks
#
# Needs: pionc ($HOME/.pion/bin), cargo, python3, node >= 18. Network only for the first
# cargo fetch (Cargo.lock is committed and pinned with --locked).
# All builds, inputs and reports go to $AUDIT_OUT (default ${TMPDIR:-/tmp}/pion-url-audit);
# the git worktree is never written to.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
URL_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
OUT=${AUDIT_OUT:-${TMPDIR:-/tmp}/pion-url-audit}
OUT=${OUT%/}
BIN="$OUT/bin"
QUICK=${QUICK:-0}
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$BIN"

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

section "0. Build differential drivers (Pion --release, Rust url =2.5.9 --release) -> $BIN"
pionc build --release -o "$BIN/pion_diff" "$AUDIT_DIR/diff/pion"
CARGO_TARGET_DIR="$OUT/rust-target" cargo build -q --release --locked \
  --manifest-path "$AUDIT_DIR/diff/rust/Cargo.toml"
cp "$OUT/rust-target/release/url-audit-rust" "$BIN/rust_diff"
node --version >/dev/null
python3 "$AUDIT_DIR/diff/gen_cases.py" "$OUT/cases"

section "1. Red-team unit tests: pionc test packages/url/audit (every redteam_* failure is a finding)"
(cd "$URL_DIR" && pionc test --json audit > "$OUT/redteam_test.json" 2> "$OUT/redteam_test.stderr") || true
python3 - "$OUT/redteam_test.json" <<'PY' || true
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
mine = [t for t in d["tests"] if t["pkg"] == "url_audit"]
print("url_audit: %d tests, %d FAILED (findings), %d passed (controls)" % (
    len(mine), sum(not t["ok"] for t in mine), sum(t["ok"] for t in mine)))
for t in mine:
    print("  %-6s %s" % ("FAIL" if not t["ok"] else "pass", t["name"]))
PY
echo "assertion messages:"; sed 's|^.*/audit/|  |' "$OUT/redteam_test.stderr"

section "2. Three-way differential (Pion vs Rust url 2.5.9, Node/Ada tie-breaker)"
python3 "$AUDIT_DIR/diff/compare.py" "$OUT/cases" "$BIN/pion_diff" "$BIN/rust_diff" "$OUT/diff" \
  "$AUDIT_DIR/diff/node/driver.mjs"
echo "per-case reports: $OUT/diff/<suite>.mismatch.txt"

section "3. UTS #46 conformance: WHATWG domainToASCII vs IdnaTestV2.txt"
python3 "$AUDIT_DIR/diff/idna_conformance.py" "$AUDIT_DIR/data/IdnaTestV2.txt" \
  "$BIN/pion_diff" "$BIN/rust_diff" "$OUT/diff/idna_conformance.txt"

section "4. Serialization round-trip (parse(href) == parse(input)) over wpt+fuzz+fastpath"
python3 "$AUDIT_DIR/diff/roundtrip.py" "$OUT/cases/roundtrip.in" "$BIN/pion_diff" "$BIN/rust_diff" \
  "$OUT/diff/roundtrip.txt"
sed -n '1,12p' "$OUT/diff/roundtrip.txt"

section "5. DoS: adversarial-input scaling (n vs 4n, median of 3)"
python3 "$AUDIT_DIR/perf/dos_scaling.py" "$BIN/pion_diff" "$BIN/rust_diff" "$OUT/dos_scaling.md"

section "6. Adversarial throughput head-to-head (scripts/bench_compare.py, SHA-256 gated)"
if [ "$QUICK" = 1 ]; then
  echo "(QUICK=1: skipped)"
else
  sh "$AUDIT_DIR/perf/run_adversarial_bench.sh" "$BIN" "$OUT"
fi

section "Done. Reports under $OUT"
