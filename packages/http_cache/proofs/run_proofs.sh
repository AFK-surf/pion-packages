#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LEAN_WORK="${LEAN_WORK:-/private/tmp/pion-lean-shared}"
LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"
PROJ="$LEAN_WORK/proj"

echo "=== [1/7] Prepare Pion lean/ runtime & Aeneas in $LEAN_WORK ==="
mkdir -p "$PROJ"
if [ ! -d "$PROJ/PionLean" ]; then
  if [ -d /private/tmp/pion-lean-ref/PionLean ]; then
    cp -R /private/tmp/pion-lean-ref/PionLean "$PROJ/PionLean"
    cp /private/tmp/pion-lean-ref/PionLean.lean "$PROJ/PionLean.lean"
  else
    echo "ERROR: PionLean reference missing" >&2
    exit 1
  fi
fi

rm -f "$PROJ/lakefile.toml"
cat > "$PROJ/lakefile.lean" <<EOF
import Lake
open Lake DSL

require aeneas from "./.deps/aeneas"

package «pionlean» where
  leanOptions := #[⟨\`weak.linter.dupNamespace, false⟩]

@[default_target] lean_lib PionLean

lean_lib HttpCache where
  moreLeanArgs := #["--memory=$LEAN_MEM_LIMIT", "-j", "$LEAN_NUM_THREADS"]

lean_lib HttpCacheProofs where
  moreLeanArgs := #["--memory=$LEAN_MEM_LIMIT", "-j", "$LEAN_NUM_THREADS"]
EOF

echo "=== [2/7] pionc extract-lean packages/http_cache ==="
rm -rf "$PROJ/HttpCache" "$PROJ/HttpCacheProofs" "$PROJ/HttpCacheProofs.lean" "$PROJ/CheckAxioms.lean" "$PROJ/EvalDiff.lean"
pionc extract-lean --json "$PKG_DIR" --out "$PROJ"

cp "$SCRIPT_DIR/HttpCacheProofs.lean" "$PROJ/HttpCacheProofs.lean"
cp -R "$SCRIPT_DIR/HttpCacheProofs" "$PROJ/HttpCacheProofs"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "$SCRIPT_DIR/HttpCacheProofs" "$SCRIPT_DIR/HttpCacheProofs.lean"; then
  echo "FAIL: forbidden tactic or axiom found" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean HttpCache.Types HttpCache.Funs HttpCacheProofs ==="
(
  cd "$PROJ"
  LEAN_NUM_THREADS="$LEAN_NUM_THREADS" lake build \
    PionLean HttpCache.Types HttpCache.Funs HttpCacheProofs
)

echo "=== [5/7] CheckAxioms (standard axioms only) ==="
AXIOM_OUT="$(cd "$PROJ" && lake env lean "$PROJ/CheckAxioms.lean")"
echo "$AXIOM_OUT"
if echo "$AXIOM_OUT" | grep -E 'sorryAx|Lean\.ofReduceBool|Lean\.trustCompiler'; then
  echo "FAIL: non-standard axiom detected" >&2
  exit 1
fi
THM_COUNT="$(echo "$AXIOM_OUT" | grep -c "^'HttpCacheProofs\." || true)"
if [ "$THM_COUNT" -ne 24 ]; then
  echo "FAIL: expected 24 theorems in CheckAxioms, got $THM_COUNT" >&2
  exit 1
fi
echo "CheckAxioms: $THM_COUNT theorems verified, standard axioms only"

echo "=== [6/7] Lean EvalDiff ==="
LEAN_DIFF_OUT="$(cd "$PROJ" && lake env lean "$PROJ/EvalDiff.lean")"
echo "$LEAN_DIFF_OUT"
if echo "$LEAN_DIFF_OUT" | grep -q "FAIL"; then
  echo "FAIL: Lean EvalDiff reported FAIL" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_TMP="$(mktemp -d /tmp/http_cache-diff.XXXXXX)"
trap 'rm -rf "$DIFF_TMP"; kill -- -$$ 2>/dev/null || true' EXIT INT TERM
mkdir -p "$DIFF_TMP/src"

cat > "$DIFF_TMP/pion.toml" <<EOF
[package]
name = "http_cache_diff"
version = "0.1.0"

[dependencies]
http_cache = { path = "$PKG_DIR" }
EOF

cat > "$DIFF_TMP/src/main.pion" <<'EOF'
import "http_cache"

fn check_i64(w : World, label : String, actual : Int64, expected : Int64) -> Unit {
  if actual == expected { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn check_i32(w : World, label : String, actual : Int, expected : Int) -> Unit {
  if actual == expected { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

fn check_bool(w : World, label : String, actual : Bool, expected : Bool) -> Unit {
  if actual == expected { io_println(w, label + ": PASS") } else { io_println(w, label + ": FAIL") }
}

pub fn main(w : World) -> Int {
  check_i64(w, "add_0_0", http_cache::clamped_add_i64(0L, 0L), 0L)
  check_i64(w, "add_10_20", http_cache::clamped_add_i64(10L, 20L), 30L)
  check_i64(w, "add_clamp", http_cache::clamped_add_i64(2147483640L, 100L), 2147483648L)
  check_i64(w, "add_ovf", http_cache::clamped_add_i64(9223372036854775807L, 1L), 2147483648L)
  check_i64(w, "sub_le", http_cache::clamped_sub_i64(100L, 200L), 0L)
  check_i64(w, "sub_eq", http_cache::clamped_sub_i64(500L, 500L), 0L)
  check_i64(w, "sub_mid", http_cache::clamped_sub_i64(1000L, 250L), 750L)
  check_i64(w, "sub_clamp", http_cache::clamped_sub_i64(5000000000L, 0L), 2147483648L)
  check_i64(w, "sub_extreme", http_cache::clamped_sub_i64(9223372036854775807L, -100L), 2147483648L)
  check_i64(w, "iage_app", http_cache::compute_initial_age_core(50L, 10L, 100L, 105L), 50L)
  check_i64(w, "iage_corr", http_cache::compute_initial_age_core(5L, 10L, 100L, 125L), 35L)
  check_i64(w, "cage_0", http_cache::compute_current_age_core(30L, 1000L, 900L), 30L)
  check_i64(w, "cage_60", http_cache::compute_current_age_core(30L, 1000L, 1060L), 90L)
  check_i64(w, "cage_cap", http_cache::compute_current_age_core(2147483640L, 1000L, 2000L), 2147483648L)
  check_bool(w, "hc_200", http_cache::is_heuristically_cacheable_status(200), true)
  check_bool(w, "hc_206", http_cache::is_heuristically_cacheable_status(206), false)
  check_bool(w, "hc_308", http_cache::is_heuristically_cacheable_status(308), true)
  check_bool(w, "hc_410", http_cache::is_heuristically_cacheable_status(410), true)
  check_bool(w, "hc_501", http_cache::is_heuristically_cacheable_status(501), true)
  check_bool(w, "hc_500", http_cache::is_heuristically_cacheable_status(500), false)
  check_bool(w, "us_302", http_cache::is_understood_status(302), true)
  check_bool(w, "us_206", http_cache::is_understood_status(206), false)
  check_bool(w, "us_418", http_cache::is_understood_status(418), false)
  check_bool(w, "lim_def", http_cache::limits_all_nonneg(http_cache::CacheLimits::default()), true)
  check_bool(w, "lim_neg", http_cache::limits_all_nonneg(http_cache::CacheLimits::new(-1, 1, 1, 1, 1L, 1, 1L)), false)
  check_bool(w, "dig_0", http_cache::is_ascii_digit(48), true)
  check_bool(w, "dig_9", http_cache::is_ascii_digit(57), true)
  check_bool(w, "dig_a", http_cache::is_ascii_digit(97), false)
  check_bool(w, "leap_2000", http_cache::is_leap_year(2000), true)
  check_bool(w, "leap_1900", http_cache::is_leap_year(1900), false)
  check_bool(w, "leap_2024", http_cache::is_leap_year(2024), true)
  check_bool(w, "leap_2025", http_cache::is_leap_year(2025), false)
  check_i32(w, "dim_feb24", http_cache::days_in_month(2024, 2), 29)
  check_i32(w, "dim_feb25", http_cache::days_in_month(2025, 2), 28)
  check_i32(w, "dim_apr", http_cache::days_in_month(2025, 4), 30)
  check_i32(w, "dim_dec", http_cache::days_in_month(2025, 12), 31)
  0
}
EOF

printf '%s\n' "$LEAN_DIFF_OUT" > "$DIFF_TMP/lean.out"
PION_CACHE_DIR="$DIFF_TMP/cache" pionc run "$DIFF_TMP" > "$DIFF_TMP/pion.out"
diff -u "$DIFF_TMP/lean.out" "$DIFF_TMP/pion.out"
CASE_COUNT="$(wc -l < "$DIFF_TMP/lean.out" | tr -d ' ')"
echo "Native vs Lean differential: $CASE_COUNT cases identical (diff -u exit 0)"
echo "PASS: packages/http_cache Lean 4 proofs"
