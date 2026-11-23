#!/bin/sh
# Red-team audit of packages/markdown v0.3.0: `Document` AST (src/ast.pion) + `plain_text` (src/plain_text.pion).
#   sh packages/markdown/audit_v030/run_audit.sh          # full run (~1-2 min on an M-series Mac)
#   QUICK=1 sh packages/markdown/audit_v030/run_audit.sh  # smaller fuzz corpora
# Exit 0 only when every gating check passes: all p0_/p1_/p2_ and ok_ tests, the AST round-trip
# differential, the plain_text invariants, the scaling probes and the 4-mode consistency probes.
# gap_ (advertised but unimplemented) and pre_ (pre-existing, outside the v0.3.0 diff) tests are
# reported but do not gate.
# Everything generated goes to $AUDIT_TMP (default /private/tmp/rt-md-v030-audit); the repo stays clean.
set -u
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
T="${AUDIT_TMP:-/private/tmp/rt-md-v030-audit}"
mkdir -p "$T"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
QUICK="${QUICK:-0}"
FUZZ="${FUZZ:-20000}"; [ "$QUICK" = 1 ] && FUZZ=3000
S="$AUDIT_DIR/scripts"
FAIL=0
step() { printf '\n==================== %s ====================\n' "$*"; }
gate() { if [ "$1" -ne 0 ]; then FAIL=1; echo ">>> GATE FAILED: $2"; else echo ">>> gate ok: $2"; fi; }

step "0. toolchain"
pionc --version; python3 --version
echo "pion-packages HEAD: $(git -C "$ROOT_DIR" rev-parse --short HEAD)  markdown src last commit: $(git -C "$ROOT_DIR" log -1 --format=%h -- packages/markdown/src)"
CRATE=$(ls -d "$HOME"/.cargo/registry/src/*/pulldown-cmark-0.13.1 2>/dev/null | head -1)
[ -n "$CRATE" ] || CRATE=-
echo "pulldown-cmark 0.13.1 test-suite inputs: $CRATE"

step "1. build harness (--release)"
pionc build --release -o "$T/h_rel" "$AUDIT_DIR/harness" > /dev/null || { echo "harness build failed"; exit 1; }

step "2. pionc test (red-team evidence; p*_ failures are the defects)"
pionc test --json -p markdown_redteam_v030 "$AUDIT_DIR/tests" > "$T/redteam.json" 2> "$T/redteam.stderr"
python3 - "$T/redteam.json" << 'PYEOF'
import json, sys, collections
d = json.load(open(sys.argv[1]))
c = collections.Counter()
for t in d["tests"]:
    c[(t["name"].split("_")[0], t["ok"])] += 1
print(f"total={d['total']} passed={d['passed']} failed={d['failed']}")
for lvl in ("p0", "p1", "p2", "gap", "pre", "ok"):
    print(f"  {lvl:4s} fail={c[(lvl, False)]:3d} pass={c[(lvl, True)]:3d}")
for t in d["tests"]:
    if not t["ok"]:
        print("  FAIL", t["name"])
gating = sum(v for (lvl, ok), v in c.items() if not ok and lvl not in ("pre", "gap"))
sys.exit(1 if gating else 0)
PYEOF
gate $? "no failing p0_/p1_/p2_/ok_ test"

step "3. AST round-trip differential: render(parse*) vs render(lower(parse_document*)), fuzz=$FUZZ"
python3 "$S/ast_diff.py" "$T/h_rel" "$CRATE" "$T/diff" --fuzz "$FUZZ"
gate $? "Document AST loses / reorders nothing"

step "4. plain_text invariants (UTF-8 validity, max_chars, prefix, collapse), fuzz=$FUZZ"
python3 "$S/pt_check.py" "$T/h_rel" "$T/pt" --fuzz "$FUZZ"
gate $? "plain_text invariants"

step "5. scaling: Document AST build vs flat parse()"
python3 "$S/dos_scale.py" "$T/h_rel"
gate $? "AST build linear"

step "6. 4-mode native_dbg/native_rel/wasm_dbg/wasm_rel: exit codes + stdout SHA-256"
python3 "$S/ast_diff.py" "$T/h_rel" "$CRATE" "$T/diff4" --fuzz 500 > /dev/null 2>&1
python3 "$S/pt_check.py" "$T/h_rel" "$T/pt4" --fuzz 1000 > /dev/null 2>&1
python3 "$S/four_mode.py" "$AUDIT_DIR/harness" "$T" "$T/pt4/pt.in" "$T/diff4/batch.in"
gate $? "4-mode consistency, 0 crashes"

echo
if [ "$FAIL" -ne 0 ]; then
  echo "RESULT: FAIL (open defects remain; see packages/markdown/audit_v030/REPORT.md). artifacts: $T"
  exit 1
fi
echo "RESULT: PASS. artifacts: $T"
exit 0
