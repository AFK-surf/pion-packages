#!/bin/sh
set -eu

# End-to-end Lean 4 formal verification gate for `packages/crdt`.
# All Lake build artifacts stay in /private/tmp/pion-lean-shared (single shared Mathlib .lake, zero git worktree pollution).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$HOME/.cargo/bin:$PATH"
export LEAN_NUM_THREADS="${LEAN_NUM_THREADS:-2}"
export LEAN_MEM_LIMIT="${LEAN_MEM_LIMIT:-8192}"

WORK="${LEAN_WORK:-/private/tmp/pion-lean-shared}"
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

echo "=== [2/7] pionc extract-lean packages/crdt ==="
rm -rf "$PROJ/Crdt"
EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$PKG_DIR" 2>&1)
echo "$EXTRACT_JSON"
for f in Types Funs FunsExternal FunsExternal_Template; do
  if [ ! -f "$PROJ/Crdt/$f.lean" ]; then
    echo "FAIL: missing Crdt/$f.lean" >&2
    exit 1
  fi
done

rm -rf "$PROJ/CrdtProofs"
cp -R "$SCRIPT_DIR/CrdtProofs" "$PROJ/CrdtProofs"
cp "$SCRIPT_DIR/CrdtProofs.lean" "$PROJ/CrdtProofs.lean"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

printf '\nlean_lib Crdt where\n  globs := #[.submodules `Crdt]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"
printf '\nlean_lib CrdtProofs where\n  globs := #[.andSubmodules `CrdtProofs]\n  moreLeanArgs := #["--memory=%s", "-j", "%s"]\n' "$LEAN_MEM_LIMIT" "$LEAN_NUM_THREADS" >> "$PROJ/lakefile.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$SCRIPT_DIR/CrdtProofs.lean" "$SCRIPT_DIR/CrdtProofs" "$SCRIPT_DIR/CheckAxioms.lean" "$SCRIPT_DIR/EvalDiff.lean" >/dev/null; then
  echo "FAIL: proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Crdt CrdtProofs ==="
cd "$PROJ"
set +e
lake build PionLean Crdt CrdtProofs > "$WORK/build.log" 2>&1
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
echo "lake build PionLean Crdt CrdtProofs: exit 0, 0 errors"

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
name = "crdt_lean_diff"
version = "0.1.0"

[dependencies]
crdt = { path = "$PKG_DIR" }
EOF

cat > "$DIFF_DIR/src/main.pion" <<'EOF'
import "crdt"

fn report(w : World, label : String, passed : Bool) -> Unit {
  if passed {
    io_println(w, label + ": PASS")
  } else {
    io_println(w, label + ": FAIL")
  }
}

pub fn main(w : World) -> Int {
  let id1 = crdt::Id::new(1UL, 10UL)
  let id2 = crdt::Id::new(1UL, 20UL)
  let id3 = crdt::Id::new(2UL, 5UL)
  report(w, "id_eq_same", id1.eq(id1))
  report(w, "id_eq_diff_clock", !id1.eq(id2))
  report(w, "id_eq_diff_client", !id1.eq(id3))
  report(w, "id_cmp_same", id1.cmp(id1) == 0)
  report(w, "id_cmp_clock_lt", id1.cmp(id2) == -1)
  report(w, "id_cmp_clock_gt", id2.cmp(id1) == 1)
  report(w, "id_cmp_client_lt", id2.cmp(id3) == -1)
  report(w, "id_cmp_client_gt", id3.cmp(id1) == 1)
  report(w, "opt_id_none_none", crdt::opt_id_eq(None, None))
  report(w, "opt_id_some_none", !crdt::opt_id_eq(Some(id1), None))
  report(w, "opt_id_some_same", crdt::opt_id_eq(Some(id1), Some(id1)))
  report(w, "opt_id_some_diff", !crdt::opt_id_eq(Some(id1), Some(id2)))
  report(w, "yata_before_lt", crdt::yata_same_origin_before(1UL, 2UL))
  report(w, "yata_before_eq", !crdt::yata_same_origin_before(2UL, 2UL))
  report(w, "yata_before_gt", !crdt::yata_same_origin_before(5UL, 2UL))

  report(w, "type_ref_array", crdt::type_ref_to_int(crdt::TypeRef::YArrayRef) == 0)
  report(w, "type_ref_map", crdt::type_ref_to_int(crdt::TypeRef::YMapRef) == 1)
  report(w, "type_ref_text", crdt::type_ref_to_int(crdt::TypeRef::YTextRef) == 2)
  let tr0 = match crdt::int_to_type_ref(0) {
    crdt::TypeRef::YArrayRef => true
    _ => false
  }
  let tr1 = match crdt::int_to_type_ref(1) {
    crdt::TypeRef::YMapRef => true
    _ => false
  }
  let tr2 = match crdt::int_to_type_ref(2) {
    crdt::TypeRef::YTextRef => true
    _ => false
  }
  report(w, "int_to_tr_0", tr0)
  report(w, "int_to_tr_1", tr1)
  report(w, "int_to_tr_2", tr2)
  let lid1 = crdt::item_last_id(id1, 1UL)
  let lid5 = crdt::item_last_id(id1, 5UL)
  report(w, "item_last_id_1", lid1.client == 1UL && lid1.clock == 10UL)
  report(w, "item_last_id_5", lid5.client == 1UL && lid5.clock == 14UL)

  let d1 = crdt::DeleteItem::{ clock: 10UL, len: 5UL }
  let d2 = crdt::DeleteItem::{ clock: 15UL, len: 3UL }
  let d3 = crdt::DeleteItem::{ clock: 12UL, len: 2UL }
  let d4 = crdt::DeleteItem::{ clock: 20UL, len: 4UL }
  report(w, "del_can_merge_adj", crdt::delete_item_can_merge(d1, d2))
  report(w, "del_can_merge_sub", crdt::delete_item_can_merge(d1, d3))
  report(w, "del_can_merge_gap", !crdt::delete_item_can_merge(d1, d4))
  let m12 = crdt::delete_item_merge(d1, d2)
  let m13 = crdt::delete_item_merge(d1, d3)
  report(w, "del_merge_adj", m12.clock == 10UL && m12.len == 8UL)
  report(w, "del_merge_sub", m13.clock == 10UL && m13.len == 5UL)
  report(w, "del_contains_lo", crdt::delete_item_contains(d1, 10UL))
  report(w, "del_contains_hi", crdt::delete_item_contains(d1, 14UL))
  report(w, "del_contains_end", !crdt::delete_item_contains(d1, 15UL))
  report(w, "del_contains_pre", !crdt::delete_item_contains(d1, 9UL))

  let info1 = crdt::encode_item_info(4, true, false, true)
  report(w, "info_enc_val", info1 == 164)
  report(w, "info_ref_4", crdt::info_ref_id(164) == 4)
  report(w, "info_orig_t", crdt::info_has_origin(164))
  report(w, "info_rorig_f", !crdt::info_has_right_origin(164))
  report(w, "info_psub_t", crdt::info_has_parent_sub(164))
  report(w, "info_cant_copy_f", !crdt::info_cant_copy_parent(164))
  report(w, "info_cant_copy_t", crdt::info_cant_copy_parent(36))
  report(w, "hex_char_0", crdt::hex_nibble_char(0) == 48)
  report(w, "hex_char_15", crdt::hex_nibble_char(15) == 102)
  report(w, "hex_parse_9", crdt::parse_hex_nibble(57) == 9)
  report(w, "hex_parse_a", crdt::parse_hex_nibble(97) == 10)
  report(w, "hex_parse_F", crdt::parse_hex_nibble(70) == 15)
  report(w, "hex_parse_bad", crdt::parse_hex_nibble(122) == -1)
  0
}
EOF

"$PIONC" build --release -o "$DIFF_DIR/runner" "$DIFF_DIR"
"$DIFF_DIR/runner" > "$DIFF_DIR/native.out"
printf '%s\n' "$EVAL_OUT" | grep -E ': (PASS|FAIL)$' > "$DIFF_DIR/lean.out"
diff -u "$DIFF_DIR/native.out" "$DIFF_DIR/lean.out"
echo "Native vs Lean differential: $(wc -l < "$DIFF_DIR/native.out" | tr -d ' ') cases identical (diff -u exit 0)"
echo "PASS: packages/crdt Lean 4 proofs"
