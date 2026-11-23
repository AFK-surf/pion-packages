#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.elan/bin:$HOME/.pion/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PIONC_BIN="${PIONC:-$(command -v pionc 2>/dev/null || echo "$HOME/.pion/bin/pionc")}"
LEAN_CACHE="${LEAN_CACHE:-/private/tmp/pion-lean-shared}"
PION_LEAN_REF="${PION_LEAN_REF:-/private/tmp/pion-lean-ref/lean}"
BASE_WORK="${LEAN_WORK:-/private/tmp/pion-lean-work/effect}"

if [ ! -d "$BASE_WORK/.lake/build" ]; then
  echo "Baseline build not found at $BASE_WORK/.lake/build; running run_proofs.sh first..."
  bash "$SCRIPT_DIR/run_proofs.sh"
fi

MUT_ROOT="$(mktemp -d /tmp/effect_mut.XXXXXX)"
trap 'rm -rf "$MUT_ROOT"; kill -- -$$ 2>/dev/null || true' EXIT INT TERM

# Seed isolated Lean build workspace from clean baseline
WORK_DIR="$MUT_ROOT/lean_work"
mkdir -p "$WORK_DIR/.deps" "$WORK_DIR/.lake"
ln -sfn "$LEAN_CACHE/aeneas/backends/lean" "$WORK_DIR/.deps/aeneas"
ln -sfn "$LEAN_CACHE/proj/.lake/packages" "$WORK_DIR/.lake/packages"
cp -f "$BASE_WORK/lean-toolchain" "$WORK_DIR/"
cp -f "$BASE_WORK/lake-manifest.json" "$WORK_DIR/"
cp -f "$BASE_WORK/lakefile.lean" "$WORK_DIR/"
cp -f "$BASE_WORK/PionLean.lean" "$WORK_DIR/"
cp -R "$BASE_WORK/PionLean" "$WORK_DIR/"
cp -f "$BASE_WORK/EffectProofs.lean" "$WORK_DIR/"
cp -R "$BASE_WORK/EffectProofs" "$WORK_DIR/"
cp -R "$BASE_WORK/.lake/build" "$WORK_DIR/.lake/build"

# Isolated copy of packages/effect (never mutates git worktree)
MUT_PKG="$MUT_ROOT/pkg"
cp -R "$PKG_DIR" "$MUT_PKG"

KILLED=0
SURVIVED=0
TOTAL=0

run_mutant() {
  local id="$1"
  local file="$2"
  local old="$3"
  local new="$4"
  local desc="$5"
  TOTAL=$((TOTAL + 1))

  cp "$PKG_DIR/$file" "$MUT_PKG/$file"
  python3 - "$MUT_PKG/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if old not in s:
    sys.exit(f"PATCH_ERROR: pattern not found in {path}: {old!r}")
s2 = s.replace(old, new, 1)
if s2 == s:
    sys.exit(f"PATCH_ERROR: replacement had no effect in {path}")
open(path, "w").write(s2)
PYEOF

  rm -rf "$WORK_DIR/Effect" "$WORK_DIR/Effect.lean"
  "$PIONC_BIN" extract-lean "$MUT_PKG" --out "$WORK_DIR" >/dev/null 2>&1

  if (cd "$WORK_DIR" && lake build Effect.Types Effect.Funs EffectProofs) >"$MUT_ROOT/${id}.log" 2>&1; then
    echo "SURVIVED  $id  ($desc)"
    SURVIVED=$((SURVIVED + 1))
  else
    echo "KILLED    $id  ($desc)"
    KILLED=$((KILLED + 1))
  fi

  cp "$PKG_DIR/$file" "$MUT_PKG/$file"
}

echo "=== Running Stage 2 semantic mutation kill-rate gate (10 mutants) ==="

run_mutant "M01_sift_down_flip_left" "src/runtime.pion" \
  "if timer_before(l_at, l_seq, best_at, best_seq) {" \
  "if timer_before(best_at, best_seq, l_at, l_seq) {" \
  "heap_sift_down_pick: flipped left-child comparison (RT-lean-proofs pop bug)"

run_mutant "M02_sift_down_drop_right" "src/runtime.pion" \
  "if has_right && timer_before(r_at, r_seq, best_at, best_seq) {" \
  "if false && timer_before(r_at, r_seq, best_at, best_seq) {" \
  "heap_sift_down_pick: skipped right child comparison"

run_mutant "M03_sift_down_cmp_cur" "src/runtime.pion" \
  "if has_right && timer_before(r_at, r_seq, best_at, best_seq) {" \
  "if has_right && timer_before(r_at, r_seq, cur_at, cur_seq) {" \
  "heap_sift_down_pick: compared right child to cur instead of best"

run_mutant "M04_sift_up_flip" "src/runtime.pion" \
  "  timer_before(cur_at, cur_seq, par_at, par_seq)" \
  "  timer_before(par_at, par_seq, cur_at, cur_seq)" \
  "heap_sift_up_should_swap: flipped sift-up comparison direction"

run_mutant "M05_heap_right_off1" "src/runtime.pion" \
  "  2 * i + 2" \
  "  2 * i + 3" \
  "heap_right: off-by-one right child index 2*i+2 -> 2*i+3"

run_mutant "M06_rng_shift13_to_12" "src/rng.pion" \
  "let x1 = (s ^ ((s << 13) & 4294967295L)) & 4294967295L" \
  "let x1 = (s ^ ((s << 12) & 4294967295L)) & 4294967295L" \
  "rng_step_u32: corrupted xorshift32 shift 13 -> 12"

run_mutant "M07_rng_shift17_to_16" "src/rng.pion" \
  "let x2 = (x1 ^ ((x1 >> 17) & 4294967295L)) & 4294967295L" \
  "let x2 = (x1 ^ ((x1 >> 16) & 4294967295L)) & 4294967295L" \
  "rng_step_u32: corrupted xorshift32 shift 17 -> 16"

run_mutant "M08_rng_mask_31bit" "src/rng.pion" \
  "(x2 ^ ((x2 << 5) & 4294967295L)) & 4294967295L" \
  "(x2 ^ ((x2 << 5) & 4294967295L)) & 2147483647L" \
  "rng_step_u32: corrupted 32-bit mask to 31-bit (breaks bijection)"

run_mutant "M09_ring_slot_prev_dir" "src/ring_deque.pion" \
  "  (head - 1 + cap) % cap" \
  "  (head + 1 + cap) % cap" \
  "ring_slot_prev: wrong wraparound direction -1 -> +1"

run_mutant "M10_ring_slot_add_shift" "src/ring_deque.pion" \
  "  (head + offset) % cap" \
  "  (head + offset + 1) % cap" \
  "ring_slot_add: off-by-one slot offset (breaks logical-to-physical bijection)"

PCT=$((KILLED * 100 / TOTAL))
echo "=== Mutation kill summary: $KILLED / $TOTAL killed (${PCT}%) ==="
if [ "$PCT" -lt 90 ]; then
  echo "FAIL: mutation kill rate ${PCT}% < 90%" >&2
  exit 1
fi
echo "PASS: packages/effect Stage 2 mutation kill gate ($KILLED/$TOTAL = ${PCT}% >= 90%)"
