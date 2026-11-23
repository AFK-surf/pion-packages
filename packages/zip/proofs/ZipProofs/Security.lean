import Aeneas
import PionLean
import Zip.Types
import Zip.Funs

open Aeneas Aeneas.Std Result Pion zip

namespace ZipProofs

@[simp]
lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

lemma iscalar_eq_of_bv_eq {ty} {a b : IScalar ty} (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

lemma iscalar_eq_of_val_eq {ty} {a b : IScalar ty} (h : a.val = b.val) : a = b :=
  iscalar_eq_of_bv_eq (BitVec.eq_of_toInt_eq h)

lemma i32_mk_bv (x : BitVec 32) : (⟨x⟩ : I32).bv = x := rfl

lemma u32_mk_bv (x : BitVec 32) : (⟨x⟩ : U32).bv = x := rfl

lemma i32_band_bv (a b : I32) : (Pion.I32.band a b).bv = a.bv &&& b.bv := rfl

lemma i32_bor_bv (a b : I32) : (Pion.I32.bor a b).bv = a.bv ||| b.bv := rfl

lemma u32_band_bv (a b : U32) : (Pion.U32.band a b).bv = a.bv &&& b.bv := rfl

lemma i32_shl_ok (x : I32) (s : I32) (hs0 : 0 ≤ s.val) (hs1 : s.val < 32) :
    Pion.I32.shl x s = ok (⟨x.bv <<< s.val.toNat⟩ : I32) := by
  unfold Pion.I32.shl
  simp [hs0, hs1]

lemma i32_shr_ok (x : I32) (s : I32) (hs0 : 0 ≤ s.val) (hs1 : s.val < 32) :
    Pion.I32.shr x s = ok (⟨x.bv.sshiftRight s.val.toNat⟩ : I32) := by
  unfold Pion.I32.shr
  simp [hs0, hs1]

lemma u32_shr_ok (x : U32) (s : U32) (hs : s.val < 32) :
    Pion.U32.shr x s = ok (⟨x.bv >>> s.val⟩ : U32) := by
  unfold Pion.U32.shr
  simp [hs]

lemma i32_val_nonneg_toNat (x : I32) (hx : 0 ≤ x.val) :
    x.bv.toNat = x.val.toNat := by
  have h1 : x.val = x.bv.toInt := rfl
  have h2 : x.bv.toInt = if 2 * x.bv.toNat < 2 ^ 32 then (x.bv.toNat : Int) else (x.bv.toNat : Int) - 2 ^ 32 := by
    rw [BitVec.toInt_eq_toNat_cond]; rfl
  have hlt : x.bv.toNat < 2 ^ 32 := x.bv.isLt
  omega

lemma i32_add_val_of_bounds (a b : I32)
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  have h1 : (Pion.I32.add a b).val = (a.bv + b.bv).toInt := rfl
  rw [h1, BitVec.toInt_add]
  have ha : a.bv.toInt = a.val := rfl
  have hb : b.bv.toInt = b.val := rfl
  rw [ha, hb]
  by_cases h0 : 0 ≤ a.val + b.val
  · have hm : (a.val + b.val) % ((2 ^ 32 : Nat) : Int) = a.val + b.val :=
      Int.emod_eq_of_lt h0 (by omega)
    simp only [Int.bmod, hm]; split <;> omega
  · have hm : (a.val + b.val) % ((2 ^ 32 : Nat) : Int) = a.val + b.val + ((2 ^ 32 : Nat) : Int) := by
      have h' : (a.val + b.val + ((2 ^ 32 : Nat) : Int)) % ((2 ^ 32 : Nat) : Int) =
          a.val + b.val + ((2 ^ 32 : Nat) : Int) :=
        Int.emod_eq_of_lt (by omega) (by omega)
      simpa [Int.add_emod_right] using h'
    simp only [Int.bmod, hm]; split <;> omega

lemma i32_sub_val_of_bounds (a b : I32)
    (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  have h1 : (Pion.I32.sub a b).val = (a.bv - b.bv).toInt := rfl
  rw [h1, BitVec.toInt_sub]
  have ha : a.bv.toInt = a.val := rfl
  have hb : b.bv.toInt = b.val := rfl
  rw [ha, hb]
  by_cases h0 : 0 ≤ a.val - b.val
  · have hm : (a.val - b.val) % ((2 ^ 32 : Nat) : Int) = a.val - b.val :=
      Int.emod_eq_of_lt h0 (by omega)
    simp only [Int.bmod, hm]; split <;> omega
  · have hm : (a.val - b.val) % ((2 ^ 32 : Nat) : Int) = a.val - b.val + ((2 ^ 32 : Nat) : Int) := by
      have h' : (a.val - b.val + ((2 ^ 32 : Nat) : Int)) % ((2 ^ 32 : Nat) : Int) =
          a.val - b.val + ((2 ^ 32 : Nat) : Int) :=
        Int.emod_eq_of_lt (by omega) (by omega)
      simpa [Int.add_emod_right] using h'
    simp only [Int.bmod, hm]; split <;> omega

lemma i64_sub_val_of_bounds (a b : I64)
    (hlo : -9223372036854775808 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 9223372036854775807) :
    (Pion.I64.sub a b).val = a.val - b.val := by
  have h1 : (Pion.I64.sub a b).val = (a.bv - b.bv).toInt := rfl
  rw [h1, BitVec.toInt_sub]
  have ha : a.bv.toInt = a.val := rfl
  have hb : b.bv.toInt = b.val := rfl
  rw [ha, hb]
  by_cases h0 : 0 ≤ a.val - b.val
  · have hm : (a.val - b.val) % ((2 ^ 64 : Nat) : Int) = a.val - b.val :=
      Int.emod_eq_of_lt h0 (by omega)
    simp only [Int.bmod, hm]; split <;> omega
  · have hm : (a.val - b.val) % ((2 ^ 64 : Nat) : Int) = a.val - b.val + ((2 ^ 64 : Nat) : Int) := by
      have h' : (a.val - b.val + ((2 ^ 64 : Nat) : Int)) % ((2 ^ 64 : Nat) : Int) =
          a.val - b.val + ((2 ^ 64 : Nat) : Int) :=
        Int.emod_eq_of_lt (by omega) (by omega)
      simpa [Int.add_emod_right] using h'
    simp only [Int.bmod, hm]; split <;> omega

lemma bv32_getElem_high_false (x : I32) (hx0 : 0 ≤ x.val) {k : Nat} (hx : x.val < ((2 ^ k : Nat) : Int))
    (i : Nat) (hi : i < 32) (hki : k ≤ i) : x.bv[i] = false := by
  rw [BitVec.getElem_eq_testBit_toNat, i32_val_nonneg_toNat x hx0]
  apply Nat.testBit_lt_two_pow
  have hlt : x.val.toNat < 2 ^ k := by omega
  exact Nat.lt_of_lt_of_le hlt (Nat.pow_le_pow_right (by omega) hki)

/-- Theorem 1: `in_range64` is exact overflow-free mathematical range inclusion `0 ≤ off, size, limit ∧ off + size ≤ limit`. -/
theorem in_range64_iff (off size limit : I64) :
    in_range64 off size limit = ok true ↔
      0 ≤ off.val ∧ 0 ≤ size.val ∧ 0 ≤ limit.val ∧ off.val + size.val ≤ limit.val := by
  unfold in_range64
  have hlim_hi : limit.val ≤ 9223372036854775807 := by
    have h := limit.hBounds.2; change limit.val < 2 ^ 63 at h; omega
  constructor
  · intro h
    have ht := result_ok_inj h
    simp only [Bool.and_eq_true, decide_eq_true_eq] at ht
    rcases ht with ⟨⟨⟨⟨hoff, hsize⟩, hlim⟩, hle⟩, hoff_le⟩
    have hoff' : 0 ≤ off.val := hoff
    have hsize' : 0 ≤ size.val := hsize
    have hlim' : 0 ≤ limit.val := hlim
    have hle' : size.val ≤ limit.val := hle
    have hsub := i64_sub_val_of_bounds limit size (by omega) (by omega)
    have hoff_le' : off.val ≤ (Pion.I64.sub limit size).val := hoff_le
    omega
  · intro ⟨hoff, hsize, hlim, hsum⟩
    have h1 : (0#i64 : I64) ≤ off := hoff
    have h2 : (0#i64 : I64) ≤ size := hsize
    have h3 : (0#i64 : I64) ≤ limit := hlim
    have h4 : size ≤ limit := by change size.val ≤ limit.val; omega
    have hsub := i64_sub_val_of_bounds limit size (by omega) (by omega)
    have h5 : off ≤ Pion.I64.sub limit size := show off.val ≤ (Pion.I64.sub limit size).val by omega
    simp only [h1, h2, h3, h4, h5, decide_true, Bool.and_self]

/-- Theorem 4: `ascii_upper` is idempotent on all bytes `0..255`. -/
theorem ascii_upper_idempotent (c : I32) (hlo : 0 ≤ c.val) (hhi : c.val ≤ 255) :
    (do let y ← ascii_upper c; ascii_upper y) = ascii_upper c := by
  unfold ascii_upper
  have c32 : (32#i32 : I32).val = 32 := rfl
  by_cases hl : 97 ≤ c.val ∧ c.val ≤ 122
  · have h1 : (97#i32 : I32) ≤ c := hl.1
    have h2 : c ≤ (122#i32 : I32) := hl.2
    simp only [h1, h2, decide_true, Bool.and_self, ↓reduceIte, result_bind_ok]
    have hs := i32_sub_val_of_bounds c 32#i32 (by omega) (by omega)
    have hnot : ¬((97#i32 : I32) ≤ Pion.I32.sub c 32#i32) := show ¬((97 : Int) ≤ (Pion.I32.sub c 32#i32).val) by omega
    simp only [hnot, decide_false, Bool.false_and, Bool.false_eq_true, ↓reduceIte]
  · have hfl : (decide (c ≥ 97#i32) && decide (c ≤ 122#i32)) = false := by
      rw [Bool.and_eq_false_iff]; by_cases ha : 97 ≤ c.val
      · right; rw [decide_eq_false_iff_not]; change ¬(c.val ≤ 122); omega
      · left; rw [decide_eq_false_iff_not]; change ¬(97 ≤ c.val); omega
    simp only [hfl, Bool.false_eq_true, ↓reduceIte, result_bind_ok]

end ZipProofs
