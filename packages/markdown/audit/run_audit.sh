#!/bin/sh
# One-shot red-team audit: packages/markdown (Pion) vs real Rust pulldown-cmark 0.13.1.
#   sh packages/markdown/audit/run_audit.sh            # full run (~3-6 min on an M-series Mac)
#   QUICK=1 sh packages/markdown/audit/run_audit.sh    # smaller fuzz / sizes, no bench_compare
# Everything generated goes to $AUDIT_TMP (default: $TMPDIR/pion-markdown-audit); the repo stays clean.
set -u
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
T="${AUDIT_TMP:-${TMPDIR:-/tmp}/pion-markdown-audit}"
mkdir -p "$T"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
QUICK="${QUICK:-0}"
FUZZ="${FUZZ:-20000}"; [ "$QUICK" = 1 ] && FUZZ=3000
SIZES="${SIZES:-1000,2000,4000,8000,16000}"; [ "$QUICK" = 1 ] && SIZES=1000,2000,4000
S="$AUDIT_DIR/scripts"
step() { printf '\n==================== %s ====================\n' "$*"; }

step "0. toolchain"
pionc --version; cargo --version; python3 --version
echo "pion-packages HEAD: $(git -C "$ROOT_DIR" rev-parse --short HEAD)  markdown src last commit: $(git -C "$ROOT_DIR" log -1 --format=%h -- packages/markdown/src)"

step "1. build oracle (Rust pulldown-cmark =0.13.1, --release) and Pion harness (--release)"
CARGO_TARGET_DIR="$T/rust_target" cargo build --release -q --manifest-path "$AUDIT_DIR/rust_ref/Cargo.toml" || exit 1
RUST="$T/rust_target/release/pulldown_ref"
pionc build --release -o "$T/pion_harness" "$AUDIT_DIR/harness" || exit 1
PION="$T/pion_harness"
CRATE=$(cargo metadata --format-version 1 --manifest-path "$AUDIT_DIR/rust_ref/Cargo.toml" | python3 -c '
import json,sys,os
m=json.load(sys.stdin)
print(next(os.path.dirname(p["manifest_path"]) for p in m["packages"] if p["name"]=="pulldown-cmark" and p["version"]=="0.13.1"))')
echo "oracle crate: $CRATE"

step "2. pionc test (red-team evidence; FAILURES ARE EXPECTED = evidence)"
pionc test --json -p markdown_redteam "$AUDIT_DIR" > "$T/redteam.json" 2> "$T/redteam.stderr"
python3 - "$T/redteam.json" << 'PYEOF'
import json, sys, collections
d = json.load(open(sys.argv[1]))
c = collections.Counter()
for t in d["tests"]:
    lvl = t["name"].split("_")[0]
    c[(lvl, t["ok"])] += 1
print(f"total={d['total']} passed={d['passed']} failed={d['failed']}")
for lvl in ("p0", "p1", "gap", "p2", "ok"):
    print(f"  {lvl:4s} fail={c[(lvl, False)]:3d} pass={c[(lvl, True)]:3d}")
for t in d["tests"]:
    if not t["ok"]:
        print("  FAIL", t["name"])
PYEOF

step "3. three-way differential (Rust vs to_html_pulldown vs render_html_pulldown(parse)) + fuzz=$FUZZ"
python3 "$S/difftest.py" "$RUST" "$PION" "$CRATE" "$T/diff" --fuzz "$FUZZ"
python3 "$S/minimize.py" "$RUST" "$PION" "$T/diff/diff_results.json" "$T/diff/min.json" --max 6000 2>/dev/null
python3 "$S/classify.py" "$T/diff/min.json" | cut -c1-240

step "4. pulldown-cmark 0.13.1's own test suite (tests/suite/*.rs) scored on Pion"
python3 "$S/suite_score.py" "$RUST" "$PION" "$CRATE" "$T/suite"

step "5. DoS / robustness probes"
probe() { # name mask python-expr
  python3 -c "import sys; sys.stdout.write($3)" > "$T/probe.md"
  B=$(wc -c < "$T/probe.md" | tr -d ' ')
  "$RUST" html "$T/probe.md" "$2" > /dev/null 2>&1; R=$?
  "$PION" direct "$T/probe.md" "$2" > /dev/null 2>&1; P=$?
  "$PION" events "$T/probe.md" "$2" > /dev/null 2>&1; E=$?
  printf '  %-34s %8s B  rust rc=%-4s pion direct rc=%-4s events rc=%-4s %s\n' "$1" "$B" "$R" "$P" "$E" "$( [ $P -ne 0 ] || [ $E -ne 0 ] && echo '<== PION CRASH (139 = SIGSEGV)')"
}
probe "blockquote depth 10000"   0 "'> '*10000+'a\n'"
probe "blockquote depth 50000"   0 "'> '*50000+'a\n'"
probe "bullet list depth 20000"  0 "'- '*20000+'a\n'"
probe "bullet list depth 32000"  0 "'- '*32000+'a\n'"
probe "ordered list depth 32000" 0 "'1. '*32000+'a\n'"
probe "nested brackets 200000"   0 "'['*200000+'a'+']'*200000"
probe "nested emph 200000"       0 "'*'*200000+'a'+'*'*200000"
printf '\xff*a*\xc3\n**\xe4\xb8**x\n' > "$T/badutf8.md"
if "$PION" direct "$T/badutf8.md" 0 | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null; then
  echo "  invalid UTF-8 input: pion output is valid UTF-8"
else
  echo "  invalid UTF-8 input: pion emits INVALID UTF-8 HTML (bytes passed through; Rust &str cannot even hold this input)"
fi

step "6. pathological scaling (time ~ N^k), sizes=$SIZES"
python3 "$S/patho_bench.py" "$RUST" "$PION" "$T/patho" --sizes "$SIZES" --timeout 20

[ "$QUICK" = 1 ] && { echo; echo "QUICK=1: skipped bench_compare"; exit 0; }
step "7. scripts/bench_compare.py (SHA-256 verified): direct path, Event-API path, pathological inputs"
python3 "$S/make_corpora.py" "$CRATE" "$T/corp" > /dev/null
bc() { # title file mask
  python3 "$ROOT_DIR/scripts/bench_compare.py" --title "$1" \
    --impl "rust_pulldown_cmark=$RUST html $T/corp/$2 $3" \
    --impl "pion_to_html_pulldown=$PION direct $T/corp/$2 $3" \
    --impl "pion_parse_render_html_pulldown=$PION events $T/corp/$2 $3" \
    --baseline rust_pulldown_cmark --warmup 1 --rounds "${ROUNDS:-7}" --bytes "$(wc -c < "$T/corp/$2" | tr -d ' ')" \
    --md-out "$T/bench_$2.txt.md"
}
bc "Mixed GFM corpus (2.50 MB)" corpus_gfm.md 7
bc "CommonMark spec examples corpus (2.51 MB)" corpus_spec.md 0
bc "PATHOLOGICAL nested strong/emph N=4000 (56 KB)" patho_nested_strong_emph_4000.md 0
bc "PATHOLOGICAL unclosed <!-- N=32000 (128 KB)" patho_unclosed_comments_32000.md 0
bc "PATHOLOGICAL increasing backtick runs (500 KB)" patho_backticks_increasing.md 0
bc "PATHOLOGICAL deeply indented list lines (6.5 MB)" patho_deep_list_lines_32000.md 0
bc "PATHOLOGICAL inline list nesting depth 16000 (32 KB)" patho_deep_list_inline_16000.md 0
echo "(smart_quotes_nested: outputs differ by quote direction, so it is timed by patho_bench.py instead)"
echo; echo "artifacts: $T"
