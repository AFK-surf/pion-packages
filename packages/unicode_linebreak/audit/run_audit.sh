#!/bin/sh
# One-shot red-team audit for packages/unicode_linebreak (RT-unicode-linebreak, see REPORT.md).
#   sh packages/unicode_linebreak/audit/run_audit.sh [all|build|static|unit|tables|cases|conformance|api|oracles|dos|smoke|bench|inject]
# (single sections need a previous `build`)
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), cargo (Rust icu_segmenter =2.4.0 oracle, --locked, crate
# cache when offline), python3 (stdlib only, always run as `python3 -I -B`). Unicode 16.0.0 data is vendored
# (gzip, SHA-256 pinned) in audit/ucd; network not needed. Artifacts go to $AUDIT_OUT (default
# /tmp/pion-unicode-linebreak-audit; /private/tmp on macOS because the wasm32 runner resolves symlinks).
# Nothing is written inside the repository. Every number README.md claims (Send lists, unit test count,
# LineBreakTest count, wasm_smoke stdout / SHA-256 / size, differential count, benchmark SHA-256 and speedups)
# is parsed from README.md at run time (diff/readme.py).
#
# Exit status: 1 while any P0 condition reproduces (crash / trap / timeout, a native-vs-wasm32 or debug-vs-release
# divergence, a divergence from LineBreakTest-16.0.0, the independent model or Rust icu_segmenter 2.4.0 that no
# finding explains, a failing control case, a wasm_smoke hash that differs from README.md, a benchmark whose
# outputs are not byte-identical, or an injected bug the gate misses). Open P1/P2 findings (and README drift) are
# listed as OPEN and fail the run only with STRICT=1. Repository-root files (BENCHMARKS.md, catalog.json,
# README.md, THIRD_PARTY_NOTICES.md) are only ever reported as INFO.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/tmp/pion-unicode-linebreak-audit}
if [ -d /private/tmp ] && [ "$AUDIT_OUT" = /tmp/pion-unicode-linebreak-audit ]; then AUDIT_OUT=/private/tmp/pion-unicode-linebreak-audit; fi
BIN="$AUDIT_OUT/bin"
C="$AUDIT_OUT/corpus"
U="$AUDIT_DIR/ucd"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
STRICT=${STRICT:-0}
FUZZ_N=${FUZZ_N:-20000}
README="$PKG_DIR/README.md"
PY="python3 -I -B"
CMP="$PY $AUDIT_DIR/diff/compare.py"
RD="$PY $AUDIT_DIR/diff/readme.py $README"
MODES="native_dbg native_rel wasm_dbg wasm_rel"
CORPORA="lbtest named pairs fastpath fuzz"
mkdir -p "$BIN"
export PYTHONDONTWRITEBYTECODE=1
RC=0
OPEN=""
INFO=""
fail() { echo "  FAIL (P0): $*"; RC=1; }
open_finding() {
  case "$OPEN" in *"- ${1%%:*}:"*) return ;; esac
  echo "  OPEN: $*"
  OPEN="$OPEN
  - $*"
}
info() {
  echo "  INFO: $*"
  INFO="$INFO
  - $*"
}
title() {
  case "$1" in
    P2-1) echo "94 unassigned Supplemental Arrows-C code points (U+1F80C..1F8FF gaps) are Line_Break=ID, Unicode 16.0.0 says XX (gen_tables.py hard-codes 1F000..1FAFF)" ;;
    P2-2) echo "LB21a ignores the [BA - \$EastAsian] exclusion: HL + U+3000 IDEOGRAPHIC SPACE glues the next non-HL" ;;
    P2-3) echo "LB10 keeps a remaining mark's East_Asian_Width (U+3099 / U+302A / U+16FF0 after SP or at sot): LB19a breaks before a quote" ;;
    P1-1) echo "next_break_opportunity rescans from byte 0 on every call: iterating the opportunities of a text is O(n^2) (16 KB -> seconds)" ;;
    P2-4) echo "tools/gen_tables.py --check (README.md's determinism check) fails on the committed src/tables.pion: the generator's layout is not pionc fmt's" ;;
    P2-5) echo "README.md claims not reproduced (counts, Send list, smoke hash / size, benchmark numbers)" ;;
    *) echo "(see REPORT.md)" ;;
  esac
}
runner() {
  case "$1" in
    native_dbg) echo "$BIN/ulb_audit_dbg" ;;
    native_rel) echo "$BIN/ulb_audit_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/ulb_audit_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/ulb_audit_rel.wasm" ;;
  esac
}
build4() { # <pkg_dir> <prefix>
  pionc build -o "$2_dbg" "$1" > /dev/null &&
    pionc build --release -o "$2_rel" "$1" > /dev/null &&
    pionc build --target wasm32 -o "$2_dbg.wasm" "$1" > /dev/null &&
    pionc build --release --target wasm32 -o "$2_rel.wasm" "$1" > /dev/null
}

build() {
  echo "==> build: audit CLI in 4 modes, white-box table dumper, Rust icu_segmenter =2.4.0 oracle (cargo --locked), corpora"
  pionc fmt --check "$AUDIT_DIR" > /dev/null || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  build4 "$AUDIT_DIR" "$BIN/ulb_audit" || fail "build audit CLI (4 modes)"
  W="$AUDIT_OUT/whitebox" && rm -rf "$W" && mkdir -p "$W/src"
  printf '[package]\nname = "unicode_linebreak_whitebox"\nversion = "0.1.0"\n\n[dependencies]\n' > "$W/pion.toml"
  for f in "$PKG_DIR"/src/*.pion; do
    case "$f" in *_test.pion) ;; *) cp "$f" "$W/src/" ;; esac
  done
  cp "$AUDIT_DIR/whitebox/dump.pion" "$W/src/zz_audit_whitebox.pion"
  for f in "$PKG_DIR"/src/*.pion; do
    case "$f" in *_test.pion) ;; *) cmp -s "$f" "$W/src/$(basename "$f")" || fail "white-box copy of $(basename "$f") differs" ;; esac
  done
  pionc build --release -o "$BIN/whitebox" "$W" > "$AUDIT_OUT/whitebox_build.log" 2>&1 || { tail -5 "$AUDIT_OUT/whitebox_build.log"; fail "white-box build"; }
  M="$AUDIT_DIR/diff/rust/Cargo.toml"
  { CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline --manifest-path "$M" 2> /dev/null ||
    CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --manifest-path "$M"; } || fail "cargo build oracle"
  cp "$AUDIT_OUT/rust-target/release/unicode_linebreak_audit_oracle" "$BIN/oracle"
  ver=$(sed -n '/^name = "icu_segmenter"$/{n;p;}' "$AUDIT_DIR/diff/rust/Cargo.lock")
  rm -rf "$C" && set -- $($PY "$AUDIT_DIR/diff/gen.py" "$U" "$C" "$FUZZ_N")
  echo "  corpora: LineBreakTest $1, named $2, pairs $3, fuzz $4, fastpath $5 ($6 Unicode 16.0.0 property combinations), icuprobe $7 (ICU behaviour only)"
  $PY "$AUDIT_DIR/diff/ucd.py" "$U" verify || fail "vendored Unicode 16.0.0 data (SHA-256 / derived-file cross-check)"
  $PY "$AUDIT_DIR/diff/model.py" "$U" selftest || fail "reference model self-test"
  echo "  $(pionc --version) | node $(node --version) | $(cargo --version) | icu_segmenter $ver | python $(python3 -c 'import sys;print(sys.version.split()[0])')"
}

static() {
  echo "==> static: license, dependencies, extern \"C\", World, module-level state, floats, internal names, tables regeneration, Send"
  SRC=$(ls "$PKG_DIR"/src/*.pion | grep -v '_test\.pion$' | xargs cat | grep -v '^ *//')
  lic=$(grep -cE '^license *= *"MIT"' "$PKG_DIR/pion.toml")
  echo "  pion.toml license = \"MIT\": $lic"; [ "$lic" = 1 ] || fail "pion.toml license is not MIT"
  deps=$(sed -n '/^\[dependencies\]/,/^\[/p' "$PKG_DIR/pion.toml" | grep -vc '^\[\|^ *$\|^#')
  echo "  [dependencies] entries: $deps"; [ "$deps" = 0 ] || fail "external dependencies"
  for pat in 'extern "C"' '^import '; do
    n=$(printf '%s\n' "$SRC" | grep -c "$pat")
    echo "  $pat: $n"; [ "$n" = 0 ] || fail "$pat in src"
  done
  n=$(printf '%s\n' "$SRC" | grep -cw 'World')
  echo "  World: $n"; [ "$n" = 0 ] || fail "World in src"
  n=$(printf '%s\n' "$SRC" | grep -cE '^(pub )?let mut ')
  echo "  module-level let mut: $n"; [ "$n" = 0 ] || fail "module-level let mut"
  n=$(printf '%s\n' "$SRC" | grep -cE '^(pub )?let [A-Za-z_0-9]+ *: *(Array|Map|Bytes|StringBuilder|FixedArray)')
  echo "  module-level Array / Map / Bytes / StringBuilder / FixedArray: $n"; [ "$n" = 0 ] || fail "module-level container"
  n=$(printf '%s\n' "$SRC" | grep -c 'FixedArray')
  echo "  FixedArray anywhere in src (README: zero): $n"; [ "$n" = 0 ] || open_finding "P2-5: $(title P2-5)"
  n=$(printf '%s\n' "$SRC" | grep -cE 'Double|Float|to_double|\.to_float')
  echo "  Double / Float: $n"; [ "$n" = 0 ] || fail "floating point in src"
  n=$(printf '%s\n' "$SRC" | grep -cE 'panic\(|abort\(|\.unwrap\(')
  echo "  panic / abort / unwrap in src: $n"; [ "$n" = 0 ] || fail "explicit panic paths in src"
  # generic leak check (no host list is kept in the repository): this machine's host name, absolute home paths,
  # and any extra names a caller passes in $AUDIT_PRIVATE_NAMES (`a|b|c`)
  set -- "$README" "$PKG_DIR"/src/*.pion "$PKG_DIR"/tools/*.py "$PKG_DIR"/bench/*.sh "$PKG_DIR"/bench/*.py "$PKG_DIR"/bench/*/src/* "$PKG_DIR"/wasm_smoke/src/* "$AUDIT_DIR"/*.md
  n1=$(grep -ciE '/Users/|/home/' "$@" | awk -F: '{s+=$NF} END {print s+0}')
  n2=$(grep -ciwE "$(hostname -s 2> /dev/null || echo localhost)${AUDIT_PRIVATE_NAMES:+|$AUDIT_PRIVATE_NAMES}" "$@" | awk -F: '{s+=$NF} END {print s+0}')
  n=$((n1 + n2))
  echo "  host names / absolute paths in README, src, tools, bench, wasm_smoke, audit report: $n"; [ "$n" = 0 ] || fail "internal names"
  echo "  README.md Unicode version: $($RD unicode_version)"
  [ "$($RD unicode_version)" = 16.0.0 ] || fail "README does not claim Unicode 16.0.0"
  grep -q 'Unicode 16.0.0' "$PKG_DIR/tools/gen_tables.py" || fail "tools/gen_tables.py does not name Unicode 16.0.0"
  grep -q 'Unicode-3.0' "$README" || fail "README.md lacks the Unicode-3.0 attribution"
  grep -q 'Unicode-3.0' "$PKG_DIR/src/tables.pion" || fail "src/tables.pion lacks the Unicode-3.0 header"
  D="$AUDIT_OUT/ucd" && rm -rf "$D" && mkdir -p "$D"
  for f in LineBreak EastAsianWidth UnicodeData emoji-data; do gunzip -c "$U/$f.txt.gz" > "$D/$f.txt"; done
  R="$AUDIT_OUT/regen" && rm -rf "$R" && mkdir -p "$R"
  $PY "$PKG_DIR/tools/gen_tables.py" "$D" "$R/tables.pion" > /dev/null || fail "tools/gen_tables.py failed on Unicode 16.0.0 data"
  $PY "$PKG_DIR/tools/gen_tables.py" "$D" "$R/tables2.pion" > /dev/null
  # token-level identity: string concatenations joined, all whitespace dropped
  norm() { $PY -c 'import re,sys; s=open(sys.argv[1]).read(); s=re.sub(r"\"\s*\+\s*\"","",s); print(re.sub(r"\s+","",s))' "$1"; }
  same_tokens=0
  [ "$(norm "$PKG_DIR/src/tables.pion")" = "$(norm "$R/tables.pion")" ] && same_tokens=1
  if cmp -s "$PKG_DIR/src/tables.pion" "$R/tables.pion"; then echo "  src/tables.pion regenerated byte-identically from the official 16.0.0 files ($(wc -c < "$R/tables.pion" | tr -d ' ') B)"
  elif [ $same_tokens = 1 ]; then
    echo "  src/tables.pion ($(wc -c < "$PKG_DIR/src/tables.pion" | tr -d ' ') B) == generator output ($(wc -c < "$R/tables.pion" | tr -d ' ') B) token for token (same data); bytes differ only in layout"
    cp "$R/tables.pion" "$R/fmt_probe.pion"
    pionc fmt "$R/fmt_probe.pion" > /dev/null 2>&1 && cmp -s "$R/fmt_probe.pion" "$PKG_DIR/src/tables.pion" && echo "  generator output + pionc fmt == committed file: the committed file was pionc-fmt'ed after generation"
    pionc fmt --check "$R/tables.pion" > /dev/null 2>&1 || echo "  raw generator output fails pionc fmt --check"
    open_finding "P2-4: $(title P2-4)"
  else fail "src/tables.pion data differs from tools/gen_tables.py output on Unicode 16.0.0 data"; fi
  cmp -s "$R/tables.pion" "$R/tables2.pion" && echo "  two generator runs byte-identical (deterministic)" || fail "gen_tables.py not deterministic"
  if out=$($PY "$PKG_DIR/tools/gen_tables.py" --check "$D" "$PKG_DIR/src/tables.pion" 2>&1); then echo "  --check: $out"
  else
    echo "  --check on the committed file: $out" | sed "s|$PKG_DIR/||"
    [ $same_tokens = 1 ] && open_finding "P2-4: $(title P2-4)" || fail "gen_tables.py --check"
  fi
  printf 'garbage\n' > "$R/stale.pion"
  $PY "$PKG_DIR/tools/gen_tables.py" --check "$D" "$R/stale.pion" > /dev/null 2>&1 && fail "gen_tables.py --check accepts a stale file" || echo "  --check rejects a stale file: ok"
  $PY "$AUDIT_DIR/diff/ucd.py" "$U" defaults "$PKG_DIR/tools/gen_tables.py"
  grep -q 'unicode_linebreak' "$ROOT_DIR/THIRD_PARTY_NOTICES.md" 2> /dev/null || info "root THIRD_PARTY_NOTICES.md does not list packages/unicode_linebreak's Unicode 16.0.0 data (LineBreak.txt, EastAsianWidth.txt, UnicodeData.txt, emoji-data.txt; Unicode-3.0) - root file: release integration, not this branch"
  git -C "$ROOT_DIR" rev-parse HEAD > /dev/null 2>&1 && [ -z "$(git -C "$ROOT_DIR" log --format=%H -- "$PKG_DIR/src" | sed -n 2p)" ] && info "the branch has a single commit for packages/unicode_linebreak: the Red stage ($($RD red) on the stub build) is a README statement, not reproducible from history"
  echo "  Send probe: public values captured by spawn, checked against README.md (pionc check --json)"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\nunicode_linebreak = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  probe() { # <type> <value expr>
    printf 'import "unicode_linebreak"\n\nfn probe(v : %s, world : World) -> Unit {\n  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })\n}\n\n///|\npub fn main(world : World) -> Int {\n  0\n}\n' "$1" > "$P/src/main.pion"
    pionc check --json "$P" 2>&1 | $PY -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))' 2>/dev/null
  }
  c_send=" $($RD send_types) "
  c_not=" $($RD notsend_types) "
  for t in LineBreakClass BreakKind BreakOpportunity LineBreakError LineBreakLimits String "Array[BreakOpportunity]"; do
    case "$t" in String) ty=String ;; "Array[BreakOpportunity]") ty="Array[unicode_linebreak::BreakOpportunity]" ;; *) ty="unicode_linebreak::$t" ;; esac
    r=$(probe "$ty")
    extra=""
    case "$c_send" in *" $t "*) [ "$r" = ok ] || { open_finding "P2-5: $(title P2-5)"; extra=" (README.md claims Send)"; } ;; esac
    case "$c_not" in *" $t "*) [ "$r" = ok ] && { open_finding "P2-5: $(title P2-5)"; extra=" (README.md claims !Send)"; } ;; esac
    printf '    %-26s %s%s\n' "$t" "$([ "$r" = ok ] && echo Send || echo "!Send ($r)")" "$extra"
  done
  for t in $c_send $c_not; do
    case " LineBreakClass BreakKind BreakOpportunity LineBreakError LineBreakLimits Array[BreakOpportunity] " in
      *" $t "*) ;; *) open_finding "P2-5: $(title P2-5)"; echo "    README.md lists unknown type $t" ;; esac
  done
}

unit() {
  echo "==> unit: pionc fmt/check/test of packages/unicode_linebreak (count vs README.md)"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/unicode_linebreak"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/unicode_linebreak"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> /dev/null
  $PY - "$AUDIT_OUT/unit_pkg.json" "$($RD unit)" <<'PY' || fail "unit tests"
import json, sys
d = json.load(open(sys.argv[1]))
own = [t for t in d["tests"] if t.get("pkg") in (None, "unicode_linebreak")]
bad = [t["name"] for t in own if not t["ok"]]
print("  packages/unicode_linebreak tests: %d/%d pass (README.md: %s)" % (len(own) - len(bad), len(own), sys.argv[2]))
for b in bad:
    print("  FAIL  %s" % b)
sys.exit(1 if bad or "%d/%d" % (len(own), len(own)) != sys.argv[2] else 0)
PY
}

tables() {
  echo "==> tables: all 1,114,112 code points (public line_break_class in 4 modes + white-box raw / resolved / flags) vs independent UCD loader"
  for m in $MODES; do
    # shellcheck disable=SC2046
    $(runner $m) classes > "$AUDIT_OUT/classes_$m.txt" 2> "$AUDIT_OUT/classes_$m.err" || fail "classes: $m exited non-zero"
  done
  for m in native_dbg wasm_dbg wasm_rel; do
    $CMP same "$AUDIT_OUT/classes_native_rel.txt" "$AUDIT_OUT/classes_$m.txt" || fail "classes: $m differs from native_rel"
  done
  echo "  line_break_class dump: $(wc -l < "$AUDIT_OUT/classes_native_rel.txt" | tr -d ' ') runs, 4 modes byte-identical"
  "$BIN/whitebox" > "$AUDIT_OUT/whitebox.txt" || fail "white-box dump"
  out=$($PY "$AUDIT_DIR/diff/ucd.py" "$U" table "$AUDIT_OUT/classes_native_rel.txt" "$AUDIT_OUT/whitebox.txt")
  r=$?
  printf '%s\n' "$out" | grep -v '^FINDINGS'
  [ $r = 0 ] || fail "table mismatch no finding explains"
  for id in $(printf '%s\n' "$out" | grep '^FINDINGS' | cut -d' ' -f2-); do open_finding "$id: $(title "$id")"; done
}

cases() {
  echo "==> cases: red-team + control cases, one process per case, in all 4 modes"
  names=$("$BIN/ulb_audit_rel" list)
  for m in $MODES; do
    : > "$AUDIT_OUT/cases_$m.txt"
    for c in $names; do
      # shellcheck disable=SC2046
      raw=$($(runner $m) case "$c" 2>&1)
      out=$(printf '%s\n' "$raw" | grep -E '^(PASS|FAIL) ' | tail -1)
      [ -n "$out" ] || out="FAIL $c :: ABORT ($(printf '%s\n' "$raw" | tail -1))"
      echo "$out" >> "$AUDIT_OUT/cases_$m.txt"
    done
    echo "  $m: $(grep -c '^PASS' "$AUDIT_OUT/cases_$m.txt")/$(echo "$names" | wc -w | tr -d ' ') pass"
  done
  sed 's/^/    /' "$AUDIT_OUT/cases_native_rel.txt" | cut -c1-200
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/cases_native_rel.txt" "$AUDIT_OUT/cases_$m.txt" || { diff "$AUDIT_OUT/cases_native_rel.txt" "$AUDIT_OUT/cases_$m.txt" | head -6; fail "case results of $m differ from native_rel"; }
  done
  grep -q 'ABORT' "$AUDIT_OUT"/cases_*.txt && fail "a case aborted (panic / trap)"
  grep -q '^FAIL control_' "$AUDIT_OUT/cases_native_rel.txt" && fail "control case failing"
  for f in $(grep '^FAIL redteam_' "$AUDIT_OUT/cases_native_rel.txt" | awk '{print $2}'); do
    id=$(echo "$f" | sed -E 's/redteam_p([0-9])_([0-9]+)_.*/P\1-\2/')
    open_finding "$id: $(title "$id")"
    case "$f" in redteam_p0_*) fail "P0 red-team case $f" ;; esac
  done
}

conformance() {
  echo "==> conformance: every corpus in 4 modes byte-identical; official LineBreakTest-16.0.0 positions + kinds; invariants"
  for g in $CORPORA; do
    for m in $MODES; do
      # shellcheck disable=SC2046
      $(runner $m) dump "$C/$g.cases" > "$AUDIT_OUT/pion_${g}_$m.txt" 2> "$AUDIT_OUT/pion_${g}_$m.err" || fail "$g: $m exited non-zero ($(tail -1 "$AUDIT_OUT/pion_${g}_$m.err"))"
    done
    for m in native_dbg wasm_dbg wasm_rel; do
      $CMP same "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_${g}_$m.txt" || fail "$g: $m differs from native_rel"
    done
    cp "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_$g.txt"
    echo "  [$g] $(wc -l < "$C/$g.cases" | tr -d ' ') inputs, sha256 $(shasum -a 256 "$AUDIT_OUT/pion_$g.txt" | cut -c1-16), 4 modes byte-identical"
  done
  $CMP lbtest "$U" "$C/lbtest.cases" "$AUDIT_OUT/pion_lbtest.txt" || fail "LineBreakTest-16.0.0 / kinds / invariants"
  claim=$($RD lbtest)
  got=$($CMP lbtest "$U" "$C/lbtest.cases" "$AUDIT_OUT/pion_lbtest.txt" | sed -n 's/.*txt: \([0-9]*\/[0-9]*\) vectors.*/\1/p')
  echo "  README.md: $claim"; [ "$got" = "$claim" ] || open_finding "P2-5: $(title P2-5)"
  for g in named pairs fastpath fuzz; do
    $CMP invariants "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" | sed "s/^  /  [$g] /" || fail "$g: output invariants"
  done
}

api() {
  echo "==> api: next_break_opportunity at every byte offset (incl. mid-UTF-8, -1, len, len+1, INT_MIN/MAX) == line_breaks; LineBreakLimits sweep"
  for g in lbtest named fastpath fuzz; do
    for m in native_rel wasm_rel; do
      # shellcheck disable=SC2046
      $(runner $m) api "$C/$g.cases" > "$AUDIT_OUT/api_${g}_$m.txt" 2>&1 || fail "api $g: $m exited non-zero"
    done
    cmp -s "$AUDIT_OUT/api_${g}_native_rel.txt" "$AUDIT_OUT/api_${g}_wasm_rel.txt" || fail "api $g: wasm32 differs from native"
    n=$(wc -l < "$AUDIT_OUT/api_${g}_native_rel.txt" | tr -d ' ')
    ok=$(grep -c '^ok$' "$AUDIT_OUT/api_${g}_native_rel.txt")
    offs=$($PY -c 'import sys
n=0
for l in open(sys.argv[1]):
    l=l.rstrip("\n")
    if l: n += len(l.split("\t",1)[1])//2 + 8
print(n)' "$C/$g.cases")
    echo "  [$g] $ok/$n inputs consistent ($offs next_break_opportunity calls, 9 limit settings each), native == wasm32"
    [ "$ok" = "$n" ] || { grep -v '^ok$' "$AUDIT_OUT/api_${g}_native_rel.txt" | head -3; fail "api inconsistency ($g)"; }
  done
}

oracles() {
  echo "==> oracles: independent Python UAX #14 16.0.0 model (offsets + kinds), Rust icu_segmenter =2.4.0 (offsets)"
  "$BIN/oracle" "$C/lbtest.cases" > "$AUDIT_OUT/icu_lbtest.txt" || fail "oracle failed on lbtest"
  "$BIN/oracle" "$C/icuprobe.cases" > "$AUDIT_OUT/icu_icuprobe.txt" || fail "oracle failed on icuprobe"
  for g in $CORPORA; do
    echo "  [$g]"
    out=$($CMP model "$U" "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" 2>&1)
    r=$?
    printf '%s\n' "$out" | grep -v '^FINDINGS' | cut -c1-260
    [ $r = 0 ] || fail "unexplained divergence from the reference model ($g)"
    for id in $(printf '%s\n' "$out" | grep '^FINDINGS' | cut -d' ' -f2-); do open_finding "$id: $(title "$id")"; done
    "$BIN/oracle" "$C/$g.cases" > "$AUDIT_OUT/icu_$g.txt" || fail "oracle failed on $g"
    out=$($CMP icu "$U" "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" "$AUDIT_OUT/icu_$g.txt" "$AUDIT_OUT/icu_lbtest.txt" "$C/lbtest.cases" "$C/icuprobe.cases" "$AUDIT_OUT/icu_icuprobe.txt" 2>&1)
    r=$?
    printf '%s\n' "$out" | grep -v '^FINDINGS' | cut -c1-300
    [ $r = 0 ] || fail "unexplained divergence from Rust icu_segmenter 2.4.0 ($g)"
  done
}

dos() {
  echo "==> dos: 25 bombs at n and 4n, self-timed median of 7 runs in process (native --release, wasm32 --release)"
  out=$($PY "$AUDIT_DIR/diff/dos.py" "$BIN/ulb_audit_rel" "node $WASM_RT $BIN/ulb_audit_rel.wasm")
  r=$?
  printf '%s\n' "$out" | grep -v '^OPENIDS' | cut -c1-200
  for id in $(printf '%s\n' "$out" | grep '^OPENIDS' | cut -d' ' -f2-); do open_finding "$id: $(title "$id")"; done
  [ $r = 0 ] || fail "DoS bomb crashed / diverged / over budget without an open finding (see above)"
}

smoke() {
  echo "==> smoke: packages/unicode_linebreak/wasm_smoke in 4 modes vs README.md"
  S="$PKG_DIR/wasm_smoke"
  build4 "$S" "$BIN/smoke" || { fail "build wasm_smoke"; return; }
  for m in native_dbg native_rel wasm_dbg wasm_rel; do
    case $m in
      native_dbg) "$BIN/smoke_dbg" > "$AUDIT_OUT/smoke_$m.txt" ;;
      native_rel) "$BIN/smoke_rel" > "$AUDIT_OUT/smoke_$m.txt" ;;
      wasm_dbg) node "$WASM_RT" "$BIN/smoke_dbg.wasm" > "$AUDIT_OUT/smoke_$m.txt" ;;
      wasm_rel) node "$WASM_RT" "$BIN/smoke_rel.wasm" > "$AUDIT_OUT/smoke_$m.txt" ;;
    esac || fail "wasm_smoke $m exited non-zero"
  done
  want=$($RD smoke_sha) || fail "README.md: wasm_smoke SHA-256 not found"
  for m in native_dbg native_rel wasm_dbg wasm_rel; do
    got=$(shasum -a 256 "$AUDIT_OUT/smoke_$m.txt" | awk '{print $1}')
    echo "  $m sha256 $got"
    [ "$got" = "$want" ] || fail "wasm_smoke $m sha256 != README.md ($want)"
  done
  [ "$(cat "$AUDIT_OUT/smoke_native_rel.txt")" = "$($RD smoke_stdout)" ] || fail "wasm_smoke stdout != README.md"
  sed 's/^/    /' "$AUDIT_OUT/smoke_native_rel.txt"
  want=$($RD wasm_size)
  for k in dbg rel; do
    got=$(wc -c < "$BIN/smoke_$k.wasm" | tr -d ' ')
    # the wasm32 binary embeds absolute source paths, so its size depends on the checkout path: tolerance 1 %
    echo "  wasm32 $k size: $got B (README.md: $want B; path-dependent, tolerance 1 %)"
    [ $(( (got - want) * (got - want) * 10000 )) -le $(( want * want )) ] || open_finding "P2-5: $(title P2-5)"
  done
}

bench() {
  echo "==> bench: independent re-run of bench/run_bench.sh (differential, SHA-256, speed vs README.md)"
  sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || { tail -20 "$AUDIT_OUT/bench.log"; fail "bench/run_bench.sh failed"; return; }
  grep -E '^(PASS|FAIL)|^\| `|SHA-256 verified' "$AUDIT_OUT/bench.log" | sed 's/^/    /'
  n=$(sed -nE 's/^PASS: ([0-9]+\/[0-9]+) differential cases.*/\1/p' "$AUDIT_OUT/bench.log")
  [ -n "$n" ] || fail "bench differential oracle did not pass"
  [ "$n" = "$($RD diff_cases)" ] || open_finding "P2-5: $(title P2-5)"
  shas=$(sed -nE 's/.*SHA-256 verified identical across all implementations and rounds: `([0-9a-f]{64})`.*/\1/p' "$AUDIT_OUT/bench.log" | tr '\n' ' ')
  echo "  benchmark stdout SHA-256: $shas"
  [ "$shas" = "$($RD sha_c1) $($RD sha_c2) " ] || fail "benchmark stdout SHA-256 ($shas) != README.md"
  $PY - "$AUDIT_OUT/bench.log" "$($RD speedup_c1)" "$($RD speedup_c2)" <<'PY' || open_finding "P2-5: $(title P2-5)"
import os, re, sys
t = open(sys.argv[1]).read()
rows = [l for l in t.split("\n") if l.startswith("| `pion_linebreak`")]
sp = [float(re.search(r"([0-9.]+)x", r.split("|")[8]).group(1)) for r in rows]
claims = [float(sys.argv[2]), float(sys.argv[3])]
load = os.popen("cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg").read().strip()
print("  measured speed vs Rust %s, README.md %s (machine load: %s; claims hold if >= 0.75x the claim)" % (sp, claims, load))
sys.exit(0 if len(sp) == 2 and all(a >= 0.75 * b for a, b in zip(sp, claims)) else 1)
PY
}

inject() {
  echo "==> inject: realistic bugs injected into a copy of packages/unicode_linebreak/src; the gate must catch each"
  echo "     (gate = control cases + official LineBreakTest positions / kinds + next_break_opportunity / limits sweep)"
  I="$AUDIT_OUT/inject" && rm -rf "$I" && mkdir -p "$I"
  $PY "$AUDIT_DIR/diff/inject.py" "$PKG_DIR" "$I" > "$I/list.txt"
  caught=0
  total=0
  while read -r n dir desc; do
    total=$((total + 1))
    if [ "$dir" = SKIP ]; then
      echo "  [$n] SKIP (target text not present any more: $desc)"
      fail "mutant $n target missing"
      continue
    fi
    if ! pionc build --release -o "$I/m$n.bin" "$dir" > "$I/build$n.log" 2>&1; then
      echo "  [$n] mutant does not compile ($desc)"
      fail "mutant $n did not build"
      continue
    fi
    hit=""
    for c in $("$I/m$n.bin" list); do
      case "$c" in control_*) ;; *) continue ;; esac
      "$I/m$n.bin" case "$c" 2>&1 | grep -q '^PASS ' || hit="$hit $c"
    done
    "$I/m$n.bin" dump "$C/lbtest.cases" > "$I/lb$n.txt" 2>&1
    $CMP lbtest "$U" "$C/lbtest.cases" "$I/lb$n.txt" > "$I/lb$n.log" 2>&1 || hit="$hit LineBreakTest"
    "$I/m$n.bin" api "$C/named.cases" > "$I/api$n.txt" 2>&1
    [ "$(grep -vc '^ok$' "$I/api$n.txt")" = 0 ] || hit="$hit api"
    if [ -n "$hit" ]; then
      caught=$((caught + 1))
      echo "  [$n] caught by$hit: $desc" | cut -c1-220
    else
      echo "  [$n] MISSED: $desc"
      fail "injected bug $n not caught"
    fi
  done < "$I/list.txt"
  echo "  injected bugs caught: $caught/$total"
  rm -rf "$I"/m*/
}

summary() {
  echo "==> summary"
  if [ -n "$OPEN" ]; then
    echo "  OPEN findings (REPORT.md):$OPEN"
  else
    echo "  no open findings"
  fi
  [ -z "$INFO" ] || echo "  INFO (not failing):$INFO"
  if [ "$STRICT" = 1 ] && [ -n "$OPEN" ]; then
    echo "  STRICT=1: open findings fail the run"
    RC=1
  fi
  dirty=$(git -C "$ROOT_DIR" status --porcelain --ignored -- "$PKG_DIR" 2> /dev/null | grep -v '^?? packages/unicode_linebreak/audit/$')
  [ -z "$dirty" ] || { printf '%s\n' "$dirty" | head; fail "audit left files in the repository"; }
  echo "EXIT=$RC"
}

case "$SECTION" in
  all)
    build
    static
    unit
    tables
    cases
    conformance
    api
    oracles
    dos
    smoke
    bench
    inject
    ;;
  build | static | unit | tables | cases | conformance | api | oracles | dos | smoke | bench | inject) "$SECTION" ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
summary
exit $RC
