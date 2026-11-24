#!/bin/sh
# One-shot red-team audit for packages/exif (see REPORT.md).
#   sh packages/exif/audit/run_audit.sh [all|build|cases|unit|diff|adv|trunc|fuzz|dos|portability|smoke|bench|harness]
# (single sections need a previous `build`; `harness` also needs `diff`)
# Requires: pionc (~/.pion/bin), node (wasm32 runtime), cargo (Rust kamadak-exif 0.6.2 oracle, locked; uses the
# crate cache when offline), python3 (stdlib only).
# Artifacts go to $AUDIT_OUT (default /private/tmp/pion-exif-audit: the real path of /tmp on macOS, because the
# wasm32 runner resolves symlinks). Nothing is written inside the repository.
#
# Exit status: 1 while any P0 condition reproduces (crash / trap / hang on any input, a silent value deviation from
# kamadak-exif on well-formed input, a native-vs-wasm32 or debug-vs-release divergence, a failing control case,
# a P0 DoS budget breach, a portability gate, a wasm_smoke hash mismatch with README.md, or bench output not
# byte-identical). Open P1/P2 findings are listed as OPEN and do not fail the run unless STRICT=1.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-exif-audit}
if [ ! -d /private/tmp ] && [ "$AUDIT_OUT" = /private/tmp/pion-exif-audit ]; then AUDIT_OUT=/tmp/pion-exif-audit; fi
BIN="$AUDIT_OUT/bin"
C="$AUDIT_OUT/corpus"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
FUZZ_N=${FUZZ_N:-10000}
STRICT=${STRICT:-0}
CMP="python3 -I $AUDIT_DIR/diff/compare.py"
mkdir -p "$BIN"
export PYTHONDONTWRITEBYTECODE=1
RC=0
OPEN=""
fail() { echo "  FAIL (P0): $*"; RC=1; }
open_finding() { echo "  OPEN: $*"; OPEN="$OPEN
  - $*"; }

runner() {
  case "$1" in
    native_dbg) echo "$BIN/exif_audit_dbg" ;;
    native_rel) echo "$BIN/exif_audit_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/exif_audit_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/exif_audit_rel.wasm" ;;
  esac
}
MODES="native_dbg native_rel wasm_dbg wasm_rel"

build() {
  echo "==> build: exif_audit in 4 modes, kamadak-exif 0.6.2 oracle (cargo --locked), corpus"
  pionc fmt --check "$AUDIT_DIR" > /dev/null || fail "pionc fmt --check audit"
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; return; }
  pionc build -o "$BIN/exif_audit_dbg" "$AUDIT_DIR" > /dev/null || fail "build native_dbg"
  pionc build --release -o "$BIN/exif_audit_rel" "$AUDIT_DIR" > /dev/null || fail "build native_rel"
  pionc build --target wasm32 -o "$BIN/exif_audit_dbg.wasm" "$AUDIT_DIR" > /dev/null || fail "build wasm_dbg"
  pionc build --release --target wasm32 -o "$BIN/exif_audit_rel.wasm" "$AUDIT_DIR" > /dev/null || fail "build wasm_rel"
  M="$AUDIT_DIR/diff/oracle/Cargo.toml"
  { CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --offline --manifest-path "$M" 2> /dev/null ||
    CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release --locked --manifest-path "$M"; } || fail "cargo build oracle"
  cp "$AUDIT_OUT/rust-target/release/exif_audit_oracle" "$BIN/oracle"
  rm -rf "$C" && python3 -I "$AUDIT_DIR/diff/gen.py" "$C" "$FUZZ_N" | sed 's/^/  /'
  # kamadak-exif's own test images (JPEG/TIFF/PNG/WebP; HEIF is out of scope for packages/exif)
  KT=$(ls -d "${CARGO_HOME:-$HOME/.cargo}"/registry/src/*/kamadak-exif-0.6.2/tests 2> /dev/null | head -1)
  if [ -n "$KT" ]; then
    mkdir -p "$C/kamadak" && cp "$KT"/*.jpg "$KT"/*.tif "$KT"/*.png "$KT"/*.webp "$C/kamadak/"
    ls "$C"/kamadak/* >> "$C/diff.lst"
  else
    fail "kamadak-exif 0.6.2 test images not found in the cargo registry"
  fi
  echo "  $(pionc --version) | node $(node --version) | $(cargo --version) | kamadak-exif 0.6.2"
}

# dump a corpus group in every mode, require identical records across modes, keep native_rel as reference
dump_group() {
  g=$1
  for m in $MODES; do
    # shellcheck disable=SC2046
    $CMP run "$C/$g.lst" "$AUDIT_OUT/pion_${g}_$m.txt" $(runner $m) | sed "s/^/  [$m]/"
  done
  for m in native_dbg wasm_dbg wasm_rel; do
    $CMP same "$AUDIT_OUT/pion_${g}_native_rel.txt" "$AUDIT_OUT/pion_${g}_$m.txt" || fail "$g: $m differs from native_rel"
  done
  "$BIN/oracle" dumplist "$C/$g.lst" > "$AUDIT_OUT/oracle_$g.txt" || fail "oracle crashed on $g"
}

cases() {
  echo "==> cases: red-team + control cases, one process per case, in all 4 modes"
  names=$("$BIN/exif_audit_rel" list)
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
  sed 's/^/    /' "$AUDIT_OUT/cases_native_rel.txt" | cut -c1-240
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/cases_native_rel.txt" "$AUDIT_OUT/cases_$m.txt" || { diff "$AUDIT_OUT/cases_native_rel.txt" "$AUDIT_OUT/cases_$m.txt" | head -6; fail "case results of $m differ from native_rel"; }
  done
  grep -q 'ABORT' "$AUDIT_OUT"/cases_*.txt && fail "a case aborted (panic / trap)"
  grep -q '^FAIL control_' "$AUDIT_OUT/cases_native_rel.txt" && fail "control case failing"
  for f in $(grep '^FAIL redteam_' "$AUDIT_OUT/cases_native_rel.txt" | awk '{print $2}'); do
    open_finding "$(echo "$f" | sed -E 's/redteam_p([0-9])_([0-9]+)_.*/P\1-\2/'): case $f"
    case "$f" in redteam_p0_*) fail "P0 red-team case $f" ;; esac
  done
}

unit() {
  echo "==> unit: pionc fmt/check/test of packages/exif, pionc test of audit (control_* must pass)"
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || fail "pionc fmt --check packages/exif"
  pionc check --json "$PKG_DIR" > /dev/null || fail "pionc check packages/exif"
  pionc test --json "$PKG_DIR" > "$AUDIT_OUT/unit_pkg.json" 2> /dev/null
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit_audit.json" 2> "$AUDIT_OUT/unit_audit.stderr"
  python3 -I - "$AUDIT_OUT/unit_pkg.json" "$AUDIT_OUT/unit_audit.json" <<'PY' || fail "unit tests"
import json, sys
pkg = json.load(open(sys.argv[1]))
print("  packages/exif own tests: %d/%d pass" % (pkg["passed"], pkg["total"]))
bad = pkg["failed"]
d = json.load(open(sys.argv[2]))
for t in d["tests"]:
    if t["pkg"] != "exif_audit":
        continue
    print("  %s  %s" % ("PASS" if t["ok"] else ("OPEN" if t["name"].startswith("redteam_") else "FAIL"), t["name"]))
    if not t["ok"] and not t["name"].startswith("redteam_"):
        bad += 1
sys.exit(1 if bad else 0)
PY
}

diff_corpus() {
  echo "==> diff: well-formed corpus (all 12 types LE/BE inline+external, camera IFD0/Exif/GPS/Interop/IFD1, JPEG/WebP/PNG"
  echo "    containers, kamadak-exif test images) vs kamadak-exif 0.6.2, field by field + accessors"
  dump_group diff
  $CMP diff "$AUDIT_OUT/pion_diff_native_rel.txt" "$AUDIT_OUT/oracle_diff.txt" || fail "silent value deviation on well-formed input"
}

adv() {
  echo "==> adv: adversarial containers / TIFF structure / GPS / limits vs the expectation of a correct parser"
  dump_group adv
  $CMP adv "$C/manifest.json" "$AUDIT_OUT/pion_adv_native_rel.txt" "$AUDIT_OUT/oracle_adv.txt" > "$AUDIT_OUT/adv.txt"
  r=$?
  grep -v '^  ok' "$AUDIT_OUT/adv.txt" | cut -c1-260
  echo "  $(grep -c '^  ok' "$AUDIT_OUT/adv.txt") cases as expected"
  [ $r = 1 ] && fail "adversarial expectation (P0 or unclassified)"
  for f in $(grep '^  open ' "$AUDIT_OUT/adv.txt" | awk '{print $2}' | tr -d ':'); do open_finding "$f: adversarial corpus"; done
}

trunc() {
  echo "==> trunc: every byte prefix of JPEG/WebP/PNG/TIFF seeds, all 4 modes"
  dump_group trunc
  $CMP fuzz "$AUDIT_OUT/pion_trunc_native_rel.txt" "$AUDIT_OUT/oracle_trunc.txt" trunc || fail "truncation sweep"
}

fuzz() {
  echo "==> fuzz: $FUZZ_N deterministic mutants (LCG seed 0x5EEDE1F0), all 4 modes, classified against kamadak-exif"
  dump_group fuzz
  $CMP fuzz "$AUDIT_OUT/pion_fuzz_native_rel.txt" "$AUDIT_OUT/oracle_fuzz.txt" fuzz || fail "fuzz: crash/timeout or silent value deviation"
}

dos() {
  echo "==> dos: resource bombs, verdict + ms/parse + peak RSS (native_rel)"
  python3 -I "$AUDIT_DIR/diff/dos.py" "$C/dos.json" "$BIN/exif_audit_rel"
  r=$?
  [ $r = 1 ] && fail "DoS P0 budget"
  [ $r = 3 ] && open_finding "P2-3: decoded-memory amplification beyond max_payload_bytes"
  # format_canonical() on 4096 entries, ascending vs descending tag order
  a=$("$BIN/exif_audit_rel" canon "$C/dos/entries_4096.tif")
  d=$("$BIN/exif_audit_rel" canon "$C/dos/entries_4096_desc.tif")
  echo "  format_canonical 4096 entries: ascending [$a]  descending [$d]"
  ua=$(echo "$a" | sed 's/.*us=//')
  ud=$(echo "$d" | sed 's/.*us=//')
  [ "$ud" -gt $((ua * 20 + 1000)) ] && open_finding "P2-4: format_canonical is O(n^2) (${ud} us vs ${ua} us)"
  echo "==> dos (wasm_rel, information): same bombs under node"
  # shellcheck disable=SC2046
  DOS_ADVISORY=0 python3 -I "$AUDIT_DIR/diff/dos.py" "$C/dos.json" $(runner wasm_rel) | sed -n '$p'
}

portability() {
  echo "==> portability: packages/exif/src: 0 extern \"C\", 0 World, 0 external deps, 0 module-level mutable state"
  n=$(cat "$PKG_DIR"/src/*.pion | grep -c 'extern "C"')
  echo "  extern \"C\": $n"; [ "$n" = 0 ] || fail "extern \"C\" in packages/exif/src"
  n=$(cat "$PKG_DIR"/src/*.pion | grep -cw 'World')
  echo "  World: $n"; [ "$n" = 0 ] || fail "World in packages/exif/src"
  n=$(cat "$PKG_DIR"/src/*.pion | grep -c '^import ')
  echo "  imports: $n"; [ "$n" = 0 ] || fail "imports in packages/exif/src"
  deps=$(sed -n '/^\[dependencies\]/,/^\[/p' "$PKG_DIR/pion.toml" | grep -vc '^\[\|^ *$\|^#')
  echo "  pion.toml [dependencies] entries: $deps"; [ "$deps" = 0 ] || fail "external dependencies"
  n=$(cat "$PKG_DIR"/src/*.pion | grep -cE '^(pub )?let mut|^(pub )?let [a-zA-Z_0-9]+ *: *(Array|Bytes|Map|FixedArray|StringBuilder|Ref)')
  echo "  module-level mutable bindings: $n"; [ "$n" = 0 ] || fail "module-level mutable state"
  echo "  module-level lets: $(cat "$PKG_DIR"/src/*.pion | grep -cE '^(pub )?let ') (all immutable Int constants)"
  echo "  Send probe (information): which public results may cross a spawn boundary"
  P="$AUDIT_OUT/send_probe" && rm -rf "$P" && mkdir -p "$P/src"
  printf '[package]\nname = "send_probe"\nversion = "0.1.0"\n\n[dependencies]\nexif = { path = "%s" }\n' "$PKG_DIR" > "$P/pion.toml"
  for v in "exif::ExifLimits::default()" "exif::Orientation::Normal" "exif::parse(Bytes::new(0))"; do
    printf 'import "exif"\n\n///|\npub fn main(world : World) -> Int {\n  let v = %s\n  scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })\n  0\n}\n' "$v" > "$P/src/main.pion"
    r=$(pionc check --json "$P" 2>&1 | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("Send" if d.get("ok") else ",".join(x.get("code","?") for x in d.get("diagnostics",[])))')
    printf '    %-40s %s\n' "$v" "$r"
  done
}

smoke() {
  echo "==> smoke: packages/exif/wasm_smoke in 4 modes vs README.md"
  want=$(grep -o 'SHA-256: `[0-9a-f]*`' "$PKG_DIR/README.md" | head -1 | sed 's/.*`\([0-9a-f]*\)`/\1/')
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
}

bench() {
  echo "==> bench: packages/exif/bench/run_bench.sh as shipped, then the same binaries on camera-sized EXIF"
  EXIF_BENCH_ITERS=${EXIF_BENCH_ITERS:-25000} sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || { tail -20 "$AUDIT_OUT/bench.log"; fail "run_bench.sh"; return; }
  grep -E '^\| `|SHA-256 verified' "$AUDIT_OUT/bench.log" | sed 's/^/  /'
  claimed=$(python3 -I -c 'import re,sys; m=re.search(r"Canonical output SHA-256[^`]*`([0-9a-f]{64})`", open(sys.argv[1]).read()); print(m.group(1) if m else "none")' "$PKG_DIR/README.md")
  python3 -I - /tmp/pion-exif-bench/bench.json "$claimed" <<'PY' || fail "shipped bench: output hash / protocol"
import json, sys
d = json.load(open(sys.argv[1]))
ok = d.get("sha256") == sys.argv[2] and d["rounds"] >= 5 and d["warmup"] >= 1
print("  shipped bench: sha256 %s %s README, warmup %d rounds %d" % (d.get("sha256", "?")[:16], "==" if d.get("sha256") == sys.argv[2] else "!=", d["warmup"], d["rounds"]))
sys.exit(0 if ok else 1)
PY
  B=/tmp/pion-exif-bench/bin
  for mn in 1500 30000; do
    D="$AUDIT_OUT/bench_real_$mn"
    rm -rf "$D" && python3 -I "$AUDIT_DIR/diff/gen_bench_real.py" "$D" "$mn" > /dev/null
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "camera EXIF, MakerNote $mn B" \
      --impl "pion_exif=$B/pion_exif $D 5000" --impl "rust_kamadak_exif=$B/rust_kamadak $D 5000" \
      --baseline rust_kamadak_exif --warmup 1 --rounds 5 --ops 20000 --json-out "$AUDIT_OUT/bench_real_$mn.json" \
      > "$AUDIT_OUT/bench_real_$mn.log" 2>&1 || { tail -5 "$AUDIT_OUT/bench_real_$mn.log"; fail "camera-sized bench ($mn)"; continue; }
    python3 -I - "$AUDIT_OUT/bench_real_$mn.json" "$mn" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
r = {x["name"]: x for x in d["results"]}
p, k = r["pion_exif"], r["rust_kamadak_exif"]
print("  MakerNote %5s B: pion %7.1f ms  kamadak %7.1f ms  ns/op %8.0f vs %8.0f  speedup %.2fx  sha256 %s" % (
    sys.argv[2], p["median_ms"], k["median_ms"], p["median_ms"] * 1e6 / 20000, k["median_ms"] * 1e6 / 20000,
    p["speedup_vs_baseline"], d["sha256"][:16]))
open(sys.argv[1] + ".speedup", "w").write("%.3f" % p["speedup_vs_baseline"])
PY
  done
  s=$(cat "$AUDIT_OUT/bench_real_30000.json.speedup" 2> /dev/null || echo 0)
  python3 -I -c "import sys; sys.exit(0 if float('$s') >= 1.0 else 1)" ||
    open_finding "P1-2: README 1.01x does not hold on camera-sized EXIF (${s}x with a 30 KB MakerNote)"
}

harness() {
  echo "==> harness: the gates must catch an injected panic and an injected silent value bug (copies in \$AUDIT_OUT)"
  for bug in panic value; do
    H="$AUDIT_OUT/inject_$bug" && rm -rf "$H" && mkdir -p "$H" && cp -R "$PKG_DIR" "$H/exif" && rm -rf "$H/exif/audit/.git"
    python3 -I - "$H/exif/src/tiff.pion" "$bug" <<'PY'
import sys
p, bug = sys.argv[1], sys.argv[2]
s = open(p).read()
if bug == "panic":  # out-of-bounds read for UNDEFINED fields of count 3
    old = "    7 => {\n      let mut out = Bytes::new(count)"
    new = "    7 => {\n      if count == 3 {\n        let z : Array[Int] = []\n        let _ = z[count]\n      }\n      let mut out = Bytes::new(count)"
else:  # SSHORT sign bug for -1 only
    old = "arr.push(if u >= 32768 { u - 65536 } else { u })"
    new = "arr.push(if u == 65535 { 65535 } else if u >= 32768 { u - 65536 } else { u })"
assert old in s
open(p, "w").write(s.replace(old, new))
PY
    pionc build --release -o "$H/ea" "$H/exif/audit" > /dev/null || { fail "harness build ($bug)"; continue; }
    $CMP run "$C/diff.lst" "$H/diff.txt" "$H/ea" > /dev/null
    if $CMP diff "$H/diff.txt" "$AUDIT_OUT/oracle_diff.txt" > "$H/diff.log"; then
      fail "harness: injected $bug bug not caught by the diff gate"
    else
      echo "  injected $bug bug: diff gate fails as it must ($(grep -c '^  FAIL' "$H/diff.log") file(s), e.g. $(grep -m1 '^  FAIL' "$H/diff.log" | cut -c8-140))"
    fi
  done
}

clean_check() {
  d=$(git -C "$ROOT_DIR" status --porcelain --ignored -- packages/exif | grep -v '^?? packages/exif/audit/$')
  [ -z "$d" ] || { echo "$d"; fail "worktree not clean after audit"; }
}

case "$SECTION" in
  build) build ;;
  cases) cases ;;
  unit) unit ;;
  diff) diff_corpus ;;
  adv) adv ;;
  trunc) trunc ;;
  fuzz) fuzz ;;
  dos) dos ;;
  portability) portability ;;
  smoke) smoke ;;
  bench) bench ;;
  harness) harness ;;
  all)
    build
    cases
    unit
    diff_corpus
    adv
    trunc
    fuzz
    dos
    portability
    smoke
    bench
    harness
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
