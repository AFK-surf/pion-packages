import Aeneas
import PionLean
import Msgpack.Types
import Msgpack.Funs

open Aeneas Aeneas.Std Result Pion msgpack

namespace MsgpackProofs

lemma iscalar_le_iff {ty : IScalarTy} (a b : IScalar ty) : a ≤ b ↔ a.val ≤ b.val := Iff.rfl
lemma iscalar_lt_iff {ty : IScalarTy} (a b : IScalar ty) : a < b ↔ a.val < b.val := Iff.rfl
lemma iscalar_eq_iff {ty : IScalarTy} (a b : IScalar ty) : a = b ↔ a.val = b.val := by
  constructor
  · intro h; subst h; rfl
  · intro h; cases a; cases b; congr; exact BitVec.eq_of_toInt_eq h

lemma uscalar_le_iff {ty : UScalarTy} (a b : UScalar ty) : a ≤ b ↔ a.val ≤ b.val := Iff.rfl
lemma uscalar_lt_iff {ty : UScalarTy} (a b : UScalar ty) : a < b ↔ a.val < b.val := Iff.rfl
lemma uscalar_eq_iff {ty : UScalarTy} (a b : UScalar ty) : a = b ↔ a.val = b.val := by
  constructor
  · intro h; subst h; rfl
  · intro h; cases a; cases b; congr; exact BitVec.eq_of_toNat_eq h

lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

lemma i32_bounds (x : Std.I32) :
    -(2147483648 : Int) ≤ x.val ∧ x.val ≤ 2147483647 := by
  have h1 := x.hBounds
  have hpow : (2 : Int) ^ (IScalarTy.I32.numBits - 1) = 2147483648 := by
    change (2 : Int) ^ (32 - 1) = 2147483648; norm_num
  omega

lemma i64_bounds (x : Std.I64) :
    -(9223372036854775808 : Int) ≤ x.val ∧ x.val ≤ 9223372036854775807 := by
  have h1 := x.hBounds
  have hpow : (2 : Int) ^ (IScalarTy.I64.numBits - 1) = 9223372036854775808 := by
    change (2 : Int) ^ (64 - 1) = 9223372036854775808; norm_num
  omega

lemma u64_127_val : (127#u64).val = 127 := by
  change (BitVec.ofNat 64 127).toNat = 127; rw [BitVec.toNat_ofNat]

lemma u64_255_val : (255#u64).val = 255 := by
  change (BitVec.ofNat 64 255).toNat = 255; rw [BitVec.toNat_ofNat]

lemma u64_65535_val : (65535#u64).val = 65535 := by
  change (BitVec.ofNat 64 65535).toNat = 65535; rw [BitVec.toNat_ofNat]

lemma u64_u32max_val : (4294967295#u64).val = 4294967295 := by
  change (BitVec.ofNat 64 4294967295).toNat = 4294967295; rw [BitVec.toNat_ofNat]

lemma i64_add_val (a b : Std.I64)
    (hlo : -(9223372036854775808 : Int) ≤ a.val + b.val)
    (hhi : a.val + b.val ≤ 9223372036854775807) :
    (Pion.I64.add a b).val = a.val + b.val := by
  simp only [Pion.I64.add, Std.I64.wrapping_add, IScalar.wrapping_add, IScalar.val, BitVec.toInt_add]
  have hpow : (2 : Nat) ^ IScalarTy.I64.numBits = 2 ^ 64 := rfl
  rw [hpow]
  change (a.val + b.val).bmod (2 ^ 64) = a.val + b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i32_sub_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val - b.val)
    (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  simp only [Pion.I32.sub, Std.I32.wrapping_sub, IScalar.wrapping_sub, IScalar.val, BitVec.toInt_sub]
  have hpow : (2 : Nat) ^ IScalarTy.I32.numBits = 2 ^ 32 := rfl
  rw [hpow]
  change (a.val - b.val).bmod (2 ^ 32) = a.val - b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i32_add_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val + b.val)
    (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  simp only [Pion.I32.add, Std.I32.wrapping_add, IScalar.wrapping_add, IScalar.val, BitVec.toInt_add]
  have hpow : (2 : Nat) ^ IScalarTy.I32.numBits = 2 ^ 32 := rfl
  rw [hpow]
  change (a.val + b.val).bmod (2 ^ 32) = a.val + b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i32_to_i64_val (x : Std.I32) :
    (Pion.I32.to_int64 x).val = x.val := by
  have hx := i32_bounds x
  unfold Pion.I32.to_int64
  change (BitVec.ofInt 64 x.val).toInt = x.val
  rw [BitVec.toInt_ofInt, Int.bmod_eq_of_le] <;> norm_num <;> omega

/-- Default `DecodeOptions` enforces bounded depth (512), items (1M), bytes (64 MiB), and rejects trailing bytes. -/
theorem decode_options_default_spec :
    ∃ o : DecodeOptions, DecodeOptions.default = ok o ∧
      o.max_depth.val = 512 ∧ o.max_items.val = 1048576 ∧ o.max_bytes.val = 67108864 ∧
      o.decode_timestamp = true ∧ o.allow_trailing_bytes = false := by
  refine ⟨DecodeOptions.mk 512#i32 1048576#i32 67108864#i32 false false true false, rfl, ?_, ?_, ?_, rfl, rfl⟩
  · change (BitVec.ofInt 32 512).toInt = 512; rw [BitVec.toInt_ofInt]; norm_num
  · change (BitVec.ofInt 32 1048576).toInt = 1048576; rw [BitVec.toInt_ofInt]; norm_num
  · change (BitVec.ofInt 32 67108864).toInt = 67108864; rw [BitVec.toInt_ofInt]; norm_num

/-- Strict `DecodeOptions` enables duplicate-key rejection and canonical encoding enforcement. -/
theorem decode_options_strict_spec :
    ∃ o : DecodeOptions, DecodeOptions.strict = ok o ∧
      o.reject_duplicate_keys = true ∧ o.require_canonical = true ∧ o.allow_trailing_bytes = false :=
  ⟨DecodeOptions.mk 512#i32 1048576#i32 67108864#i32 true true true false, rfl, rfl, rfl, rfl⟩

/-- `EncodeOptions::default` disables float32 compaction; `EncodeOptions::compact` enables it. -/
theorem encode_options_specs :
    (∃ o : EncodeOptions, EncodeOptions.default = ok o ∧ o.compact_floats = false) ∧
    (∃ o : EncodeOptions, EncodeOptions.compact = ok o ∧ o.compact_floats = true) :=
  ⟨⟨EncodeOptions.mk false, rfl, rfl⟩, ⟨EncodeOptions.mk true, rfl, rfl⟩⟩

/-- MessagePack `Ext` type tag is valid iff `-128 <= tag <= 127`. -/
theorem is_valid_ext_tag_spec (tag : Std.I32) :
    is_valid_ext_tag tag = ok (decide (-128 ≤ tag.val ∧ tag.val ≤ 127)) := by
  unfold is_valid_ext_tag; congr 1

end MsgpackProofs
