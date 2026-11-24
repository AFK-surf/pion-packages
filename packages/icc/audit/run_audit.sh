#!/bin/sh
# One-shot red-team audit for packages/icc (see REPORT.md).
#   sh packages/icc/audit/run_audit.sh [all|build|cases|unit|diff|adv|trunc|fuzz|dos|portability|smoke|bench]
# (single sections need a previous `build`)
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), cargo (Rust qcms 0.3.0 + moxcms 0.9.2 oracle, locked; uses the
# crate cache when offline), python3 (stdlib only). On macOS the ColorSync system profiles in
# /System/Library/ColorSync/Profiles join the differential run read-only, out of tree; they are never copied into git.
# Artifacts go to $AUDIT_OUT (default /private/tmp/pion-icc-audit: the real path of /tmp on macOS, because the
# wasm32 runner resolves symlinks). Nothing is written inside the repository.
#
# Exit status: 1 while any P0 condition reproduces (crash / trap / hang on any input, a P0 red-team case or DoS budget
# breach, a transform more than 1 LSB away from the exact ICC float reference on well-formed input that is not a
# classified finding, a native-vs-wasm32 or debug-vs-release divergence, a failing control case, a portability gate,
# wasm_smoke output that differs between the 4 modes, or shipped bench output that is not byte-identical).
# Open P1/P2 findings are listed as OPEN and fail the run only with STRICT=1 (STRICT=1 exits 0 only with 0 OPEN, 0 P0).
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-icc-audit}
if [ ! -d /private/tmp ] && [ "$AUDIT_OUT" = /private/tmp/pion-icc-audit ]; then AUDIT_OUT=/tmp/pion-icc-audit; fi
BIN="$AUDIT_OUT/bin"
C="$AUDIT_OUT/corpus"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SYS_ICC=/System/Library/ColorSync/Profiles
SECTION=${1:-all}
FUZZ_N=${FUZZ_N:-10000}
STRICT=${STRICT:-0}
CMP="python3 -I $AUDIT_DIR/diff/compare.py"
mkdir -p "$BIN"
export PYTHONDONTWRITEBYTECODE=1
RC=0
OPEN=""
fail() { echo "  FAIL (P0): $*"; RC=1; }
open_finding() { echo "  OPEN: $*"; OPEN="$OPEN
  - $*"; }

runner() {
  case "$1" in
    native_dbg) echo "$BIN/icc_audit_dbg" ;;
    native_rel) echo "$BIN/icc_audit_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/icc_audit_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/icc_audit_rel.wasm" ;;
  esac
}
MODES="native_dbg native_rel wasm_dbg wasm_rel"

build() {
  echo "==> build: icc_audit in 4 modes, qcms 0.3.0 + moxcms 0.9.2 oracle (cargo --locked), corpus"
  pionc fmt --check "$AUDIT_DIR" > /dev/null || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  pionc build -o "$BIN/icc_audit_dbg" "$AUDIT_DIR" > /dev/null || fail "build native_dbg"
  pionc build --release -o "$BIN/icc_audit_rel" "$AUDIT_DIR" > /dev/null || fail "build native_rel"
  pionc build --target wasm32 -o "$BIN/icc_audit_dbg.wasm" "$AUDIT_DIR" > /dev/null || fail "build wasm_dbg"
  pionc build --release --target wasm32 -o "$BIN/icc_audit_rel.wasm" "$AUDIT_DIR" > /dev/null || fail "build wasm_rel"
  M="$AUDIT_DIR/diff/oracle/Cargo.toml"
  { CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline --manifest-path "$M" 2> /dev/null ||
    CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --manifest-path "$M"; } || fail "cargo build oracle"
  cp "$AUDIT_OUT/rust-target/release/icc_audit_oracle" "$BIN/oracle"
  rm -rf "$C" && python3 -I "$AUDIT_DIR/diff/gen.py" "$C" "$FUZZ_N" | sed 's/^/  /'
  cp "$C/diff.lst" "$C/diff_all.lst"
  if [ -d "$SYS_ICC" ]; then
    # out-of-tree, read-only: RGB matrix/TRC and GRAY system profiles (CMYK/Lab/XYZ LUT profiles are adversarial-only)
    for f in "$SYS_ICC"/*.icc; do
      case "$f" in *CMYK* | *Lab* | *XYZ*) echo "$f" >> "$C/sys_lut.lst" ;; *) echo "$f" >> "$C/diff_all.lst" ;; esac
    done
    echo "  + $(grep -c "$SYS_ICC" "$C/diff_all.lst") macOS ColorSync profiles (differential), $(wc -l < "$C/sys_lut.lst" | tr -d ' ') LUT profiles (adv)"
    cat "$C/sys_lut.lst" >> "$C/adv.lst"
  else
    echo "  (no $SYS_ICC: synthetic corpus only)"
  fi
  echo "  $(pionc --version) | node $(node --version) | $(cargo --version) | qcms 0.3.0 | moxcms 0.9.2"
}

# dump a corpus group in every mode, require identical records across modes, keep native_rel as reference
dump_group() {
  g=$1
  for m in $MODES; do
    # shellcheck disable=SC2046
    $CMP run "$C/$g.lst" "$AUDIT_OUT/pion_${g}_$m.txt" $(runner $m) | sed "s/^/  [$m] /"
  done
  for m in native_dbg wasm_dbg wasm_rel; do
    $CMP same "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_${g}_$m.txt" || fail "$g: $m differs from native_rel"
  done
}

cases() {
  echo "==> cases: red-team + control cases, one process per case, in all 4 modes"
  names=$("$BIN/icc_audit_rel" list)
  for m in $MODES; do
    : > "$AUDIT_OUT/cases_$m.txt"
    for c in $names; do
      # shellcheck disable=SC2046
      raw=$($(runner $m) case "$c" 2>&1)
      out=$(printf '%s\n' "$raw" | grep -E '^(PASS|FAIL) ' | tail -1)
      [ -n "$out" ] || out="FAIL $c :: ABORT ($(printf '%s\n' "$raw" | grep -m1 'pion panic' || printf '%s\n' "$raw" | tail -1))"
      # timings inside messages differ between modes: normalise them for the cross-mode comparison
      echo "$out" | sed -E 's/in [0-9]+ ms/in N ms/' >> "$AUDIT_OUT/cases_$m.txt"
    done
    echo "  $m: $(grep -c '^PASS' "$AUDIT_OUT/cases_$m.txt")/$(echo "$names" | wc -w | tr -d ' ') pass"
  done
  sed 's/^/    /' "$AUDIT_OUT/cases_native_rel.txt" | cut -c1-300
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/cases_native_rel.txt" "$AUDIT_OUT/cases_$m.txt" || { diff "$AUDIT_OUT/cases_native_rel.txt" "$AUDIT_OUT/cases_$m.txt" | head -6; fail "case results of $m differ from native_rel"; }
  done
  grep -q 'ABORT' "$AUDIT_OUT"/cases_*.txt && fail "a case aborted (panic / trap)"
  grep -q '^FAIL control_' "$AUDIT_OUT/cases_native_rel.txt" && fail "control case failing"
  for f in $(grep '^FAIL redteam_' "$AUDIT_OUT/cases_native_rel.txt" | awk '{print $2}'); do
    open_finding "$(echo "$f" | sed -E 's/redteam_p([0-9])_([0-9]+)_.*/P\1-\2/'): case $f"
    case "$f" in redteam_p0_*) fail "P0 red-team case $f" ;; esac
  done
}

unit() {
  echo "==> unit: pionc fmt/check/test of packages/icc, pionc test of audit (control_* must pass)"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/icc"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/icc"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> /dev/null
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit_audit.json" 2> "$AUDIT_OUT/unit_audit.stderr"
  python3 -I - "$AUDIT_OUT/unit_pkg.json" "$AUDIT_OUT/unit_audit.json" <<'PY' || fail "unit tests"
import json, sys
pkg = json.load(open(sys.argv[1]))
print("  packages/icc own tests: %d/%d pass" % (pkg["passed"], pkg["total"]))
bad = pkg["failed"]
d = json.load(open(sys.argv[2]))
for t in d["tests"]:
    if t["pkg"] != "icc_audit":
        continue
    print("  %s  %s" % ("PASS" if t["ok"] else ("OPEN" if t["name"].startswith("redteam_") else "FAIL"), t["name"]))
    if not t["ok"] and not t["name"].startswith("redteam_"):
        bad += 1
sys.exit(1 if bad else 0)
PY
}

diff_corpus() {
  echo "==> diff: well-formed profiles, packages/icc vs exact float reference (compare.py) / qcms 0.3.0 / moxcms 0.9.2"
  echo "    input: 4 x 256 ramps + 33^3 grid + 4096 LCG pixels (40 033 px); GRAY profiles: 256-level ramp"
  dump_group diff_all
  $CMP grid "$C/diff_all.lst" "$BIN/icc_audit_rel" "$BIN/oracle" "$C/grid.rgb" "$AUDIT_OUT/grid" > "$AUDIT_OUT/grid.txt"
  r=$?
  sed 's/^/  /' "$AUDIT_OUT/grid.txt" | cut -c1-200
  # the only >1 LSB deviations allowed are the two profiles of finding P2-2 (identity fast path)
  if [ $r = 1 ]; then
    fail "a well-formed profile failed to transform"
  elif [ $r = 2 ]; then
    others=$(grep -B1 '^    > ' "$AUDIT_OUT/grid.txt" | grep -v '^    > \|^--' | grep -vc 'srgb_offdiag_00')
    if [ "$others" = 0 ]; then
      open_finding "P2-2: identity fast path off by $(grep -A1 'srgb_offdiag_0019' "$AUDIT_OUT/grid.txt" | sed -nE 's/.*> ([0-9]+) LSB.*/\1/p') LSB vs exact ICC math"
    else
      fail "transform more than 1 LSB away from the exact reference outside finding P2-2"
    fi
  fi
}

adv() {
  echo "==> adv: adversarial profiles / JPEG / WebP vs the expectation of a correct implementation"
  dump_group adv
  $CMP adv "$C/manifest.json" "$AUDIT_OUT/pion_adv_native_rel.txt" > "$AUDIT_OUT/adv.txt"
  r=$?
  grep -v '^  ok' "$AUDIT_OUT/adv.txt" | cut -c1-260
  echo "  $(grep -c '^  ok' "$AUDIT_OUT/adv.txt") cases as expected"
  [ -f "$C/sys_lut.lst" ] && grep -A5 -F "$SYS_ICC" "$AUDIT_OUT/pion_adv_native_rel.txt" | grep -E '^== |^T ' | paste - - | sed 's/^/  system LUT profile: /'
  for f in $(grep '^  open ' "$AUDIT_OUT/adv.txt" | awk '{print $2}' | tr -d ':'); do open_finding "$f: adversarial corpus"; done
  [ $r = 1 ] && fail "adversarial expectation (P0 or unclassified)"
}

trunc() {
  echo "==> trunc: every byte prefix of 5 seeds (v4 P3, v2 sRGB curv, GRAY mluc, 3-chunk JPEG, VP8X WebP), all 4 modes"
  dump_group trunc
  $CMP fuzz "$AUDIT_OUT/pion_trunc_native_rel.txt" || fail "truncation sweep: crash/timeout"
}

fuzz() {
  echo "==> fuzz: $FUZZ_N deterministic mutants (LCG seed 0x5EED1CC), all 4 modes"
  dump_group fuzz
  $CMP fuzz "$AUDIT_OUT/pion_fuzz_native_rel.txt" || fail "fuzz: crash/timeout"
}

dos() {
  echo "==> dos: resource bombs, verdict + ms/parse + peak RSS (native_rel, budget 250 ms / 512 MiB per parse)"
  python3 -I "$AUDIT_DIR/diff/dos.py" "$C/dos.json" "$BIN/icc_audit_rel" > "$AUDIT_OUT/dos.txt"
  r=$?
  cat "$AUDIT_OUT/dos.txt"
  grep -q 'open P0-1' "$AUDIT_OUT/dos.txt" && open_finding "P0-1: duplicate-tag DoS ($(sed -nE 's/^ *dup_desc_4096x1MiB .* ([0-9.]+) ms\/parse.*/\1 ms/p' "$AUDIT_OUT/dos.txt") for one parse of a 1 MiB profile)"
  [ $r = 1 ] && fail "DoS budget (P0)"
  echo "==> dos (wasm_rel, information): same bombs under node"
  # shellcheck disable=SC2046
  DOS_ADVISORY=0 python3 -I "$AUDIT_DIR/diff/dos.py" "$C/dos.json" $(runner wasm_rel) | sed -n '1,3p;$p'
}

portability() {
  echo "==> portability: packages/icc/src (comments excluded): 0 extern \"C\", 0 World, 0 imports, 0 external deps, module state"
  code=$(cat "$PKG_DIR"/src/*.pion | grep -v '^ *//')
  n=$(printf '%s\n' "$code" | grep -c 'extern "C"')
  echo "  extern \"C\": $n"; [ "$n" = 0 ] || fail "extern \"C\" in packages/icc/src"
  n=$(printf '%s\n' "$code" | grep -cw 'World')
  echo "  World: $n"; [ "$n" = 0 ] || fail "World in packages/icc/src"
  n=$(printf '%s\n' "$code" | grep -c '^import ')
  echo "  imports: $n"; [ "$n" = 0 ] || fail "imports in packages/icc/src"
  deps=$(sed -n '/^\[dependencies\]/,/^\[/p' "$PKG_DIR/pion.toml" | grep -vc '^\[\|^ *$\|^#')
  echo "  pion.toml [dependencies] entries: $deps"; [ "$deps" = 0 ] || fail "external dependencies"
  n=$(cat "$PKG_DIR"/src/*.pion | grep -cE '^(pub )?let mut')
  echo "  module-level 'let mut': $n"; [ "$n" = 0 ] || fail "module-level mutable binding"
  arr=$(grep -nE '^(pub )?let [a-zA-Z_0-9]+ *: *(Array|Bytes|Map|FixedArray|StringBuilder|Ref)' "$PKG_DIR"/src/*.pion | sed "s|$PKG_DIR/||")
  echo "  module-level lets: $(cat "$PKG_DIR"/src/*.pion | grep -cE '^(pub )?let ')"
  if [ -n "$arr" ]; then
    echo "$arr" | sed 's/=.*//; s/^/    module-level mutable container: /'
    # never written after init (only read; Transform's lut fields are private): not a race, but the README
    # "zero mutable module globals" claim is false and every Transform aliases them (P2-6)
    w=$(grep -nE 'srgb_(eotf_q14|oetf_8193)\[[^]]*\] *=' "$PKG_DIR"/src/*.pion | wc -l | tr -d ' ')
    echo "    writes to them anywhere in src/: $w"; [ "$w" = 0 ] || fail "module-level LUT written at run time"
    open_finding "P2-6: module-level FixedArray LUTs contradict README 'zero mutable module globals' (never written)"
  fi
  n=$(find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o \( -iname '*.icc' -o -iname '*.icm' \) -print | wc -l | tr -d ' ')
  echo "  .icc/.icm files in the tree: $n"; [ "$n" = 0 ] || fail "ICC binaries committed"
  ch=$(git -C "$ROOT_DIR" diff --name-only 04ba43c~1 04ba43c | grep -vc '^packages/icc/')
  echo "  files changed by 04ba43c outside packages/icc/: $ch"; [ "$ch" = 0 ] || fail "04ba43c touches files outside packages/icc"
  echo "  Send probe (information): which public results may cross a spawn boundary"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\nicc = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  for v in "icc::IccError::InvalidTag(\"x\")" "icc::Xyz::new(0.0, 0.0, 0.0)" "icc::parse(Bytes::new(0))" "icc::extract_jpeg_icc(Bytes::new(0))" "tf"; do
    printf 'import "icc"\n\n///|\nfn tf() -> Option[icc::Transform] {\n  match icc::parse(Bytes::new(0)) {\n    Ok(p) =>\n      match icc::Transform::to_srgb(p) {\n        Ok(t) => Some(t)\n        Err(_) => None\n      }\n    Err(_) => None\n  }\n}\n\n///|\npub fn main(world : World) -> Int {\n  let v = %s\n  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })\n  0\n}\n' "$( [ "$v" = tf ] && echo 'tf()' || echo "$v")" > "$P/src/main.pion"
    r=$(pionc check --json "$P" 2>&1 | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("Send" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))')
    printf '    %-44s %s\n' "$([ "$v" = tf ] && echo 'Option[icc::Transform]' || echo "$v")" "$r"
  done
}

smoke() {
  echo "==> smoke: packages/icc/wasm_smoke in 4 modes vs README.md"
  want=$(grep -o 'icc_wasm_smoke: OK [^`]*' "$PKG_DIR/README.md" | head -1)
  : > "$AUDIT_OUT/smoke.txt"
  for flags in "" "--release" "--target wasm32" "--release --target wasm32"; do
    # shellcheck disable=SC2086
    out=$(pionc run $flags "$PKG_DIR/wasm_smoke" 2>&1 | tail -1)
    echo "  [${flags:-native debug}] $out"
    echo "$out" >> "$AUDIT_OUT/smoke.txt"
  done
  [ "$(sort -u "$AUDIT_OUT/smoke.txt" | wc -l | tr -d ' ')" = 1 ] || fail "wasm_smoke output differs between modes"
  # the 4 modes agree (the P0 property); a stale README number is an evidence finding (P1-3), not a runtime bug
  [ "$(head -1 "$AUDIT_OUT/smoke.txt")" = "$want" ] || open_finding "P1-3: README wasm_smoke line '$want' is not what the shipped smoke prints ($(head -1 "$AUDIT_OUT/smoke.txt" | sed 's/.* //'))"
  echo "  README.md: $want"
}

bench() {
  PI=${ICC_BENCH_PARSE_ITERS:-20000}
  FR=${ICC_BENCH_FRAMES:-20}
  echo "==> bench: packages/icc/bench/run_bench.sh as shipped (ICC_PARSE_ITERS=$PI ICC_RGBA_FRAMES=$FR)"
  ICC_PARSE_ITERS=$PI ICC_RGBA_FRAMES=$FR sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || { tail -20 "$AUDIT_OUT/bench.log"; fail "run_bench.sh"; return; }
  grep -E '^\| `|SHA-256 verified|accuracy vs' "$AUDIT_OUT/bench.log" | sed 's/^/  /'
  B=/tmp/pion-icc-bench/bin
  D=/tmp/pion-icc-bench/data
  O="$BIN/oracle"
  echo "==> bench fairness A: same loop with qcms' documented precached sRGB output (qcms_pre), 4 profiles"
  : > "$AUDIT_OUT/fair_a.txt"
  for f in "$D/display_p3_v4.icc" "$C/diff/srgb_v2_curv1024.icc" "$C/diff/adobe_v2_gamma.icc" "$C/diff/rec2020_para3_709.icc"; do
    n=$(basename "$f" .icc)
    # qcms without precache costs ~0.3 ms/op: only on the shipped profile, to keep the section short
    set -- --impl "pion_icc=$B/pion_icc parse $f $PI"
    [ "$n" = display_p3_v4 ] && set -- "$@" --impl "rust_qcms=$O build qcms $f $PI"
    set -- "$@" --impl "rust_qcms_pre=$O build qcms_pre $f $PI" --impl "rust_moxcms=$O build moxcms $f $PI"
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "parse + to_srgb $n" "$@" \
      --baseline rust_qcms_pre --warmup 1 --rounds 5 --ops "$PI" --json-out "$AUDIT_OUT/fair_a_$n.json" > "$AUDIT_OUT/fair_a_$n.log" 2>&1 ||
      { tail -5 "$AUDIT_OUT/fair_a_$n.log"; fail "fairness A bench ($n)"; continue; }
    python3 -I - "$AUDIT_OUT/fair_a_$n.json" "$n" <<'PY' | tee -a "$AUDIT_OUT/fair_a.txt"
import json, sys
d = json.load(open(sys.argv[1]))
r = {x["name"]: x for x in d["results"]}
p = r["pion_icc"]
q = r.get("rust_qcms")
print("  %-22s ns/op: pion %6.0f | qcms %8s | qcms_pre %6.0f | moxcms %6.0f || pion vs qcms %7s, vs qcms_pre %5.2fx, vs moxcms %5.2fx" % (
    sys.argv[2], p["ns_per_op"], "%.0f" % q["ns_per_op"] if q else "-", r["rust_qcms_pre"]["ns_per_op"], r["rust_moxcms"]["ns_per_op"],
    "%.1fx" % (q["median_ms"] / p["median_ms"]) if q else "-", r["rust_qcms_pre"]["median_ms"] / p["median_ms"], r["rust_moxcms"]["median_ms"] / p["median_ms"]))
PY
  done
  sp=$(grep display_p3_v4 "$AUDIT_OUT/fair_a.txt" | sed -E 's/.*vs qcms_pre *([0-9.]+)x.*/\1/')
  worst=$(sed -E 's/.*vs qcms_pre *([0-9.]+)x.*/\1/' "$AUDIT_OUT/fair_a.txt" | sort -n | head -1)
  python3 -I -c "import sys; sys.exit(0 if float('${sp:-0}') >= 245.31 / 2 else 1)" ||
    open_finding "P1-1: README Scenario A 245.31x vs qcms is ${sp}x against qcms with its precached sRGB output, worst ${worst}x over 4 profiles"
  echo "==> bench fairness B: 1080p RGBA8 x $FR frames, qcms_pre vs pion"
  python3 "$ROOT_DIR/scripts/bench_compare.py" --title "rgba fair" \
    --impl "pion_icc=$B/pion_icc rgba $D/display_p3_v4.icc $D/frame_1080p.rgba $FR" \
    --impl "rust_qcms=$O rgba qcms $D/display_p3_v4.icc $D/frame_1080p.rgba $FR" \
    --impl "rust_qcms_pre=$O rgba qcms_pre $D/display_p3_v4.icc $D/frame_1080p.rgba $FR" \
    --impl "rust_moxcms=$O rgba moxcms $D/display_p3_v4.icc $D/frame_1080p.rgba $FR" \
    --baseline rust_qcms_pre --warmup 1 --rounds 5 --ops $((2073600 * FR)) --json-out "$AUDIT_OUT/fair_b.json" > "$AUDIT_OUT/fair_b.log" 2>&1 ||
    { tail -5 "$AUDIT_OUT/fair_b.log"; fail "fairness B bench"; return; }
  python3 -I - "$AUDIT_OUT/fair_b.json" > "$AUDIT_OUT/fair_b.speedup" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
r = {x["name"]: x for x in d["results"]}
p = r["pion_icc"]
for k in ("pion_icc", "rust_qcms", "rust_qcms_pre", "rust_moxcms"):
    sys.stderr.write("  %-14s %8.1f ms  %6.2f ns/px  RSS %6.1f MiB\n" % (k, r[k]["median_ms"], r[k]["ns_per_op"], r[k]["peak_rss_bytes"] / 1048576.0))
print("%.2f" % (r["rust_qcms"]["median_ms"] / p["median_ms"]), "%.2f" % (r["rust_qcms_pre"]["median_ms"] / p["median_ms"]))
PY

  sb=$(cat "$AUDIT_OUT/fair_b.speedup")
  echo "  pion vs qcms (as shipped) / vs qcms_pre: $sb"
  s2=$(echo "$sb" | awk '{print $2}')
  python3 -I -c "import sys; sys.exit(0 if float('${s2:-0}') >= 1.99 * 0.75 else 1)" ||
    open_finding "P1-2: README Scenario B 1.99x vs qcms is ${s2}x against qcms with its precached sRGB output"
  echo "==> bench integrity: does the SHA-256 gate see the colour work at all?"
  a=$("$B/pion_icc" rgba "$D/display_p3_v4.icc" "$D/frame_1080p.rgba" 2 | shasum -a 256 | cut -c1-16)
  b=$("$B/pion_icc" rgba "$C/diff/srgb_v4_para3.icc" "$D/frame_1080p.rgba" 2 | shasum -a 256 | cut -c1-16)
  c=$("$B/pion_icc" parse "$D/display_p3_v4.icc" 3 | shasum -a 256 | cut -c1-16)
  e=$("$B/pion_icc" parse "$C/diff/srgb_v4_para3.icc" 3 | shasum -a 256 | cut -c1-16)
  echo "  rgba stdout sha: Display-P3 $a, identity sRGB (no colour work) $b; parse stdout: P3 $c, sRGB $e"
  [ "$a" = "$b" ] && [ "$c" = "$e" ] && open_finding "P2-5: bench stdout (alpha of 2 px, probe (128,128,128)) is identical with and without any colour transform: the SHA gate checks nothing"
  echo "  no-DCE check: pion rgba wall time scales with frames:"
  for fr in 5 25; do
    s=$(python3 -I -c 'import subprocess,sys,time; t=time.monotonic(); subprocess.run(sys.argv[1:],stdout=subprocess.DEVNULL); print("%.0f" % ((time.monotonic()-t)*1000))' "$B/pion_icc" rgba "$D/display_p3_v4.icc" "$D/frame_1080p.rgba" $fr)
    echo "    $fr frames: $s ms"
  done
}

clean_check() {
  d=$(git -C "$ROOT_DIR" status --porcelain --ignored -- packages/icc | grep -v '^?? packages/icc/audit/$')
  [ -z "$d" ] || { echo "$d"; fail "worktree not clean after audit"; }
}

case "$SECTION" in
  build) build ;;
  cases) cases ;;
  unit) unit ;;
  diff) diff_corpus ;;
  adv) adv ;;
  trunc) trunc ;;
  fuzz) fuzz ;;
  dos) dos ;;
  portability) portability ;;
  smoke) smoke ;;
  bench) bench ;;
  all)
    build
    cases
    unit
    diff_corpus
    adv
    trunc
    fuzz
    dos
    portability
    smoke
    bench
    ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
clean_check
if [ -n "$OPEN" ]; then
  echo "==> open findings (REPORT.md):$OPEN" | awk '!seen[$0]++'
  [ "$STRICT" = 1 ] && RC=1
fi
if [ "$RC" = 0 ]; then echo "AUDIT PASS (0 P0)"; else echo "AUDIT FAIL"; fi
exit $RC
