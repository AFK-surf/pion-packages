#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/graph`.
# All Lake build artifacts stay in /private/tmp/pion-lean-graph (zero git worktree pollution).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

WORK="${LEAN_WORK:-/private/tmp/pion-lean-graph}"
PROJ="$WORK/proj"
PION_REF="${PION_LEAN_REF:-$WORK/pion-ref}"
AENEAS_REV=1dc8ad31b1
PIONC="${PIONC:-pionc}"

mkdir -p "$WORK"

echo "=== [1/7] Prepare Pion lean/ runtime & Aeneas@$AENEAS_REV in $WORK ==="
if [ ! -d "$PION_REF/lean" ]; then
  if [ -d "/private/tmp/pion-lean-ref/lean" ]; then
    PION_REF="/private/tmp/pion-lean-ref"
  elif [ -d "/private/tmp/pion-lean-ref-semver/lean" ]; then
    PION_REF="/private/tmp/pion-lean-ref-semver"
  else
    git clone --depth 1 -q https://github.com/AFK-surf/pion.git "$PION_REF"
  fi
fi

if [ -z "${AENEAS_DIR:-}" ]; then
  if [ -d "/private/tmp/pion-lean-semver/aeneas/backends/lean" ]; then
    AENEAS_DIR="/private/tmp/pion-lean-semver/aeneas/backends/lean"
  else
    if [ ! -d "$WORK/aeneas/.git" ]; then
      git clone -q https://github.com/AeneasVerif/aeneas.git "$WORK/aeneas"
    fi
    git -C "$WORK/aeneas" checkout -q "$AENEAS_REV"
    AENEAS_DIR="$WORK/aeneas/backends/lean"
  fi
fi

if [ ! -f "$PROJ/lakefile.lean" ] || [ ! -d "$PROJ/.lake/packages/mathlib" ]; then
  rm -rf "$PROJ"
  mkdir -p "$PROJ/.deps" "$PROJ/.lake"
  (cd "$PION_REF/lean" && tar -cf - --exclude .lake --exclude .deps .) | (cd "$PROJ" && tar -xf -)
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
  (cd "$PROJ" && lake exe cache get)
else
  cp "$PION_REF/lean/lakefile.lean" "$PROJ/lakefile.lean"
  ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
fi

echo "=== [2/7] pionc extract-lean packages/graph ==="
rm -rf "$PROJ/Graph"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Graph/$f.lean" ]; then
    echo "FAIL: missing Graph/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/GraphProofs"
cp -R "$SCRIPT_DIR/GraphProofs" "$PROJ/GraphProofs"
cp "$SCRIPT_DIR/GraphProofs.lean" "$PROJ/GraphProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Graph where\n  globs := #[.submodules `Graph]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib GraphProofs where\n  globs := #[.andSubmodules `GraphProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/GraphProofs.lean" "$SCRIPT_DIR/GraphProofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Graph GraphProofs ==="
cd "$PROJ"
set +e
lake build PionLean Graph GraphProofs > "$WORK/build.log" 2>&1
RC=$?
set -e
grep -v '^✔\|^trace\|^info' "$WORK/build.log" | tail -80 || true
if [ "$RC" -ne 0 ] || grep -q '^error' "$WORK/build.log"; then
  echo "FAIL: lake build failed (rc=$RC)" >&2
  cat "$WORK/build.log" >&2
  exit 1
fi
if grep -q "declaration uses .sorry" "$WORK/build.log"; then
  echo "FAIL: declaration uses sorry" >&2
  exit 1
fi
echo "lake build PionLean Graph GraphProofs: exit 0, 0 errors"

echo "=== [5/7] #print axioms audit ==="
AXIOMS_OUT=$(lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" CheckAxioms.lean 2>&1)
echo "$AXIOMS_OUT"
BAD_AXIOMS=$(printf '%s\n' "$AXIOMS_OUT" | grep -E "depends on axioms:" | sed 's/.*\[//;s/\].*//;s/,/\n/g' | tr -d ' ' | sort -u | grep -v -E '^(propext|Classical\.choice|Quot\.sound)$' || true)
if [ -n "$BAD_AXIOMS" ]; then
  echo "FAIL: unexpected axioms found: $BAD_AXIOMS" >&2
  exit 1
fi
if printf '%s\n' "$AXIOMS_OUT" | grep -q "error:"; then
  echo "FAIL: CheckAxioms.lean reported errors" >&2
  exit 1
fi
echo "Axioms audit: ONLY standard axioms (propext, Classical.choice, Quot.sound)"

echo "=== [6/7] EvalDiff.lean (#eval) ==="
EVAL_OUT=$(lake env lean --memory="$LEAN_MEM_LIMIT" -j "$LEAN_NUM_THREADS" --run EvalDiff.lean 2>&1)
echo "$EVAL_OUT"
if printf '%s\n' "$EVAL_OUT" | grep -q "error:"; then
  echo "FAIL: EvalDiff.lean reported errors" >&2
  exit 1
fi
if printf '%s\n' "$EVAL_OUT" | grep -q ': FAIL$'; then
  echo "FAIL: EvalDiff.lean had a FAIL check" >&2
  exit 1
fi

echo "=== [7/7] Native Pion vs Lean differential cross-check (diff -u) ==="
DIFF_DIR="$WORK/native-diff"
rm -rf "$DIFF_DIR"
mkdir -p "$DIFF_DIR/src"
cat > "$DIFF_DIR/pion.toml" <<EOF
[package]
name = "graph_lean_diff"
version = "0.1.0"

[dependencies]
graph = { path = "$PKG_DIR" }
EOF

cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "graph"

fn report(w : World, label : String, passed : Bool) -> Unit {
  if passed {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

fn opt_i64_eq(a : Option[Int64], b : Option[Int64]) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => x == y
    _ => false
  }
}

pub fn main(w : World) -> Int {
  report(w, "node_id_rt_0", graph::NodeId::new(0).to_int() == 0)
  report(w, "node_id_rt_42", graph::NodeId::new(42).to_int() == 42)
  report(w, "node_id_eq_true", graph::NodeId::new(7).eq(graph::NodeId::new(7)))
  report(w, "node_id_eq_false", !graph::NodeId::new(7).eq(graph::NodeId::new(8)))
  report(w, "edge_id_rt_99", graph::EdgeId::new(99).to_int() == 99)
  report(w, "edge_id_eq_true", graph::EdgeId::new(3).eq(graph::EdgeId::new(3)))
  report(w, "edge_id_eq_false", !graph::EdgeId::new(3).eq(graph::EdgeId::new(4)))

  report(w, "valid_nc_neg1", !graph::is_valid_node_count(-1))
  report(w, "valid_nc_0", graph::is_valid_node_count(0))
  report(w, "valid_nc_max", graph::is_valid_node_count(67108864))
  report(w, "valid_nc_over", !graph::is_valid_node_count(67108865))
  report(w, "valid_idx_neg1", !graph::is_valid_node_idx(-1, 10))
  report(w, "valid_idx_0_10", graph::is_valid_node_idx(0, 10))
  report(w, "valid_idx_9_10", graph::is_valid_node_idx(9, 10))
  report(w, "valid_idx_10_10", !graph::is_valid_node_idx(10, 10))

  let min_i64 = -9223372036854775807L - 1L
  report(w, "cadd_10_20", opt_i64_eq(graph::checked_add_i64(10L, 20L), Some(30L)))
  report(w, "cadd_max_0", opt_i64_eq(graph::checked_add_i64(9223372036854775807L, 0L), Some(9223372036854775807L)))
  report(w, "cadd_max_1_none", opt_i64_eq(graph::checked_add_i64(9223372036854775807L, 1L), None))
  report(w, "cadd_min_m1_none", opt_i64_eq(graph::checked_add_i64(min_i64, -1L), None))
  report(w, "cadd_max_negmax", opt_i64_eq(graph::checked_add_i64(9223372036854775807L, -9223372036854775807L), Some(0L)))

  report(w, "fits_0_max", graph::fits_i64(0L, 9223372036854775807UL))
  report(w, "fits_0_signbit_false", !graph::fits_i64(0L, 9223372036854775808UL))
  report(w, "fits_m1_signbit_true", graph::fits_i64(-1L, 9223372036854775808UL))
  report(w, "fits_m1_halfmax_false", !graph::fits_i64(-1L, 9223372036854775807UL))
  report(w, "fits_1_0_false", !graph::fits_i64(1L, 0UL))
  report(w, "sign_hi_pos", graph::i64_sign_hi(42L) == 0L)
  report(w, "sign_hi_neg", graph::i64_sign_hi(-42L) == -1L)
  report(w, "carry_0", graph::i128_add_carry(100UL, 200UL) == 0L)
  report(w, "carry_1", graph::i128_add_carry(18446744073709551615UL, 1UL) == 1L)
  report(w, "i128_lt_hi", graph::i128_lt(-1L, 100UL, 0L, 0UL))
  report(w, "i128_lt_lo", graph::i128_lt(0L, 5UL, 0L, 6UL))
  report(w, "i128_lt_eq", !graph::i128_lt(0L, 5UL, 0L, 5UL))

  report(w, "radix_min", graph::i64_to_radix_key(min_i64) == 0UL)
  report(w, "radix_0", graph::i64_to_radix_key(0L) == 9223372036854775808UL)
  report(w, "radix_max", graph::i64_to_radix_key(9223372036854775807L) == 18446744073709551615UL)

  report(w, "fwd_edge_5", graph::forward_half_edge(5) == 10)
  report(w, "twin_10", graph::residual_twin(10) == 11)
  report(w, "twin_11", graph::residual_twin(11) == 10)
  report(w, "heap_parent_1", graph::heap_parent(1) == 0)
  report(w, "heap_parent_2", graph::heap_parent(2) == 0)
  report(w, "heap_parent_7", graph::heap_parent(7) == 3)
  report(w, "heap_left_0", graph::heap_left_child(0) == 1)
  report(w, "heap_left_3", graph::heap_left_child(3) == 7)
  0
}
EOF

"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/graph Lean 4 proofs"
