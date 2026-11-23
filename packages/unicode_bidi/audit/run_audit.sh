#!/bin/sh
# One-shot red-team audit: packages/unicode_bidi (Pion) vs Rust unicode-bidi =0.3.18
# (+ unicode-bidi-mirroring =0.4.0), the Unicode 16.0.0 UCD / conformance files and ICU4C ubidi
# (macOS libicucore, tie-breaker only).
#   sh packages/unicode_bidi/audit/run_audit.sh          # full run (~4 min on an M-series Mac)
#   QUICK=1 sh packages/unicode_bidi/audit/run_audit.sh  # smaller fuzz and DoS sizes
# Everything generated goes to $AUDIT_TMP (default /private/tmp/redteam-bidi); the repo stays clean.
set -u
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
export AUDIT_TMP="${AUDIT_TMP:-/private/tmp/redteam-bidi}"
T="$AUDIT_TMP"
B="$T/bin"
mkdir -p "$B" "$T/ucd"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
QUICK="${QUICK:-0}"
FUZZ="${FUZZ:-30000}"; [ "$QUICK" = 1 ] && FUZZ=5000
S="$AUDIT_DIR/scripts"
step() { printf '\n==================== %s ====================\n' "$*"; }

step "0. toolchain + Unicode 16.0.0 data"
pionc --version; cargo --version; node --version; python3 --version
echo "pion-packages HEAD: $(git -C "$ROOT_DIR" rev-parse --short HEAD)  unicode_bidi src last commit: $(git -C "$ROOT_DIR" log -1 --format=%h -- packages/unicode_bidi/src)"
for f in BidiCharacterTest.txt BidiTest.txt BidiBrackets.txt BidiMirroring.txt extracted/DerivedBidiClass.txt; do
  out="$T/ucd/$(basename "$f")"
  [ -s "$out" ] || curl -sfL -o "$out" "https://www.unicode.org/Public/16.0.0/ucd/$f" || { echo "download $f failed"; exit 1; }
done
head -1 "$T/ucd/BidiCharacterTest.txt"; head -1 "$T/ucd/DerivedBidiClass.txt"

step "1. build Pion probe (native debug/release, wasm32 debug/release) + Rust oracle"
pionc build -o "$B/pion_probe_debug" "$AUDIT_DIR/probe" || exit 1
pionc build --release -o "$B/pion_probe" "$AUDIT_DIR/probe" || exit 1
pionc build --target wasm32 -o "$B/pion_probe_debug.wasm" "$AUDIT_DIR/probe" || exit 1
pionc build --release --target wasm32 -o "$B/pion_probe_release.wasm" "$AUDIT_DIR/probe" || exit 1
CARGO_TARGET_DIR="$T/rust-target" cargo build --release -q --locked --manifest-path "$AUDIT_DIR/rust/Cargo.toml" || exit 1
cp "$T/rust-target/release/oracle" "$B/oracle"

step "2. pionc test (red-team evidence; p0_/p1_/p2_ FAILURES ARE EXPECTED = evidence, control_ must pass)"
(cd "$AUDIT_DIR" && pionc fmt --check . && pionc check --json . | tail -c 200 && echo)
(cd "$AUDIT_DIR" && pionc test --json -p unicode_bidi_audit . > "$T/redteam.json" 2> "$T/redteam.stderr")
python3 - "$T/redteam.json" << 'PYEOF'
import json, sys, collections
d = json.load(open(sys.argv[1]))
c = collections.Counter()
for t in d["tests"]:
    c[(t["name"].split("_")[0], t["ok"])] += 1
print(f"total={d['total']} passed={d['passed']} failed={d['failed']}")
for lvl in ("p0", "p1", "p2", "control"):
    print(f"  {lvl:8s} fail={c[(lvl, False)]:3d} pass={c[(lvl, True)]:3d}")
for t in d["tests"]:
    if not t["ok"]:
        print("  FAIL", t["name"])
bad = [t["name"] for t in d["tests"] if t["name"].startswith("control") and not t["ok"]]
if bad:
    print("  !! CONTROL FAILURES:", bad)
PYEOF
grep "pion panic" "$T/redteam.stderr" | sed 's#^.*redteam_test.pion:#  redteam_test.pion:#' | cut -c1-260

step "3. tables over all 0..=0x10FFFF: Bidi_Class / BidiBrackets / BidiMirroring vs Rust and UCD 16"
python3 "$S/tables.py" --json "$T/tables.json"

step "4. Unicode 16 conformance: BidiCharacterTest.txt + BidiTest.txt (Pion AND Rust)"
python3 "$S/conformance.py" --json "$T/conformance.json"

step "5. differential fuzz vs Rust unicode-bidi 0.3.18 (fuzz=$FUZZ), mismatches adjudicated by ICU4C"
python3 "$S/diff_fuzz.py" --fuzz "$FUZZ" --show 4 --json "$T/fuzz.json"

step "6. Native debug/release vs Wasm32 debug/release (executed under node) byte parity"
python3 "$S/wasm4.py" --json "$T/wasm4.json"

step "7. DoS / complexity / memory probes (x1 and x2 sizes; growth 4 = quadratic)"
if [ "$QUICK" = 1 ]; then
  DOS_TIMEOUT=30 python3 "$S/dos.py" --quick --json "$T/dos.json"
else
  DOS_TIMEOUT=60 python3 "$S/dos.py" --json "$T/dos.json"
fi

step "8. worktree must be clean (only the committed audit files)"
git -C "$ROOT_DIR" status --porcelain --ignored
echo "(empty above = clean; JSON evidence in $T)"
