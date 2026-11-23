#!/bin/sh
# One-shot red-team audit for packages/flate.
#   sh packages/flate/audit/run_audit.sh [all|build|unit|vectors|fuzz|compress|dos|bench]
# All artifacts go to $AUDIT_OUT (default /private/tmp/pion-flate-audit, the *real* path of /tmp on macOS,
# because the wasm32 runner resolves symlinks). Nothing is written inside the repository.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-flate-audit}
BIN="$AUDIT_OUT/bin"
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
SECTION=${1:-all}
FUZZ_N=${FUZZ_N:-24000}
mkdir -p "$BIN"
export AUDIT_OUT

build() {
  echo "==> build: Pion native + wasm32, Go, Rust (artifacts in $AUDIT_OUT)"
  pionc fmt --check "$AUDIT_DIR" || exit 1
  pionc check --json "$AUDIT_DIR" || exit 1
  pionc build --release -o "$BIN/pion_audit" "$AUDIT_DIR" || exit 1
  pionc build --release --target wasm32 -o "$BIN/pion_audit.wasm" "$AUDIT_DIR" || exit 1
  (cd "$AUDIT_DIR/diff/go" && GOCACHE="$AUDIT_OUT/gocache" go build -o "$BIN/go_audit" .) || exit 1
  rm -rf "$AUDIT_OUT/rust-proj" && mkdir -p "$AUDIT_OUT/rust-proj"
  cp -R "$AUDIT_DIR/diff/rust/Cargo.toml" "$AUDIT_DIR/diff/rust/src" "$AUDIT_OUT/rust-proj/"
  CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release \
    --manifest-path "$AUDIT_OUT/rust-proj/Cargo.toml" || exit 1
  cp "$AUDIT_OUT/rust-target/release/flate-audit-rust" "$BIN/rust_audit"
}

unit() {
  echo "==> unit: red-team Pion tests (redteam_* FAIL while a defect exists; control_* must PASS)"
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit.json" 2> "$AUDIT_OUT/unit.stderr"
  python3 - "$AUDIT_OUT/unit.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
bad_controls = 0
for t in d['tests']:
    if t['pkg'] != 'flate_audit':
        continue
    kind = 'RED ' if t['name'].startswith('redteam_') else 'CTRL'
    print(f"  {kind} {'PASS' if t['ok'] else 'FAIL'}  {t['name']}")
    if kind == 'CTRL' and not t['ok']:
        bad_controls += 1
print(f"  upstream flate tests: {sum(1 for t in d['tests'] if t['pkg']=='flate' and t['ok'])}/"
      f"{sum(1 for t in d['tests'] if t['pkg']=='flate')} pass")
sys.exit(1 if bad_controls else 0)
PY
  grep "pion panic" "$AUDIT_OUT/unit.stderr" | sed 's/^/    /'
}

dos() {
  echo "==> dos: zip bombs, empty-member flood, dynamic-block flood, adversarial LZ77 inputs"
  python3 - "$AUDIT_OUT" <<'PY'
import sys, zlib, struct
o = sys.argv[1] + '/'
z = b'\0' * (1 << 20)
c = zlib.compressobj(9, zlib.DEFLATED, -15); b = b''.join(c.compress(z) for _ in range(1024)) + c.flush()
open(o + 'bomb_1GiB.deflate', 'wb').write(b)
c = zlib.compressobj(9, zlib.DEFLATED, 31); g = b''.join(c.compress(z) for _ in range(1024)) + c.flush()
open(o + 'bomb_1GiB.gz', 'wb').write(g)
m = b'\x1f\x8b\x08\x00\0\0\0\0\0\xff\x03\x00' + b'\0' * 8
open(o + 'empty_members_100k.gz', 'wb').write(m * 100000)
import random
r = random.Random(5)
open(o + 'adv_ab_4M', 'wb').write(bytes(r.choice(b'ab') for _ in range(4 << 20)))
open(o + 'adv_acgt_4M', 'wb').write(bytes(r.choice(b'ACGT') for _ in range(4 << 20)))
open(o + 'adv_prefix3_4M', 'wb').write(b''.join(b'xyz' + bytes([r.randrange(256)]) for _ in range(1 << 20)))
open(o + 'adv_zeros_4M', 'wb').write(b'\0' * (4 << 20))
PY
  cd "$AUDIT_OUT" || exit 1
  for spec in "inflate bomb_1GiB.deflate" "gzip bomb_1GiB.gz" "gzip empty_members_100k.gz"; do
    for lim in 268435456 1048576; do
      for t in pion go rust; do
        set -- $spec
        r=$( { /usr/bin/time -l "$BIN/${t}_audit" file "$1" "$2" "$lim" ; } 2>&1 )
        v=$(echo "$r" | grep -E '^(OK|ERR)' | cut -c1-40)
        s=$(echo "$r" | awk '/real/{print $1}')
        m=$(echo "$r" | awk '/maximum resident/{printf "%.1f", $1/1048576}')
        printf "  %-28s limit=%-10s %-5s %-30s %6ss  RSS %8s MiB\n" "$2" "$lim" "$t" "$v" "$s" "$m"
      done
    done
  done
  for f in adv_zeros_4M adv_ab_4M adv_acgt_4M adv_prefix3_4M; do
    for l in 1 6 9; do
      printf "  compress %-16s L%s" "$f" "$l"
      for t in pion go rust; do
        s=$( { /usr/bin/time -p "$BIN/${t}_audit" cfile "$l" "$f" "$AUDIT_OUT/adv.out" >/dev/null; } 2>&1 | awk '/real/{print $2}')
        printf "  %s=%6ss" "$t" "$s"
      done
      echo
    done
  done
}

bench() {
  echo "==> bench: Pion vs Rust flate2/miniz_oxide vs Go across corpus shapes (bench_compare.py)"
  python3 "$AUDIT_DIR/gen_corpora.py" "$AUDIT_OUT" || exit 1
  for c in entropy html json source text big16; do
    sz=$(wc -c < "$AUDIT_OUT/corpus_$c.bin" | tr -d ' ')
    it=8; [ "$c" = big16 ] && it=2
    for op in d 1 6 9 crc; do
      in="$AUDIT_OUT/corpus_$c.bin"; [ "$op" = d ] && in="$AUDIT_OUT/corpus_$c.gz"
      i=$it; [ "$op" = 9 ] && i=$(( (it + 1) / 2 ))
      python3 "$ROOT_DIR/scripts/bench_compare.py" --title "flate audit: $c op=$op" \
        --impl "pion=$BIN/pion_audit bench $op $in $i" \
        --impl "rust_miniz_oxide=$BIN/rust_audit bench $op $in $i" \
        --impl "go=$BIN/go_audit bench $op $in $i" \
        --baseline rust_miniz_oxide --warmup 1 --rounds 5 --bytes $((sz * i)) \
        --json-out "$AUDIT_OUT/bench_${c}_$op.json" --md-out "$AUDIT_OUT/bench_${c}_$op.md" > "$AUDIT_OUT/bench_${c}_$op.log" 2>&1 \
        || { echo "  bench $c $op FAILED (see $AUDIT_OUT/bench_${c}_$op.log)"; tail -5 "$AUDIT_OUT/bench_${c}_$op.log"; }
    done
    for t in pion rust go; do "$BIN/${t}_audit" bench 6 "$AUDIT_OUT/corpus_$c.bin" 1 >/dev/null; done
  done
  python3 "$AUDIT_DIR/summarize_bench.py" "$AUDIT_OUT"
}

rc=0
case "$SECTION" in
  build) build ;;
  unit) unit || rc=1 ;;
  vectors|fuzz|compress) python3 "$AUDIT_DIR/difftest.py" "$SECTION" --fuzz "$FUZZ_N" || rc=1 ;;
  dos) dos ;;
  bench) bench ;;
  all)
    build
    unit || rc=1
    python3 "$AUDIT_DIR/difftest.py" vectors || rc=1
    python3 "$AUDIT_DIR/difftest.py" compress || rc=1
    python3 "$AUDIT_DIR/difftest.py" fuzz --fuzz "$FUZZ_N" || rc=1
    dos
    bench
    ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
cd "$ROOT_DIR" && git status --porcelain --ignored -- packages/flate | grep -v '^?? packages/flate/audit/$' && { echo "worktree NOT clean"; rc=1; }
exit $rc
