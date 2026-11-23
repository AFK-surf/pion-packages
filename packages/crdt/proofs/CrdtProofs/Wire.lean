import CrdtProofs.Core

open Aeneas Aeneas.Std Result Pion crdt

namespace CrdtProofs

private lemma i32_eq_of_bv (a b : Std.I32) (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

private lemma i32_bor_bv (a b : Std.I32) : (Pion.I32.bor a b).bv = a.bv ||| b.bv := rfl
private lemma i32_band_bv (a b : Std.I32) : (Pion.I32.band a b).bv = a.bv &&& b.bv := rfl

private lemma i32_mask_31_of_range (r : Std.I32) (h0 : 0 ≤ r.val) (h32 : r.val < 32) :
    (Pion.I32.band r 31#i32).bv = r.bv := by
  rw [i32_band_bv]
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_and]
  have h31 : (31#i32).bv.toNat = 31 := by decide
  rw [h31]
  have hr_nat : r.bv.toNat = r.val.toNat := by
    have hti := BitVec.toInt_eq_toNat_cond r.bv
    have hlt : 2 * r.bv.toNat < 2 ^ 32 := by
      by_contra hge; push Not at hge
      rw [ite_eq_right (by omega)] at hti
      change r.bv.toInt ≥ 0 at h0
      omega
    rw [ite_eq_left hlt] at hti
    change r.bv.toNat = r.bv.toInt.toNat
    omega
  have hlt32 : r.bv.toNat < 32 := by omega
  have hmod : r.bv.toNat &&& 31 = r.bv.toNat % 32 := by
    have : (31 : Nat) = 2 ^ 5 - 1 := by norm_num
    rw [this, Nat.and_two_pow_sub_one_eq_mod]
  rw [hmod, Nat.mod_eq_of_lt hlt32]

private lemma bv_and_or_distrib (x y z : BitVec IScalarTy.I32.numBits) :
    (x ||| y) &&& z = (x &&& z) ||| (y &&& z) := by
  ext i; simp [Bool.and_or_distrib_right]

private lemma bv_and_31_128 : (128#i32).bv &&& (31#i32).bv = 0#32 := by decide
private lemma bv_and_31_64 : (64#i32).bv &&& (31#i32).bv = 0#32 := by decide
private lemma bv_and_31_32 : (32#i32).bv &&& (31#i32).bv = 0#32 := by decide
private lemma bv_and_31_0 : (0#i32).bv &&& (31#i32).bv = 0#32 := by decide
private lemma bv_and_31_128' : (31#i32).bv &&& (128#i32).bv = 0#32 := by decide
private lemma bv_and_31_64' : (31#i32).bv &&& (64#i32).bv = 0#32 := by decide
private lemma bv_and_31_32' : (31#i32).bv &&& (32#i32).bv = 0#32 := by decide

/-- Yjs v1 wire info byte roundtrip for the 5-bit `ref_id` (`0..=31`). -/
theorem encode_item_info_ref_id (ref_id : Std.I32) (ho hr hp : Bool)
    (h0 : 0 ≤ ref_id.val) (h32 : ref_id.val < 32) :
    (do let b ← encode_item_info ref_id ho hr hp; info_ref_id b) = ok ref_id := by
  unfold encode_item_info info_ref_id
  rw [result_bind_ok]
  congr 1
  apply i32_eq_of_bv
  have hmask := i32_mask_31_of_range ref_id h0 h32
  rw [i32_band_bv] at hmask
  simp only [i32_band_bv, i32_bor_bv]
  rw [bv_and_or_distrib, bv_and_or_distrib, bv_and_or_distrib, hmask, hmask]
  cases ho <;> cases hr <;> cases hp <;>
    simp only [↓reduceIte, Bool.false_eq_true, bv_and_31_128, bv_and_31_64, bv_and_31_32, bv_and_31_0,
      BitVec.or_zero]

/-- `encode_item_info` always produces an unsigned byte in `[0, 255]`. -/
theorem encode_item_info_bounds (ref_id : Std.I32) (ho hr hp : Bool) :
    ∃ b : Std.I32, encode_item_info ref_id ho hr hp = ok b ∧ 0 ≤ b.val ∧ b.val < 256 := by
  unfold encode_item_info
  refine ⟨_, rfl, ?_⟩
  set b : Std.I32 := Pion.I32.bor (Pion.I32.bor (Pion.I32.bor (Pion.I32.band ref_id 31#i32)
    (if ho then 128#i32 else 0#i32)) (if hr then 64#i32 else 0#i32)) (if hp then 32#i32 else 0#i32)
  have hlow : b.bv.toNat < 256 := by
    have h1 : (Pion.I32.band ref_id 31#i32).bv.toNat < 32 := by
      rw [i32_band_bv, BitVec.toNat_and]
      have h31 : (31#i32).bv.toNat = 31 := by decide
      rw [h31]
      have hmod : ref_id.bv.toNat &&& 31 = ref_id.bv.toNat % 32 := by
        have : (31 : Nat) = 2 ^ 5 - 1 := by norm_num
        rw [this, Nat.and_two_pow_sub_one_eq_mod]
      rw [hmod]; exact Nat.mod_lt _ (by omega)
    have h_or : ∀ (x y : BitVec IScalarTy.I32.numBits), x.toNat < 256 → y.toNat < 256 → (x ||| y).toNat < 256 := by
      intro x y hx hy
      rw [BitVec.toNat_or]
      exact Nat.or_lt_two_pow (n := 8) hx hy
    have hho : (if ho then 128#i32 else 0#i32).bv.toNat < 256 := by cases ho <;> decide
    have hhr : (if hr then 64#i32 else 0#i32).bv.toNat < 256 := by cases hr <;> decide
    have hhp : (if hp then 32#i32 else 0#i32).bv.toNat < 256 := by cases hp <;> decide
    exact h_or _ _ (h_or _ _ (h_or _ _ (by omega) hho) hhr) hhp
  have hval : b.val = (b.bv.toNat : Int) := by
    change b.bv.toInt = (b.bv.toNat : Int)
    rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
  omega

/-- lib0 hex nibble roundtrip: `parse_hex_nibble (hex_nibble_char n) = ok n` for every `0 ≤ n < 16`. -/
theorem hex_nibble_roundtrip (n : Std.I32) (h0 : 0 ≤ n.val) (h16 : n.val < 16) :
    (do let c ← hex_nibble_char n; parse_hex_nibble c) = ok n := by
  unfold hex_nibble_char parse_hex_nibble
  rw [result_bind_ok]
  congr 1
  by_cases hlt : n < 10#i32
  · simp only [hlt, ↓reduceIte]
    rw [iscalar_lt_iff] at hlt
    have h10 : (10#i32).val = 10 := by norm_num
    have h48 : (48#i32).val = 48 := by norm_num
    have hadd := i32_add_val 48#i32 n (by omega) (by omega)
    have hc1 : ((decide (Pion.I32.add 48#i32 n ≥ 48#i32)) && (decide (Pion.I32.add 48#i32 n ≤ 57#i32))) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff, hadd, h48]
      have h57 : (57#i32).val = 57 := by norm_num
      omega
    simp only [hc1, ↓reduceIte]
    apply (iscalar_eq_iff _ _).mpr
    have hsub := i32_sub_val (Pion.I32.add 48#i32 n) 48#i32 (by omega) (by omega)
    omega
  · simp only [hlt, ↓reduceIte]
    rw [iscalar_lt_iff] at hlt
    have h10 : (10#i32).val = 10 := by norm_num
    have h87 : (87#i32).val = 87 := by norm_num
    have hadd := i32_add_val 87#i32 n (by omega) (by omega)
    have hc1 : ((decide (Pion.I32.add 87#i32 n ≥ 48#i32)) && (decide (Pion.I32.add 87#i32 n ≤ 57#i32))) = false := by
      simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, iscalar_le_iff, hadd, h87]
      have h57 : (57#i32).val = 57 := by norm_num
      omega
    have hc2 : ((decide (Pion.I32.add 87#i32 n ≥ 97#i32)) && (decide (Pion.I32.add 87#i32 n ≤ 102#i32))) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff, hadd, h87]
      have h97 : (97#i32).val = 97 := by norm_num
      have h102 : (102#i32).val = 102 := by norm_num
      omega
    simp only [hc1, hc2, Bool.false_eq_true, ↓reduceIte]
    apply (iscalar_eq_iff _ _).mpr
    have hsub := i32_sub_val (Pion.I32.add 87#i32 n) 87#i32 (by omega) (by omega)
    omega

/-- `parse_hex_nibble` always returns `-1` (invalid) or a nibble in `[0, 15]`. -/
theorem parse_hex_nibble_range (c : Std.I32) :
    ∃ r : Std.I32, parse_hex_nibble c = ok r ∧ (r = (-1)#i32 ∨ (0 ≤ r.val ∧ r.val < 16)) := by
  unfold parse_hex_nibble
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

end CrdtProofs
