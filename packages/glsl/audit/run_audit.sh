#!/bin/sh
# One-shot red-team audit for packages/glsl.
#   sh packages/glsl/audit/run_audit.sh [all|build|unit|judge|dos|wasm_dos|fuzz|perf]
# Requires: pionc (~/.pion/bin), node (wasm32 runner), python3, clang + macOS OpenGL.framework (judge section).
# Every artifact goes to $AUDIT_OUT (default /private/tmp/pion-glsl-audit, the real path of /tmp on macOS because
# the wasm32 runner resolves symlinks).  Nothing is written inside the repository.
set -u
export PATH="$HOME/.pion/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-glsl-audit}
BIN="$AUDIT_OUT/bin"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
FUZZ_N=${FUZZ_N:-12000}
mkdir -p "$BIN"
export AUDIT_OUT PYTHONDONTWRITEBYTECODE=1

now() { python3 -c 'import time;print(time.time())'; }

build() {
  echo "==> build: audit driver (native --release + wasm32 --release), CGL OpenGL 4.1 Core oracle, bench corpora"
  pionc fmt --check "$AUDIT_DIR" || exit 1
  pionc check --json "$AUDIT_DIR" > /dev/null || { pionc check --json "$AUDIT_DIR"; exit 1; }
  pionc build --release -o "$BIN/drv" "$AUDIT_DIR" || exit 1
  pionc build --release --target wasm32 -o "$BIN/drv.wasm" "$AUDIT_DIR" || exit 1
  if [ "$(uname -s)" = "Darwin" ]; then
    clang -O2 -Wall -Wno-deprecated-declarations "$AUDIT_DIR/oracle/gl41_oracle.c" -framework OpenGL \
      -o "$BIN/gl41_oracle" || exit 1
  fi
  python3 -I "$PKG_DIR/bench/gen_corpus.py" "$AUDIT_OUT/bench_corpus" > /dev/null || exit 1
}

unit() {
  echo "==> unit: red-team Pion tests (redteam_* FAIL while a defect exists; control_* must PASS)"
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit.json" 2> "$AUDIT_OUT/unit.stderr"
  python3 -I - "$AUDIT_OUT/unit.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
bad = 0
for t in d['tests']:
    if t['pkg'] != 'glsl_audit':
        continue
    kind = 'RED ' if t['name'].startswith('redteam_') else 'CTRL'
    print(f"  {kind} {'PASS' if t['ok'] else 'FAIL'}  {t['name']}")
    bad += kind == 'CTRL' and not t['ok']
up = [t for t in d['tests'] if t['pkg'] == 'glsl']
print(f"  package glsl_test.pion: {sum(t['ok'] for t in up)}/{len(up)} pass")
sys.exit(1 if bad else 0)
PY
}

judge() {
  echo "==> judge: corpus -> Pion translate -> macOS OpenGL 4.1 Core glCompileShader + glLinkProgram"
  python3 -I "$AUDIT_DIR/gl_judge.py"
}

dos() {
  echo "==> dos: limits, bombs, integer overflow, hostile bytes (native; tr = default ParseLimits, time = unlimited)"
  python3 -I "$AUDIT_DIR/dos_gen.py" "$AUDIT_OUT" || exit 1
  while read -r f st m; do
    s0=$(now)
    if [ "$m" = tr ]; then
      r=$( { /usr/bin/time -l "$BIN/drv" tr "$st" "$f" "$AUDIT_OUT/dos.out"; } 2>&1 )
    else
      r=$( { /usr/bin/time -l "$BIN/drv" time "$st" "$f" 1; } 2>&1 )
    fi
    s1=$(now)
    v=$(echo "$r" | grep -E '^(OK|ERR|ms=)' | cut -c1-80)
    [ -z "$v" ] && v="CRASH: $(echo "$r" | head -2 | tr '\n' ' ' | cut -c1-80)"
    m2=$(echo "$r" | awk '/maximum resident/{printf "%.0f", $1/1048576}')
    printf "  %-38s %-4s %-4s %6.2fs %5s MiB  %s\n" "$(basename "$f")" "$st" "$m" "$(python3 -c "print($s1-$s0)")" "$m2" "$v"
  done < "$AUDIT_OUT/dos_cases.txt"
  rm -f "$AUDIT_OUT/dos.out"
}

wasm_dos() {
  echo "==> wasm_dos: the same probes under wasm32 --release (node)"
  while read -r f st m; do
    s0=$(now)
    if [ "$m" = tr ]; then
      v=$(node "$WASM_RT" "$BIN/drv.wasm" tr "$st" "$f" "$AUDIT_OUT/dos.out" 2>&1 | head -1 | cut -c1-80)
    else
      v=$(node "$WASM_RT" "$BIN/drv.wasm" time "$st" "$f" 1 2>&1 | head -1 | cut -c1-80)
    fi
    s1=$(now)
    printf "  %-38s %-4s %-4s %6.2fs  %s\n" "$(basename "$f")" "$st" "$m" "$(python3 -c "print($s1-$s0)")" "$v"
  done < "$AUDIT_OUT/dos_cases.txt"
  rm -f "$AUDIT_OUT/dos.out"
}

perf() {
  echo "==> perf: wall-clock per stage (translate vs reflect-only), linear-scaling check, native vs wasm32"
  C="$AUDIT_OUT/bench_corpus"
  for f in threejs_pbr_es100.frag shadertoy_es300.frag postprocess_2d_es100.frag; do
    t=$("$BIN/drv" time frag "$C/$f" 2000 | sed 's/ ok=.*//')
    r=$("$BIN/drv" rtime frag "$C/$f" 2000 | sed 's/ ok=.*//')
    w=$(node "$WASM_RT" "$BIN/drv.wasm" time frag "$C/$f" 2000 | sed 's/ ok=.*//')
    printf "  %-28s x2000  native translate %-9s reflect-only %-9s wasm32 translate %s\n" "$f" "$t" "$r" "$w"
  done
  python3 -I - "$C/threejs_pbr_es100.frag" "$AUDIT_OUT/scale" <<'PY'
import os, sys
src = open(sys.argv[1]).read()
body = src[src.index("void main()"):]
pre = src[:src.index("void main()")]
os.makedirs(sys.argv[2], exist_ok=True)
for k in (1, 8, 64, 512):
    fns = "".join(body.replace("void main()", f"void main{i}()") for i in range(k))
    open(os.path.join(sys.argv[2], f"x{k}.frag"), "w").write(pre + fns + body)
PY
  for k in 1 8 64 512; do
    sz=$(wc -c < "$AUDIT_OUT/scale/x$k.frag" | tr -d ' ')
    it=$((4000 / k)); [ $it -lt 4 ] && it=4
    t=$("$BIN/drv" time frag "$AUDIT_OUT/scale/x$k.frag" $it | sed 's/ms=//; s/ ok=.*//')
    printf "  scale x%-4s %9s B  %4s iters  %6s ms  %s MB/s\n" "$k" "$sz" "$it" "$t" \
      "$(python3 -c "print(round($sz*$it/max($t,1)/1000,1))")"
  done
}

rc=0
case "$SECTION" in
  build) build ;;
  unit) unit || rc=1 ;;
  judge) judge || rc=1 ;;
  dos) dos ;;
  wasm_dos) wasm_dos ;;
  fuzz) python3 -I "$AUDIT_DIR/fuzz.py" "$FUZZ_N" || rc=1 ;;
  perf) perf ;;
  all)
    build
    unit || rc=1
    judge || rc=1
    dos
    wasm_dos
    python3 -I "$AUDIT_DIR/fuzz.py" "$FUZZ_N" || rc=1
    perf
    ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
echo "==> run_audit.sh $SECTION exit=$rc (non-zero = open red-team findings, see REPORT.md)"
exit $rc
