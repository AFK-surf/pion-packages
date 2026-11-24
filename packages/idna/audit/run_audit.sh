#!/bin/sh
# One-shot red-team audit for packages/idna (RT-idna, see REPORT.md).
#   sh packages/idna/audit/run_audit.sh [all|build|static|unit|cases|determinism|oracles|idnatest|dos|smoke|bench|inject]
# (single sections need a previous `build`)
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), cargo (Rust idna =1.1.0 oracle, --locked, crate cache
# when offline), python3 (stdlib only). Unicode 16.0.0 data is vendored (gzip) in audit/ucd; network not needed.
# Artifacts go to $AUDIT_OUT (default /private/tmp/pion-idna-audit, the real path of /tmp on macOS, because the
# wasm32 runner resolves symlinks). Nothing is written inside the repository.
# Every number README.md claims (Send lists, unit test count, wasm_smoke stdout / SHA-256 / sizes, differential
# and IdnaTestV2 counts, benchmark SHA-256 and speedups, "Moderately Restrictive") is parsed from README.md at
# run time (diff/readme.py); nothing about it is hard-coded here.
#
# Exit status: 1 while any P0 condition reproduces (crash / trap / timeout on a bomb no finding explains, a
# native-vs-wasm32 or debug-vs-release divergence, a divergence from the independent model, Rust idna 1.1.0 or
# IdnaTestV2 that no finding explains, a failing control case, a wasm_smoke hash that differs from README.md, a
# benchmark whose outputs are not byte-identical, or an injected bug the control cases miss). Open P1/P2 findings
# (and README drift) are listed as OPEN and fail the run only with STRICT=1. Repository-root files
# (BENCHMARKS.md, catalog.json, README.md, THIRD_PARTY_NOTICES.md) are only ever reported as INFO.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-idna-audit}
if [ ! -d /private/tmp ] && [ "$AUDIT_OUT" = /private/tmp/pion-idna-audit ]; then AUDIT_OUT=/tmp/pion-idna-audit; fi
BIN="$AUDIT_OUT/bin"
C="$AUDIT_OUT/corpus"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
STRICT=${STRICT:-0}
FUZZ_N=${FUZZ_N:-3000}
README="$PKG_DIR/README.md"
PY="python3 -I"
CMP="$PY $AUDIT_DIR/diff/compare.py"
RD="$PY $AUDIT_DIR/diff/readme.py $README"
MODES="native_dbg native_rel wasm_dbg wasm_rel"
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
    P1-1) echo "NFC_Quick_Check=Maybe gap: 19 code points skip normalisation; to_ascii emits a second, non-NFC A-label it rejects itself" ;;
    P1-2) echo "display_domain returns the raw attacker-controlled input (RLO, U+2044 ...) as \`display\` for invalid IDNs" ;;
    P1-3) echo "single-script Latin homoglyphs (ɡ ɑ ᴏ ...) are displayed as Unicode (gooɡle.com, ɑpple.com)" ;;
    P1-4) echo "CJK slash / dash look-alikes next to Latin (ノ 丿 一 ー) are displayed: google.comノevil.com" ;;
    P1-5) echo "skeleton / are_confusable ignore UTS #39 16.0 Default_Ignorable removal (pay<ZWSP>pal !~ paypal)" ;;
    P1-6) echo "skeleton / are_confusable: unbounded input + quadratic mark sort (200 KB -> 10 s CPU)" ;;
    P2-1) echo "UTS #46 V4 missing: decoded label starting with xn-- accepted when CheckHyphens=false" ;;
    P2-2) echo "ignore_invalid_punycode also suppresses the non-ASCII xn-- error and skips label validation" ;;
    P2-3) echo "ContextO KATAKANA MIDDLE DOT ignores Han below U+3040 (々・ rejected)" ;;
    P2-4) echo "transitional_processing: ẞ (mapped to the deviation ß) gives xn--fa-hia / DisallowedCodePoint, IdnaTestV2 wants fass" ;;
    P2-5) echo "whole-script confusable test needs a pure-ASCII skeleton: Cyrillic соӧр / ѕсһӧн displayed" ;;
    P2-6) echo "combining overlays U+0335..U+0338 displayed (google.com̸evil.com)" ;;
    P2-7) echo "skeleton is not bidiSkeleton(LTR, X): RTL strings are mapped in logical order" ;;
    P2-8) echo "numbering systems from merged Nd runs: U+116D0..116E3 (two systems) counted as one" ;;
    P2-9) echo "NFC of the whole domain runs before per-label limits: raised max_input_bytes -> quadratic before LimitExceeded" ;;
    P2-10) echo "README.md claims not reproduced (Moderately Restrictive, IdnaTestV2 546/546, Send list, sizes, ...)" ;;
    *) echo "(see REPORT.md)" ;;
  esac
}
runner() {
  case "$1" in
    native_dbg) echo "$BIN/idna_audit_dbg" ;;
    native_rel) echo "$BIN/idna_audit_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/idna_audit_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/idna_audit_rel.wasm" ;;
  esac
}
build4() { # <pkg_dir> <prefix>
  pionc build -o "$2_dbg" "$1" > /dev/null &&
    pionc build --release -o "$2_rel" "$1" > /dev/null &&
    pionc build --target wasm32 -o "$2_dbg.wasm" "$1" > /dev/null &&
    pionc build --release --target wasm32 -o "$2_rel.wasm" "$1" > /dev/null
}

build() {
  echo "==> build: idna_audit in 4 modes, Rust idna =1.1.0 oracle (cargo --locked), corpora, Unicode 16.0.0 data"
  pionc fmt --check "$AUDIT_DIR" > /dev/null || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  build4 "$AUDIT_DIR" "$BIN/idna_audit" || fail "build idna_audit (4 modes)"
  M="$AUDIT_DIR/diff/rust/Cargo.toml"
  { CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline --manifest-path "$M" 2> /dev/null ||
    CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --manifest-path "$M"; } || fail "cargo build oracle"
  cp "$AUDIT_OUT/rust-target/release/idna_audit_oracle" "$BIN/oracle"
  rm -rf "$C" && echo "  corpus: $($PY "$AUDIT_DIR/diff/gen.py" "$C" "$FUZZ_N" | awk '{print $1 " IdnaTestV2 sources, " $2 " named adversarial, " $3 " fuzz"}')"
  mkdir -p "$AUDIT_OUT/ucd"
  for f in "$AUDIT_DIR"/ucd/*.gz; do gunzip -c "$f" > "$AUDIT_OUT/ucd/$(basename "$f" .gz)"; done
  $PY "$AUDIT_DIR/diff/model.py" selftest | sed 's/^/  /' || fail "reference model self-test (NFC / Punycode vs Python stdlib)"
  echo "  $(pionc --version) | node $(node --version) | $(cargo --version) | idna =1.1.0 | python $(python3 -c 'import sys;print(sys.version.split()[0])')"
}

static() {
  echo "==> static: license, dependencies, extern \"C\", World, module-level state, floats, internal names, Unicode data, Send"
  SRC=$(cat "$PKG_DIR"/src/*.pion | grep -v '^ *//')
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
  n=$(printf '%s\n' "$SRC" | grep -cE '^(pub )?let [A-Za-z_0-9]+ *: *(Array|Map|Bytes|StringBuilder)\[?')
  echo "  module-level Array / Map / Bytes / StringBuilder: $n"; [ "$n" = 0 ] || fail "module-level mutable container"
  n=$(printf '%s\n' "$SRC" | grep -cE '^(pub )?let [A-Za-z_0-9]+ *: *FixedArray')
  echo "  module-level FixedArray tables: $n (init_consts frees them as frozen immortal constants, SPEC.md pion_rc_immortalize)"
  n=$(printf '%s\n' "$SRC" | grep -cE 'Double|Float|to_double|\.to_float')
  echo "  Double / Float: $n"; [ "$n" = 0 ] || fail "floating point in src"
  n=$(grep -ciwE 'tokyo|pvg-office|afk-ap|gt1|gt2|office-host|mac-studio|stillfail|/Users|/home' "$README" "$PKG_DIR"/src/*.pion "$PKG_DIR"/tools/*.py "$PKG_DIR"/bench/*.sh "$PKG_DIR"/bench/*.py "$PKG_DIR"/bench/*/src/* "$PKG_DIR"/wasm_smoke/src/* | awk -F: '{s+=$NF} END {print s+0}')
  echo "  internal machine names / paths in README, src, tools, bench: $n"; [ "$n" = 0 ] || fail "internal names"
  uv=$($RD unicode_version)
  echo "  README.md Unicode version: $uv; vendored data: $(zcat < "$AUDIT_DIR/ucd/IdnaMappingTable.txt.gz" | sed -n 's/^# Version: //p' | head -1)$(zcat < "$AUDIT_DIR/ucd/confusables.txt.gz" | sed -n 's/^# Version: \(.*\)/ \/ confusables \1/p' | head -1)"
  grep -q 'Unicode 16.0.0' "$PKG_DIR/tools/gen_tables.py" || fail "tools/gen_tables.py does not name Unicode 16.0.0"
  grep -q 'Unicode-3.0' "$README" || fail "README.md lacks the Unicode-3.0 attribution"
  for f in tables_uts46.pion tables_uts39.pion; do grep -q 'Unicode-3.0' "$PKG_DIR/src/$f" || fail "src/$f lacks the Unicode-3.0 header"; done
  rm -rf "$AUDIT_OUT/regen" && mkdir -p "$AUDIT_OUT/regen"
  $PY "$PKG_DIR/tools/gen_tables.py" "$AUDIT_OUT/ucd" "$AUDIT_OUT/regen" > /dev/null || fail "tools/gen_tables.py failed on Unicode 16.0.0 data"
  for f in tables_uts46.pion tables_uts39.pion; do
    if cmp -s "$PKG_DIR/src/$f" "$AUDIT_OUT/regen/$f"; then echo "  src/$f regenerated byte-identically from the official 16.0.0 files"
    else fail "src/$f differs from tools/gen_tables.py output on Unicode 16.0.0 data"; fi
  done
  $PY "$AUDIT_DIR/diff/model.py" nfcqc || fail "NFC quick-check data inconsistent"
  grep -q 'packages/idna' "$ROOT_DIR/THIRD_PARTY_NOTICES.md" 2> /dev/null || info "root THIRD_PARTY_NOTICES.md does not list packages/idna's UCD / IDNA / confusables data (root file: release integration, not this branch)"
  echo "  Send probe: public values captured in spawn, checked against README.md"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\nidna = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  c_send=" $($RD send_types) "
  c_not=" $($RD notsend_types) "
  probe() { # <type> <body using v>
    printf 'import "idna"\n\nfn probe(v : %s, world : World) -> Unit {\n%s\n}\n\n///|\npub fn main(world : World) -> Int {\n  0\n}\n' "$1" "$2" > "$P/src/main.pion"
    pionc check --json "$P" 2>&1 | $PY -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))' 2>/dev/null
  }
  for t in IdnaOptions IdnaLimits DisplayPolicy IdnaErrorKind IdnaError UnicodeResult Script SpoofReason DisplayDecision; do
    r=$(probe "idna::$t" '  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })')
    extra=""
    case "$c_send" in *" $t "*) [ "$r" = ok ] || { open_finding "P2-10: $(title P2-10)"; extra=" (README.md claims Send)"; } ;; esac
    case "$c_not" in *" $t "*)
      [ "$r" = ok ] && extra=" (README.md says !Send, but it is Send: INFO)"
      m=$(probe "idna::$t" '  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let q = move v
  let _ = q }) })')
      f=$(probe "idna::$t" '  let d = v.display
  let a = v.ascii
  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = d + a }) })')
      extra="$extra move-into-spawn:$m String-fields:$f"
      [ "$m" = ok ] && [ "$f" = ok ] || open_finding "P2-10: $(title P2-10)"
      ;;
    esac
    printf '    %-22s %s%s\n' "$t" "$([ "$r" = ok ] && echo Send || echo "!Send ($r)")" "$extra"
  done
  for t in $c_send $c_not; do
    case " IdnaOptions IdnaLimits DisplayPolicy IdnaErrorKind IdnaError UnicodeResult Script SpoofReason DisplayDecision " in
      *" $t "*) ;; *) open_finding "P2-10: $(title P2-10)"; echo "    README.md lists unknown type $t" ;; esac
  done
  if pionc build --release -o "$BIN/concurrency" "$AUDIT_DIR/probe" > "$AUDIT_OUT/conc_build.log" 2>&1; then
    out=$("$BIN/concurrency") || fail "concurrency probe exited non-zero"
    echo "  $out (8 threads, to_ascii / to_unicode / display_domain / skeleton against one-thread results)"
    case "$out" in *"mismatches=0"*) ;; *) fail "concurrent results differ" ;; esac
  else
    cat "$AUDIT_OUT/conc_build.log" | head -5
    fail "concurrency probe does not build"
  fi
}

unit() {
  echo "==> unit: pionc fmt/check/test of packages/idna (count vs README.md), pionc test of the audit package"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/idna"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/idna"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> /dev/null
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit_audit.json" 2> "$AUDIT_OUT/unit_audit.stderr"
  $PY - "$AUDIT_OUT/unit_pkg.json" "$AUDIT_OUT/unit_audit.json" "$($RD unit_pass)" "$($RD unit_total)" <<'PY' || fail "unit tests"
import json, sys
pkg = json.load(open(sys.argv[1]))
own = [t for t in pkg["tests"] if t.get("pkg") == "idna"]
bad = sum(1 for t in own if not t["ok"])
print("  packages/idna own tests: %d/%d pass (README.md: %s/%s)" % (len(own) - bad, len(own), sys.argv[3], sys.argv[4]))
d = json.load(open(sys.argv[2]))
n = {"PASS": 0, "OPEN": 0, "FAIL": 0}
for t in d["tests"]:
    if t.get("pkg") != "idna_audit":
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

cases() {
  echo "==> cases: red-team + control cases, one process per case, in all 4 modes"
  names=$("$BIN/idna_audit_rel" list)
  for m in $MODES; do
    : > "$AUDIT_OUT/cases_$m.txt"
    for c in $names; do
      # shellcheck disable=SC2046
      raw=$($(runner $m) case "$c" 2>&1)
      out=$(printf '%s\n' "$raw" | grep -E '^(PASS|FAIL) ' | tail -1)
      [ -n "$out" ] || out="FAIL $c :: ABORT ($(printf '%s\n' "$raw" | grep -m1 'pion panic' || printf '%s\n' "$raw" | tail -1))"
      echo "$out" >> "$AUDIT_OUT/cases_$m.txt"
    done
    cut -d' ' -f1,2 "$AUDIT_OUT/cases_$m.txt" > "$AUDIT_OUT/status_$m.txt"
    echo "  $m: $(grep -c '^PASS' "$AUDIT_OUT/cases_$m.txt")/$(echo "$names" | wc -w | tr -d ' ') pass"
  done
  sed 's/^/    /' "$AUDIT_OUT/cases_native_rel.txt" | cut -c1-220
  for m in native_dbg wasm_dbg wasm_rel; do # timing cases carry microseconds: compare PASS/FAIL per case only
    cmp -s "$AUDIT_OUT/status_native_rel.txt" "$AUDIT_OUT/status_$m.txt" || { diff "$AUDIT_OUT/status_native_rel.txt" "$AUDIT_OUT/status_$m.txt" | head -6; fail "case results of $m differ from native_rel"; }
  done
  grep -q 'ABORT' "$AUDIT_OUT"/cases_*.txt && fail "a case aborted (panic / trap)"
  grep -q '^FAIL control_' "$AUDIT_OUT/cases_native_rel.txt" && fail "control case failing"
  for f in $(grep '^FAIL redteam_' "$AUDIT_OUT/cases_native_rel.txt" | awk '{print $2}'); do
    id=$(echo "$f" | sed -E 's/redteam_p([0-9])_([0-9]+)_.*/P\1-\2/')
    open_finding "$id: $(title "$id")"
    case "$f" in redteam_p0_*) fail "P0 red-team case $f" ;; esac
  done
}

determinism() {
  echo "==> determinism: corpora, API sweep and in-budget DoS bombs in all 4 modes must be byte-identical"
  for g in idnatest named fuzz; do
    for m in $MODES; do
      # shellcheck disable=SC2046
      $(runner $m) dump "$C/$g.cases" > "$AUDIT_OUT/pion_${g}_$m.txt" 2> "$AUDIT_OUT/pion_${g}_$m.err" || fail "$g: $m exited non-zero ($(tail -1 "$AUDIT_OUT/pion_${g}_$m.err"))"
    done
    for m in native_dbg wasm_dbg wasm_rel; do
      $CMP same "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_${g}_$m.txt" || fail "$g: $m differs from native_rel"
    done
    cp "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_$g.txt"
    echo "  [$g] $(wc -l < "$C/$g.cases" | tr -d ' ') inputs x 16 entry points, $(wc -l < "$AUDIT_OUT/pion_$g.txt" | tr -d ' ') dump lines, sha256 $(shasum -a 256 "$AUDIT_OUT/pion_$g.txt" | cut -c1-16), 4 modes byte-identical"
  done
  for m in $MODES; do
    # shellcheck disable=SC2046
    $(runner $m) api > "$AUDIT_OUT/api_$m.txt" 2>&1 || fail "api: $m exited non-zero"
  done
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/api_native_rel.txt" "$AUDIT_OUT/api_$m.txt" || fail "IdnaLimits sweep: $m differs from native_rel"
  done
  echo "  [api] IdnaLimits sweep: $(wc -l < "$AUDIT_OUT/api_native_rel.txt" | tr -d ' ') lines, 4 modes byte-identical"
  $PY "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos" --list-only > /dev/null
  n=0
  for f in "$AUDIT_OUT"/dos/b0*.bomb "$AUDIT_OUT"/dos/b1[0-6].bomb "$AUDIT_OUT"/dos/b20.bomb; do
    for m in $MODES; do
      # shellcheck disable=SC2046
      $(runner $m) bomb "$f" > "$AUDIT_OUT/bomb_$m.txt" 2>&1 || fail "$(basename "$f"): $m exited non-zero"
    done
    for m in native_dbg wasm_dbg wasm_rel; do
      cmp -s "$AUDIT_OUT/bomb_native_rel.txt" "$AUDIT_OUT/bomb_$m.txt" || fail "$(basename "$f"): $m differs from native_rel"
    done
    n=$((n + 1))
  done
  echo "  [dos] $n bombs that finish within budget, 4 modes byte-identical"
}

oracles() {
  echo "==> oracles: independent Python model (UTS #46 / NFC / RFC 3492 / UTS #39 from Unicode 16.0.0), Rust idna =1.1.0"
  for g in idnatest named fuzz; do
    $PY "$AUDIT_DIR/diff/model.py" dump "$C/$g.cases" > "$AUDIT_OUT/model_$g.txt" || fail "model crashed on $g"
    out=$($CMP model "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" "$AUDIT_OUT/model_$g.txt" 2>&1)
    r=$?
    echo "  [$g]"
    printf '%s\n' "$out" | grep -v '^FINDINGS' | cut -c1-230
    [ $r = 0 ] || fail "unexplained divergence from the reference model ($g)"
    "$BIN/oracle" "$C/$g.cases" > "$AUDIT_OUT/rust_$g.txt" || fail "oracle failed on $g"
    out=$($CMP rust "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" "$AUDIT_OUT/rust_$g.txt" 2>&1)
    r=$?
    printf '%s\n' "$out" | grep -v '^FINDINGS' | cut -c1-230
    [ $r = 0 ] || fail "unexplained divergence from Rust idna 1.1.0 ($g)"
  done
  agree=$($CMP rust "$C/idnatest.cases" "$AUDIT_OUT/pion_idnatest.txt" "$AUDIT_OUT/rust_idnatest.txt" 2> /dev/null | sed -n 's/.*identical U+N results: \([0-9]*\)\/\([0-9]*\).*/\1 \2/p')
  set -- $agree
  # the README counts the 6,387 well-formed lines; the 2 lines with lone surrogates agree too (both reject)
  echo "  IdnaTestV2 inputs where Pion and Rust agree (U + N): $1/$2 incl. 2 ill-formed (README.md: $($RD rust_agree)/$($RD rust_total) well-formed)"
  [ "$(( $1 - 2 ))/$(( $2 - 2 ))" = "$($RD rust_agree)/$($RD rust_total)" ] || open_finding "P2-10: $(title P2-10)"
}

idnatest() {
  echo "==> idnatest: official Unicode 16.0.0 IdnaTestV2.txt (toUnicode, toAsciiN, toAsciiT) against Pion"
  out=$($PY "$AUDIT_DIR/diff/idnatest.py" "$AUDIT_OUT/pion_idnatest.txt")
  r=$?
  printf '%s\n' "$out" | grep -v '^FINDINGS\|^VALID_ALL' | cut -c1-230
  [ $r = 0 ] || fail "IdnaTestV2 failure no finding explains"
  for id in $(printf '%s\n' "$out" | grep '^FINDINGS' | cut -d' ' -f2-); do open_finding "$id: $(title "$id")"; done
  set -- $(printf '%s\n' "$out" | grep '^VALID_ALL' | cut -d' ' -f2-)
  echo "  all-valid vectors (empty status in every column): $1/$2 (README.md: $($RD idnatest_valid)/$($RD idnatest_valid_total))"
  [ "$1/$2" = "$($RD idnatest_valid)/$($RD idnatest_valid_total)" ] || open_finding "P2-10: $(title P2-10)"
  case "$($RD restrictive)" in
    Moderately)
      # UTS #39 Moderately Restrictive allows Latin + any Recommended script except Cyrillic / Greek
      nm=$(grep "	$(printf 'shop\340\271\204\340\270\227\340\270\242.com' | od -An -tx1 | tr -d ' \n')\$" "$C/named.cases" | cut -f1)
      line=$(awk -v n="=$nm" '$0==n{f=1;next} f&&/^D /{print;exit}' "$AUDIT_OUT/pion_named.txt")
      echo "  README.md says 'UTS #39 Moderately Restrictive'; Latin+Thai label shopไทย.com ($nm) -> $line"
      case "$line" in "D 1 MixedScript"*) open_finding "P2-10: $(title P2-10)" ;; esac
      ;;
  esac
}

dos() {
  echo "==> dos: 20 bombs, native --release and wasm32 --release, fresh process each (budget: time, RSS <= 512 MiB)"
  out=$($PY "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos" "$BIN/idna_audit_rel" "node $WASM_RT $BIN/idna_audit_rel.wasm")
  r=$?
  printf '%s\n' "$out" | grep -v '^OPENIDS' | cut -c1-230
  for id in $(printf '%s\n' "$out" | grep '^OPENIDS' | cut -d' ' -f2-); do
    open_finding "$id: $(title "$id")"
  done
  [ $r = 0 ] || fail "DoS bomb crashed / trapped / diverged / over budget without an open finding (see above)"
}

smoke() {
  echo "==> smoke: packages/idna/wasm_smoke in 4 modes vs README.md"
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
  for k in dbg rel; do
    got=$(wc -c < "$BIN/smoke_$k.wasm" | tr -d ' ')
    want=$($RD wasm_$k)
    # the wasm32 binary embeds absolute source paths, so its size depends on the checkout path: tolerance 1 %
    echo "  wasm32 $k size: $got B (README.md: $want B; path-dependent, tolerance 1 %)"
    [ $(( (got - want) * (got - want) * 10000 )) -le $(( want * want )) ] || open_finding "P2-10: $(title P2-10)"
  done
}

bench() {
  echo "==> bench: independent re-run of bench/run_bench.sh, README.md claims, second corpus, display / skeleton throughput"
  sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || { tail -20 "$AUDIT_OUT/bench.log"; fail "bench/run_bench.sh failed"; return; }
  grep -E '^(PASS|FAIL)|^\| `|SHA-256 verified' "$AUDIT_OUT/bench.log" | sed 's/^/    /'
  n=$(sed -nE 's/^PASS: ([0-9]+)\/([0-9]+) differential cases.*/\1/p' "$AUDIT_OUT/bench.log")
  [ -n "$n" ] || fail "bench differential oracle did not pass"
  [ "$n" = "$($RD diff_cases)" ] || open_finding "P2-10: $(title P2-10)"
  shas=$(sed -nE 's/.*SHA-256 verified identical across all implementations and rounds: `([0-9a-f]{64})`.*/\1/p' "$AUDIT_OUT/bench.log" | tr '\n' ' ')
  [ "$shas" = "$($RD sha_mixed) $($RD sha_rw) " ] || fail "benchmark stdout SHA-256 ($shas) != README.md"
  $PY - "$AUDIT_OUT/bench.log" "$($RD speedup_mixed)" "$($RD speedup_rw)" <<'PY' || open_finding "P2-10: $(title P2-10)"
import os, re, sys
t = open(sys.argv[1]).read()
rows = [l for l in t.split("\n") if l.startswith("| `pion_idna`")]
sp = [float(re.search(r"([0-9.]+)x", r.split("|")[8]).group(1)) for r in rows]
claims = [float(sys.argv[2]), float(sys.argv[3])]
load = os.popen("sysctl -n vm.loadavg 2>/dev/null || cat /proc/loadavg").read().strip()
print("  measured speedups %s vs README.md %s (machine load: %s)" % (sp, claims, load))
sys.exit(0 if all(a >= 0.75 * b for a, b in zip(sp, claims)) else 1)
PY
  B=/tmp/pion-idna-bench/bin
  [ -x "$B/pion_idna" ] && [ -x "$B/rust_idna" ] || { fail "bench binaries missing"; return; }
  set -- $($PY "$AUDIT_DIR/diff/altbench.py" "$AUDIT_OUT/alt_corpus.txt")
  echo "  -- second corpus (diff/altbench.py, $1 domains): 63-byte labels, NFD-dense, A-label heavy, Bidi"
  $PY "$ROOT_DIR/scripts/bench_compare.py" --title "IDNA alt corpus ($1 domains x 100)" \
    --impl "pion_idna=$B/pion_idna bench $AUDIT_OUT/alt_corpus.txt 100" --impl "rust_idna=$B/rust_idna bench $AUDIT_OUT/alt_corpus.txt 100" \
    --baseline rust_idna --warmup 1 --rounds 5 --bytes $(($2 * 100)) --ops $(($1 * 200)) \
    --md-out "$AUDIT_OUT/alt_bench.md" --json-out "$AUDIT_OUT/alt_bench.json" > "$AUDIT_OUT/alt_bench.log" 2>&1 || { tail -5 "$AUDIT_OUT/alt_bench.log"; fail "alt benchmark failed (outputs differ?)"; }
  grep -E '^\| `|SHA-256 verified' "$AUDIT_OUT/alt_bench.log" | sed 's/^/    /'
  $PY - "$AUDIT_OUT/alt_bench.log" "$($RD speedup_mixed)" "$($RD speedup_rw)" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
row = [l for l in t.split("\n") if l.startswith("| `pion_idna`")][0].split("|")
sp = float(re.search(r"([0-9.]+)x", row[8]).group(1))
lo = min(float(sys.argv[2]), float(sys.argv[3]))
print("  second corpus: %.2fx vs Rust (README.md corpora: %s / %s)%s" % (sp, sys.argv[2], sys.argv[3],
      "" if sp >= lo else "  -> slower than both README corpora: INFO-8 in REPORT.md (not a README claim)"))
PY
  echo "  -- Pion-only throughput (no Rust equivalent): display_domain_default / skeleton over both README corpora"
  for op in display skeleton ascii; do
    for f in bench_mixed bench_realworld; do
      set -- $("$BIN/idna_audit_rel" time "/tmp/pion-idna-bench/data/$f.txt" 50 "$op")
      n=$(grep -c . "/tmp/pion-idna-bench/data/$f.txt")
      echo "    $op $f: $(( $1 * 1000 / (n * 50) )) ns/op"
    done
  done
}

inject() {
  echo "==> inject: realistic bugs injected into a copy of packages/idna/src; the control cases must catch each"
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
    if ! pionc build --release -o "$AUDIT_OUT/inject/m$n.bin" "$dir" > "$AUDIT_OUT/inject/build$n.log" 2>&1; then
      echo "  [$n] mutant does not compile ($desc)"
      fail "mutant $n did not build"
      continue
    fi
    hit=""
    for c in $("$AUDIT_OUT/inject/m$n.bin" list); do
      case "$c" in control_*) ;; *) continue ;; esac
      "$AUDIT_OUT/inject/m$n.bin" case "$c" 2>&1 | grep -q '^PASS ' || hit="$hit $c"
    done
    if [ -n "$hit" ]; then
      caught=$((caught + 1))
      echo "  [$n] caught by$hit: $desc"
    else
      echo "  [$n] MISSED: $desc"
      fail "injected bug $n not caught"
    fi
  done < "$AUDIT_OUT/inject/list.txt"
  echo "  injected bugs caught: $caught/$total"
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
  [ -z "$(git -C "$ROOT_DIR" status --porcelain --ignored -- "$PKG_DIR" | grep -v '^?? packages/idna/audit/$' 2> /dev/null)" ] || { git -C "$ROOT_DIR" status --porcelain --ignored -- "$PKG_DIR" | head; fail "audit left files in the repository"; }
  echo "EXIT=$RC"
}

case "$SECTION" in
  all)
    build
    static
    unit
    cases
    determinism
    oracles
    idnatest
    dos
    smoke
    bench
    inject
    ;;
  build | static | unit | cases | determinism | oracles | idnatest | dos | smoke | bench | inject) "$SECTION" ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
summary
exit $RC
