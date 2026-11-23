import Aeneas
import PionLean
import Url.Types
import Url.Funs

open Aeneas Aeneas.Std Result Pion url

namespace UrlProofs

private lemma i64_add_val (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val + y.val)
    (hhi : x.val + y.val ≤ 9223372036854775807) :
    (Pion.I64.add x y).val = x.val + y.val := by
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add, Int.bmod_def]
  change -9223372036854775808 ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt ≤ 9223372036854775807 at hhi
  omega

private lemma i64_sub_val (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val - y.val)
    (hhi : x.val - y.val ≤ 9223372036854775807) :
    (Pion.I64.sub x y).val = x.val - y.val := by
  change (x.bv - y.bv).toInt = x.bv.toInt - y.bv.toInt
  rw [BitVec.toInt_sub, Int.bmod_def]
  change -9223372036854775808 ≤ x.bv.toInt - y.bv.toInt at hlo
  change x.bv.toInt - y.bv.toInt ≤ 9223372036854775807 at hhi
  omega

private lemma i32_add_val (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val + y.val)
    (hhi : x.val + y.val ≤ 2147483647) :
    (Pion.I32.add x y).val = x.val + y.val := by
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add, Int.bmod_def]
  change -2147483648 ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt ≤ 2147483647 at hhi
  omega

private lemma i32_sub_val (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val - y.val)
    (hhi : x.val - y.val ≤ 2147483647) :
    (Pion.I32.sub x y).val = x.val - y.val := by
  change (x.bv - y.bv).toInt = x.bv.toInt - y.bv.toInt
  rw [BitVec.toInt_sub, Int.bmod_def]
  change -2147483648 ≤ x.bv.toInt - y.bv.toInt at hlo
  change x.bv.toInt - y.bv.toInt ≤ 2147483647 at hhi
  omega

private lemma i64_to_i32_val (x : Std.I64) (hlo : 0 ≤ x.val) (hhi : x.val ≤ 1000) :
    (Pion.I64.to_int x).val = x.val := by
  have hcond : (x.bv.toNat : Int) = x.val ∧ 2 * x.bv.toNat < 2 ^ 64 := by
    have h := x.bv.toInt_eq_toNat_cond
    change 0 ≤ x.bv.toInt at hlo
    split_ifs at h with hc
    · exact ⟨h.symm, hc⟩
    · have := x.bv.isLt; omega
  have hmsb : x.bv.msb = false := by
    rw [BitVec.msb_eq_decide]
    exact decide_eq_false (by omega)
  have hbv : (Pion.I64.to_int x).bv = x.bv.signExtend 32 := rfl
  have hnat : (Pion.I64.to_int x).bv.toNat = x.bv.toNat := by
    rw [hbv, BitVec.signExtend_eq_setWidth_of_msb_false hmsb, BitVec.toNat_setWidth]
    exact Nat.mod_eq_of_lt (by omega)
  have h := (Pion.I64.to_int x).bv.toInt_eq_toNat_cond
  change (Pion.I64.to_int x).bv.toInt = x.val
  split_ifs at h with hc
  · rw [h, hnat]; omega
  · change ¬ 2 * (Pion.I64.to_int x).bv.toNat < 2 ^ 32 at hc; omega

private lemma i32_to_i64_val (x : Std.I32) (hlo : 0 ≤ x.val) :
    (Pion.I32.to_int64 x).val = x.val := by
  have hcond : (x.bv.toNat : Int) = x.val ∧ 2 * x.bv.toNat < 2 ^ 32 := by
    have h := x.bv.toInt_eq_toNat_cond
    change 0 ≤ x.bv.toInt at hlo
    split_ifs at h with hc
    · exact ⟨h.symm, hc⟩
    · have := x.bv.isLt; omega
  have hmsb : x.bv.msb = false := by
    rw [BitVec.msb_eq_decide]
    exact decide_eq_false (by omega)
  have hbv : (Pion.I32.to_int64 x).bv = x.bv.signExtend 64 := rfl
  have hnat : (Pion.I32.to_int64 x).bv.toNat = x.bv.toNat := by
    rw [hbv, BitVec.signExtend_eq_setWidth_of_msb_false hmsb, BitVec.toNat_setWidth]
    have := x.bv.isLt
    exact Nat.mod_eq_of_lt (by omega)
  have h := (Pion.I32.to_int64 x).bv.toInt_eq_toNat_cond
  change (Pion.I32.to_int64 x).bv.toInt = x.val
  split_ifs at h with hc
  · rw [h, hnat]; omega
  · change ¬ 2 * (Pion.I32.to_int64 x).bv.toNat < 2 ^ 64 at hc; omega

private lemma i32_to_u8_val (x : Std.I32) (hlo : 0 ≤ x.val) (hhi : x.val ≤ 255) :
    (Pion.I32.to_byte x).val = x.val.toNat := by
  have hcond : (x.bv.toNat : Int) = x.val ∧ 2 * x.bv.toNat < 2 ^ 32 := by
    have h := x.bv.toInt_eq_toNat_cond
    change 0 ≤ x.bv.toInt at hlo
    split_ifs at h with hc
    · exact ⟨h.symm, hc⟩
    · have := x.bv.isLt; omega
  have hmsb : x.bv.msb = false := by
    rw [BitVec.msb_eq_decide]
    exact decide_eq_false (by omega)
  have hbv : (Pion.I32.to_byte x).bv = x.bv.signExtend 8 := rfl
  change (Pion.I32.to_byte x).bv.toNat = x.val.toNat
  rw [hbv, BitVec.signExtend_eq_setWidth_of_msb_false hmsb, BitVec.toNat_setWidth]
  rw [Nat.mod_eq_of_lt (by omega)]
  omega

/-- Theorem 1: `puny_threshold` always clamps into RFC 3492 `[tmin = 1, tmax = 26]`. -/
theorem puny_threshold_bounds (k bias : Std.I64)
    (hb_lo : -1000000000 ≤ bias.val) (hb_hi : bias.val ≤ 1000000000) :
    ∃ t : Std.I64, puny_threshold k bias = ok t ∧ 1 ≤ t.val ∧ t.val ≤ 26 := by
  unfold puny_threshold
  have c1 : (1#i64 : Std.I64).val = 1 := rfl
  have c26 : (26#i64 : Std.I64).val = 26 := rfl
  have hadd : (Pion.I64.add bias 26#i64).val = bias.val + 26 := i64_add_val bias 26#i64 (by omega) (by omega)
  refine ⟨_, rfl, ?_, ?_⟩
  · split_ifs with h1 h2
    · omega
    · omega
    · have h1' : ¬ (k.val ≤ bias.val) := h1
      have h2' : ¬ (k.val ≥ (Pion.I64.add bias 26#i64).val) := h2
      have hsub := i64_sub_val k bias (by omega) (by omega)
      omega
  · split_ifs with h1 h2
    · omega
    · omega
    · have h1' : ¬ (k.val ≤ bias.val) := h1
      have h2' : ¬ (k.val ≥ (Pion.I64.add bias 26#i64).val) := h2
      have hsub := i64_sub_val k bias (by omega) (by omega)
      omega

private lemma puny_threshold_exact (k bias : Std.I64)
    (hb_lo : -1000000000 ≤ bias.val) (hb_hi : bias.val ≤ 1000000000) :
    ∃ t : Std.I64, puny_threshold k bias = ok t ∧
      ((k.val ≤ bias.val → t.val = 1) ∧
       (k.val ≥ bias.val + 26 → t.val = 26) ∧
       (bias.val < k.val ∧ k.val < bias.val + 26 → t.val = k.val - bias.val)) := by
  unfold puny_threshold
  have c1 : (1#i64 : Std.I64).val = 1 := rfl
  have c26 : (26#i64 : Std.I64).val = 26 := rfl
  have hadd : (Pion.I64.add bias 26#i64).val = bias.val + 26 := i64_add_val bias 26#i64 (by omega) (by omega)
  refine ⟨_, rfl, ?_, ?_, ?_⟩
  · intro hle
    have hc : k ≤ bias := hle
    simp only [hc, ↓reduceIte]; omega
  · intro hge
    have h1 : ¬ (k ≤ bias) := by intro h; change k.val ≤ bias.val at h; omega
    have h2 : k ≥ Pion.I64.add bias 26#i64 := by change k.val ≥ (Pion.I64.add bias 26#i64).val; omega
    simp only [h1, h2, ↓reduceIte]; omega
  · intro ⟨hlt1, hlt2⟩
    have h1 : ¬ (k ≤ bias) := by intro h; change k.val ≤ bias.val at h; omega
    have h2 : ¬ (k ≥ Pion.I64.add bias 26#i64) := by intro h; change k.val ≥ (Pion.I64.add bias 26#i64).val at h; omega
    simp only [h1, h2, ↓reduceIte]
    exact i64_sub_val k bias (by omega) (by omega)

/-- Theorem 3: `puny_threshold` is monotonic in `k`. -/
theorem puny_threshold_mono_k (k1 k2 bias : Std.I64)
    (hb_lo : -1000000000 ≤ bias.val) (hb_hi : bias.val ≤ 1000000000) (hle : k1.val ≤ k2.val) :
    ∃ t1 t2 : Std.I64, puny_threshold k1 bias = ok t1 ∧ puny_threshold k2 bias = ok t2 ∧ t1.val ≤ t2.val := by
  obtain ⟨t1, ht1, h1a, h1b, h1c⟩ := puny_threshold_exact k1 bias hb_lo hb_hi
  obtain ⟨t2, ht2, h2a, h2b, h2c⟩ := puny_threshold_exact k2 bias hb_lo hb_hi
  refine ⟨t1, t2, ht1, ht2, ?_⟩
  by_cases c1 : k1.val ≤ bias.val
  · have := h1a c1
    obtain ⟨t2', ht2', hlo, _⟩ := puny_threshold_bounds k2 bias hb_lo hb_hi
    rw [ht2] at ht2'; simp only [ok.injEq] at ht2'; subst ht2'; omega
  · by_cases c2 : k1.val ≥ bias.val + 26
    · have := h1b c2; have := h2b (by omega); omega
    · have := h1c ⟨by omega, by omega⟩
      by_cases d2 : k2.val ≥ bias.val + 26
      · have := h2b d2; omega
      · have := h2c ⟨by omega, by omega⟩; omega

private lemma puny_encode_digit_ascii_range (d : Std.I64) (hlo : 0 ≤ d.val) (hhi : d.val ≤ 35) :
    ∃ b : Std.U8, puny_encode_digit d = ok b ∧
      ((d.val < 26 → b.val = 97 + d.val.toNat) ∧
       (26 ≤ d.val → b.val = 48 + (d.val - 26).toNat)) := by
  unfold puny_encode_digit
  have c26 : (26#i64 : Std.I64).val = 26 := rfl
  have c97 : (97#i32 : Std.I32).val = 97 := rfl
  have c48 : (48#i32 : Std.I32).val = 48 := rfl
  refine ⟨_, rfl, ?_, ?_⟩
  · intro hlt
    have hc : d < 26#i64 := hlt
    simp only [hc, ↓reduceIte]
    have hd32 : (Pion.I64.to_int d).val = d.val := i64_to_i32_val d hlo (by omega)
    have hadd : (Pion.I32.add 97#i32 (Pion.I64.to_int d)).val = 97 + d.val := by
      rw [i32_add_val 97#i32 (Pion.I64.to_int d) (by omega) (by omega), c97, hd32]
    rw [i32_to_u8_val _ (by omega) (by omega), hadd]
    omega
  · intro hge
    have hc : ¬ (d < 26#i64) := by intro h; change d.val < 26 at h; omega
    simp only [hc, ↓reduceIte]
    have hsub : (Pion.I64.sub d 26#i64).val = d.val - 26 := by
      rw [i64_sub_val d 26#i64 (by omega) (by omega), c26]
    have hd32 : (Pion.I64.to_int (Pion.I64.sub d 26#i64)).val = d.val - 26 := by
      rw [i64_to_i32_val _ (by omega) (by omega), hsub]
    have hadd : (Pion.I32.add 48#i32 (Pion.I64.to_int (Pion.I64.sub d 26#i64))).val = 48 + (d.val - 26) := by
      rw [i32_add_val 48#i32 _ (by omega) (by omega), c48, hd32]
    rw [i32_to_u8_val _ (by omega) (by omega), hadd]
    omega

/-- Theorem 5: RFC 3492 base-36 digit encode→decode roundtrip over all 36 digits `0..35`. -/
theorem puny_digit_roundtrip (d : Std.I64) (hlo : 0 ≤ d.val) (hhi : d.val ≤ 35) :
    ∃ b : Std.U8, puny_encode_digit d = ok b ∧
      puny_decode_digit ⟨b.bv.setWidth 32⟩ = ok d := by
  obtain ⟨b, hb, hlt, hge⟩ := puny_encode_digit_ascii_range d hlo hhi
  refine ⟨b, hb, ?_⟩
  set bi : Std.I32 := ⟨b.bv.setWidth 32⟩
  have hbi_val : bi.val = (b.val : Int) := by
    have hnat : bi.bv.toNat = b.val := by
      change (b.bv.setWidth 32).toNat = b.bv.toNat
      rw [BitVec.toNat_setWidth]
      have := b.bv.isLt
      exact Nat.mod_eq_of_lt (by omega)
    have h := bi.bv.toInt_eq_toNat_cond
    change bi.bv.toInt = (b.val : Int)
    split_ifs at h with hc
    · rw [h, hnat]
    · change ¬ 2 * bi.bv.toNat < 2 ^ 32 at hc; have := b.bv.isLt; omega
  unfold puny_decode_digit
  have c97 : (97#i32 : Std.I32).val = 97 := rfl
  have c48 : (48#i32 : Std.I32).val = 48 := rfl
  have c26 : (26#i32 : Std.I32).val = 26 := rfl
  by_cases hd26 : d.val < 26
  · have hbv := hlt hd26
    have hc1 : ((decide (bi >= 97#i32)) && (decide (bi <= 122#i32))) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq]
      exact ⟨by change bi.val ≥ 97; omega, by change bi.val ≤ 122; omega⟩
    simp only [hc1, ↓reduceIte]
    apply congrArg ok
    apply IScalar.eq_of_val_eq
    have hsub : (Pion.I32.sub bi 97#i32).val = d.val := by
      rw [i32_sub_val bi 97#i32 (by omega) (by omega), c97]; omega
    rw [i32_to_i64_val _ (by omega), hsub]
  · have hbv := hge (by omega)
    have hc1 : ((decide (bi >= 97#i32)) && (decide (bi <= 122#i32))) = false := by
      have hf : decide (bi >= 97#i32) = false := decide_eq_false (by intro h; change bi.val ≥ 97 at h; omega)
      rw [hf]; rfl
    have hc2 : ((decide (bi >= 65#i32)) && (decide (bi <= 90#i32))) = false := by
      have hf : decide (bi >= 65#i32) = false := decide_eq_false (by intro h; change bi.val ≥ 65 at h; omega)
      rw [hf]; rfl
    have hc3 : ((decide (bi >= 48#i32)) && (decide (bi <= 57#i32))) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq]
      exact ⟨by change bi.val ≥ 48; omega, by change bi.val ≤ 57; omega⟩
    simp only [hc1, hc2, hc3, Bool.false_eq_true, ↓reduceIte]
    apply congrArg ok
    apply IScalar.eq_of_val_eq
    have hsub : (Pion.I32.sub bi 48#i32).val = d.val - 26 := by
      rw [i32_sub_val bi 48#i32 (by omega) (by omega), c48]; omega
    have hadd : (Pion.I32.add (Pion.I32.sub bi 48#i32) 26#i32).val = d.val := by
      rw [i32_add_val _ 26#i32 (by omega) (by omega), hsub, c26]; omega
    rw [i32_to_i64_val _ (by omega), hadd]

/-- Theorem 6: `puny_decode_digit` is strictly case-insensitive on ASCII letters `'A'..'Z'` vs `'a'..'z'`. -/
theorem puny_decode_digit_case_insensitive (b : Std.I32) (hlo : 65 ≤ b.val) (hhi : b.val ≤ 90) :
    puny_decode_digit b = puny_decode_digit (Pion.I32.add b 32#i32) := by
  have c32 : (32#i32 : Std.I32).val = 32 := rfl
  have c65 : (65#i32 : Std.I32).val = 65 := rfl
  have c97 : (97#i32 : Std.I32).val = 97 := rfl
  set bl := Pion.I32.add b 32#i32
  have hbl : bl.val = b.val + 32 := by rw [i32_add_val b 32#i32 (by omega) (by omega), c32]
  unfold puny_decode_digit
  have hb1 : ((decide (b >= 97#i32)) && (decide (b <= 122#i32))) = false := by
    have hf : decide (b >= 97#i32) = false := decide_eq_false (by intro h; change b.val ≥ 97 at h; omega)
    rw [hf]; rfl
  have hb2 : ((decide (b >= 65#i32)) && (decide (b <= 90#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq]
    exact ⟨by change b.val ≥ 65; omega, by change b.val ≤ 90; omega⟩
  have hbl1 : ((decide (bl >= 97#i32)) && (decide (bl <= 122#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq]
    exact ⟨by change bl.val ≥ 97; omega, by change bl.val ≤ 122; omega⟩
  simp only [hb1, hb2, hbl1, Bool.false_eq_true, ↓reduceIte]
  apply congrArg ok
  apply IScalar.eq_of_val_eq
  have hsub1 : (Pion.I32.sub b 65#i32).val = b.val - 65 := by
    rw [i32_sub_val b 65#i32 (by omega) (by omega), c65]
  have hsub2 : (Pion.I32.sub bl 97#i32).val = b.val - 65 := by
    rw [i32_sub_val bl 97#i32 (by omega) (by omega), hbl, c97]; omega
  rw [i32_to_i64_val _ (by omega), i32_to_i64_val _ (by omega), hsub1, hsub2]

/-- Theorem 7: `puny_decode_digit` returns a digit in `[0, 35]` iff `b` is ASCII alphanumeric, else `-1`. -/
theorem puny_decode_digit_valid_iff (b : Std.I32) :
    ∃ v : Std.I64, puny_decode_digit b = ok v ∧
      ((0 ≤ v.val ∧ v.val ≤ 35) ↔
        ((97 ≤ b.val ∧ b.val ≤ 122) ∨ (65 ≤ b.val ∧ b.val ≤ 90) ∨ (48 ≤ b.val ∧ b.val ≤ 57))) ∧
      (v.val = -1 ↔
        ¬ ((97 ≤ b.val ∧ b.val ≤ 122) ∨ (65 ≤ b.val ∧ b.val ≤ 90) ∨ (48 ≤ b.val ∧ b.val ≤ 57))) := by
  unfold puny_decode_digit
  have c97 : (97#i32 : Std.I32).val = 97 := rfl
  have c65 : (65#i32 : Std.I32).val = 65 := rfl
  have c48 : (48#i32 : Std.I32).val = 48 := rfl
  have c26 : (26#i32 : Std.I32).val = 26 := rfl
  have cm1 : ((-1)#i64 : Std.I64).val = -1 := rfl
  by_cases h1 : ((decide (b >= 97#i32)) && (decide (b <= 122#i32))) = true
  · simp only [h1, ↓reduceIte]
    simp only [Bool.and_eq_true, decide_eq_true_eq] at h1
    have h1a : 97 ≤ b.val := h1.1; have h1b : b.val ≤ 122 := h1.2
    have hsub : (Pion.I32.sub b 97#i32).val = b.val - 97 := by
      rw [i32_sub_val b 97#i32 (by omega) (by omega), c97]
    have hv := i32_to_i64_val (Pion.I32.sub b 97#i32) (by omega)
    exact ⟨_, rfl, ⟨fun _ => Or.inl ⟨h1a, h1b⟩, fun _ => by omega⟩, ⟨fun h => by omega, fun h => (h (Or.inl ⟨h1a, h1b⟩)).elim⟩⟩
  · have h1f : ((decide (b >= 97#i32)) && (decide (b <= 122#i32))) = false := Bool.eq_false_iff.mpr h1
    simp only [h1f, Bool.false_eq_true, ↓reduceIte]
    simp only [Bool.and_eq_true, decide_eq_true_eq] at h1
    have hn1 : ¬ (97 ≤ b.val ∧ b.val ≤ 122) := fun ⟨a, c⟩ => h1 ⟨a, c⟩
    by_cases h2 : ((decide (b >= 65#i32)) && (decide (b <= 90#i32))) = true
    · simp only [h2, ↓reduceIte]
      simp only [Bool.and_eq_true, decide_eq_true_eq] at h2
      have h2a : 65 ≤ b.val := h2.1; have h2b : b.val ≤ 90 := h2.2
      have hsub : (Pion.I32.sub b 65#i32).val = b.val - 65 := by
        rw [i32_sub_val b 65#i32 (by omega) (by omega), c65]
      have hv := i32_to_i64_val (Pion.I32.sub b 65#i32) (by omega)
      exact ⟨_, rfl, ⟨fun _ => Or.inr (Or.inl ⟨h2a, h2b⟩), fun _ => by omega⟩,
             ⟨fun h => by omega, fun h => (h (Or.inr (Or.inl ⟨h2a, h2b⟩))).elim⟩⟩
    · have h2f : ((decide (b >= 65#i32)) && (decide (b <= 90#i32))) = false := Bool.eq_false_iff.mpr h2
      simp only [h2f, Bool.false_eq_true, ↓reduceIte]
      simp only [Bool.and_eq_true, decide_eq_true_eq] at h2
      have hn2 : ¬ (65 ≤ b.val ∧ b.val ≤ 90) := fun ⟨a, c⟩ => h2 ⟨a, c⟩
      by_cases h3 : ((decide (b >= 48#i32)) && (decide (b <= 57#i32))) = true
      · simp only [h3, ↓reduceIte]
        simp only [Bool.and_eq_true, decide_eq_true_eq] at h3
        have h3a : 48 ≤ b.val := h3.1; have h3b : b.val ≤ 57 := h3.2
        have hsub : (Pion.I32.sub b 48#i32).val = b.val - 48 := by
          rw [i32_sub_val b 48#i32 (by omega) (by omega), c48]
        have hadd : (Pion.I32.add (Pion.I32.sub b 48#i32) 26#i32).val = b.val - 48 + 26 := by
          rw [i32_add_val _ 26#i32 (by omega) (by omega), hsub, c26]
        have hv := i32_to_i64_val (Pion.I32.add (Pion.I32.sub b 48#i32) 26#i32) (by omega)
        exact ⟨_, rfl, ⟨fun _ => Or.inr (Or.inr ⟨h3a, h3b⟩), fun _ => by omega⟩,
               ⟨fun h => by omega, fun h => (h (Or.inr (Or.inr ⟨h3a, h3b⟩))).elim⟩⟩
      · have h3f : ((decide (b >= 48#i32)) && (decide (b <= 57#i32))) = false := Bool.eq_false_iff.mpr h3
        simp only [h3f, Bool.false_eq_true, ↓reduceIte]
        simp only [Bool.and_eq_true, decide_eq_true_eq] at h3
        have hn3 : ¬ (48 ≤ b.val ∧ b.val ≤ 57) := fun ⟨a, c⟩ => h3 ⟨a, c⟩
        exact ⟨(-1)#i64, rfl, ⟨fun h => by omega, fun h => by rcases h with h | h | h <;> omega⟩,
               ⟨fun _ => by rintro (h | h | h) <;> omega, fun _ => cm1⟩⟩

private def pureByteMask (b : Int) : BitVec 32 :=
  let is_ctrl := decide (b ≤ 31) || decide (b > 126)
  let m1 : BitVec 32 := if is_ctrl then 0#32 ||| 1#32 else 0#32
  let is_frag := is_ctrl || decide (b = 32) || decide (b = 34) || decide (b = 60) || decide (b = 62) || decide (b = 96)
  let m2 := if is_frag then m1 ||| 2#32 else m1
  let is_query := is_ctrl || decide (b = 32) || decide (b = 34) || decide (b = 35) || decide (b = 60) || decide (b = 62)
  let m3 := if is_query then m2 ||| 4#32 else m2
  let is_squery := is_query || decide (b = 39)
  let m4 := if is_squery then m3 ||| 8#32 else m3
  let is_path := is_query || decide (b = 63) || decide (b = 94) || decide (b = 96) || decide (b = 123) || decide (b = 125)
  let m5 := if is_path then m4 ||| 16#32 else m4
  let is_userinfo := is_path || decide (b = 47) || decide (b = 58) || decide (b = 59) || decide (b = 61) ||
                     decide (b = 64) || decide (b = 91) || decide (b = 92) || decide (b = 93) || decide (b = 124)
  let m6 := if is_userinfo then m5 ||| 32#32 else m5
  let is_comp := is_userinfo || decide (b = 36) || decide (b = 37) || decide (b = 38) || decide (b = 43) || decide (b = 44)
  let m7 := if is_comp then m6 ||| 64#32 else m6
  let is_form_safe := decide (b = 42) || decide (b = 45) || decide (b = 46) ||
                      (decide (b ≥ 48) && decide (b ≤ 57)) ||
                      (decide (b ≥ 65) && decide (b ≤ 90)) ||
                      decide (b = 95) ||
                      (decide (b ≥ 97) && decide (b ≤ 122))
  if !is_form_safe then m7 ||| 128#32 else m7

private lemma i32_beq_eq_decide (b c : Std.I32) : (b == c) = decide (b.val = c.val) := by
  cases hb : (b == c)
  · have hne : b ≠ c := beq_eq_false_iff_ne.mp hb
    have hv : b.val ≠ c.val := fun h => hne (IScalar.eq_of_val_eq h)
    exact (decide_eq_false hv).symm
  · have heq : b = c := beq_iff_eq.mp hb
    subst heq
    exact (decide_eq_true rfl).symm

private lemma i32_if_bor_mk (p : Bool) (x c : BitVec 32) :
    (if p = true then Pion.I32.bor ⟨x⟩ ⟨c⟩ else (⟨x⟩ : Std.I32)) = ⟨if p then x ||| c else x⟩ := by
  cases p <;> rfl

private lemma encode_byte_mask_eq_pure (b : Std.I32) :
    encode_byte_mask b = ok ⟨pureByteMask b.val⟩ := by
  unfold encode_byte_mask pureByteMask
  have hbind : ∀ (x : Std.I32) (f : Std.I32 → Result Std.I32),
      (do let r ← ok x; f r) = f x := by intro x f; simp
  have hstep_end : ∀ (p : Bool) (x y : Std.I32),
      (if p = true then ok x else ok y) = ok (if p = true then x else y) := by
    intro p x y; cases p <;> rfl
  simp only [hstep_end, hbind, i32_beq_eq_decide]
  apply congrArg ok
  have h0 : (0#i32 : Std.I32) = ⟨0#32⟩ := rfl
  have h1 : (1#i32 : Std.I32) = ⟨1#32⟩ := rfl
  have h2 : (2#i32 : Std.I32) = ⟨2#32⟩ := rfl
  have h4 : (4#i32 : Std.I32) = ⟨4#32⟩ := rfl
  have h8 : (8#i32 : Std.I32) = ⟨8#32⟩ := rfl
  have h16 : (16#i32 : Std.I32) = ⟨16#32⟩ := rfl
  have h32 : (32#i32 : Std.I32) = ⟨32#32⟩ := rfl
  have h64 : (64#i32 : Std.I32) = ⟨64#32⟩ := rfl
  have h128 : (128#i32 : Std.I32) = ⟨128#32⟩ := rfl
  rw [h0, h1, h2, h4, h8, h16, h32, h64, h128]
  simp only [i32_if_bor_mk]
  rfl

private lemma bv32_if_or_bit0_false (p : Bool) (x y : BitVec 32)
    (hx : x.getLsbD 0 = false) (hy : y.getLsbD 0 = false) :
    (if p then x ||| y else x).getLsbD 0 = false := by
  cases p
  · exact hx
  · simp only [↓reduceIte, BitVec.getLsbD_or, hx, hy, Bool.or_false]

/-- Theorem 9: In WHATWG URL §1.3, every byte in `Controls` (bit 0) is encoded by all 8 sets (`mask = 0xFF`). -/
theorem encode_byte_mask_controls_subset_all (b : Std.I32) :
    ∃ m : Std.I32, encode_byte_mask b = ok m ∧
      (m.bv.getLsbD 0 = true → m.bv = 255#32) := by
  rw [encode_byte_mask_eq_pure]
  refine ⟨⟨pureByteMask b.val⟩, rfl, ?_⟩
  intro h0
  change (pureByteMask b.val).getLsbD 0 = true at h0
  change pureByteMask b.val = 255#32
  unfold pureByteMask at h0 ⊢
  dsimp only at h0 ⊢
  by_cases hc : (decide (b.val ≤ 31) || decide (b.val > 126)) = true
  · have hnsafe : (decide (b.val = 42) || decide (b.val = 45) || decide (b.val = 46) ||
        (decide (b.val ≥ 48) && decide (b.val ≤ 57)) ||
        (decide (b.val ≥ 65) && decide (b.val ≤ 90)) ||
        decide (b.val = 95) ||
        (decide (b.val ≥ 97) && decide (b.val ≤ 122))) = false := by
      simp only [Bool.or_eq_true, decide_eq_true_eq] at hc
      simp only [Bool.or_eq_false_iff, Bool.and_eq_false_iff, decide_eq_false_iff_not]
      omega
    simp only [hc, hnsafe, Bool.true_or, Bool.not_false, ↓reduceIte]
    decide
  · have hcf : (decide (b.val ≤ 31) || decide (b.val > 126)) = false := Bool.eq_false_iff.mpr hc
    simp only [hcf, Bool.false_eq_true, ↓reduceIte] at h0
    have hf : ∀ (p2 p3 p4 p5 p6 p7 p8 : Bool),
        let m1 : BitVec 32 := 0#32
        let m2 := if p2 then m1 ||| 2#32 else m1
        let m3 := if p3 then m2 ||| 4#32 else m2
        let m4 := if p4 then m3 ||| 8#32 else m3
        let m5 := if p5 then m4 ||| 16#32 else m4
        let m6 := if p6 then m5 ||| 32#32 else m5
        let m7 := if p7 then m6 ||| 64#32 else m6
        (if p8 then m7 ||| 128#32 else m7).getLsbD 0 = false := by
      intro p2 p3 p4 p5 p6 p7 p8
      have h1 : (0#32 : BitVec 32).getLsbD 0 = false := rfl
      have h2 := bv32_if_or_bit0_false p2 _ 2#32 h1 rfl
      have h3 := bv32_if_or_bit0_false p3 _ 4#32 h2 rfl
      have h4 := bv32_if_or_bit0_false p4 _ 8#32 h3 rfl
      have h5 := bv32_if_or_bit0_false p5 _ 16#32 h4 rfl
      have h6 := bv32_if_or_bit0_false p6 _ 32#32 h5 rfl
      have h7 := bv32_if_or_bit0_false p7 _ 64#32 h6 rfl
      exact bv32_if_or_bit0_false p8 _ 128#32 h7 rfl
    rw [hf] at h0
    contradiction

/-- Theorem 10: WHATWG URL §1.3 percent-encode inclusion hierarchy holds for all 256 byte values:
    `Query ⊆ SpecialQuery` and `Query ⊆ Path ⊆ Userinfo ⊆ Component`. -/
theorem encode_byte_mask_hierarchy (b : Std.I32) (hlo : 0 ≤ b.val) (hhi : b.val ≤ 255) :
    ∃ m : Std.I32, encode_byte_mask b = ok m ∧
      (m.bv.getLsbD 2 = true → m.bv.getLsbD 3 = true) ∧
      (m.bv.getLsbD 2 = true → m.bv.getLsbD 4 = true) ∧
      (m.bv.getLsbD 4 = true → m.bv.getLsbD 5 = true) ∧
      (m.bv.getLsbD 5 = true → m.bv.getLsbD 6 = true) := by
  rw [encode_byte_mask_eq_pure]
  refine ⟨⟨pureByteMask b.val⟩, rfl, ?_⟩
  have hdec : ∀ hi lo : Fin 16,
      let v := pureByteMask ((hi.val * 16 + lo.val : Nat) : Int)
      ((!v.getLsbD 2 || v.getLsbD 3) &&
       (!v.getLsbD 2 || v.getLsbD 4) &&
       (!v.getLsbD 4 || v.getLsbD 5) &&
       (!v.getLsbD 5 || v.getLsbD 6)) = true := by decide
  have hk := hdec ⟨b.val.toNat / 16, by omega⟩ ⟨b.val.toNat % 16, by omega⟩
  have hre : ((b.val.toNat / 16 * 16 + b.val.toNat % 16 : Nat) : Int) = b.val := by omega
  simp only [hre] at hk
  simp only [Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true'] at hk
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro h
    change (pureByteMask b.val).getLsbD 2 = true at h
    rcases hk.1.1.1 with h' | h'
    · rw [h] at h'; contradiction
    · exact h'
  · intro h
    change (pureByteMask b.val).getLsbD 2 = true at h
    rcases hk.1.1.2 with h' | h'
    · rw [h] at h'; contradiction
    · exact h'
  · intro h
    change (pureByteMask b.val).getLsbD 4 = true at h
    rcases hk.1.2 with h' | h'
    · rw [h] at h'; contradiction
    · exact h'
  · intro h
    change (pureByteMask b.val).getLsbD 5 = true at h
    rcases hk.2 with h' | h'
    · rw [h] at h'; contradiction
    · exact h'

/-- Theorem 11: Every ASCII alphanumeric byte (`0-9`, `A-Z`, `a-z`) is never percent-encoded in any WHATWG set (`mask = 0`). -/
theorem encode_byte_mask_ascii_alnum_safe (b : Std.I32)
    (halnum : (48 ≤ b.val ∧ b.val ≤ 57) ∨ (65 ≤ b.val ∧ b.val ≤ 90) ∨ (97 ≤ b.val ∧ b.val ≤ 122)) :
    encode_byte_mask b = ok 0#i32 := by
  rw [encode_byte_mask_eq_pure]
  apply congrArg ok
  apply IScalar.eq_of_val_eq
  have hdec : ∀ hi lo : Fin 16,
      let n : Int := ((hi.val * 16 + lo.val : Nat) : Int)
      if (48 ≤ n ∧ n ≤ 57) ∨ (65 ≤ n ∧ n ≤ 90) ∨ (97 ≤ n ∧ n ≤ 122) then
        pureByteMask n = 0#32
      else True := by decide
  have hk := hdec ⟨b.val.toNat / 16, by omega⟩ ⟨b.val.toNat % 16, by omega⟩
  have hre : ((b.val.toNat / 16 * 16 + b.val.toNat % 16 : Nat) : Int) = b.val := by omega
  simp only [hre, halnum, ↓reduceIte] at hk
  change (pureByteMask b.val).toInt = (0#i32 : Std.I32).val
  rw [hk]; rfl

end UrlProofs
