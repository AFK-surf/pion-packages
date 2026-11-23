#!/bin/sh
# One-shot red-team audit for packages/gif (see AUDIT_REPORT.md).
#   sh packages/gif/audit/run_audit.sh [all|build|selftest|unit|diff|fuzz|dos|wasm_dos|portability|bench]
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), go >= 1.22 (image/gif oracle), python3.
# Artifacts go to $AUDIT_OUT (default /private/tmp/pion-gif-audit: the real path of /tmp on macOS, because the
# wasm32 runner resolves symlinks). Nothing is written inside the repository.
# Exit status: 0 only when every red-team case, control, differential and DoS budget passes.
set -u
export PATH="$HOME/.pion/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-gif-audit}
if [ ! -d /private/tmp ] && [ "$AUDIT_OUT" = /private/tmp/pion-gif-audit ]; then AUDIT_OUT=/tmp/pion-gif-audit; fi
BIN="$AUDIT_OUT/bin"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
FUZZ_N=${FUZZ_N:-30000}
CORPUS_N=${CORPUS_N:-400}
mkdir -p "$BIN"
export PYTHONDONTWRITEBYTECODE=1
RC=0
fail() { echo "  FAIL: $*"; RC=1; }

# mode -> runner command prefix
runner() {
  case "$1" in
    native_dbg) echo "$BIN/gif_audit_dbg" ;;
    native_rel) echo "$BIN/gif_audit_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/gif_audit_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/gif_audit_rel.wasm" ;;
  esac
}
MODES="native_dbg native_rel wasm_dbg wasm_rel"

build() {
  echo "==> build: gif_audit in 4 modes, Go image/gif oracle"
  pionc fmt --check "$AUDIT_DIR" || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  pionc build -o "$BIN/gif_audit_dbg" "$AUDIT_DIR" || fail "build native_dbg"
  pionc build --release -o "$BIN/gif_audit_rel" "$AUDIT_DIR" || fail "build native_rel"
  pionc build --target wasm32 -o "$BIN/gif_audit_dbg.wasm" "$AUDIT_DIR" || fail "build wasm_dbg"
  pionc build --release --target wasm32 -o "$BIN/gif_audit_rel.wasm" "$AUDIT_DIR" || fail "build wasm_rel"
  rm -rf "$AUDIT_OUT/gosrc" && mkdir -p "$AUDIT_OUT/gosrc"
  cp "$AUDIT_DIR/diff/go/go.mod" "$AUDIT_DIR/diff/go/main.go" "$AUDIT_OUT/gosrc/"
  (cd "$AUDIT_OUT/gosrc" && GOFLAGS=-mod=mod go build -o "$BIN/gifdiff" .) || fail "go build gifdiff"
  echo "  $(go version)  |  $(pionc --version)  |  node $(node --version)"
}

selftest() {
  echo "==> selftest: every red-team/control case in native_dbg, native_rel, wasm_dbg, wasm_rel"
  for m in $MODES; do
    # shellcheck disable=SC2046
    $(runner $m) selftest > "$AUDIT_OUT/selftest_$m.txt" 2>&1
    echo "  $m: $(tail -1 "$AUDIT_OUT/selftest_$m.txt")"
  done
  sed 's/^/    /' "$AUDIT_OUT/selftest_native_rel.txt" | grep -v '^    selftest:'
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/selftest_native_rel.txt" "$AUDIT_OUT/selftest_$m.txt" || fail "selftest output of $m differs from native_rel"
  done
  grep -q '^FAIL' "$AUDIT_OUT/selftest_native_rel.txt" && fail "red-team cases failing (see above)"
  grep -q '^selftest:' "$AUDIT_OUT/selftest_native_rel.txt" || fail "selftest did not complete"
  echo "==> wasm_smoke (packages/gif's own 4-mode smoke)"
  for flags in "" "--release" "--target wasm32" "--release --target wasm32"; do
    # shellcheck disable=SC2086
    out=$(pionc run $flags "$PKG_DIR/wasm_smoke" 2>&1 | tail -1)
    echo "  [${flags:-native dbg}] $out"
    echo "$out" >> "$AUDIT_OUT/smoke.txt.new"
  done
  [ "$(sort -u "$AUDIT_OUT/smoke.txt.new" | wc -l | tr -d ' ')" = 1 ] || fail "wasm_smoke output differs between modes"
  grep -q "OK" "$AUDIT_OUT/smoke.txt.new" || fail "wasm_smoke failed"
  rm -f "$AUDIT_OUT/smoke.txt.new"
}

unit() {
  echo "==> unit: pionc test (audit redteam_*/control_* + packages/gif's own suite), fmt/check of the package"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/gif"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/gif"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> /dev/null
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit_audit.json" 2> "$AUDIT_OUT/unit_audit.stderr"
  python3 -I - "$AUDIT_OUT/unit_pkg.json" "$AUDIT_OUT/unit_audit.json" <<'PY' || RC=1
import json, sys
bad = 0
pkg = json.load(open(sys.argv[1]))
print("  packages/gif own tests: %d/%d pass" % (pkg["passed"], pkg["total"]))
bad += pkg["failed"]
d = json.load(open(sys.argv[2]))
for t in d["tests"]:
    if t["pkg"] != "gif_audit":
        continue
    print("  %s  %s" % ("PASS" if t["ok"] else "FAIL", t["name"]))
    bad += 0 if t["ok"] else 1
sys.exit(1 if bad else 0)
PY
}

diff_corpus() {
  echo "==> diff: structured + random corpus (seed 1, $CORPUS_N random) vs Go image/gif, every mode"
  rm -rf "$AUDIT_OUT/corpus" && "$BIN/gifdiff" gen "$AUDIT_OUT/corpus" 1 "$CORPUS_N" | sed 's/^/  /'
  for m in $MODES; do
    echo "  [$m]"
    # shellcheck disable=SC2046
    python3 -I "$AUDIT_DIR/diff/compare.py" strict "$AUDIT_OUT/corpus" "$BIN/gifdiff" $(runner $m) digest || fail "corpus differential ($m)"
  done
}

fuzz() {
  echo "==> fuzz: $FUZZ_N byte-level mutants vs Go image/gif (native_rel, wasm_rel)"
  [ -d "$AUDIT_OUT/corpus" ] || "$BIN/gifdiff" gen "$AUDIT_OUT/corpus" 1 "$CORPUS_N" > /dev/null
  rm -rf "$AUDIT_OUT/fuzz" && "$BIN/gifdiff" mutate "$AUDIT_OUT/corpus" "$AUDIT_OUT/fuzz" 7 "$FUZZ_N" | sed 's/^/  /'
  for m in native_rel wasm_rel; do
    echo "  [$m]"
    # shellcheck disable=SC2046
    python3 -I "$AUDIT_DIR/diff/compare.py" fuzz "$AUDIT_OUT/fuzz" "$BIN/gifdiff" $(runner $m) digest || fail "fuzz differential ($m)"
  done
}

dos() {
  echo "==> dos: bombs with verdict + wall-clock budget (native_rel)"
  mkdir -p "$AUDIT_OUT/dos" && "$BIN/gif_audit_rel" gen_dos "$AUDIT_OUT/dos" > /dev/null
  python3 -I "$AUDIT_DIR/diff/dos.py" native "$AUDIT_OUT/dos" "$BIN/gif_audit_rel" || fail "DoS budget / verdict"
}

wasm_dos() {
  echo "==> wasm_dos: same GIF bombs under wasm32 release (information only)"
  [ -f "$AUDIT_OUT/dos/canvas_65535sq.gif" ] || "$BIN/gif_audit_rel" gen_dos "$AUDIT_OUT/dos" > /dev/null
  # shellcheck disable=SC2046
  python3 -I "$AUDIT_DIR/diff/dos.py" wasm "$AUDIT_OUT/dos" $(runner wasm_rel)
}

portability() {
  echo "==> portability: packages/gif/src must have 0 extern \"C\", 0 World, 0 module-level mutable state"
  n=$(grep -c 'extern "C"' "$PKG_DIR"/src/*.pion | awk -F: '{s+=$2} END {print s}')
  echo "  extern \"C\": $n"; [ "$n" = 0 ] || fail "extern \"C\" in packages/gif/src"
  n=$(grep -cw 'World' "$PKG_DIR"/src/*.pion | awk -F: '{s+=$2} END {print s}')
  echo "  World: $n"; [ "$n" = 0 ] || fail "World in packages/gif/src"
  n=$(grep -cE '^(pub )?let mut|^(pub )?let [a-zA-Z_0-9]+ *: *(Array|Bytes|Map|FixedArray|Mutex|AtomicInt)' "$PKG_DIR"/src/*.pion | awk -F: '{s+=$2} END {print s}')
  echo "  module-level mutable bindings: $n"; [ "$n" = 0 ] || fail "module-level mutable state in packages/gif/src"
  echo "  Send probe (information): which public results may cross a spawn boundary"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\ngif = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  for v in "gif::DecodeLimits::default()" "gif::decode(Bytes::new(0))" "gif::probe_header(Bytes::new(0))"; do
    printf 'import "gif"\n\n///|\npub fn main(world : World) -> Int {\n  let v = %s\n  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })\n  0\n}\n' "$v" > "$P/src/main.pion"
    r=$(pionc check --json "$P" 2>&1 | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("Send" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))')
    printf '    %-36s %s\n' "$v" "$r"
  done
}

bench() {
  echo "==> bench: packages/gif/bench/run_bench.sh (Pion --release vs Go image/gif), fairness gates"
  sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || { tail -20 "$AUDIT_OUT/bench.log"; fail "run_bench.sh"; return; }
  python3 -I - /tmp/pion-gif-bench/bench_static.json /tmp/pion-gif-bench/bench_anim.json <<'PY' || RC=1
import json, sys
bad = 0
for f in sys.argv[1:]:
    d = json.load(open(f))
    r = {x["name"]: x for x in d["results"]}
    p = r["pion"]
    print("  %-70s pion %.1f ms (min %.1f, p95 %.1f)  go %.1f ms  speedup %.2fx  sha256 %s" % (
        d["title"][:70], p["median_ms"], p["min_ms"], p["p95_ms"], r["go_image_gif"]["median_ms"],
        p["speedup_vs_baseline"], d["sha256"][:16]))
    if p["median_ms"] < 40 or r["go_image_gif"]["median_ms"] < 40:
        print("    FAIL: steady-state median < 40 ms"); bad += 1
    if p["speedup_vs_baseline"] < 1.0:
        print("    FAIL: Pion slower than Go"); bad += 1
    if d["rounds"] < 5 or d["warmup"] < 1:
        print("    FAIL: fewer than warmup 1 / rounds 5"); bad += 1
sys.exit(1 if bad else 0)
PY
}

clean_check() {
  d=$(git -C "$ROOT_DIR" status --porcelain --ignored -- packages/gif | grep -v '^?? packages/gif/audit/$')
  [ -z "$d" ] || { echo "$d"; fail "worktree not clean after audit"; }
}

case "$SECTION" in
  build) build ;;
  selftest) selftest ;;
  unit) unit ;;
  diff) diff_corpus ;;
  fuzz) fuzz ;;
  dos) dos ;;
  wasm_dos) wasm_dos ;;
  portability) portability ;;
  bench) bench ;;
  all)
    build
    selftest
    unit
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
