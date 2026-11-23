import CborProofs.Core

open Aeneas Aeneas.Std Result Pion cbor

namespace CborProofs

private lemma i64_shl_i32_const (x : Std.I64) (k : Std.I32) (h0 : 0 ≤ k.val) (h64 : k.val < 64) :
    Pion.I64.shl_i32 x k = ok (⟨x.bv <<< k.val.toNat⟩ : Std.I64) := by
  unfold Pion.I64.shl_i32
  have hc : 0 ≤ k.val ∧ k.val < 64 := ⟨h0, h64⟩
  simp only [hc, and_self, ↓reduceIte]

private lemma i64_shr_i32_const (x : Std.I64) (k : Std.I32) (h0 : 0 ≤ k.val) (h64 : k.val < 64) :
    Pion.I64.shr_i32 x k = ok (⟨x.bv.sshiftRight k.val.toNat⟩ : Std.I64) := by
  unfold Pion.I64.shr_i32
  have hc : 0 ≤ k.val ∧ k.val < 64 := ⟨h0, h64⟩
  simp only [hc, and_self, ↓reduceIte]

private lemma i32_shl_const (x : Std.I32) (k : Std.I32) (h0 : 0 ≤ k.val) (h32 : k.val < 32) :
    Pion.I32.shl x k = ok (⟨x.bv <<< k.val.toNat⟩ : Std.I32) := by
  unfold Pion.I32.shl
  have hc : 0 ≤ k.val ∧ k.val < 32 := ⟨h0, h32⟩
  simp only [hc, and_self, ↓reduceIte]

private lemma i32_shr_const (x : Std.I32) (k : Std.I32) (h0 : 0 ≤ k.val) (h32 : k.val < 32) :
    Pion.I32.shr x k = ok (⟨x.bv.sshiftRight k.val.toNat⟩ : Std.I32) := by
  unfold Pion.I32.shr
  have hc : 0 ≤ k.val ∧ k.val < 32 := ⟨h0, h32⟩
  simp only [hc, and_self, ↓reduceIte]

private lemma i32_sub_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  simp only [Pion.I32.sub, Std.I32.wrapping_sub, IScalar.wrapping_sub, IScalar.val, BitVec.toInt_sub]
  have hpow : (2 : Nat) ^ IScalarTy.I32.numBits = 2 ^ 32 := rfl
  rw [hpow]
  change (a.val - b.val).bmod (2 ^ 32) = a.val - b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

private lemma i32_add_val (a b : Std.I32)
    (hlo : -(2147483648 : Int) ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  simp only [Pion.I32.add, Std.I32.wrapping_add, IScalar.wrapping_add, IScalar.val, BitVec.toInt_add]
  have hpow : (2 : Nat) ^ IScalarTy.I32.numBits = 2 ^ 32 := rfl
  rw [hpow]
  change (a.val + b.val).bmod (2 ^ 32) = a.val + b.val
  rw [Int.bmod_eq_of_le] <;> norm_num <;> omega

/-- RFC 8949 §4.2.1: ANY binary64 NaN (`exp = 0x7FF`, `frac != 0`) canonicalizes to `0x7E00` in float16. -/
theorem double_bits_to_float16_any_nan_canonical (bits : Std.I64)
    (hexp : Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64) = 2047#i32)
    (hfrac : Pion.I64.band bits 4503599627370495#i64 ≠ 0#i64) :
    double_bits_to_float16_exact bits = ok (some 32256#i32) := by
  unfold double_bits_to_float16_exact
  rw [i64_shr_i32_const bits 63#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shr_i32_const bits 52#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h52 : (52#i32).val.toNat = 52 := by norm_num
  rw [h52]
  simp only [hexp, hfrac, ↓reduceIte]

/-- `double_bits_to_float16_exact` never silently loses precision on normal-range values with non-zero low 42 mantissa bits. -/
theorem double_bits_to_float16_rejects_excess_precision (bits : Std.I64)
    (hexp_lo : 1009 ≤ (Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)).val)
    (hexp_hi : (Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)).val ≤ 1038)
    (hlow : Pion.I64.band (Pion.I64.band bits 4503599627370495#i64) 4398046511103#i64 ≠ 0#i64) :
    double_bits_to_float16_exact bits = ok none := by
  unfold double_bits_to_float16_exact
  rw [i64_shr_i32_const bits 63#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shr_i32_const bits 52#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h52 : (52#i32).val.toNat = 52 := by norm_num
  rw [h52]
  set exp := Pion.I64.to_int (Pion.I64.band (⟨bits.bv.sshiftRight 52⟩ : Std.I64) 2047#i64)
  have hne2047 : exp ≠ 2047#i32 := fun h => by
    have := (iscalar_eq_iff _ _).mp h; norm_num at this; omega
  have hne0 : (exp == 0#i32) = false := by
    apply beq_false_of_ne; intro h
    have := (iscalar_eq_iff _ _).mp h; norm_num at this; omega
  have he_val : (Pion.I32.sub exp 1023#i32).val = exp.val - 1023 := by
    have h1023 : (1023#i32).val = 1023 := by norm_num
    rw [i32_sub_val exp 1023#i32 (by omega) (by omega), h1023]
  have hrange : ((decide (Pion.I32.sub exp 1023#i32 ≥ (-14)#i32)) &&
      (decide (Pion.I32.sub exp 1023#i32 ≤ 15#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff, he_val]
    norm_num; omega
  simp only [hne2047, hne0, Bool.false_and, Bool.false_eq_true, hrange, ↓reduceIte]
  split_ifs with hc
  · rfl
  · exact absurd hlow hc

/-- Universal IEEE-754 binary16 normal encoding: for EVERY normal binary16 (`0 <= h < 65536`, `1 <= exp <= 30`),
    `float16_to_double_bits` succeeds without overflow and maps `exp` to `exp + 1008` in bits `[52..62]`
    with zero low 42 mantissa bits. -/
theorem float16_to_double_bits_normal_exact (h : Std.I32)
    (hh0 : 0 ≤ h.val) (hh1 : h.val ≤ 65535)
    (hexp1 : 1 ≤ (Pion.I32.band (⟨h.bv.sshiftRight 10⟩ : Std.I32) 31#i32).val)
    (hexp30 : (Pion.I32.band (⟨h.bv.sshiftRight 10⟩ : Std.I32) 31#i32).val ≤ 30) :
    ∃ d : Std.I64, float16_to_double_bits h = ok d ∧
      d.bv =
        ((BitVec.ofInt 64 (Pion.I32.band (⟨h.bv.sshiftRight 15⟩ : Std.I32) 1#i32).val) <<< 63) |||
        ((BitVec.ofInt 64 ((Pion.I32.band (⟨h.bv.sshiftRight 10⟩ : Std.I32) 31#i32).val + 1008)) <<< 52) |||
        ((BitVec.ofInt 64 (Pion.I32.band h 1023#i32).val) <<< 42) := by
  have hh_mask : Pion.I32.band h 65535#i32 = h := by
    unfold Pion.I32.band
    cases h with | mk hv =>
    change (⟨hv &&& (65535#i32).bv⟩ : Std.I32) = ⟨hv⟩
    congr 1
    apply BitVec.eq_of_toNat_eq
    have hpow : (2 : Nat) ^ IScalarTy.I32.numBits = 2 ^ 32 := rfl
    have hval : (⟨hv⟩ : Std.I32).val = hv.toInt := rfl
    rw [hval] at hh0 hh1
    have hv_lt : hv.toNat < 2 ^ 32 := by have := hv.isLt; rw [hpow] at this; exact this
    have hv_nat : hv.toNat = hv.toInt.toNat := by
      have hti := BitVec.toInt_eq_toNat_cond hv
      rw [hpow] at hti
      have hlt : 2 * hv.toNat < 2 ^ 32 := by
        by_contra hge; push Not at hge
        rw [ite_eq_right (by omega)] at hti
        omega
      rw [ite_eq_left hlt] at hti; omega
    rw [BitVec.toNat_and]
    have h65535 : (65535#i32).bv.toNat = 65535 := by norm_num
    rw [h65535]
    have hlt : hv.toNat < 65536 := by omega
    have hmod : hv.toNat &&& 65535 = hv.toNat % 65536 := by
      have : (65535 : Nat) = 2 ^ 16 - 1 := by norm_num
      rw [this, Nat.and_two_pow_sub_one_eq_mod]
    rw [hmod, Nat.mod_eq_of_lt hlt]
  unfold float16_to_double_bits
  rw [hh_mask]
  dsimp only
  rw [i32_shr_const h 15#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i32_shr_const h 10#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h15n : (15#i32).val.toNat = 15 := by norm_num
  have h10n : (10#i32).val.toNat = 10 := by norm_num
  rw [h15n, h10n]
  set exp := Pion.I32.band (⟨h.bv.sshiftRight 10⟩ : Std.I32) 31#i32
  have hne0 : exp ≠ 0#i32 := fun e => by have := (iscalar_eq_iff _ _).mp e; norm_num at this; omega
  have hne31 : exp ≠ 31#i32 := fun e => by have := (iscalar_eq_iff _ _).mp e; norm_num at this; omega
  simp only [hne0, hne31, ↓reduceIte]
  rw [i64_shl_i32_const _ 42#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shl_i32_const _ 63#i32 (by norm_num) (by norm_num), result_bind_ok]
  rw [i64_shl_i32_const _ 52#i32 (by norm_num) (by norm_num), result_bind_ok]
  have h42n : (42#i32).val.toNat = 42 := by norm_num
  have h63n : (63#i32).val.toNat = 63 := by norm_num
  have h52n : (52#i32).val.toNat = 52 := by norm_num
  rw [h42n, h63n, h52n]
  have he_add : (Pion.I32.add exp 1008#i32).val = exp.val + 1008 := by
    have h1008 : (1008#i32).val = 1008 := by norm_num
    rw [i32_add_val exp 1008#i32 (by omega) (by omega), h1008]
  refine ⟨_, rfl, ?_⟩
  unfold Pion.I64.bor Pion.I32.to_int64
  change ((BitVec.ofInt 64 (Pion.I32.band (⟨h.bv.sshiftRight 15⟩ : Std.I32) 1#i32).val) <<< 63 |||
      (BitVec.ofInt 64 (Pion.I32.add exp 1008#i32).val) <<< 52) |||
      (BitVec.ofInt 64 (Pion.I32.band h 1023#i32).val) <<< 42 = _
  rw [he_add]

end CborProofs
