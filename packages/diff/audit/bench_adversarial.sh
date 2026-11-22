#!/bin/sh
# Adversarial head-to-head benchmark: Pion `packages/diff` vs Rust `imara-diff v0.2.0 --release`
# through scripts/bench_compare.py (--warmup 1 --rounds 5, interleaved, stdout SHA-256 enforced).
# usage: bench_adversarial.sh ORACLE_BIN RUNNER_BIN CORPUS_DIR OUT_DIR
set -u
ORACLE=$1; RUNNER=$2; C=$3; OUT=$4
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
mkdir -p "$OUT"
FAILED=""

size() { python3 -c "import os,sys; print(sum(os.path.getsize(p) for p in sys.argv[1:]))" "$@"; }

bench() { # name algo iters
  n=$1; algo=$2; it=$3
  b=$(size "$C/$n.before" "$C/$n.after")
  echo ""
  echo "==> $n / $algo x $it"
  if ! python3 "$ROOT/scripts/bench_compare.py" \
      --title "diff red-team: $n ($algo, ctx 3) x $it" \
      --impl "pion=$RUNNER bench $C/$n.before $C/$n.after $algo $it 3" \
      --impl "rust-imara-diff=$ORACLE bench $C/$n.before $C/$n.after $algo $it 3" \
      --baseline rust-imara-diff --warmup 1 --rounds 5 \
      --bytes $((b * it)) --ops "$it" \
      --json-out "$OUT/$n-$algo.json" --md-out "$OUT/$n-$algo.md"; then
    FAILED="$FAILED $n/$algo"
  fi
}

bench rewrite histogram 1
bench rewrite myers 4
bench repetitive histogram 4
bench repetitive myers 4
bench minified histogram 3
bench edge_fallback histogram 3
bench edge_control histogram 3
bench million histogram 3
bench scattered histogram 1
bench scattered myers 3
bench high_d histogram 3
bench high_d myers 3
bench hashctrl histogram 3
bench hashflood histogram 1

echo ""
echo "==> multi (interner reuse: 1 before x 8 afters) x 2"
MB=$(size "$C/multi.before")
MA=$(size "$C"/multi.after*)
python3 "$ROOT/scripts/bench_compare.py" \
  --title "diff red-team: interner reuse (1 before x 8 afters) x 2" \
  --impl "pion=$RUNNER multi $C/multi.before 2 $(ls "$C"/multi.after* | tr '\n' ' ')" \
  --impl "rust-imara-diff=$ORACLE multi $C/multi.before 2 $(ls "$C"/multi.after* | tr '\n' ' ')" \
  --baseline rust-imara-diff --warmup 1 --rounds 5 \
  --bytes $(((MB * 8 + MA) * 2)) --ops 16 \
  --json-out "$OUT/multi.json" --md-out "$OUT/multi.md" || FAILED="$FAILED multi"

echo ""
if [ -n "$FAILED" ]; then
  echo "SHA/benchmark failures:$FAILED"
fi
