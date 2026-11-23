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
BASE_WORK="${LEAN_WORK:-/private/tmp/pion-lean-work/regex}"

if [ ! -d "$BASE_WORK/.lake/build" ]; then
  echo "Baseline build not found at $BASE_WORK/.lake/build; running run_proofs.sh first..."
  bash "$SCRIPT_DIR/run_proofs.sh"
fi

MUT_ROOT="$(mktemp -d /tmp/regex_mut.XXXXXX)"
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
cp -f "$BASE_WORK/RegexProofs.lean" "$WORK_DIR/"
cp -R "$BASE_WORK/RegexProofs" "$WORK_DIR/"
cp -R "$BASE_WORK/.lake/build" "$WORK_DIR/.lake/build"

# Isolated copy of packages/regex (never mutates git worktree)
MUT_PKG="$MUT_ROOT/pkg"
mkdir -p "$MUT_PKG"
cp "$PKG_DIR/pion.toml" "$MUT_PKG/"
cp -R "$PKG_DIR/src" "$MUT_PKG/src"

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

  rm -rf "$WORK_DIR/Regex" "$WORK_DIR/Regex.lean"
  "$PIONC_BIN" extract-lean "$MUT_PKG" --out "$WORK_DIR" >/dev/null 2>&1

  if (cd "$WORK_DIR" && lake build Regex.Types Regex.Funs RegexProofs) >"$MUT_ROOT/${id}.log" 2>&1; then
    echo "SURVIVED  $id  ($desc)"
    SURVIVED=$((SURVIVED + 1))
  else
    echo "KILLED    $id  ($desc)"
    KILLED=$((KILLED + 1))
  fi

  cp "$PKG_DIR/$file" "$MUT_PKG/$file"
}

echo "=== Running Stage 2 semantic mutation kill-rate gate (10 mutants) ==="

run_mutant "M01_pike_wb_flip" "src/pikevm.pion" \
  "    at_char_boundary && prev_is_word != next_is_word" \
  "    at_char_boundary && prev_is_word == next_is_word" \
  "pike_look_holds: flipped \\b word boundary (RT-lean-proofs PikeVM/DFA divergence)"

run_mutant "M02_dfa_wb_flip" "src/dfa.pion" \
  "    prev_is_word != next_is_word" \
  "    prev_is_word == next_is_word" \
  "dfa_look_holds: flipped \\b word boundary (DFA-side divergence)"

run_mutant "M03_dfa_endline_drop_nl" "src/dfa.pion" \
  "    LookKind::EndLine => at_eoi || next_is_nl" \
  "    LookKind::EndLine => at_eoi" \
  "dfa_look_holds: dropped next_is_nl in (?m)$ (P1-2 divergence)"

run_mutant "M04_pike_startline_drop_nl" "src/pikevm.pion" \
  "    LookKind::StartLine => pos == 0 || prev_byte == 10" \
  "    LookKind::StartLine => pos == 0" \
  "pike_look_holds: dropped prev_byte == 10 in (?m)^"

run_mutant "M05_pike_wb_drop_cb" "src/pikevm.pion" \
  "    at_char_boundary && prev_is_word != next_is_word" \
  "    prev_is_word != next_is_word" \
  "pike_look_holds: dropped UTF-8 char-boundary guard (P0-2 bug)"

run_mutant "M06_reverse_look_startline" "src/nfa.pion" \
  "    LookKind::StartLine => LookKind::EndLine" \
  "    LookKind::StartLine => LookKind::StartLine" \
  "reverse_look_kind: failed to flip StartLine -> EndLine"

run_mutant "M07_reverse_look_starttext" "src/nfa.pion" \
  "    LookKind::StartText => LookKind::EndText" \
  "    LookKind::StartText => LookKind::StartText" \
  "reverse_look_kind: failed to flip StartText -> EndText"

run_mutant "M08_range_can_merge_gap" "src/unicode.pion" \
  "  cur.hi >= 2147483647 || r.lo <= cur.hi + 1" \
  "  cur.hi >= 2147483647 || r.lo <= cur.hi + 2" \
  "char_range_can_merge: merges separated ranges with gap of 1"

run_mutant "M09_range_merge_min_hi" "src/unicode.pion" \
  "  let hi = if r.hi > cur.hi { r.hi } else { cur.hi }" \
  "  let hi = if r.hi < cur.hi { r.hi } else { cur.hi }" \
  "char_range_merge: took min instead of max upper bound"

run_mutant "M10_onepass_cap_limit32" "src/onepass.pion" \
  "  !has_look && num_captures >= 1 && num_captures <= 31 && num_nfa <= 512" \
  "  !has_look && num_captures >= 1 && num_captures <= 32 && num_nfa <= 512" \
  "onepass_can_compile: relaxed capture cap 31 -> 32 (overflows 63-bit mask)"

PCT=$((KILLED * 100 / TOTAL))
echo "=== Mutation kill summary: $KILLED / $TOTAL killed (${PCT}%) ==="
if [ "$PCT" -lt 90 ]; then
  echo "FAIL: mutation kill rate ${PCT}% < 90%" >&2
  exit 1
fi
echo "PASS: packages/regex Stage 2 mutation kill gate ($KILLED/$TOTAL = ${PCT}% >= 90%)"
