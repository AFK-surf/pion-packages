import Aeneas
import PionLean
import Base64.Types
import Base64.Funs

open Aeneas Aeneas.Std Result Pion base64

namespace Base64Proofs

lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

lemma iscalar_le_iff {ty : IScalarTy} (a b : IScalar ty) : a ≤ b ↔ a.val ≤ b.val := Iff.rfl
lemma iscalar_lt_iff {ty : IScalarTy} (a b : IScalar ty) : a < b ↔ a.val < b.val := Iff.rfl
lemma iscalar_gt_iff {ty : IScalarTy} (a b : IScalar ty) : a > b ↔ b.val < a.val := Iff.rfl

lemma iscalar_eq_iff {ty : IScalarTy} (a b : IScalar ty) :
    a = b ↔ a.val = b.val := by
  constructor
  · intro h; subst h; rfl
  · intro h; cases a; cases b; congr; exact BitVec.eq_of_toInt_eq h

lemma i32_eq_of_bv (a b : Std.I32) (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

lemma i32_bor_bv (a b : Std.I32) : (Pion.I32.bor a b).bv = a.bv ||| b.bv := rfl
lemma i32_band_bv (a b : Std.I32) : (Pion.I32.band a b).bv = a.bv &&& b.bv := rfl

lemma i32_bounds (x : Std.I32) : -2147483648 ≤ x.val ∧ x.val ≤ 2147483647 := by
  have h1 := x.hBounds
  simp [IScalarTy.numBits] at h1
  omega

lemma i64_bounds (x : Std.I64) :
    -9223372036854775808 ≤ x.val ∧ x.val ≤ 9223372036854775807 := by
  have h1 := x.hBounds
  simp [IScalarTy.numBits] at h1
  omega

lemma i32_to_int64_val (x : Std.I32) : (Pion.I32.to_int64 x).val = x.val := by
  simp only [Pion.I32.to_int64, IScalar.cast, IScalar.val, IScalarTy.numBits]
  rw [BitVec.toInt_signExtend]
  simp

lemma i64_to_int_val (x : Std.I64) (hlo : -2147483648 ≤ x.val) (hhi : x.val ≤ 2147483647) :
    (Pion.I64.to_int x).val = x.val := by
  unfold Pion.I64.to_int
  change (BitVec.ofInt 32 x.val).toInt = x.val
  rw [BitVec.toInt_ofInt, Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i32_add_val (a b : Std.I32) (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  unfold Pion.I32.add
  change (a.bv + b.bv).toInt = a.val + b.val
  rw [BitVec.toInt_add]
  change (a.val + b.val).bmod (2 ^ 32) = a.val + b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i32_sub_val (a b : Std.I32) (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  unfold Pion.I32.sub
  change (a.bv - b.bv).toInt = a.val - b.val
  rw [BitVec.toInt_sub]
  change (a.val - b.val).bmod (2 ^ 32) = a.val - b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i32_mul_val (a b : Std.I32) (hlo : -2147483648 ≤ a.val * b.val) (hhi : a.val * b.val ≤ 2147483647) :
    (Pion.I32.mul a b).val = a.val * b.val := by
  unfold Pion.I32.mul
  change (a.bv * b.bv).toInt = a.val * b.val
  rw [BitVec.toInt_mul]
  change (a.val * b.val).bmod (2 ^ 32) = a.val * b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

lemma i64_add_val (a b : Std.I64)
    (hlo : -9223372036854775808 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 9223372036854775807) :
    (Pion.I64.add a b).val = a.val + b.val := by
  unfold Pion.I64.add
  change (a.bv + b.bv).toInt = a.val + b.val
  rw [BitVec.toInt_add]
  change (a.val + b.val).bmod (2 ^ 64) = a.val + b.val
  have hpow : (2 : Int) ^ 64 = 18446744073709551616 := by norm_num
  rw [Int.bmod_eq_of_le] <;> omega

lemma i64_sub_val (a b : Std.I64)
    (hlo : -9223372036854775808 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 9223372036854775807) :
    (Pion.I64.sub a b).val = a.val - b.val := by
  unfold Pion.I64.sub
  change (a.bv - b.bv).toInt = a.val - b.val
  rw [BitVec.toInt_sub]
  change (a.val - b.val).bmod (2 ^ 64) = a.val - b.val
  have hpow : (2 : Int) ^ 64 = 18446744073709551616 := by norm_num
  rw [Int.bmod_eq_of_le] <;> omega

lemma i64_mul_val (a b : Std.I64)
    (hlo : -9223372036854775808 ≤ a.val * b.val) (hhi : a.val * b.val ≤ 9223372036854775807) :
    (Pion.I64.mul a b).val = a.val * b.val := by
  unfold Pion.I64.mul
  change (a.bv * b.bv).toInt = a.val * b.val
  rw [BitVec.toInt_mul]
  change (a.val * b.val).bmod (2 ^ 64) = a.val * b.val
  have hpow : (2 : Int) ^ 64 = 18446744073709551616 := by norm_num
  rw [Int.bmod_eq_of_le] <;> omega

lemma i64_div_pos_val (a b : Std.I64) (ha : 0 ≤ a.val) (hb : 0 < b.val) :
    ∃ q : Std.I64, Pion.I64.div a b = ok q ∧ q.val = a.val / b.val := by
  have hspec := Pion.I64.div_spec (x := a) (y := b) (by omega) (by omega)
  cases hd : Pion.I64.div a b with
  | ret q =>
    rw [hd, WP.spec_ok] at hspec
    exact ⟨q, rfl, by rw [hspec, Int.tdiv_eq_ediv_of_nonneg ha]⟩
  | vis e k => rw [hd, WP.spec_vis] at hspec; exact hspec.elim
  | div => rw [hd, WP.spec_div] at hspec; exact hspec.elim

lemma i64_max32_val : (2147483647#i64).val = 2147483647 := by
  change (BitVec.ofInt 64 2147483647).toInt = 2147483647
  rw [BitVec.toInt_ofInt]; norm_num

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

/-- Full-domain RFC 4648 §4/§5 Base64 `encoded_len` specification over ALL `Int32` inputs
    (including negative, 512 MiB `536870912`, and `INT32_MAX`): never traps, never overflows
    negative, returns `0` for `n ≤ 0`, and saturates exactly at `INT32_MAX` (`2147483647`). -/
theorem b64_encoded_len_full_domain (n : Std.I32) (pad : Bool) :
    ∃ L : Std.I32, encoded_len n pad = ok L ∧
      0 ≤ L.val ∧ L.val ≤ 2147483647 ∧
      L.val = (if n.val ≤ 0 then 0
               else min 2147483647 (if pad then ((n.val + 2) / 3) * 4 else (n.val * 4 + 2) / 3)) := by
  have hb := i32_bounds n
  have hmax := i64_max32_val
  have h2 : (2#i64).val = 2 := by decide
  have h3 : (3#i64).val = 3 := by decide
  have h4 : (4#i64).val = 4 := by decide
  have hmax32 : (2147483647#i32).val = 2147483647 := by norm_num
  unfold encoded_len
  by_cases hle : n.val ≤ 0
  · have hle' : n ≤ 0#i32 := hle
    simp only [hle', hle, ↓reduceIte]
    exact ⟨0#i32, rfl, by norm_num, by norm_num, by norm_num⟩
  · have hle' : ¬(n ≤ 0#i32) := hle
    simp only [hle', hle, ↓reduceIte]
    have hn64 : (Pion.I32.to_int64 n).val = n.val := i32_to_int64_val n
    cases pad
    · simp only [Bool.false_eq_true, ↓reduceIte]
      have hmul : (Pion.I64.mul (Pion.I32.to_int64 n) 4#i64).val = n.val * 4 := by
        rw [i64_mul_val _ _ (by rw [hn64, h4]; omega) (by rw [hn64, h4]; omega), hn64, h4]
      have hadd : (Pion.I64.add (Pion.I64.mul (Pion.I32.to_int64 n) 4#i64) 2#i64).val = n.val * 4 + 2 := by
        rw [i64_add_val _ _ (by rw [hmul, h2]; omega) (by rw [hmul, h2]; omega), hmul, h2]
      obtain ⟨res, hres, hresv⟩ := i64_div_pos_val _ 3#i64 (by rw [hadd]; omega) (by rw [h3]; omega)
      rw [hres, result_bind_ok]
      rw [hadd, h3] at hresv
      by_cases hgt : res.val > 2147483647
      · have hgt' : res > 2147483647#i64 := by rw [iscalar_gt_iff, hmax]; omega
        simp only [hgt', ↓reduceIte]
        exact ⟨2147483647#i32, rfl, by omega, by omega, by omega⟩
      · have hgt' : ¬(res > 2147483647#i64) := by rw [iscalar_gt_iff, hmax]; omega
        simp only [hgt', ↓reduceIte]
        have hcast := i64_to_int_val res (by omega) (by omega)
        exact ⟨Pion.I64.to_int res, rfl, by omega, by omega, by omega⟩
    · simp only [↓reduceIte]
      have hadd : (Pion.I64.add (Pion.I32.to_int64 n) 2#i64).val = n.val + 2 := by
        rw [i64_add_val _ _ (by rw [hn64, h2]; omega) (by rw [hn64, h2]; omega), hn64, h2]
      obtain ⟨q, hq, hqv⟩ := i64_div_pos_val _ 3#i64 (by rw [hadd]; omega) (by rw [h3]; omega)
      rw [hq, result_bind_ok]
      rw [hadd, h3] at hqv
      have hmul : (Pion.I64.mul q 4#i64).val = ((n.val + 2) / 3) * 4 := by
        rw [i64_mul_val q 4#i64 (by rw [hqv, h4]; omega) (by rw [hqv, h4]; omega), hqv, h4]
      set res := Pion.I64.mul q 4#i64
      by_cases hgt : res.val > 2147483647
      · have hgt' : res > 2147483647#i64 := by rw [iscalar_gt_iff, hmax]; omega
        simp only [hgt', ↓reduceIte]
        exact ⟨2147483647#i32, rfl, by omega, by omega, by omega⟩
      · have hgt' : ¬(res > 2147483647#i64) := by rw [iscalar_gt_iff, hmax]; omega
        simp only [hgt', ↓reduceIte]
        have hcast := i64_to_int_val res (by omega) (by omega)
        exact ⟨Pion.I64.to_int res, rfl, by omega, by omega, by omega⟩

/-- Global monotonicity of `encoded_len` over ALL `Std.I32` inputs (`m ≤ n`), both padded and unpadded. -/
theorem b64_encoded_len_mono_full (m n : Std.I32) (pad : Bool) (hmn : m.val ≤ n.val) :
    ∃ lm ln : Std.I32, encoded_len m pad = ok lm ∧ encoded_len n pad = ok ln ∧ lm.val ≤ ln.val := by
  obtain ⟨lm, hlm, _, _, hlmv⟩ := b64_encoded_len_full_domain m pad
  obtain ⟨ln, hln, _, _, hlnv⟩ := b64_encoded_len_full_domain n pad
  refine ⟨lm, ln, hlm, hln, ?_⟩
  cases pad <;> split_ifs at hlmv hlnv <;> omega

/-- Full-domain Base64 length roundtrip over ALL non-negative `Std.I32`:
    exact bijection `b64_decoded_len (encoded_len n false) = ok n` whenever the exact encoded
    length fits in `Int32` (`n ≤ 1610612734`), and safe saturation at `INT32_MAX` above. -/
theorem b64_length_roundtrip_full (n : Std.I32) (h0 : 0 ≤ n.val) :
    if (n.val * 4 + 2) / 3 ≤ 2147483647 then
      (do let L ← encoded_len n false; b64_decoded_len L) = ok n
    else
      encoded_len n false = ok 2147483647#i32 := by
  obtain ⟨L, hL, hL0, hLhi, hLv⟩ := b64_encoded_len_full_domain n false
  simp only [Bool.false_eq_true, ↓reduceIte] at hLv
  by_cases hfit : (n.val * 4 + 2) / 3 ≤ 2147483647
  · simp only [hfit, ↓reduceIte]
    rw [hL, result_bind_ok]
    have hLexact : L.val = (n.val * 4 + 2) / 3 := by
      split_ifs at hLv <;> omega
    unfold b64_decoded_len
    have hnotneg : ¬(L < 0#i32) := by rw [iscalar_lt_iff]; norm_num; omega
    simp only [hnotneg, ↓reduceIte]
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
  · simp only [hfit, ↓reduceIte]
    rw [hL]
    congr 1
    apply (iscalar_eq_iff _ _).mpr
    have hmax32 : (2147483647#i32).val = 2147483647 := by norm_num
    split_ifs at hLv <;> omega

end Base64Proofs
