#!/bin/sh
# Red-team audit of packages/url/src/data.pion (RFC 2397 / Fetch §6 data: URLs) against
# Node.js fetch() (undici: WHATWG URL parser + Fetch data: URL processor + Infra
# forgiving-base64) as the oracle.
#
#   sh packages/url/audit_data/run_audit.sh            # ~1 min on an M-series Mac
#   QUICK=1 sh packages/url/audit_data/run_audit.sh    # skip the n=100k DoS scaling run
#
# Needs: pionc ($HOME/.pion/bin), python3, node >= 18. Writes only to $AUDIT_OUT
# (default ${TMPDIR:-/tmp}/pion-url-data-audit); the git worktree is never written to.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
URL_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
OUT=${AUDIT_OUT:-${TMPDIR:-/tmp}/pion-url-data-audit}
OUT=${OUT%/}
BIN="$OUT/bin"
QUICK=${QUICK:-0}
export PATH="$HOME/.pion/bin:$PATH"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
mkdir -p "$BIN"

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

section "0. Build drivers (Native --release + wasm32) -> $BIN"
pionc build --release -o "$BIN/data_diff" "$AUDIT_DIR/diff/pion"
pionc build --release -o "$BIN/data_probe" "$AUDIT_DIR/probe"
pionc build --release --target wasm32 -o "$BIN/data_probe.wasm" "$AUDIT_DIR/probe"

section "1. Red-team unit tests (every redteam_* FAIL is a finding; control_* must pass)"
(cd "$URL_DIR" && pionc test --json audit_data > "$OUT/redteam_test.json" 2> "$OUT/redteam_test.stderr") || true
python3 - "$OUT/redteam_test.json" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
mine = [t for t in d["tests"] if t["pkg"] == "url_audit_data"]
print("url_audit_data: %d tests, %d FAILED (findings), %d passed (controls)" % (
    len(mine), sum(not t["ok"] for t in mine), sum(t["ok"] for t in mine)))
for t in mine:
    print("  %-4s %s" % ("FAIL" if not t["ok"] else "pass", t["name"]))
bad = [t["name"] for t in mine if t["ok"] == t["name"].startswith("redteam_")]
if bad:
    print("UNEXPECTED (a finding got fixed or a control regressed):", bad)
PY
echo "assertion messages:"; sed 's|^.*/audit_data/|  |' "$OUT/redteam_test.stderr"

section "2. Differential: Pion parse_data_url vs Node fetch()"
python3 "$AUDIT_DIR/diff/cases.py" "$OUT/cases.txt"
"$BIN/data_diff" < "$OUT/cases.txt" > "$OUT/pion.txt"
node "$AUDIT_DIR/diff/node/oracle.mjs" < "$OUT/cases.txt" > "$OUT/node.txt"
python3 "$AUDIT_DIR/diff/compare.py" "$OUT/cases.txt" "$OUT/pion.txt" "$OUT/node.txt" "$OUT/mismatch.txt"
cat "$OUT/mismatch.txt"

section "3. No-panic / DoS probe, Native vs wasm32 (100k shapes + distinct-params 5k vs 20k)"
echo "--- native"; "$BIN/data_probe"
echo "--- wasm32"; node "$WASM_RT" "$BIN/data_probe.wasm"

section "4. DoS scaling n=25k vs 4n (median of 3, process wall time)"
if [ "$QUICK" = 1 ]; then
  echo "(QUICK=1: skipped)"
else
  python3 "$AUDIT_DIR/perf/dos_scaling.py" "$BIN/data_diff" "$OUT/dos_scaling.md"
fi

section "Done. Reports under $OUT"
