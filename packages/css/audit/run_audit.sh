#!/bin/sh
# One-shot red-team audit: packages/css (Pion) vs Rust cssparser =0.35.0 + cssparser-color =0.3.0 +
# lightningcss =1.0.0-alpha.72 (parcel_selectors) and Node css-tree@3.1.0.
#   sh packages/css/audit/run_audit.sh            # full run (~2 min on an M-series Mac, perf included)
#   QUICK=1 sh packages/css/audit/run_audit.sh    # smaller fuzz, x1 DoS sizes, 2 perf rounds
# Everything generated goes to $AUDIT_TMP (default /private/tmp/redteam-css); the repo stays clean.
set -u
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
export AUDIT_TMP="${AUDIT_TMP:-/private/tmp/redteam-css}"
T="$AUDIT_TMP"
B="$T/bin"
mkdir -p "$B"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
QUICK="${QUICK:-0}"
FUZZ="${FUZZ:-20000}"; [ "$QUICK" = 1 ] && FUZZ=3000
ROUNDS=5; [ "$QUICK" = 1 ] && ROUNDS=2
S="$AUDIT_DIR/scripts"
step() { printf '\n==================== %s ====================\n' "$*"; }

step "0. toolchain"
pionc --version; cargo --version; node --version; python3 --version
echo "pion-packages HEAD: $(git -C "$ROOT_DIR" rev-parse --short HEAD)  css src last commit: $(git -C "$ROOT_DIR" log -1 --format=%h -- packages/css/src)"

step "1. build Pion probe (native debug/release, wasm32 debug/release), Rust + Node oracles"
pionc build -o "$B/pion_probe_debug" "$AUDIT_DIR/probe" || exit 1
pionc build --release -o "$B/pion_probe" "$AUDIT_DIR/probe" || exit 1
pionc build --target wasm32 -o "$B/pion_probe_debug.wasm" "$AUDIT_DIR/probe" || exit 1
pionc build --release --target wasm32 -o "$B/pion_probe_release.wasm" "$AUDIT_DIR/probe" || exit 1
CARGO_TARGET_DIR="$T/rust-target" cargo build --release -q --locked --manifest-path "$AUDIT_DIR/rust/Cargo.toml" || exit 1
cp "$T/rust-target/release/oracle" "$B/oracle"
if [ ! -f "$T/node_pkg/node_modules/css-tree/package.json" ] ||
   ! grep -q '"version": "3.1.0"' "$T/node_pkg/node_modules/css-tree/package.json"; then
  mkdir -p "$T/node_pkg"
  cp "$AUDIT_DIR/node/package.json" "$T/node_pkg/package.json"
  (cd "$T/node_pkg" && npm install --no-audit --no-fund --silent) || exit 1
fi
echo "css-tree: $(node -p "require('$T/node_pkg/node_modules/css-tree/package.json').version")"

step "2. pionc test (red-team evidence; p0_/p1_/p2_ FAILURES ARE EXPECTED = evidence, control_ must pass)"
(cd "$AUDIT_DIR" && pionc fmt --check . && pionc check --json . | tail -c 200 && echo)
(cd "$AUDIT_DIR" && pionc test --json -p css_audit . > "$T/redteam.json" 2> "$T/redteam.stderr")
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

step "3. W3C CSS Syntax 3 token differential (Pion vs cssparser vs css-tree, fuzz=$FUZZ)"
python3 "$S/tok_diff.py" --fuzz "$FUZZ" --show 2 --json "$T/tok.json"

step "4. Stylesheet / declaration AST, Selectors 4 specificity, Color 4, Media Queries 4"
python3 "$S/struct_diff.py" --show 40 --json "$T/struct.json"

step "5. Minifier / serializer semantic preservation (lightningcss canonical form)"
python3 "$S/minify_diff.py" --show 40 --json "$T/minify.json"

step "6. DoS / complexity / crash probes (x1 and x2 sizes; growth 4 = quadratic)"
if [ "$QUICK" = 1 ]; then
  DOS_TIMEOUT=30 python3 "$S/dos.py" --quick --json "$T/dos.json"
else
  DOS_TIMEOUT=60 python3 "$S/dos.py" --json "$T/dos.json"
fi

step "7. Native debug/release vs Wasm32 debug/release (executed under node) byte parity"
python3 "$S/wasm4.py" --json "$T/wasm4.json"

step "8. Adversarial / un-curated head-to-head timings + Pion phase breakdown"
python3 "$S/perf.py" --rounds "$ROUNDS" --json "$T/perf.json"

step "9. worktree must be clean (only the committed audit files)"
git -C "$ROOT_DIR" status --porcelain --ignored
echo "(empty above = clean; JSON evidence in $T)"
