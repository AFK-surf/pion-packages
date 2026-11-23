import Aeneas
import PionLean
import Base64.Types
import Base64.Funs

open Aeneas Aeneas.Std Result Pion base64

namespace Base64Proofs

lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

lemma iscalar_eq_iff {ty : IScalarTy} (a b : IScalar ty) :
    a = b ↔ a.val = b.val := by
  constructor
  · intro h; subst h; rfl
  · intro h; cases a; cases b; congr; exact BitVec.eq_of_toInt_eq h

lemma i32_eq_of_bv (a b : Std.I32) (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

lemma i32_bor_bv (a b : Std.I32) : (Pion.I32.bor a b).bv = a.bv ||| b.bv := rfl
lemma i32_band_bv (a b : Std.I32) : (Pion.I32.band a b).bv = a.bv &&& b.bv := rfl

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

lemma i32_mul_val (a b : Std.I32) (hlo : -2147483648 ≤ a.val * b.val) (hhi : a.val * b.val ≤ 2147483647) :
    (Pion.I32.mul a b).val = a.val * b.val := by
  unfold Pion.I32.mul
  have ha : a.bv.toInt = a.val := rfl
  have hb : b.bv.toInt = b.val := rfl
  change (a.bv * b.bv).toInt = a.bv.toInt * b.bv.toInt
  rw [BitVec.toInt_mul, ha, hb, Int.bmod_eq_of_le] <;> omega

lemma i32_div_pos_val (a b : Std.I32) (ha : 0 ≤ a.val) (hb : 0 < b.val) :
    ∃ q : Std.I32, Pion.I32.div a b = ok q ∧ q.val = a.val / b.val := by
  have hspec := Pion.I32.div_spec (x := a) (y := b) (by omega) (by omega)
  cases hd : Pion.I32.div a b with
  | ret q =>
    rw [hd, WP.spec_ok] at hspec
    exact ⟨q, rfl, by rw [hspec, Int.tdiv_eq_ediv_of_nonneg ha]⟩
  | vis e k => rw [hd, WP.spec_vis] at hspec; exact hspec.elim
  | div => rw [hd, WP.spec_div] at hspec; exact hspec.elim

lemma i32_toNat_of_nonneg (x : Std.I32) (h0 : 0 ≤ x.val) :
    x.bv.toNat = x.val.toNat ∧ x.bv.toNat < 2 ^ 31 := by
  have hti := BitVec.toInt_eq_toNat_cond x.bv
  have hlt : 2 * x.bv.toNat < 2 ^ 32 := by
    by_contra hge; push Not at hge
    rw [ite_eq_right (by omega)] at hti
    change x.bv.toInt ≥ 0 at h0
    omega
  rw [ite_eq_left hlt] at hti
  change x.bv.toNat = x.bv.toInt.toNat ∧ _
  omega

lemma bv32_sshiftRight_eq_ushiftRight (x : BitVec 32) (k : Nat) (hmsb : x.msb = false) :
    x.sshiftRight k = x >>> k := by
  ext i hi
  rw [BitVec.getElem_sshiftRight, BitVec.getElem_ushiftRight]
  by_cases h : k + i < 32
  · rw [dite_eq_left h, BitVec.getLsbD_eq_getElem (by omega)]
  · rw [dite_eq_right h, hmsb]
    symm
    rw [BitVec.getLsbD]
    exact Nat.testBit_lt_two_pow (by
      have := x.isLt
      have : (2 : Nat) ^ 32 ≤ 2 ^ (k + i) := Nat.pow_le_pow_right (by omega) (by omega)
      omega)

lemma i32_band_3_nonneg (x : Std.I32) (h0 : 0 ≤ x.val) :
    (Pion.I32.band x 3#i32).val = x.val % 4 := by
  have ⟨hnat, hlt⟩ := i32_toNat_of_nonneg x h0
  have hband : (Pion.I32.band x 3#i32).bv.toNat = x.bv.toNat % 4 := by
    rw [i32_band_bv, BitVec.toNat_and]
    have h3 : (3#i32).bv.toNat = 3 := by decide
    rw [h3]
    have : (3 : Nat) = 2 ^ 2 - 1 := by norm_num
    rw [this, Nat.and_two_pow_sub_one_eq_mod]
  have hval : (Pion.I32.band x 3#i32).val = ((Pion.I32.band x 3#i32).bv.toNat : Int) := by
    change (Pion.I32.band x 3#i32).bv.toInt = _
    rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega)]
  omega

lemma i32_shr_2_nonneg (x : Std.I32) (h0 : 0 ≤ x.val) :
    ∃ q : Std.I32, Pion.I32.shr x 2#i32 = ok q ∧ q.val = x.val / 4 := by
  unfold Pion.I32.shr
  have hc : 0 ≤ (2#i32).val ∧ (2#i32).val < 32 := by norm_num
  have h2 : (2#i32).val.toNat = 2 := by norm_num
  simp only [hc, and_self, ↓reduceIte, h2]
  refine ⟨_, rfl, ?_⟩
  have ⟨hnat, hlt⟩ := i32_toNat_of_nonneg x h0
  have hmsb : x.bv.msb = false := by
    rw [BitVec.msb_eq_decide]; simp only [decide_eq_false_iff_not]; omega
  have hshr_nat : (x.bv.sshiftRight 2).toNat = x.bv.toNat / 4 := by
    rw [bv32_sshiftRight_eq_ushiftRight x.bv 2 hmsb, BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
  change (x.bv.sshiftRight 2).toInt = x.val / 4
  rw [BitVec.toInt_eq_toNat_cond, ite_eq_left (by omega), hshr_nat]
  omega

/-- RFC 4648 §4: padded Base64 `encoded_len` equals `((n + 2) / 3) * 4` and is always a multiple of 4. -/
theorem b64_encoded_len_pad_spec (n : Std.I32) (h0 : 0 ≤ n.val) (hhi : n.val ≤ 536870910) :
    ∃ L : Std.I32, encoded_len n true = ok L ∧ L.val = ((n.val + 2) / 3) * 4 ∧ L.val % 4 = 0 := by
  unfold encoded_len
  simp only [↓reduceIte]
  have h2 : (2#i32).val = 2 := by norm_num
  have h3 : (3#i32).val = 3 := by norm_num
  have h4 : (4#i32).val = 4 := by norm_num
  have hadd := i32_add_val n 2#i32 (by omega) (by omega)
  obtain ⟨q, hq, hqv⟩ := i32_div_pos_val (Pion.I32.add n 2#i32) 3#i32 (by omega) (by omega)
  rw [hq, result_bind_ok]
  rw [hadd, h2, h3] at hqv
  have hmul : (Pion.I32.mul q 4#i32).val = q.val * 4 := by
    have := i32_mul_val q 4#i32 (by rw [h4]; omega) (by rw [h4]; omega)
    rw [h4] at this; exact this
  exact ⟨_, rfl, by omega, by omega⟩

/-- RFC 4648 §4/§5: unpadded Base64 `encoded_len` equals `(n * 4 + 2) / 3`. -/
theorem b64_encoded_len_nopad_spec (n : Std.I32) (h0 : 0 ≤ n.val) (hhi : n.val ≤ 536870910) :
    ∃ L : Std.I32, encoded_len n false = ok L ∧ L.val = (n.val * 4 + 2) / 3 := by
  unfold encoded_len
  simp only [Bool.false_eq_true, ↓reduceIte]
  have h2 : (2#i32).val = 2 := by norm_num
  have h3 : (3#i32).val = 3 := by norm_num
  have h4 : (4#i32).val = 4 := by norm_num
  have hmul : (Pion.I32.mul n 4#i32).val = n.val * 4 := by
    have := i32_mul_val n 4#i32 (by rw [h4]; omega) (by rw [h4]; omega)
    rw [h4] at this; exact this
  have hadd := i32_add_val (Pion.I32.mul n 4#i32) 2#i32 (by omega) (by omega)
  obtain ⟨q, hq, hqv⟩ := i32_div_pos_val (Pion.I32.add (Pion.I32.mul n 4#i32) 2#i32) 3#i32 (by omega) (by omega)
  rw [hq, result_bind_ok]
  rw [hadd, hmul, h2, h3] at hqv
  exact ⟨q, rfl, hqv⟩

/-- RFC 4648 §4: `b64_decoded_len` rejects every non-negative length `≡ 1 (mod 4)` with `-1`. -/
theorem b64_decoded_len_rejects_mod1 (len : Std.I32) (h0 : 0 ≤ len.val) (hmod : len.val % 4 = 1) :
    b64_decoded_len len = ok (-1)#i32 := by
  unfold b64_decoded_len
  have hrem : Pion.I32.band len 3#i32 = 1#i32 := by
    apply (iscalar_eq_iff _ _).mpr
    rw [i32_band_3_nonneg len h0]; norm_num; omega
  simp only [hrem, ↓reduceIte]

/-- Exact Base64 length bijection: `b64_decoded_len (encoded_len n false) = ok n` for every `0 ≤ n ≤ 536870910`. -/
theorem b64_length_roundtrip (n : Std.I32) (h0 : 0 ≤ n.val) (hhi : n.val ≤ 536870910) :
    (do let L ← encoded_len n false; b64_decoded_len L) = ok n := by
  obtain ⟨L, hL, hLv⟩ := b64_encoded_len_nopad_spec n h0 hhi
  rw [hL, result_bind_ok]
  unfold b64_decoded_len
  have hL0 : 0 ≤ L.val := by omega
  have hremv := i32_band_3_nonneg L hL0
  have h1v : (1#i32).val = 1 := by norm_num
  have h0v : (0#i32).val = 0 := by norm_num
  have h3v : (3#i32).val = 3 := by norm_num
  have hne1 : Pion.I32.band L 3#i32 ≠ 1#i32 := fun h => by
    have hv := (iscalar_eq_iff _ _).mp h
    rw [h1v] at hv; omega
  simp only [hne1, ↓reduceIte]
  obtain ⟨q, hq, hqv⟩ := i32_shr_2_nonneg L hL0
  rw [hq, result_bind_ok]
  congr 1
  apply (iscalar_eq_iff _ _).mpr
  have hmul : (Pion.I32.mul q 3#i32).val = q.val * 3 := by
    have := i32_mul_val q 3#i32 (by rw [h3v]; omega) (by rw [h3v]; omega)
    rw [h3v] at this; exact this
  by_cases hrem0 : Pion.I32.band L 3#i32 = 0#i32
  · simp only [hrem0, ↓reduceIte]
    have hr0 : L.val % 4 = 0 := by have hv := (iscalar_eq_iff _ _).mp hrem0; rw [h0v] at hv; omega
    have hadd := i32_add_val (Pion.I32.mul q 3#i32) 0#i32 (by omega) (by omega)
    omega
  · simp only [hrem0, ↓reduceIte]
    have hrne0 : L.val % 4 ≠ 0 := fun h => hrem0 ((iscalar_eq_iff _ _).mpr (by omega))
    have hsub := i32_sub_val (Pion.I32.band L 3#i32) 1#i32 (by omega) (by omega)
    have hadd := i32_add_val (Pion.I32.mul q 3#i32) (Pion.I32.sub (Pion.I32.band L 3#i32) 1#i32) (by omega) (by omega)
    omega

/-- `b64_expected_pad` completes any valid remainder `{0, 2, 3}` to a multiple of 4 with `0..2` pad chars. -/
theorem b64_expected_pad_completes_group (r : Std.I32) (hr : r = 0#i32 ∨ r = 2#i32 ∨ r = 3#i32) :
    ∃ p : Std.I32, b64_expected_pad r = ok p ∧ (r.val + p.val) % 4 = 0 ∧ 0 ≤ p.val ∧ p.val ≤ 2 := by
  rcases hr with rfl | rfl | rfl <;> unfold b64_expected_pad <;> refine ⟨_, rfl, by decide, by decide, by decide⟩

/-- `b64_tail_canonical_mask` yields exact trailing-bit masks: `2 → 15` (4 bits), `3 → 3` (2 bits), `0 → 0`. -/
theorem b64_tail_canonical_mask_spec :
    b64_tail_canonical_mask 2#i32 = ok 15#i32 ∧
    b64_tail_canonical_mask 3#i32 = ok 3#i32 ∧
    b64_tail_canonical_mask 0#i32 = ok 0#i32 := by
  refine ⟨by simp [b64_tail_canonical_mask], by simp [b64_tail_canonical_mask], by simp [b64_tail_canonical_mask]⟩

/-- `encoded_len` is monotonic in input length for both padded and unpadded modes. -/
theorem b64_encoded_len_mono (m n : Std.I32) (pad : Bool)
    (hm0 : 0 ≤ m.val) (hmn : m.val ≤ n.val) (hnhi : n.val ≤ 536870910) :
    ∃ lm ln : Std.I32, encoded_len m pad = ok lm ∧ encoded_len n pad = ok ln ∧ lm.val ≤ ln.val := by
  cases pad
  · obtain ⟨lm, hlm, hlmv⟩ := b64_encoded_len_nopad_spec m hm0 (by omega)
    obtain ⟨ln, hln, hlnv⟩ := b64_encoded_len_nopad_spec n (by omega) hnhi
    exact ⟨lm, ln, hlm, hln, by omega⟩
  · obtain ⟨lm, hlm, hlmv, _⟩ := b64_encoded_len_pad_spec m hm0 (by omega)
    obtain ⟨ln, hln, hlnv, _⟩ := b64_encoded_len_pad_spec n (by omega) hnhi
    exact ⟨lm, ln, hlm, hln, by omega⟩

end Base64Proofs
