/-
Formal verification of `packages/time` (`Time.Funs`, extracted via
`pionc extract-lean` from `packages/time/src/*.pion`).

All proofs are complete and kernel-checked, depending only on the three
standard Lean axioms: `propext`, `Classical.choice`, `Quot.sound`.
-/
import Time.Funs

open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 400000
set_option linter.unusedSimpArgs false

namespace TimeProofs

open time

/-! ## 0. Scalar & Bitwise Bridge Lemmas -/

theorem b_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← (ok x : Result α); f y) = f x := by simp

theorem ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  have h1 : WP.spec (ok a) (fun x => x = a) := by simp
  rw [h, WP.spec_ok] at h1
  exact h1.symm

theorem ok_eq_iff {α : Type} {a b : α} : ((ok a : Result α) = ok b) ↔ a = b :=
  ⟨ok_inj, fun h => h ▸ rfl⟩

theorem i32_ext {a b : Std.I32} (h : a.val = b.val) : a = b := by
  cases a; cases b
  congr 1
  exact BitVec.eq_of_toInt_eq h

theorem i64_ext {a b : Std.I64} (h : a.val = b.val) : a = b := by
  cases a; cases b
  congr 1
  exact BitVec.eq_of_toInt_eq h

theorem i32_bounds (x : Std.I32) : -2147483648 ≤ x.val ∧ x.val ≤ 2147483647 := by
  have h1 := x.hBounds
  simp [IScalar.min, IScalar.max, IScalarTy.numBits] at h1
  omega

theorem i64_bounds (x : Std.I64) :
    -9223372036854775808 ≤ x.val ∧ x.val ≤ 9223372036854775807 := by
  have h1 := x.hBounds
  simp [IScalar.min, IScalar.max, IScalarTy.numBits] at h1
  omega

private theorem bmod_eq_self {z m : Int} (hm : 0 < m)
    (hlo : -(m / 2) ≤ z) (hhi : z < (m + 1) / 2) :
    z.bmod m.toNat = z := by
  have hmn : (m.toNat : Int) = m := Int.toNat_of_nonneg (by omega)
  rw [Int.bmod]
  have h1 : z % m = if 0 ≤ z then z else z + m := by
    split_ifs with hz
    · exact Int.emod_eq_of_lt hz (by omega)
    · have : (z + m) % m = z % m := Int.add_emod_right z m
      rw [← this]
      exact Int.emod_eq_of_lt (by omega) (by omega)
  rw [hmn, h1]
  split_ifs <;> omega

theorem i32_add_val (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val + y.val) (hhi : x.val + y.val ≤ 2147483647) :
    (Pion.I32.add x y).val = x.val + y.val := by
  simp only [IScalar.val] at hlo hhi ⊢
  simp only [Pion.I32.add, Std.I32.wrapping_add, IScalar.wrapping_add]
  rw [BitVec.toInt_add]
  exact bmod_eq_self (m := 4294967296) (by decide) hlo (by omega)

theorem i32_sub_val (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val - y.val) (hhi : x.val - y.val ≤ 2147483647) :
    (Pion.I32.sub x y).val = x.val - y.val := by
  simp only [IScalar.val] at hlo hhi ⊢
  simp only [Pion.I32.sub, Std.I32.wrapping_sub, IScalar.wrapping_sub]
  rw [BitVec.toInt_sub]
  exact bmod_eq_self (m := 4294967296) (by decide) hlo (by omega)

theorem i32_mul_val (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val * y.val) (hhi : x.val * y.val ≤ 2147483647) :
    (Pion.I32.mul x y).val = x.val * y.val := by
  simp only [IScalar.val] at hlo hhi ⊢
  simp only [Pion.I32.mul, Std.I32.wrapping_mul, IScalar.wrapping_mul]
  rw [BitVec.toInt_mul]
  exact bmod_eq_self (m := 4294967296) (by decide) hlo (by omega)

theorem i32_neg_val (x : Std.I32) (hne : x.val ≠ -2147483648) :
    (Pion.I32.neg x).val = -x.val := by
  have hb := i32_bounds x
  have hlo : -2147483648 ≤ -x.val := by omega
  have hhi : -x.val < 2147483648 := by omega
  simp only [IScalar.val] at hlo hhi ⊢
  simp only [Pion.I32.neg]
  rw [BitVec.toInt_neg]
  exact bmod_eq_self (m := 4294967296) (by decide) hlo hhi

theorem i64_add_val (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val + y.val) (hhi : x.val + y.val ≤ 9223372036854775807) :
    (Pion.I64.add x y).val = x.val + y.val := by
  simp only [IScalar.val] at hlo hhi ⊢
  simp only [Pion.I64.add, Std.I64.wrapping_add, IScalar.wrapping_add]
  rw [BitVec.toInt_add]
  exact bmod_eq_self (m := 18446744073709551616) (by decide) hlo (by omega)

theorem i64_sub_val (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val - y.val) (hhi : x.val - y.val ≤ 9223372036854775807) :
    (Pion.I64.sub x y).val = x.val - y.val := by
  simp only [IScalar.val] at hlo hhi ⊢
  simp only [Pion.I64.sub, Std.I64.wrapping_sub, IScalar.wrapping_sub]
  rw [BitVec.toInt_sub]
  exact bmod_eq_self (m := 18446744073709551616) (by decide) hlo (by omega)

theorem i64_mul_val (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val * y.val) (hhi : x.val * y.val ≤ 9223372036854775807) :
    (Pion.I64.mul x y).val = x.val * y.val := by
  simp only [IScalar.val] at hlo hhi ⊢
  simp only [Pion.I64.mul, Std.I64.wrapping_mul, IScalar.wrapping_mul]
  rw [BitVec.toInt_mul]
  exact bmod_eq_self (m := 18446744073709551616) (by decide) hlo (by omega)

theorem i64_neg_val (x : Std.I64) (hne : x.val ≠ -9223372036854775808) :
    (Pion.I64.neg x).val = -x.val := by
  have hb := i64_bounds x
  have hlo : -9223372036854775808 ≤ -x.val := by omega
  have hhi : -x.val < 9223372036854775808 := by omega
  simp only [IScalar.val] at hlo hhi ⊢
  simp only [Pion.I64.neg]
  rw [BitVec.toInt_neg]
  exact bmod_eq_self (m := 18446744073709551616) (by decide) hlo hhi

theorem i32_to_int64_val (x : Std.I32) : (Pion.I32.to_int64 x).val = x.val := by
  simp only [Pion.I32.to_int64, IScalar.cast, IScalar.val, IScalarTy.numBits]
  rw [BitVec.toInt_signExtend]
  simp

theorem i64_to_int_val (x : Std.I64)
    (hlo : -2147483648 ≤ x.val) (hhi : x.val ≤ 2147483647) :
    (Pion.I64.to_int x).val = x.val := by
  simp only [IScalar.val] at hlo hhi ⊢
  simp only [Pion.I64.to_int, IScalar.cast, IScalarTy.numBits]
  rw [BitVec.toInt_signExtend]
  simp only [Nat.min_eq_left (by decide : 32 ≤ 64)]
  exact bmod_eq_self (m := 4294967296) (by decide) hlo (by omega)

private theorem bv_and_mask_toInt {w : Nat} (x : BitVec w) (k : Nat) (hk : k < w) :
    (x &&& BitVec.ofNat w (2 ^ k - 1)).toInt = x.toInt % (2 ^ k : Int) := by
  have hpow : 2 ^ k ≤ 2 ^ (w - 1) := Nat.pow_le_pow_right (by omega) (by omega)
  have hpow_w : 2 ^ k ∣ 2 ^ w := Nat.pow_dvd_pow 2 (by omega)
  have hmod_lt : x.toNat % 2 ^ k < 2 ^ (w - 1) := lt_of_lt_of_le (Nat.mod_lt _ (by positivity)) hpow
  have hand_nat : (x &&& BitVec.ofNat w (2 ^ k - 1)).toNat = x.toNat % 2 ^ k := by
    rw [BitVec.toNat_and, BitVec.toNat_ofNat]
    have hlt : 2 ^ k - 1 < 2 ^ w := by
      have : 2 ^ k ≤ 2 ^ w := Nat.pow_le_pow_right (by omega) (by omega)
      omega
    rw [Nat.mod_eq_of_lt hlt, Nat.and_two_pow_sub_one_eq_mod]
  have hand_int : (x &&& BitVec.ofNat w (2 ^ k - 1)).toInt = (x.toNat % 2 ^ k : Int) := by
    rw [BitVec.toInt_eq_toNat_cond, hand_nat]
    have h2 : 2 * (x.toNat % 2 ^ k) < 2 ^ w := by
      have hw : 2 * 2 ^ (w - 1) = 2 ^ w := by
        cases w with
        | zero => omega
        | succ w' => simp [Nat.pow_succ, Nat.mul_comm]
      omega
    simp [h2]
  rw [hand_int, BitVec.toInt_eq_toNat_cond]
  split_ifs with hlt
  · norm_cast
  · have hdvd : ((2 ^ k : Nat) : Int) ∣ ((2 ^ w : Nat) : Int) := Int.ofNat_dvd.mpr hpow_w
    have hsub : ((x.toNat : Int) - (2 ^ w : Nat)) % (2 ^ k : Int) = (x.toNat : Int) % (2 ^ k : Int) := by
      obtain ⟨q, hq⟩ := hdvd
      have : (x.toNat : Int) - (2 ^ w : Nat) = (x.toNat : Int) + (2 ^ k : Int) * (-q) := by
        push_cast at hq ⊢; linarith
      rw [this, Int.add_mul_emod_self_left]
    rw [hsub]

theorem i32_band_3_val (x : Std.I32) : (Pion.I32.band x 3#i32).val = x.val % 4 := by
  have hm : (3#i32).bv = BitVec.ofNat IScalarTy.I32.numBits (2 ^ 2 - 1) := by decide
  have h := bv_and_mask_toInt (w := IScalarTy.I32.numBits) x.bv 2 (by decide)
  rw [← hm] at h
  exact h

theorem i32_band_15_val (x : Std.I32) : (Pion.I32.band x 15#i32).val = x.val % 16 := by
  have hm : (15#i32).bv = BitVec.ofNat IScalarTy.I32.numBits (2 ^ 4 - 1) := by decide
  have h := bv_and_mask_toInt (w := IScalarTy.I32.numBits) x.bv 4 (by decide)
  rw [← hm] at h
  exact h

theorem i32_band_65535_val (x : Std.I32) : (Pion.I32.band x 65535#i32).val = x.val % 65536 := by
  have hm : (65535#i32).bv = BitVec.ofNat IScalarTy.I32.numBits (2 ^ 16 - 1) := by decide
  have h := bv_and_mask_toInt (w := IScalarTy.I32.numBits) x.bv 16 (by decide)
  rw [← hm] at h
  exact h

theorem i64_band_u32max_val (x : Std.I64) :
    (Pion.I64.band x 4294967295#i64).val = x.val % 4294967296 := by
  have hm : (4294967295#i64).bv = BitVec.ofNat IScalarTy.I64.numBits (2 ^ 32 - 1) := by decide
  have h := bv_and_mask_toInt (w := IScalarTy.I64.numBits) x.bv 32 (by decide)
  rw [← hm] at h
  exact h

theorem i32_shl_2_val (x : Std.I32)
    (hlo : -2147483648 ≤ x.val * 4) (hhi : x.val * 4 ≤ 2147483647) :
    ∃ z : Std.I32, Pion.I32.shl x 2#i32 = ok z ∧ z.val = x.val * 4 := by
  unfold Pion.I32.shl
  have h2v : (2#i32).val = 2 := by decide
  simp only [h2v, show (0 : Int) ≤ 2 by decide, show (2 : Int) < 32 by decide, and_self, ↓reduceIte]
  refine ⟨_, rfl, ?_⟩
  have hhi' : x.val * 4 < 2147483648 := by omega
  simp only [IScalar.val] at hlo hhi' ⊢
  change (x.bv <<< 2).toInt = x.bv.toInt * 4
  have hsh : x.bv <<< 2 = x.bv * 4#32 := by
    rw [BitVec.shiftLeft_eq_mul_twoPow]; rfl
  rw [hsh, BitVec.toInt_mul]
  have h4 : (4#32 : BitVec 32).toInt = 4 := by decide
  rw [h4]
  exact bmod_eq_self (m := 4294967296) (by decide) hlo hhi'

theorem i32_shr_val (x k : Std.I32) (hk0 : 0 ≤ k.val) (hk : k.val < 32) :
    ∃ z : Std.I32, Pion.I32.shr x k = ok z ∧ z.val = x.val / (2 ^ k.val.toNat : Int) := by
  unfold Pion.I32.shr
  simp only [hk0, hk, and_self, ↓reduceIte]
  refine ⟨_, rfl, ?_⟩
  simp only [IScalar.val]
  rw [BitVec.toInt_sshiftRight, Int.shiftRight_eq_div_pow]
  norm_cast

theorem i64_shr_i32_val (x : Std.I64) (k : Std.I32) (hk0 : 0 ≤ k.val) (hk : k.val < 64) :
    ∃ z : Std.I64, Pion.I64.shr_i32 x k = ok z ∧ z.val = x.val / (2 ^ k.val.toNat : Int) := by
  unfold Pion.I64.shr_i32
  simp only [hk0, hk, and_self, ↓reduceIte]
  refine ⟨_, rfl, ?_⟩
  simp only [IScalar.val]
  rw [BitVec.toInt_sshiftRight, Int.shiftRight_eq_div_pow]
  norm_cast

theorem i32_div_ok (x y : Std.I32) (hnz : y.val ≠ 0)
    (hno : ¬ (x.val = -2147483648 ∧ y.val = -1)) :
    ∃ z : Std.I32, Pion.I32.div x y = ok z ∧ z.val = Int.tdiv x.val y.val := by
  have hsp := Pion.I32.div_spec hnz hno
  have heq : Pion.I32.div x y = ok ⟨BitVec.sdiv x.bv y.bv⟩ := by
    unfold Pion.I32.div
    change IScalar.div x y = _
    unfold IScalar.div
    simp [Std.I32.min_eq, hnz, hno]
  rw [heq, WP.spec_ok] at hsp
  exact ⟨_, heq, hsp⟩

theorem i32_rem_ok (x y : Std.I32) (hnz : y.val ≠ 0)
    (hno : ¬ (x.val = -2147483648 ∧ y.val = -1)) :
    ∃ z : Std.I32, Pion.I32.rem x y = ok z ∧ z.val = Int.tmod x.val y.val := by
  have hsp := Pion.I32.rem_spec hnz hno
  have heq : Pion.I32.rem x y = ok ⟨BitVec.srem x.bv y.bv⟩ := by
    unfold Pion.I32.rem
    simp only [hno, ↓reduceIte]
    change IScalar.rem x y = _
    unfold IScalar.rem
    simp [hnz]
  rw [heq, WP.spec_ok] at hsp
  exact ⟨_, heq, hsp⟩


end TimeProofs
