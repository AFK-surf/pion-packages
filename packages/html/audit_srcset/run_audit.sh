#!/bin/sh
# Red-team audit of packages/html/src/srcset.pion (WHATWG HTML §4.8.4.3 srcset / <picture>)
# against a line-by-line Python port of the spec algorithm (diff/ref/srcset_ref.py).
#
#   sh packages/html/audit_srcset/run_audit.sh          # ~1-2 min on an M-series Mac
#   QUICK=1 sh packages/html/audit_srcset/run_audit.sh  # 20k fuzz, skip DoS scaling
#
# Needs: pionc ($HOME/.pion/bin), python3, node >= 18 (wasm32 runtime only). Writes only
# to $AUDIT_OUT (default ${TMPDIR:-/tmp}/pion-html-srcset-audit); the worktree is untouched.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HTML_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
OUT=${AUDIT_OUT:-${TMPDIR:-/tmp}/pion-html-srcset-audit}
OUT=${OUT%/}
BIN="$OUT/bin"
QUICK=${QUICK:-0}
FUZZ=200000
[ "$QUICK" = 1 ] && FUZZ=20000
export PATH="$HOME/.pion/bin:$PATH"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
mkdir -p "$BIN"

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

section "0. Build drivers (Native --release + wasm32) -> $BIN"
pionc build --release -o "$BIN/srcset_diff" "$AUDIT_DIR/diff/pion"
pionc build --release -o "$BIN/srcset_probe" "$AUDIT_DIR/probe"
pionc build --release --target wasm32 -o "$BIN/srcset_probe.wasm" "$AUDIT_DIR/probe"

section "1. Red-team unit tests (every redteam_* FAIL is a finding; control_* must pass)"
(cd "$HTML_DIR" && pionc test --json audit_srcset > "$OUT/redteam_test.json" 2> "$OUT/redteam_test.stderr") || true
python3 - "$OUT/redteam_test.json" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
mine = [t for t in d["tests"] if t["pkg"] == "html_audit_srcset"]
print("html_audit_srcset: %d tests, %d FAILED (findings), %d passed (controls)" % (
    len(mine), sum(not t["ok"] for t in mine), sum(t["ok"] for t in mine)))
for t in mine:
    print("  %-4s %s" % ("FAIL" if not t["ok"] else "pass", t["name"]))
bad = [t["name"] for t in mine if t["ok"] == t["name"].startswith("redteam_")]
if bad:
    print("UNEXPECTED (a finding got fixed or a control regressed):", bad)
PY
echo "assertion messages:"; sed 's|^.*/audit_srcset/|  |' "$OUT/redteam_test.stderr"

section "2. Differential: Pion parse_srcset vs spec reference (82 handpicked + $FUZZ fuzz, seed 2)"
python3 "$AUDIT_DIR/diff/cases.py" "$OUT/cases.txt" "$FUZZ" 2
"$BIN/srcset_diff" < "$OUT/cases.txt" > "$OUT/pion.txt"
python3 "$AUDIT_DIR/diff/ref/srcset_ref.py" < "$OUT/cases.txt" > "$OUT/ref.txt"
python3 "$AUDIT_DIR/diff/compare.py" "$OUT/cases.txt" "$OUT/pion.txt" "$OUT/ref.txt" "$OUT/mismatch.txt"
python3 - "$OUT/mismatch.txt" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
blocks = [b for b in t.split("\n\n")[1:] if b.strip()]
zero = [b for b in blocks if "'x', 0.0" in b]
print("mismatch classes: density-0 (S-3a) %d, other %d" % (len(zero), len(blocks) - len(zero)))
for b in blocks:
    if b not in zero:
        print(b + "\n")
PY

section "3. No-panic / DoS probe, Native vs wasm32"
echo "--- native"; "$BIN/srcset_probe"
echo "--- wasm32"; node "$WASM_RT" "$BIN/srcset_probe.wasm"

section "4. DoS scaling n=25k vs 4n (median of 3, process wall time)"
if [ "$QUICK" = 1 ]; then
  echo "(QUICK=1: skipped)"
else
  python3 "$AUDIT_DIR/perf/dos_scaling.py" "$BIN/srcset_diff" "$OUT/dos_scaling.md"
fi

section "Done. Reports under $OUT"
