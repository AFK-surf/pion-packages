#!/bin/sh
# One-shot red-team audit: packages/html (Pion) vs Rust scraper =0.22.0 (html5ever 0.29.1) +
# ammonia =4.0.0 and Go golang.org/x/net/html v0.35.0.
#   sh packages/html/audit/run_audit.sh            # full run (~10 min on an M-series Mac)
#   QUICK=1 sh packages/html/audit/run_audit.sh    # smaller fuzz, x1 DoS sizes only
# Everything generated goes to $AUDIT_TMP (default /private/tmp/redteam-html); the repo stays clean.
set -u
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
export AUDIT_TMP="${AUDIT_TMP:-/private/tmp/redteam-html}"
T="$AUDIT_TMP"
B="$T/bin"
mkdir -p "$B"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
QUICK="${QUICK:-0}"
FUZZ="${FUZZ:-20000}"; [ "$QUICK" = 1 ] && FUZZ=3000
S="$AUDIT_DIR/scripts"
step() { printf '\n==================== %s ====================\n' "$*"; }

step "0. toolchain"
pionc --version; cargo --version; go version; node --version; python3 --version
echo "pion-packages HEAD: $(git -C "$ROOT_DIR" rev-parse --short HEAD)  html src last commit: $(git -C "$ROOT_DIR" log -1 --format=%h -- packages/html/src)"

step "1. build Pion probe (native debug/release, wasm32 debug/release), Rust + Go oracles"
pionc build -o "$B/pion_probe_debug" "$AUDIT_DIR/probe" || exit 1
pionc build --release -o "$B/pion_probe" "$AUDIT_DIR/probe" || exit 1
pionc build --target wasm32 -o "$B/pion_probe_debug.wasm" "$AUDIT_DIR/probe" || exit 1
pionc build --release --target wasm32 -o "$B/pion_probe_release.wasm" "$AUDIT_DIR/probe" || exit 1
CARGO_TARGET_DIR="$T/rust-target" cargo build --release -q --manifest-path "$AUDIT_DIR/rust/Cargo.toml" || exit 1
cp "$T/rust-target/release/oracle" "$B/oracle"
(cd "$AUDIT_DIR/go" && GOFLAGS=-mod=mod go build -o "$B/go_oracle" .) || exit 1
CRATES=$(cargo metadata --format-version 1 --manifest-path "$AUDIT_DIR/rust/Cargo.toml" | python3 -c '
import json,sys,os
m=json.load(sys.stdin)
print(next(os.path.dirname(p["manifest_path"]) for p in m["packages"] if p["name"]=="markup5ever" and p["version"]=="0.14.1"))')
echo "markup5ever (WHATWG entity table): $CRATES"

H5="$T/html5lib-tests"
if [ ! -d "$H5/tree-construction" ]; then
  # html5lib-tests moved tree-construction to WPT in 224991e; pin the last commit that has it.
  rm -rf "$H5"
  git clone -q https://github.com/html5lib/html5lib-tests.git "$H5" && git -C "$H5" checkout -q 9329e64
fi
TC="$H5/tree-construction"

step "2. pionc test (red-team evidence; p1_/p2_ FAILURES ARE EXPECTED = evidence, control_ must pass)"
(cd "$AUDIT_DIR" && pionc fmt --check . && pionc check --json . | tail -c 200 && echo)
(cd "$AUDIT_DIR" && pionc test --json -p html_audit . > "$T/redteam.json" 2> "$T/redteam.stderr")
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
PYEOF

step "3. html5lib-tests tree-construction (9329e64): Pion vs html5ever vs Go x/net/html"
python3 "$S/html5lib_suite.py" "$TC" --show 2

step "4. P0 XSS / mXSS: html5ever round-trip of Pion's sanitize output (vectors + fuzz=$FUZZ)"
python3 "$S/xss.py" --fuzz "$FUZZ" --json "$T/xss.json"

step "5. WHATWG named character references (2,231) + legacy/numeric edges"
python3 "$S/entities.py" "$CRATES/entities.rs" --json "$T/entities.json"

step "6. CSS selector differential vs scraper"
python3 "$S/css_diff.py" --json "$T/css.json"

step "7. DoS / complexity probes (x1 and x2 sizes; growth 4 = quadratic)"
if [ "$QUICK" = 1 ]; then
  DOS_TIMEOUT=30 python3 "$S/dos.py" --quick --json "$T/dos.json"
else
  DOS_TIMEOUT=60 python3 "$S/dos.py" --json "$T/dos.json"
fi

step "8. Native debug/release vs Wasm32 debug/release (executed under node) byte parity"
python3 "$S/wasm4.py" "$TC" --json "$T/wasm4.json"

step "9. Adversarial / un-curated head-to-head timings"
python3 "$S/adv_bench.py" "$TC" "$CRATES/entities.rs" --json "$T/adv_bench.json"

step "10. worktree must be clean"
git -C "$ROOT_DIR" status --porcelain --ignored -- packages/html
echo "(empty above = clean; JSON evidence in $T)"
