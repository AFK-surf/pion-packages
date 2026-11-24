#!/bin/sh
# One-shot red-team audit for packages/hls (see REPORT.md).
#   sh packages/hls/audit/run_audit.sh [all|build|static|unit|cases|determinism|oracles|dos|smoke|bench|inject]
# (single sections need a previous `build`)
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), cargo (Rust m3u8-rs =6.0.1 oracle, --locked; uses the crate
# cache when offline), python3 (stdlib only). Network is not needed.
# Artifacts go to $AUDIT_OUT (default /private/tmp/pion-hls-audit, the real path of /tmp on macOS, because the
# wasm32 runner resolves symlinks). Nothing is written inside the repository.
# Every number README.md claims (wasm_smoke SHA-256 and wasm sizes, differential counts, benchmark SHA-256, speedup,
# throughput) is parsed from README.md at run time (diff/readme.py); nothing about it is hard-coded here.
#
# Exit status: 1 while any P0 condition reproduces (crash / trap / OOM on any input, a native-vs-wasm32 or
# debug-vs-release divergence, a divergence from the reference model that no finding explains, a failing control
# case, a wasm_smoke hash that differs from README.md, a benchmark whose outputs are not byte-identical, or an
# injected bug the gates miss). Open P1/P2 findings (and README drift) are listed as OPEN and fail the run only
# with STRICT=1.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-hls-audit}
if [ ! -d /private/tmp ] && [ "$AUDIT_OUT" = /private/tmp/pion-hls-audit ]; then AUDIT_OUT=/tmp/pion-hls-audit; fi
BIN="$AUDIT_OUT/bin"
C="$AUDIT_OUT/corpus"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
STRICT=${STRICT:-0}
FUZZ_N=${FUZZ_N:-4000}
README="$PKG_DIR/README.md"
PY="python3 -I"
CMP="$PY $AUDIT_DIR/diff/compare.py"
RD="$PY $AUDIT_DIR/diff/readme.py $README"
MODES="native_dbg native_rel wasm_dbg wasm_rel"
mkdir -p "$BIN"
export PYTHONDONTWRITEBYTECODE=1
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
    P0-1) echo "variable expansion has no aggregate budget: 1.2 MB playlist -> 4.5 GB (wasm32 OOM panic)" ;;
    P1-1) echo "decimal values just above Int64 microseconds wrap around (negative EXTINF, TIME-OFFSET sign flip)" ;;
    P1-2) echo "resolve_media_sequence / total_duration_us wrap around Int64 (MSN, DSN, timeline)" ;;
    P1-3) echo "EXT-X-DEFINE declaration / lookup are linear scans: quadratic CPU DoS (7.3 MB -> 24 s)" ;;
    P1-4) echo "multi-KEYFORMAT EXT-X-KEY tags (multi-DRM) silently reduced to the last one" ;;
    P1-5) echo "EXT-X-SKIP ignored: delta-update segments numbered SKIPPED-SEGMENTS too low" ;;
    P1-6) echo "format_playlist writes CustomTag / DATERANGE client-attribute names verbatim: tag injection" ;;
    P2-1) echo "Variable Reference recognition (undefined accepted without DEFINE, literal '{\$' rejected)" ;;
    P2-2) echo "substitution skipped in LANGUAGE, DATA-ID, DATERANGE, IV, SCTE35, BYTERANGE ... values" ;;
    P2-3) echo "IMPORT / QUERYPARAM: accepted but unusable; IMPORT accepted in Multivariant Playlists" ;;
    P2-4) echo "format -> parse re-expands variable values (round trip not semantics-preserving)" ;;
    P2-5) echo "format_playlist returns Ok for text it cannot parse back" ;;
    P2-6) echo "formatter loses position: unknown tags (CUE-OUT/IN) moved to the end, KEY/MAP order inverted" ;;
    P2-7) echo "MUST-level cross-tag constraints and singleton rules not validated" ;;
    P2-8) echo "METHOD=NONE with other attributes, MAP BYTERANGE without offset accepted" ;;
    P2-9) echo "ISO 8601 date-times without zone / basic offsets fail the whole playlist" ;;
    P2-10) echo "lexical / value-type rules only partly enforced (control chars, quoted enums, CR at EOF)" ;;
    P2-11) echo "EXT-X-PART BYTERANGE without offset not resolved" ;;
    P2-12) echo "parse results (Playlist, Master/MediaPlaylist, MediaSegment, DateRange) are not Send (README: Send-safe)" ;;
    P2-13) echo "README.md benchmark / size claims not reproduced or not representative" ;;
    *) echo "(see REPORT.md)" ;;
  esac
}
runner() {
  case "$1" in
    native_dbg) echo "$BIN/hls_audit_dbg" ;;
    native_rel) echo "$BIN/hls_audit_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/hls_audit_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/hls_audit_rel.wasm" ;;
  esac
}
build4() { # <pkg_dir> <prefix>
  pionc build -o "$2_dbg" "$1" > /dev/null &&
    pionc build --release -o "$2_rel" "$1" > /dev/null &&
    pionc build --target wasm32 -o "$2_dbg.wasm" "$1" > /dev/null &&
    pionc build --release --target wasm32 -o "$2_rel.wasm" "$1" > /dev/null
}

build() {
  echo "==> build: hls_audit in 4 modes, m3u8-rs oracle (cargo --locked), corpora"
  pionc fmt --check "$AUDIT_DIR" > /dev/null || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  build4 "$AUDIT_DIR" "$BIN/hls_audit" || fail "build hls_audit (4 modes)"
  M="$AUDIT_DIR/diff/rust/Cargo.toml"
  { CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline --manifest-path "$M" 2> /dev/null ||
    CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --manifest-path "$M"; } || fail "cargo build oracle"
  cp "$AUDIT_OUT/rust-target/release/hls_audit_oracle" "$BIN/oracle"
  rm -rf "$C" && echo "  corpus: $($PY "$AUDIT_DIR/diff/gen.py" "$C" "$FUZZ_N" | awk '{print $1 " named cases, " $2 " seeds + mutations"}')"
  $PY "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos" --list-only
  echo "  $(pionc --version) | node $(node --version) | $(cargo --version) | m3u8-rs =6.0.1"
}

static() {
  echo "==> static: license, dependencies, extern \"C\", World, module-level state, Double::to_string, README hygiene"
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
  echo "  Send probe: public values crossing a spawn boundary"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\nhls = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  for v in hls::HlsLimits hls::HlsError hls::EncryptionKey hls::VariantStream hls::ResolvedSegment hls::Playlist \
    hls::MasterPlaylist hls::MediaPlaylist hls::MediaSegment hls::DateRange; do
    printf 'import "hls"\n\nfn probe(v : %s, world : World) -> Unit {\n  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })\n}\n\n///|\npub fn main(world : World) -> Int {\n  0\n}\n' "$v" > "$P/src/main.pion"
    r=$(pionc check --json "$P" 2>&1 | $PY -c 'import json,sys; d=json.load(sys.stdin); print("Send" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))' 2>/dev/null)
    printf '    %-24s %s\n' "$v" "${r:-compile-error}"
    [ "$r" = Send ] || open_finding "P2-12: $(title P2-12)"
  done
}

unit() {
  echo "==> unit: pionc fmt/check/test of packages/hls, pionc test of the audit package (control_* must pass)"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/hls"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/hls"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> /dev/null
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit_audit.json" 2> "$AUDIT_OUT/unit_audit.stderr"
  $PY - "$AUDIT_OUT/unit_pkg.json" "$AUDIT_OUT/unit_audit.json" <<'PY' || fail "unit tests"
import json, sys
pkg = json.load(open(sys.argv[1]))
own = [t for t in pkg["tests"] if t.get("pkg") == "hls"]
bad = sum(1 for t in own if not t["ok"])
print("  packages/hls own tests: %d/%d pass" % (len(own) - bad, len(own)))
d = json.load(open(sys.argv[2]))
n = {"PASS": 0, "OPEN": 0, "FAIL": 0}
for t in d["tests"]:
    if t.get("pkg") != "hls_audit":
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
  names=$("$BIN/hls_audit_rel" list)
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
  sed 's/^/    /' "$AUDIT_OUT/cases_native_rel.txt" | cut -c1-200
  for m in native_dbg wasm_dbg wasm_rel; do # P1-3's message carries timings: compare PASS/FAIL per case only
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
  echo "==> determinism: corpora, API sweep and the small DoS bombs in all 4 modes must be byte-identical"
  for g in named fuzz; do
    for m in $MODES; do
      # shellcheck disable=SC2046
      $(runner $m) dump "$C/$g.cases" > "$AUDIT_OUT/pion_${g}_$m.txt" 2> "$AUDIT_OUT/pion_${g}_$m.err" || fail "$g: $m exited non-zero ($(tail -1 "$AUDIT_OUT/pion_${g}_$m.err"))"
    done
    for m in native_dbg wasm_dbg wasm_rel; do
      $CMP same "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_${g}_$m.txt" || fail "$g: $m differs from native_rel"
    done
    cp "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_$g.txt"
    echo "  [$g] $(wc -l < "$C/$g.cases" | tr -d ' ') inputs, $(wc -l < "$AUDIT_OUT/pion_$g.txt" | tr -d ' ') dump lines, sha256 $(shasum -a 256 "$AUDIT_OUT/pion_$g.txt" | cut -c1-16), 4 modes byte-identical"
  done
  for m in $MODES; do
    # shellcheck disable=SC2046
    $(runner $m) api > "$AUDIT_OUT/api_$m.txt" 2>&1 || fail "api: $m exited non-zero"
  done
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/api_native_rel.txt" "$AUDIT_OUT/api_$m.txt" || fail "API sweep: $m differs from native_rel"
  done
  echo "  [api] $(wc -l < "$AUDIT_OUT/api_native_rel.txt" | tr -d ' ') lines, 4 modes byte-identical"
  n=0
  for f in "$AUDIT_OUT"/dos/b0[25-9]*.m3u8 "$AUDIT_OUT"/dos/b1*.m3u8; do
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
  echo "==> oracles: independent RFC 8216bis reference model (diff/model.py), Rust m3u8-rs =6.0.1"
  : > "$AUDIT_OUT/found.txt"
  for g in named fuzz; do
    $PY "$AUDIT_DIR/diff/model.py" "$C/$g.cases" > "$AUDIT_OUT/model_$g.txt" || fail "model crashed on $g"
    out=$($CMP model "$AUDIT_OUT/pion_$g.txt" "$AUDIT_OUT/model_$g.txt" 2>&1)
    r=$?
    echo "  [$g]"
    printf '%s\n' "$out" | grep -v '^FINDINGS' | cut -c1-220
    printf '%s\n' "$out" | grep '^FINDINGS' | cut -d' ' -f2- | tr ' ' '\n' >> "$AUDIT_OUT/found.txt"
    [ $r = 1 ] && fail "unexplained divergence from the reference model ($g)"
  done
  ids=$(grep . "$AUDIT_OUT/found.txt" | sort -u | tr '\n' ' ')
  echo "  findings that explain model divergences: ${ids:-none} (open/closed status comes from the red-team cases)"
  echo "  -- m3u8-rs =6.0.1 (a lenient parser, not a validator): accept sets and the shared field subset"
  for g in named fuzz; do
    "$BIN/oracle" "$C/$g.cases" > "$AUDIT_OUT/rust_$g.txt" || fail "oracle failed on $g"
    echo "  [$g]"
    $CMP rust "$AUDIT_OUT/pion_$g.txt" "$AUDIT_OUT/rust_$g.txt" "$AUDIT_OUT/model_$g.txt" "$C/$g.cases" | cut -c1-200
  done
}

dos() {
  echo "==> dos: bombs under default HlsLimits, native --release and wasm32 --release (budget: time, RSS <= 1 GiB)"
  out=$($PY "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos" "$BIN/hls_audit_rel" "node $WASM_RT $BIN/hls_audit_rel.wasm")
  r=$?
  printf '%s\n' "$out" | grep -v '^OPENIDS' | cut -c1-230
  for id in $(printf '%s\n' "$out" | grep '^OPENIDS' | cut -d' ' -f2-); do
    open_finding "$id: $(title "$id")"
  done
  [ $r = 0 ] || fail "DoS bomb crashed / trapped / diverged (see above)"
}

smoke() {
  echo "==> smoke: packages/hls/wasm_smoke in 4 modes vs README.md"
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
    want=$($RD wasm_$k)
    echo "  wasm32 $k size: $got B (README.md: $want B)"
    [ "$got" = "$want" ] || open_finding "P2-13: $(title P2-13)"
  done
}

bench() {
  echo "==> bench: independent re-run of bench/run_bench.sh, README.md claims, second corpus"
  sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || { tail -20 "$AUDIT_OUT/bench.log"; fail "bench/run_bench.sh failed"; return; }
  grep -E '^(PASS|FAIL)|^\| `|SHA-256 verified' "$AUDIT_OUT/bench.log" | sed 's/^/    /'
  grep -q '^PASS: 0 deviations' "$AUDIT_OUT/bench.log" || fail "bench differential oracle did not pass"
  dp=$(sed -nE 's/^PASS: 0 deviations across ([0-9]+) playlists \(([0-9]+) field records\).*/\1 \2/p' "$AUDIT_OUT/bench.log")
  [ "$dp" = "$($RD diff_playlists) $($RD diff_records)" ] || open_finding "P2-13: $(title P2-13)"
  bsha=$(sed -nE 's/.*SHA-256 verified identical across all implementations and rounds: `([0-9a-f]{64})`.*/\1/p' "$AUDIT_OUT/bench.log")
  [ -n "$bsha" ] || fail "benchmark stdout not byte-identical across implementations"
  [ "$bsha" = "$($RD bench_sha)" ] || fail "benchmark stdout sha256 $bsha != README.md"
  $PY - "$AUDIT_OUT/bench.log" "$($RD speedup)" "$($RD throughput)" <<'PY' || open_finding "P2-13: $(title P2-13)"
import re, sys
t = open(sys.argv[1]).read()
row = [l for l in t.split("\n") if l.startswith("| `pion_hls`")][0].split("|")
sp = float(re.search(r"([0-9.]+)x", row[8]).group(1))
tp = float(row[5])
print("  measured %.2fx / %.1f MB/s vs README.md %sx / %s MB/s (machine load: %s)" % (sp, tp, sys.argv[2], sys.argv[3],
      open("/proc/loadavg").read().split()[0] if __import__("os").path.exists("/proc/loadavg") else
      __import__("os").popen("sysctl -n vm.loadavg").read().strip()))
sys.exit(0 if sp >= 0.75 * float(sys.argv[2]) else 1)
PY
  echo "  -- second corpus (diff/altbench.py): long URLs, PDT per segment, key rotation, explicit byte ranges"
  B=/tmp/pion-hls-bench/bin
  [ -x "$B/pion_hls" ] && [ -x "$B/rust_hls" ] || { fail "bench binaries missing"; return; }
  set -- $($PY "$AUDIT_DIR/diff/altbench.py" "$AUDIT_OUT/alt_corpus.txt")
  $PY "$ROOT_DIR/scripts/bench_compare.py" --title "HLS alt corpus ($1 playlists x 5)" \
    --impl "pion_hls=$B/pion_hls bench $AUDIT_OUT/alt_corpus.txt 5" --impl "rust_m3u8_rs=$B/rust_hls bench $AUDIT_OUT/alt_corpus.txt 5" \
    --baseline rust_m3u8_rs --warmup 1 --rounds 5 --bytes $(($2 * 5)) --ops $(($1 * 5)) \
    --md-out "$AUDIT_OUT/alt_bench.md" --json-out "$AUDIT_OUT/alt_bench.json" > "$AUDIT_OUT/alt_bench.log" 2>&1 || { tail -5 "$AUDIT_OUT/alt_bench.log"; fail "alt benchmark failed (outputs differ?)"; }
  grep -E '^\| `|SHA-256 verified' "$AUDIT_OUT/alt_bench.log" | sed 's/^/    /'
  $PY - "$AUDIT_OUT/alt_bench.log" "$($RD speedup)" "$README" <<'PY' || open_finding "P2-13: $(title P2-13)"
import re, sys
t = open(sys.argv[1]).read()
row = [l for l in t.split("\n") if l.startswith("| `pion_hls`")][0].split("|")
sp = float(re.search(r"([0-9.]+)x", row[8]).group(1))
claim = float(sys.argv[2])
documented = "altbench" in open(sys.argv[3]).read()
print("  second corpus: %.2fx (README.md headline %.2fx; second corpus documented in README.md: %s)" % (sp, claim, documented))
sys.exit(0 if documented or sp * 1.25 >= claim else 1)
PY
}

inject() {
  echo "==> inject: 5 real bug classes injected into a copy of packages/hls/src; the control cases must catch each"
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
    if ! pionc build --release -o "$AUDIT_OUT/inject/m$n" "$dir" > "$AUDIT_OUT/inject/build$n.log" 2>&1; then
      echo "  [$n] mutant does not compile ($desc)"
      fail "mutant $n did not build"
      continue
    fi
    hit=""
    for c in $("$AUDIT_OUT/inject/m$n" list); do
      case "$c" in control_*) ;; *) continue ;; esac
      "$AUDIT_OUT/inject/m$n" case "$c" 2>&1 | grep -q '^PASS ' || hit="$hit $c"
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
  if [ "$STRICT" = 1 ] && [ -n "$OPEN" ]; then
    echo "  STRICT=1: open findings fail the run"
    RC=1
  fi
  [ -z "$(git -C "$ROOT_DIR" status --porcelain --ignored -- "$PKG_DIR" 2> /dev/null)" ] || { git -C "$ROOT_DIR" status --porcelain --ignored -- "$PKG_DIR" | head; fail "audit left files in the repository"; }
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
