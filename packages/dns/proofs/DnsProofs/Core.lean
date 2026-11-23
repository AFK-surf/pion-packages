import Aeneas
import PionLean
import Dns.Types
import Dns.Funs

open Aeneas Aeneas.Std Result Pion dns

namespace DnsProofs

lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

lemma iscalar_eq_iff {ty : IScalarTy} (a b : IScalar ty) :
    a = b ↔ a.val = b.val := by
  constructor
  · intro h; subst h; rfl
  · intro h; cases a; cases b; congr; exact BitVec.eq_of_toInt_eq h

lemma iscalar_le_iff {ty : IScalarTy} (a b : IScalar ty) :
    a ≤ b ↔ a.val ≤ b.val := Iff.rfl

lemma i32_eq_of_bv (a b : Std.I32) (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

lemma i32_bor_bv (a b : Std.I32) : (Pion.I32.bor a b).bv = a.bv ||| b.bv := rfl
lemma i32_band_bv (a b : Std.I32) : (Pion.I32.band a b).bv = a.bv &&& b.bv := rfl
lemma i64_bor_bv (a b : Std.I64) : (Pion.I64.bor a b).bv = a.bv ||| b.bv := rfl
lemma i64_band_bv (a b : Std.I64) : (Pion.I64.band a b).bv = a.bv &&& b.bv := rfl

lemma i32_add_val (a b : Std.I32) (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  unfold Pion.I32.add
  have ha : a.bv.toInt = a.val := rfl
  have hb : b.bv.toInt = b.val := rfl
  change (a.bv + b.bv).toInt = a.bv.toInt + b.bv.toInt
  rw [BitVec.toInt_add, Int.bmod_eq_of_le] <;> omega

lemma i32_sub_val (a b : Std.I32) (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  unfold Pion.I32.sub
  have ha : a.bv.toInt = a.val := rfl
  have hb : b.bv.toInt = b.val := rfl
  change (a.bv - b.bv).toInt = a.bv.toInt - b.bv.toInt
  rw [BitVec.toInt_sub, Int.bmod_eq_of_le] <;> omega

lemma i32_band_255_bounds (x : Std.I32) :
    0 ≤ (Pion.I32.band x 255#i32).val ∧ (Pion.I32.band x 255#i32).val ≤ 255 := by
  have hlt : (Pion.I32.band x 255#i32).bv.toNat < 256 := by
    rw [i32_band_bv, BitVec.toNat_and]
    have h255 : (255#i32).bv.toNat = 255 := by decide
    rw [h255]
    have hmod : x.bv.toNat &&& 255 = x.bv.toNat % 256 := by
      have : (255 : Nat) = 2 ^ 8 - 1 := by norm_num
      rw [this, Nat.and_two_pow_sub_one_eq_mod]
    rw [hmod]; exact Nat.mod_lt _ (by omega)
  have hval : (Pion.I32.band x 255#i32).val = ((Pion.I32.band x 255#i32).bv.toNat : Int) := by
    change (Pion.I32.band x 255#i32).bv.toInt = _
    rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
  omega

/-- `is_u32` holds iff `0 ≤ v ≤ 4294967295`. -/
lemma is_u32_iff (v : Std.I64) :
    is_u32 v = ok true ↔ 0 ≤ v.val ∧ v.val ≤ 4294967295 := by
  unfold is_u32
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff]
  have h0 : (0#i64).val = 0 := by norm_num
  have hmax : (4294967295#i64).val = 4294967295 := by norm_num
  omega

/-- RFC 4343 `ascii_lower_byte` is idempotent on every `Int32`. -/
theorem ascii_lower_byte_idempotent (b : Std.I32) :
    (do let x ← ascii_lower_byte b; ascii_lower_byte x) = ascii_lower_byte b := by
  unfold ascii_lower_byte
  rw [result_bind_ok]
  congr 1
  by_cases h : ((decide (b ≥ 65#i32)) && (decide (b ≤ 90#i32))) = true
  · simp only [h, ↓reduceIte]
    simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff] at h
    have h65 : (65#i32).val = 65 := by norm_num
    have h90 : (90#i32).val = 90 := by norm_num
    have h32 : (32#i32).val = 32 := by norm_num
    have hadd := i32_add_val b 32#i32 (by omega) (by omega)
    have h2 : ((decide (Pion.I32.add b 32#i32 ≥ 65#i32)) && (decide (Pion.I32.add b 32#i32 ≤ 90#i32))) = false := by
      simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, iscalar_le_iff, hadd]; omega
    simp only [h2, Bool.false_eq_true, ↓reduceIte]
  · have hf : ((decide (b ≥ 65#i32)) && (decide (b ≤ 90#i32))) = false := Bool.eq_false_iff.mpr h
    simp only [hf, Bool.false_eq_true, ↓reduceIte]

/-- `hex_val` always returns `-1` (invalid) or a nibble in `[0, 15]`. -/
theorem hex_val_range (c : Std.I32) :
    ∃ r : Std.I32, hex_val c = ok r ∧ (r = (-1)#i32 ∨ (0 ≤ r.val ∧ r.val < 16)) := by
  unfold hex_val
  refine ⟨_, rfl, ?_⟩
  split_ifs with h1 h2 h3
  · right
    simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff] at h1
    have h48 : (48#i32).val = 48 := by norm_num
    have h57 : (57#i32).val = 57 := by norm_num
    have hsub := i32_sub_val c 48#i32 (by omega) (by omega)
    omega
  · right
    simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff] at h2
    have h97 : (97#i32).val = 97 := by norm_num
    have h102 : (102#i32).val = 102 := by norm_num
    have h87 : (87#i32).val = 87 := by norm_num
    have hsub := i32_sub_val c 87#i32 (by omega) (by omega)
    omega
  · right
    simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff] at h3
    have h65 : (65#i32).val = 65 := by norm_num
    have h70 : (70#i32).val = 70 := by norm_num
    have h55 : (55#i32).val = 55 := by norm_num
    have hsub := i32_sub_val c 55#i32 (by omega) (by omega)
    omega
  · left; rfl

/-- RFC 4648 §5 / RFC 8484 `b64url_val` always returns `-1` (invalid) or a 6-bit value in `[0, 63]`. -/
theorem b64url_val_range (c : Std.I32) :
    ∃ r : Std.I32, b64url_val c = ok r ∧ (r = (-1)#i32 ∨ (0 ≤ r.val ∧ r.val < 64)) := by
  unfold b64url_val
  refine ⟨_, rfl, ?_⟩
  split_ifs with h1 h2 h3 h4 h5
  · right
    simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff] at h1
    have h65 : (65#i32).val = 65 := by norm_num
    have h90 : (90#i32).val = 90 := by norm_num
    have hsub := i32_sub_val c 65#i32 (by omega) (by omega)
    omega
  · right
    simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff] at h2
    have h97 : (97#i32).val = 97 := by norm_num
    have h122 : (122#i32).val = 122 := by norm_num
    have h71 : (71#i32).val = 71 := by norm_num
    have hsub := i32_sub_val c 71#i32 (by omega) (by omega)
    omega
  · right
    simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff] at h3
    have h48 : (48#i32).val = 48 := by norm_num
    have h57 : (57#i32).val = 57 := by norm_num
    have h4 : (4#i32).val = 4 := by norm_num
    have hadd := i32_add_val c 4#i32 (by omega) (by omega)
    omega
  · right; norm_num
  · right; norm_num
  · left; rfl

end DnsProofs
