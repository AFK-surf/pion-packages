#!/bin/sh
# One-shot red-team audit for packages/opentype (see REPORT.md).
#   sh packages/opentype/audit/run_audit.sh [all|build|cases|unit|diff|system|fuzz|dos|portability|smoke|bench|harness|docs]
# (single sections need a previous `build`; `harness` also needs `diff`; `docs` reads `unit`/`smoke` results)
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), cargo (oracles: ttf-parser 0.25.1 + skrifa 0.44.0, locked;
# uses the crate cache when offline), python3 (stdlib only). Optional: system fonts (macOS /System/Library/Fonts,
# Linux /usr/share/fonts) are read in place, never copied into the repository.
# Artifacts go to $AUDIT_OUT (default /private/tmp/pion-opentype-audit: the real path of /tmp on macOS, because
# the wasm32 runner resolves symlinks). Nothing is written inside the repository.
#
# Exit status: 1 while any P0 condition reproduces (crash / trap / hang on any input, an unexplained divergence
# from both oracles, a native-vs-wasm32 or debug-vs-release divergence, a failing control case, a DoS hard-limit
# breach, a wasm_smoke hash mismatch with README.md, bench stdout not byte-identical, or an applicable injected
# bug the gates do not catch). Open P1/P2 findings are listed as OPEN and fail the run only with STRICT=1.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-opentype-audit}
if [ ! -d /private/tmp ] && [ "$AUDIT_OUT" = /private/tmp/pion-opentype-audit ]; then AUDIT_OUT=/tmp/pion-opentype-audit; fi
BIN="$AUDIT_OUT/bin"
C="$AUDIT_OUT/corpus"
D="$AUDIT_OUT/d"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
STRICT=${STRICT:-0}
FUZZ_N=${FUZZ_N:-20000}        # file-based mutation corpus (synthetic seeds)
FUZZ_MUT=${FUZZ_MUT:-400}      # in-memory mutations per system-font seed
SYSTEM_N=${SYSTEM_N:-0}        # 0 = every system font face found (cap 3 faces per collection)
SYSTEM_4MODE=${SYSTEM_4MODE:-12}
ORACLE="$BIN/oracle"
CMP="python3 -I $AUDIT_DIR/diff/compare.py"
TAB=$(printf '\t')
mkdir -p "$BIN" "$D"
export PYTHONDONTWRITEBYTECODE=1
RC=0
OPEN=""
fail() { echo "  FAIL (P0): $*"; RC=1; }
open_finding() { echo "  OPEN: $*"; OPEN="$OPEN
  - $*"; }
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }

runner() {
  case "$1" in
    native_dbg) echo "$BIN/oa_dbg" ;;
    native_rel) echo "$BIN/oa_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/oa_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/oa_rel.wasm" ;;
  esac
}
MODES="native_dbg native_rel wasm_dbg wasm_rel"

build() {
  echo "==> build: opentype_audit in 4 modes, oracles (ttf-parser 0.25.1 + skrifa 0.44.0, cargo --locked), corpus"
  pionc fmt --check "$AUDIT_DIR" > /dev/null || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  pionc build -o "$BIN/oa_dbg" "$AUDIT_DIR" > /dev/null || fail "build native_dbg"
  pionc build --release -o "$BIN/oa_rel" "$AUDIT_DIR" > /dev/null || fail "build native_rel"
  pionc build --target wasm32 -o "$BIN/oa_dbg.wasm" "$AUDIT_DIR" > /dev/null || fail "build wasm_dbg"
  pionc build --release --target wasm32 -o "$BIN/oa_rel.wasm" "$AUDIT_DIR" > /dev/null || fail "build wasm_rel"
  M="$AUDIT_DIR/diff/oracle/Cargo.toml"
  { CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline --manifest-path "$M" 2> /dev/null ||
    CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --manifest-path "$M"; } || fail "cargo build oracle"
  cp "$AUDIT_OUT/rust-target/release/opentype_audit_oracle" "$ORACLE"
  rm -rf "$C" && python3 -I "$AUDIT_DIR/diff/gen.py" "$C" "$FUZZ_N" | sed 's/^/  corpus: /'
  echo "  $(pionc --version) | node $(node --version) | $(cargo --version) | ttf-parser 0.25.1 | skrifa 0.44.0"
}

cases() {
  echo "==> cases: red-team + control cases, one process per case, in all 4 modes"
  names=$("$BIN/oa_rel" list)
  for m in $MODES; do
    : > "$AUDIT_OUT/cases_$m.txt"
    for c in $names; do
      # shellcheck disable=SC2046
      raw=$(limit 120 $(runner $m) case "$c" "$C" 2>&1)
      out=$(printf '%s\n' "$raw" | grep -E '^(PASS|FAIL) ' | tail -1)
      [ -n "$out" ] || out="FAIL $c :: ABORT ($(printf '%s\n' "$raw" | grep -m1 -i 'panic\|trap\|error' || printf '%s\n' "$raw" | tail -1))"
      echo "$out" >> "$AUDIT_OUT/cases_$m.txt"
    done
    echo "  $m: $(grep -c '^PASS' "$AUDIT_OUT/cases_$m.txt")/$(echo "$names" | wc -w | tr -d ' ') pass"
  done
  sed 's/^/    /' "$AUDIT_OUT/cases_native_rel.txt" | cut -c1-260
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/cases_native_rel.txt" "$AUDIT_OUT/cases_$m.txt" || { diff "$AUDIT_OUT/cases_native_rel.txt" "$AUDIT_OUT/cases_$m.txt" | head -6; fail "case results of $m differ from native_rel"; }
  done
  grep -q 'ABORT' "$AUDIT_OUT"/cases_*.txt && fail "a case aborted (panic / trap / hang)"
  grep -q '^FAIL control_' "$AUDIT_OUT/cases_native_rel.txt" && fail "control case failing"
  for f in $(grep '^FAIL redteam_' "$AUDIT_OUT/cases_native_rel.txt" | awk '{print $2}'); do
    open_finding "$(echo "$f" | sed -E 's/redteam_p([0-9])_([0-9]+)_.*/P\1-\2/'): case $f"
    case "$f" in redteam_p0_*) fail "P0 red-team case $f" ;; esac
  done
}

unit() {
  echo "==> unit: pionc fmt/check/test of packages/opentype (AGENTS.md 1.2)"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/opentype"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/opentype"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> /dev/null
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print("  packages/opentype own tests: %d/%d pass" % (d["passed"], d["total"])); sys.exit(1 if d["failed"] else 0)' "$AUDIT_OUT/unit_pkg.json" || fail "package unit tests"
}

diff_corpus() {
  echo "==> diff: $(wc -l < "$C/cases.tsv" | tr -d ' ') synthesized fonts: 4 modes byte-identical, pion vs ttf-parser 0.25.1 and skrifa 0.44.0"
  : > "$AUDIT_OUT/diff_verdicts.txt"
  bad=0
  while IFS="$TAB" read -r name pol font face q full note; do
    for m in $MODES; do
      # shellcheck disable=SC2046
      limit 120 $(runner $m) dump "$font" "$face" "$q" "$full" > "$D/$name.$m" 2> "$D/$name.$m.err" || { fail "$name: $m exited non-zero ($(tail -1 "$D/$name.$m.err"))"; }
    done
    for m in native_dbg wasm_dbg wasm_rel; do
      $CMP same "$D/$name.native_rel" "$D/$name.$m" || { fail "$name: $m output differs from native_rel"; bad=1; }
    done
    cp "$D/$name.native_rel" "$D/$name.pion"
    limit 60 "$ORACLE" ttf "$font" "$face" "$q" "$full" > "$D/$name.ttf" 2>&1
    limit 60 "$ORACLE" skrifa "$font" "$face" "$q" "$full" > "$D/$name.sk" 2>&1
    $CMP case "$name" "$pol" "$D/$name.pion" "$D/$name.ttf" "$D/$name.sk" "$BIN/oa_rel" "$ORACLE" "$font" "$face" >> "$AUDIT_OUT/diff_verdicts.txt" ||
      echo "$name" >> "$AUDIT_OUT/diff_unexplained.txt"
  done < "$C/cases.tsv"
  [ $bad = 0 ] && echo "  4 modes byte-identical on every synthesized font"
  grep -v 'quirk-' "$AUDIT_OUT/diff_verdicts.txt" | cut -c1-230
  n=$(grep -c 'UNEXPLAINED' "$AUDIT_OUT/diff_verdicts.txt")
  echo "  attributed divergences (finding ids): $(grep ' ATTR ' "$AUDIT_OUT/diff_verdicts.txt" | awk '{print $3}' | sort | uniq -c | tr -s ' ' | tr '\n' ',' | sed 's/,$//')"
  [ "$n" = 0 ] || fail "$n unexplained divergence lines on synthesized fonts"
}

system() {
  echo "==> system: read-only system font faces vs ttf-parser 0.25.1 and skrifa 0.44.0 (never copied)"
  [ -s "$C/system.tsv" ] || { echo "  no system fonts on this machine (skipped)"; return; }
  S="$AUDIT_OUT/sys" && rm -rf "$S" && mkdir -p "$S"
  if [ "$SYSTEM_N" = 0 ]; then cp "$C/system.tsv" "$S/list.tsv"; else head -n "$SYSTEM_N" "$C/system.tsv" > "$S/list.tsv"; fi
  i=0
  : > "$S/verdicts.txt"
  # queries ($q) are taken from each font by gen.py: its own kern pairs, UVS sequences, variation coordinates.
  # P2-2 is the only accepted divergence on real fonts, and only as an off-by-one F2Dot14 coordinate.
  while IFS="$TAB" read -r f face q; do
    i=$((i + 1))
    limit 300 "$BIN/oa_rel" dump "$f" "$face" "$q" 0 > "$S/$i.pion" 2>&1 || fail "native_rel exited non-zero on $f#$face"
    limit 300 "$ORACLE" ttf "$f" "$face" "$q" 0 > "$S/$i.ttf" 2>&1
    limit 300 "$ORACLE" skrifa "$f" "$face" "$q" 0 > "$S/$i.sk" 2>&1
    $CMP case "$(basename "$f")#$face" "P2-2:norm~1" "$S/$i.pion" "$S/$i.ttf" "$S/$i.sk" "$BIN/oa_rel" "$ORACLE" "$f" "$face" >> "$S/verdicts.txt" || :
  done < "$S/list.tsv"
  faces=$(wc -l < "$S/list.tsv" | tr -d ' ')
  glyphs=$(cat "$S"/*.pion | grep -c '^outl ')
  cps=$(cat "$S"/*.pion | grep -c '^cmap ')
  kq=$(cat "$S"/*.pion | grep -c '^kern '); uq=$(cat "$S"/*.pion | grep -c '^uvs '); nq=$(cat "$S"/*.pion | grep -c '^norm ')
  echo "  $faces faces, $cps mapped code points, $glyphs outlined glyphs, $kq kern pairs, $uq UVS sequences, $nq variation coordinates compared"
  p22=$(grep ' P2-2 ' "$S/verdicts.txt" | grep -o '[0-9][0-9]* lines' | awk '{n += $1} END {print n + 0}')
  [ "$p22" -gt 0 ] && echo "  P2-2 on real fonts: $p22 of $nq variation coordinates off by one F2Dot14 unit (skrifa = spec)"
  grep -v 'quirk-' "$S/verdicts.txt" | cut -c1-230 | head -40
  n=$(grep -c 'UNEXPLAINED' "$S/verdicts.txt")
  [ "$n" = 0 ] || fail "$n unexplained divergence lines on system fonts"
  # 4-mode determinism on a spread of real faces (debug wasm is slow on CJK collections: skip > 4 MiB)
  k=0
  while IFS="$TAB" read -r f face q; do
    [ "$(wc -c < "$f")" -gt 4194304 ] && continue
    k=$((k + 1)); [ $k -gt "$SYSTEM_4MODE" ] && break
    for m in native_dbg wasm_dbg wasm_rel; do
      # shellcheck disable=SC2046
      limit 600 $(runner $m) dump "$f" "$face" "$q" 0 > "$S/4m.$m" 2>&1
      j=$(grep -n "^$f$TAB$face$TAB" "$S/list.tsv" | head -1 | cut -d: -f1)
      cmp -s "$S/4m.$m" "$S/$j.pion" || fail "$m dump of $f#$face differs from native_rel"
    done
  done < "$S/list.tsv"
  echo "  4 modes byte-identical on $((k > SYSTEM_4MODE ? SYSTEM_4MODE : k)) real faces"
}

fuzz() {
  echo "==> fuzz: $FUZZ_N mutated fonts (files) + $FUZZ_MUT in-memory mutations of each system seed, 4 modes, no crash"
  for m in $MODES; do
    # shellcheck disable=SC2046
    limit 1800 $(runner $m) fuzz "$C/fuzz.txt" > "$AUDIT_OUT/fuzz_$m.txt" 2> "$AUDIT_OUT/fuzz_$m.err" || {
      last=$(tail -1 "$AUDIT_OUT/fuzz_$m.txt" | cut -d' ' -f1)
      fail "fuzz $m aborted after ${last:-<start>} ($(grep -m1 -i 'panic\|trap\|error' "$AUDIT_OUT/fuzz_$m.err"))"; }
  done
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/fuzz_native_rel.txt" "$AUDIT_OUT/fuzz_$m.txt" || fail "fuzz digests of $m differ from native_rel"
  done
  echo "  file corpus: $(wc -l < "$AUDIT_OUT/fuzz_native_rel.txt" | tr -d ' ') fonts, $(cut -d' ' -f2 "$AUDIT_OUT/fuzz_native_rel.txt" | sort -u | wc -l | tr -d ' ') distinct digests, 4 modes identical"
  seeds="/System/Library/Fonts/Supplemental/Courier New.ttf
/System/Library/Fonts/Supplemental/Georgia.ttf
/System/Library/Fonts/SFNS.ttf
/System/Library/Fonts/Helvetica.ttc
/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
  while read -r s; do
    [ -f "$s" ] || continue
    for m in native_rel wasm_rel; do
      # shellcheck disable=SC2046
      limit 1800 $(runner $m) fuzzmut "$s" "$FUZZ_MUT" 20261124 > "$AUDIT_OUT/fuzzmut_$m.txt" 2> "$AUDIT_OUT/fuzzmut_$m.err" ||
        fail "fuzzmut $m on $s aborted after iteration $(tail -1 "$AUDIT_OUT/fuzzmut_$m.txt" | cut -d' ' -f1)"
    done
    cmp -s "$AUDIT_OUT/fuzzmut_native_rel.txt" "$AUDIT_OUT/fuzzmut_wasm_rel.txt" || fail "fuzzmut native/wasm digests differ on $s"
    echo "  $(basename "$s"): $(wc -l < "$AUDIT_OUT/fuzzmut_native_rel.txt" | tr -d ' ') mutations, $(cut -d' ' -f2 "$AUDIT_OUT/fuzzmut_native_rel.txt" | sort -u | wc -l | tr -d ' ') distinct digests, native == wasm32"
  done <<EOF
$seeds
EOF
}

dos() {
  echo "==> dos: $(wc -l < "$C/bombs.tsv" | tr -d ' ') bombs (< 8 KiB; 3 size-amplification bombs < 1 MiB), native --release and wasm32 --release (budgets in diff/gen.py, hard limit 60 s)"
  python3 -I "$AUDIT_DIR/diff/dos.py" "$C/bombs.tsv" "$BIN/oa_rel" node "$WASM_RT" "$BIN/oa_rel.wasm" -- "$ORACLE" > "$AUDIT_OUT/dos.txt"
  r=$?
  grep -v '^OPEN-FINDING' "$AUDIT_OUT/dos.txt"
  [ $r = 1 ] && fail "DoS: crash / trap / hang / native-wasm divergence on a bomb"
  grep '^OPEN-FINDING' "$AUDIT_OUT/dos.txt" | awk '{print $2}' | sort -u > "$AUDIT_OUT/dos_ids.txt"
  while read -r id; do
    case "$id" in
      P2-9) open_finding "P2-9: cmap / UVS lookup cost grows with the number of encoding records ($(grep "^OPEN-FINDING P2-9" "$AUDIT_OUT/dos.txt" | cut -d' ' -f3- | tr '\n' ';' | sed 's/;$//'))" ;;
      P2-12) open_finding "P2-12: Face::parse is quadratic in the number of cmap encoding records ($(grep "^OPEN-FINDING P2-12" "$AUDIT_OUT/dos.txt" | cut -d' ' -f3- | tr '\n' ';' | sed 's/;$//'))" ;;
      *) open_finding "$id: DoS budget ($(grep "^OPEN-FINDING $id" "$AUDIT_OUT/dos.txt" | cut -d' ' -f3-))" ;;
    esac
  done < "$AUDIT_OUT/dos_ids.txt"
}

portability() {
  echo "==> portability: packages/opentype/src: license, 0 deps, 0 extern \"C\", 0 World, 0 mutable globals, 0 fonts"
  SRC=$(cat "$PKG_DIR"/src/*.pion | grep -v '^ *//')
  grep -q '^license = "MIT"' "$PKG_DIR/pion.toml" && echo "  pion.toml license = \"MIT\"" || fail "pion.toml has no license = \"MIT\""
  deps=$(sed -n '/^\[dependencies\]/,/^\[/p' "$PKG_DIR/pion.toml" | grep -vc '^\[\|^ *$\|^#')
  echo "  pion.toml [dependencies] entries: $deps"; [ "$deps" = 0 ] || fail "external dependencies"
  n=$(printf '%s\n' "$SRC" | grep -c 'extern "C"'); echo "  extern \"C\": $n"; [ "$n" = 0 ] || fail "extern \"C\" in src"
  n=$(printf '%s\n' "$SRC" | grep -cw 'World'); echo "  World: $n"; [ "$n" = 0 ] || fail "World in src"
  n=$(printf '%s\n' "$SRC" | grep -c '^import '); echo "  imports: $n"; [ "$n" = 0 ] || fail "imports in src"
  n=$(printf '%s\n' "$SRC" | grep -cE '^(pub )?let mut '); echo "  module-level let mut: $n"; [ "$n" = 0 ] || fail "module-level let mut"
  m=$(grep -nE '^(pub )?let [a-zA-Z_0-9]+ *: *(Array|Bytes|Map|FixedArray|StringBuilder|Ref)' "$PKG_DIR"/src/*.pion | sed "s|$PKG_DIR/||")
  [ -z "$m" ] && echo "  module-level mutable containers: 0 ($(printf '%s\n' "$SRC" | grep -cE '^(pub )?let [a-z_0-9]+ : Int ') immutable Int limits)" ||
    { printf '%s\n' "$m" | sed 's/^/    /'; fail "module-level mutable container"; }
  n=$(grep -n 'Double::to_string\|\.to_double()\.to_string()' "$PKG_DIR"/src/*.pion | grep -vc '_test.pion'); echo "  Double::to_string in src: $n"; [ "$n" = 0 ] || fail "Double::to_string in src"
  fonts=$(git -C "$ROOT_DIR" ls-files | grep -ciE '\.(ttf|otf|ttc|woff2?|dfont)$')
  echo "  font binaries tracked in the repository: $fonts"; [ "$fonts" = 0 ] || fail "font binaries committed"
  hosts=$(grep -nE 'mac-studio|tokyo-|pvg-office|afk-ap|Office-Host|\bgt[12]\b|/Users/' "$PKG_DIR/README.md" | head -3)
  [ -z "$hosts" ] && echo "  README.md internal host names / home paths: 0" || { echo "$hosts"; fail "internal host names in README.md"; }
  echo "  Send probe (information): which public values may cross a spawn boundary"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\nopentype = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  for v in "opentype::Face::parse(Bytes::new(0), 0)" "opentype::Tag::from_bytes(1, 2, 3, 4)" "opentype::OutlineBuilder::new()" \
    "opentype::fonts_in_collection(Bytes::new(0))"; do
    printf 'import "opentype"\n\n///|\npub fn main(world : World) -> Int {\n  let v = %s\n  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })\n  0\n}\n' "$v" > "$P/src/main.pion"
    r=$(pionc check --json "$P" 2>&1 | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("Send" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))')
    printf '    %-52s %s\n' "$v" "$r"
  done
}

smoke() {
  echo "==> smoke: packages/opentype/wasm_smoke in 4 modes vs README.md (values parsed from README.md)"
  want=$(python3 -I "$AUDIT_DIR/diff/claims.py" smoke-sha "$PKG_DIR/README.md")
  : > "$AUDIT_OUT/smoke.txt"
  for flags in "" "--release" "--target wasm32" "--release --target wasm32"; do
    # shellcheck disable=SC2086
    out=$(pionc run $flags "$PKG_DIR/wasm_smoke" 2>&1 | tail -1)
    h=$(printf '%s\n' "$out" | shasum -a 256 | awk '{print $1}')
    echo "  [${flags:-native debug}] $out  sha256=$h"
    echo "$h" >> "$AUDIT_OUT/smoke.txt"
  done
  [ "$(sort -u "$AUDIT_OUT/smoke.txt" | wc -l | tr -d ' ')" = 1 ] || fail "wasm_smoke output differs between modes"
  [ "$(head -1 "$AUDIT_OUT/smoke.txt")" = "$want" ] || fail "wasm_smoke sha256 differs from README.md ($want)"
  echo "  README.md sha256: $want"
  S="$AUDIT_OUT/smoke_bin" && mkdir -p "$S"
  pionc build --target wasm32 -o "$S/w_dbg.wasm" "$PKG_DIR/wasm_smoke" > /dev/null && pionc build --release --target wasm32 -o "$S/w_rel.wasm" "$PKG_DIR/wasm_smoke" > /dev/null
  set -- $(python3 -I "$AUDIT_DIR/diff/claims.py" sizes "$PKG_DIR/README.md")
  got_d=$(wc -c < "$S/w_dbg.wasm" | tr -d ' '); got_r=$(wc -c < "$S/w_rel.wasm" | tr -d ' ')
  echo "  wasm32 bytes debug / release: $got_d / $got_r   README: $1 / $2"
  python3 -I -c 'import sys; a=list(map(int,sys.argv[1:])); sys.exit(0 if all(abs(x-y) <= 0.01*y for x,y in ((a[0],a[2]),(a[1],a[3]))) else 1)' "$got_d" "$got_r" "$1" "$2" ||
    echo "$got_d $got_r $1 $2" > "$AUDIT_OUT/smoke_size_mismatch"
}

bench() {
  echo "==> bench: packages/opentype/bench/run_bench.sh as shipped (stdout SHA-256 identical per scenario; README ratios parsed at run time)"
  OPENTYPE_BENCH_ITERS=${OPENTYPE_BENCH_ITERS:-200} sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || { tail -20 "$AUDIT_OUT/bench.log"; fail "run_bench.sh"; return; }
  grep -E '^  (PASS|FAIL) \[' "$AUDIT_OUT/bench.log" | sed 's/^/  /'
  python3 -I "$AUDIT_DIR/diff/claims.py" bench "$PKG_DIR/README.md" /tmp/pion-opentype-bench
  r=$?
  [ $r = 1 ] && fail "shipped bench: output hash / protocol"
  [ $r = 3 ] && echo "bench" >> "$AUDIT_OUT/docs_extra"
  # what the shipped workload actually reads (information)
  echo "  ttf-parser oracle stress (full API surface, same machine, single run): $("$ORACLE" stress /System/Library/Fonts/Supplemental/Arial.ttf 2> /dev/null || echo n/a); pion: $("$BIN/oa_rel" stress /System/Library/Fonts/Supplemental/Arial.ttf 0 2> /dev/null || echo n/a)"
}

harness() {
  echo "==> harness: the gates must catch 5 injected bugs (copies in \$AUDIT_OUT; a target that a fix rewrote is SKIPPED)"
  for bug in fmt12_off_by_one hmtx_reuse_first xshort_sign compound_2x2_swap macroman_0xdb; do
    H="$AUDIT_OUT/inject_$bug" && rm -rf "$H" && mkdir -p "$H" && cp -R "$PKG_DIR" "$H/opentype"
    res=$(python3 -I - "$H/opentype/src" "$bug" <<'PY'
import os, re, sys
d, bug = sys.argv[1], sys.argv[2]
# (file, regex, replacement): realistic one-token bugs, matched loosely so that formatting changes still apply
INJ = {
    "fmt12_off_by_one": ("cmap.pion", r"start_gid \+ \(cp64 - start_c\)", "start_gid + (cp64 - start_c) + 1L"),
    "hmtx_reuse_first": ("tables.pion", r"if gid < num_metrics \{ gid \} else \{ num_metrics - 1 \}", "if gid < num_metrics { gid } else { 0 }"),
    "xshort_sign": ("glyf.pion", r"x = if x_same_or_pos \{ x \+ dx \} else \{ x - dx \}", "x = if x_same_or_pos { x - dx } else { x + dx }"),
    "compound_2x2_swap": ("glyf.pion", r"mb = f2dot14_to_double\(read_i16_be\(data, g_off \+ pos \+ 2\)\)\n(\s*)mc = f2dot14_to_double\(read_i16_be\(data, g_off \+ pos \+ 4\)\)",
                          "mb = f2dot14_to_double(read_i16_be(data, g_off + pos + 4))\n\\1mc = f2dot14_to_double(read_i16_be(data, g_off + pos + 2))"),
    "macroman_0xdb": ("reader.pion", r"0xDB => 0x20AC", "0xDB => 0x00A4"),
}
f, rx, new = INJ[bug]
p = os.path.join(d, f)
s = open(p).read() if os.path.exists(p) else ""
s2, n = re.subn(rx, new, s)
if n != 1:
    print("SKIP")
    sys.exit(0)
open(p, "w").write(s2)
print("APPLIED")
PY
)
    if [ "$res" = SKIP ]; then echo "  injected $bug: SKIPPED (target rewritten by a fix)"; continue; fi
    if ! pionc build --release -o "$H/oa" "$H/opentype/audit" > "$H/build.log" 2>&1; then fail "harness build ($bug)"; continue; fi
    caught=""
    while IFS="$TAB" read -r name pol font face q full note; do
      "$H/oa" dump "$font" "$face" "$q" "$full" > "$H/$name.pion" 2>&1
      $CMP case "$name" "$pol" "$H/$name.pion" "$D/$name.ttf" "$D/$name.sk" "$H/oa" "$ORACLE" "$font" "$face" > /dev/null || caught="$caught $name"
    done < "$C/cases.tsv"
    for c in $("$H/oa" list | grep '^control_'); do
      "$H/oa" case "$c" "$C" | grep -q '^PASS' || caught="$caught $c"
    done
    if [ -z "$caught" ]; then
      fail "harness: injected $bug not caught by the diff gate or the control cases"
    else
      echo "  injected $bug: caught by $(echo $caught | wc -w | tr -d ' ') gates, e.g.$(echo $caught | cut -d' ' -f1-4 | sed 's/^/ /')"
    fi
  done
}

docs() {
  echo "==> docs: README.md / process claims vs measurements (values parsed from README.md)"
  grep -q 'redteam_p1_2_.* FAIL\|FAIL redteam_p1_2' "$AUDIT_OUT/cases_native_rel.txt" 2> /dev/null && export P1_2_OPEN=1
  UP=$(ls -d "$HOME"/.cargo/registry/src/*/ttf-parser-0.25.1/tests/tables 2> /dev/null | head -1)
  python3 -I "$AUDIT_DIR/diff/claims.py" docs "$PKG_DIR/README.md" "$PKG_DIR" "$AUDIT_OUT/unit_pkg.json" "$ROOT_DIR" "${UP:--}"
  r=$?
  extra=""
  [ -f "$AUDIT_OUT/smoke_size_mismatch" ] && { echo "  - wasm32 sizes differ > 1 % from README.md: $(cat "$AUDIT_OUT/smoke_size_mismatch")"; extra=1; }
  [ -f "$AUDIT_OUT/docs_extra" ] && { echo "  - a README.md benchmark ratio / hash is not reproduced (bench section)"; extra=1; }
  rm -f "$AUDIT_OUT/docs_extra"
  { [ $r = 3 ] || [ -n "$extra" ]; } && open_finding "P2-10: README.md / process claims not backed (see docs section)"
  [ $r = 0 ] && [ -z "$extra" ] && echo "  all checked claims hold"
}

clean_check() {
  d=$(git -C "$ROOT_DIR" status --porcelain --ignored -- packages/opentype | grep -v '^?? packages/opentype/audit/$')
  [ -z "$d" ] || { echo "$d"; fail "worktree not clean after audit"; }
}

case "$SECTION" in
  build) build ;;
  cases) cases ;;
  unit) unit ;;
  diff) diff_corpus ;;
  system) system ;;
  fuzz) fuzz ;;
  dos) dos ;;
  portability) portability ;;
  smoke) smoke ;;
  bench) bench ;;
  harness) harness ;;
  docs) docs ;;
  all)
    build
    cases
    unit
    diff_corpus
    system
    fuzz
    dos
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
