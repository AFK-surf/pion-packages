#!/bin/sh
# One-shot red-team audit for packages/dash (see REPORT.md).
#   sh packages/dash/audit/run_audit.sh [all|build|static|unit|cases|determinism|oracles|dos|smoke|bench|inject]
# (single sections need a previous `build`)
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), cargo (Rust dash-mpd-core =0.1.0 oracle; uses the crate
# cache when offline), python3 (stdlib only). Network is not needed when the crates are cached.
# Artifacts go to $AUDIT_OUT (default /private/tmp/pion-dash-audit, the real path of /tmp on macOS, because the
# wasm32 runner resolves symlinks). Nothing is written inside the repository.
# Every number README.md claims (wasm_smoke SHA-256 and sizes, test count, benchmark SHA-256, speedup, throughput,
# the `Send` claim) is parsed from packages/dash/README.md at run time (diff/readme.py); nothing is hard-coded here.
# Repository-root files (README.md, BENCHMARKS.md, catalog.json) are never gated: feature branches must not touch them.
#
# Exit status: 1 while any P0 condition reproduces (crash / trap / OOM / budget overrun on an input under default
# limits, a native-vs-wasm32 or debug-vs-release divergence, a divergence from the reference model that no finding
# explains, a failing control case, a wasm_smoke hash that differs from README.md, a benchmark whose outputs are not
# byte-identical, or an injected bug the gates miss). Open P1/P2 findings (and README drift) are listed as OPEN and
# fail the run only with STRICT=1.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-dash-audit}
if [ ! -d /private/tmp ] && [ "$AUDIT_OUT" = /private/tmp/pion-dash-audit ]; then AUDIT_OUT=/tmp/pion-dash-audit; fi
BIN="$AUDIT_OUT/bin"
C="$AUDIT_OUT/corpus"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
STRICT=${STRICT:-0}
FUZZ_N=${FUZZ_N:-2000}
README="$PKG_DIR/README.md"
PY="python3 -I"
CMP="$PY $AUDIT_DIR/diff/compare.py"
RD="$PY $AUDIT_DIR/diff/readme.py $README"
MODES="native_dbg native_rel wasm_dbg wasm_rel"
mkdir -p "$BIN"
export PYTHONDONTWRITEBYTECODE=1
STATUS0=$(git -C "$ROOT_DIR" status --porcelain --ignored -- "$PKG_DIR" 2> /dev/null)
RC=0
OPEN=""
fail() { echo "  FAIL (P0): $*"; RC=1; }
open_finding() {
  case "$OPEN" in *"- ${1%%:*}:"*) return ;; esac
  echo "  OPEN: $*"
  OPEN="$OPEN
  - $*"
}
title() {
  case "$1" in
    P0-1) echo "resolve_segments has no aggregate budget: 39 KB MPD -> 4 GB of URLs (wasm32 OOM panic), 1 MB -> CPU > 20 s" ;;
    P1-1) echo "resolve_url is not RFC 3986: relative BaseURL chains lose '../', '.'/'..' lose '/', '//' collapsed, '#f' drops ?q" ;;
    P1-2) echo "segment numbers wrap around Int64 (duration-based SegmentTemplate, SegmentList): negative \$Number\$ in URLs" ;;
    P1-3) echo "SegmentTimeline r=-1 ignores presentationTimeOffset at the Period end (0 / wrong segment count)" ;;
    P1-4) echo "max_xml_depth above a few thousand turns deep input into native SIGSEGV / wasm32 stack overflow" ;;
    P2-1) echo "Period@start not inferred (first Period, previous start + duration); segment count floors fractional ticks" ;;
    P2-2) echo "SegmentTimeline S@r below -1 accepted (treated as -1)" ;;
    P2-3) echo "README.md claims the package is \`Send\`-safe: 8 public types are !Send" ;;
    P2-4) echo "xs: lexical / value spaces: dateTime without zone / 24:00, '+' integers, width=0 reject the whole MPD; ',' 't' 'z' +23:59 accepted" ;;
    P2-5) echo "XML 1.0 well-formedness not enforced (UTF-8 / Char, Names, ']]>', XMLDecl / PI targets, &#X, CR in CDATA)" ;;
    P2-6) echo "attribute-value normalisation (XML 1.0 3.3.3) missing: literal TAB / LF / CR kept in attribute values" ;;
    P2-7) echo "format_mpd returns Ok for values its output cannot carry (unparsable XML, silently changed values)" ;;
    P2-8) echo "select_representation matches only the first codec of a multi-codec @codecs list" ;;
    P2-9) echo "namespace-unaware: foreign-namespace elements / attributes taken for DASH ones (x:Period, x:id)" ;;
    P2-10) echo "PlayReady <mspr:pro> payloads dropped (data model and format_mpd)" ;;
    P2-11) echo "README.md benchmark / size / test-count claims not reproduced or not representative" ;;
    *) echo "(see REPORT.md)" ;;
  esac
}
runner() {
  case "$1" in
    native_dbg) echo "$BIN/dash_audit_dbg" ;;
    native_rel) echo "$BIN/dash_audit_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/dash_audit_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/dash_audit_rel.wasm" ;;
  esac
}
build4() { # <pkg_dir> <prefix>
  pionc build -o "$2_dbg" "$1" > /dev/null &&
    pionc build --release -o "$2_rel" "$1" > /dev/null &&
    pionc build --target wasm32 -o "$2_dbg.wasm" "$1" > /dev/null &&
    pionc build --release --target wasm32 -o "$2_rel.wasm" "$1" > /dev/null
}

build() {
  echo "==> build: dash_audit in 4 modes, dash-mpd-core oracle (cargo --locked), corpora"
  pionc fmt --check "$AUDIT_DIR" > /dev/null || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  build4 "$AUDIT_DIR" "$BIN/dash_audit" || fail "build dash_audit (4 modes)"
  M="$AUDIT_DIR/diff/rust/Cargo.toml"
  { CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline --manifest-path "$M" 2> /dev/null ||
    CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --manifest-path "$M"; } || fail "cargo build oracle"
  cp "$AUDIT_OUT/rust-target/release/dash_audit_oracle" "$BIN/oracle"
  rm -rf "$C" && echo "  corpus: $($PY "$AUDIT_DIR/diff/gen.py" "$C" "$FUZZ_N" | awk '{print $1 " named cases, " $2 " seeds + mutations, " $3 " API vectors"}')"
  $PY "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos" --list-only
  echo "  $(pionc --version) | node $(node --version) | $(cargo --version) | dash-mpd-core =0.1.0 | $(python3 --version)"
}

static() {
  echo "==> static: license, dependencies, extern \"C\", World, module-level state, Double / Float, README hygiene, media files"
  SRC=$(cat "$PKG_DIR"/src/*.pion | grep -v '^ *//')
  lic=$(grep -E '^license *= *"MIT"' "$PKG_DIR/pion.toml" | wc -l | tr -d ' ')
  echo "  pion.toml license = \"MIT\": $lic"; [ "$lic" = 1 ] || fail "pion.toml license is not MIT"
  deps=$(sed -n '/^\[dependencies\]/,/^\[/p' "$PKG_DIR/pion.toml" | grep -vc '^\[\|^ *$\|^#')
  echo "  [dependencies] entries: $deps"; [ "$deps" = 0 ] || fail "external dependencies"
  n=$(printf '%s\n' "$SRC" | grep -c 'extern "C"')
  echo "  extern \"C\": $n"; [ "$n" = 0 ] || fail "extern \"C\" in src"
  n=$(printf '%s\n' "$SRC" | grep -cw 'World')
  echo "  World: $n"; [ "$n" = 0 ] || fail "World in src"
  n=$(printf '%s\n' "$SRC" | grep -c '^import ')
  echo "  imports: $n"; [ "$n" = 0 ] || fail "imports in src"
  n=$(printf '%s\n' "$SRC" | grep -cE '^(pub )?let mut ')
  echo "  module-level let mut: $n"; [ "$n" = 0 ] || fail "module-level let mut"
  m=$(grep -nE '^(pub )?let [a-zA-Z_0-9]+ *(: *[A-Za-z]|=)' "$PKG_DIR"/src/*.pion | sed "s|$PKG_DIR/||")
  echo "  module-level lets: $(printf '%s' "$m" | grep -c .)"
  [ -z "$m" ] || { printf '%s\n' "$m"; fail "module-level binding (possible shared mutable state)"; }
  n=$(printf '%s\n' "$SRC" | grep -cE 'Double|Float|to_double|\.to_float')
  echo "  Double / Float use (incl. Double::to_string): $n"; [ "$n" = 0 ] || fail "floating point in src"
  n=$(grep -ciE 'tokyo|pvg-office|afk-ap|gt1|gt2|office-host|mac-studio|stillfail|/Users/|/home/' "$README")
  echo "  README internal machine names / paths: $n"; [ "$n" = 0 ] || fail "internal names in README.md"
  n=$(git -C "$ROOT_DIR" ls-files -- "$PKG_DIR" | grep -ciE '\.(mp4|m4s|m4a|mkv|webm|ts|mov|aac|mp3|jpg|png|mpd)$')
  echo "  media files tracked under packages/dash: $n"; [ "$n" = 0 ] || fail "media files in the package"
  echo "  Send probe: every public value crossing a spawn boundary (pionc check), against what README.md claims"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\ndash = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  claim=$($RD send_claim)
  echo "  README.md claim: ${claim}"
  probe() { # <type> <body using v>: prints ok or the diagnostic codes
    printf 'import "dash"\n\nfn probe(v : %s, world : World) -> Unit {\n%s\n}\n\n///|\npub fn main(world : World) -> Int {\n  0\n}\n' "$1" "$2" > "$P/src/main.pion"
    pionc check --json "$P" 2>&1 | $PY -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))' 2>/dev/null
  }
  nsend=0
  for v in Mpd Period AdaptationSet Representation SegmentTemplate SegmentTimelineEntry SegmentList SegmentUrl SegmentBase \
    ContentProtection Descriptor ResolvedSegment ResolvedTrack DashLimits DashError Rational MpdType ContentType; do
    r=$(probe "dash::$v" '  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })')
    extra=""
    if [ "$r" = ok ]; then
      r=Send
    else
      nsend=$((nsend + 1))
      m=$(probe "dash::$v" '  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let q = move v
  let _ = q }) })')
      extra=" (move into spawn: $m)"
      case " $claim " in *" all "* | *" $v "*) open_finding "P2-3: $(title P2-3)"; extra="$extra  <- README.md claims Send" ;; esac
    fi
    printf '    %-28s %s%s\n' "dash::$v" "${r:-compile-error}" "$extra"
  done
  echo "  !Send public types: $nsend"
}

unit() {
  echo "==> unit: pionc fmt/check/test of packages/dash, pionc test of the audit package (control_* must pass)"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/dash"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/dash"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> /dev/null
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit_audit.json" 2> "$AUDIT_OUT/unit_audit.stderr"
  $PY - "$AUDIT_OUT/unit_pkg.json" "$AUDIT_OUT/unit_audit.json" "$($RD tests)" <<'PY' || fail "unit tests"
import json, sys
pkg = json.load(open(sys.argv[1]))
own = [t for t in pkg["tests"] if t.get("pkg") == "dash"]
bad = sum(1 for t in own if not t["ok"])
print("  packages/dash own tests: %d/%d pass (README.md claims %s)" % (len(own) - bad, len(own), sys.argv[3]))
d = json.load(open(sys.argv[2]))
n = {"PASS": 0, "OPEN": 0, "FAIL": 0}
for t in d["tests"]:
    if t.get("pkg") != "dash_audit":
        continue
    k = "PASS" if t["ok"] else ("OPEN" if t["name"].startswith("redteam_") else "FAIL")
    n[k] += 1
    if k == "FAIL":
        print("  FAIL  %s" % t["name"])
        bad += 1
print("  audit tests under pionc test: %d pass, %d red-team open, %d control failing" % (n["PASS"], n["OPEN"], n["FAIL"]))
sys.exit(1 if bad else 0)
PY
  got=$($PY -c 'import json,sys; print(sum(1 for t in json.load(open(sys.argv[1]))["tests"] if t.get("pkg")=="dash"))' "$AUDIT_OUT/unit_pkg.json")
  [ "$got" = "$($RD tests)" ] || open_finding "P2-11: $(title P2-11)"
}

cases() {
  echo "==> cases: red-team + control cases, one process per case, in all 4 modes"
  names=$("$BIN/dash_audit_rel" list)
  for m in $MODES; do
    : > "$AUDIT_OUT/cases_$m.txt"
    for c in $names; do
      # shellcheck disable=SC2046
      raw=$($(runner $m) case "$c" 2>&1; echo "exit=$?")
      out=$(printf '%s\n' "$raw" | grep -E '^(PASS|FAIL) ' | tail -1)
      [ -n "$out" ] || out="FAIL $c :: ABORT ($(printf '%s\n' "$raw" | grep -m1 -E 'pion panic|RangeError' || true) $(printf '%s\n' "$raw" | tail -1); exit 139 = SIGSEGV)"
      echo "$out" >> "$AUDIT_OUT/cases_$m.txt"
    done
    cut -d' ' -f1,2 "$AUDIT_OUT/cases_$m.txt" > "$AUDIT_OUT/status_$m.txt"
    echo "  $m: $(grep -c '^PASS' "$AUDIT_OUT/cases_$m.txt")/$(echo "$names" | wc -w | tr -d ' ') pass"
  done
  sed 's/^/    /' "$AUDIT_OUT/cases_native_rel.txt" | cut -c1-230
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/status_native_rel.txt" "$AUDIT_OUT/status_$m.txt" || { diff "$AUDIT_OUT/status_native_rel.txt" "$AUDIT_OUT/status_$m.txt" | head -6; fail "case results of $m differ from native_rel"; }
  done
  grep -q '^FAIL control_.*ABORT' "$AUDIT_OUT"/cases_*.txt && fail "a control case aborted (panic / trap)"
  grep -q '^FAIL control_' "$AUDIT_OUT/cases_native_rel.txt" && fail "control case failing"
  for f in $(grep '^FAIL redteam_' "$AUDIT_OUT/cases_native_rel.txt" | awk '{print $2}'); do
    id=$(echo "$f" | sed -E 's/redteam_p([0-9])_([0-9]+)_.*/P\1-\2/')
    open_finding "$id: $(title "$id")"
    case "$f" in redteam_p0_*) fail "P0 red-team case $f" ;; esac
  done
}

determinism() {
  echo "==> determinism: corpora, API sweep, format_mpd output and the in-budget DoS bombs in all 4 modes must be byte-identical"
  for g in named fuzz; do
    for m in $MODES; do
      # shellcheck disable=SC2046
      $(runner $m) dump "$C/$g.cases" > "$AUDIT_OUT/pion_${g}_$m.txt" 2> "$AUDIT_OUT/pion_${g}_$m.err" || fail "$g: $m exited non-zero ($(tail -1 "$AUDIT_OUT/pion_${g}_$m.err"))"
      # shellcheck disable=SC2046
      $(runner $m) fmt "$C/$g.cases" > "$AUDIT_OUT/fmt_${g}_$m.txt" 2>&1 || fail "$g fmt: $m exited non-zero"
    done
    for m in native_dbg wasm_dbg wasm_rel; do
      $CMP same "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_${g}_$m.txt" || fail "$g: $m differs from native_rel"
      $CMP same "$AUDIT_OUT/fmt_${g}_native_rel.txt" "$AUDIT_OUT/fmt_${g}_$m.txt" || fail "$g fmt: $m differs from native_rel"
    done
    cp "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_$g.txt"
    cp "$AUDIT_OUT/fmt_${g}_native_rel.txt" "$AUDIT_OUT/fmt_$g.txt"
    echo "  [$g] $(wc -l < "$C/$g.cases" | tr -d ' ') inputs, $(wc -l < "$AUDIT_OUT/pion_$g.txt" | tr -d ' ') dump lines, sha256 $(shasum -a 256 "$AUDIT_OUT/pion_$g.txt" | cut -c1-16), format sha256 $(shasum -a 256 "$AUDIT_OUT/fmt_$g.txt" | cut -c1-16), 4 modes byte-identical"
  done
  for m in $MODES; do
    # shellcheck disable=SC2046
    $(runner $m) api "$C/api.vec" > "$AUDIT_OUT/api_$m.txt" 2>&1 || fail "api: $m exited non-zero"
  done
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/api_native_rel.txt" "$AUDIT_OUT/api_$m.txt" || fail "API sweep: $m differs from native_rel"
  done
  echo "  [api] $(wc -l < "$AUDIT_OUT/api_native_rel.txt" | tr -d ' ') vectors, 4 modes byte-identical"
  n=0
  for f in "$AUDIT_OUT"/dos/b0*.mpd "$AUDIT_OUT"/dos/b1*.mpd "$AUDIT_OUT"/dos/b2[0-6]*.mpd; do
    for m in $MODES; do
      # shellcheck disable=SC2046
      $(runner $m) bomb "$f" > "$AUDIT_OUT/bomb_$m.txt" 2>&1 || fail "$(basename "$f"): $m exited non-zero"
    done
    for m in native_dbg wasm_dbg wasm_rel; do
      cmp -s "$AUDIT_OUT/bomb_native_rel.txt" "$AUDIT_OUT/bomb_$m.txt" || fail "$(basename "$f"): $m differs from native_rel"
    done
    n=$((n + 1))
  done
  echo "  [dos] $n bombs that finish in budget, 4 modes byte-identical"
}

oracles() {
  echo "==> oracles: independent reference model (diff/model.py) + pyexpat, RFC 3986 vs urljoin, Rust dash-mpd-core =0.1.0"
  : > "$AUDIT_OUT/found.txt"
  for g in named fuzz; do
    $PY "$AUDIT_DIR/diff/model.py" --expat "$C/$g.cases" | sed "s/^/  [$g] /" | tail -4
    [ "$($PY "$AUDIT_DIR/diff/model.py" --expat "$C/$g.cases" > /dev/null; echo $?)" = 0 ] || fail "strict XML layer of the model disagrees with pyexpat ($g)"
    $PY "$AUDIT_DIR/diff/model.py" "$C/$g.cases" > "$AUDIT_OUT/model_$g.txt" || fail "model crashed on $g"
    out=$($CMP model "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" "$AUDIT_OUT/model_$g.txt" 2>&1)
    r=$?
    echo "  [$g] Pion vs reference model"
    printf '%s\n' "$out" | grep -v '^FINDINGS' | cut -c1-400
    printf '%s\n' "$out" | grep '^FINDINGS' | cut -d' ' -f2- | tr ' ' '\n' >> "$AUDIT_OUT/found.txt"
    [ $r = 1 ] && fail "unexplained divergence from the reference model ($g)"
    out=$($CMP fmt "$C/$g.cases" "$AUDIT_OUT/fmt_$g.txt")
    r=$?
    printf '%s\n' "$out" | grep -v '^FINDINGS' | sed "s/^/  [$g] /"
    [ $r = 0 ] || fail "format_mpd output not well-formed / injected element ($g)"
  done
  ids=$(grep . "$AUDIT_OUT/found.txt" | sort -u | tr '\n' ' ')
  echo "  findings that explain model divergences: ${ids:-none} (open/closed status comes from the red-team cases)"
  $PY "$AUDIT_DIR/diff/model.py" --api "$C/api.vec" > "$AUDIT_OUT/api_model.txt"
  $CMP api "$C/api.vec" "$AUDIT_OUT/api_native_rel.txt" "$AUDIT_OUT/api_model.txt" || fail "API sweep: unexplained divergence"
  echo "  -- dash-mpd-core =0.1.0 (serde + quick-xml, lenient, no validation): accept sets and the shared field subset"
  for g in named fuzz; do
    "$BIN/oracle" "$C/$g.cases" > "$AUDIT_OUT/rust_$g.txt" || fail "oracle failed on $g"
    echo "  [$g]"
    out=$($CMP rust "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" "$AUDIT_OUT/rust_$g.txt" "$AUDIT_OUT/model_$g.txt")
    r=$?
    printf '%s\n' "$out" | cut -c1-230
    [ $r = 0 ] || fail "unexplained divergence from dash-mpd-core ($g)"
  done
}

dos() {
  echo "==> dos: bombs under default DashLimits, native --release and wasm32 --release (budget: time, RSS <= 1 GiB)"
  out=$($PY "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos" "$BIN/dash_audit_rel" "node $WASM_RT $BIN/dash_audit_rel.wasm")
  r=$?
  printf '%s\n' "$out" | grep -v '^OPENIDS' | cut -c1-230
  for id in $(printf '%s\n' "$out" | grep '^OPENIDS' | cut -d' ' -f2-); do
    open_finding "$id: $(title "$id")"
    case "$id" in P0-*) fail "DoS bomb of $id breaks the budget" ;; esac
  done
  [ $r = 0 ] || fail "DoS bomb crashed / trapped / diverged / over budget (see above)"
}

smoke() {
  echo "==> smoke: packages/dash/wasm_smoke in 4 modes vs README.md"
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
  sed 's/^/    /' "$AUDIT_OUT/smoke_native_rel.txt"
  for k in dbg rel; do
    got=$(wc -c < "$BIN/smoke_$k.wasm" | tr -d ' ')
    want=$($RD wasm_${k}_kib)
    # the wasm32 binary embeds absolute source paths, so its size depends on the checkout path: tolerance 2 %
    echo "  wasm32 $k size: $got B = $((got / 1024)) KiB (README.md: $want KiB; path-dependent, tolerance 2 %)"
    $PY -c 'import sys; g=int(sys.argv[1])/1024; w=float(sys.argv[2]); sys.exit(0 if abs(g-w) <= 0.02*w else 1)' "$got" "$want" || open_finding "P2-11: $(title P2-11)"
  done
}

bench() {
  echo "==> bench: independent re-run of bench/run_bench.sh, README.md claims, second corpus (diff/altbench.py)"
  sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || { tail -20 "$AUDIT_OUT/bench.log"; fail "bench/run_bench.sh failed"; return; }
  grep -E '^(PASS|FAIL)|^\| `|SHA-256 verified' "$AUDIT_OUT/bench.log" | sed 's/^/    /' | cut -c1-260
  grep -q '^PASS: MPEG-DASH differential parity' "$AUDIT_OUT/bench.log" || fail "bench differential parity did not pass"
  bsha=$(sed -nE 's/.*SHA-256 verified identical across all implementations and rounds: `([0-9a-f]{64})`.*/\1/p' "$AUDIT_OUT/bench.log" | head -1)
  [ -n "$bsha" ] || fail "benchmark stdout not byte-identical across implementations"
  [ "$bsha" = "$($RD bench_sha)" ] || fail "benchmark stdout sha256 $bsha != README.md"
  $PY - "$AUDIT_OUT/bench.log" "$($RD speedup)" "$($RD throughput)" <<'PY' || open_finding "P2-11: $(title P2-11)"
import os, re, sys
t = open(sys.argv[1]).read()
row = [l for l in t.split("\n") if l.startswith("| `pion_dash`")][0].split("|")
sp = float(re.search(r"([0-9.]+)x", row[8]).group(1))
tp = float(row[5])
load = os.popen("sysctl -n vm.loadavg 2>/dev/null || cat /proc/loadavg").read().strip()
print("  measured %.2fx / %.1f MB/s vs README.md %sx / %s MB/s (machine load: %s)" % (sp, tp, sys.argv[2], sys.argv[3], load))
sys.exit(0 if sp >= 0.75 * float(sys.argv[2]) else 1)
PY
  B=/tmp/pion-dash-bench/bin
  [ -x "$B/pion_dash_bench" ] && [ -x "$B/rust_dash_bench" ] || { fail "bench binaries missing"; return; }
  set -- $($PY "$AUDIT_DIR/diff/altbench.py" "$AUDIT_OUT/alt_corpus.txt")
  "$B/pion_dash_bench" "$AUDIT_OUT/alt_corpus.txt" 0 > "$AUDIT_OUT/alt_pion.txt"
  "$B/rust_dash_bench" "$AUDIT_OUT/alt_corpus.txt" 0 > "$AUDIT_OUT/alt_rust.txt"
  cmp -s "$AUDIT_OUT/alt_pion.txt" "$AUDIT_OUT/alt_rust.txt" || { diff "$AUDIT_OUT/alt_rust.txt" "$AUDIT_OUT/alt_pion.txt" | head -5; fail "alt corpus: Pion and Rust field dumps differ"; }
  echo "  -- second corpus: $1 manifests, $2 B (multi-Period ads, Widevine + PlayReady pssh, 2 h SegmentTimelines, tokenised URLs)"
  $PY "$ROOT_DIR/scripts/bench_compare.py" --title "MPEG-DASH alt corpus ($1 manifests x 20)" \
    --impl "pion_dash=$B/pion_dash_bench $AUDIT_OUT/alt_corpus.txt 20" --impl "rust_dash_mpd=$B/rust_dash_bench $AUDIT_OUT/alt_corpus.txt 20" \
    --baseline rust_dash_mpd --warmup 1 --rounds 5 --bytes $(($2 * 20)) --ops $(($1 * 20)) \
    --md-out "$AUDIT_OUT/alt_bench.md" --json-out "$AUDIT_OUT/alt_bench.json" > "$AUDIT_OUT/alt_bench.log" 2>&1 || { tail -5 "$AUDIT_OUT/alt_bench.log"; fail "alt benchmark failed (outputs differ?)"; }
  grep -E '^\| `|SHA-256 verified' "$AUDIT_OUT/alt_bench.log" | sed 's/^/    /' | cut -c1-260
  $PY - "$AUDIT_OUT/alt_bench.log" "$($RD speedup)" "$README" <<'PY' || open_finding "P2-11: $(title P2-11)"
import re, sys
t = open(sys.argv[1]).read()
row = [l for l in t.split("\n") if l.startswith("| `pion_dash`")][0].split("|")
sp = float(re.search(r"([0-9.]+)x", row[8]).group(1))
claim = float(sys.argv[2])
documented = "altbench" in open(sys.argv[3]).read()
print("  second corpus: %.2fx (README.md headline %.2fx; second corpus documented in README.md: %s)" % (sp, claim, documented))
sys.exit(0 if documented or sp * 1.25 >= claim else 1)
PY
}

inject() {
  echo "==> inject: 5 real bug classes injected into a copy of packages/dash/src; the control cases must catch each"
  rm -rf "$AUDIT_OUT/inject" && mkdir -p "$AUDIT_OUT/inject"
  $PY "$AUDIT_DIR/diff/inject.py" "$PKG_DIR" "$AUDIT_DIR" "$AUDIT_OUT/inject" > "$AUDIT_OUT/inject/list.txt"
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
  echo "  injected bugs caught: $caught/$total (sources restored: mutants live only in $AUDIT_OUT/inject)"
}

summary() {
  echo "==> summary"
  if [ -n "$OPEN" ]; then
    echo "  OPEN findings (REPORT.md):$OPEN"
  else
    echo "  no open findings"
  fi
  echo "  INFO (not gated): repository-root README.md / BENCHMARKS.md / catalog.json are left to the release integration"
  if [ "$STRICT" = 1 ] && [ -n "$OPEN" ]; then
    echo "  STRICT=1: open findings fail the run"
    RC=1
  fi
  # nothing may appear in the work tree that was not there before the run (clean checkout: empty)
  st=$(git -C "$ROOT_DIR" status --porcelain --ignored -- "$PKG_DIR" 2> /dev/null)
  [ "$st" = "$STATUS0" ] || { printf '%s\n' "$st" | head; fail "audit left files in the repository"; }
  [ -n "$st" ] && echo "  work tree not clean before the run (uncommitted audit files?):" && printf '%s\n' "$st" | sed 's/^/    /' | head -5
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
    dos
    smoke
    bench
    inject
    ;;
  build | static | unit | cases | determinism | oracles | dos | smoke | bench | inject) "$SECTION" ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
summary
exit $RC
