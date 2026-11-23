#!/bin/sh
# One-shot red-team audit: packages/graphql (Pion) vs graphql-js graphql@16.10.0 and Rust apollo-parser =0.8.4.
#   sh packages/graphql/audit/run_audit.sh            # full run (~6 min on an M-series Mac, perf included)
#   QUICK=1 sh packages/graphql/audit/run_audit.sh    # smaller fuzz, single DoS size, 2 perf rounds
# Everything generated goes to $AUDIT_TMP (default /private/tmp/rt-graphql); the repo stays clean.
set -u
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
export AUDIT_TMP="${AUDIT_TMP:-/private/tmp/rt-graphql}"
T="$AUDIT_TMP"
B="$T/bin"
mkdir -p "$B"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
QUICK="${QUICK:-0}"
FUZZ="${FUZZ:-6000}"; [ "$QUICK" = 1 ] && FUZZ=1500
ROUNDS=5; [ "$QUICK" = 1 ] && ROUNDS=2
S="$AUDIT_DIR/scripts"
step() { printf '\n==================== %s ====================\n' "$*"; }

step "0. toolchain"
pionc --version; cargo --version; node --version; python3 --version
echo "pion-packages HEAD: $(git -C "$ROOT_DIR" rev-parse --short HEAD)  graphql src last commit: $(git -C "$ROOT_DIR" log -1 --format=%h -- packages/graphql/src)"

step "1. build Pion probe (native debug/release, wasm32 debug/release), apollo-parser + graphql-js oracles"
pionc build -o "$B/pion_probe_debug" "$AUDIT_DIR/probe" || exit 1
pionc build --release -o "$B/pion_probe" "$AUDIT_DIR/probe" || exit 1
pionc build --target wasm32 -o "$B/pion_probe_debug.wasm" "$AUDIT_DIR/probe" || exit 1
pionc build --release --target wasm32 -o "$B/pion_probe_release.wasm" "$AUDIT_DIR/probe" || exit 1
CARGO_TARGET_DIR="$T/rust-target" cargo build --release -q --locked --manifest-path "$AUDIT_DIR/rust/Cargo.toml" || exit 1
cp "$T/rust-target/release/oracle" "$B/oracle"
if [ ! -f "$T/node_pkg/node_modules/graphql/package.json" ] ||
   ! grep -q '"version": "16.10.0"' "$T/node_pkg/node_modules/graphql/package.json"; then
  mkdir -p "$T/node_pkg"
  cp "$AUDIT_DIR/node/package.json" "$T/node_pkg/package.json"
  (cd "$T/node_pkg" && npm install --no-audit --no-fund --silent) || exit 1
fi
echo "graphql-js: $(node -p "require('$T/node_pkg/node_modules/graphql/package.json').version")"

step "2. pionc test (red-team evidence; p0_/p1_/p2_ FAILURES ARE EXPECTED = evidence, control_ must pass)"
(cd "$AUDIT_DIR" && pionc fmt --check . && pionc check --json . | tail -c 200 && echo)
(cd "$AUDIT_DIR" && pionc test --json -p graphql_audit . > "$T/redteam.json" 2> "$T/redteam.stderr")
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
grep "pion panic" "$T/redteam.stderr" | sed 's#^.*redteam_test.pion:#  redteam_test.pion:#' | cut -c1-220

step "3. Oct 2021 hand-written spec differential (lexer, escapes, block strings, numbers, keywords, SDL, executable)"
python3 "$S/spec_diff.py" --json "$T/spec.json"

step "4. lexer fuzz differential: tokenize / tokenize_bytes vs graphql-js Lexer (n=$((FUZZ * 3)))"
python3 "$S/tok_diff.py" --n $((FUZZ * 3)) --json "$T/tok.json"

step "5. parser fuzz differential: grammar + mutation fuzz, AST vs graphql-js (n=$FUZZ)"
python3 "$S/fuzz_diff.py" --n "$FUZZ" --json "$T/fuzz.json"

step "6. printer / minifier semantic preservation and idempotency"
python3 "$S/roundtrip_diff.py" --n "$FUZZ" --json "$T/roundtrip.json"

step "7. static validation vs graphql-js schema-free executable rules"
python3 "$S/valid_diff.py" --n "$FUZZ" --json "$T/valid.json"

step "8. DoS / complexity / crash probes (N and 2N; growth 4 = quadratic; rc -11 = SIGSEGV)"
if [ "$QUICK" = 1 ]; then
  DOS_TIMEOUT=60 python3 "$S/dos.py" --quick --json "$T/dos.json"
else
  DOS_TIMEOUT=120 python3 "$S/dos.py" --json "$T/dos.json"
fi

step "9. Native debug/release vs Wasm32 debug/release (executed under node) byte parity + deep-AST teardown"
python3 "$S/wasm4.py" --n "$FUZZ" --json "$T/wasm4.json"

step "10. adversarial head-to-head timings (5 corpora x parse/print/min, Pion native + wasm32, graphql-js, apollo)"
python3 "$S/perf.py" --rounds "$ROUNDS" --json "$T/perf.json"

step "11. worktree must be clean (only the committed audit files)"
git -C "$ROOT_DIR" status --porcelain --ignored
echo "(empty above = clean; JSON evidence in $T)"
