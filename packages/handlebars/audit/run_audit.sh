#!/bin/sh
# Red-team audit of packages/handlebars (Pion, feat/pkg-handlebars @ 4ab06f4) against Handlebars.js 4.7.8,
# Rust `handlebars` =6.4.4 and the official Mustache Spec v1.4.2 core vectors. See REPORT.md.
#
#   sh packages/handlebars/audit/run_audit.sh                 # everything (~6 min on an M-series Mac)
#   STEPS="unit diff" sh packages/handlebars/audit/run_audit.sh   # subset of: unit diff fourmode dos bench
#
# Exit status: 0 iff every graded check passes (all red-team unit tests, every graded differential case,
# 4-mode identity, every DoS probe within budget). The bench step is informational and never fails.
# A fix branch can re-run this script unchanged: expectations live in this directory, not in the oracles.
#
# Needs: pionc ($HOME/.pion/bin, AFK-surf/pion@66d2b4b), node (wasm32 runtime + Handlebars.js oracle),
# cargo, python3, curl, npm, network for the first cargo/npm/spec fetch. Every build, download and log
# goes to $AUDIT_OUT (default /private/tmp/rt-handlebars-audit); the worktree is never written to.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HBS_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$HBS_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt-handlebars-audit}
BIN="$OUT/bin"
STEPS=${STEPS:-"unit diff fourmode dos bench"}
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SPEC_TAG=v1.4.2
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH" PYTHONDONTWRITEBYTECODE=1
export CARGO_TARGET_DIR="$OUT/cargo-target"
mkdir -p "$BIN"
# Copy a binary to a fresh inode: overwriting a code-signed Mach-O in place gets it SIGKILLed on macOS.
put() { rm -f "$2" && cp "$1" "$2"; }
want() { case " $STEPS " in *" $1 "*) return 0 ;; esac; return 1; }
section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
D="$AUDIT_DIR/diff"
STATUS=0
fail() { STATUS=1; printf '\033[31m>>> %s\033[0m\n' "$1"; }

section "0. Build -> $BIN (Pion probe x4 modes, Rust oracle, Handlebars.js 4.7.8, Mustache spec $SPEC_TAG)"
pionc build --release -o "$BIN/probe" "$AUDIT_DIR/probe"
pionc build -o "$BIN/probe_dbg" "$AUDIT_DIR/probe"
pionc build --release --target wasm32 -o "$BIN/probe.wasm" "$AUDIT_DIR/probe"
pionc build --target wasm32 -o "$BIN/probe_dbg.wasm" "$AUDIT_DIR/probe"
for c in oracle/rust bench/rust_fair; do
  rm -rf "$OUT/src-$(basename $c)" && cp -R "$AUDIT_DIR/$c" "$OUT/src-$(basename $c)"
  cargo build -q --release --locked --manifest-path "$OUT/src-$(basename $c)/Cargo.toml"
done
put "$CARGO_TARGET_DIR/release/rt_handlebars_oracle" "$BIN/rust_oracle"
put "$CARGO_TARGET_DIR/release/handlebars_rust_fair" "$BIN/rust_fair"
if [ ! -f "$OUT/node/node_modules/handlebars/package.json" ]; then
  mkdir -p "$OUT/node" && (cd "$OUT/node" && npm init -y >/dev/null && npm install -s --no-audit --no-fund handlebars@4.7.8 >/dev/null)
fi
HBS="node $AUDIT_DIR/oracle/hbsjs/oracle.js $OUT/node/node_modules"
if [ ! -f "$OUT/spec/specs/sections.json" ]; then
  rm -rf "$OUT/spec" && mkdir -p "$OUT/spec"
  curl -sSfL "https://github.com/mustache/spec/archive/refs/tags/$SPEC_TAG.tar.gz" | tar xz -C "$OUT/spec" --strip-components=1
fi
(cd "$OUT/spec/specs" && shasum -a 256 -c - >/dev/null) <<'SUMS'
e5e07151b538c62d3d00e585ff49e411817ba7eb834267fd5ad67225b6e025b6  comments.json
a5ac3b70e04ecd03f292977e172883a41c97a949201e7d6aa364054148df225e  delimiters.json
530f691371198333f894a4b7c64cf7bdfd2247dfa04e769202c4c3fc31c28bf1  interpolation.json
8c5f81135bfad218ca9a4524221c3199e3b0e82654f9b4686013ca6ef93edaa5  inverted.json
61b0de5f51b8cb61259a7291aeaa2df26ef8e6b410be1d5ebd39e6e318a1f640  partials.json
f9acc93eb30e5997f9168bd531656f5468cba250fcf84d55d97ac5570327ce37  sections.json
SUMS
echo "built: $(ls "$BIN" | tr '\n' ' ')"

if want unit; then
  section "1. Red-team unit tests: pionc test packages/handlebars/audit (every p0_/p1_/p2_ FAIL is a finding)"
  (cd "$HBS_DIR" && pionc test --json audit > "$OUT/redteam_test.json" 2> "$OUT/redteam_test.stderr") || true
  python3 - "$OUT/redteam_test.json" <<'PY' || fail "red-team unit tests"
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
mine = [t for t in d["tests"] if t["pkg"] == "handlebars_audit"]
other = [t for t in d["tests"] if t["pkg"] != "handlebars_audit"]
print("handlebars_audit: %d tests, %d FAILED (findings), %d passed; dependency tests %d/%d ok" % (
    len(mine), sum(not t["ok"] for t in mine), sum(t["ok"] for t in mine), sum(t["ok"] for t in other), len(other)))
for t in mine:
    print("  %-5s %s" % ("FAIL" if not t["ok"] else "pass", t["name"]))
bad = [t["name"] for t in mine if t["name"].startswith("control_") and not t["ok"]]
if bad:
    print("UNEXPECTED: control tests failing:", bad)
sys.exit(1 if any(not t["ok"] for t in d["tests"]) or not mine else 0)
PY
  echo "assertion messages:"; sed 's|^.*/audit/|  |' "$OUT/redteam_test.stderr" | grep -v '^ *$' | head -40
fi

if want diff; then
  section "2. Differential: Pion vs Rust handlebars =6.4.4 vs Handlebars.js 4.7.8 (adversarial corpus + Mustache spec)"
  python3 "$D/diff.py" "$OUT" "$OUT/spec/specs" "$BIN/probe" "$BIN/rust_oracle" "$HBS" || fail "differential"
fi

if want fourmode; then
  section "3. 4-mode consistency (native_dbg / native_rel / wasm_dbg / wasm_rel) over the whole corpus"
  python3 "$D/fourmode.py" "$OUT" "$OUT/spec/specs" "$BIN" "$WASM_RT" || fail "4-mode consistency"
fi

if want dos; then
  section "4. DoS / stack / complexity probes (4 modes, per-case process, budgets) + Rust / Handlebars.js reference"
  python3 "$D/gen_dos.py" "$OUT/dos.jsonl"
  python3 -u "$D/dos.py" "$OUT/dos.jsonl" "$BIN" "$WASM_RT" "$BIN/rust_oracle" "$HBS" || fail "DoS probes"
fi

if want bench; then
  section "5. Benchmark fairness (informational): official W1/W2/W3 vs Rust with a prebuilt Context, blind spots B1-B3"
  python3 "$HBS_DIR/bench/gen_data.py" "$OUT/bench" >/dev/null
  python3 "$AUDIT_DIR/bench/gen_blind.py" "$OUT/bench"
  pionc build --release -o "$BIN/pion_bench" "$HBS_DIR/bench/pion_bench"
  pionc build --release -o "$BIN/pion_blind" "$AUDIT_DIR/bench/pion_blind"
  rm -rf "$OUT/src-rust_bench" && cp -R "$HBS_DIR/bench/rust_bench" "$OUT/src-rust_bench"
  cargo build -q --release --locked --manifest-path "$OUT/src-rust_bench/Cargo.toml"
  put "$CARGO_TARGET_DIR/release/handlebars_bench_rust" "$BIN/rust_bench"
  B="$OUT/bench"
  bc() { python3 "$ROOT_DIR/scripts/bench_compare.py" --warmup 1 --rounds 5 "$@" | sed -n '/^| Impl/,/^_SHA/p'; }
  echo "### W1 (1,000 renders): official harness vs Rust rendering from a prebuilt Context"
  bc --title W1 --ops 1000 --baseline rust_official --impl "pion=$BIN/pion_bench w1 $B 1000" \
    --impl "rust_official=$BIN/rust_bench w1 $B 1000" --impl "rust_ctx=$BIN/rust_fair w1ctx $B 1000" || true
  echo; echo "### W2 (2,000 compile+render iterations, harness unchanged)"
  bc --title W2 --ops 2000 --baseline rust_official --impl "pion=$BIN/pion_bench w2 $B 2000" \
    --impl "rust_official=$BIN/rust_bench w2 $B 2000" || true
  echo; echo "### W3 (200 renders): official harness vs Rust rendering from a prebuilt Context"
  bc --title W3 --ops 200 --baseline rust_official --impl "pion=$BIN/pion_bench w3 $B 200" \
    --impl "rust_official=$BIN/rust_bench w3 $B 200" --impl "rust_ctx=$BIN/rust_fair w3ctx $B 200" || true
  echo; echo "### B1 wide-object lookups (20 renders x 2,000 @root lookups, 5,002-key root)"
  bc --title B1 --ops 20 --baseline rust --impl "pion=$BIN/pion_blind b1 $B 20" --impl "rust=$BIN/rust_fair b1 $B 20" || true
  echo; echo "### B2 partial fan-out (50 renders x 4,096 leaf partials)"
  bc --title B2 --ops 50 --baseline rust --impl "pion=$BIN/pion_blind b2 $B 50" --impl "rust=$BIN/rust_fair b2 $B 50" || true
  echo; echo "### B3 large-template compile + render (10 x 64 KiB template from source)"
  bc --title B3 --ops 10 --baseline rust --impl "pion=$BIN/pion_blind b3 $B 10" --impl "rust=$BIN/rust_fair b3 $B 10" || true
fi

section "Done. Artifacts in $OUT"
if [ "$STATUS" -ne 0 ]; then
  echo "RESULT: defects reproduced (exit 1)"
else
  echo "RESULT: all graded checks pass (exit 0)"
fi
exit "$STATUS"
