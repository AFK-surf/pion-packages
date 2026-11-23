#!/bin/sh
# One-shot red-team audit for packages/webp (see AUDIT_REPORT.md).
#   sh packages/webp/audit/run_audit.sh [all|build|cases|unit|vectors|diff|fuzz|dos|wasm_dos|portability|bench]
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), go >= 1.22 (golang.org/x/image v0.48.0 oracle, from the
# module cache or the network), cwebp + dwebp (libwebp: corpus generation and tie-break oracle), python3.
# Artifacts go to $AUDIT_OUT (default /private/tmp/pion-webp-audit: the real path of /tmp on macOS, because the
# wasm32 runner resolves symlinks). Nothing is written inside the repository.
# Exit status: 0 only when every red-team case, control, vector, differential and DoS budget passes.
set -u
export PATH="$HOME/.pion/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-webp-audit}
if [ ! -d /private/tmp ] && [ "$AUDIT_OUT" = /private/tmp/pion-webp-audit ]; then AUDIT_OUT=/tmp/pion-webp-audit; fi
BIN="$AUDIT_OUT/bin"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
FUZZ_N=${FUZZ_N:-10000}
CORPUS_N=${CORPUS_N:-160}
mkdir -p "$BIN"
export PYTHONDONTWRITEBYTECODE=1
RC=0
fail() { echo "  FAIL: $*"; RC=1; }

# mode -> runner command prefix
runner() {
  case "$1" in
    native_dbg) echo "$BIN/webp_audit_dbg" ;;
    native_rel) echo "$BIN/webp_audit_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/webp_audit_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/webp_audit_rel.wasm" ;;
  esac
}
MODES="native_dbg native_rel wasm_dbg wasm_rel"

build() {
  echo "==> build: webp_audit in 4 modes, Go x/image/webp oracle + generator"
  pionc fmt --check "$AUDIT_DIR" > /dev/null || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  pionc build -o "$BIN/webp_audit_dbg" "$AUDIT_DIR" || fail "build native_dbg"
  pionc build --release -o "$BIN/webp_audit_rel" "$AUDIT_DIR" || fail "build native_rel"
  pionc build --target wasm32 -o "$BIN/webp_audit_dbg.wasm" "$AUDIT_DIR" || fail "build wasm_dbg"
  pionc build --release --target wasm32 -o "$BIN/webp_audit_rel.wasm" "$AUDIT_DIR" || fail "build wasm_rel"
  rm -rf "$AUDIT_OUT/gosrc" && mkdir -p "$AUDIT_OUT/gosrc"
  cp "$AUDIT_DIR/diff/go/go.mod" "$AUDIT_DIR/diff/go/go.sum" "$AUDIT_DIR/diff/go/main.go" "$AUDIT_OUT/gosrc/"
  (cd "$AUDIT_OUT/gosrc" && GOFLAGS=-mod=mod go build -o "$BIN/webpdiff" .) || fail "go build webpdiff"
  echo "  $(go version)  |  $(pionc --version)  |  node $(node --version)  |  $(cwebp -version 2>&1 | head -1 | sed 's/^/libwebp /')"
}

cases() {
  echo "==> cases: every red-team/control case, one process per case, in native_dbg, native_rel, wasm_dbg, wasm_rel"
  names=$("$BIN/webp_audit_rel" list)
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
  sed 's/^/    /' "$AUDIT_OUT/cases_native_rel.txt" | cut -c1-260
  # verdicts must agree across modes (abort messages are worded differently by the native and wasm runtimes)
  for m in $MODES; do sed 's/ :: ABORT (.*/ :: ABORT/' "$AUDIT_OUT/cases_$m.txt" > "$AUDIT_OUT/cases_$m.norm"; done
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/cases_native_rel.norm" "$AUDIT_OUT/cases_$m.norm" || { diff "$AUDIT_OUT/cases_native_rel.norm" "$AUDIT_OUT/cases_$m.norm" | head -6; fail "case results of $m differ from native_rel"; }
  done
  grep -q '^FAIL' "$AUDIT_OUT/cases_native_rel.txt" && fail "red-team cases failing (see above)"
  echo "==> wasm_smoke (packages/webp's own 4-mode smoke)"
  rm -f "$AUDIT_OUT/smoke.txt.new"
  for flags in "" "--release" "--target wasm32" "--release --target wasm32"; do
    # shellcheck disable=SC2086
    out=$(pionc run $flags "$PKG_DIR/wasm_smoke" 2>&1 | tail -1)
    echo "  [${flags:-native dbg}] $out"
    echo "$out" >> "$AUDIT_OUT/smoke.txt.new"
  done
  [ "$(sort -u "$AUDIT_OUT/smoke.txt.new" | wc -l | tr -d ' ')" = 1 ] || fail "wasm_smoke output differs between modes"
}

unit() {
  echo "==> unit: pionc test (audit redteam_*/control_* + packages/webp's own suite), fmt/check of the package"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/webp"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/webp"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> /dev/null
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit_audit.json" 2> "$AUDIT_OUT/unit_audit.stderr"
  python3 -I - "$AUDIT_OUT/unit_pkg.json" "$AUDIT_OUT/unit_audit.json" "$AUDIT_OUT/unit_audit.stderr" <<'PY' || RC=1
import json, sys
bad = 0
pkg = json.load(open(sys.argv[1]))
print("  packages/webp own tests: %d/%d pass" % (pkg["passed"], pkg["total"]))
bad += pkg["failed"]
try:
    d = json.load(open(sys.argv[2]))
except Exception:
    err = open(sys.argv[3]).read().strip().splitlines()
    print("  FAIL audit test run aborted: %s" % (err[-1] if err else "no JSON"))
    sys.exit(1)
for t in d["tests"]:
    if t["pkg"] != "webp_audit":
        continue
    print("  %s  %s" % ("PASS" if t["ok"] else "FAIL", t["name"]))
    bad += 0 if t["ok"] else 1
sys.exit(1 if bad else 0)
PY
}

vectors() {
  echo "==> vectors: audit/vectors/*.webp against libwebp-adjudicated digests, every mode"
  for m in $MODES; do
    echo "  [$m]"
    # shellcheck disable=SC2046
    python3 -I "$AUDIT_DIR/diff/vectors.py" "$AUDIT_DIR/vectors" $(runner $m) || fail "vectors ($m)"
  done
}

gen_corpus() {
  [ -f "$AUDIT_OUT/corpus/.done" ] && return
  rm -rf "$AUDIT_OUT/corpus" && "$BIN/webpdiff" gen "$AUDIT_OUT/corpus" 1 "$CORPUS_N" | sed 's/^/  /'
  touch "$AUDIT_OUT/corpus/.done"
}

diff_corpus() {
  echo "==> diff: cwebp matrix + VP8X/ALPH composites + random VP8/VP8L (seed 1) vs x/image/webp (+ libwebp), every mode"
  rm -f "$AUDIT_OUT/corpus/.done"
  gen_corpus
  for m in $MODES; do
    echo "  [$m]"
    # shellcheck disable=SC2046
    python3 -I "$AUDIT_DIR/diff/compare.py" strict "$AUDIT_OUT/corpus" "$BIN/webpdiff" $(runner $m) digest || fail "corpus differential ($m)"
  done
}

fuzz() {
  echo "==> fuzz: $FUZZ_N byte-level mutants vs x/image/webp (+ libwebp) (native_rel, wasm_rel)"
  gen_corpus
  rm -rf "$AUDIT_OUT/fuzz" && "$BIN/webpdiff" mutate "$AUDIT_OUT/corpus" "$AUDIT_OUT/fuzz" 7 "$FUZZ_N" | sed 's/^/  /'
  for m in native_rel wasm_rel; do
    echo "  [$m]"
    # shellcheck disable=SC2046
    COMPARE_DUMP="$AUDIT_OUT/fuzz_pion_$m.txt" python3 -I "$AUDIT_DIR/diff/compare.py" fuzz "$AUDIT_OUT/fuzz" "$BIN/webpdiff" $(runner $m) digest > "$AUDIT_OUT/fuzz_$m.txt" 2>&1 || fail "fuzz differential ($m)"
    cat "$AUDIT_OUT/fuzz_$m.txt"
  done
  # native and wasm32 must agree on every mutant (verdict, size, SHA-256; aborts compared by message)
  if cmp -s "$AUDIT_OUT/fuzz_pion_native_rel.txt" "$AUDIT_OUT/fuzz_pion_wasm_rel.txt"; then
    echo "  native_rel == wasm_rel on all $(wc -l < "$AUDIT_OUT/fuzz_pion_native_rel.txt" | tr -d ' ') mutants"
  else
    diff "$AUDIT_OUT/fuzz_pion_native_rel.txt" "$AUDIT_OUT/fuzz_pion_wasm_rel.txt" | head -6
    fail "native_rel and wasm_rel results differ on mutants"
  fi
}

dos() {
  echo "==> dos: bombs with verdict + wall-clock + peak-RSS budget (native_rel)"
  rm -rf "$AUDIT_OUT/dos" && mkdir -p "$AUDIT_OUT/dos" && "$BIN/webp_audit_rel" gen_dos "$AUDIT_OUT/dos" > /dev/null
  python3 -I "$AUDIT_DIR/diff/dos.py" native "$AUDIT_OUT/dos" "$BIN/webp_audit_rel" || fail "DoS budget / verdict"
}

wasm_dos() {
  echo "==> wasm_dos: same bombs under wasm32 release (information only; RSS includes node)"
  [ -f "$AUDIT_OUT/dos/vp8_16383sq.webp" ] || { mkdir -p "$AUDIT_OUT/dos" && "$BIN/webp_audit_rel" gen_dos "$AUDIT_OUT/dos" > /dev/null; }
  # shellcheck disable=SC2046
  python3 -I "$AUDIT_DIR/diff/dos.py" wasm "$AUDIT_OUT/dos" $(runner wasm_rel)
}

portability() {
  echo "==> portability: packages/webp/src must have 0 extern \"C\", 0 World, 0 module-level mutable state"
  n=$(grep -c 'extern "C"' "$PKG_DIR"/src/*.pion | awk -F: '{s+=$2} END {print s}')
  echo "  extern \"C\": $n"; [ "$n" = 0 ] || fail "extern \"C\" in packages/webp/src"
  n=$(grep -cw 'World' "$PKG_DIR"/src/*.pion | awk -F: '{s+=$2} END {print s}')
  echo "  World: $n"; [ "$n" = 0 ] || fail "World in packages/webp/src"
  n=$(grep -cE '^(pub )?let mut|^(pub )?let [a-zA-Z_0-9]+ *: *(Array|Bytes|Map|Mutex|AtomicInt)' "$PKG_DIR"/src/*.pion | awk -F: '{s+=$2} END {print s}')
  echo "  module-level mutable bindings (let mut / Array / Bytes / Map): $n"; [ "$n" = 0 ] || fail "module-level mutable state in packages/webp/src"
  tables=$(grep -hoE '^let [a-z_0-9]+ *: *FixedArray' "$PKG_DIR"/src/*.pion | awk '{print $2}')
  w=0
  for t in $tables; do
    c=$(grep -hE "(^|[^a-z_])$t\[[^]]*\] *=[^=]" "$PKG_DIR"/src/*.pion | wc -l | tr -d ' ')
    w=$((w + c))
  done
  echo "  module-level FixedArray lookup tables: $(echo "$tables" | wc -w | tr -d ' '), element writes to them: $w"
  [ "$w" = 0 ] || fail "module-level lookup table written at run time"
  echo "  Send probe (information): which public results may cross a spawn boundary"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\nwebp = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  for v in "webp::DecodeLimits::default()" "webp::decode(Bytes::new(0))" "webp::probe_header(Bytes::new(0))"; do
    printf 'import "webp"\n\n///|\npub fn main(world : World) -> Int {\n  let v = %s\n  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })\n  0\n}\n' "$v" > "$P/src/main.pion"
    r=$(pionc check --json "$P" 2>&1 | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("Send" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))')
    printf '    %-40s %s\n' "$v" "$r"
  done
}

bench() {
  echo "==> bench: packages/webp/bench/run_bench.sh (Pion --release vs Go x/image/webp), fairness gates"
  sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || { tail -20 "$AUDIT_OUT/bench.log"; fail "run_bench.sh"; return; }
  python3 -I - /tmp/pion-webp-bench/bench_vp8l.json /tmp/pion-webp-bench/bench_vp8.json /tmp/pion-webp-bench/bench_vp8x_alph.json <<'PY' || RC=1
import json, sys
bad = 0
for f in sys.argv[1:]:
    d = json.load(open(f))
    r = {x["name"]: x for x in d["results"]}
    p, g = r["pion"], r["go_x_image_webp"]
    print("  %-52s pion %6.1f ms (min %6.1f, p95 %6.1f)  go %6.1f ms  speedup %.2fx  sha256 %s" % (
        d["title"][:52], p["median_ms"], p["min_ms"], p["p95_ms"], g["median_ms"], p["speedup_vs_baseline"], d["sha256"][:16]))
    if d["rounds"] < 5 or d["warmup"] < 1:
        print("    FAIL: fewer than warmup 1 / rounds 5"); bad += 1
sys.exit(1 if bad else 0)
PY
}

clean_check() {
  d=$(git -C "$ROOT_DIR" status --porcelain --ignored -- packages/webp | grep -v '^?? packages/webp/audit/$')
  [ -z "$d" ] || { echo "$d"; fail "worktree not clean after audit"; }
}

case "$SECTION" in
  build) build ;;
  cases) cases ;;
  unit) unit ;;
  vectors) vectors ;;
  diff) diff_corpus ;;
  fuzz) fuzz ;;
  dos) dos ;;
  wasm_dos) wasm_dos ;;
  portability) portability ;;
  bench) bench ;;
  all)
    build
    cases
    unit
    vectors
    diff_corpus
    fuzz
    dos
    wasm_dos
    portability
    bench
    ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
clean_check
if [ "$RC" = 0 ]; then echo "AUDIT PASS"; else echo "AUDIT FAIL (red-team findings reproduced; see AUDIT_REPORT.md)"; fi
exit $RC
