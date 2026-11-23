#!/bin/sh
# One-shot red-team audit for packages/wgsl (see AUDIT_REPORT.md).
#   sh packages/wgsl/audit/run_audit.sh [all|build|portability|selftest|unit|judge|gpu|dos|fuzz|bench]
# Requires: pionc (~/.pion/bin), node (wasm32 runner), python3, cargo (Rust naga =24.0.0 oracle),
#   macOS with Xcode (`xcrun metal`, `swiftc`, a Metal GPU). glslangValidator is taken from PATH, otherwise
#   glslang 16.6.0 (macOS universal, SHA-256 pinned) is downloaded once into $AUDIT_OUT/tools.
# Every artifact goes to $AUDIT_OUT (default /private/tmp/pion-wgsl-audit: the real path of /tmp on macOS,
# because the wasm32 runner resolves symlinks). Nothing is written inside the repository.
# Exit status: 0 only when every red-team case, control, judge, GPU, DoS and fuzz gate passes.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-wgsl-audit}
if [ ! -d /private/tmp ] && [ "$AUDIT_OUT" = /private/tmp/pion-wgsl-audit ]; then AUDIT_OUT=/tmp/pion-wgsl-audit; fi
BIN="$AUDIT_OUT/bin"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
NAGA="$AUDIT_OUT/naga-target/release/wgsl_audit_naga"
SECTION=${1:-all}
FUZZ_N=${FUZZ_N:-5000}
FUZZ_SEED=${FUZZ_SEED:-20261124}
GLSLANG_URL=https://github.com/KhronosGroup/glslang/releases/download/16.6.0/glslang-16.6.0-macos-universal-release.tar.gz
GLSLANG_SHA=4f8c05f2888a73ed0b7b274bc524af9130e09ae94b43c0f3f9ed83cfae852834
mkdir -p "$BIN"
export PYTHONDONTWRITEBYTECODE=1
RC=0
SUMMARY=""
fail() { echo "  FAIL: $*"; RC=1; }
gate() { # gate <section> <status>
  if [ "$2" -eq 0 ]; then SUMMARY="$SUMMARY\n  PASS  $1"; else SUMMARY="$SUMMARY\n  FAIL  $1"; RC=1; fi
}

runner() {
  case "$1" in
    native_dbg) echo "$BIN/wgsl_audit_dbg" ;;
    native_rel) echo "$BIN/wgsl_audit_rel" ;;
    wasm_dbg) echo "node $WASM_RT $BIN/wgsl_audit_dbg.wasm" ;;
    wasm_rel) echo "node $WASM_RT $BIN/wgsl_audit_rel.wasm" ;;
  esac
}
MODES="native_dbg native_rel wasm_dbg wasm_rel"

glslang_bin() {
  if command -v glslangValidator > /dev/null 2>&1; then command -v glslangValidator; return; fi
  g="$AUDIT_OUT/tools/glslang/bin/glslangValidator"
  if [ ! -x "$g" ]; then
    mkdir -p "$AUDIT_OUT/tools/glslang"
    curl -sSL -o "$AUDIT_OUT/tools/glslang.tgz" "$GLSLANG_URL" || return 1
    echo "$GLSLANG_SHA  $AUDIT_OUT/tools/glslang.tgz" | shasum -a 256 -c - > /dev/null || return 1
    tar -xzf "$AUDIT_OUT/tools/glslang.tgz" -C "$AUDIT_OUT/tools/glslang" || return 1
  fi
  echo "$g"
}

build() {
  echo "==> build: wgsl_audit in 4 modes, Rust naga =24.0.0 oracle, Metal GPU runner, glslang"
  s=0
  pionc fmt --check "$AUDIT_DIR" > /dev/null || { fail "pionc fmt --check audit"; s=1; }
  pionc check --json "$AUDIT_DIR" > "$AUDIT_OUT/check.json" || { cat "$AUDIT_OUT/check.json"; fail "pionc check audit"; s=1; }
  pionc build -o "$BIN/wgsl_audit_dbg" "$AUDIT_DIR" || { fail "build native_dbg"; s=1; }
  pionc build --release -o "$BIN/wgsl_audit_rel" "$AUDIT_DIR" || { fail "build native_rel"; s=1; }
  pionc build --target wasm32 -o "$BIN/wgsl_audit_dbg.wasm" "$AUDIT_DIR" || { fail "build wasm_dbg"; s=1; }
  pionc build --release --target wasm32 -o "$BIN/wgsl_audit_rel.wasm" "$AUDIT_DIR" || { fail "build wasm_rel"; s=1; }
  CARGO_TARGET_DIR="$AUDIT_OUT/naga-target" cargo build -q --release --locked \
    --manifest-path "$AUDIT_DIR/diff/naga/Cargo.toml" || { fail "cargo build naga oracle"; s=1; }
  xcrun swiftc -O "$AUDIT_DIR/gpu/gpurun.swift" -o "$BIN/gpurun" || { fail "swiftc gpurun"; s=1; }
  GLSLANG=$(glslang_bin) || { fail "glslangValidator unavailable"; s=1; }
  python3 -I "$PKG_DIR/bench/gen_corpus.py" "$AUDIT_OUT/bench_corpus" > /dev/null || { fail "bench corpus"; s=1; }
  echo "  $(pionc --version) | node $(node --version) | $(cargo --version) | $(xcrun -sdk macosx metal --version 2>&1 | head -1) | $("$GLSLANG" --version 2>&1 | head -1)"
  gate build $s
}

portability() {
  echo "==> portability: packages/wgsl/src must have 0 extern \"C\", 0 World, 0 module-level mutable state"
  s=0
  code() { cat "$PKG_DIR"/src/*.pion | grep -vE '^[[:space:]]*//'; } # doc comments mention the words
  n=$(code | grep -c 'extern "C"')
  echo "  extern \"C\": $n"; [ "$n" = 0 ] || s=1
  n=$(code | grep -cw 'World')
  echo "  World: $n"; [ "$n" = 0 ] || s=1
  n=$(code | grep -cE '^(pub )?(let mut|var) |^(pub )?let [a-zA-Z_0-9]+ *: *(Array|Bytes|Map|FixedArray|StringBuilder|Mutex|AtomicInt)')
  echo "  module-level mutable bindings: $n"; [ "$n" = 0 ] || s=1
  echo "  module-level immutable lets (token kind constants): $(cat "$PKG_DIR"/src/*.pion | grep -cE '^let tk_[a-z0-9_]+ : Int = [0-9]+')"
  gate portability $s
}

selftest() {
  echo "==> selftest: every red-team/control case in native_dbg, native_rel, wasm_dbg, wasm_rel"
  s=0
  for m in $MODES; do
    # shellcheck disable=SC2046
    $(runner $m) selftest > "$AUDIT_OUT/selftest_$m.txt" 2>&1
    echo "  $m: $(tail -1 "$AUDIT_OUT/selftest_$m.txt")"
  done
  grep -E '^(PASS|FAIL) ' "$AUDIT_OUT/selftest_native_rel.txt" | sed -E 's/^(PASS|FAIL) ([a-z0-9_]+)( :: )?(.*)$/  \1 \2  \4/' | cut -c1-220
  for m in native_dbg wasm_dbg wasm_rel; do
    cmp -s "$AUDIT_OUT/selftest_native_rel.txt" "$AUDIT_OUT/selftest_$m.txt" || { fail "selftest stdout of $m differs from native_rel"; s=1; }
  done
  grep -q '^FAIL' "$AUDIT_OUT/selftest_native_rel.txt" && s=1
  grep -q '^selftest:' "$AUDIT_OUT/selftest_native_rel.txt" || { fail "selftest did not complete"; s=1; }
  echo "  -- packages/wgsl/wasm_smoke (the package's own 4-mode smoke)"
  rm -f "$AUDIT_OUT/smoke.sha"
  for flags in "" "--release" "--target wasm32" "--release --target wasm32"; do
    # shellcheck disable=SC2086
    out=$(pionc run $flags "$PKG_DIR/wasm_smoke" 2>/dev/null | shasum -a 256 | cut -c1-16)
    echo "  [${flags:-native dbg}] stdout sha256 $out"
    echo "$out" >> "$AUDIT_OUT/smoke.sha"
  done
  [ "$(sort -u "$AUDIT_OUT/smoke.sha" | wc -l | tr -d ' ')" = 1 ] || { fail "wasm_smoke stdout differs between modes"; s=1; }
  gate "selftest (56 cases x 4 modes)" $s
}

unit() {
  echo "==> unit: pionc test (audit redteam_*/control_* + packages/wgsl's own suite)"
  s=0
  pionc fmt --check "$PKG_DIR" > /dev/null 2>&1 || { fail "pionc fmt --check packages/wgsl"; s=1; }
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit.json" 2> "$AUDIT_OUT/unit.stderr"
  python3 -I - "$AUDIT_OUT/unit.json" <<'PY' || s=1
import json, sys
d = json.load(open(sys.argv[1]))
bad = 0
own = [t for t in d["tests"] if t["pkg"] == "wgsl"]
print("  packages/wgsl own tests: %d/%d pass" % (sum(t["ok"] for t in own), len(own)))
bad += sum(not t["ok"] for t in own)
aud = [t for t in d["tests"] if t["pkg"] == "wgsl_audit"]
red = [t for t in aud if t["name"].startswith("redteam_")]
ctl = [t for t in aud if t["name"].startswith("control_")]
print("  audit control_*: %d/%d pass   audit redteam_*: %d/%d pass" % (
    sum(t["ok"] for t in ctl), len(ctl), sum(t["ok"] for t in red), len(red)))
bad += sum(not t["ok"] for t in aud)
sys.exit(1 if bad else 0)
PY
  gate "unit (pionc test)" $s
}

judge() {
  echo "==> judge: corpus vs naga =24.0.0; valid => Ok + xcrun metal + glslangValidator, invalid => Err"
  GLSLANG=$(glslang_bin)
  python3 -I "$AUDIT_DIR/diff/judge.py" "$BIN/wgsl_audit_rel" "$NAGA" "$GLSLANG" "$AUDIT_OUT/judge" \
    "$AUDIT_DIR/corpus/valid" "$AUDIT_OUT/bench_corpus" -- "$AUDIT_DIR/corpus/invalid"
  gate "judge (Metal / glslang / naga corpus)" $?
}

gpu() {
  echo "==> gpu: compute shaders run on the local Metal GPU, packages/wgsl vs naga vs WGSL-spec result"
  python3 -I "$AUDIT_DIR/gpu/gpu_judge.py" "$AUDIT_DIR/corpus/valid" "$BIN/wgsl_audit_rel" "$NAGA" "$BIN/gpurun" "$AUDIT_OUT/gpu"
  gate "gpu (Metal runtime semantics)" $?
}

dos() {
  echo "==> dos: hostile inputs, one process per input and mode, 2 s budget each"
  rm -rf "$AUDIT_OUT/dos" && mkdir -p "$AUDIT_OUT/dos" && "$BIN/wgsl_audit_rel" gen_dos "$AUDIT_OUT/dos" > /dev/null
  python3 -I "$AUDIT_DIR/diff/dos.py" "$AUDIT_OUT/dos" 2 \
    "native_dbg=$(runner native_dbg)" "native_rel=$(runner native_rel)" \
    "wasm_dbg=$(runner wasm_dbg)" "wasm_rel=$(runner wasm_rel)"
  gate "dos (stack / time budget, 4 modes)" $?
}

fuzz() {
  echo "==> fuzz: $FUZZ_N deterministic mutants (seed $FUZZ_SEED), 4 modes, naga agreement"
  rm -rf "$AUDIT_OUT/fuzz"
  python3 -I "$AUDIT_DIR/diff/fuzz.py" "$AUDIT_OUT/fuzz" "$FUZZ_N" "$FUZZ_SEED" "$NAGA" \
    "native_rel=$(runner native_rel)" "native_dbg=$(runner native_dbg)" \
    "wasm_rel=$(runner wasm_rel)" "wasm_dbg=$(runner wasm_dbg)" \
    -- "$AUDIT_DIR/corpus/valid" "$AUDIT_DIR/corpus/invalid" "$AUDIT_OUT/bench_corpus"
  gate "fuzz (crash / hang / 4-mode determinism)" $?
}

bench() {
  echo "==> bench: packages/wgsl/bench/run_bench.sh as shipped + stage split (information; fairness in AUDIT_REPORT.md)"
  sh "$PKG_DIR/bench/run_bench.sh" > "$AUDIT_OUT/bench.log" 2>&1 || echo "  run_bench.sh exited non-zero (see $AUDIT_OUT/bench.log)"
  grep -E '^\| `(pion|rust)|sha|SHA|mismatch' "$AUDIT_OUT/bench.log" | head -6 | sed 's/^/  /'
  "$BIN/wgsl_audit_rel" stages "$AUDIT_OUT/bench_corpus" 200 | sed 's/^/  /'
  "$NAGA" stages "$AUDIT_OUT/bench_corpus" 200 | sed 's/^/  /'
  echo "  the bench counts a GLSL compile as ok when its text starts with '#version'; see judge rows pbr /"
  echo "  compute_reduce / particles for glslangValidator's verdict on those same outputs"
}

case "$SECTION" in
  all)
    T0=$(date +%s)
    build; portability; selftest; unit; judge; gpu; dos; fuzz; bench
    printf "==> summary%b\n" "$SUMMARY"
    echo "  wall time: $(( $(date +%s) - T0 ))s"
    git -C "$ROOT_DIR" status --porcelain --ignored -- "$PKG_DIR" | grep -v '^?? packages/wgsl/audit/$' | sed 's/^/  dirty: /'
    ;;
  build | portability | selftest | unit | judge | gpu | dos | fuzz | bench) "$SECTION" ;;
  *) echo "usage: run_audit.sh [all|build|portability|selftest|unit|judge|gpu|dos|fuzz|bench]"; exit 2 ;;
esac
if [ "$RC" -eq 0 ]; then echo "AUDIT RESULT: PASS"; else echo "AUDIT RESULT: FAIL (red-team findings reproduce; see AUDIT_REPORT.md)"; fi
exit "$RC"
