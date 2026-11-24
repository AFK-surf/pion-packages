#!/bin/sh
# One-shot red-team audit for packages/unicode_segment (RT-unicode-segment, see REPORT.md).
#   sh packages/unicode_segment/audit/run_audit.sh [all|build|static|unit|tables|conformance|oracles|determinism|dos|smoke|bench|inject]
# (single sections need a previous `build`)
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), cargo (Rust unicode-segmentation =1.13.3 and =1.12.0
# oracles, --locked), python3 (stdlib only). The official Unicode 16.0.0 data and test files (and the 17.0.0
# property files used to classify Rust 1.13.3 drift) are vendored gzip-compressed in audit/ucd.
# Artifacts go to $AUDIT_OUT (default /tmp/pion-unicode-segment-audit, /private/tmp/... on macOS because the
# wasm32 runner resolves symlinks). Nothing is written inside the repository.
# Every README number (unit count, UCD counts, wasm_smoke stdout / SHA-256 / sizes, differential count,
# benchmark SHA-256s and speedups, Send lists, the Rust oracle's Unicode version) is parsed from README.md at run
# time (diff/readme.py).
#
# Exit status: 1 while any P0 condition reproduces (a failing official UAX #29 16.0.0 vector, a table entry that
# differs from the UCD, an invariant violation (tiling, concat, cursor at any byte offset, SegmentLimits
# contract), a crash / timeout / non-linear bomb no finding explains, a native-vs-wasm32 or debug-vs-release
# divergence, an unexplained difference from Rust unicode-segmentation, a wasm_smoke or benchmark hash that
# differs from README.md, or an injected bug the gate misses). Open P1/P2 findings are listed as OPEN and fail
# the run only with STRICT=1. Repository-root files (BENCHMARKS.md, catalog.json, README.md,
# THIRD_PARTY_NOTICES.md) are only ever reported as INFO.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
if [ -d /private/tmp ]; then DEF_OUT=/private/tmp/pion-unicode-segment-audit; else DEF_OUT=/tmp/pion-unicode-segment-audit; fi
AUDIT_OUT=${AUDIT_OUT:-$DEF_OUT}
BIN="$AUDIT_OUT/bin"
C="$AUDIT_OUT/corpus"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
STRICT=${STRICT:-0}
FUZZ_N=${FUZZ_N:-4000}
README="$PKG_DIR/README.md"
PY="python3 -I -B"
CMP="$PY $AUDIT_DIR/diff/compare.py"
RD="$PY $AUDIT_DIR/diff/readme.py $README"
MODES="native_dbg native_rel wasm_dbg wasm_rel"
SHA() { if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
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
  case "$INFO" in *"- ${1%%:*}:"*) return ;; esac
  echo "  INFO: $*"
  INFO="$INFO
  - $*"
}
title() {
  case "$1" in
    P1-1) echo "cursor APIs quadratic on ordinary text: walking 31 KB of space-separated Korean with next_/prev_grapheme_boundary takes ~5 s (Rust GraphemeCursor: 0.3 ms) (find_safe_grapheme_anchor rescans to the previous pair of neutral code points; no *_with_limits variant)" ;;
    P2-1) echo "README.md: Rust oracle 'unicode-segmentation 1.13.3 (Unicode 16.0.0 aligned)' is false: 1.13.3 embeds Unicode 17.0.0 and fails Unicode 16.0.0 vectors; bench Cargo.toml asks for 1.12.0 but Cargo.lock pins 1.13.3" ;;
    P2-2) echo "README.md claims not reproduced (unit / UCD counts, Send list, wasm_smoke, differential count)" ;;
    INFO-1) echo "root THIRD_PARTY_NOTICES.md does not list packages/unicode_segment's Unicode 16.0.0 data files (release integration, root file)" ;;
    INFO-2) echo "README '0 is enforced strictly (accepting only empty input)': unicode_words*_with_limits(max_segments = 0) accepts non-empty input that has no words (Ok([]): 0 <= 0, correct, wording only)" ;;
    INFO-3) echo "Rust unicode-segmentation 1.13.3 uses Unicode 17.0.0: differences on code points whose properties changed 16 -> 17 are version drift, not defects (1.12.0 = Unicode 16.0.0 agrees on every input)" ;;
    INFO-4) echo "cursor walk over a long Regional_Indicator run is quadratic: RI parity needs the whole run (Rust's GraphemeCursor rescans too)" ;;
    INFO-5) echo "benchmark speedups differ from README.md by more than 25 % on this machine (load-dependent, see bench log)" ;;
    INFO-9) echo "Rust unicode-segmentation (1.12.0 and 1.13.3) keeps 'AHLetter|Numeric|Hebrew_Letter Mid* ZWJ ExtPict' in one word; Pion matches the independent UAX #29 reference (diff/wbref.py) and WB6 / WB12" ;;
    INFO-6) echo "wasm32 binary size differs from README.md by more than 2 % (the binary embeds absolute source paths)" ;;
    *) echo "(see REPORT.md)" ;;
  esac
}
runner() {
  case "$1" in
    native_dbg) echo "$BIN/aud_dbg" ;;
    native_rel) echo "$BIN/aud_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/aud_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/aud_rel.wasm" ;;
  esac
}
build4() { # <pkg_dir> <prefix>
  pionc build -o "$2_dbg" "$1" > /dev/null &&
    pionc build --release -o "$2_rel" "$1" > /dev/null &&
    pionc build --target wasm32 -o "$2_dbg.wasm" "$1" > /dev/null &&
    pionc build --release --target wasm32 -o "$2_rel.wasm" "$1" > /dev/null
}
cargo_build() { # <manifest dir> <bin name> <dest>
  T="$AUDIT_OUT/rust-target-$2"
  { CARGO_TARGET_DIR="$T" cargo build -q --release --locked --offline --manifest-path "$1/Cargo.toml" 2> /dev/null ||
    CARGO_TARGET_DIR="$T" cargo build -q --release --locked --manifest-path "$1/Cargo.toml"; } && cp "$T/release/$2" "$3"
}

build() {
  echo "==> build: audit CLI in 4 modes, Rust oracles (unicode-segmentation =1.13.3 and =1.12.0, --locked), corpora, UCD"
  pionc fmt --check "$AUDIT_DIR" > /dev/null || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  build4 "$AUDIT_DIR" "$BIN/aud" || fail "build audit CLI (4 modes)"
  cargo_build "$AUDIT_DIR/diff/rust" useg_oracle "$BIN/rust13" || fail "cargo build oracle 1.13.3"
  cargo_build "$AUDIT_DIR/diff/rust12" useg_oracle12 "$BIN/rust12" || fail "cargo build oracle 1.12.0"
  rm -rf "$C" "$AUDIT_OUT"/pion_*.txt "$AUDIT_OUT"/rust1*_*.txt && set -- $($PY "$AUDIT_DIR/diff/gen.py" "$C" "$FUZZ_N")
  echo "  corpus: $1 official UAX #29 vectors, $2 named adversarial, $3 fuzz ($4 with ill-formed UTF-8)"
  mkdir -p "$AUDIT_OUT/ucd16"
  for f in "$AUDIT_DIR"/ucd/16.0.0/*.gz; do gunzip -c "$f" > "$AUDIT_OUT/ucd16/$(basename "$f" .gz)"; done
  echo "  $(pionc --version) | node $(node --version) | $(cargo --version) | python $(python3 -c 'import sys;print(sys.version.split()[0])')"
}

static() {
  echo "==> static: license, dependencies, extern \"C\", World, module-level state, FixedArray, floats, internal names, tables, Send"
  SRC=$(cat "$PKG_DIR"/src/*.pion | grep -v '^ *//')
  lic=$(grep -cE '^license *= *"MIT"' "$PKG_DIR/pion.toml")
  echo "  pion.toml license = \"MIT\": $lic"; [ "$lic" = 1 ] || fail "pion.toml license is not MIT"
  deps=$(sed -n '/^\[dependencies\]/,/^\[/p' "$PKG_DIR/pion.toml" | grep -vc '^\[\|^ *$\|^#')
  echo "  [dependencies] entries: $deps"; [ "$deps" = 0 ] || fail "external dependencies"
  for pat in 'extern "C"' '^import ' 'FixedArray' 'panic(' 'abort('; do
    n=$(printf '%s\n' "$SRC" | grep -c "$pat")
    echo "  $pat: $n"; [ "$n" = 0 ] || fail "$pat in src (README: zero)"
  done
  n=$(printf '%s\n' "$SRC" | grep -cw 'World')
  echo "  World: $n"; [ "$n" = 0 ] || fail "World in src"
  n=$(printf '%s\n' "$SRC" | grep -cE '^(pub )?let mut ')
  echo "  module-level let mut: $n"; [ "$n" = 0 ] || fail "module-level let mut"
  n=$(printf '%s\n' "$SRC" | grep -cE '^(pub )?let [A-Za-z_0-9]+ *: *(Array|Map|Bytes|StringBuilder)')
  echo "  module-level Array / Map / Bytes / StringBuilder: $n"; [ "$n" = 0 ] || fail "module-level mutable container"
  n=$(printf '%s\n' "$SRC" | grep -cE 'Double|Float')
  echo "  Double / Float: $n"; [ "$n" = 0 ] || fail "floating point in src (README: zero)"
  n=$(grep -ciwE 'tokyo|pvg-office|afk-ap|gt1|gt2|office-host|mac-studio|stillfail|/Users|/home' "$README" "$PKG_DIR"/src/*.pion "$PKG_DIR"/tools/*.py "$PKG_DIR"/bench/*.sh "$PKG_DIR"/bench/*.py "$PKG_DIR"/bench/*/src/* "$PKG_DIR"/wasm_smoke/src/* | awk -F: '{s+=$NF} END {print s+0}')
  echo "  internal machine names / paths in README, src, tools, bench, wasm_smoke: $n"; [ "$n" = 0 ] || fail "internal names"
  grep -q 'Unicode-3.0' "$README" || fail "README.md lacks the Unicode-3.0 attribution"
  grep -q 'Unicode-3.0' "$PKG_DIR/src/tables.pion" || fail "src/tables.pion lacks the Unicode-3.0 header"
  out=$($PY "$PKG_DIR/tools/gen_tables.py" "$AUDIT_OUT/ucd16" "$PKG_DIR/src/tables.pion" --check 2>&1) || fail "src/tables.pion differs from tools/gen_tables.py on the official 16.0.0 files"
  echo "  tools/gen_tables.py --check on vendored Unicode 16.0.0: $out" | sed "s#$PKG_DIR/##"
  grep -q 'packages/unicode_segment' "$ROOT_DIR/THIRD_PARTY_NOTICES.md" 2> /dev/null || info "INFO-1: $(title INFO-1)"

  echo "  Send probes (real pionc check --json, captured in scope/spawn), checked against README.md:"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\nunicode_segment = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  probe() { # <param type> <body using v>
    printf 'import "unicode_segment"\n\nfn probe(v : %s, world : World) -> Unit {\n%s\n}\n\n///|\npub fn main(world : World) -> Int {\n  0\n}\n' "$1" "$2" > "$P/src/main.pion"
    pionc check --json "$P" 2>&1 | $PY -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))' 2> /dev/null
  }
  c_send=" $($RD send_types) "
  c_not=" $($RD notsend_types) "
  for t in SegmentSpan SegmentLimits SegmentError String "Array[SegmentSpan]" "Array[String]"; do
    case "$t" in String) ty=String ;; "Array[String]") ty="Array[String]" ;; "Array[SegmentSpan]") ty="Array[unicode_segment::SegmentSpan]" ;; *) ty="unicode_segment::$t" ;; esac
    r=$(probe "$ty" '  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })')
    extra=""
    case "$c_send" in *" $t "*) [ "$r" = ok ] || { open_finding "P2-2: $(title P2-2)"; extra=" (README.md claims Send)"; } ;; esac
    case "$c_not" in *" $t "*)
      [ "$r" = ok ] && { extra=" (README.md says !Send, but it is Send)"; open_finding "P2-2: $(title P2-2)"; }
      m=$(probe "$ty" '  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let q = move v
  let _ = q.length() }) })')
      x=$(probe "$ty" '  let m = Mutex::new(v)
  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = m.with_lock(fn(a : '"$ty"') -> Int { a.length() }) }) })')
      extra="$extra move-into-spawn:$m Mutex::new(...)-into-spawn:$x"
      { [ "$m" = ok ] && [ "$x" = ok ]; } || open_finding "P2-2: $(title P2-2)"
      ;;
    esac
    printf '    %-20s %s%s\n' "$t" "$([ "$r" = ok ] && echo Send || echo "!Send ($r)")" "$extra"
  done
  # README.md's own concurrency example, verbatim
  awk '/^## Concurrency/{c=1} c&&/^```pion/{f=1;next} f&&/^```/{exit} f' "$README" > "$P/src/main.pion"
  printf '\n///|\npub fn main(world : World) -> Int {\n  count_in_worker(world, "a\\u{0301}b", unicode_segment::SegmentLimits::default())\n  0\n}\n' >> "$P/src/main.pion"
  if pionc build --release -o "$BIN/readme_worker" "$P" > "$AUDIT_OUT/readme_worker.log" 2>&1 && "$BIN/readme_worker"; then
    echo "  README.md count_in_worker example: compiles and runs"
  else
    head -3 "$AUDIT_OUT/readme_worker.log"; open_finding "P2-2: $(title P2-2)"
  fi
}

unit() {
  echo "==> unit: pionc fmt / check / test of packages/unicode_segment (count vs README.md) and of the audit package"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/unicode_segment"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/unicode_segment"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> "$AUDIT_OUT/unit_pkg.stderr"
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit_audit.json" 2> "$AUDIT_OUT/unit_audit.stderr"
  $PY - "$AUDIT_OUT/unit_pkg.json" "$AUDIT_OUT/unit_audit.json" "$($RD unit_pass)" "$($RD unit_total)" <<'PY' || fail "unit tests"
import json, sys
def tests(path, pkg):
    try:
        d = json.load(open(path))
    except ValueError:
        return []
    return [t for t in d.get("tests", []) if t.get("pkg") == pkg]
own = tests(sys.argv[1], "unicode_segment")
aud = tests(sys.argv[2], "unicode_segment_audit")
po = sum(1 for t in own if t["ok"])
pa = sum(1 for t in aud if t["ok"])
print("  packages/unicode_segment own tests: %d/%d pass (README.md: %s/%s)" % (po, len(own), sys.argv[3], sys.argv[4]))
print("  audit control tests (redteam_test.pion): %d/%d pass" % (pa, len(aud)))
for t in own + aud:
    if not t["ok"]:
        print("  FAIL  %s" % t["name"])
sys.exit(0 if own and aud and po == len(own) and pa == len(aud) and "%d/%d" % (po, len(own)) == "%s/%s" % (sys.argv[3], sys.argv[4]) else 1)
PY
  if sh "$ROOT_DIR/scripts/verify.sh" --allow-dirty packages/unicode_segment > "$AUDIT_OUT/verify.log" 2>&1; then
    echo "  scripts/verify.sh --allow-dirty packages/unicode_segment: PASS (--allow-dirty: the audit directory is uncommitted while it runs)"
  else
    tail -5 "$AUDIT_OUT/verify.log" | sed 's/^/    /'
    fail "scripts/verify.sh packages/unicode_segment"
  fi
}

tables() { # <pkg dir> [quiet]
  T="$AUDIT_OUT/tab" && rm -rf "$T" && mkdir -p "$T/pkg/src" "$T/probe/src"
  cp "$1/pion.toml" "$T/pkg/"
  for f in "$1"/src/*.pion; do case "$f" in *_test.pion) ;; *) cp "$f" "$T/pkg/src/" ;; esac; done
  cp "$AUDIT_DIR/tabprobe/export.pion.in" "$T/pkg/src/zz_audit_export.pion"
  cp "$AUDIT_DIR/tabprobe/main.pion.in" "$T/probe/src/main.pion"
  printf '[package]\nname = "tabprobe"\nversion = "0.1.0"\n\n[dependencies]\nunicode_segment = { path = "../pkg" }\n' > "$T/probe/pion.toml"
  pionc build --release -o "$T/tabprobe" "$T/probe" > "$T/build.log" 2>&1 || { cat "$T/build.log" | head -5; return 1; }
  "$T/tabprobe" > "$T/dump.txt" || return 1
  if [ -n "${2:-}" ]; then $PY "$AUDIT_DIR/diff/ucd.py" tables "$1/src/tables.pion" "$T/dump.txt" > /dev/null; else $PY "$AUDIT_DIR/diff/ucd.py" tables "$1/src/tables.pion" "$T/dump.txt"; fi
}

tables_section() {
  echo "==> tables: the package's own lookup (BMP 2-level pages + SMP base-64 binary search) for all 1,114,112 code points"
  tables "$PKG_DIR" || fail "table lookup differs from the Unicode 16.0.0 UCD"
}

conformance() {
  echo "==> conformance: official Unicode 16.0.0 GraphemeBreakTest / WordBreakTest / SentenceBreakTest (every vector, 4 modes)"
  for m in $MODES; do
    # shellcheck disable=SC2046
    $(runner $m) dump "$C/ucd.cases" > "$AUDIT_OUT/pion_ucd_$m.txt" 2> "$AUDIT_OUT/pion_ucd_$m.err" || fail "ucd dump: $m exited non-zero"
  done
  $CMP ucd "$C/ucd.expect" "$AUDIT_OUT/pion_ucd_native_rel.txt" || fail "official UAX #29 16.0.0 vector failure"
  $PY "$AUDIT_DIR/diff/wbref.py" selftest || fail "independent word-boundary reference does not reproduce WordBreakTest"
  cp "$AUDIT_OUT/pion_ucd_native_rel.txt" "$AUDIT_OUT/pion_ucd.txt"
  for g in G W S; do
    want=$($RD "$(echo $g | tr GWS gws)b")
    got=$($CMP ucd "$C/ucd.expect" "$AUDIT_OUT/pion_ucd.txt" | awk -v t=$g '($1=="GraphemeBreakTest"&&t=="G")||($1=="WordBreakTest"&&t=="W")||($1=="SentenceBreakTest"&&t=="S"){print $2 "/" $4}')
    [ "$got" = "$want" ] || { echo "  $g: $got vs README.md $want"; open_finding "P2-2: $(title P2-2)"; }
  done
}

oracles() {
  echo "==> oracles: Rust unicode-segmentation =1.13.3 (requested oracle, Unicode 17.0.0) and =1.12.0 (Unicode 16.0.0)"
  for g in ucd named fuzz; do
    [ -f "$AUDIT_OUT/pion_$g.txt" ] || "$BIN/aud_rel" dump "$C/$g.cases" > "$AUDIT_OUT/pion_$g.txt" || fail "dump $g"
    "$BIN/rust12" "$C/$g.cases" > "$AUDIT_OUT/rust12_$g.txt" || fail "oracle 1.12.0 failed on $g"
    "$BIN/rust13" "$C/$g.cases" > "$AUDIT_OUT/rust13_$g.txt" || fail "oracle 1.13.3 failed on $g"
    echo "  [$g]"
    $CMP rust "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" "$AUDIT_OUT/rust12_$g.txt" | cut -c1-260 || fail "unexplained difference from Rust 1.12.0 ($g)"
    out=$($CMP rust "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" "$AUDIT_OUT/rust13_$g.txt")
    r=$?
    printf '%s\n' "$out" | cut -c1-260
    [ $r = 0 ] || fail "unexplained difference from Rust 1.13.3 ($g)"
    case "$out" in *" 0 Unicode 16->17 drift"*) ;; *) info "INFO-3: $(title INFO-3)" ;; esac
    for o in "$AUDIT_OUT/rust12_$g.txt"; do
      $CMP rust "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" "$o" | grep -q ' 0 Rust word-boundary defect' || info "INFO-9: $(title INFO-9)"
    done
  done
  $CMP inv "$AUDIT_OUT/pion_ucd.txt" "$AUDIT_OUT/pion_named.txt" "$AUDIT_OUT/pion_fuzz.txt" || fail "in-process invariant violated"
  v13=$(sed -n 's/^V //p' "$AUDIT_OUT/rust13_named.txt" | head -1)
  claim=$($RD rust_unicode)
  lockv=$(sed -n '/name = "unicode-segmentation"/{n;s/version = "\(.*\)"/\1/p;}' "$PKG_DIR/bench/rust_bench/Cargo.lock")
  echo "  README.md: 'unicode-segmentation 1.13.3 (Unicode ${claim:-?} aligned)'; locked crate reports Unicode $v13; bench/rust_bench/Cargo.lock pins $lockv"
  if [ -n "$claim" ] && [ "$claim" != "$v13" ] && [ "$lockv" = 1.13.3 ]; then open_finding "P2-1: $(title P2-1)"; fi
  # the README differential corpus itself, against both oracles
  $PY - "$PKG_DIR/bench/gen_corpus.py" "$C/readme_diff.cases" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("g", sys.argv[1]); g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
with open(sys.argv[2], "w") as f:
    for i, s in enumerate(g.DIFF_CASES):
        f.write("readme_%02d\t%s\n" % (i, s.encode().hex() or "-"))
PY
  "$BIN/aud_rel" dump "$C/readme_diff.cases" > "$AUDIT_OUT/pion_readme.txt"
  "$BIN/rust13" "$C/readme_diff.cases" > "$AUDIT_OUT/rust13_readme.txt"
  n=$($CMP rust "$C/readme_diff.cases" "$AUDIT_OUT/pion_readme.txt" "$AUDIT_OUT/rust13_readme.txt" | sed -n 's/.*comparisons, \([0-9]*\) identical inputs.*/\1/p')
  echo "  README differential corpus (bench/gen_corpus.py DIFF_CASES) vs 1.13.3: $n identical (README.md: $($RD diff_cases))"
  [ "$n" = "$($RD diff_cases)" ] || open_finding "P2-2: $(title P2-2)"
}

determinism() {
  echo "==> determinism: every corpus and the SegmentLimits sweep byte-identical in native / wasm32 x debug / release"
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/pion_ucd_native_rel.txt" "$AUDIT_OUT/pion_ucd_$m.txt" || fail "ucd: $m differs from native_rel"
  done
  for g in named fuzz; do
    for m in $MODES; do
      # shellcheck disable=SC2046
      $(runner $m) dump "$C/$g.cases" > "$AUDIT_OUT/pion_${g}_$m.txt" 2> "$AUDIT_OUT/pion_${g}_$m.err" || fail "$g: $m exited non-zero"
    done
    for m in native_dbg wasm_dbg wasm_rel; do
      cmp -s "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_${g}_$m.txt" || fail "$g: $m differs from native_rel"
    done
  done
  for m in $MODES; do
    # shellcheck disable=SC2046
    $(runner $m) api > "$AUDIT_OUT/api_$m.txt" 2>&1 || fail "api: $m exited non-zero"
  done
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/api_native_rel.txt" "$AUDIT_OUT/api_$m.txt" || fail "api sweep: $m differs from native_rel"
  done
  tot=0
  for g in ucd named fuzz; do tot=$((tot + $(grep -c '^=' "$AUDIT_OUT/pion_${g}_native_rel.txt"))); done
  echo "  $tot inputs x (G/W/U/S + graphemes/words/unicode_words/sentences + count + 9 x 8 limit probes + 3 cursor APIs at every byte -3..n+3), $(wc -l < "$AUDIT_OUT/api_native_rel.txt" | tr -d ' ') limit-sweep lines: 4 modes byte-identical"
  # documented SegmentLimits semantics: negative -> Err even on "", 0 accepts only inputs with 0 segments
  grep -q '^in0 n=0 lim(-1,0) -1 -1 -1 -1 -1 -1 -1 -1 -1$' "$AUDIT_OUT/api_native_rel.txt" || fail "negative limit on empty input not rejected"
  grep -q '^in5 n=6 lim(100,0) -1 -1 -1 -1 -1 0 0 -1 -1$' "$AUDIT_OUT/api_native_rel.txt" && info "INFO-2: $(title INFO-2)"
}

dos() {
  echo "==> dos: UAX #29 O(n^2) classics at N and 4N (100,000+ units), native --release timed in-process, wasm32 --release must agree"
  out=$($PY "$AUDIT_DIR/diff/dos.py" "$BIN/aud_rel" "node $WASM_RT $BIN/aud_rel.wasm" "$BIN/rust13")
  r=$?
  printf '%s\n' "$out" | grep -v '^OPENIDS\|^INFOIDS' | cut -c1-200
  for id in $(printf '%s\n' "$out" | grep '^OPENIDS' | cut -d' ' -f2-); do open_finding "$id: $(title "$id")"; done
  for id in $(printf '%s\n' "$out" | grep '^INFOIDS' | cut -d' ' -f2-); do info "$id: $(title "$id")"; done
  [ $r = 0 ] || fail "DoS bomb crashed / diverged / non-linear (see above)"
}

smoke() {
  echo "==> smoke: packages/unicode_segment/wasm_smoke in 4 modes vs README.md"
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
    got=$(SHA "$AUDIT_OUT/smoke_$m.txt")
    echo "  $m sha256 $got"
    [ "$got" = "$want" ] || fail "wasm_smoke $m sha256 != README.md ($want)"
  done
  [ "$(cat "$AUDIT_OUT/smoke_native_rel.txt")" = "$($RD smoke_stdout)" ] || fail "wasm_smoke stdout != README.md"
  sed 's/^/    /' "$AUDIT_OUT/smoke_native_rel.txt"
  for k in dbg rel; do
    got=$(wc -c < "$BIN/smoke_$k.wasm" | tr -d ' ')
    want=$($RD wasm_$k)
    echo "  wasm32 $k size: $got B (README.md: $want B; path-dependent, tolerance 2 %)"
    [ $(((got - want) * (got - want) * 2500)) -le $((want * want)) ] || info "INFO-6: $(title INFO-6)"
  done
}

bench() {
  echo "==> bench: independent re-run of bench/run_bench.sh (differential + 2 corpora x 5 rounds), README.md claims"
  sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || { tail -20 "$AUDIT_OUT/bench.log"; fail "bench/run_bench.sh failed"; return; }
  grep -E '^(PASS|FAIL)|^\| `|SHA-256 verified' "$AUDIT_OUT/bench.log" | sed 's/^/    /'
  shas=$(sed -nE 's/.*SHA-256 verified identical across all implementations and rounds: `([0-9a-f]{64})`.*/\1/p' "$AUDIT_OUT/bench.log" | tr '\n' ' ')
  [ "$shas" = "$($RD sha_multi) $($RD sha_tech) " ] || fail "benchmark stdout SHA-256 ($shas) != README.md"
  $PY - "$AUDIT_OUT/bench.log" "$($RD speedup_multi)" "$($RD speedup_tech)" <<'PY' || info "INFO-5: $(title INFO-5)"
import os, re, sys
t = open(sys.argv[1]).read()
rows = [l for l in t.split("\n") if l.startswith("| `pion_segment`")]
sp = [float(re.search(r"([0-9.]+)x", r.split("|")[-2]).group(1)) for r in rows]
claims = [float(sys.argv[2]), float(sys.argv[3])]
load = os.popen("cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg").read().strip()
print("  measured speedups vs Rust %s, README.md %s (machine load: %s)" % (sp, claims, load))
sys.exit(0 if len(sp) == 2 and all(0.75 * b <= a <= 1.33 * b for a, b in zip(sp, claims)) else 1)
PY
}

inject() {
  echo "==> inject: realistic defects injected into copies of packages/unicode_segment/src; the gate must fail on each"
  rm -rf "$AUDIT_OUT/inject" && mkdir -p "$AUDIT_OUT/inject"
  $PY "$AUDIT_DIR/diff/inject.py" "$PKG_DIR" "$AUDIT_OUT/inject" > "$AUDIT_OUT/inject/list.txt"
  caught=0
  total=0
  while read -r n dir desc; do
    total=$((total + 1))
    if [ "$dir" = SKIP ]; then
      echo "  [$n] SKIP (target text not present any more: $desc)"
      continue
    fi
    A="$AUDIT_OUT/inject/m$n/aud"
    mkdir -p "$A" && cp -R "$AUDIT_DIR/src" "$AUDIT_DIR/redteam_test.pion" "$A/"
    printf '[package]\nname = "unicode_segment_audit"\nversion = "0.1.0"\n\n[dependencies]\nunicode_segment = { path = "%s" }\n' "$dir" > "$A/pion.toml"
    if ! pionc build --release -o "$A/bin" "$A" > "$A/build.log" 2>&1; then
      echo "  [$n] mutant does not compile ($desc)"
      fail "mutant $n did not build"
      continue
    fi
    hit=""
    for g in ucd named fuzz; do "$A/bin" dump "$C/$g.cases" > "$A/$g.txt" 2>&1 || hit="$hit crash:$g"; done
    $CMP ucd "$C/ucd.expect" "$A/ucd.txt" > /dev/null 2>&1 || hit="$hit uax29-vectors"
    $CMP inv "$A/ucd.txt" "$A/named.txt" "$A/fuzz.txt" > /dev/null 2>&1 || hit="$hit invariants"
    for g in named fuzz; do $CMP rust "$C/$g.cases" "$A/$g.txt" "$AUDIT_OUT/rust12_$g.txt" > /dev/null 2>&1 || hit="$hit rust12:$g"; done
    tables "$dir" quiet > /dev/null 2>&1 || hit="$hit tables"
    if [ -n "$hit" ]; then
      caught=$((caught + 1))
      echo "  [$n] caught by$hit: $desc"
    else
      echo "  [$n] MISSED: $desc"
      fail "injected bug $n not caught"
    fi
  done < "$AUDIT_OUT/inject/list.txt"
  echo "  injected defects caught: $caught/$total"
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
  left=""
  if git -C "$ROOT_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    left=$(git -C "$ROOT_DIR" status --porcelain --ignored -- "$PKG_DIR" | grep -v '^?? packages/unicode_segment/audit/$')
  else
    echo "  (not a git checkout: worktree-cleanliness check skipped)"
  fi
  [ -z "$left" ] || { printf '%s\n' "$left" | head; fail "audit left files in the repository"; }
  echo "EXIT=$RC"
}

case "$SECTION" in
  all)
    build
    static
    unit
    tables_section
    conformance
    oracles
    determinism
    dos
    smoke
    bench
    inject
    ;;
  build | static | unit | conformance | oracles | determinism | dos | smoke | bench | inject) "$SECTION" ;;
  tables) tables_section ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
summary
exit $RC
