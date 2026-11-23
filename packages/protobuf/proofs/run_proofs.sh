#!/usr/bin/env bash
set -euo pipefail
trap 'kill -- -$$ 2>/dev/null || true' INT TERM

export PATH="$HOME/.pion/bin:$HOME/.elan/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd)"

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

lean_lib Protobuf where
  moreLeanArgs := #["--memory=$LEAN_MEM_LIMIT", "-j", "$LEAN_NUM_THREADS"]

lean_lib ProtobufProofs where
  moreLeanArgs := #["--memory=$LEAN_MEM_LIMIT", "-j", "$LEAN_NUM_THREADS"]
EOF

echo "=== [2/7] pionc extract-lean packages/protobuf ==="
rm -rf "$PROJ/Protobuf" "$PROJ/ProtobufProofs" "$PROJ/ProtobufProofs.lean" "$PROJ/CheckAxioms.lean" "$PROJ/EvalDiff.lean"
pionc extract-lean --json "$PKG_DIR" --out "$PROJ"

cp "$SCRIPT_DIR/ProtobufProofs.lean" "$PROJ/ProtobufProofs.lean"
cp -R "$SCRIPT_DIR/ProtobufProofs" "$PROJ/ProtobufProofs"
cp "$SCRIPT_DIR/CheckAxioms.lean" "$PROJ/CheckAxioms.lean"
cp "$SCRIPT_DIR/EvalDiff.lean" "$PROJ/EvalDiff.lean"

echo "=== [3/7] Static scan for forbidden tactics/axioms ==="
if grep -rnE '\b(sorry|admit|axiom|bv_decide|native_decide)\b' "$SCRIPT_DIR/ProtobufProofs" "$SCRIPT_DIR/ProtobufProofs.lean"; then
  echo "FAIL: forbidden tactic or axiom found" >&2
  exit 1
fi
echo "Static scan: 0 sorry / admit / axiom / bv_decide / native_decide"

echo "=== [4/7] lake build PionLean Protobuf.Types Protobuf.Funs ProtobufProofs ==="
(
  cd "$PROJ"
  LEAN_NUM_THREADS="$LEAN_NUM_THREADS" lake build \
    PionLean Protobuf.Types Protobuf.Funs ProtobufProofs
)

echo "=== [5/7] CheckAxioms (standard axioms only) ==="
AXIOM_OUT="$(cd "$PROJ" && lake env lean "$PROJ/CheckAxioms.lean")"
echo "$AXIOM_OUT"
if echo "$AXIOM_OUT" | grep -E 'sorryAx|Lean\.ofReduceBool|Lean\.trustCompiler'; then
  echo "FAIL: non-standard axiom detected" >&2
  exit 1
fi
THM_COUNT="$(echo "$AXIOM_OUT" | grep -c "^'ProtobufProofs\." || true)"
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
DIFF_TMP="$(mktemp -d /tmp/protobuf-diff.XXXXXX)"
trap 'rm -rf "$DIFF_TMP"; kill -- -$$ 2>/dev/null || true' EXIT INT TERM
mkdir -p "$DIFF_TMP/src"

cat > "$DIFF_TMP/pion.toml" <<EOF
[package]
name = "protobuf_diff"
version = "0.1.0"

[dependencies]
protobuf = { path = "$PKG_DIR" }
EOF

cat > "$DIFF_TMP/src/main.pion" <<'EOF'
import "protobuf"

fn check_i64(w : World, name : String, actual : Int64, expected : Int64) -> Unit {
  if actual == expected { io_println(w, name + ": PASS") } else { io_println(w, name + ": FAIL") }
}

fn check_u64(w : World, name : String, actual : UInt64, expected : UInt64) -> Unit {
  if actual == expected { io_println(w, name + ": PASS") } else { io_println(w, name + ": FAIL") }
}

fn check_i32(w : World, name : String, actual : Int, expected : Int) -> Unit {
  if actual == expected { io_println(w, name + ": PASS") } else { io_println(w, name + ": FAIL") }
}

fn check_wt_opt(w : World, name : String, actual : Option[protobuf::WireType], expected : Int) -> Unit {
  let code = match actual {
    Some(wt) => protobuf::wire_type_code(wt)
    None => -1
  }
  if code == expected { io_println(w, name + ": PASS") } else { io_println(w, name + ": FAIL") }
}

pub fn main(w : World) -> Int {
  check_i64(w, "zz32_enc_0", protobuf::zigzag_encode_i32(0), 0L)
  check_i64(w, "zz32_enc_m1", protobuf::zigzag_encode_i32(-1), 1L)
  check_i64(w, "zz32_enc_1", protobuf::zigzag_encode_i32(1), 2L)
  check_i64(w, "zz32_enc_m2", protobuf::zigzag_encode_i32(-2), 3L)
  check_i64(w, "zz32_enc_max", protobuf::zigzag_encode_i32(2147483647), 4294967294L)
  check_i64(w, "zz32_enc_min", protobuf::zigzag_encode_i32(-2147483648), 4294967295L)
  check_i32(w, "zz32_dec_0", protobuf::zigzag_decode_i32(0L), 0)
  check_i32(w, "zz32_dec_1", protobuf::zigzag_decode_i32(1L), -1)
  check_i32(w, "zz32_dec_max", protobuf::zigzag_decode_i32(4294967294L), 2147483647)
  check_i32(w, "zz32_dec_min", protobuf::zigzag_decode_i32(4294967295L), -2147483648)
  check_u64(w, "zz64_enc_0", protobuf::zigzag_encode_i64(0L), 0UL)
  check_u64(w, "zz64_enc_m1", protobuf::zigzag_encode_i64(-1L), 1UL)
  check_u64(w, "zz64_enc_1", protobuf::zigzag_encode_i64(1L), 2UL)
  check_u64(w, "zz64_enc_max", protobuf::zigzag_encode_i64(9223372036854775807L), 18446744073709551614UL)
  check_u64(w, "zz64_enc_min", protobuf::zigzag_encode_i64(-9223372036854775807L - 1L), 18446744073709551615UL)
  check_i64(w, "zz64_dec_0", protobuf::zigzag_decode_i64(0UL), 0L)
  check_i64(w, "zz64_dec_1", protobuf::zigzag_decode_i64(1UL), -1L)
  check_i64(w, "zz64_dec_min", protobuf::zigzag_decode_i64(18446744073709551615UL), -9223372036854775807L - 1L)
  check_i32(w, "vlen_0", protobuf::varint_len_u64(0UL), 1)
  check_i32(w, "vlen_127", protobuf::varint_len_u64(127UL), 1)
  check_i32(w, "vlen_128", protobuf::varint_len_u64(128UL), 2)
  check_i32(w, "vlen_16383", protobuf::varint_len_u64(16383UL), 2)
  check_i32(w, "vlen_16384", protobuf::varint_len_u64(16384UL), 3)
  check_i32(w, "vlen_268435456", protobuf::varint_len_u64(268435456UL), 5)
  check_i32(w, "vlen_max9", protobuf::varint_len_u64(9223372036854775807UL), 9)
  check_i32(w, "vlen_min10", protobuf::varint_len_u64(9223372036854775808UL), 10)
  check_i32(w, "vlen_max", protobuf::varint_len_u64(18446744073709551615UL), 10)
  check_i32(w, "wt_varint", protobuf::wire_type_code(protobuf::WireType::Varint), 0)
  check_i32(w, "wt_fixed32", protobuf::wire_type_code(protobuf::WireType::Fixed32), 5)
  check_wt_opt(w, "wtf_2", protobuf::wire_type_from_code(2), 2)
  check_wt_opt(w, "wtf_6", protobuf::wire_type_from_code(6), -1)
  check_u64(w, "tag_enc_1", protobuf::encode_tag_raw(1, protobuf::WireType::Varint), 8UL)
  check_u64(w, "tag_enc_max", protobuf::encode_tag_raw(536870911, protobuf::WireType::Fixed32), 4294967293UL)
  check_i32(w, "tag_dec_fn", protobuf::decode_tag_field_num(4294967293UL), 536870911)
  check_i32(w, "tag_dec_wt", protobuf::decode_tag_wire_type(4294967293UL), 5)
  check_i32(w, "taglen_15", protobuf::tag_len(15), 1)
  check_i32(w, "taglen_16", protobuf::tag_len(16), 2)
  check_i32(w, "taglen_max", protobuf::tag_len(536870911), 5)
  check_i32(w, "fn_0", protobuf::field_number_err_code(0, false), 1)
  check_i32(w, "fn_1", protobuf::field_number_err_code(1, true), 0)
  check_i32(w, "fn_19000_t", protobuf::field_number_err_code(19000, true), 2)
  check_i32(w, "fn_19000_f", protobuf::field_number_err_code(19000, false), 0)
  check_i32(w, "fn_max", protobuf::field_number_err_code(536870911, true), 0)
  check_i32(w, "fn_over", protobuf::field_number_err_code(536870912, false), 1)
  0
}
EOF

printf '%s\n' "$LEAN_DIFF_OUT" > "$DIFF_TMP/lean.out"
PION_CACHE_DIR="$DIFF_TMP/cache" pionc run "$DIFF_TMP" > "$DIFF_TMP/pion.out"
diff -u "$DIFF_TMP/lean.out" "$DIFF_TMP/pion.out"
CASE_COUNT="$(wc -l < "$DIFF_TMP/lean.out" | tr -d ' ')"
echo "Native vs Lean differential: $CASE_COUNT cases identical (diff -u exit 0)"
echo "PASS: packages/protobuf Lean 4 proofs"
