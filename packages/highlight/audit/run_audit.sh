#!/bin/sh
# Red-team audit of packages/highlight — one command:
#   sh packages/highlight/audit/run_audit.sh            # full run (~3–5 min on an M-class Mac)
#   AUDIT_QUICK=1 sh packages/highlight/audit/run_audit.sh   # skip the 1 MiB adversarial sweep
# Needs: pionc (PATH or ~/.pion/bin), node >= 18, npm, python3. Reference engines (prismjs 1.30.0, shiki 3.23.0)
# are installed once into $HL_AUDIT_REF (default ~/.cache/hl-audit-ref), never into the repository.
# Every artifact (probe binary, generated inputs, reports) goes to a temp dir; the worktree stays clean.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
export PATH="$HOME/.pion/bin:$PATH"
PIONC="${PIONC:-pionc}"
REF="${HL_AUDIT_REF:-$HOME/.cache/hl-audit-ref}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hl-audit.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
PROBE="$WORK/probe"

section() { printf '\n==================== %s ====================\n' "$1"; }

section "0. toolchain + reference engines"
"$PIONC" --version
node --version
if [ ! -d "$REF/node_modules/prismjs" ] || [ ! -d "$REF/node_modules/shiki" ]; then
  mkdir -p "$REF"
  (cd "$REF" && [ -f package.json ] || (cd "$REF" && npm init -y >/dev/null))
  (cd "$REF" && npm install --no-audit --no-fund prismjs@1.30.0 shiki@3.23.0 >/dev/null)
fi
export REF_NODE_MODULES="$REF/node_modules"
node -e "console.log('prismjs', require('$REF/node_modules/prismjs/package.json').version, '/ shiki', require('$REF/node_modules/shiki/package.json').version)"
"$PIONC" build --release "$AUDIT_DIR/probe" -o "$PROBE"

section "1. red-team tests (pionc test packages/highlight/audit) — every audit test is EXPECTED TO FAIL"
"$PIONC" test --json "$AUDIT_DIR" >"$WORK/test.json" 2>"$WORK/test.err" || true
python3 - "$WORK/test.json" <<'PY'
import json, sys
d = json.loads(open(sys.argv[1], "rb").read().decode("utf-8", "replace"))
t = [x for x in d.get("tests", []) if x["pkg"] == "highlight_redteam_audit"]
base = [x for x in d.get("tests", []) if x["pkg"] == "highlight"]
print(f"shipped highlight suite: {sum(x['ok'] for x in base)}/{len(base)} pass")
print(f"red-team suite: {sum(not x['ok'] for x in t)}/{len(t)} FAIL (each failure = one reproduced defect)")
for x in t:
    print(("  FAIL  " if not x["ok"] else "  pass  ") + x["name"])
PY
echo "(assertion messages: $WORK/test.err, first 40 lines below)"
LC_ALL=C sed 's/^pion panic at [^:]*:[0-9]*: /  /' "$WORK/test.err" | head -40

section "2. token-classification differential vs shiki / prismjs"
PROBE="$PROBE" node "$AUDIT_DIR/bench/token_diff.mjs" --corpus "$PKG_DIR/bench/corpus.txt" "$AUDIT_DIR"/cases/*

section "3. incremental highlight_line vs highlight (editor lines without terminators, CRLF)"
python3 "$AUDIT_DIR/bench/incremental_probe.py" "$PROBE"

section "4. UTF-8 boundary + HTML escaping / XSS probe (17 languages x 67 inputs)"
python3 "$AUDIT_DIR/bench/utf8_xss_probe.py" "$PROBE"

section "5a. end-to-end HTML benchmark: shipped corpus (9 languages), scripts/bench_compare.py"
BYTES=$(python3 -c "
raw=open('$PKG_DIR/bench/corpus.txt',encoding='utf-8').read().split('\n'); t=0; cur=None
for l in raw:
    if len(l)>11 and l.startswith('===LANG:') and l.endswith('==='):
        if cur is not None: t+=len('\n'.join(cur).encode())
        cur=[]
    elif cur is not None: cur.append(l)
t+=len('\n'.join(cur).encode()); print(t*${CORPUS_ITERS:-20})")
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "highlight_html end-to-end, corpus x ${CORPUS_ITERS:-20} (decoded text verified)" \
  --baseline node-prismjs \
  --impl "node-prismjs=node $AUDIT_DIR/bench/ref_html.mjs prism corpus $PKG_DIR/bench/corpus.txt ${CORPUS_ITERS:-20}" \
  --impl "node-shiki=node $AUDIT_DIR/bench/ref_html.mjs shiki corpus $PKG_DIR/bench/corpus.txt ${CORPUS_ITERS:-20}" \
  --impl "pion-highlight=$PROBE corpus-html $PKG_DIR/bench/corpus.txt ${CORPUS_ITERS:-20}" \
  --warmup 1 --rounds 5 --bytes "$BYTES"

python3 "$AUDIT_DIR/bench/patho_gen.py" "$WORK/patho" >/dev/null
section "5b. end-to-end HTML benchmark: 1 MiB minified JavaScript, scripts/bench_compare.py"
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "highlight_html end-to-end, 1 MiB minified JS (decoded text verified)" \
  --baseline node-prismjs \
  --impl "node-prismjs=node $AUDIT_DIR/bench/ref_html.mjs prism javascript $WORK/patho/javascript.minified_1MB 1" \
  --impl "node-shiki=node $AUDIT_DIR/bench/ref_html.mjs shiki javascript $WORK/patho/javascript.minified_1MB 1" \
  --impl "pion-highlight=$PROBE bench-html-text javascript $WORK/patho/javascript.minified_1MB 1" \
  --warmup 1 --rounds 5 --bytes 1048576

if [ "${AUDIT_QUICK:-0}" != "1" ]; then
  section "5c. adversarial 1 MiB sweep (single run each, ${SWEEP_TIMEOUT:-15}s timeout)"
  python3 "$AUDIT_DIR/bench/patho_sweep.py" "$PROBE" "$AUDIT_DIR/bench/ref_html.mjs" "$WORK/patho" "${SWEEP_TIMEOUT:-15}"
fi

section "6. worktree must stay clean outside audit/"
git -C "$ROOT_DIR" status --porcelain --ignored -- . ":!packages/highlight/audit" || true
echo "done."
