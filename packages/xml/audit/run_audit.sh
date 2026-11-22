#!/bin/sh
# One-shot red-team audit of packages/xml:
#   Pion `xml`  vs  Rust roxmltree =0.21.2 (DOM)  /  quick-xml =0.42.0 (pull Reader)
#
#   sh packages/xml/audit/run_audit.sh            # everything (~2 min on an M-series Mac)
#   sh packages/xml/audit/run_audit.sh --quick    # skip the head-to-head bench section (~40 s)
#   SECTIONS="build tests diff" sh .../run_audit.sh
#        sections: build tests diff wasm scaling bench
#
# Needs: pionc (~/.pion/bin), cargo, python3, node (wasm32 runner of `pionc run --target wasm32`),
# curl + network for the first W3C XML Conformance Test Suite download (xmlts20130923).
# Everything built or generated goes to $AUDIT_OUT (default /tmp/pion-xml-audit); the git worktree
# is never written to (AGENTS.md 1.5).
#
# Exit status: 0 when every section ran. The red-team tests (section `tests`) are *expected* to
# FAIL while the reported defects exist; their pass/fail list is printed, not turned into an exit code.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT="${AUDIT_OUT:-/tmp/pion-xml-audit}"
BIN="$OUT/bin"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1
if [ $QUICK = 1 ]; then
  SECTIONS="${SECTIONS:-build tests diff wasm scaling}"
else
  SECTIONS="${SECTIONS:-build tests diff wasm scaling bench}"
fi
W3C_URL="https://www.w3.org/XML/Test/xmlts20130923.tar.gz"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$BIN" "$OUT/logs"

want() { case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }
hdr() { printf '\n\033[1m==== %s ====\033[0m\n' "$*"; }

ROX_SRC=""
find_rox() {
  ROX_SRC=$(ls -d "${CARGO_HOME:-$HOME/.cargo}"/registry/src/*/roxmltree-0.21.2 2>/dev/null | head -1 || true)
}

if want build; then
  hdr "build: pion_dump + pion_perf (pionc --release), rust_dump + rust_perf (roxmltree 0.21.2, quick-xml 0.42.0)"
  pionc build --release -o "$BIN/pion_dump" "$AUDIT_DIR/tools/pion_dump"
  pionc build --release -o "$BIN/pion_perf" "$AUDIT_DIR/tools/pion_perf"
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --quiet --release --locked \
    --manifest-path "$AUDIT_DIR/tools/rust_ref/Cargo.toml"
  cp "$OUT/rust-target/release/rust_dump" "$OUT/rust-target/release/rust_perf" "$BIN/"
  if [ ! -f "$OUT/w3c/xmlconf/xmlconf.xml" ]; then
    mkdir -p "$OUT/w3c"
    curl -sSfL -o "$OUT/xmlts.tgz" "$W3C_URL"
    tar -xzf "$OUT/xmlts.tgz" -C "$OUT/w3c"
  fi
  find_rox
  python3 -I "$AUDIT_DIR/diff/gen_corpus.py" "$OUT/corpus" "$ROX_SRC" "$OUT/w3c/xmlconf"
  python3 -I "$AUDIT_DIR/perf/gen_adversarial.py" "$OUT/adv"
  python3 -I "$AUDIT_DIR/perf/gen_adversarial.py" "$OUT/advq" --quick >/dev/null
  python3 "$ROOT_DIR/packages/xml/bench/gen_data.py" "$OUT/adv" >/dev/null
fi

if want tests; then
  hdr "red-team tests (packages/xml/audit/*_test.pion): FAIL = defect still present"
  pionc fmt --check "$AUDIT_DIR"
  pionc check --json "$AUDIT_DIR" >/dev/null
  pionc test --json "$AUDIT_DIR" > "$OUT/logs/tests.json" 2> "$OUT/logs/tests.stderr" || true
  python3 -I - "$OUT/logs/tests.json" <<'EOF'
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
rows = [t for t in d["tests"] if t["pkg"] == "xml_audit"]
for t in rows:
    print("  %s %s" % ("PASS" if t["ok"] else "FAIL", t["name"]))
fails = [t for t in rows if not t["ok"]]
ctrl = [t for t in fails if t["name"].startswith("control_")]
print("  -> %d audit tests: %d pass, %d fail (%d of the failures are controls)" % (
    len(rows), len(rows) - len(fails), len(fails), len(ctrl)))
main = [t for t in d["tests"] if t["pkg"] == "xml"]
print("  -> upstream packages/xml suite: %d/%d pass" % (sum(t["ok"] for t in main), len(main)))
EOF
  echo "  failure messages: $OUT/logs/tests.stderr"
fi

if want diff; then
  hdr "differential: pion DOM vs roxmltree, DOM vs Reader, W3C conformance"
  python3 -I "$AUDIT_DIR/diff/run_diff.py" "$BIN" "$OUT/corpus" "$OUT/logs"
fi

if want wasm; then
  hdr "wasm32: pion_dump under \`pionc run --target wasm32\` must be byte-identical to native"
  for pack in "$OUT"/corpus/*.pack; do
    for mode in dom dom_dtd rd rd_dtd; do
      "$BIN/pion_dump" "$mode" "$pack" > "$OUT/logs/native.out"
      pionc run --release --target wasm32 "$AUDIT_DIR/tools/pion_dump" -- "$mode" "$pack" > "$OUT/logs/wasm.out"
      if cmp -s "$OUT/logs/native.out" "$OUT/logs/wasm.out"; then
        echo "  identical: $(basename "$pack") $mode"
      else
        echo "  DIFFERENT: $(basename "$pack") $mode"
      fi
    done
  done
  N=40000
  echo "  P0-1 on wasm32: DOM parse of merge_$N.xml ($(wc -c < "$OUT/adv/merge_$N.xml") bytes)"
  if pionc run --release --target wasm32 "$AUDIT_DIR/tools/pion_perf" -- dom "$OUT/adv/merge_$N.xml" 1 \
      > "$OUT/logs/wasm_merge.out" 2> "$OUT/logs/wasm_merge.err"; then
    echo "    completed: $(tr '\n' ' ' < "$OUT/logs/wasm_merge.out")"
  else
    echo "    CRASHED: $(grep -m1 -i error "$OUT/logs/wasm_merge.err" || tail -1 "$OUT/logs/wasm_merge.err")"
  fi
fi

if want scaling; then
  hdr "complexity probe (2x input per row): P0-1 Text/CDATA merge"
  python3 -I "$AUDIT_DIR/perf/scaling.py" "$BIN" "$OUT/adv" "$OUT/logs/scaling.md"
fi

if want bench; then
  hdr "head-to-head adversarial benchmarks (scripts/bench_compare.py, SHA-256 verified)"
  sh "$AUDIT_DIR/perf/run_bench.sh" "$BIN" "$OUT/adv" "$OUT/advq" "$OUT/bench" 5
fi

hdr "done; artefacts in $OUT"
git -C "$ROOT_DIR" status --porcelain --ignored -- packages/xml
