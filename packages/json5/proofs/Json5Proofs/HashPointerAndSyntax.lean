import Aeneas
import PionLean
import Json5.Types
import Json5.Funs

open Aeneas Aeneas.Std Result Error Pion
open json5

namespace Json5Proofs

private lemma i32_mul_val (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val * y.val) (hhi : x.val * y.val < 2 ^ 31) :
    (Pion.I32.mul x y).val = x.val * y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt * y.bv.toInt at hlo
  change x.bv.toInt * y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv * y.bv).toInt = x.bv.toInt * y.bv.toInt
  rw [BitVec.toInt_mul]
  exact Int.bmod_eq_of_le (by omega) (by omega)

/-- Open-addressing termination guarantee: whenever `hash_needs_grow len cap = false`
    (with `0 ≤ len`, `0 < cap`, `len, cap < 2^28`, guarded in `packages/json5/src/hash_index.pion`),
    `len < cap`, so at least one empty slot exists during linear probing. -/
theorem hash_needs_grow_guarantees_empty_slot (len cap : Std.I32)
    (hlen0 : 0 ≤ len.val) (hcap0 : 0 < cap.val)
    (hlen_hi : len.val < 2 ^ 28) (hcap_hi : cap.val < 2 ^ 28) :
    hash_needs_grow len cap = ok false → len.val < cap.val := by
  unfold hash_needs_grow
  have h8 : (8#i32).val = 8 := by decide
  have h5 : (5#i32).val = 5 := by decide
  have hm1 : (Pion.I32.mul len 8#i32).val = len.val * 8 := by
    rw [i32_mul_val len 8#i32 (by rw [h8]; omega) (by rw [h8]; omega), h8]
  have hm2 : (Pion.I32.mul cap 5#i32).val = cap.val * 5 := by
    rw [i32_mul_val cap 5#i32 (by rw [h5]; omega) (by rw [h5]; omega), h5]
  simp only [Result.ok.injEq, decide_eq_false_iff_not, ge_iff_le, IScalar.le_equiv, hm1, hm2]
  omega

/-- `hash_next_slot` always produces an in-bounds array index in `[0, mask]` for `mask ≥ 0`. -/
theorem hash_next_slot_bounds (slot mask : Std.I32) (hmask : 0 ≤ mask.val) :
    ∃ nxt : Std.I32,
      hash_next_slot slot mask = ok nxt ∧ 0 ≤ nxt.val ∧ nxt.val ≤ mask.val := by
  unfold hash_next_slot
  have hm_lt : 2 * mask.bv.toNat < 2 ^ 32 := by
    have hbv := BitVec.toInt_eq_toNat_cond mask.bv
    split_ifs at hbv with hc
    · omega
    · change 0 ≤ mask.bv.toInt at hmask; omega
  have hm_val : mask.bv.toInt = (mask.bv.toNat : Int) := BitVec.toInt_eq_toNat_of_lt hm_lt
  have hle : ((Pion.I32.add slot 1#i32).bv &&& mask.bv).toNat ≤ mask.bv.toNat := by
    rw [BitVec.toNat_and]
    exact Nat.and_le_right
  have hnxt_lt : 2 * (Pion.I32.band (Pion.I32.add slot 1#i32) mask).bv.toNat < 2 ^ 32 := by
    change 2 * ((Pion.I32.add slot 1#i32).bv &&& mask.bv).toNat < 2 ^ 32
    omega
  have hnxt_val : (Pion.I32.band (Pion.I32.add slot 1#i32) mask).val =
      (((Pion.I32.add slot 1#i32).bv &&& mask.bv).toNat : Int) := by
    change ((Pion.I32.add slot 1#i32).bv &&& mask.bv).toInt = _
    exact BitVec.toInt_eq_toNat_of_lt hnxt_lt
  refine ⟨Pion.I32.band (Pion.I32.add slot 1#i32) mask, rfl, ?_, ?_⟩
  · omega
  · change (Pion.I32.band (Pion.I32.add slot 1#i32) mask).val ≤ mask.bv.toInt
    rw [hnxt_val, hm_val]
    omega

/-- Any valid RFC 6901 unescaped byte round-trips back to its exact escape suffix. -/
theorem pointer_unescape_roundtrip (next ch : Std.I32)
    (h : pointer_unescape_byte next = ok ch) (hvalid : 0 ≤ ch.val) :
    pointer_escape_suffix ch = ok next := by
  unfold pointer_unescape_byte at h
  simp only [Result.ok.injEq] at h
  split_ifs at h with h48 h49
  · subst h48; subst h; rfl
  · subst h49; subst h; rfl
  · subst h; exact absurd hvalid (by decide)

/-- `ascii_lut_flags` always fits in 7 bits (`[0, 127]`), guaranteeing lossless `Byte` storage. -/
theorem ascii_lut_flags_bounds (i : Std.I32) :
    ∃ f : Std.I32, ascii_lut_flags i = ok f ∧ 0 ≤ f.val ∧ f.val ≤ 127 := by
  unfold ascii_lut_flags
  set f1 : Std.I32 := if ((((((i == 9#i32) || (i == 10#i32)) || (i == 11#i32)) || (i == 12#i32)) || (i == 13#i32)) || (i == 32#i32)) then 1#i32 else 0#i32
  set f2 : Std.I32 := if ((((i == 9#i32) || (i == 10#i32)) || (i == 13#i32)) || (i == 32#i32)) then 2#i32 else 0#i32
  set f3 : Std.I32 := if (((((decide (i >= 65#i32)) && (decide (i <= 90#i32))) || ((decide (i >= 97#i32)) && (decide (i <= 122#i32)))) || (i == 95#i32)) || (i == 36#i32)) then 12#i32 else 0#i32
  set f4 : Std.I32 := if ((decide (i >= 48#i32)) && (decide (i <= 57#i32))) then 24#i32 else 0#i32
  set f5 : Std.I32 := if (((decide (i < 32#i32)) || (i == 34#i32)) || (i == 92#i32)) then 32#i32 else 0#i32
  set f6 : Std.I32 := if (((decide (i < 32#i32)) || (i == 39#i32)) || (i == 92#i32)) then 64#i32 else 0#i32
  have l1 : f1.bv.toNat < 2 ^ 7 := by dsimp [f1]; split_ifs <;> decide
  have l2 : f2.bv.toNat < 2 ^ 7 := by dsimp [f2]; split_ifs <;> decide
  have l3 : f3.bv.toNat < 2 ^ 7 := by dsimp [f3]; split_ifs <;> decide
  have l4 : f4.bv.toNat < 2 ^ 7 := by dsimp [f4]; split_ifs <;> decide
  have l5 : f5.bv.toNat < 2 ^ 7 := by dsimp [f5]; split_ifs <;> decide
  have l6 : f6.bv.toNat < 2 ^ 7 := by dsimp [f6]; split_ifs <;> decide
  have o1 : (Pion.I32.bor f1 f2).bv.toNat < 2 ^ 7 := by
    change (f1.bv ||| f2.bv).toNat < 2 ^ 7; rw [BitVec.toNat_or]; exact Nat.or_lt_two_pow l1 l2
  have o2 : (Pion.I32.bor (Pion.I32.bor f1 f2) f3).bv.toNat < 2 ^ 7 := by
    change ((Pion.I32.bor f1 f2).bv ||| f3.bv).toNat < 2 ^ 7; rw [BitVec.toNat_or]; exact Nat.or_lt_two_pow o1 l3
  have o3 : (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor f1 f2) f3) f4).bv.toNat < 2 ^ 7 := by
    change ((Pion.I32.bor (Pion.I32.bor f1 f2) f3).bv ||| f4.bv).toNat < 2 ^ 7; rw [BitVec.toNat_or]; exact Nat.or_lt_two_pow o2 l4
  have o4 : (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor f1 f2) f3) f4) f5).bv.toNat < 2 ^ 7 := by
    change ((Pion.I32.bor (Pion.I32.bor (Pion.I32.bor f1 f2) f3) f4).bv ||| f5.bv).toNat < 2 ^ 7; rw [BitVec.toNat_or]; exact Nat.or_lt_two_pow o3 l5
  have o5 : (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor f1 f2) f3) f4) f5) f6).bv.toNat < 2 ^ 7 := by
    change ((Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor f1 f2) f3) f4) f5).bv ||| f6.bv).toNat < 2 ^ 7
    rw [BitVec.toNat_or]; exact Nat.or_lt_two_pow o4 l6
  have hval : (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor f1 f2) f3) f4) f5) f6).val =
      ((Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor f1 f2) f3) f4) f5) f6).bv.toNat : Int) := by
    change (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.bor f1 f2) f3) f4) f5) f6).bv.toInt = _
    exact BitVec.toInt_eq_toNat_of_lt (by omega)
  exact ⟨_, rfl, by omega, by omega⟩

end Json5Proofs
