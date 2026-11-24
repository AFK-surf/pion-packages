#!/bin/sh
# Red-team audit of packages/csp (W3C CSP3 + WHATWG Fetch CORS): one command reproduces every
# piece of evidence in README.md.
#
#   sh packages/csp/audit/run_audit.sh [all|build|unit|compare|fuzz|dos|bench]
#
#   unit     pionc test of audit/: control_* MUST PASS, p0_*/p1_*/p2_* FAIL = reproduced finding
#   compare  differential vs an independent reference (diff/cspref.mjs: Node WHATWG URL + CSP3
#            §6.7.2 matching transcribed from the spec): ~89k records, raw and href-normalised URLs
#   fuzz     deterministic grammar+mutation fuzzing, 3 seeds x FUZZ_N (default 10000) inputs of every
#            public API, native debug/release + wasm32 debug/release: exit 0, identical digests
#   dos      /usr/bin/time -l: source / directive / duplicate / policy floods, 64 KiB worst case,
#            huge Access-Control-Allow-Headers, 4 MB target URL
#   bench    re-run packages/csp/bench (bench_compare.py) to check README numbers / SHA-256 parity
#
# Needs pionc ($HOME/.pion/bin), node (wasm32 runtime + reference), cargo (bench), python3.
# Every build artefact goes to $AUDIT_OUT (default /private/tmp/rt_csp_work), never into git.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt_csp_work}
BIN="$OUT/bin"
DATA="$OUT/out"
WHAT=${1:-all}
FUZZ_N=${FUZZ_N:-10000}
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$BIN" "$DATA"

step() { printf '\n==== %s ====\n' "$*"; }

build() {
  step "build: pion oracle (native debug/release + wasm32 debug/release)"
  pionc build --release -o "$BIN/oracle" "$AUDIT_DIR/oracle" > "$OUT/build.log" 2>&1 || { cat "$OUT/build.log"; exit 1; }
  pionc build -o "$BIN/oracle_debug" "$AUDIT_DIR/oracle" >> "$OUT/build.log" 2>&1
  pionc build --release --target wasm32 -o "$BIN/oracle.wasm" "$AUDIT_DIR/oracle" >> "$OUT/build.log" 2>&1
  pionc build --target wasm32 -o "$BIN/oracle_debug.wasm" "$AUDIT_DIR/oracle" >> "$OUT/build.log" 2>&1
  ls -l "$BIN"
}

run_unit() {
  step "pionc fmt --check / check of audit/"
  pionc fmt --check "$AUDIT_DIR"
  pionc check --json "$AUDIT_DIR" > /dev/null
  step "pionc test audit/: control_* must PASS; p0_*/p1_*/p2_* FAIL = finding reproduced"
  # pionc exits non-zero when a test fails; that is the expected outcome for p0_/p1_/p2_.
  pionc test --json "$AUDIT_DIR" > "$OUT/tests.json" 2> "$OUT/tests.stderr" || true
  python3 -I - "$OUT/tests.json" "$OUT/tests.stderr" <<'PY'
import json, re, sys
t = open(sys.argv[1]).read() + open(sys.argv[2]).read()
d = json.JSONDecoder().raw_decode(t[t.find('{"ok"'):])[0]
if "diagnostics" in d:
    for x in d["diagnostics"]:
        print("COMPILE ERROR", x["file"], x["line"], x["message"])
    sys.exit(1)
why = {}
for m in re.finditer(r"(redteam|control)_test\.pion:(\d+): (.*)", open(sys.argv[2]).read()):
    why[int(m.group(2))] = m.group(3)
mine = [x for x in d["tests"] if x["pkg"] == "csp_redteam_audit"]
ctl = [x for x in mine if x["name"].startswith("control_")]
rt = [x for x in mine if x["name"].startswith(("p0_", "p1_", "p2_"))]
print("control tests: %d, passed %d" % (len(ctl), sum(x["ok"] for x in ctl)))
for x in ctl:
    print("  %s %s" % ("PASS" if x["ok"] else "FAIL(REGRESSION)", x["name"]))
print("red-team tests: %d, failing (= reproduced) %d" % (len(rt), sum(not x["ok"] for x in rt)))
for x in rt:
    print("  %s %s" % ("FAIL(reproduced)" if not x["ok"] else "PASS(fixed?)", x["name"]))
print("evidence (assertion messages):")
for line in sorted(why):
    print("  line %d: %s" % (line, why[line]))
pkg = [x for x in d["tests"] if x["pkg"] == "csp"]
print("package's own csp_test.pion: %d/%d pass" % (sum(x["ok"] for x in pkg), len(pkg)))
if any(not x["ok"] for x in ctl):
    sys.exit(1)
PY
}

run_compare() {
  step "differential: Pion check_source / parse_origin vs diff/cspref.mjs (WHATWG URL + CSP3 §6.7.2)"
  node "$AUDIT_DIR/diff/cspref.mjs" gen "$DATA" "${DIFF_N:-600}"
  "$BIN/oracle" eval "$DATA/corpus.tsv" > "$DATA/pion.out"
  # exit 1 = bypass rows present (expected on the audited baseline)
  node "$AUDIT_DIR/diff/cspref.mjs" compare "$DATA" "$DATA/pion.out" || true
}

run_fuzz() {
  step "fuzz: 3 seeds x $FUZZ_N inputs x {native release, native debug, wasm32 release, wasm32 debug}"
  bad=0
  for s in 1 2 3; do
    for m in native_release native_debug wasm_release wasm_debug; do
      case $m in
        native_release) set -- "$BIN/oracle" ;;
        native_debug) set -- "$BIN/oracle_debug" ;;
        wasm_release) set -- node "$WASM_RT" "$BIN/oracle.wasm" ;;
        wasm_debug) set -- node "$WASM_RT" "$BIN/oracle_debug.wasm" ;;
      esac
      "$@" fuzz $s "$FUZZ_N" > "$DATA/fuzz_${s}_$m.txt" 2>&1 && rc=0 || rc=$?
      printf '%-15s rc=%s %s\n' $m $rc "$(tr '\n' ' ' < "$DATA/fuzz_${s}_$m.txt" | cut -c1-240)"
      [ $rc -eq 0 ] || bad=1
    done
    n=$(cat "$DATA"/fuzz_${s}_*.txt | sort -u | wc -l | tr -d ' ')
    if [ "$n" = 1 ]; then echo "seed $s: 4 modes byte-identical"; else echo "seed $s: MODES DIFFER"; bad=1; fi
  done
  [ $bad -eq 0 ] && echo "fuzz: 0 panic / 0 trap, native == wasm32, serialize fixpoint + decision-stable" || { echo "fuzz: FAILURE"; return 1; }
}

timed() {
  /usr/bin/time -l "$@" > "$OUT/dos.txt" 2> "$OUT/dos.time" || true
  printf '%s | wall %ss | peak RSS %s MiB\n' "$(tr '\n' ' ' < "$OUT/dos.txt")" \
    "$(awk '/ real/{print $1}' "$OUT/dos.time")" \
    "$(awk '/maximum resident/{printf "%.1f", $1/1048576}' "$OUT/dos.time")"
}

run_dos() {
  step "dos: inside ParseLimits::default() (worst-case 64 directives x 256 sources, 1000 parses)"
  timed "$BIN/oracle" dos default 1000
  printf '(wasm32) '
  timed node "$WASM_RT" "$BIN/oracle.wasm" dos default 1000
  step "dos: limits lifted to i32::MAX (what a caller raising the limits gets)"
  for a in "sources 10000" "sources 100000" "directives 5000" "directives 20000" "dups 100000" "list 20000"; do
    # shellcheck disable=SC2086
    timed "$BIN/oracle" dos $a
  done
  step "dos: CORS (no size limits in the API) and huge target URLs"
  timed "$BIN/oracle" dos cors 100000 100
  timed "$BIN/oracle" dos cors 1000000 1
  timed "$BIN/oracle" dos url 1000000
}

run_bench() {
  step "bench: packages/csp/bench (Pion vs Rust mirror, bench_compare.py, artefacts in $OUT/bench)"
  B="$OUT/bench"
  mkdir -p "$B/bin"
  pionc build --release -o "$B/bin/pion_csp_bench" "$PKG_DIR/bench/pion_bench" > /dev/null
  rm -rf "$B/rust-proj" && mkdir -p "$B/rust-proj"
  cp -R "$PKG_DIR/bench/rust/Cargo.toml" "$PKG_DIR/bench/rust/src" "$B/rust-proj/"
  CARGO_TARGET_DIR="$B/rust-target" cargo build --release --quiet --manifest-path "$B/rust-proj/Cargo.toml"
  cp "$B/rust-target/release/csp-bench-rust" "$B/bin/rust_csp_bench"
  for mode in csp cors; do
    ops=100000; [ $mode = cors ] && ops=200000
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "csp $mode (audit re-run)" \
      --impl "pion=$B/bin/pion_csp_bench $mode" --impl "rust_csp=$B/bin/rust_csp_bench $mode" \
      --baseline rust_csp --warmup 1 --rounds "${BENCH_ROUNDS:-5}" --ops $ops \
      --md-out "$B/$mode.md" --json-out "$B/$mode.json" | tail -8
    printf 'stdout sha256: pion %s  rust %s\n' "$("$B/bin/pion_csp_bench" $mode | shasum -a 256 | cut -c1-16)" "$("$B/bin/rust_csp_bench" $mode | shasum -a 256 | cut -c1-16)"
  done
}

case "$WHAT" in
  build) build ;;
  unit) run_unit ;;
  compare) [ -x "$BIN/oracle" ] || build; run_compare ;;
  fuzz) [ -f "$BIN/oracle_debug.wasm" ] || build; run_fuzz ;;
  dos) [ -x "$BIN/oracle" ] || build; run_dos ;;
  bench) run_bench ;;
  all) build; run_unit; run_compare; run_fuzz; run_dos ;;
  *) echo "usage: $0 [all|build|unit|compare|fuzz|dos|bench]" >&2; exit 2 ;;
esac
