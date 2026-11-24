#!/bin/sh
# One-shot red-team audit for packages/css_color (see REPORT.md).
#   sh packages/css_color/audit/run_audit.sh [all|build|cases|unit|determinism|oracles|gamut|dos|api|portability|smoke|bench|harness|docs]
# (single sections need a previous `build`; `harness` and `docs` also need `oracles`)
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), cargo (Rust color =0.3.3 oracle, --locked; uses the crate cache
# when offline), python3 (stdlib only). Headless Chrome is only needed with REFRESH_CHROME=1 (regenerates the
# committed golden diff/chrome/*.txt); every other run compares against the golden files.
# Artifacts go to $AUDIT_OUT (default /private/tmp/pion-css-color-audit: the real path of /tmp on macOS, because the
# wasm32 runner resolves symlinks). Nothing is written inside the repository.
# README.md numbers (wasm_smoke SHA-256 and sizes, differential case counts, benchmark medians) are parsed from
# README.md at run time (diff/readme.py): nothing about them is hard-coded here.
#
# Exit status: 1 while any P0 condition reproduces (crash / trap / timeout on any input, a native-vs-wasm32 or
# debug-vs-release divergence, an unexplained divergence from WPT / Chrome / the Rust oracle / spec_ref, software
# math error > 1e-9, a failing control case, a DoS budget breach, a gamut-mapping invariant violation, a wasm_smoke
# hash that differs from README.md, a benchmark whose outputs are not byte-identical, or a gate that misses an
# injected bug). Open P1/P2 findings are listed as OPEN and fail the run only with STRICT=1.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-css-color-audit}
if [ ! -d /private/tmp ] && [ "$AUDIT_OUT" = /private/tmp/pion-css-color-audit ]; then AUDIT_OUT=/tmp/pion-css-color-audit; fi
BIN="$AUDIT_OUT/bin"
C="$AUDIT_OUT/corpus"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
STRICT=${STRICT:-0}
FUZZ_N=${FUZZ_N:-10000}
README="$PKG_DIR/README.md"
PY="python3 -I"
CMP="$PY $AUDIT_DIR/diff/compare.py"
CASE_GROUPS="named hex syntax none mix relative numeric fuzz wpt"
FIX_IDS="P1-1 P2-8 P1-2 P2-7 P2-11 P2-12 P2-9 P2-2 ORACLE-wpt-rec2020"
CHROME_BIN=${CHROME_BIN:-$HOME/Library/Caches/ms-playwright/chromium_headless_shell-1255/chrome-headless-shell-mac-arm64/chrome-headless-shell}
mkdir -p "$BIN"
export PYTHONDONTWRITEBYTECODE=1
RC=0
OPEN=""
fail() { echo "  FAIL (P0): $*"; RC=1; }
open_finding() { echo "  OPEN: $*"; OPEN="$OPEN
  - $*"; }
# compare.py exit status: 0 clean, 3 known findings only, 1 unexplained; its last line lists the finding ids
cmp_run() {
  out=$("$@" 2>&1)
  r=$?
  printf '%s\n' "$out" | grep -v '^FINDINGS' | cut -c1-260
  for f in $(printf '%s\n' "$out" | grep '^FINDINGS' | cut -d' ' -f2-); do echo "$f" >> "$AUDIT_OUT/found.txt"; done
  return $r
}

runner() {
  case "$1" in
    native_dbg) echo "$BIN/css_color_audit_dbg" ;;
    native_rel) echo "$BIN/css_color_audit_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/css_color_audit_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/css_color_audit_rel.wasm" ;;
  esac
}
MODES="native_dbg native_rel wasm_dbg wasm_rel"

stages() {  # FIX_STAGES value for group $1
  k=1
  s=""
  for id in $FIX_IDS; do
    s="$s$id=$AUDIT_OUT/fix${k}_$1.txt,"
    k=$((k + 1))
  done
  echo "$s"
}

build() {
  echo "==> build: css_color_audit in 4 modes, color =0.3.3 oracle (cargo --locked), corpus, fix model"
  pionc fmt --check "$AUDIT_DIR" > /dev/null || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  pionc build -o "$BIN/css_color_audit_dbg" "$AUDIT_DIR" > /dev/null || fail "build native_dbg"
  pionc build --release -o "$BIN/css_color_audit_rel" "$AUDIT_DIR" > /dev/null || fail "build native_rel"
  pionc build --target wasm32 -o "$BIN/css_color_audit_dbg.wasm" "$AUDIT_DIR" > /dev/null || fail "build wasm_dbg"
  pionc build --release --target wasm32 -o "$BIN/css_color_audit_rel.wasm" "$AUDIT_DIR" > /dev/null || fail "build wasm_rel"
  M="$AUDIT_DIR/diff/oracle/Cargo.toml"
  { CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline --manifest-path "$M" 2> /dev/null ||
    CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --manifest-path "$M"; } || fail "cargo build oracle"
  cp "$AUDIT_OUT/rust-target/release/css_color_audit_oracle" "$BIN/oracle"
  rm -rf "$C" && $PY "$AUDIT_DIR/diff/gen.py" "$C" "$FUZZ_N" | tr '\n' ' ' | sed 's/^/  corpus: /'
  echo
  # WPT css-color parsing vectors (pinned commit, diff/wpt/PINNED) -> one case per specified value
  $PY - "$AUDIT_DIR/diff/wpt/vectors.tsv" "$C/wpt.cases" <<'PY'
import sys
def unesc(s): return s.replace("\\t", "\t").replace("\\n", "\n").replace("\\\\", "\\")
def enc(s):
    b = s.encode("utf-8", "surrogateescape")
    return s if all(0x20 <= x < 0x7F for x in b) else "hex:" + b.hex()
with open(sys.argv[2], "w") as f:
    for line in open(sys.argv[1], encoding="utf-8"):
        f.write("srgb\t" + enc(unesc(line.rstrip("\n").split("\t")[2])) + "\n")
PY
  # fix model (attribution only): on an already-fixed tree a patch whose snippet is gone is skipped, and a stage
  # that no longer builds is replaced by the previous stage; neither is a P0
  rm -rf "$AUDIT_OUT/fixmodel" && $PY "$AUDIT_DIR/diff/fixmodel.py" "$PKG_DIR" "$AUDIT_OUT/fixmodel" --build "$BIN" "$BIN/css_color_audit_rel" > "$AUDIT_OUT/fixmodel.txt" || fail "fixmodel"
  echo "  fix model stages (patches applied / build): $(awk '{printf "%s %s%s  ", $2, $3, ($4 == "build=reverted" ? " reverted" : "")}' "$AUDIT_OUT/fixmodel.txt")"
  if [ "${REFRESH_CHROME:-0}" = 1 ]; then
    for g in $CASE_GROUPS; do
      $PY "$AUDIT_DIR/diff/chrome.py" "$C/$g.cases" "$AUDIT_DIR/diff/chrome/$g.txt" "$CHROME_BIN" | sed "s/^/  $g /"
      shasum -a 256 "$C/$g.cases" | awk '{print $1}' > "$AUDIT_DIR/diff/chrome/$g.sha256"
    done
  fi
  for g in $CASE_GROUPS; do
    [ "$(shasum -a 256 "$C/$g.cases" | awk '{print $1}')" = "$(cat "$AUDIT_DIR/diff/chrome/$g.sha256")" ] ||
      fail "corpus $g differs from the one the Chrome golden was recorded for (REFRESH_CHROME=1)"
  done
  echo "  $(pionc --version) | node $(node --version) | $(cargo --version) | color =0.3.3 | golden: $(head -1 "$AUDIT_DIR/diff/chrome/VERSION")"
}

cases() {
  echo "==> cases: red-team + control cases, one process per case, in all 4 modes"
  names=$("$BIN/css_color_audit_rel" list)
  for m in $MODES; do
    : > "$AUDIT_OUT/cases_$m.txt"
    for c in $names; do
      # shellcheck disable=SC2046
      raw=$($(runner $m) case "$c" 2>&1)
      out=$(printf '%s\n' "$raw" | grep -E '^(PASS|FAIL) ' | tail -1)
      [ -n "$out" ] || out="FAIL $c :: ABORT ($(printf '%s\n' "$raw" | grep -m1 'pion panic' || printf '%s\n' "$raw" | tail -1))"
      echo "$out" >> "$AUDIT_OUT/cases_$m.txt"
    done
    echo "  $m: $(grep -c '^PASS' "$AUDIT_OUT/cases_$m.txt")/$(echo "$names" | wc -w | tr -d ' ') pass"
  done
  sed 's/^/    /' "$AUDIT_OUT/cases_native_rel.txt" | cut -c1-240
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
  echo "==> unit: pionc fmt/check/test of packages/css_color, pionc test of audit (control_* must pass)"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/css_color"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/css_color"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> /dev/null
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit_audit.json" 2> "$AUDIT_OUT/unit_audit.stderr"
  $PY - "$AUDIT_OUT/unit_pkg.json" "$AUDIT_OUT/unit_audit.json" <<'PY' || fail "unit tests"
import json, sys
pkg = json.load(open(sys.argv[1]))
print("  packages/css_color own tests: %d/%d pass" % (pkg["passed"], pkg["total"]))
bad = pkg["failed"]
d = json.load(open(sys.argv[2]))
n = {"PASS": 0, "OPEN": 0, "FAIL": 0}
for t in d["tests"]:
    if t["pkg"] != "css_color_audit":
        continue
    k = "PASS" if t["ok"] else ("OPEN" if t["name"].startswith("redteam_") else "FAIL")
    n[k] += 1
    if k == "FAIL":
        print("  FAIL  %s" % t["name"])
        bad += 1
print("  audit tests under pionc test: %d pass, %d red-team open, %d control failing" % (n["PASS"], n["OPEN"], n["FAIL"]))
sys.exit(1 if bad else 0)
PY
}

determinism() {
  echo "==> determinism: every corpus (+ gamut, DoS bombs, API sweep) in all 4 modes must be byte-identical"
  $PY "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos" --list-only > /dev/null
  for g in $CASE_GROUPS gamut dos; do
    f="$C/$g.cases"
    [ "$g" = dos ] && f="$AUDIT_OUT/dos/dos.cases"
    for m in $MODES; do
      # shellcheck disable=SC2046
      $(runner $m) run "$f" > "$AUDIT_OUT/pion_${g}_$m.txt" 2> "$AUDIT_OUT/pion_${g}_$m.err" || fail "$g: $m exited non-zero ($(tail -1 "$AUDIT_OUT/pion_${g}_$m.err"))"
    done
    for m in native_dbg wasm_dbg wasm_rel; do
      $CMP same "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_${g}_$m.txt" || fail "$g: $m differs from native_rel"
    done
    cp "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_$g.txt"
    echo "  [$g] $(wc -l < "$f" | tr -d ' ') inputs, $(grep -c '^OK' "$AUDIT_OUT/pion_$g.txt") accepted, 4 modes byte-identical"
  done
  for m in $MODES; do
    # shellcheck disable=SC2046
    $(runner $m) gamut "$C/gamut.cases" > "$AUDIT_OUT/gamut_$m.txt" || fail "gamut: $m exited non-zero"
    # shellcheck disable=SC2046
    $(runner $m) api > "$AUDIT_OUT/api_$m.txt" || fail "api: $m exited non-zero"
  done
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/gamut_native_rel.txt" "$AUDIT_OUT/gamut_$m.txt" || fail "to_gamut: $m differs from native_rel"
    cmp -s "$AUDIT_OUT/api_native_rel.txt" "$AUDIT_OUT/api_$m.txt" || fail "API sweep: $m differs from native_rel"
  done
  echo "  [to_gamut] $(wc -l < "$C/gamut.cases" | tr -d ' ') mappings x 8 destinations mix, 4 modes byte-identical"
  echo "  [api] $(cat "$AUDIT_OUT/api_native_rel.txt"), 4 modes identical"
}

oracles() {
  echo "==> oracles: WPT vectors, headless Chrome golden, Rust color =0.3.3, float64 spec_ref (fix model attributes divergences)"
  : > "$AUDIT_OUT/found.txt"
  for g in $CASE_GROUPS; do
    k=1
    for id in $FIX_IDS; do
      "$BIN/fix$k" run "$C/$g.cases" > "$AUDIT_OUT/fix${k}_$g.txt" || fail "fix model stage $k crashed on $g"
      k=$((k + 1))
    done
  done
  echo "  -- WPT css/css-color/parsing @ $(head -1 "$AUDIT_DIR/diff/wpt/PINNED")"
  FIX_BASE="$AUDIT_OUT/pion_wpt.txt" FIX_STAGES=$(stages wpt) cmp_run $CMP wpt "$AUDIT_DIR/diff/wpt/vectors.tsv" "$AUDIT_OUT/pion_wpt.txt"
  [ $? = 1 ] && fail "unexplained divergence from the WPT vectors"
  cmp_run $CMP chromewpt "$AUDIT_DIR/diff/wpt/vectors.tsv" "$AUDIT_DIR/diff/chrome/wpt.txt"
  for g in $CASE_GROUPS; do
    [ "$g" = wpt ] && continue
    echo "  -- headless Chrome golden: $g"
    FIX_BASE="$AUDIT_OUT/pion_$g.txt" FIX_STAGES=$(stages $g) cmp_run $CMP chrome "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" "$AUDIT_DIR/diff/chrome/$g.txt"
    [ $? = 1 ] && fail "unexplained divergence from Chrome on $g"
  done
  echo "  -- Rust color =0.3.3 (f32; parse + convert to every space must agree to 2e-4 of the range)"
  for g in named hex numeric; do
    "$BIN/oracle" run "$C/$g.cases" > "$AUDIT_OUT/rust_$g.txt" || fail "oracle crashed on $g"
    cmp_run $CMP rust "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" "$AUDIT_OUT/rust_$g.txt" || fail "numeric divergence from color 0.3.3 on $g"
  done
  "$BIN/oracle" mix "$C/mix.rust" > "$AUDIT_OUT/rust_mixp.txt" || fail "oracle crashed on mix"
  cmp_run $CMP mixrust "$AUDIT_OUT/pion_mix.txt" "$AUDIT_OUT/rust_mixp.txt"
  echo "     (information: color 0.3.3 has no none-alpha carry, no ED powerless rules; see REPORT.md)"
  echo "  -- float64 spec_ref.py (ED sample code; matrices derived from the chromaticities)"
  echo "     software math gate (<= 1e-9 of the range): tried with the ED's constants first, then with the pre-2023"
  echo "     Bradford / ProPhoto constants (alone or both); passing only with old constants = P2-2, not P0:"
  for g in numeric none mix relative syntax; do
    cmp_run $CMP spec "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" auto > "$AUDIT_OUT/spec_$g.txt"
    r=$?
    grep -E 'software|guard|> 1e-9' "$AUDIT_OUT/spec_$g.txt" | sed "s/^ */       [$g] /"
    [ $r = 1 ] && fail "software math error > 1e-9 ($g)"
  done
  echo "     with the ED's current constants (information):"
  $CMP spec "$C/numeric.cases" "$AUDIT_OUT/pion_numeric.txt" ed | grep -v '^FINDINGS' | sed 's/^/  /'
  echo "  -- to_css() round trip"
  for g in numeric syntax relative mix wpt; do
    cmp_run $CMP roundtrip "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" | sed "s/^ */     [$g] /"
  done
  for id in $(sort -u "$AUDIT_OUT/found.txt" | grep -v ORACLE); do
    case "$id" in
      P1-1) open_finding "P1-1: HSL/HWB of near-white/black colors (no ED epsilon guard): saturation up to 849%" ;;
      P1-2) open_finding "P1-2: relative-color channel keywords drop none / powerless-missing" ;;
      P2-1) open_finding "P2-1: to_css() corrupts |v| >= 9.2e12, writes NaN/Inf as 0, out-of-range lab L not lossless" ;;
      P2-2) open_finding "P2-2: Bradford / ProPhoto constants differ from the CSS Color 4 ED (pre-2023 values)" ;;
      P2-3) open_finding "P2-3: hash / from token boundaries (#fffr accepted, from#f00 rejected)" ;;
      P2-4) open_finding "P2-4: calc() accepts invalid grammar and type mixes" ;;
      P2-5) open_finding "P2-5: valid calc() edge values / huge literals rejected" ;;
      P2-6) open_finding "P2-6: CSS Color 5 ED color-mix() forms and display-p3-linear rejected" ;;
      P2-7) open_finding "P2-7: analogous components x/y/z and analogous sets not carried" ;;
      P2-8) open_finding "P2-8: powerless-hue epsilons / origin normalisation differ from the ED" ;;
      P2-9) open_finding "P2-9: hsl() clamps S > 100% and L at parse time" ;;
      P2-11) open_finding "P2-11: color-mix() missing hue before fix-up, zero alpha components" ;;
      P2-12) open_finding "P2-12: hues >= 2^52 x 360 normalise to 0" ;;
      *) open_finding "$id: (oracle comparison)" ;;
    esac
  done
}

gamut() {
  echo "==> gamut: Color::to_gamut vs the ED binary search (spec_ref.gamut_map), invariants"
  cmp_run $PY "$AUDIT_DIR/diff/gamut.py" "$C/gamut.cases" "$AUDIT_OUT/pion_gamut.txt" "$AUDIT_OUT/gamut_native_rel.txt"
  r=$?
  [ $r = 1 ] && fail "gamut mapping invariant / unexplained divergence"
  [ $r = 3 ] && open_finding "P2-10: to_gamut early exit returns the in-gamut chroma instead of clipped (and skips ED step 11)"
}

dos() {
  echo "==> dos: nesting / tree / calc / number / length bombs, budgets in diff/dos.py (native_rel, then wasm_rel)"
  $PY "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos" "$BIN/css_color_audit_rel" | grep -v '^  prefix '
  r=$?
  [ $r = 1 ] && fail "DoS P0 budget"
  [ $r = 3 ] && open_finding "P1: DoS time budget"
  $PY "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos_wasm" "$BIN/css_color_audit_rel.wasm" node "$WASM_RT" "$BIN/css_color_audit_rel.wasm" > "$AUDIT_OUT/dos_wasm.log"
  r=$?
  echo "  wasm_rel: $(grep 'worst input' "$AUDIT_OUT/dos_wasm.log" | sed 's/^ *//')"
  [ $r = 1 ] && { grep 'P0' "$AUDIT_OUT/dos_wasm.log" | head -5; fail "DoS P0 budget (wasm_rel)"; }
}

api() {
  echo "==> api: extreme-value sweep of the public API (0, -0, 1e-12, 5e-324, 1e6, 1e300, NaN, +-Inf in every channel)"
  cat "$AUDIT_OUT/api_native_rel.txt" | sed 's/^/  /'
  grep -q 'moderate=0 ' "$AUDIT_OUT/api_native_rel.txt" || fail "non-finite coordinates from moderate (|v| <= 1e6) finite input"
}

portability() {
  echo "==> portability: packages/css_color/src: 0 extern \"C\", 0 World, 0 imports, 0 deps, 0 module-level mutable state"
  SRC=$(cat "$PKG_DIR"/src/*.pion | grep -v '^ *//')
  n=$(printf '%s\n' "$SRC" | grep -c 'extern "C"')
  echo "  extern \"C\": $n"; [ "$n" = 0 ] || fail "extern \"C\" in packages/css_color/src"
  n=$(printf '%s\n' "$SRC" | grep -cw 'World')
  echo "  World: $n"; [ "$n" = 0 ] || fail "World in packages/css_color/src"
  n=$(printf '%s\n' "$SRC" | grep -c '^import ')
  echo "  imports: $n"; [ "$n" = 0 ] || fail "imports in packages/css_color/src"
  deps=$(sed -n '/^\[dependencies\]/,/^\[/p' "$PKG_DIR/pion.toml" | grep -vc '^\[\|^ *$\|^#')
  echo "  pion.toml [dependencies] entries: $deps"; [ "$deps" = 0 ] || fail "external dependencies"
  n=$(printf '%s\n' "$SRC" | grep -cE '^(pub )?let mut ')
  echo "  module-level let mut: $n"; [ "$n" = 0 ] || fail "module-level let mut"
  m=$(grep -nE '^(pub )?let [a-zA-Z_0-9]+ *: *(Array|Bytes|Map|FixedArray|StringBuilder|Ref)' "$PKG_DIR"/src/*.pion | sed "s|$PKG_DIR/||")
  echo "  module-level lets: $(printf '%s\n' "$SRC" | grep -cE '^(pub )?let ') (all scalar: $(printf '%s\n' "$SRC" | grep -E '^(pub )?let ' | sed -E 's/^(pub )?let ([a-z0-9_]+) : ([A-Za-z]+).*/\2:\3/' | tr '\n' ' '))"
  [ -z "$m" ] || { printf '%s\n' "$m"; fail "module-level mutable container"; }
  echo "  Send probe: public values crossing a spawn boundary"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\ncss_color = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  for v in "css_color::parse(\"red\")" "css_color::Color::srgb(1.0, 0.0, 0.0, 1.0)" "css_color::ColorSpace::Oklch" "css_color::HueInterpolation::Longer"; do
    printf 'import "css_color"\n\n///|\npub fn main(world : World) -> Int {\n  let v = %s\n  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })\n  0\n}\n' "$v" > "$P/src/main.pion"
    r=$(pionc check --json "$P" 2>&1 | $PY -c 'import json,sys; d=json.load(sys.stdin); print("Send" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))')
    printf '    %-52s %s\n' "$v" "$r"
    [ "$r" = Send ] || fail "$v is not Send"
  done
}

smoke() {
  echo "==> smoke: packages/css_color/wasm_smoke in 4 modes vs README.md (values parsed from README.md)"
  want=$($PY "$AUDIT_DIR/diff/readme.py" "$README" smoke_sha)
  want_line=$($PY "$AUDIT_DIR/diff/readme.py" "$README" smoke_line)
  : > "$AUDIT_OUT/smoke.txt"
  for flags in "" "--release" "--target wasm32" "--release --target wasm32"; do
    # shellcheck disable=SC2086
    out=$(pionc run $flags "$PKG_DIR/wasm_smoke" 2>&1 | tail -1)
    h=$(printf '%s\n' "$out" | shasum -a 256 | awk '{print $1}')
    echo "  [${flags:-native debug}] $out  sha256=$h"
    echo "$h" >> "$AUDIT_OUT/smoke.txt"
    [ "$out" = "$want_line" ] || fail "wasm_smoke output differs from README.md ($want_line)"
  done
  [ "$(sort -u "$AUDIT_OUT/smoke.txt" | wc -l | tr -d ' ')" = 1 ] || fail "wasm_smoke output differs between modes"
  [ "$(head -1 "$AUDIT_OUT/smoke.txt")" = "$want" ] || fail "wasm_smoke sha256 differs from README.md ($want)"
  echo "  README.md sha256: $want"
  D="$AUDIT_OUT/smoke_bin" && mkdir -p "$D"
  pionc build --target wasm32 -o "$D/w_dbg.wasm" "$PKG_DIR/wasm_smoke" > /dev/null && pionc build --release --target wasm32 -o "$D/w_rel.wasm" "$PKG_DIR/wasm_smoke" > /dev/null
  got="$(wc -c < "$D/w_dbg.wasm" | tr -d ' ') $(wc -c < "$D/w_rel.wasm" | tr -d ' ')"
  claim=$($PY "$AUDIT_DIR/diff/readme.py" "$README" wasm_sizes)
  echo "$got" > "$AUDIT_OUT/smoke_sizes.txt"
  echo "  wasm32 bytes (debug release): measured $got, README $claim"
}

bench() {
  echo "==> bench: packages/css_color/bench/run_bench.sh as shipped (stdout SHA-256 identical, warmup >= 1, rounds >= 5)"
  sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || { tail -20 "$AUDIT_OUT/bench.log"; fail "run_bench.sh"; return; }
  grep -E '^\| `|SHA-256|Differential Oracle Summary|Parse \+ Space|color-mix\(\) \(|Gamut Mapping' "$AUDIT_OUT/bench.log" | sed 's/^/  /' | cut -c1-200
  $PY - /tmp/pion-css-color-bench "$README" "$AUDIT_DIR/diff/readme.py" > "$AUDIT_OUT/bench_check.txt" <<'PY'
import json, os, subprocess, sys
d, readme, rp = sys.argv[1], sys.argv[2], sys.argv[3]
ok, drift = True, []
for sc, f in (("A", "bench_parse.json"), ("B", "bench_convert.json")):
    j = json.load(open(os.path.join(d, f)))
    r = {x["name"]: x for x in j["results"]}
    good = bool(j.get("sha256")) and j["rounds"] >= 5 and j["warmup"] >= 1
    ok &= good
    pm, rm, ps = (float(x) for x in subprocess.run(["python3", "-I", rp, readme, "bench", sc], capture_output=True,
                                                     text=True).stdout.split())
    got = r["pion_css_color"]["speedup_vs_baseline"]
    print("  scenario %s: sha256 %s; pion %.1f ms (README %.1f), color %.1f ms (README %.1f), speedup %.2fx (README %.2fx)" % (
        sc, j.get("sha256", "?")[:16], r["pion_css_color"]["median_ms"], pm, r["rust_color"]["median_ms"], rm, got, ps))
    if abs(got - ps) > 0.35 * ps:
        drift.append("scenario %s speedup %.2fx vs README %.2fx" % (sc, got, ps))
for x in drift:
    print("  DRIFT " + x)
sys.exit(0 if ok else 1)
PY
  r=$?
  cat "$AUDIT_OUT/bench_check.txt"
  [ $r = 0 ] || fail "shipped bench: output hash / protocol"
}

harness() {
  echo "==> harness: the gates must catch injected bugs (mutated copies in \$AUDIT_OUT)"
  injected=0
  for bug in named_typo hue_shorter depth_guard matrix_coeff legacy_mixing; do
    H="$AUDIT_OUT/inject_$bug" && rm -rf "$H" && mkdir -p "$H" && cp -R "$PKG_DIR" "$H/css_color"
    # each bug has alternatives so that it can still be injected into a fixed (rewritten) tree
    $PY - "$H/css_color/src" "$bug" <<'PY'
import os, re, sys
d, bug = sys.argv[1], sys.argv[2]
alts = {
    "named_typo": [("named.pion", r'"coral" => Some\(\(255, 127, 80, 255\)\)', '"coral" => Some((255, 127, 81, 255))')],
    "hue_shorter": [("mix.pion", r"      if diff > 180\.0 \{\n        h1 = h1 \+ 360\.0\n      \} else if diff < -180\.0 \{\n        h2 = h2 \+ 360\.0\n      \}",
                     "      if diff > 180.0 {\n        h2 = h2 + 360.0\n      } else if diff < -180.0 {\n        h1 = h1 + 360.0\n      }"),
                    ("parser.pion", r'"shorter" => HueInterpolation::Shorter', '"shorter" => HueInterpolation::Increasing')],
    "depth_guard": [("parser.pion", r"(fn parse_color_expr\(cur : Cursor, depth : Int\) -> Result\[Color, ColorError\] \{\n  if depth > max_nesting_depth) \{",
                     r"\1 * 1000 {"),
                    ("types.pion", r"pub let max_nesting_depth : Int = 32\b", "pub let max_nesting_depth : Int = 32000")],
    "matrix_coeff": [("space.pion", r"0\.41239079926595934\b", "0.41239179926595934")],
    "legacy_mixing": [("parser.pion", r"    if p0 != p1 \|\| p1 != p2 \{", "    if false {"),
                      ("parser.pion", r"if (\w+) != (\w+) \|\| (\w+) != (\w+) \{", "if false {")],
}[bug]
for p, pat, new in alts:
    path = os.path.join(d, p)
    s = open(path).read()
    out, n = re.subn(pat, new, s, count=1)
    if n:
        open(path, "w").write(out)
        sys.exit(0)
sys.exit(4)
PY
    if [ $? = 4 ]; then
      echo "  injected $bug: SKIP (no injection point left in this tree)"
      continue
    fi
    injected=$((injected + 1))
    pionc build --release -o "$H/ca" "$H/css_color/audit" > /dev/null || { fail "harness build ($bug)"; continue; }
    caught=""
    for g in named mix relative numeric wpt; do
      "$H/ca" run "$C/$g.cases" > "$H/$g.txt"
      if [ "$g" = wpt ]; then
        FIX_BASE="$AUDIT_OUT/pion_wpt.txt" FIX_STAGES=$(stages wpt) $CMP wpt "$AUDIT_DIR/diff/wpt/vectors.tsv" "$H/wpt.txt" > "$H/$g.log"
      else
        FIX_BASE="$AUDIT_OUT/pion_$g.txt" FIX_STAGES=$(stages $g) $CMP chrome "$C/$g.cases" "$H/$g.txt" "$AUDIT_DIR/diff/chrome/$g.txt" > "$H/$g.log"
      fi
      [ $? = 1 ] && caught="$caught $g"
    done
    $CMP spec "$C/numeric.cases" "$H/numeric.txt" auto > "$H/spec.log"
    [ $? = 1 ] && caught="$caught spec_ref"
    $PY "$AUDIT_DIR/diff/dos.py" "$H/dos" "$H/ca" > "$H/dos.log"
    [ $? = 1 ] && caught="$caught dos"
    r=$("$H/ca" case control_dos_guards)
    case "$r" in FAIL*) caught="$caught control_dos_guards" ;; esac
    if [ -z "$caught" ]; then
      fail "harness: injected $bug not caught by any gate"
    else
      echo "  injected $bug: caught by$caught"
    fi
  done
  [ "$injected" -ge 3 ] || fail "harness: only $injected of 5 bugs could be injected (need >= 3)"
}

docs() {
  echo "==> docs: README.md claims vs measurements (values parsed from README.md), AGENTS.md 1.1 test port"
  why=""
  spec_open=$(sort -u "$AUDIT_OUT/found.txt" 2> /dev/null | grep -v ORACLE | tr '\n' ' ')
  n=$($PY -c 'import json,sys; print(json.load(open(sys.argv[1]))["total"])' "$AUDIT_OUT/unit_pkg.json" 2> /dev/null || echo 0)
  w=$(wc -l < "$AUDIT_DIR/diff/wpt/vectors.tsv" | tr -d ' ')
  if grep -rlq --exclude-dir=audit 'css/css-color/parsing' "$PKG_DIR"; then
    echo "  WPT css-color parsing vectors are referenced by the package's own tests"
  else
    echo "  packages/css_color unit tests: $n test blocks; the pinned WPT css-color parsing suite ($w vectors) is not ported"
    why="$why wpt-not-ported"
  fi
  if grep -q 'Complete W3C CSS Color' "$README" && [ -n "$spec_open" ]; then
    echo "  README \"Complete W3C CSS Color 4 & 5\" while spec findings are open: $spec_open"
    why="$why complete-claim"
  fi
  if grep -q 'exact Bradford' "$README" && printf '%s' "$spec_open" | grep -q 'P2-2'; then
    echo "  README \"exact §18 matrices, exact Bradford\": ProPhoto / Bradford are pre-2023 ED values (P2-2)"
    why="$why exact-matrices-claim"
  fi
  claim=$($PY "$AUDIT_DIR/diff/readme.py" "$README" diff_counts 2> /dev/null)
  got=$(grep -o 'Differential Oracle Summary ([0-9]* total' "$AUDIT_OUT/bench.log" 2> /dev/null | grep -o '[0-9]*' | head -1)
  echo "  README differential cases: ${claim:-none} (total parse mix gamut); shipped diff_oracle.py measured total: ${got:-?}"
  [ -n "$got" ] && [ -n "$claim" ] && [ "$got" != "$(echo "$claim" | awk '{print $1}')" ] && why="$why diff-count"
  if [ -n "$claim" ] && ! grep -qiE 'curated|only inputs' "$README"; then
    echo "  the differential table does not say its corpus is curated (only inputs color 0.3.3 accepts: no rejection"
    echo "  tests, no none, no relative colors, no calc, 7 grey aliases removed; \"160/160\" checks only in-gamut)"
    why="$why curated-diff"
  fi
  if [ -f "$AUDIT_OUT/smoke_sizes.txt" ]; then
    got=$(cat "$AUDIT_OUT/smoke_sizes.txt")
    claim=$($PY "$AUDIT_DIR/diff/readme.py" "$README" wasm_sizes)
    # the binaries embed absolute source paths (toolchain), so sizes move with the checkout path: allow 0.2 %
    $PY -c 'import sys; a=[int(x) for x in sys.argv[1].split()]; b=[int(x) for x in sys.argv[2].split()]; sys.exit(0 if all(abs(x-y) <= 0.002*y for x, y in zip(a, b)) else 1)' "$got" "$claim" ||
      { echo "  README wasm32 sizes $claim B, measured $got B"; why="$why sizes"; }
    echo "  wasm32 sizes: README $claim B, measured $got B (binaries embed absolute source paths: path-dependent)"
  fi
  grep -q DRIFT "$AUDIT_OUT/bench_check.txt" 2> /dev/null && { grep DRIFT "$AUDIT_OUT/bench_check.txt" | sed 's/^ */  README /'; why="$why bench-drift"; }
  [ -n "$why" ] && open_finding "P2-13: README / process claims not backed:$why"
}

clean_check() {
  d=$(git -C "$ROOT_DIR" status --porcelain --ignored -- packages/css_color | grep -v '^?? packages/css_color/audit/$')
  [ -z "$d" ] || { echo "$d"; fail "worktree not clean after audit"; }
}

case "$SECTION" in
  build) build ;;
  cases) cases ;;
  unit) unit ;;
  determinism) determinism ;;
  oracles) oracles ;;
  gamut) gamut ;;
  dos) dos ;;
  api) api ;;
  portability) portability ;;
  smoke) smoke ;;
  bench) bench ;;
  harness) harness ;;
  docs) docs ;;
  all)
    build
    cases
    unit
    determinism
    oracles
    gamut
    dos
    api
    portability
    smoke
    bench
    harness
    docs
    ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
clean_check
if [ -n "$OPEN" ]; then
  echo "==> open non-P0 findings (REPORT.md):$OPEN" | awk '!seen[$0]++'
  [ "$STRICT" = 1 ] && RC=1
fi
if [ "$RC" = 0 ]; then echo "AUDIT PASS (0 P0)"; else echo "AUDIT FAIL"; fi
exit $RC
