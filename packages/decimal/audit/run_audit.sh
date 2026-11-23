#!/bin/sh
# Red-team audit of packages/decimal (Pion) vs Rust rust_decimal =1.37.2 (see REPORT.md).
#
#   sh packages/decimal/audit/run_audit.sh            # full run (~6 min on an M-series Mac)
#   QUICK=1 sh packages/decimal/audit/run_audit.sh    # 16k sort killer instead of 50k, no 1M corpus
#   BIG=1   sh packages/decimal/audit/run_audit.sh    # also diff a 1,000,000-op random corpus
#
# Needs: pionc ($HOME/.pion/bin), node (wasm32 runtime), cargo (network for the first fetch), python3.
# Every build, corpus, output and report goes to $AUDIT_OUT (default /private/tmp/pion-decimal-audit:
# a real path, the wasm32 runtime resolves file arguments through realpath); the worktree is never
# written to.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEC_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$DEC_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/pion-decimal-audit}
BIN="$OUT/bin"
QUICK=${QUICK:-0}
BIG=${BIG:-0}
RANDOM_N=${RANDOM_N:-60000}
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$BIN" "$OUT/dos"

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

section "0. Build -> $BIN (Pion native release+debug, wasm32 release+debug; Rust --release)"
pionc build --release -o "$BIN/pion_probe" "$AUDIT_DIR/probe"
pionc build -o "$BIN/pion_probe_debug" "$AUDIT_DIR/probe"
pionc build --release --target wasm32 -o "$BIN/pion_probe_release.wasm" "$AUDIT_DIR/probe"
pionc build --target wasm32 -o "$BIN/pion_probe_debug.wasm" "$AUDIT_DIR/probe"
pionc build --release -o "$BIN/pion_advbench" "$AUDIT_DIR/advbench"
rm -rf "$OUT/oracle-build" && cp -R "$AUDIT_DIR/oracle" "$OUT/oracle-build"
CARGO_TARGET_DIR="$OUT/rust-target" cargo build -q --release --manifest-path "$OUT/oracle-build/Cargo.toml"
cp "$OUT/rust-target/release/rust_oracle" "$OUT/rust-target/release/rust_advbench" "$BIN/"

section "1. Red-team unit tests: pionc test packages/decimal/audit (every redteam_* failure is a finding)"
(cd "$DEC_DIR" && pionc test --json audit > "$OUT/redteam_test.json" 2> "$OUT/redteam_test.stderr") || true
python3 - "$OUT/redteam_test.json" <<'PY' || true
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
mine = [t for t in d["tests"] if t["pkg"] == "decimal_audit"]
print("decimal_audit: %d tests, %d FAILED (findings), %d passed (controls)" % (
    len(mine), sum(not t["ok"] for t in mine), sum(t["ok"] for t in mine)))
for t in mine:
    print("  %-6s %s" % ("FAIL" if not t["ok"] else "pass", t["name"]))
PY
echo "assertion messages:"; sed 's|^.*/audit/|  |' "$OUT/redteam_test.stderr"

section "2. 1:1 differential: edge matrix + $RANDOM_N random ops (seed 1372) vs rust_decimal"
python3 "$AUDIT_DIR/gen_corpus.py" "$OUT/corpus.tsv" "$RANDOM_N" 1372
"$BIN/rust_oracle" "$OUT/corpus.tsv" > "$OUT/rust.out"
"$BIN/pion_probe" "$OUT/corpus.tsv" > "$OUT/pion.out"
python3 "$AUDIT_DIR/diff_corpus.py" "$OUT/corpus.tsv" "$OUT/rust.out" "$OUT/pion.out" 3 \
  --json "$OUT/diff.json" > "$OUT/diff.txt" || true
head -2 "$OUT/diff.txt"; grep '^\[' "$OUT/diff.txt" || true
echo "(full counterexamples: $OUT/diff.txt)"
if [ "$BIG" = 1 ]; then
  python3 "$AUDIT_DIR/gen_corpus.py" "$OUT/big.tsv" 1000000 20261123
  "$BIN/rust_oracle" "$OUT/big.tsv" > "$OUT/big.rust"
  "$BIN/pion_probe" "$OUT/big.tsv" > "$OUT/big.pion"
  python3 "$AUDIT_DIR/diff_corpus.py" "$OUT/big.tsv" "$OUT/big.rust" "$OUT/big.pion" 3 > "$OUT/big.diff" || true
  head -2 "$OUT/big.diff"
fi

section "3. Who is right? value mismatches arbitrated against exact arithmetic"
python3 "$AUDIT_DIR/judge_exact.py" "$OUT/corpus.tsv" "$OUT/rust.out" "$OUT/pion.out"

section "4. Wasm32 vs Native: the whole corpus must be byte-identical"
"$BIN/pion_probe_debug" "$OUT/corpus.tsv" > "$OUT/native_debug.out"
node "$WASM_RT" "$BIN/pion_probe_release.wasm" "$OUT/corpus.tsv" > "$OUT/wasm_release.out"
node "$WASM_RT" "$BIN/pion_probe_debug.wasm" "$OUT/corpus.tsv" > "$OUT/wasm_debug.out"
for f in native_debug wasm_release wasm_debug; do
  if cmp -s "$OUT/pion.out" "$OUT/$f.out"; then echo "  $f: identical to native --release"; else echo "  $f: DIFFERS"; fi
done
shasum -a 256 "$OUT/pion.out" "$OUT/native_debug.out" "$OUT/wasm_release.out" "$OUT/wasm_debug.out" | sed 's|  .*/|  |'

section "5. DoS: hostile inputs (time / peak RSS / exit code / first result line)"
for n in $(python3 "$AUDIT_DIR/gen_dos.py" "$OUT/dos"); do
  for impl in rust_oracle pion_probe; do
    rc=0
    /usr/bin/time -l "$BIN/$impl" "$OUT/dos/dos_$n.tsv" > "$OUT/dos/$n.$impl.out" 2> "$OUT/dos/$n.$impl.time" || rc=$?
    t=$(awk '/real/ {print $1}' "$OUT/dos/$n.$impl.time")
    rss=$(awk '/maximum resident/ {printf "%.1f", $1/1048576}' "$OUT/dos/$n.$impl.time")
    printf '  %-24s %-12s rc=%-3s %6ss %6sMiB  %s\n' "$n" "$impl" "$rc" "$t" "$rss" \
      "$(head -1 "$OUT/dos/$n.$impl.out" | cut -c1-58)"
  done
done
KN=50000; [ "$QUICK" = 1 ] && KN=16000
if [ ! -s "$OUT/killer_$KN.txt" ]; then
  echo "  generating McIlroy quicksort-killer permutation n=$KN (pure Python, ~100 s for 50k) ..."
  python3 "$AUDIT_DIR/gen_qsort_killer.py" "$KN" "$OUT/killer_$KN.txt"
fi
python3 "$AUDIT_DIR/gen_bench_inputs.py" "$OUT"

section "6. Adversarial head-to-head (scripts/bench_compare.py, warmup 1, 5 interleaved rounds, SHA-256 checked)"
bc() {
  slug=$1; title=$2; ops=$3; shift 3
  python3 "$ROOT_DIR/scripts/bench_compare.py" --title "$title" \
    --impl "pion=$BIN/pion_advbench $*" --impl "rust_decimal=$BIN/rust_advbench $*" \
    --baseline rust_decimal --warmup 1 --rounds 5 --ops "$ops" \
    --md-out "$OUT/bench_$slug.md" --json-out "$OUT/bench_$slug.json" > /dev/null
  cat "$OUT/bench_$slug.md"; echo
}
bc a1_sort_killer "A1 Decimal::sort vs sort_unstable: McIlroy killer permutation ($KN)" "$KN" sort "$OUT/killer_$KN.txt"
bc a2_sort_random "A2 same values, random order (50k)" 50000 sort "$OUT/random_50k.txt"
bc a3_mul96 "A3 full-width 96x96 checked_mul (2M)" 2000000 mul96 2000000
bc a4_div "A4 checked_div, 32/64/96-bit divisors (2M)" 2000000 div 2000000
bc a5_sci "A5 from_scientific (50k x 10)" 500000 sci "$OUT/sci_50k.txt" 10
bc a6_sqrt "A6 sqrt (100k)" 100000 sqrt 100000

section "7. Worktree must stay clean"
git -C "$ROOT_DIR" status --porcelain --ignored -- packages/decimal | sed 's/^/  /'
echo "done. outputs in $OUT"
