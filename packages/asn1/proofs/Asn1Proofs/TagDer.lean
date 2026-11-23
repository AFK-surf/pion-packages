import Aeneas
import PionLean
import Asn1.Types
import Asn1.Funs

open Aeneas Aeneas.Std Result Pion asn1

namespace Asn1Proofs

@[simp]
theorem result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

theorem result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

theorem iscalar_eq_of_bv_eq {ty} {a b : IScalar ty} (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

theorem iscalar_eq_of_val_eq {ty} {a b : IScalar ty} (h : a.val = b.val) : a = b :=
  iscalar_eq_of_bv_eq (BitVec.eq_of_toInt_eq h)

theorem i32_mk_bv (x : BitVec 32) : (⟨x⟩ : I32).bv = x := rfl

theorem i32_band_bv (a b : I32) : (Pion.I32.band a b).bv = a.bv &&& b.bv := rfl

theorem i32_bor_bv (a b : I32) : (Pion.I32.bor a b).bv = a.bv ||| b.bv := rfl

theorem i32_shl_ok (x : I32) (s : I32) (hs0 : 0 ≤ s.val) (hs1 : s.val < 32) :
    Pion.I32.shl x s = ok (⟨x.bv <<< s.val.toNat⟩ : I32) := by
  unfold Pion.I32.shl
  simp [hs0, hs1]

theorem i32_shr_ok (x : I32) (s : I32) (hs0 : 0 ≤ s.val) (hs1 : s.val < 32) :
    Pion.I32.shr x s = ok (⟨x.bv.sshiftRight s.val.toNat⟩ : I32) := by
  unfold Pion.I32.shr
  simp [hs0, hs1]

theorem i32_val_nonneg_toNat (x : I32) (hx : 0 ≤ x.val) :
    x.bv.toNat = x.val.toNat := by
  have h1 : x.val = x.bv.toInt := rfl
  have h2 : x.bv.toInt = if 2 * x.bv.toNat < 2 ^ 32 then (x.bv.toNat : Int) else (x.bv.toNat : Int) - 2 ^ 32 := by
    rw [BitVec.toInt_eq_toNat_cond]; rfl
  have hlt : x.bv.toNat < 2 ^ 32 := x.bv.isLt
  omega

theorem i32_add_val_of_bounds (a b : I32)
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

theorem bv32_getElem_high_false (x : I32) (hx0 : 0 ≤ x.val) {k : Nat} (hx : x.val < ((2 ^ k : Nat) : Int))
    (i : Nat) (hi : i < 32) (hki : k ≤ i) : x.bv[i] = false := by
  rw [BitVec.getElem_eq_testBit_toNat, i32_val_nonneg_toNat x hx0]
  apply Nat.testBit_lt_two_pow
  have hlt : x.val.toNat < 2 ^ k := by omega
  exact Nat.lt_of_lt_of_le hlt (Nat.pow_le_pow_right (by omega) hki)

/-- Theorem 1: `tag_class_from_code ∘ tag_class_code = id` on all 4 X.690 tag classes. -/
theorem tag_class_roundtrip (c : TagClass) :
    (do let k ← tag_class_code c; tag_class_from_code k) = ok c := by
  cases c <;> simp [tag_class_code, tag_class_from_code]

/-- Theorem 2: `tag_class_equals` is exact decidable equality on `TagClass`. -/
theorem tag_class_equals_iff (a b : TagClass) :
    tag_class_equals a b = ok true ↔ a = b := by
  cases a <;> cases b <;> simp [tag_class_equals, tag_class_code]

/-- Theorem 3: `Tag.equals` is exact decidable equality on `Tag`. -/
theorem tag_equals_iff (a b : Tag) :
    Tag.equals a b = ok true ↔ a = b := by
  rcases a with ⟨ca, fa, na⟩
  rcases b with ⟨cb, fb, nb⟩
  unfold Tag.equals
  constructor
  · intro h
    by_cases hnf : ((na == nb) && (fa == fb)) = true
    · simp only [hnf, ↓reduceIte] at h
      simp only [Bool.and_eq_true, beq_iff_eq] at hnf
      rcases hnf with ⟨rfl, rfl⟩
      have hc : ca = cb := by
        cases ca <;> cases cb <;> simp [tag_class_code] at h ⊢
      subst hc; rfl
    · simp only [hnf] at h
      exact absurd (result_ok_inj h) (by decide)
  · intro h
    cases h
    cases ca <;> simp [tag_class_code]

private lemma band_31_range (x : I32) :
    0 ≤ (Pion.I32.band x 31#i32).val ∧ (Pion.I32.band x 31#i32).val ≤ 31 := by
  have hval : (Pion.I32.band x 31#i32).val = (Pion.I32.band x 31#i32).bv.toInt := rfl
  have htoNat : (Pion.I32.band x 31#i32).bv.toNat ≤ 31 := by
    rw [i32_band_bv, BitVec.toNat_and]
    have : (31#i32).bv.toNat = 31 := by decide
    rw [this]; exact Nat.and_le_right
  have h2 : (Pion.I32.band x 31#i32).bv.toInt =
      if 2 * (Pion.I32.band x 31#i32).bv.toNat < 2 ^ 32 then ((Pion.I32.band x 31#i32).bv.toNat : Int)
      else ((Pion.I32.band x 31#i32).bv.toNat : Int) - 2 ^ 32 := by
    rw [BitVec.toInt_eq_toNat_cond]; rfl
  omega

/-- Theorem 4: X.690 §8.1.2 `encode_tag_first_byte` always produces a valid wire byte in `[0, 255]`. -/
theorem encode_tag_first_byte_range (cls : TagClass) (constructed : Bool) (num : I32) :
    ∃ b, encode_tag_first_byte cls constructed num = ok b ∧ 0 ≤ b.val ∧ b.val ≤ 255 := by
  unfold encode_tag_first_byte
  cases cls <;> cases constructed <;>
    (simp only [tag_class_code, result_bind_ok, ↓reduceIte, Bool.false_eq_true]
     rw [i32_shl_ok _ 6#i32 (by decide) (by decide), result_bind_ok]
     refine ⟨_, rfl, ?_⟩
     have hval : ∀ z : I32, z.bv.toNat ≤ 255 → 0 ≤ z.val ∧ z.val ≤ 255 := by
       intro z hz
       have hv : z.val = z.bv.toInt := rfl
       have h2 : z.bv.toInt = if 2 * z.bv.toNat < 2 ^ 32 then (z.bv.toNat : Int) else (z.bv.toNat : Int) - 2 ^ 32 := by
         rw [BitVec.toInt_eq_toNat_cond]; rfl
       omega
     apply hval
     rw [i32_bor_bv, BitVec.toNat_or]
     have hlow : (if num < 31#i32 then Pion.I32.band num 31#i32 else 31#i32).bv.toNat < 256 := by
       split
       · rw [i32_band_bv, BitVec.toNat_and]
         have : (31#i32).bv.toNat = 31 := by decide
         rw [this]
         have := Nat.and_le_right (n := num.bv.toNat) (m := 31)
         omega
       · decide
     exact Nat.le_of_lt_succ (Nat.or_lt_two_pow (n := 8) (by decide) hlow))

private lemma byte_tag_decode_components (cls : TagClass) (constructed : Bool) (low : I32)
    (hlo : 0 ≤ low.val) (hhi : low.val ≤ 31) :
    ∃ b,
      (do
        let k ← tag_class_code cls
        let s ← Pion.I32.shl k 6#i32
        ok (Pion.I32.bor (Pion.I32.bor s (if constructed then 32#i32 else 0#i32)) low)) = ok b ∧
      decode_tag_class_byte b = ok cls ∧
      decode_tag_constructed_byte b = ok constructed ∧
      decode_tag_low_byte b = ok low := by
  have hlow_hi : ∀ i (hi : i < 32), 5 ≤ i → low.bv[i] = false := fun i hi h5 =>
    bv32_getElem_high_false low hlo (by omega : low.val < ((2 ^ 5 : Nat) : Int)) i hi h5
  have h6n : (6#i32 : I32).val.toNat = 6 := rfl
  have haux : ∀ (k : I32) (cbyte : I32),
      0 ≤ k.val → k.val ≤ 3 → (cbyte = 0#i32 ∨ cbyte = 32#i32) →
      let b := Pion.I32.bor (Pion.I32.bor (⟨k.bv <<< 6⟩ : I32) cbyte) low
      Pion.I32.band (⟨b.bv.sshiftRight 6⟩ : I32) 3#i32 = k ∧
      Pion.I32.band b 32#i32 = cbyte ∧
      Pion.I32.band b 31#i32 = low := by
    intro k cbyte hk0 hk3 hc
    have hk_hi : ∀ i (hi : i < 32), 2 ≤ i → k.bv[i] = false := fun i hi h2 =>
      bv32_getElem_high_false k hk0 (by omega : k.val < ((2 ^ 2 : Nat) : Int)) i hi h2
    refine ⟨?_, ?_, ?_⟩
    · apply iscalar_eq_of_bv_eq
      apply BitVec.eq_of_getElem_eq
      intro i hi
      have hi32 : i < 32 := hi
      simp only [i32_band_bv, i32_mk_bv, BitVec.getElem_and]
      by_cases h2 : i < 2
      · have hlt : 6 + i < 32 := by omega
        have h3t : (3#i32).bv[i] = true := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (3#i32).bv.toNat = 3 := by decide
          rw [this]; revert i h2; decide
        simp only [BitVec.getElem_sshiftRight, hlt, ↓reduceDIte, i32_bor_bv, i32_mk_bv,
                   BitVec.getElem_or, BitVec.getElem_shiftLeft, show ¬(6 + i < 6) by omega,
                   decide_false, Bool.not_false, Bool.true_and, h3t, Bool.and_true]
        have hl := hlow_hi (6 + i) hlt (by omega)
        have hcb : cbyte.bv[6 + i] = false := by
          rcases hc with rfl | rfl
          · simp
          · rw [BitVec.getElem_eq_testBit_toNat]
            have : (32#i32).bv.toNat = 2 ^ 5 := by decide
            rw [this, Nat.testBit_two_pow]; simp [show 5 ≠ 6 + i by omega]
        rw [hl, hcb, Bool.or_false, Bool.or_false]
        congr 1; omega
      · have h3f : (3#i32).bv[i] = false := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (3#i32).bv.toNat = 3 := by decide
          rw [this]
          exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 2 ≤ i)))
        have hkf := hk_hi i hi32 (by omega)
        rw [h3f, hkf, Bool.and_false]
    · apply iscalar_eq_of_bv_eq
      apply BitVec.eq_of_getElem_eq
      intro i hi
      have hi32 : i < 32 := hi
      simp only [i32_band_bv, i32_bor_bv, i32_mk_bv, BitVec.getElem_and, BitVec.getElem_or, BitVec.getElem_shiftLeft]
      by_cases h5 : i = 5
      · subst h5
        have hl := hlow_hi 5 (by omega) (by omega)
        have h32t : (32#i32).bv[5]'(by decide) = true := by decide
        simp only [show (5 < 6) by omega, decide_true, Bool.not_true, Bool.false_and,
                   Bool.false_or, hl, Bool.or_false, h32t, Bool.and_true]
      · have h32f : (32#i32).bv[i] = false := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (32#i32).bv.toNat = 2 ^ 5 := by decide
          rw [this, Nat.testBit_two_pow]; simp [Ne.symm h5]
        have hcb : cbyte.bv[i] = false := by
          rcases hc with rfl | rfl
          · simp
          · exact h32f
        rw [h32f, hcb, Bool.and_false]
    · apply iscalar_eq_of_bv_eq
      apply BitVec.eq_of_getElem_eq
      intro i hi
      have hi32 : i < 32 := hi
      simp only [i32_band_bv, i32_bor_bv, i32_mk_bv, BitVec.getElem_and, BitVec.getElem_or, BitVec.getElem_shiftLeft]
      by_cases h5 : i < 5
      · have h31t : (31#i32).bv[i] = true := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (31#i32).bv.toNat = 31 := by decide
          rw [this]; revert i h5; decide
        have hcb : cbyte.bv[i] = false := by
          rcases hc with rfl | rfl
          · simp
          · rw [BitVec.getElem_eq_testBit_toNat]
            have : (32#i32).bv.toNat = 2 ^ 5 := by decide
            rw [this, Nat.testBit_two_pow]; simp [show 5 ≠ i by omega]
        simp only [show i < 6 by omega, decide_true, Bool.not_true, Bool.false_and,
                   Bool.false_or, hcb, h31t, Bool.and_true]
      · have h31f : (31#i32).bv[i] = false := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (31#i32).bv.toNat = 31 := by decide
          rw [this]
          exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 5 ≤ i)))
        have hl := hlow_hi i hi32 (by omega)
        rw [h31f, hl, Bool.and_false]
  cases cls <;> cases constructed <;>
    (simp only [tag_class_code, result_bind_ok, ↓reduceIte, Bool.false_eq_true]
     rw [i32_shl_ok _ 6#i32 (by decide) (by decide), result_bind_ok, h6n]
     refine ⟨_, rfl, ?_, ?_, ?_⟩
     · unfold decode_tag_class_byte
       rw [i32_shr_ok _ 6#i32 (by decide) (by decide), result_bind_ok, h6n]
       rw [(haux _ _ (by decide) (by decide) (by simp)).1]
       simp [tag_class_from_code]
     · unfold decode_tag_constructed_byte
       rw [(haux _ _ (by decide) (by decide) (by simp)).2.1]
       congr 1
     · unfold decode_tag_low_byte
       rw [(haux _ _ (by decide) (by decide) (by simp)).2.2])

/-- Theorem 5: X.690 §8.1.2 full short-form identifier octet bijection for all `cls`, `constructed`, `0 ≤ num ≤ 30`. -/
theorem short_tag_byte_roundtrip (cls : TagClass) (constructed : Bool) (num : I32)
    (hlo : 0 ≤ num.val) (hhi : num.val ≤ 30) :
    ∃ b, encode_tag_first_byte cls constructed num = ok b ∧
      decode_tag_class_byte b = ok cls ∧
      decode_tag_constructed_byte b = ok constructed ∧
      decode_tag_low_byte b = ok num := by
  have hlt31 : num < (31#i32 : I32) := by change num.val < 31; omega
  have hmask : Pion.I32.band num 31#i32 = num := by
    apply iscalar_eq_of_bv_eq
    apply BitVec.eq_of_getElem_eq
    intro i hi
    have hi32 : i < 32 := hi
    simp only [i32_band_bv, BitVec.getElem_and]
    by_cases h5 : i < 5
    · have h31t : (31#i32).bv[i] = true := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (31#i32).bv.toNat = 31 := by decide
        rw [this]; revert i h5; decide
      rw [h31t]; simp
    · have h31f : (31#i32).bv[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (31#i32).bv.toNat = 31 := by decide
        rw [this]
        exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 5 ≤ i)))
      have hn := bv32_getElem_high_false num hlo (by omega : num.val < ((2 ^ 5 : Nat) : Int)) i hi32 (by omega)
      rw [h31f, hn]; simp
  rcases byte_tag_decode_components cls constructed num hlo (by omega) with ⟨b, henc, hcls, hcon, hlow⟩
  refine ⟨b, ?_, hcls, hcon, hlow⟩
  unfold encode_tag_first_byte
  simp only [hlt31, ↓reduceIte, hmask]
  exact henc

/-- Theorem 6: X.690 §8.1.2.4 high-tag-number sentinel (`num ≥ 31`) sets low 5 bits to `0x1F` (31) and preserves class & constructed flag. -/
theorem high_tag_sentinel_invariant (cls : TagClass) (constructed : Bool) (num : I32)
    (hhi : 31 ≤ num.val) :
    ∃ b, encode_tag_first_byte cls constructed num = ok b ∧
      decode_tag_class_byte b = ok cls ∧
      decode_tag_constructed_byte b = ok constructed ∧
      decode_tag_low_byte b = ok 31#i32 := by
  have hge31 : ¬(num < (31#i32 : I32)) := by change ¬(num.val < 31); omega
  rcases byte_tag_decode_components cls constructed 31#i32 (by decide) (by decide) with ⟨b, henc, hcls, hcon, hlow⟩
  refine ⟨b, ?_, hcls, hcon, hlow⟩
  unfold encode_tag_first_byte
  simp only [hge31, ↓reduceIte]
  exact henc

/-- Theorem 7: X.690 §11.1 DER BOOLEAN canonical check accepts ONLY `0x00` and `0xFF`. -/
theorem der_bool_canonical_iff (v : I32) :
    is_canonical_der_bool_byte v = ok true ↔ v = 0#i32 ∨ v = 255#i32 := by
  unfold is_canonical_der_bool_byte
  constructor
  · intro h
    have ht := result_ok_inj h
    simp only [Bool.or_eq_true, beq_iff_eq] at ht
    exact ht
  · intro h
    rcases h with rfl | rfl <;> simp

private lemma byte_bit7_zero (b1 : I32) (hlo : 0 ≤ b1.val) (hhi : b1.val ≤ 127) :
    Pion.I32.band b1 128#i32 = 0#i32 := by
  apply iscalar_eq_of_bv_eq
  apply BitVec.eq_of_getElem_eq
  intro i hi
  have hi32 : i < 32 := hi
  simp only [i32_band_bv, BitVec.getElem_and]
  by_cases h7 : i = 7
  · subst h7
    have hb := bv32_getElem_high_false b1 hlo (by omega : b1.val < ((2 ^ 7 : Nat) : Int)) 7 (by omega) (by omega)
    rw [hb]; simp
  · have h128f : (128#i32).bv[i] = false := by
      rw [BitVec.getElem_eq_testBit_toNat]
      have : (128#i32).bv.toNat = 2 ^ 7 := by decide
      rw [this, Nat.testBit_two_pow]; simp [Ne.symm h7]
    rw [h128f]; simp

private lemma byte_bit7_nonzero (b1 : I32) (hlo : 128 ≤ b1.val) (hhi : b1.val ≤ 255) :
    Pion.I32.band b1 128#i32 = 128#i32 := by
  apply iscalar_eq_of_bv_eq
  apply BitVec.eq_of_getElem_eq
  intro i hi
  have hi32 : i < 32 := hi
  simp only [i32_band_bv, BitVec.getElem_and]
  by_cases h7 : i = 7
  · subst h7
    have hb : b1.bv[7] = true := by
      rw [BitVec.getElem_eq_testBit_toNat, i32_val_nonneg_toNat b1 (by omega)]
      rw [Nat.testBit, Nat.shiftRight_eq_div_pow]
      have hdiv : b1.val.toNat / 2 ^ 7 = 1 := by omega
      rw [hdiv]; decide
    have h128t : (128#i32).bv[7]'(by decide) = true := by decide
    rw [hb, h128t]; simp
  · have h128f : (128#i32).bv[i] = false := by
      rw [BitVec.getElem_eq_testBit_toNat]
      have : (128#i32).bv.toNat = 2 ^ 7 := by decide
      rw [this, Nat.testBit_two_pow]; simp [Ne.symm h7]
    rw [h128f]; simp

/-- Theorem 8: X.690 §8.3.2 DER INTEGER rejects redundant leading `0x00` when next byte's MSB is 0. -/
theorem der_int_pair_rejects_redundant_zero (b1 : I32) (hlo : 0 ≤ b1.val) (hhi : b1.val ≤ 127) :
    is_canonical_der_int_pair 0#i32 b1 = ok false := by
  unfold is_canonical_der_int_pair
  rw [byte_bit7_zero b1 hlo hhi]
  congr 1

/-- Theorem 9: X.690 §8.3.2 DER INTEGER rejects redundant leading `0xFF` when next byte's MSB is 1. -/
theorem der_int_pair_rejects_redundant_ff (b1 : I32) (hlo : 128 ≤ b1.val) (hhi : b1.val ≤ 255) :
    is_canonical_der_int_pair 255#i32 b1 = ok false := by
  unfold is_canonical_der_int_pair
  rw [byte_bit7_nonzero b1 hlo hhi]
  congr 1

/-- Theorem 10: X.690 §8.3.2 DER INTEGER accepts necessary sign-extension leading `0x00` (when MSB=1) and `0xFF` (when MSB=0). -/
theorem der_int_pair_accepts_sign_guard (b0 b1 : I32)
    (h : (b0 = 0#i32 ∧ 128 ≤ b1.val ∧ b1.val ≤ 255) ∨ (b0 = 255#i32 ∧ 0 ≤ b1.val ∧ b1.val ≤ 127)) :
    is_canonical_der_int_pair b0 b1 = ok true := by
  unfold is_canonical_der_int_pair
  rcases h with ⟨rfl, hlo, hhi⟩ | ⟨rfl, hlo, hhi⟩
  · rw [byte_bit7_nonzero b1 hlo hhi]; congr 1
  · rw [byte_bit7_zero b1 hlo hhi]; congr 1

/-- Theorem 11: X.690 §8.6 BIT STRING rejects `unused_bits` outside `[0, 7]`. -/
theorem bit_string_padding_rejects_out_of_range (len unused last : I32)
    (h : unused.val < 0 ∨ unused.val > 7) :
    is_valid_bit_string_padding len unused last = ok false := by
  unfold is_valid_bit_string_padding
  rcases h with hlt | hgt
  · have h1 : unused < (0#i32 : I32) := hlt
    simp [h1]
  · have h2 : (7#i32 : I32) < unused := hgt
    simp [h2]

/-- Theorem 12: X.690 §11.2.2 empty BIT STRING is valid iff `unused_bits == 0`. -/
theorem bit_string_empty_requires_zero_unused (unused last : I32) :
    is_valid_bit_string_padding 0#i32 unused last = ok true ↔ unused = 0#i32 := by
  unfold is_valid_bit_string_padding
  constructor
  · intro h
    by_cases hbad : (decide (unused < 0#i32) || decide (unused > 7#i32)) = true
    · simp only [hbad, ↓reduceIte] at h
      exact absurd (result_ok_inj h) (by decide)
    · simp only [hbad, ↓reduceIte] at h
      have ht := result_ok_inj h
      exact beq_iff_eq.mp ht
  · intro h
    subst h; simp

/-- Theorem 13: X.690 §8.6 non-empty BIT STRING with `unused_bits = 0` is always valid regardless of `last_byte`. -/
theorem bit_string_zero_unused_always_valid (len last : I32) (hne : len ≠ 0#i32) :
    is_valid_bit_string_padding len 0#i32 last = ok true := by
  unfold is_valid_bit_string_padding
  simp [hne]

private lemma der_length_encoded_size_spec (x : I32) :
    ∃ n, der_length_encoded_size x = ok n ∧ 1 ≤ n.val ∧ n.val ≤ 5 ∧
      (n.val = 1 ↔ x.val < 128) ∧
      (n.val = 2 ↔ 128 ≤ x.val ∧ x.val ≤ 255) ∧
      (n.val = 3 ↔ 256 ≤ x.val ∧ x.val ≤ 65535) ∧
      (n.val = 4 ↔ 65536 ≤ x.val ∧ x.val ≤ 16777215) ∧
      (n.val = 5 ↔ 16777216 ≤ x.val) := by
  unfold der_length_encoded_size
  have v1 : (1#i32 : I32).val = 1 := rfl
  have v2 : (2#i32 : I32).val = 2 := rfl
  have v3 : (3#i32 : I32).val = 3 := rfl
  have v4 : (4#i32 : I32).val = 4 := rfl
  have v5 : (5#i32 : I32).val = 5 := rfl
  by_cases h1 : x.val < 128
  · have ht : x < (128#i32 : I32) := h1
    simp only [ht, ↓reduceIte]
    exact ⟨1#i32, rfl, by omega, by omega, by omega, by omega, by omega, by omega, by omega⟩
  · have hf1 : ¬(x < (128#i32 : I32)) := h1
    by_cases h2 : x.val ≤ 255
    · have ht : x ≤ (255#i32 : I32) := h2
      simp only [hf1, ht, ↓reduceIte]
      exact ⟨2#i32, rfl, by omega, by omega, by omega, by omega, by omega, by omega, by omega⟩
    · have hf2 : ¬(x ≤ (255#i32 : I32)) := h2
      by_cases h3 : x.val ≤ 65535
      · have ht : x ≤ (65535#i32 : I32) := h3
        simp only [hf1, hf2, ht, ↓reduceIte]
        exact ⟨3#i32, rfl, by omega, by omega, by omega, by omega, by omega, by omega, by omega⟩
      · have hf3 : ¬(x ≤ (65535#i32 : I32)) := h3
        by_cases h4 : x.val ≤ 16777215
        · have ht : x ≤ (16777215#i32 : I32) := h4
          simp only [hf1, hf2, hf3, ht, ↓reduceIte]
          exact ⟨4#i32, rfl, by omega, by omega, by omega, by omega, by omega, by omega, by omega⟩
        · have hf4 : ¬(x ≤ (16777215#i32 : I32)) := h4
          simp only [hf1, hf2, hf3, hf4, ↓reduceIte]
          exact ⟨5#i32, rfl, by omega, by omega, by omega, by omega, by omega, by omega, by omega⟩

/-- Theorem 14: X.690 §8.1.3 / §10.1 canonical DER length byte count is bounded in `[1, 5]` and monotone in `len`. -/
theorem der_length_encoded_size_bounds_and_monotone (len1 len2 : I32) (hle : len1.val ≤ len2.val) :
    ∃ n1 n2, der_length_encoded_size len1 = ok n1 ∧ der_length_encoded_size len2 = ok n2 ∧
      1 ≤ n1.val ∧ n1.val ≤ 5 ∧ 1 ≤ n2.val ∧ n2.val ≤ 5 ∧ n1.val ≤ n2.val := by
  rcases der_length_encoded_size_spec len1 with ⟨n1, h1, ha1, hb1, c11, c12, c13, c14, c15⟩
  rcases der_length_encoded_size_spec len2 with ⟨n2, h2, ha2, hb2, c21, c22, c23, c24, c25⟩
  exact ⟨n1, n2, h1, h2, ha1, hb1, ha2, hb2, by omega⟩

end Asn1Proofs
