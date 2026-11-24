#!/bin/sh
# One-shot red-team audit for packages/structured_fields (RT-sfv, see REPORT.md).
#   sh packages/structured_fields/audit/run_audit.sh [all|build|static|unit|cases|official|determinism|oracles|dos|smoke|bench|inject]
# (single sections need a previous `build`)
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), cargo (Rust sfv =0.16.1 oracle, --locked; crate cache when
# offline), python3 (stdlib only). The official httpwg/structured-field-tests vectors are vendored (gzip, BSD-3-Clause,
# audit/sft/LICENSE.md); network not needed. Artifacts go to $AUDIT_OUT (default /private/tmp/pion-sfv-audit, the
# real path of /tmp on macOS, because the wasm32 runner resolves symlinks). Nothing is written inside the repository.
# Every number README.md claims (Send lists, unit test count, official vector count, wasm_smoke stdout / SHA-256 /
# sizes, benchmark SHA-256, speedups and RSS) is parsed from README.md at run time (diff/readme.py).
#
# Exit status: 1 while any P0 condition reproduces (crash / trap / over-budget bomb, a native-vs-wasm32 or
# debug-vs-release divergence, an official vector or a model / Rust sfv divergence no finding explains, a failing
# control case, a wasm_smoke hash that differs from README.md, a benchmark whose outputs are not byte-identical, or
# an injected bug the control cases miss). Open P1/P2 findings are listed as OPEN and fail the run only with
# STRICT=1. Repository-root files (BENCHMARKS.md, catalog.json, README.md, THIRD_PARTY_NOTICES.md) are only ever
# reported as INFO.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-sfv-audit}
if [ ! -d /private/tmp ] && [ "$AUDIT_OUT" = /private/tmp/pion-sfv-audit ]; then AUDIT_OUT=/tmp/pion-sfv-audit; fi
BIN="$AUDIT_OUT/bin"
C="$AUDIT_OUT/corpus"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
STRICT=${STRICT:-0}
FUZZ_N=${FUZZ_N:-6000}
README="$PKG_DIR/README.md"
PY="python3 -I"
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
  echo "  INFO: $*"
  INFO="$INFO
  - $*"
}
title() {
  case "$1" in
    P2-1) echo "List / Dictionary ending in HTAB rejected (RFC 9651 4.2.1 / 4.2.2 discard trailing OWS; Rust sfv accepts)" ;;
    P2-2) echo "serializer emits duplicate Dictionary / Parameter keys (first-wins get_* vs last-wins parse differential)" ;;
    P2-3) echo "README.md claims not reproduced (see the section output)" ;;
    *) echo "(see REPORT.md)" ;;
  esac
}
runner() {
  case "$1" in
    native_dbg) echo "$BIN/sfv_audit_dbg" ;;
    native_rel) echo "$BIN/sfv_audit_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/sfv_audit_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/sfv_audit_rel.wasm" ;;
  esac
}
build4() { # <pkg_dir> <prefix>
  pionc build -o "$2_dbg" "$1" > /dev/null &&
    pionc build --release -o "$2_rel" "$1" > /dev/null &&
    pionc build --target wasm32 -o "$2_dbg.wasm" "$1" > /dev/null &&
    pionc build --release --target wasm32 -o "$2_rel.wasm" "$1" > /dev/null
}

build() {
  echo "==> build: sfv_audit in 4 modes, Rust sfv =0.16.1 oracle (cargo --locked), corpora"
  pionc fmt --check "$AUDIT_DIR" > /dev/null || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  build4 "$AUDIT_DIR" "$BIN/sfv_audit" || fail "build sfv_audit (4 modes)"
  M="$AUDIT_DIR/diff/rust/Cargo.toml"
  { CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline --manifest-path "$M" 2> /dev/null ||
    CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --manifest-path "$M"; } || fail "cargo build oracle"
  cp "$AUDIT_OUT/rust-target/release/sfv_audit_oracle" "$BIN/oracle"
  rm -rf "$C" && echo "  corpus: $($PY "$AUDIT_DIR/diff/gen.py" "$AUDIT_DIR/sft" "$C" "$FUZZ_N" |
    awk '{print $1 " official parsing + " $2 " official serialisation vectors, " $3 " named adversarial, " $4 " fuzz, " $5 " serializer ASTs, " $6 " helper vectors"}')"
  $PY "$AUDIT_DIR/diff/model.py" selftest | sed 's/^/  /' || fail "reference model self-test"
  echo "  $(pionc --version) | node $(node --version) | $(cargo --version) | sfv =0.16.1 | python $(python3 -c 'import sys;print(sys.version.split()[0])') | $(uname -sm)"
}

static() {
  echo "==> static: license, dependencies, extern \"C\", World, module-level state, floats, internal names, Send"
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
  m=$(grep -hE '^(pub )?let [a-zA-Z_0-9]+ *(: *[A-Za-z]|=)' "$PKG_DIR"/src/*.pion)
  echo "  module-level lets: $(printf '%s' "$m" | grep -c .) ($(printf '%s' "$m" | grep -cv ': Int64 = -\?[0-9]*L$') not an Int64 constant)"
  [ "$(printf '%s' "$m" | grep -cv ': Int64 = -\?[0-9]*L$')" = 0 ] || fail "module-level binding other than an Int64 constant"
  n=$(printf '%s\n' "$SRC" | grep -cE 'Double|Float|to_double|\.to_float')
  echo "  Double / Float: $n"; [ "$n" = 0 ] || fail "floating point in src"
  n=$(printf '%s\n' "$SRC" | grep -cE '\bpanic\(|\babort\(|\.unwrap\(\)')
  echo "  panic / abort / unwrap in src: $n"; [ "$n" = 0 ] || fail "panic path in src"
  n=$(cat "$README" "$PKG_DIR"/src/*.pion "$PKG_DIR"/bench/*.sh "$PKG_DIR"/bench/*.py "$PKG_DIR"/bench/*/src/* "$PKG_DIR"/wasm_smoke/src/* |
    grep -ciE 'tokyo|pvg-office|afk-ap|gt1|gt2|office-host|mac-studio|stillfail|/Users/|/home/')
  echo "  internal machine names / paths in README, src, bench, wasm_smoke: $n"; [ "$n" = 0 ] || fail "internal names"
  grep -q 'structured-field-tests' "$ROOT_DIR/THIRD_PARTY_NOTICES.md" 2> /dev/null ||
    info "root THIRD_PARTY_NOTICES.md does not list httpwg/structured-field-tests (BSD-3-Clause, vendored in bench/gen_data.py and audit/sft) (root file: release integration, not this branch)"
  grep -q 'structured_fields' "$ROOT_DIR/catalog.json" 2> /dev/null ||
    info "root catalog.json / README.md / BENCHMARKS.md / index/ do not list structured_fields yet (release integration, not this branch)"
  echo "  Send probe: every public type captured in spawn (pionc check), against README.md"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\nstructured_fields = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  c_send=" $($RD send) "
  c_not=" $($RD notsend) "
  probe() { # <type> <body using v>
    printf 'import "structured_fields"\n\nfn probe(v : %s, world : World) -> Unit {\n%s\n}\n\n///|\npub fn main(world : World) -> Int {\n  0\n}\n' "$1" "$2" > "$P/src/main.pion"
    pionc check --json "$P" 2>&1 | $PY -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))' 2>/dev/null
  }
  ns=0; nn=0
  for v in SfvLimits Decimal SfvError Priority BareItem Param Item InnerList ListEntry DictMember PermissionsDirective; do
    r=$(probe "structured_fields::$v" '  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })')
    if [ "$r" = ok ]; then st=Send; ns=$((ns + 1)); else st="!Send ($r)"; nn=$((nn + 1)); fi
    claim="?"
    case "$c_send" in *" $v "*) claim=Send ;; esac
    case "$c_not" in *" $v "*) claim="!Send" ;; esac
    printf '    %-36s %-36s README.md: %s\n' "structured_fields::$v" "$st" "$claim"
    case "$claim:$st" in Send:Send | '!Send:!Send'*) ;; *) open_finding "P2-3: $(title P2-3)"; echo "    ^ Send claim not reproduced" ;; esac
  done
  # the README's advice: a serialized String crosses spawn
  r=$(probe "String" '  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = structured_fields::parse_item(v) }) })')
  echo "  String (serialized form) re-parsed inside spawn: $r"; [ "$r" = ok ] || open_finding "P2-3: $(title P2-3)"
  echo "  Send: $ns, !Send: $nn"
}

unit() {
  echo "==> unit: pionc fmt/check/test of packages/structured_fields, pionc test of the audit package (control_* must pass)"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/structured_fields"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/structured_fields"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> /dev/null
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit_audit.json" 2> "$AUDIT_OUT/unit_audit.stderr"
  $PY - "$AUDIT_OUT/unit_pkg.json" "$AUDIT_OUT/unit_audit.json" "$($RD tests)" <<'PY' || fail "unit tests"
import json, sys
pkg = json.load(open(sys.argv[1]))
own = [t for t in pkg["tests"] if t.get("pkg") == "structured_fields"]
bad = sum(1 for t in own if not t["ok"])
print("  packages/structured_fields own tests: %d/%d pass (README.md claims %s)" % (len(own) - bad, len(own), sys.argv[3]))
if str(len(own)) != sys.argv[3]:
    print("  README_DRIFT")
d = json.load(open(sys.argv[2]))
n = {"PASS": 0, "OPEN": 0, "FAIL": 0}
for t in d["tests"]:
    if t.get("pkg") != "structured_fields_audit":
        continue
    k = "PASS" if t["ok"] else ("OPEN" if t["name"].startswith("redteam_") else "FAIL")
    n[k] += 1
    if k != "PASS":
        print("  %s  %s" % (k, t["name"]))
    if k == "FAIL":
        bad += 1
print("  audit tests under pionc test: %d pass, %d red-team open, %d control failing" % (n["PASS"], n["OPEN"], n["FAIL"]))
sys.exit(1 if bad else 0)
PY
  got=$($PY -c 'import json,sys; print(sum(1 for t in json.load(open(sys.argv[1]))["tests"] if t.get("pkg")=="structured_fields"))' "$AUDIT_OUT/unit_pkg.json")
  [ "$got" = "$($RD tests)" ] || open_finding "P2-3: $(title P2-3)"
}

cases() {
  echo "==> cases: red-team + control cases, one process per case, in all 4 modes"
  names=$("$BIN/sfv_audit_rel" list)
  for m in $MODES; do
    : > "$AUDIT_OUT/cases_$m.txt"
    for c in $names; do
      # shellcheck disable=SC2046
      raw=$($(runner $m) case "$c" 2>&1; echo "exit=$?")
      out=$(printf '%s\n' "$raw" | grep -E '^(PASS|FAIL) ' | tail -1)
      [ -n "$out" ] || out="FAIL $c :: ABORT ($(printf '%s\n' "$raw" | tail -2 | tr '\n' ' '))"
      echo "$out" >> "$AUDIT_OUT/cases_$m.txt"
    done
    cut -d' ' -f1,2 "$AUDIT_OUT/cases_$m.txt" > "$AUDIT_OUT/status_$m.txt"
    echo "  $m: $(grep -c '^PASS' "$AUDIT_OUT/cases_$m.txt")/$(echo "$names" | wc -w | tr -d ' ') pass"
  done
  sed 's/^/    /' "$AUDIT_OUT/cases_native_rel.txt" | cut -c1-260
  for m in native_dbg wasm_dbg wasm_rel; do
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

official() {
  echo "==> official: all httpwg/structured-field-tests vectors ($(cat "$AUDIT_DIR/sft/SOURCE")) on Pion, the model and Rust sfv"
  "$BIN/sfv_audit_rel" dump "$C/official.cases" > "$AUDIT_OUT/pion_official.txt" || fail "dump official"
  "$BIN/sfv_audit_rel" ser "$C/official_ser.vec" > "$AUDIT_OUT/pion_oser.txt" || fail "ser official"
  $PY "$AUDIT_DIR/diff/model.py" dump "$C/official.cases" > "$AUDIT_OUT/model_official.txt"
  $PY "$AUDIT_DIR/diff/model.py" ser "$C/official_ser.vec" > "$AUDIT_OUT/model_oser.txt"
  "$BIN/oracle" dump "$C/official.cases" > "$AUDIT_OUT/rust_official.txt" || fail "oracle official"
  "$BIN/oracle" ser "$C/official_ser.vec" > "$AUDIT_OUT/rust_oser.txt" || fail "oracle ser official"
  for who in model rust pion; do
    echo "  [$who]"
    $CMP official "$C/official.json" "$AUDIT_OUT/${who}_official.txt" > "$AUDIT_OUT/off_$who.txt"; r1=$?
    sed 's/^/    /' "$AUDIT_OUT/off_$who.txt" | head -12 | cut -c1-260
    if [ "$who" = rust ]; then
      $CMP official_ser "$C/official_ser.json" "$AUDIT_OUT/${who}_oser.txt" | head -12 | sed 's/^/    /' | cut -c1-260
      echo "    (serialisation vectors with more than 3 fractional digits go through sfv's f64 Decimal::try_from)"
      continue
    fi
    $CMP official_ser "$C/official_ser.json" "$AUDIT_OUT/${who}_oser.txt" > "$AUDIT_OUT/offs_$who.txt"; r2=$?
    sed 's/^/    /' "$AUDIT_OUT/offs_$who.txt" | head -12 | cut -c1-260
    if [ "$who" = model ] && [ $((r1 + r2)) != 0 ]; then fail "the reference model fails official vectors (model bug)"; fi
    if [ "$who" = pion ] && [ $((r1 + r2)) != 0 ]; then fail "Pion fails official structured-field-tests vectors"; fi
  done
  want=$($RD vectors)
  echo "  README.md claims $want/$want core vectors; the full suite is $(grep -c . "$C/official.cases") parsing + $(grep -c . "$C/official_ser.vec") serialisation vectors"
}

determinism() {
  echo "==> determinism: every corpus and serializer vector file in all 4 modes must be byte-identical"
  for g in official named fuzz helpers official_ser ser; do
    case $g in official_ser | ser) mode=ser; f="$C/$g.vec" ;; helpers) mode=helpers; f="$C/$g.cases" ;; *) mode=dump; f="$C/$g.cases" ;; esac
    for m in $MODES; do
      # shellcheck disable=SC2046
      $(runner $m) $mode "$f" > "$AUDIT_OUT/pion_${g}_$m.txt" 2> "$AUDIT_OUT/pion_${g}_$m.err" || fail "$g: $m exited non-zero ($(tail -1 "$AUDIT_OUT/pion_${g}_$m.err"))"
    done
    for m in native_dbg wasm_dbg wasm_rel; do
      cmp -s "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_${g}_$m.txt" || fail "$g: $m differs from native_rel"
    done
    cp "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_$g.txt"
    echo "  [$g] $(grep -c . "$f") inputs, $(wc -l < "$AUDIT_OUT/pion_$g.txt" | tr -d ' ') lines, sha256 $(SHA "$AUDIT_OUT/pion_$g.txt" | cut -c1-16), 4 modes byte-identical"
  done
}

oracles() {
  echo "==> oracles: Pion vs the independent RFC 9651 model (diff/model.py) vs Rust sfv =0.16.1"
  : > "$AUDIT_OUT/found.txt"
  for g in official named fuzz; do
    $PY "$AUDIT_DIR/diff/model.py" dump "$C/$g.cases" > "$AUDIT_OUT/model_$g.txt" || fail "model crashed on $g"
    "$BIN/oracle" dump "$C/$g.cases" > "$AUDIT_OUT/rust_$g.txt" || fail "oracle failed on $g"
    out=$($CMP triple "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" "$AUDIT_OUT/model_$g.txt" "$AUDIT_OUT/rust_$g.txt" 2>&1)
    r=$?
    echo "  [$g parse]"
    printf '%s\n' "$out" | grep -v '^FINDINGS' | sed 's/^/  /' | cut -c1-300
    printf '%s\n' "$out" | grep '^FINDINGS' | cut -d' ' -f2- | tr ' ' '\n' >> "$AUDIT_OUT/found.txt"
    [ $r = 0 ] || fail "unexplained divergence from the reference model ($g)"
  done
  for g in ser official_ser; do
    $PY "$AUDIT_DIR/diff/model.py" ser "$C/$g.vec" > "$AUDIT_OUT/model_$g.txt" || fail "model crashed on $g"
    "$BIN/oracle" ser "$C/$g.vec" > "$AUDIT_OUT/rust_$g.txt" || fail "oracle failed on $g"
    out=$($CMP ser "$C/$g.vec" "$AUDIT_OUT/pion_$g.txt" "$AUDIT_OUT/model_$g.txt" "$AUDIT_OUT/rust_$g.txt" 2>&1)
    r=$?
    echo "  [$g serialize]"
    printf '%s\n' "$out" | grep -v '^FINDINGS' | sed 's/^/  /' | cut -c1-300
    printf '%s\n' "$out" | grep '^FINDINGS' | cut -d' ' -f2- | tr ' ' '\n' >> "$AUDIT_OUT/found.txt"
    [ $r = 0 ] || fail "unexplained serializer divergence from the reference model ($g)"
  done
  echo "  [helpers] RFC 9218 Priority / W3C Permissions-Policy (src/helpers.pion), full table in pion_helpers.txt"
  paste -d' ' - - - < "$AUDIT_OUT/pion_helpers.txt" | sed 's/^/    /' | cut -c1-200 | head -60
  ids=$(grep . "$AUDIT_OUT/found.txt" | sort -u | tr '\n' ' ')
  echo "  findings that explain model divergences: ${ids:-none} (open/closed status comes from the red-team cases)"
}

dos() {
  echo "==> dos: bombs under default and raised SfvLimits, native --release and wasm32 --release"
  out=$($PY "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos" "$BIN/sfv_audit_rel" "node $WASM_RT $BIN/sfv_audit_rel.wasm")
  r=$?
  printf '%s\n' "$out" | grep -v '^OPENIDS' | cut -c1-230
  for id in $(printf '%s\n' "$out" | grep '^OPENIDS' | cut -d' ' -f2-); do
    open_finding "$id: $(title "$id")"
  done
  [ $r = 0 ] || fail "DoS bomb crashed / trapped / diverged / over budget / superlinear (see above)"
}

smoke() {
  echo "==> smoke: packages/structured_fields/wasm_smoke in 4 modes vs README.md"
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
  want=$($RD smoke_sha)
  wantb=$($RD smoke_bytes)
  for m in native_dbg native_rel wasm_dbg wasm_rel; do
    got=$(SHA "$AUDIT_OUT/smoke_$m.txt")
    echo "  $m sha256 $got ($(wc -c < "$AUDIT_OUT/smoke_$m.txt" | tr -d ' ') B)"
    [ "$got" = "$want" ] || fail "wasm_smoke $m sha256 != README.md ($want)"
    [ "$(wc -c < "$AUDIT_OUT/smoke_$m.txt" | tr -d ' ')" = "$wantb" ] || open_finding "P2-3: $(title P2-3)"
  done
  sed 's/^/    /' "$AUDIT_OUT/smoke_native_rel.txt"
  for k in native_dbg native_rel wasm_dbg wasm_rel; do
    case $k in native_dbg) f=smoke_dbg ;; native_rel) f=smoke_rel ;; wasm_dbg) f=smoke_dbg.wasm ;; wasm_rel) f=smoke_rel.wasm ;; esac
    got=$(wc -c < "$BIN/$f" | tr -d ' ')
    want=$($RD size_$k)
    # binaries embed absolute source paths and depend on pionc / OS: tolerance 5 %, Linux x86_64 native only
    ok=$($PY -c 'import sys; g=int(sys.argv[1]); w=int(sys.argv[2]); print(1 if abs(g-w) <= 0.05*w else 0)' "$got" "$want")
    echo "  $k size: $got B (README.md: $want B) $([ "$ok" = 1 ] && echo within 5 % || echo DIFFERS)"
    if [ "$ok" != 1 ]; then
      case "$k:$(uname -sm)" in native*:"Linux x86_64" | wasm*) info "wasm_smoke $k size $got B vs README.md $want B (pionc / checkout-path dependent)" ;; esac
    fi
  done
}

bench() {
  echo "==> bench: independent re-run of bench/run_bench.sh against README.md"
  sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || { tail -20 "$AUDIT_OUT/bench.log"; fail "bench/run_bench.sh failed"; return; }
  grep -E '^\| `|SHA-256' "$AUDIT_OUT/bench.log" | sed 's/^/    /' | cut -c1-240
  $PY - "$AUDIT_OUT/bench.log" "$($RD bench_sha1)" "$($RD bench_sha2)" "$($RD speedup1)" "$($RD speedup2)" "$($RD rss1)" "$($RD rss2)" <<'PY'
import re, sys
log = open(sys.argv[1]).read()
shas = re.findall(r"\b([0-9a-f]{64})\b", log)
want = sys.argv[2:4]
rc = 0
for w in want:
    print("  README.md stdout sha256 %s... %s" % (w[:16], "reproduced" if w in shas else "NOT reproduced"))
    rc |= w not in shas
sp = re.findall(r"\| `pion` \| ([\d.]+) \|.*?\| ([\d.]+)x \|", log)
for i, (sw, rw) in enumerate(zip(sys.argv[4:6], sys.argv[6:8])):
    print("  corpus %d: README.md %sx, RSS %s MiB" % (i + 1, sw, rw))
sys.exit(rc)
PY
  [ $? = 0 ] || fail "benchmark stdout sha256 differs from README.md"
  echo "  peak RSS of one run each (diff/rss.py; bench_compare.py needs /usr/bin/time and may print N/A):"
  for n in 1 2; do
    case $n in 1) cf=corpus_browser.txt; it=5000 ;; 2) cf=corpus_complex.txt; it=4000 ;; esac
    for impl in pion_sfv_bench rust_sfv_bench; do
      echo "    corpus $n $impl: $($PY "$AUDIT_DIR/diff/rss.py" /tmp/pion-sfv-bench/bin/$impl bench /tmp/pion-sfv-bench/$cf $it |
        awk '{printf "%.3f s, peak RSS %.2f MiB, exit %s", $1, $2 / 1048576, $3}') (README.md: pion $($RD rss$n) MiB, rust_sfv $($RD rrss$n) MiB)"
    done
  done
  info "benchmark speed ratios depend on machine load; compare the table above with README.md by hand (re-run on an idle machine before quoting)"
}

inject() {
  echo "==> inject: real bugs injected into an isolated copy of the package must be caught by the control tests"
  $PY "$AUDIT_DIR/diff/inject.py" "$PKG_DIR" "$AUDIT_OUT/inject" || fail "an injected bug was not caught"
}

summary() {
  echo "==> summary"
  [ -n "$INFO" ] && echo "  INFO (not blocking):$INFO"
  if [ -n "$OPEN" ]; then echo "  OPEN findings:$OPEN"; else echo "  OPEN findings: none"; fi
  nopen=$(printf '%s' "$OPEN" | grep -c '^  - ')
  echo "  P0 conditions: $([ $RC = 0 ] && echo none || echo YES)   OPEN: $nopen   STRICT=$STRICT"
  if [ "$STRICT" = 1 ] && [ "$nopen" != 0 ]; then RC=1; fi
  if git -C "$ROOT_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    git -C "$ROOT_DIR" status --porcelain --ignored -- "$PKG_DIR" | grep -v '^?? packages/structured_fields/audit/' | grep . && fail "audit left files in the worktree"
  fi
  echo "EXIT=$RC"
}

case "$SECTION" in
  all) build; static; unit; cases; official; determinism; oracles; dos; smoke; bench; inject; summary ;;
  build | static | unit | cases | official | determinism | oracles | dos | smoke | bench | inject) "$SECTION"; summary ;;
  quick) build; unit; cases; official; determinism; oracles; summary ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
exit $RC
