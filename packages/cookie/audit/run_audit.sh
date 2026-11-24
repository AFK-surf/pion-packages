#!/bin/sh
# One-shot red-team audit for packages/cookie (see REPORT.md).
#   sh packages/cookie/audit/run_audit.sh [all|build|portability|unit|cases|determinism|oracles|psl|dos|api|smoke|bench|harness|docs]
# (single sections need a previous `build`; `docs` also needs `bench`)
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), cargo (Rust cookie =0.18.3 + psl =2.1.261 oracle, --locked;
# uses the crate cache when offline), python3 (stdlib only). Network is not needed: the official PSL snapshot and
# tests/test_psl.txt are pinned in psl/ (sha256 in psl/PINNED).
# Artifacts go to $AUDIT_OUT (default /private/tmp/pion-cookie-audit: the real path of /tmp on macOS, because the
# wasm32 runner resolves symlinks). Nothing is written inside the repository.
# README.md numbers (wasm_smoke stdout / SHA-256 / sizes, rule counts, test count, differential counts, benchmark
# medians) are parsed from README.md at run time (diff/readme.py): nothing about them is hard-coded here.
#
# Exit status: 1 while any P0 condition reproduces (crash / trap / timeout on any input, a native-vs-wasm32 or
# debug-vs-release divergence, a divergence from the reference model / Mozilla test_psl.txt / psl 2.1.261 that no
# known finding explains, an unsorted or corrupt embedded PSL table, a failing control case, a DoS hard limit, a
# wasm_smoke output or hash that differs from README.md, a benchmark whose outputs are not byte-identical, or a gate
# that misses an injected bug). Open P1/P2 findings are listed as OPEN and fail the run only with STRICT=1.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-cookie-audit}
if [ ! -d /private/tmp ] && [ "$AUDIT_OUT" = /private/tmp/pion-cookie-audit ]; then AUDIT_OUT=/tmp/pion-cookie-audit; fi
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
LINE_MODES="parse date psl match jar"
NEWER_RULES="*.airoapp.ai *.host.cloud sites.aspirethemes.com"  # in the pinned list, not in psl 2.1.261's
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
# compare.py exit status: 0 clean, 3 known findings only, 1 unexplained; its FINDINGS line lists the ids
cmp_run() {
  out=$("$@" 2>&1)
  r=$?
  printf '%s\n' "$out" | grep -v '^FINDINGS' | cut -c1-240
  for f in $(printf '%s\n' "$out" | grep '^FINDINGS' | cut -d' ' -f2-); do echo "$f" >> "$AUDIT_OUT/found.txt"; done
  return $r
}
runner() {
  case "$1" in
    native_dbg) echo "$BIN/cookie_audit_dbg" ;;
    native_rel) echo "$BIN/cookie_audit_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/cookie_audit_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/cookie_audit_rel.wasm" ;;
  esac
}
spec_env() {  # the model uses the pinned official PSL unless the package embeds a different snapshot
  if [ -f "$AUDIT_OUT/psl_snapshot_differs" ]; then echo "SPEC_PSL=$PKG_DIR/src/psl_data.pion"; else echo "SPEC_PSL="; fi
}

build() {
  echo "==> build: cookie_audit in 4 modes, Rust oracle (cargo --locked), corpora"
  pionc fmt --check "$AUDIT_DIR" > /dev/null || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  pionc build -o "$BIN/cookie_audit_dbg" "$AUDIT_DIR" > /dev/null || fail "build native_dbg"
  pionc build --release -o "$BIN/cookie_audit_rel" "$AUDIT_DIR" > /dev/null || fail "build native_rel"
  pionc build --target wasm32 -o "$BIN/cookie_audit_dbg.wasm" "$AUDIT_DIR" > /dev/null || fail "build wasm_dbg"
  pionc build --release --target wasm32 -o "$BIN/cookie_audit_rel.wasm" "$AUDIT_DIR" > /dev/null || fail "build wasm_rel"
  M="$AUDIT_DIR/diff/oracle/Cargo.toml"
  { CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline --manifest-path "$M" 2> /dev/null ||
    CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --manifest-path "$M"; } || fail "cargo build oracle"
  cp "$AUDIT_OUT/rust-target/release/cookie_audit_oracle" "$BIN/oracle"
  rm -rf "$C" && $PY "$AUDIT_DIR/diff/gen.py" "$C" "$FUZZ_N" | tr '\n' ' ' | sed 's/^/  corpus: /'
  echo
  echo "  $(pionc --version) | node $(node --version) | $(cargo --version) | cookie =0.18.3, psl =2.1.261"
}

portability() {
  echo "==> portability: packages/cookie/src: 0 extern \"C\", 0 World, 0 imports, 0 deps, 0 module-level mutable state"
  SRC=$(cat "$PKG_DIR"/src/*.pion | grep -v '^ *//')
  n=$(printf '%s\n' "$SRC" | grep -c 'extern "C"')
  echo "  extern \"C\": $n"; [ "$n" = 0 ] || fail "extern \"C\" in packages/cookie/src"
  n=$(printf '%s\n' "$SRC" | grep -cw 'World')
  echo "  World: $n"; [ "$n" = 0 ] || fail "World in packages/cookie/src"
  n=$(printf '%s\n' "$SRC" | grep -c '^import ')
  echo "  imports: $n"; [ "$n" = 0 ] || fail "imports in packages/cookie/src"
  deps=$(sed -n '/^\[dependencies\]/,/^\[/p' "$PKG_DIR/pion.toml" | grep -vc '^\[\|^ *$\|^#')
  echo "  pion.toml [dependencies] entries: $deps"; [ "$deps" = 0 ] || fail "external dependencies"
  n=$(printf '%s\n' "$SRC" | grep -cE '^(pub )?let mut ')
  echo "  module-level let mut: $n"; [ "$n" = 0 ] || fail "module-level let mut"
  m=$(grep -nE '^(pub )?let [a-zA-Z_0-9]+ *: *(Array|Bytes|Map|FixedArray|StringBuilder|Ref)' "$PKG_DIR"/src/*.pion | sed "s|$PKG_DIR/||")
  echo "  module-level lets: $(printf '%s\n' "$SRC" | grep -cE '^(pub )?let ')"
  [ -z "$m" ] || { printf '%s\n' "$m"; fail "module-level mutable container"; }
  n=$(grep -c 'struct CookieJar' "$PKG_DIR/src/jar.pion")
  echo "  CookieJar is the only mutable public type (pub struct with mut field / Array): $n"
  echo "  Send probe: public values crossing a spawn boundary"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\ncookie = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  for v in "cookie::parse_set_cookie(\"a=b\")" "cookie::Cookie::new(\"a\", \"b\")" "cookie::RequestContext::http(\"https://e.com/\", 0L)" \
    "cookie::public_suffix_info(\"a.co.uk\", true)" "cookie::JarLimits::default()"; do
    printf 'import "cookie"\n\n///|\npub fn main(world : World) -> Int {\n  let v = %s\n  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })\n  0\n}\n' "$v" > "$P/src/main.pion"
    r=$(pionc check --json "$P" 2>&1 | $PY -c 'import json,sys; d=json.load(sys.stdin); print("Send" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))')
    printf '    %-58s %s\n' "$v" "$r"
    [ "$r" = Send ] || fail "$v is not Send"
  done
}

unit() {
  echo "==> unit: pionc fmt/check/test of packages/cookie, pionc test of audit (control_* must pass)"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/cookie"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/cookie"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> /dev/null
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit_audit.json" 2> "$AUDIT_OUT/unit_audit.stderr"
  $PY - "$AUDIT_OUT/unit_pkg.json" "$AUDIT_OUT/unit_audit.json" <<'PY' || fail "unit tests"
import json, sys
pkg = json.load(open(sys.argv[1]))
print("  packages/cookie own tests: %d/%d pass" % (pkg["passed"], pkg["total"]))
bad = pkg["failed"]
d = json.load(open(sys.argv[2]))
n = {"PASS": 0, "OPEN": 0, "FAIL": 0}
for t in d["tests"]:
    if t.get("pkg") != "cookie_audit":
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
  names=$("$BIN/cookie_audit_rel" list)
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
  sed 's/^/    /' "$AUDIT_OUT/cases_native_rel.txt" | cut -c1-230
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/cases_native_rel.txt" "$AUDIT_OUT/cases_$m.txt" || { diff "$AUDIT_OUT/cases_native_rel.txt" "$AUDIT_OUT/cases_$m.txt" | head -6; fail "case results of $m differ from native_rel"; }
  done
  grep -q 'ABORT' "$AUDIT_OUT"/cases_*.txt && fail "a case aborted (panic / trap)"
  grep -q '^FAIL control_' "$AUDIT_OUT/cases_native_rel.txt" && fail "control case failing"
  for f in $(grep '^FAIL redteam_' "$AUDIT_OUT/cases_native_rel.txt" | awk '{print $2}'); do
    id=$(echo "$f" | sed -E 's/redteam_p([0-9])_([0-9]+)_.*/P\1-\2/')
    open_finding "$id: case $f"
    case "$f" in redteam_p0_*) fail "P0 red-team case $f" ;; esac
  done
}

determinism() {
  echo "==> determinism: every corpus (+ DoS bombs, API sweep) in all 4 modes must be byte-identical"
  $PY "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos" --list-only > /dev/null
  for g in $LINE_MODES testpsl; do
    mode=$g
    [ "$g" = testpsl ] && mode=psl
    for m in $MODES; do
      # shellcheck disable=SC2046
      $(runner $m) "$mode" "$C/$g.cases" > "$AUDIT_OUT/pion_${g}_$m.txt" 2> "$AUDIT_OUT/pion_${g}_$m.err" || fail "$g: $m exited non-zero ($(tail -1 "$AUDIT_OUT/pion_${g}_$m.err"))"
    done
    for m in native_dbg wasm_dbg wasm_rel; do
      $CMP same "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_${g}_$m.txt" || fail "$g: $m differs from native_rel"
    done
    cp "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_$g.txt"
    echo "  [$g] $(wc -l < "$C/$g.cases" | tr -d ' ') input lines, $(wc -l < "$AUDIT_OUT/pion_$g.txt" | tr -d ' ') output lines, 4 modes byte-identical"
  done
  # the smaller DoS bombs in all 4 modes (the big ones run in `dos`)
  for f in "$AUDIT_OUT"/dos/bomb0[0-8].* "$AUDIT_OUT"/dos/bomb1[3-8].*; do
    mode=${f##*.}
    for m in $MODES; do
      # shellcheck disable=SC2046
      $(runner $m) "$mode" "$f" > "$AUDIT_OUT/bomb_$m.txt" 2>&1 || fail "$(basename "$f"): $m exited non-zero"
    done
    for m in native_dbg wasm_dbg wasm_rel; do
      cmp -s "$AUDIT_OUT/bomb_native_rel.txt" "$AUDIT_OUT/bomb_$m.txt" || fail "$(basename "$f"): $m differs from native_rel"
    done
  done
  echo "  [dos] 15 bombs (<= 1 MiB, <= 10k jar operations), 4 modes byte-identical"
  for m in $MODES; do
    # shellcheck disable=SC2046
    $(runner $m) api > "$AUDIT_OUT/api_$m.txt" 2>&1 || fail "api: $m exited non-zero"
  done
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/api_native_rel.txt" "$AUDIT_OUT/api_$m.txt" || fail "API sweep: $m differs from native_rel"
  done
  echo "  [api] $(wc -l < "$AUDIT_OUT/api_native_rel.txt" | tr -d ' ') lines, 4 modes byte-identical"
}

oracles() {
  echo "==> oracles: reference model (draft-22 + CHIPS + PSL algorithm + WHATWG URL), Rust cookie =0.18.3"
  : > "$AUDIT_OUT/found.txt"
  for g in $LINE_MODES; do
    env $(spec_env) $CMP spec "$g" "$C/$g.cases" "$AUDIT_OUT/pion_$g.txt" > "$AUDIT_OUT/spec_$g.txt" 2>&1
    r=$?
    grep -v '^FINDINGS' "$AUDIT_OUT/spec_$g.txt" | cut -c1-240
    for f in $(grep '^FINDINGS' "$AUDIT_OUT/spec_$g.txt" | cut -d' ' -f2-); do echo "$f" >> "$AUDIT_OUT/found.txt"; done
    [ $r = 1 ] && fail "unexplained divergence from the reference model ($g)"
  done
  echo "  -- Rust cookie =0.18.3 (not an RFC 6265bis parser: divergences where Pion == model are classified)"
  "$BIN/oracle" parse "$C/parse.cases" > "$AUDIT_OUT/rust_parse.txt" || fail "oracle crashed on parse"
  $CMP rustparse "$C/parse.cases" "$AUDIT_OUT/pion_parse.txt" "$AUDIT_OUT/rust_parse.txt" | cut -c1-200
  for id in $(sort -u "$AUDIT_OUT/found.txt"); do
    case "$id" in
      P1-1) open_finding "P1-1: nameless cookie with a __Secure-/__Host- value is stored (prefix bypass)" ;;
      P1-2) open_finding "P1-2: 'leave secure cookies alone' (§5.7 step 16) missing: insecure origins shadow Secure cookies" ;;
      P1-3) open_finding "P1-3: cookie identity ignores host-only-flag: subdomains replace / delete host-only cookies" ;;
      P1-4) open_finding "P1-4: cross-site responses / non-HTTP APIs set SameSite Lax/Strict/Default cookies" ;;
      P1-6) open_finding "P1-6: parse_request_url is not WHATWG: https://evil.com\\@good.com/ is read as good.com" ;;
      P2-1) open_finding "P2-1: invalid SameSite keeps an earlier value; Lax exemption ignores non-HTTP retrievals" ;;
      P2-2) open_finding "P2-2: an invalid later Path does not reset the cookie-path to the default-path" ;;
      P2-3) open_finding "P2-3: Domain loses two leading dots (Domain=..example.com accepted)" ;;
      P2-4) open_finding "P2-4: format_set_cookie writes a nameless value containing '=' as a named cookie" ;;
      P2-8) open_finding "P2-8: hosts are not canonicalised (trailing-dot IP, UTS #46 case / full stops)" ;;
      *) open_finding "$id: (reference model)" ;;
    esac
  done
}

psl() {
  echo "==> psl: embedded table vs pinned official list, Mozilla test_psl.txt, Rust psl =2.1.261, PSL perf breakdown"
  ok=1
  while read -r h f; do
    [ "$(shasum -a 256 "$AUDIT_DIR/psl/$f" | awk '{print $1}')" = "$h" ] || { fail "pinned psl/$f sha256 mismatch"; ok=0; }
  done <<EOF
$(grep -E '^[0-9a-f]{64}  ' "$AUDIT_DIR/psl/PINNED")
EOF
  [ $ok = 1 ] && echo "  pinned files: sha256 ok ($(head -1 "$AUDIT_DIR/psl/PINNED" | awk '{print $2}' | sed 's|.*/blob/||'))"
  rm -f "$AUDIT_OUT/psl_snapshot_differs"
  $CMP pslfile "$PKG_DIR/src/psl_data.pion" "$AUDIT_DIR/psl/public_suffix_list.dat" > "$AUDIT_OUT/psl_check.txt" 2>&1
  r=$?
  cat "$AUDIT_OUT/psl_check.txt"
  grep -q 'not strictly byte-sorted' "$AUDIT_OUT/psl_check.txt" && fail "embedded PSL table is not sorted / unique (binary search precondition)"
  if [ $r = 3 ]; then
    touch "$AUDIT_OUT/psl_snapshot_differs"
    echo "  (information) the package embeds another PSL snapshot: the model uses the embedded table from here on"
  fi
  $CMP pslindex "$PKG_DIR/src/psl_index.pion" "$PKG_DIR/src/psl_data.pion"
  r=$?
  [ $r = 1 ] && fail "generated PSL node index disagrees with the rule table"
  if [ -f "$PKG_DIR/src/psl_index.pion" ]; then
    # P2-11: a generated index needs its generator in the repository, or a PSL refresh cannot regenerate it
    gen=$(grep -rl 'psl_node_data' "$PKG_DIR" "$ROOT_DIR/scripts" 2> /dev/null | grep -v "^$AUDIT_DIR/" | grep -v "^$PKG_DIR/src/" |
      grep -vE '\.(md|txt|json)$' | head -1)
    if [ -n "$gen" ]; then echo "  index generator: ${gen#$ROOT_DIR/}"; else
      open_finding "P2-11: src/psl_index.pion is generated but no generator is in the repository (PSL refresh cannot rebuild it)"
    fi
  fi
  $CMP testpsl "$C/testpsl.expect" "$AUDIT_OUT/pion_testpsl.txt" || fail "Mozilla test_psl.txt vector mismatch"
  "$BIN/oracle" psl "$C/psl.cases" > "$AUDIT_OUT/rust_psl.txt" || fail "oracle crashed on psl"
  # shellcheck disable=SC2086
  $CMP rustpsl "$C/psl.cases" "$AUDIT_OUT/pion_psl.txt" "$AUDIT_OUT/rust_psl.txt" $NEWER_RULES ||
    [ -f "$AUDIT_OUT/psl_snapshot_differs" ] || fail "unexplained divergence from psl 2.1.261"
  # perf breakdown: binary searches per match (current algorithm vs one probe per level with node flags)
  $PY - "$AUDIT_DIR/diff" "$PKG_DIR/bench/gen_data.py" "$AUDIT_OUT/benchgen" <<'PY'
import os, subprocess, sys
sys.path.insert(0, sys.argv[1])
import spec_ref
subprocess.run(["python3", "-I", sys.argv[2], sys.argv[3]], stdout=subprocess.DEVNULL, check=True)
R = spec_ref.rules()
nodes = set()
for r in R:
    base = r[2:] if r.startswith("*.") else r.lstrip("!")
    labs = base.split(".")
    for i in range(len(labs)):
        nodes.add(".".join(labs[i:]))
cur = opt = cnt = 0
for d in open(os.path.join(sys.argv[3], "psl_corpus.txt")):
    d = d.strip()
    if not d or d.startswith(".") or spec_ref.is_ip_literal(d):
        continue
    labs = d.lower().rstrip(".").split(".")
    n = len(labs)
    for k in range(1, n + 1):
        s = ".".join(labs[n - k:])
        cur += 3 if k >= 2 else 2
        if "!" + s in R:
            break
    for k in range(1, n + 1):
        opt += 1
        if ".".join(labs[n - k:]) not in nodes:
            break
    cnt += 1
print("  bench corpus (information): the v0.1.0 walk needs %.2f binary searches per match (exception + exact +"
      " wildcard per label); a walk over per-node flags needs %.2f" % (cur / cnt, opt / cnt))
PY
}

dos() {
  echo "==> dos: parser / PSL / jar bombs, budgets in diff/dos.py (native_rel, then wasm_rel)"
  $PY "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos" "$BIN/cookie_audit_rel"
  r=$?
  [ $r = 1 ] && fail "DoS hard limit / crash (native_rel)"
  [ $r = 3 ] && open_finding "P2-6: algorithmic DoS: quadratic PSL label walk / Punycode / eviction after import_text"
  $PY "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos_wasm" node "$WASM_RT" "$BIN/cookie_audit_rel.wasm" > "$AUDIT_OUT/dos_wasm.log"
  r=$?
  echo "  wasm_rel: $(grep 'worst input' "$AUDIT_OUT/dos_wasm.log" | sed 's/^ *//'); $(grep -c 'OVER BUDGET' "$AUDIT_OUT/dos_wasm.log") over budget"
  [ $r = 1 ] && { grep 'P0' "$AUDIT_OUT/dos_wasm.log" | head -5; fail "DoS hard limit / crash (wasm_rel)"; }
}

api() {
  echo "==> api: extreme-value sweep (dates at the Int64 limits, Max-Age extremes, jar clocks at the Int64 limits)"
  grep -E '^!|violations|^jar|^format' "$AUDIT_OUT/api_native_rel.txt" | sed 's/^/  /' | cut -c1-200
  grep -q '^violations=' "$AUDIT_OUT/api_native_rel.txt" || fail "API sweep did not finish"
}

smoke() {
  echo "==> smoke: packages/cookie/wasm_smoke in 4 modes vs README.md (values parsed from README.md)"
  want=$($RD smoke_sha)
  $RD smoke_lines > "$AUDIT_OUT/smoke_want.txt"
  D="$AUDIT_OUT/smoke_bin" && mkdir -p "$D"
  pionc build -o "$D/n_dbg" "$PKG_DIR/wasm_smoke" > /dev/null || fail "wasm_smoke build native debug"
  pionc build --release -o "$D/n_rel" "$PKG_DIR/wasm_smoke" > /dev/null || fail "wasm_smoke build native release"
  pionc build --target wasm32 -o "$D/w_dbg.wasm" "$PKG_DIR/wasm_smoke" > /dev/null || fail "wasm_smoke build wasm32 debug"
  pionc build --release --target wasm32 -o "$D/w_rel.wasm" "$PKG_DIR/wasm_smoke" > /dev/null || fail "wasm_smoke build wasm32 release"
  : > "$AUDIT_OUT/smoke.txt"
  for x in "native debug|$D/n_dbg" "native release|$D/n_rel" "wasm32 debug|node $WASM_RT $D/w_dbg.wasm" "wasm32 release|node $WASM_RT $D/w_rel.wasm"; do
    label=${x%%|*}
    # shellcheck disable=SC2086
    ${x#*|} > "$AUDIT_OUT/smoke_out.txt" 2> /dev/null || fail "wasm_smoke $label exited non-zero"
    h=$(shasum -a 256 < "$AUDIT_OUT/smoke_out.txt" | awk '{print $1}')
    echo "  [$label] $(tail -1 "$AUDIT_OUT/smoke_out.txt" | cut -c1-70)...  sha256=$h"
    echo "$h" >> "$AUDIT_OUT/smoke.txt"
    cmp -s "$AUDIT_OUT/smoke_out.txt" "$AUDIT_OUT/smoke_want.txt" || fail "wasm_smoke $label stdout differs from README.md"
  done
  [ "$(sort -u "$AUDIT_OUT/smoke.txt" | wc -l | tr -d ' ')" = 1 ] || fail "wasm_smoke output differs between modes"
  [ "$(head -1 "$AUDIT_OUT/smoke.txt")" = "$want" ] || fail "wasm_smoke sha256 differs from README.md ($want)"
  echo "  README.md sha256: $want"
  got="$(wc -c < "$D/n_dbg" | tr -d ' ') $(wc -c < "$D/n_rel" | tr -d ' ') $(wc -c < "$D/w_dbg.wasm" | tr -d ' ') $(wc -c < "$D/w_rel.wasm" | tr -d ' ')"
  echo "$got" > "$AUDIT_OUT/smoke_sizes.txt"
  echo "  sizes in bytes (native dbg/rel, wasm32 dbg/rel): measured $got; README KiB: $($RD sizes)"
}

bench() {
  echo "==> bench: packages/cookie/bench/run_bench.sh as shipped (stdout SHA-256 identical, warmup >= 1, rounds >= 5)"
  sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || { tail -20 "$AUDIT_OUT/bench.log"; fail "run_bench.sh"; return; }
  grep -E '^\| `|PASS:|SHA-256 verified' "$AUDIT_OUT/bench.log" | sed 's/^/  /' | cut -c1-200
  $PY - /tmp/pion-cookie-bench "$README" "$AUDIT_DIR/diff/readme.py" > "$AUDIT_OUT/bench_check.txt" <<'PY'
import json, os, subprocess, sys
d, readme, rp = sys.argv[1], sys.argv[2], sys.argv[3]
ok = True
for sc, f, base in (("parse", "bench_parse.json", "rust_cookie"), ("psl", "bench_psl.json", "rust_psl")):
    j = json.load(open(os.path.join(d, f)))
    r = {x["name"]: x for x in j["results"]}
    good = bool(j.get("sha256")) and j["rounds"] >= 5 and j["warmup"] >= 1
    ok &= good
    pm, rm, ps = (float(x) for x in subprocess.run(["python3", "-I", rp, readme, "bench", sc], capture_output=True,
                                                     text=True).stdout.split())
    got = r["pion_cookie"]["speedup_vs_baseline"]
    print("  %s: sha256 %s; pion %.1f ms (README %.1f), %s %.1f ms (README %.1f), speedup %.2fx (README %.2fx)%s" % (
        sc, j.get("sha256", "?")[:16], r["pion_cookie"]["median_ms"], pm, base, r[base]["median_ms"], rm, got, ps,
        # README numbers are the package's: drift = Pion median off by > 35 %, or the speedup off by more than
        # 35 % and more than 0.02 (the README rounds to 2 decimals; the Rust side is noisy on a loaded machine)
        "" if abs(r["pion_cookie"]["median_ms"] - pm) <= 0.35 * pm and abs(got - ps) <= max(0.35 * ps, 0.02)
        else "  DRIFT"))
    with open(os.path.join(d, "audit_speedup_%s.txt" % sc), "w") as o:
        o.write("%f %f\n" % (got, ps))
sys.exit(0 if ok else 1)
PY
  r=$?
  cat "$AUDIT_OUT/bench_check.txt"
  [ $r = 0 ] || fail "shipped bench: output hash / protocol"
  # P2-9: PSL lookups >= 16x slower than psl 2.1.261 (2 full binary-search walks per op, see REPORT.md)
  sp=$(awk '{print $1}' /tmp/pion-cookie-bench/audit_speedup_psl.txt)
  if [ "$($PY -c 'import sys; print(int(float(sys.argv[1]) < 0.0625))' "$sp")" = 1 ]; then
    open_finding "P2-9: PSL lookup $(printf '%.3f' "$sp")x of psl 2.1.261 (~7.3 binary searches per match_psl_internal, 2 matches per op)"
  fi
}

docs() {
  echo "==> docs: README.md claims vs measurements (parsed from README.md)"
  issues=""
  rules_claim=$($RD rules)
  rules_got=$($PY - "$PKG_DIR/src/psl_data.pion" <<'PY'
import re, sys
lit = re.search(r'"(.*)"', open(sys.argv[1], encoding="utf-8").read(), re.S).group(1).encode().decode("unicode_escape")
rows = [l.rsplit("\t", 1) for l in lit.split("\n") if l]
print(len(rows), sum(1 for r in rows if r[1] == "I"), sum(1 for r in rows if r[1] == "P"), "%.1f" % (len(lit.encode()) / 1024))
PY
)
  echo "  PSL rules (total ICANN Private): README $rules_claim, embedded ${rules_got% *}"
  [ "$rules_claim" = "${rules_got% *}" ] || issues="$issues rule-counts"
  kib=$($RD table_kib)
  echo "  PSL table size: README $kib KiB, embedded ${rules_got##* } KiB"
  [ "$kib" = "${rules_got##* }" ] || issues="$issues table-KiB(${kib}KiB-claimed,${rules_got##* }KiB-real)"
  snap=$($RD psl_snapshot)
  echo "  PSL snapshot named in README: $snap"
  [ "$snap" = none ] && issues="$issues psl-snapshot-unnamed"
  tests=$($RD tests)
  got=$($PY -c 'import json,sys; print(json.load(open(sys.argv[1]))["total"])' "$AUDIT_OUT/unit_pkg.json" 2> /dev/null || echo "?")
  echo "  test groups: README $tests, pionc test $got"
  [ "$tests" = "$got" ] || issues="$issues test-count"
  dc=$($RD diffcounts)
  echo "  differential counts (parse ok/n, psl ok/n): README $dc; shipped corpora $(grep -c . /tmp/pion-cookie-bench/set_cookie_corpus.txt 2> /dev/null)/$(grep -c . /tmp/pion-cookie-bench/psl_corpus.txt 2> /dev/null)"
  set -- $($RD sizes)
  read -r a b c d < "$AUDIT_OUT/smoke_sizes.txt" 2> /dev/null || { a=0; b=0; c=0; d=0; }
  drift=$($PY -c 'import sys; v=[float(x) for x in sys.argv[1:5]]; g=[int(x)/1024 for x in sys.argv[5:9]]; print(" ".join("%.0f/%.0f" % (x, y) for x, y in zip(v, g)) + (" DRIFT" if any(abs(x - y) > 0.10 * y for x, y in zip(v, g)) else ""))' "$@" "$a" "$b" "$c" "$d")
  echo "  binary sizes KiB README/measured (native dbg, rel, wasm32 dbg, rel): $drift"
  case "$drift" in *DRIFT*) issues="$issues binary-sizes" ;; esac
  grep -q 'DRIFT' "$AUDIT_OUT/bench_check.txt" 2> /dev/null && issues="$issues bench-speedup"
  if [ -n "$issues" ]; then
    open_finding "P2-10: README.md claims:$issues"
  fi
}

harness() {
  echo "==> harness: the gates must catch injected bugs (mutated copies in \$AUDIT_OUT)"
  injected=0
  caught=0
  for bug in date_two_digit_year psl_exception prefix_host_path path_match_boundary ctl_allows_lf; do
    H="$AUDIT_OUT/inject_$bug" && rm -rf "$H" && mkdir -p "$H/cookie"
    cp -R "$PKG_DIR/pion.toml" "$PKG_DIR/src" "$AUDIT_DIR" "$H/cookie/"
    # each bug has alternatives so that it can still be injected into a fixed (rewritten) tree
    $PY - "$H/cookie/src" "$bug" <<'PY'
import os, re, sys
d, bug = sys.argv[1], sys.argv[2]
alts = {
    "date_two_digit_year": [("date.pion", r"year >= 70 && year <= 99", "year >= 69 && year <= 99"),
                            ("date.pion", r"(\w+) >= 70 && \1 <= 99", r"\1 >= 69 && \1 <= 99")],
    "psl_exception": [("psl.pion", r'psl_lookup\("!" \+', 'psl_lookup("?" +'), ("psl.pion", r'"!" \+ ', '"?" + ')],
    "prefix_host_path": [("parse.pion", r"has_domain \|\| !is_root_path \{\n(\s+return Err\(\n\s+CookieError::PrefixViolation\(\"__Host- )",
                          r"has_domain {\n\1"),
                         ("parse.pion", r"\|\| !is_root_path \{\n(\s+return Err\(\n\s+CookieError::PrefixViolation\(\"__Host- )", r"{\n\1")],
    "path_match_boundary": [("parse.pion", r"request_path\.code_unit_at\(clen\) == 47", "true"),
                            ("parse.pion", r"(\w+)\.code_unit_at\((\w+)\) == 47\n\}", "true\n}")],
    "ctl_allows_lf": [("parse.pion", r"\(c >= 10 && c <= 31\)", "(c >= 11 && c <= 31)"),
                      ("parse.pion", r"c >= 10 && c <= 31", "c >= 11 && c <= 31")],
}[bug]
for p, pat, new in alts:
    path = os.path.join(d, p)
    if not os.path.exists(path):
        continue
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
    HB="$H/cookie/audit"
    if ! pionc build --release -o "$H/cli" "$HB" > /dev/null 2>&1; then
      echo "  injected $bug: CAUGHT (does not build)"
      caught=$((caught + 1))
      continue
    fi
    why=""
    for c in $("$H/cli" list); do
      case "$c" in control_*) "$H/cli" case "$c" | grep -q '^FAIL' && why="$why $c" ;; esac
    done
    for g in $LINE_MODES; do
      "$H/cli" "$g" "$C/$g.cases" > "$H/out_$g.txt" 2> /dev/null || why="$why crash:$g"
      env $(spec_env) $CMP spec "$g" "$C/$g.cases" "$H/out_$g.txt" > "$H/spec_$g.txt" 2>&1
      [ $? = 1 ] && why="$why model:$g"
    done
    "$H/cli" psl "$C/testpsl.cases" > "$H/out_testpsl.txt" 2> /dev/null
    $CMP testpsl "$C/testpsl.expect" "$H/out_testpsl.txt" > /dev/null || why="$why test_psl"
    if [ -n "$why" ]; then
      caught=$((caught + 1))
      echo "  injected $bug: CAUGHT by$(echo "$why" | tr ' ' '\n' | sort -u | head -6 | tr '\n' ' ')"
    else
      echo "  injected $bug: MISSED"
      fail "gates miss injected bug $bug"
    fi
  done
  echo "  harness: $caught/$injected injected bugs caught"
}

case "$SECTION" in
  all)
    build
    for s in portability unit cases determinism oracles psl dos api smoke bench docs harness; do "$s"; done ;;
  build | portability | unit | cases | determinism | oracles | psl | dos | api | smoke | bench | docs | harness) "$SECTION" ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
echo
if [ -n "$OPEN" ]; then
  echo "OPEN findings (P1/P2):$OPEN"
fi
if [ "$RC" != 0 ]; then
  echo "RESULT: P0 conditions reproduce (see FAIL lines above)"
  exit 1
fi
if [ -n "$OPEN" ] && [ "$STRICT" = 1 ]; then
  echo "RESULT: no P0; STRICT=1 and P1/P2 findings are open"
  exit 1
fi
if [ -n "$OPEN" ]; then
  echo "RESULT: no P0 (open P1/P2 findings listed above; STRICT=1 makes them fatal)"
else
  echo "RESULT: clean"
fi
exit 0
