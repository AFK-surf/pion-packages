import Aeneas
import PionLean
import Qrcode.Types
import Qrcode.Funs

open Aeneas Aeneas.Std Result Pion qrcode

namespace QrcodeProofs

private lemma result_bind_ok' {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private lemma i32_bv_toNat_of_nonneg (x : Std.I32) (h0 : 0 ≤ x.val) :
    (x.bv.toNat : Int) = x.val := by
  have h := x.bv.toInt_eq_toNat_cond
  change 0 ≤ x.bv.toInt at h0
  split_ifs at h with hcond
  · exact h.symm
  · have := x.bv.isLt; omega

private lemma i32_val_of_bv_toNat_lt (x : Std.I32) (hlt : x.bv.toNat < 2 ^ 31) :
    x.val = (x.bv.toNat : Int) := by
  have h := x.bv.toInt_eq_toNat_cond
  have h2 : 2 * x.bv.toNat < 2 ^ 32 := by omega
  simp only [h2, ↓reduceIte] at h
  exact h

private lemma i32_add_val' (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  change -2147483648 ≤ a.bv.toInt + b.bv.toInt at hlo
  change a.bv.toInt + b.bv.toInt ≤ 2147483647 at hhi
  change (a.bv + b.bv).toInt = a.bv.toInt + b.bv.toInt
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_sub_val' (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  change -2147483648 ≤ a.bv.toInt - b.bv.toInt at hlo
  change a.bv.toInt - b.bv.toInt ≤ 2147483647 at hhi
  change (a.bv - b.bv).toInt = a.bv.toInt - b.bv.toInt
  rw [BitVec.toInt_sub]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_mul_val' (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val * b.val) (hhi : a.val * b.val ≤ 2147483647) :
    (Pion.I32.mul a b).val = a.val * b.val := by
  change -2147483648 ≤ a.bv.toInt * b.bv.toInt at hlo
  change a.bv.toInt * b.bv.toInt ≤ 2147483647 at hhi
  change (a.bv * b.bv).toInt = a.bv.toInt * b.bv.toInt
  rw [BitVec.toInt_mul]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_band_1_nonneg (x : Std.I32) (hx : 0 ≤ x.val) :
    (Pion.I32.band x 1#i32).val = x.val % 2 := by
  have hxnat : (x.bv.toNat : Int) = x.val := i32_bv_toNat_of_nonneg x hx
  set r := Pion.I32.band x 1#i32
  have hrnat : r.bv.toNat = x.bv.toNat % 2 := by
    change (x.bv &&& (1#32 : BitVec 32)).toNat = x.bv.toNat % 2
    rw [BitVec.toNat_and]
    have h1 : (1#32 : BitVec 32).toNat = 2 ^ 1 - 1 := rfl
    rw [h1, Nat.and_two_pow_sub_one_eq_mod]
  have hrval : r.val = (r.bv.toNat : Int) := i32_val_of_bv_toNat_lt r (by rw [hrnat]; omega)
  rw [hrval, hrnat]; omega

private lemma i32_band_255_nonneg (x : Std.I32) (hx : 0 ≤ x.val) :
    (Pion.I32.band x 255#i32).val = x.val % 256 := by
  have hxnat : (x.bv.toNat : Int) = x.val := i32_bv_toNat_of_nonneg x hx
  set r := Pion.I32.band x 255#i32
  have hrnat : r.bv.toNat = x.bv.toNat % 256 := by
    change (x.bv &&& (255#32 : BitVec 32)).toNat = x.bv.toNat % 256
    rw [BitVec.toNat_and]
    have h255 : (255#32 : BitVec 32).toNat = 2 ^ 8 - 1 := rfl
    rw [h255, Nat.and_two_pow_sub_one_eq_mod]
  have hrval : r.val = (r.bv.toNat : Int) := i32_val_of_bv_toNat_lt r (by rw [hrnat]; omega)
  rw [hrval, hrnat]; omega

private lemma i32_div_nonneg' (a b : Std.I32) (ha : 0 ≤ a.val) (hb : 0 < b.val) :
    ∃ q : Std.I32, Pion.I32.div a b = ok q ∧ q.val = a.val / b.val := by
  have h1 : (b.val != 0) = true := bne_iff_ne.mpr (by omega)
  have h2 : ¬ ((decide (a.val = IScalar.min .I32) && decide (b.val = -1)) = true) := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, not_and]; intro _; omega
  have hdiv : Pion.I32.div a b = ok ⟨a.bv.sdiv b.bv⟩ := by
    unfold Pion.I32.div
    change IScalar.div a b = ok ⟨a.bv.sdiv b.bv⟩
    unfold IScalar.div
    simp only [h1, h2, ↓reduceIte]
    rfl
  refine ⟨⟨a.bv.sdiv b.bv⟩, hdiv, ?_⟩
  have hab := a.hBounds; simp [IScalarTy.numBits] at hab
  have ht : a.val.tdiv b.val = a.val / b.val := Int.tdiv_eq_ediv_of_nonneg ha
  have hqlo : 0 ≤ a.val / b.val := Int.ediv_nonneg ha (by omega)
  have hqhi : a.val / b.val ≤ a.val := Int.ediv_le_self b.val ha
  change (a.bv.sdiv b.bv).toInt = a.val / b.val
  rw [BitVec.toInt_sdiv]
  change (a.val.tdiv b.val).bmod (2 ^ 32) = a.val / b.val
  rw [ht, Int.bmod_eq_of_le (by omega) (by omega)]

private lemma i32_rem_nonneg' (a b : Std.I32) (ha : 0 ≤ a.val) (hb : 0 < b.val) :
    ∃ r : Std.I32, Pion.I32.rem a b = ok r ∧ r.val = a.val % b.val := by
  have h1 : (b.val != 0) = true := bne_iff_ne.mpr (by omega)
  have hnotmin : ¬ (a.val = -2147483648 ∧ b.val = -1) := by omega
  have hrem : Pion.I32.rem a b = ok ⟨a.bv.srem b.bv⟩ := by
    unfold Pion.I32.rem
    simp only [hnotmin, ↓reduceIte]
    change IScalar.rem a b = ok ⟨a.bv.srem b.bv⟩
    unfold IScalar.rem
    simp only [h1, ↓reduceIte]
  refine ⟨⟨a.bv.srem b.bv⟩, hrem, ?_⟩
  have hbb := b.hBounds; simp [IScalarTy.numBits] at hbb
  have ht : a.val.tmod b.val = a.val % b.val := Int.tmod_eq_emod_of_nonneg ha
  change (a.bv.srem b.bv).toInt = a.val % b.val
  rw [BitVec.toInt_srem]
  change a.val.tmod b.val = a.val % b.val
  exact ht

private lemma i32_shl8_or_byte (b0 b1 : Std.I32)
    (h0 : 0 ≤ b0.val ∧ b0.val ≤ 255) (h1 : 0 ≤ b1.val ∧ b1.val ≤ 255) :
    ∃ s w : Std.I32,
      Pion.I32.shl b0 8#i32 = ok s ∧
      Pion.I32.bor s b1 = w ∧
      w.val = b0.val * 256 + b1.val := by
  have hb0n : (b0.bv.toNat : Int) = b0.val := i32_bv_toNat_of_nonneg b0 h0.1
  have hb1n : (b1.bv.toNat : Int) = b1.val := i32_bv_toNat_of_nonneg b1 h1.1
  have hshl : Pion.I32.shl b0 8#i32 = ok ⟨b0.bv <<< 8⟩ := by
    unfold Pion.I32.shl
    have hc0 : (0 : Int) ≤ (8#i32 : Std.I32).val := by decide
    have hc32 : (8#i32 : Std.I32).val < 32 := by decide
    have hc8 : ((8#i32 : Std.I32).val).toNat = 8 := by decide
    simp only [hc0, hc32, and_self, ↓reduceIte, hc8]
  set s : Std.I32 := ⟨b0.bv <<< 8⟩
  have hsn : s.bv.toNat = b0.bv.toNat * 256 := by
    change (b0.bv <<< 8).toNat = b0.bv.toNat * 256
    rw [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq]
    exact Nat.mod_eq_of_lt (by omega)
  set w : Std.I32 := Pion.I32.bor s b1
  have hwn : w.bv.toNat = b0.bv.toNat * 256 + b1.bv.toNat := by
    change (s.bv ||| b1.bv).toNat = b0.bv.toNat * 256 + b1.bv.toNat
    rw [BitVec.toNat_or, hsn]
    apply Nat.eq_of_testBit_eq
    intro i
    rw [Nat.testBit_or]
    have hmul : (b0.bv.toNat * 256).testBit i = if i < 8 then false else b0.bv.toNat.testBit (i - 8) := by
      have h256 : b0.bv.toNat * 256 = b0.bv.toNat <<< 8 := by rw [Nat.shiftLeft_eq]
      rw [h256, Nat.testBit_shiftLeft]
      by_cases hi : i < 8
      · have : ¬ (8 ≤ i) := by omega
        simp [hi, this]
      · have : 8 ≤ i := by omega
        simp [hi, this]
    rw [hmul]
    by_cases hi : i < 8
    · simp only [hi, ↓reduceIte, Bool.false_or]
      rw [Nat.testBit_eq_decide_div_mod_eq, Nat.testBit_eq_decide_div_mod_eq]
      have hpow : 2 ^ 8 = 2 ^ (8 - i) * 2 ^ i := by rw [← Nat.pow_add]; congr 1; omega
      have hpos : 0 < 2 ^ i := Nat.two_pow_pos i
      have hdiv : (b0.bv.toNat * 256 + b1.bv.toNat) / 2 ^ i = b0.bv.toNat * 2 ^ (8 - i) + b1.bv.toNat / 2 ^ i := by
        change (b0.bv.toNat * 2 ^ 8 + b1.bv.toNat) / 2 ^ i = _
        rw [hpow, ← Nat.mul_assoc, Nat.add_comm, Nat.add_mul_div_right _ _ hpos, Nat.add_comm]
      have heven : 2 ∣ 2 ^ (8 - i) := by
        refine ⟨2 ^ (8 - i - 1), ?_⟩
        conv => lhs; rw [show 8 - i = (8 - i - 1) + 1 by omega, Nat.pow_succ, Nat.mul_comm]
      rcases heven with ⟨q, hq⟩
      rw [hdiv, hq]
      have hmod : (b0.bv.toNat * (2 * q) + b1.bv.toNat / 2 ^ i) % 2 = (b1.bv.toNat / 2 ^ i) % 2 := by
        have hre : b0.bv.toNat * (2 * q) = 2 * (b0.bv.toNat * q) := by
          rw [← Nat.mul_assoc, Nat.mul_comm b0.bv.toNat 2, Nat.mul_assoc]
        rw [hre, Nat.add_comm, Nat.add_mul_mod_self_left]
      rw [hmod]
    · simp only [hi, ↓reduceIte]
      have hlt : b1.bv.toNat.testBit i = false := by
        apply Nat.testBit_lt_two_pow
        have hle : 2 ^ 8 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
        omega
      rw [hlt, Bool.or_false, Nat.testBit_eq_decide_div_mod_eq, Nat.testBit_eq_decide_div_mod_eq]
      have hpow : 2 ^ i = 2 ^ 8 * 2 ^ (i - 8) := by rw [← Nat.pow_add]; congr 1; omega
      have hdiv1 : (b0.bv.toNat * 256 + b1.bv.toNat) / 2 ^ 8 = b0.bv.toNat := by omega
      rw [hpow, ← Nat.div_div_eq_div_mul, hdiv1]
  have hwv : w.val = (w.bv.toNat : Int) := i32_val_of_bv_toNat_lt w (by rw [hwn]; omega)
  exact ⟨s, w, hshl, rfl, by omega⟩

private lemma i32_shr8_nonneg (x : Std.I32) (h0 : 0 ≤ x.val) (_hhi : x.val ≤ 65535) :
    ∃ r : Std.I32, Pion.I32.shr x 8#i32 = ok r ∧ r.val = x.val / 256 := by
  have hxnat : (x.bv.toNat : Int) = x.val := i32_bv_toNat_of_nonneg x h0
  have hshr : Pion.I32.shr x 8#i32 = ok ⟨BitVec.sshiftRight x.bv 8⟩ := by
    unfold Pion.I32.shr
    have hc0 : (0 : Int) ≤ (8#i32 : Std.I32).val := by decide
    have hc32 : (8#i32 : Std.I32).val < 32 := by decide
    have hc8 : ((8#i32 : Std.I32).val).toNat = 8 := by decide
    simp only [hc0, hc32, and_self, ↓reduceIte, hc8]
  set r : Std.I32 := ⟨BitVec.sshiftRight x.bv 8⟩
  have hrval : r.val = x.val / 256 := by
    change (BitVec.sshiftRight x.bv 8).toInt = x.bv.toInt / 256
    rw [BitVec.toInt_sshiftRight, Int.shiftRight_eq_div_pow]
    rfl
  exact ⟨r, hshr, hrval⟩

/-- Theorem 20: `kanji_value` always succeeds and returns either `-1` or a 13-bit Kanji value in `[0, 8191]`. -/
theorem kanji_value_range (b0 b1 : Std.I32) :
    ∃ r : Std.I32, kanji_value b0 b1 = ok r ∧ (r.val = -1 ∨ (0 ≤ r.val ∧ r.val ≤ 8191)) := by
  unfold kanji_value
  split_ifs with h1 h2
  · exact ⟨(-1)#i32, rfl, Or.inl rfl⟩
  · exact ⟨(-1)#i32, rfl, Or.inl rfl⟩
  · simp only [Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq, not_or] at h1 h2
    have hb0 : 0 ≤ b0.val ∧ b0.val ≤ 255 := by
      have ha : ¬ (b0.val < 0) := h1.1.1.1
      have hb : ¬ (b0.val > 255) := h1.1.1.2
      omega
    have hb1 : 64 ≤ b1.val ∧ b1.val ≤ 252 := by
      have ha : ¬ (b1.val < 64) := h2.1.1
      have hb : ¬ (b1.val > 252) := h2.2
      omega
    obtain ⟨s, w, hshl, hbor, hwv⟩ := i32_shl8_or_byte b0 b1 hb0 (by omega)
    rw [hshl, result_bind_ok']
    dsimp only
    rw [hbor]
    split_ifs with hr1 hr2
    · simp only [Bool.and_eq_true, decide_eq_true_eq] at hr1
      have hw1 : (33088 : Int) ≤ w.val := hr1.1
      have hw2 : w.val ≤ (40956 : Int) := hr1.2
      have c33088 : (33088#i32 : Std.I32).val = 33088 := rfl
      have c192 : (192#i32 : Std.I32).val = 192 := rfl
      have hdiff := i32_sub_val' w 33088#i32 (by omega) (by omega)
      obtain ⟨q, hq, hqv⟩ := i32_shr8_nonneg (Pion.I32.sub w 33088#i32) (by omega) (by omega)
      rw [hq, result_bind_ok']
      have hband := i32_band_255_nonneg (Pion.I32.sub w 33088#i32) (by omega)
      have hmul : (Pion.I32.mul q 192#i32).val = q.val * 192 := by
        have h := i32_mul_val' q 192#i32 (by rw [c192]; omega) (by rw [c192]; omega)
        rw [c192] at h; exact h
      have hadd := i32_add_val' (Pion.I32.mul q 192#i32) (Pion.I32.band (Pion.I32.sub w 33088#i32) 255#i32) (by omega) (by omega)
      exact ⟨_, rfl, Or.inr ⟨by omega, by omega⟩⟩
    · simp only [Bool.and_eq_true, decide_eq_true_eq] at hr2
      have hw1 : (57408 : Int) ≤ w.val := hr2.1
      have hw2 : w.val ≤ (60351 : Int) := hr2.2
      have c49472 : (49472#i32 : Std.I32).val = 49472 := rfl
      have c192 : (192#i32 : Std.I32).val = 192 := rfl
      have hdiff := i32_sub_val' w 49472#i32 (by omega) (by omega)
      obtain ⟨q, hq, hqv⟩ := i32_shr8_nonneg (Pion.I32.sub w 49472#i32) (by omega) (by omega)
      rw [hq, result_bind_ok']
      have hband := i32_band_255_nonneg (Pion.I32.sub w 49472#i32) (by omega)
      have hmul : (Pion.I32.mul q 192#i32).val = q.val * 192 := by
        have h := i32_mul_val' q 192#i32 (by rw [c192]; omega) (by rw [c192]; omega)
        rw [c192] at h; exact h
      have hadd := i32_add_val' (Pion.I32.mul q 192#i32) (Pion.I32.band (Pion.I32.sub w 49472#i32) 255#i32) (by omega) (by omega)
      exact ⟨_, rfl, Or.inr ⟨by omega, by omega⟩⟩
    · exact ⟨(-1)#i32, rfl, Or.inl rfl⟩

/-- Theorem 21: `kanji_from_value` always succeeds and returns `-1` or a valid Shift-JIS QR Kanji word. -/
theorem kanji_from_value_range (kv : Std.I32) :
    ∃ w : Std.I32, kanji_from_value kv = ok w ∧
      (w.val = -1 ∨
       (((33088 ≤ w.val ∧ w.val ≤ 40956) ∨ (57408 ≤ w.val ∧ w.val ≤ 60351)) ∧
        64 ≤ w.val % 256 ∧ w.val % 256 ≤ 252 ∧ w.val % 256 ≠ 127)) := by
  unfold kanji_from_value
  by_cases h1 : ((decide (kv < 0#i32)) || (decide (kv > 8191#i32))) = true
  · simp only [h1, ↓reduceIte]
    exact ⟨(-1)#i32, rfl, Or.inl rfl⟩
  · simp only [h1]
    simp only [Bool.or_eq_true, decide_eq_true_eq, not_or] at h1
    have hkv : 0 ≤ kv.val ∧ kv.val ≤ 8191 := by
      have ha : ¬ (kv.val < 0) := h1.1
      have hb : ¬ (kv.val > 8191) := h1.2
      omega
    obtain ⟨hi, hhi, hhiv⟩ := i32_div_nonneg' kv 192#i32 hkv.1 (by decide)
    obtain ⟨lo, hlo, hlov⟩ := i32_rem_nonneg' kv 192#i32 hkv.1 (by decide)
    rw [hhi, result_bind_ok', hlo, result_bind_ok']
    change hi.val = kv.val / 192 at hhiv
    change lo.val = kv.val % 192 at hlov
    by_cases hbad : ((decide (lo > 188#i32)) || (lo == 63#i32)) = true
    · simp only [hbad, ↓reduceIte]
      exact ⟨(-1)#i32, rfl, Or.inl rfl⟩
    · simp only [hbad]
      simp only [Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq, not_or] at hbad
      have hlo_le : lo.val ≤ 188 := by have : ¬ (lo.val > 188) := hbad.1; omega
      have hlo_ne : lo.val ≠ 63 := fun h => hbad.2 (IScalar.eq_of_val_eq h)
      have c64 : (64#i32 : Std.I32).val = 64 := rfl
      have c129 : (129#i32 : Std.I32).val = 129 := rfl
      have c193 : (193#i32 : Std.I32).val = 193 := rfl
      have hb1 : (Pion.I32.add 64#i32 lo).val = 64 + lo.val := by
        have h := i32_add_val' 64#i32 lo (by omega) (by omega); omega
      by_cases hhi1 : hi ≤ 30#i32
      · simp only [hhi1, ↓reduceIte]
        have hhi_le : hi.val ≤ 30 := hhi1
        have hb0 : (Pion.I32.add 129#i32 hi).val = 129 + hi.val := by
          have h := i32_add_val' 129#i32 hi (by omega) (by omega); omega
        obtain ⟨s, w, hshl, hbor, hwv⟩ := i32_shl8_or_byte (Pion.I32.add 129#i32 hi) (Pion.I32.add 64#i32 lo) (by omega) (by omega)
        rw [hshl, result_bind_ok', hbor]
        exact ⟨w, rfl, Or.inr ⟨Or.inl ⟨by omega, by omega⟩, by omega, by omega, by omega⟩⟩
      · simp only [hhi1, ↓reduceIte]
        have hhi_gt : ¬ (hi.val ≤ 30) := hhi1
        by_cases hhi2 : hi ≤ 42#i32
        · simp only [hhi2, ↓reduceIte]
          have hhi_le : hi.val ≤ 42 := hhi2
          have hb0 : (Pion.I32.add 193#i32 hi).val = 193 + hi.val := by
            have h := i32_add_val' 193#i32 hi (by omega) (by omega); omega
          by_cases hhi3 : ((Pion.I32.add 193#i32 hi == 235#i32) && (decide (Pion.I32.add 64#i32 lo > 191#i32))) = true
          · simp only [hhi3, ↓reduceIte]
            exact ⟨(-1)#i32, rfl, Or.inl rfl⟩
          · simp only [hhi3]
            simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq, not_and] at hhi3
            have hcap : (Pion.I32.add 193#i32 hi).val = 235 → (Pion.I32.add 64#i32 lo).val ≤ 191 := by
              intro h235
              have hnot := hhi3 (IScalar.eq_of_val_eq h235)
              change ¬ ((Pion.I32.add 64#i32 lo).val > 191) at hnot
              omega
            obtain ⟨s, w, hshl, hbor, hwv⟩ := i32_shl8_or_byte (Pion.I32.add 193#i32 hi) (Pion.I32.add 64#i32 lo) (by omega) (by omega)
            rw [hshl, result_bind_ok', hbor]
            exact ⟨w, rfl, Or.inr ⟨Or.inr ⟨by omega, by omega⟩, by omega, by omega, by omega⟩⟩
        · simp only [hhi2, ↓reduceIte]
          exact ⟨(-1)#i32, rfl, Or.inl rfl⟩

/-- Theorem 22: Exact Shift-JIS QR Kanji encode-decode roundtrip:
    whenever `kanji_value b0 b1 = ok kv` with `kv ≥ 0`, `kanji_from_value kv = ok (b0 * 256 + b1)`. -/
theorem kanji_encode_decode_roundtrip (b0 b1 kv : Std.I32)
    (hkv : kanji_value b0 b1 = ok kv) (hnonneg : 0 ≤ kv.val) :
    ∃ w : Std.I32, kanji_from_value kv = ok w ∧ w.val = b0.val * 256 + b1.val := by
  unfold kanji_value at hkv
  split_ifs at hkv with h1 h2
  · have : kv = (-1)#i32 := by simpa using hkv.symm
    subst this; change 0 ≤ (-1 : Int) at hnonneg; omega
  · have : kv = (-1)#i32 := by simpa using hkv.symm
    subst this; change 0 ≤ (-1 : Int) at hnonneg; omega
  · simp only [Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq, not_or] at h1 h2
    have hb0 : 0 ≤ b0.val ∧ b0.val ≤ 255 := by
      have ha : ¬ (b0.val < 0) := h1.1.1.1
      have hb : ¬ (b0.val > 255) := h1.1.1.2
      omega
    have hb1 : 64 ≤ b1.val ∧ b1.val ≤ 252 := by
      have ha : ¬ (b1.val < 64) := h2.1.1
      have hb : ¬ (b1.val > 252) := h2.2
      omega
    have hb1_ne127 : b1.val ≠ 127 := fun h => h2.1.2 (IScalar.eq_of_val_eq h)
    obtain ⟨s, w0, hshl, hbor, hw0v⟩ := i32_shl8_or_byte b0 b1 hb0 (by omega)
    rw [hshl, result_bind_ok'] at hkv
    dsimp only at hkv
    rw [hbor] at hkv
    have c64 : (64#i32 : Std.I32).val = 64 := rfl
    have c129 : (129#i32 : Std.I32).val = 129 := rfl
    have c192 : (192#i32 : Std.I32).val = 192 := rfl
    have c193 : (193#i32 : Std.I32).val = 193 := rfl
    split_ifs at hkv with hr1 hr2
    · simp only [Bool.and_eq_true, decide_eq_true_eq] at hr1
      have hw1 : (33088 : Int) ≤ w0.val := hr1.1
      have hw2 : w0.val ≤ (40956 : Int) := hr1.2
      have c33088 : (33088#i32 : Std.I32).val = 33088 := rfl
      have hdiff := i32_sub_val' w0 33088#i32 (by omega) (by omega)
      obtain ⟨q, hq, hqv⟩ := i32_shr8_nonneg (Pion.I32.sub w0 33088#i32) (by omega) (by omega)
      rw [hq, result_bind_ok'] at hkv
      have hband := i32_band_255_nonneg (Pion.I32.sub w0 33088#i32) (by omega)
      have hmul : (Pion.I32.mul q 192#i32).val = q.val * 192 := by
        have h := i32_mul_val' q 192#i32 (by rw [c192]; omega) (by rw [c192]; omega)
        rw [c192] at h; exact h
      have hadd := i32_add_val' (Pion.I32.mul q 192#i32) (Pion.I32.band (Pion.I32.sub w0 33088#i32) 255#i32) (by omega) (by omega)
      have hkveq : kv = Pion.I32.add (Pion.I32.mul q 192#i32) (Pion.I32.band (Pion.I32.sub w0 33088#i32) 255#i32) := by
        simpa using hkv.symm
      have hkvval : kv.val = (b0.val - 129) * 192 + (b1.val - 64) := by rw [hkveq]; omega
      unfold kanji_from_value
      have hnotout : ¬ (((decide (kv < 0#i32)) || (decide (kv > 8191#i32))) = true) := by
        simp only [Bool.or_eq_true, decide_eq_true_eq, not_or]
        exact ⟨by change ¬ (kv.val < 0); omega, by change ¬ (kv.val > 8191); omega⟩
      simp only [hnotout]
      obtain ⟨hi, hhi, hhiv⟩ := i32_div_nonneg' kv 192#i32 (by omega) (by decide)
      obtain ⟨lo, hlo, hlov⟩ := i32_rem_nonneg' kv 192#i32 (by omega) (by decide)
      rw [hhi, result_bind_ok', hlo, result_bind_ok']
      change hi.val = kv.val / 192 at hhiv
      change lo.val = kv.val % 192 at hlov
      have hnotbad : ¬ (((decide (lo > 188#i32)) || (lo == 63#i32)) = true) := by
        simp only [Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq, not_or]
        exact ⟨by change ¬ (lo.val > 188); omega, fun h => by have := congrArg IScalar.val h; change lo.val = 63 at this; omega⟩
      simp only [hnotbad]
      have hhi_le : hi ≤ 30#i32 := by change hi.val ≤ 30; omega
      simp only [hhi_le, ↓reduceIte]
      have hb1' := i32_add_val' 64#i32 lo (by omega) (by omega)
      have hb0' := i32_add_val' 129#i32 hi (by omega) (by omega)
      obtain ⟨s2, w2, hshl2, hbor2, hw2v⟩ := i32_shl8_or_byte (Pion.I32.add 129#i32 hi) (Pion.I32.add 64#i32 lo) (by omega) (by omega)
      rw [hshl2, result_bind_ok', hbor2]
      exact ⟨w2, rfl, by omega⟩
    · simp only [Bool.and_eq_true, decide_eq_true_eq] at hr2
      have hw1 : (57408 : Int) ≤ w0.val := hr2.1
      have hw2 : w0.val ≤ (60351 : Int) := hr2.2
      have c49472 : (49472#i32 : Std.I32).val = 49472 := rfl
      have hdiff := i32_sub_val' w0 49472#i32 (by omega) (by omega)
      obtain ⟨q, hq, hqv⟩ := i32_shr8_nonneg (Pion.I32.sub w0 49472#i32) (by omega) (by omega)
      rw [hq, result_bind_ok'] at hkv
      have hband := i32_band_255_nonneg (Pion.I32.sub w0 49472#i32) (by omega)
      have hmul : (Pion.I32.mul q 192#i32).val = q.val * 192 := by
        have h := i32_mul_val' q 192#i32 (by rw [c192]; omega) (by rw [c192]; omega)
        rw [c192] at h; exact h
      have hadd := i32_add_val' (Pion.I32.mul q 192#i32) (Pion.I32.band (Pion.I32.sub w0 49472#i32) 255#i32) (by omega) (by omega)
      have hkveq : kv = Pion.I32.add (Pion.I32.mul q 192#i32) (Pion.I32.band (Pion.I32.sub w0 49472#i32) 255#i32) := by
        simpa using hkv.symm
      have hkvval : kv.val = (b0.val - 193) * 192 + (b1.val - 64) := by rw [hkveq]; omega
      unfold kanji_from_value
      have hnotout : ¬ (((decide (kv < 0#i32)) || (decide (kv > 8191#i32))) = true) := by
        simp only [Bool.or_eq_true, decide_eq_true_eq, not_or]
        exact ⟨by change ¬ (kv.val < 0); omega, by change ¬ (kv.val > 8191); omega⟩
      simp only [hnotout]
      obtain ⟨hi, hhi, hhiv⟩ := i32_div_nonneg' kv 192#i32 (by omega) (by decide)
      obtain ⟨lo, hlo, hlov⟩ := i32_rem_nonneg' kv 192#i32 (by omega) (by decide)
      rw [hhi, result_bind_ok', hlo, result_bind_ok']
      change hi.val = kv.val / 192 at hhiv
      change lo.val = kv.val % 192 at hlov
      have hnotbad : ¬ (((decide (lo > 188#i32)) || (lo == 63#i32)) = true) := by
        simp only [Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq, not_or]
        exact ⟨by change ¬ (lo.val > 188); omega, fun h => by have := congrArg IScalar.val h; change lo.val = 63 at this; omega⟩
      simp only [hnotbad]
      have hnot30 : ¬ (hi ≤ 30#i32) := by change ¬ (hi.val ≤ 30); omega
      have hle42 : hi ≤ 42#i32 := by change hi.val ≤ 42; omega
      simp only [hnot30, hle42, ↓reduceIte]
      have hb1' := i32_add_val' 64#i32 lo (by omega) (by omega)
      have hb0' := i32_add_val' 193#i32 hi (by omega) (by omega)
      have hnoteb : ¬ (((Pion.I32.add 193#i32 hi == 235#i32) && (decide (Pion.I32.add 64#i32 lo > 191#i32))) = true) := by
        simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq, not_and]
        intro h235
        have h235v : (Pion.I32.add 193#i32 hi).val = 235 := congrArg IScalar.val h235
        change ¬ ((Pion.I32.add 64#i32 lo).val > 191)
        omega
      simp only [hnoteb]
      obtain ⟨s2, w2, hshl2, hbor2, hw2v⟩ := i32_shl8_or_byte (Pion.I32.add 193#i32 hi) (Pion.I32.add 64#i32 lo) (by omega) (by omega)
      rw [hshl2, result_bind_ok', hbor2]
      exact ⟨w2, rfl, by omega⟩
    · have : kv = (-1)#i32 := by simpa using hkv.symm
      subst this; change 0 ≤ (-1 : Int) at hnonneg; omega

end QrcodeProofs
