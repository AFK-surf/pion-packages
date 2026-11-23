#!/bin/sh
# RT-xpath: one-shot red-team audit of packages/xpath (W3C XPath 1.0) — see REPORT.md.
#
#   sh packages/xpath/audit/run_audit.sh                 # all gating sections (~3-4 min)
#   SECTIONS="build tests diff wasm dos bench" sh ...    # bench (fairness review) is opt-in
#
# Subject: packages/xpath (pionc native debug/release + wasm32 debug/release).
# Oracles: Rust sxd-xpath =0.4.2 + sxd-document =0.3.2 (tools/rust_oracle, Cargo.lock --locked),
#          libxml2 (system lib, tools/c_oracle), and a Python model of the XPath number rules.
# Needs: pionc ($HOME/.pion/bin), cargo, cc + libxml2 headers (macOS SDK or libxml2-dev), node,
#        python3. Everything built or generated goes to $AUDIT_OUT (default /private/tmp/rt-xpath-audit);
#        the git worktree is never written to (AGENTS.md 1.5).
#
# Exit status: 0 only when every gating check passes, i.e. no defect listed in REPORT.md remains:
#   tests  every audit test passes (p1_/p2_ tests FAIL while their defect exists; control_ must pass)
#   diff   native_rel agrees with the Python spec model on all number-fuzz queries
#   wasm   native_dbg / native_rel / wasm_dbg / wasm_rel stdout byte-identical over the corpus
#   dos    every DoS / false-rejection verdict holds (dos/run_dos.py)
# A fixing branch can re-run this script without touching audit/ and get exit 0.
set -u

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT="${AUDIT_OUT:-/private/tmp/rt-xpath-audit}"
BIN="$OUT/bin"
SECTIONS="${SECTIONS:-build tests diff wasm dos}"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PION_CACHE_DIR="${PION_CACHE_DIR:-$OUT/pion-cache}"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
mkdir -p "$BIN" "$OUT/logs"
FAILED=""

want() { case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }
hdr() { printf '\n==== %s ====\n' "$*"; }
fail() { FAILED="$FAILED $1"; }

if want build; then
  hdr "build: pion_runner x4 (serial), sxd-xpath oracle (--locked), libxml2 oracle"
  R="$AUDIT_DIR/tools/pion_runner"
  pionc build -o "$BIN/pion_dbg" "$R" &&
    pionc build --release -o "$BIN/pion_rel" "$R" &&
    pionc build --target wasm32 -o "$BIN/pion_wasm_dbg.wasm" "$R" &&
    pionc build --release --target wasm32 -o "$BIN/pion_wasm_rel.wasm" "$R" || { echo "pion build failed"; exit 2; }
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --quiet --release --locked \
    --manifest-path "$AUDIT_DIR/tools/rust_oracle/Cargo.toml" || { echo "cargo build failed"; exit 2; }
  cp "$OUT/rust-target/release/rt-xpath-sxd-oracle" "$BIN/sxd"
  XML2_CFLAGS=$(xml2-config --cflags 2>/dev/null || echo "-I$(xcrun --show-sdk-path 2>/dev/null)/usr/include/libxml2")
  cc -O2 -w $XML2_CFLAGS "$AUDIT_DIR/tools/c_oracle/libxml2_oracle.c" -lxml2 -o "$BIN/libxml2" ||
    { echo "libxml2 oracle build failed"; exit 2; }
  python3 -I "$AUDIT_DIR/diff/gen_corpus.py" "$OUT/corpus.json"
fi

if want tests; then
  hdr "red-team tests (audit/*_test.pion): p1_/p2_ FAIL = defect still present"
  pionc fmt --check "$AUDIT_DIR" >/dev/null || { echo "  pionc fmt --check failed"; fail fmt; }
  pionc check --json "$AUDIT_DIR" > "$OUT/logs/check.json" || { echo "  pionc check failed"; fail check; }
  pionc test --json "$AUDIT_DIR" > "$OUT/logs/tests.json" 2> "$OUT/logs/tests.stderr"
  python3 -I - "$OUT/logs/tests.json" "$OUT/logs/tests.stderr" <<'PYEOF' || fail tests
import json, re, sys
t = open(sys.argv[1]).read()
d = json.loads(t[t.find('{"ok"'):])
rows = [x for x in d["tests"] if x["pkg"] == "xpath_audit"]
for x in rows:
    print("  %s %s" % ("PASS" if x["ok"] else "FAIL", x["name"]))
bad = [x for x in rows if not x["ok"]]
up = [x for x in d["tests"] if x["pkg"] == "xpath"]
print("  -> %d audit tests: %d pass, %d fail (%d failing controls)" % (
    len(rows), len(rows) - len(bad), len(bad), sum(x["name"].startswith("control_") for x in bad)))
print("  -> upstream packages/xpath suite: %d/%d pass" % (sum(x["ok"] for x in up), len(up)))
seen = set()
for m in re.finditer(r"(redteam_\w+\.pion):(\d+): (.*)", open(sys.argv[2]).read()):
    if m.group(0) not in seen:
        seen.add(m.group(0))
        print("     %s:%s  %s" % (m.group(1), m.group(2), m.group(3)[:200]))
sys.exit(1 if bad or not rows else 0)
PYEOF
fi

if want diff; then
  hdr "differential: pion native_rel vs sxd-xpath 0.4.2 vs libxml2 vs Python spec model"
  python3 -I "$AUDIT_DIR/diff/run_diff.py" --gate-spec --corpus "$OUT/corpus.json" --out "$OUT/diff" \
    --impl "pion_rel=$BIN/pion_rel" --impl "sxd=$BIN/sxd" --impl "libxml2=$BIN/libxml2" || fail diff
  echo "  details: $OUT/diff/{spec_mismatch,odd_one_out,all_diffs}.txt"
fi

if want wasm; then
  hdr "4-mode consistency: native_dbg / native_rel / wasm_dbg / wasm_rel over the whole corpus"
  python3 -I "$AUDIT_DIR/diff/run_diff.py" --corpus "$OUT/corpus.json" --out "$OUT/diff4" \
    --impl "pion_rel=$BIN/pion_rel" --impl "pion_dbg=$BIN/pion_dbg" \
    --impl "pion_wasm_dbg=node $WASM_RT $BIN/pion_wasm_dbg.wasm" \
    --impl "pion_wasm_rel=node $WASM_RT $BIN/pion_wasm_rel.wasm" || fail wasm
  diff "$OUT/diff4/pion_rel.out" "$OUT/diff4/pion_wasm_rel.out" | head -12 | sed 's/^/    /'
  hdr "4-mode stack battery (deep legal nesting, default limits)"
  python3 -I "$AUDIT_DIR/dos/run_dos.py" --out "$OUT/dos4" --timeout 60 \
    --only stack_parens_120,stack_preds_60,stack_deep_xml_255_strings,stack_unary_100k,stack_path_10k,stack_func_nest_60 \
    --impl "pion_rel=$BIN/pion_rel" --impl "pion_dbg=$BIN/pion_dbg" \
    --impl "pion_wasm_dbg=node $WASM_RT $BIN/pion_wasm_dbg.wasm" \
    --impl "pion_wasm_rel=node $WASM_RT $BIN/pion_wasm_rel.wasm" || fail wasm_stack
fi

if want dos; then
  hdr "DoS / limit battery: pion (XPathLimits::default) vs sxd-xpath vs libxml2 (unlimited)"
  python3 -I "$AUDIT_DIR/dos/run_dos.py" --out "$OUT/dos" --timeout "${DOS_TIMEOUT:-60}" \
    --impl "pion_rel=$BIN/pion_rel" --impl "sxd=$BIN/sxd" --impl "libxml2=$BIN/libxml2" || fail dos
fi

if want bench; then
  hdr "benchmark fairness review (informational, not gating)"
  sh "$AUDIT_DIR/bench/run_blindspots.sh" "$BIN" "$OUT/bench" 5
fi

hdr "worktree status (must be empty)"
git -C "$ROOT_DIR" status --porcelain --ignored
if [ -n "$FAILED" ]; then
  echo "RESULT: FAIL (sections:$FAILED) — defects listed in REPORT.md are still present"
  exit 1
fi
echo "RESULT: PASS"
