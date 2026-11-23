#!/bin/sh
# Red-team audit of packages/stun (RFC 8489 STUN + RFC 8445 ICE): one command reproduces every
# piece of evidence in README.md.
#
#   sh packages/stun/audit/run_audit.sh [all|build|unit|compare|fuzz|dos|bench]
#
#   unit     pionc test of audit/: control_* MUST PASS, p1_*/p2_* FAIL = reproduced finding
#   compare  3-way differential (Pion vs webrtc-rs stun 0.8.0 --release vs stdlib-only RFC reference
#            diff/stunref.py): 48 encode specs byte-for-byte + 10,126-vector decode corpus
#            (RFC 5769, Chrome/Meet-shaped ICE traffic, attacks, 10k mutations) + 20k fuzz dump
#   fuzz     deterministic mutation fuzzing, 3 seeds x FUZZ_N (default 20000) packets, native
#            debug/release + wasm32 debug/release: exit 0, identical digests
#   dos      /usr/bin/time -l: checklist flood, attribute bomb, 64 KiB message, per-packet scan
#   bench    re-run packages/stun/bench (bench_compare.py) to check README numbers / SHA-256 parity
#
# Needs pionc ($HOME/.pion/bin), node (wasm32 runtime), cargo (crates cached or network), python3.
# Every build artefact goes to $AUDIT_OUT (default /private/tmp/rt_stun_work), never into git.
# Do NOT use `sample`/`lldb` on tokyo-mac-studio-0 (no Developer Mode: they hang).
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt_stun_work}
BIN="$OUT/bin"
DATA="$OUT/out"
WHAT=${1:-all}
FUZZ_N=${FUZZ_N:-20000}
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
  step "build: rust oracle (webrtc-rs stun =0.8.0, --release)"
  rm -rf "$OUT/rust-build" && cp -R "$AUDIT_DIR/diff/rust" "$OUT/rust-build"
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --release --quiet --manifest-path "$OUT/rust-build/Cargo.toml"
  cp "$OUT/rust-target/release/oracle_rust" "$BIN/oracle_rust"
  ls -l "$BIN"
}

run_unit() {
  step "pionc test audit/: control_* must PASS; p1_*/p2_* FAIL = finding reproduced"
  # pionc exits non-zero when a test fails; that is the expected outcome for p1_/p2_.
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
mine = [x for x in d["tests"] if x["pkg"] == "stun_redteam_audit"]
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
pkg = [x for x in d["tests"] if x["pkg"] == "stun"]
print("package's own stun_test.pion: %d/%d pass" % (sum(x["ok"] for x in pkg), len(pkg)))
if any(not x["ok"] for x in ctl):
    sys.exit(1)
PY
}

run_compare() {
  step "corpus: stdlib-only RFC reference generator (diff/stunref.py)"
  python3 -I "$AUDIT_DIR/diff/stunref.py" gen "$DATA"
  step "encode: 48 specs, Pion vs reference vs webrtc-rs (MI-SHA256 specs: reference only)"
  "$BIN/oracle" encode "$DATA/specs.tsv" > "$DATA/pion_wire.out"
  "$BIN/oracle_rust" encode "$DATA/specs.tsv" > "$DATA/rust_wire.out"
  python3 -I - "$DATA" <<'PY'
import sys
d = sys.argv[1]
ld = lambda p: dict(l.rstrip("\n").split("\t", 1) for l in open(p))
ref, pion, rust = ld(d + "/ref_wire.tsv"), ld(d + "/pion_wire.out"), ld(d + "/rust_wire.out")
pr = sum(pion[k] == ref[k] for k in ref)
pu = sum(pion[k] == rust[k] for k in rust if rust[k] != "W=na")
na = sum(rust[k] == "W=na" for k in rust)
print("pion == reference: %d/%d   pion == webrtc-rs: %d/%d (+%d MI-SHA256 specs webrtc-rs cannot encode)" % (pr, len(ref), pu, len(rust) - na, na))
bad = [k for k in ref if pion[k] != ref[k]] + [k for k in rust if rust[k] != "W=na" and pion[k] != rust[k]]
for k in bad[:5]:
    print("  MISMATCH", k)
sys.exit(1 if bad else 0)
PY
  step "decode: 3-way differential over $(wc -l < "$DATA/corpus.tsv" | tr -d ' ') vectors"
  "$BIN/oracle" decode "$DATA/corpus.tsv" > "$DATA/pion.out"
  python3 -I "$AUDIT_DIR/diff/stunref.py" decode "$DATA/corpus.tsv" > "$DATA/ref.out"
  "$BIN/oracle_rust" decode "$DATA/corpus.tsv" > "$DATA/rust.out"
  python3 -I "$AUDIT_DIR/diff/compare.py" "$DATA/pion.out" "$DATA/ref.out" "$DATA/rust.out" --show 6 --md "$DATA/diff.md"
  step "decode: 3-way differential over the Pion fuzzer's own corpus (seed 1, $FUZZ_N packets)"
  "$BIN/oracle" fuzz 1 "$FUZZ_N" dump > "$DATA/fuzz_corpus.tsv"
  "$BIN/oracle" decode "$DATA/fuzz_corpus.tsv" > "$DATA/fz_pion.out"
  python3 -I "$AUDIT_DIR/diff/stunref.py" decode "$DATA/fuzz_corpus.tsv" > "$DATA/fz_ref.out"
  "$BIN/oracle_rust" decode "$DATA/fuzz_corpus.tsv" > "$DATA/fz_rust.out"
  python3 -I "$AUDIT_DIR/diff/compare.py" "$DATA/fz_pion.out" "$DATA/fz_ref.out" "$DATA/fz_rust.out" --show 3
}

run_fuzz() {
  step "fuzz: 3 seeds x $FUZZ_N packets x {native release, native debug, wasm32 release, wasm32 debug}"
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
      printf '%-15s rc=%s %s\n' $m $rc "$(cat "$DATA/fuzz_${s}_$m.txt" | tr '\n' ' ' | cut -c1-160)"
      [ $rc -eq 0 ] || bad=1
    done
    n=$(cat "$DATA"/fuzz_${s}_*.txt | sort -u | wc -l | tr -d ' ')
    if [ "$n" = 1 ]; then echo "seed $s: 4 modes byte-identical"; else echo "seed $s: MODES DIFFER"; bad=1; fi
  done
  [ $bad -eq 0 ] && echo "fuzz: 0 panic / 0 trap / 0 SIGSEGV, native == wasm32" || { echo "fuzz: FAILURE"; return 1; }
}

timed() {
  /usr/bin/time -l "$@" > "$OUT/dos.txt" 2> "$OUT/dos.time" || true
  printf '%s | wall %ss | peak RSS %s MiB\n' "$(tr '\n' ' ' < "$OUT/dos.txt")" \
    "$(awk '/ real/{print $1}' "$OUT/dos.time")" \
    "$(awk '/maximum resident/{printf "%.1f", $1/1048576}' "$OUT/dos.time")"
}

run_dos() {
  step "dos: checklist flood (P1-5): L local x R remote candidates, O(P^2) pair formation"
  for lr in "1 1000" "1 4000" "4 4000" "10 4000" "20 4000"; do
    # shellcheck disable=SC2086
    timed timeout 300 "$BIN/oracle" dos cands $lr
  done
  printf '(wasm32) '
  timed timeout 300 node "$WASM_RT" "$BIN/oracle.wasm" dos cands 10 4000
  echo "(extrapolated 2000 x 2000 = 4M pairs: ~(4e6/8e4)^2 x 37 s ~ 26 h -- not run)"
  step "dos: attribute bomb (16383 zero-length attrs, 64 KiB) / max-size message decode+MI+FP"
  timed "$BIN/oracle" dos attrs 16383
  timed "$BIN/oracle" dos big 2000
  step "dos: authenticated responses vs pair count (linear tx-id scan per packet)"
  timed "$BIN/oracle" dos inbound 100 100000
  timed "$BIN/oracle" dos inbound 10000 100000
}

run_bench() {
  step "bench: packages/stun/bench (Pion vs webrtc-rs stun 0.8, bench_compare.py, artefacts in $OUT/bench)"
  B="$OUT/bench"
  mkdir -p "$B/bin"
  pionc build --release -o "$B/bin/pion_stun_bench" "$PKG_DIR/bench/pion_bench" > /dev/null
  rm -rf "$B/rust-proj" && mkdir -p "$B/rust-proj"
  cp -R "$PKG_DIR/bench/rust/Cargo.toml" "$PKG_DIR/bench/rust/src" "$B/rust-proj/"
  CARGO_TARGET_DIR="$B/rust-target" cargo build --release --quiet --manifest-path "$B/rust-proj/Cargo.toml"
  cp "$B/rust-target/release/stun-bench-rust" "$B/bin/rust_stun_bench"
  for mode in encode_sign decode_verify; do
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "stun $mode (audit re-run)" \
      --impl "pion=$B/bin/pion_stun_bench $mode" --impl "rust_webrtc_stun=$B/bin/rust_stun_bench $mode" \
      --baseline rust_webrtc_stun --warmup 1 --rounds "${BENCH_ROUNDS:-5}" --ops 100000 \
      --md-out "$B/$mode.md" --json-out "$B/$mode.json" | tail -8
  done
}

case "$WHAT" in
  build) build ;;
  unit) run_unit ;;
  compare) [ -x "$BIN/oracle_rust" ] || build; run_compare ;;
  fuzz) [ -f "$BIN/oracle_debug.wasm" ] || build; run_fuzz ;;
  dos) [ -x "$BIN/oracle" ] || build; run_dos ;;
  bench) run_bench ;;
  all) build; run_unit; run_compare; run_fuzz; run_dos ;;
  *) echo "usage: $0 [all|build|unit|compare|fuzz|dos|bench]" >&2; exit 2 ;;
esac
