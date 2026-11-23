#!/bin/sh
# One-shot red-team audit for packages/brotli.
#   sh packages/brotli/audit/run_audit.sh [all|build|unit|vectors|fuzz|dos|wasm_dos|perf]
# Requires: pionc, node, cargo (offline crates ok), Homebrew brotli 1.2.x (headers + libbrotlidec/enc/common), python3.
# All artifacts go to $AUDIT_OUT (default /private/tmp/pion-brotli-audit, the *real* path of /tmp on macOS,
# because the wasm32 runner resolves symlinks). Nothing is written inside the repository.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-brotli-audit}
BIN="$AUDIT_OUT/bin"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
FUZZ_N=${FUZZ_N:-24000}
BREW=${BREW_PREFIX:-/opt/homebrew}
mkdir -p "$BIN"
export AUDIT_OUT PYTHONDONTWRITEBYTECODE=1

build() {
  echo "==> build: Pion native + wasm32, C libbrotlidec/enc harness, Rust brotli-decompressor harness"
  pionc fmt --check "$AUDIT_DIR" || exit 1
  pionc check --json "$AUDIT_DIR" > /dev/null || { pionc check --json "$AUDIT_DIR"; exit 1; }
  pionc build --release -o "$BIN/pion_audit" "$AUDIT_DIR" || exit 1
  pionc build --release --target wasm32 -o "$BIN/pion_audit.wasm" "$AUDIT_DIR" || exit 1
  cc -O2 -I"$BREW/include" "$AUDIT_DIR/diff/c/c_audit.c" -L"$BREW/lib" -lbrotlidec -lbrotlienc -lbrotlicommon \
    -Wl,-rpath,"$BREW/lib" -o "$BIN/c_audit" || exit 1
  rm -rf "$AUDIT_OUT/rust-proj" && mkdir -p "$AUDIT_OUT/rust-proj"
  cp -R "$AUDIT_DIR/diff/rust/Cargo.toml" "$AUDIT_DIR/diff/rust/src" "$AUDIT_OUT/rust-proj/"
  CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release \
    --manifest-path "$AUDIT_OUT/rust-proj/Cargo.toml" || exit 1
  cp "$AUDIT_OUT/rust-target/release/brotli-audit-rust" "$BIN/rust_audit"
  "$BIN/c_audit" dict "$AUDIT_OUT/dict.bin" > /dev/null
  "$BIN/c_audit" transforms "$AUDIT_OUT/transforms.bin" > /dev/null
  "$BIN/c_audit" lut "$AUDIT_OUT/lut.bin"
}

unit() {
  echo "==> unit: red-team Pion tests (redteam_* FAIL while a defect exists; control_* must PASS)"
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit.json" 2> "$AUDIT_OUT/unit.stderr"
  python3 - "$AUDIT_OUT/unit.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
bad_controls = 0
for t in d['tests']:
    if t['pkg'] != 'brotli_audit':
        continue
    kind = 'RED ' if t['name'].startswith('redteam_') else 'CTRL'
    print(f"  {kind} {'PASS' if t['ok'] else 'FAIL'}  {t['name']}")
    if kind == 'CTRL' and not t['ok']:
        bad_controls += 1
print(f"  upstream brotli tests: {sum(1 for t in d['tests'] if t['pkg']=='brotli' and t['ok'])}/"
      f"{sum(1 for t in d['tests'] if t['pkg']=='brotli')} pass")
sys.exit(1 if bad_controls else 0)
PY
  grep "pion panic" "$AUDIT_OUT/unit.stderr" | sed 's/^/    /'
}

dos() {
  echo "==> dos: bombs, metadata flood, max-tree meta-block flood, IMTF worst case, 512 MiB input"
  python3 "$AUDIT_DIR/dos_gen.py" "$AUDIT_OUT" || exit 1
  cd "$AUDIT_OUT" || exit 1
  while read -r f lim; do
    for t in pion c rust; do
      r=$( { /usr/bin/time -l "$BIN/${t}_audit" file "$f" "$lim" ; } 2>&1 )
      v=$(echo "$r" | grep -E '^(OK|ERR|TRAIL)' | cut -c1-34)
      [ -z "$v" ] && v="CRASH: $(echo "$r" | grep -iE 'panic|abort|error' | head -1 | cut -c1-60)"
      s=$(echo "$r" | awk '/real/{print $1}')
      m=$(echo "$r" | awk '/maximum resident/{printf "%.1f", $1/1048576}')
      printf "  %-30s limit=%-10s %-5s %-36s %7ss  RSS %8s MiB\n" "$f" "$lim" "$t" "$v" "$s" "$m"
    done
  done < "$AUDIT_OUT/dos_cases.txt"
}

wasm_dos() {
  echo "==> wasm_dos: the same probes under wasm32 (node)"
  cd "$AUDIT_OUT" || exit 1
  while read -r f lim; do
    case "$f" in input_512MiB*) continue ;; esac
    s0=$(python3 -c 'import time;print(time.time())')
    v=$(node "$WASM_RT" "$BIN/pion_audit.wasm" file "$f" "$lim" 2>&1 | grep -E '^(OK|ERR)|Error' | head -1 | cut -c1-60)
    s1=$(python3 -c 'import time;print(time.time())')
    printf "  %-30s limit=%-10s wasm  %-50s %6.2fs\n" "$f" "$lim" "$v" "$(python3 -c "print($s1-$s0)")"
  done < "$AUDIT_OUT/dos_cases.txt"
}

perf() {
  echo "==> perf: path-isolating hot-spot streams, Pion vs C libbrotlidec (bench_compare.py, warmup 1, rounds 5)"
  python3 "$AUDIT_DIR/hotpath_gen.py" "$AUDIT_OUT" > /dev/null || exit 1
  for f in hp_literals hp_literals_cm hp_cmds hp_dict hp_copy_long hp_copy_short hp_copy_rle; do
    sz=$("$BIN/c_audit" bench "$AUDIT_OUT/$f.br" 1 | awk '{print $2}')
    it=$((200000000 / sz)); [ $it -lt 3 ] && it=3; [ $it -gt 400 ] && it=400
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "brotli hot path: $f" \
      --impl "pion=$BIN/pion_audit bench $AUDIT_OUT/$f.br $it" \
      --impl "c_brotlidec=$BIN/c_audit bench $AUDIT_OUT/$f.br $it" \
      --baseline c_brotlidec --warmup 1 --rounds 5 --bytes $((sz * it)) \
      --json-out "$AUDIT_OUT/hp_$f.json" --md-out "$AUDIT_OUT/hp_$f.md" > "$AUDIT_OUT/hp_$f.log" 2>&1 \
      || { echo "  $f FAILED (see $AUDIT_OUT/hp_$f.log)"; continue; }
    printf "  %-16s %s\n" "$f" "$(grep '^| `pion`' "$AUDIT_OUT/hp_$f.md" | awk -F'|' '{print "median " $3 " ms  " $6 " MB/s  vs C " $8}')"
  done
}

rc=0
case "$SECTION" in
  build) build ;;
  unit) unit || rc=1 ;;
  vectors|fuzz) python3 "$AUDIT_DIR/difftest.py" "$SECTION" --fuzz "$FUZZ_N" || rc=1 ;;
  dos) dos ;;
  wasm_dos) wasm_dos ;;
  perf) perf ;;
  all)
    build
    unit || rc=1
    python3 "$AUDIT_DIR/difftest.py" all --fuzz "$FUZZ_N" || rc=1
    dos
    wasm_dos
    perf
    ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
cd "$ROOT_DIR" && git status --porcelain --ignored -- packages/brotli | grep -v '^?? packages/brotli/audit/$' && { echo "worktree NOT clean"; rc=1; }
exit $rc
