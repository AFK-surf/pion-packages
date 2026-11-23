import GraphProofs.Core

open Aeneas Aeneas.Std Result Pion graph

namespace GraphProofs

/-- Exact mathematical value of a two's-complement 128-bit signed integer `(hi, lo)`. -/
def val128 (hi : Std.I64) (lo : Std.U64) : Int :=
  hi.val * 18446744073709551616 + (lo.val : Int)

private lemma i64_min_expr_val :
    (Pion.I64.sub (-9223372036854775807)#i64 1#i64).val = -9223372036854775808 := by
  have hneg := i64_neg_max_val
  have h1 : (1#i64).val = 1 := by norm_num
  rw [i64_sub_val (-9223372036854775807)#i64 1#i64 (by omega) (by omega), hneg, h1]; omega

/-- Exact characterization of `checked_add_i64` returning `Some(s)`. -/
theorem checked_add_i64_some_iff (a b s : Std.I64) :
    checked_add_i64 a b = ok (some s) ↔
      -(9223372036854775808 : Int) ≤ a.val + b.val ∧
      a.val + b.val ≤ 9223372036854775807 ∧
      s.val = a.val + b.val := by
  have ha := i64_bounds a
  have hb := i64_bounds b
  have hmax := i64_max_val
  have hmin := i64_min_expr_val
  have h0 : (0#i64).val = 0 := by norm_num
  unfold checked_add_i64
  set cond1 := (decide (b > 0#i64)) && (decide (a > Pion.I64.sub 9223372036854775807#i64 b))
  set cond2 := (decide (b < 0#i64)) && (decide (a < Pion.I64.sub (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b))
  by_cases hpos : 0 < b.val
  · have hsub : (Pion.I64.sub 9223372036854775807#i64 b).val = 9223372036854775807 - b.val := by
      rw [i64_sub_val _ b (by omega) (by omega), hmax]
    by_cases hov : a.val + b.val > 9223372036854775807
    · have c1 : cond1 = true := by
        simp only [cond1, Bool.and_eq_true, decide_eq_true_eq, iscalar_lt_iff, h0, hsub]; omega
      simp only [c1, ↓reduceIte]
      constructor
      · intro h; cases result_ok_inj h
      · intro h; omega
    · have c1 : cond1 = false := by
        simp only [cond1, Bool.and_eq_false_iff, decide_eq_false_iff_not, iscalar_lt_iff, h0, hsub]; omega
      have c2 : cond2 = false := by
        simp only [cond2, Bool.and_eq_false_iff, decide_eq_false_iff_not, iscalar_lt_iff, h0]; left; omega
      simp only [c1, c2, Bool.false_eq_true, ↓reduceIte]
      have hadd := i64_add_val a b (by omega) (by omega)
      constructor
      · intro h
        have hs : Pion.I64.add a b = s := Option.some.inj (result_ok_inj h)
        rw [← hs, hadd]; omega
      · rintro ⟨_, _, hs⟩
        exact congrArg (fun x => ok (some x)) ((iscalar_eq_iff (Pion.I64.add a b) s).mpr (by rw [hadd, hs]))
  · by_cases hneg : b.val < 0
    · have hsub : (Pion.I64.sub (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b).val =
          -9223372036854775808 - b.val := by
        rw [i64_sub_val _ b (by omega) (by omega), hmin]
      have c1 : cond1 = false := by
        simp only [cond1, Bool.and_eq_false_iff, decide_eq_false_iff_not, iscalar_lt_iff, h0]; left; omega
      by_cases hund : a.val + b.val < -9223372036854775808
      · have c2 : cond2 = true := by
          simp only [cond2, Bool.and_eq_true, decide_eq_true_eq, iscalar_lt_iff, h0, hsub]; omega
        simp only [c1, c2, Bool.false_eq_true, ↓reduceIte]
        constructor
        · intro h; cases result_ok_inj h
        · intro h; omega
      · have c2 : cond2 = false := by
          simp only [cond2, Bool.and_eq_false_iff, decide_eq_false_iff_not, iscalar_lt_iff, h0, hsub]; omega
        simp only [c1, c2, Bool.false_eq_true, ↓reduceIte]
        have hadd := i64_add_val a b (by omega) (by omega)
        constructor
        · intro h
          have hs : Pion.I64.add a b = s := Option.some.inj (result_ok_inj h)
          rw [← hs, hadd]; omega
        · rintro ⟨_, _, hs⟩
          exact congrArg (fun x => ok (some x)) ((iscalar_eq_iff (Pion.I64.add a b) s).mpr (by rw [hadd, hs]))
    · have c1 : cond1 = false := by
        simp only [cond1, Bool.and_eq_false_iff, decide_eq_false_iff_not, iscalar_lt_iff, h0]; left; omega
      have c2 : cond2 = false := by
        simp only [cond2, Bool.and_eq_false_iff, decide_eq_false_iff_not, iscalar_lt_iff, h0]; left; omega
      simp only [c1, c2, Bool.false_eq_true, ↓reduceIte]
      have hadd := i64_add_val a b (by omega) (by omega)
      constructor
      · intro h
        have hs : Pion.I64.add a b = s := Option.some.inj (result_ok_inj h)
        rw [← hs, hadd]; omega
      · rintro ⟨_, _, hs⟩
        exact congrArg (fun x => ok (some x)) ((iscalar_eq_iff (Pion.I64.add a b) s).mpr (by rw [hadd, hs]))

/-- `fits_i64 hi lo = ok true` iff the 128-bit signed value `val128 hi lo` lies in `[MIN_I64, MAX_I64]`. -/
theorem fits_i64_iff_val128_range (hi : Std.I64) (lo : Std.U64) :
    fits_i64 hi lo = ok true ↔
      -(9223372036854775808 : Int) ≤ val128 hi lo ∧ val128 hi lo ≤ 9223372036854775807 := by
  have hlo := u64_bounds lo
  have h0 : (0#i64).val = 0 := by norm_num
  have hm1 : ((-1)#i64).val = -1 := by norm_num
  have hhalf := u64_half_max_val
  have hsign := u64_sign_bit_val
  unfold fits_i64 val128
  constructor
  · intro h
    have hb := result_ok_inj h
    simp only [Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq,
      iscalar_eq_iff, uscalar_le_iff, h0, hm1, hhalf, hsign] at hb
    rcases hb with ⟨hhi, hle⟩ | ⟨hhi, hge⟩ <;> omega
  · intro hrange
    congr 1
    simp only [Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq,
      iscalar_eq_iff, uscalar_le_iff, h0, hm1, hhalf, hsign]
    by_cases hhi0 : hi.val = 0
    · left; exact ⟨hhi0, by omega⟩
    · right; exact ⟨by omega, by omega⟩

private lemma i64_to_uint64_val (w : Std.I64) :
    ((Pion.I64.to_uint64 w).val : Int) =
      if w.val < 0 then w.val + 18446744073709551616 else w.val := by
  unfold Pion.I64.to_uint64
  have hti := BitVec.toInt_eq_toNat_cond w.bv
  have hpow : (2 : Nat) ^ 64 = 18446744073709551616 := by norm_num
  have hwlt : w.bv.toNat < 18446744073709551616 := by
    have := w.bv.isLt; rw [hpow] at this; exact this
  rw [hpow] at hti
  have hbv : (IScalar.hcast UScalarTy.U64 w).val = w.bv.toNat := by
    change (BitVec.signExtend 64 w.bv).toNat = w.bv.toNat
    rw [BitVec.signExtend_eq_setWidth_of_le w.bv (Nat.le_refl _), BitVec.setWidth_eq]
  rw [hbv]
  have hwval : w.val = w.bv.toInt := rfl
  rw [hwval]
  by_cases hlt : 2 * w.bv.toNat < 18446744073709551616
  · rw [ite_eq_left hlt] at hti
    rw [hti]; split_ifs <;> omega
  · rw [ite_eq_right hlt] at hti
    rw [hti]; split_ifs <;> omega

/-- Every `Int64` widened to 128-bit `(i64_sign_hi w, w.to_uint64())` has exact value `w.val` and satisfies `fits_i64`. -/
theorem sign_extend_i64_exact_and_fits (w : Std.I64) :
    val128 (if w.val < 0 then (-1)#i64 else 0#i64) (Pion.I64.to_uint64 w) = w.val ∧
    fits_i64 (if w.val < 0 then (-1)#i64 else 0#i64) (Pion.I64.to_uint64 w) = ok true := by
  have hw := i64_bounds w
  have hto := i64_to_uint64_val w
  have h0 : (0#i64).val = 0 := by norm_num
  have hm1 : ((-1)#i64).val = -1 := by norm_num
  have hval : val128 (if w.val < 0 then (-1)#i64 else 0#i64) (Pion.I64.to_uint64 w) = w.val := by
    unfold val128
    split_ifs at hto ⊢ with h <;> rw [hto]
    · rw [hm1]; omega
    · rw [h0]; omega
  exact ⟨hval, (fits_i64_iff_val128_range _ _).mpr (by rw [hval]; exact hw)⟩

/-- Exact carry conservation law for unsigned 64-bit addition in 128-bit Bellman-Ford. -/
theorem i128_add_carry_exact (u_lo w_lo : Std.U64) :
    ∃ c : Std.I64, i128_add_carry u_lo w_lo = ok c ∧
      (c.val = 0 ∨ c.val = 1) ∧
      ((Pion.U64.add u_lo w_lo).val : Int) + c.val * 18446744073709551616 =
        (u_lo.val : Int) + (w_lo.val : Int) := by
  have hu := u64_bounds u_lo
  have hw := u64_bounds w_lo
  have hsum : (Pion.U64.add u_lo w_lo).val = (u_lo.val + w_lo.val) % 18446744073709551616 := by
    simp only [Pion.U64.add, Std.U64.wrapping_add, UScalar.wrapping_add, UScalar.val, BitVec.toNat_add]
    have hpow : (2 : Nat) ^ UScalarTy.U64.numBits = 18446744073709551616 := by
      change (2 : Nat) ^ 64 = 18446744073709551616; norm_num
    rw [hpow]
  unfold i128_add_carry
  by_cases hov : u_lo.val + w_lo.val ≥ 18446744073709551616
  · have hlt : Pion.U64.add u_lo w_lo < u_lo := (uscalar_lt_iff _ _).mpr (by rw [hsum]; omega)
    simp only [hlt, ↓reduceIte]
    refine ⟨1#i64, rfl, Or.inr (by norm_num), ?_⟩
    have h1 : (1#i64).val = 1 := by norm_num
    rw [h1, hsum]; omega
  · have hge : ¬(Pion.U64.add u_lo w_lo < u_lo) := fun h => by
      have := (uscalar_lt_iff _ _).mp h; rw [hsum] at this; omega
    simp only [hge, ↓reduceIte]
    refine ⟨0#i64, rfl, Or.inl (by norm_num), ?_⟩
    have h0 : (0#i64).val = 0 := by norm_num
    rw [h0, hsum]; omega

/-- `i128_lt` is exact signed 128-bit strict `<` on `val128`. -/
theorem i128_lt_iff_val128 (a_hi : Std.I64) (a_lo : Std.U64) (b_hi : Std.I64) (b_lo : Std.U64) :
    i128_lt a_hi a_lo b_hi b_lo = ok (decide (val128 a_hi a_lo < val128 b_hi b_lo)) := by
  have ha := u64_bounds a_lo
  have hb := u64_bounds b_lo
  unfold i128_lt val128
  congr 1
  by_cases h : a_hi.val * 18446744073709551616 + (a_lo.val : Int) <
               b_hi.val * 18446744073709551616 + (b_lo.val : Int)
  · rw [decide_eq_true h]
    simp only [Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq,
      iscalar_lt_iff, iscalar_eq_iff, uscalar_lt_iff]
    by_cases hlt : a_hi.val < b_hi.val
    · left; exact hlt
    · right; exact ⟨by omega, by omega⟩
  · rw [decide_eq_false h]
    simp only [Bool.or_eq_false_iff, Bool.and_eq_false_iff, beq_eq_false_iff_ne, ne_eq,
      decide_eq_false_iff_not, iscalar_lt_iff, iscalar_eq_iff, uscalar_lt_iff]
    exact ⟨by omega, by by_cases heq : a_hi.val = b_hi.val <;> [right; left] <;> omega⟩

/-- Kruskal LSD Radix Sort key formula: `i64_to_radix_key w` equals `w.val + 2^63` exactly! -/
theorem i64_to_radix_key_val (w : Std.I64) :
    ∃ k : Std.U64, i64_to_radix_key w = ok k ∧
      (k.val : Int) = w.val + 9223372036854775808 := by
  unfold i64_to_radix_key
  refine ⟨Pion.U64.bxor (Pion.I64.to_uint64 w) 9223372036854775808#u64, rfl, ?_⟩
  have hto := i64_to_uint64_val w
  have hw := i64_bounds w
  set u := Pion.I64.to_uint64 w
  have hu_lt := u64_bounds u
  have hxor_nat : (Pion.U64.bxor u 9223372036854775808#u64).val =
      if u.val < 9223372036854775808 then u.val + 9223372036854775808
      else u.val - 9223372036854775808 := by
    unfold Pion.U64.bxor
    change (u.bv ^^^ (9223372036854775808#64 : BitVec 64)).toNat = _
    rw [BitVec.toNat_xor]
    have hs : (9223372036854775808#64 : BitVec 64).toNat = 2 ^ 63 := by
      rw [BitVec.toNat_ofNat]; norm_num
    rw [hs]
    have h263 : (2 : Nat) ^ 63 = 9223372036854775808 := by norm_num
    have hnat : u.bv.toNat = u.val := rfl
    rw [hnat]
    by_cases hlt : u.val < 9223372036854775808
    · rw [ite_eq_left hlt]
      have htest : u.val.testBit 63 = false := Nat.testBit_eq_false_of_lt (by omega)
      apply Nat.eq_of_testBit_eq; intro i
      rw [Nat.testBit_xor, Nat.testBit_two_pow]
      by_cases hi : i = 63
      · subst hi; simp [htest]
        have h1 : (u.val + 9223372036854775808) / 2 ^ 63 = 1 := by omega
        rw [Nat.testBit, Nat.shiftRight_eq_div_pow, h1]; decide
      · simp [Ne.symm hi]
        have hadd : (u.val + 2 ^ 63).testBit i = u.val.testBit i := by
          by_cases hlt63 : i < 63
          · rw [Nat.testBit, Nat.testBit, Nat.shiftRight_eq_div_pow, Nat.shiftRight_eq_div_pow]
            have hd : 2 ^ 63 = 2 ^ (63 - i) * 2 ^ i := by rw [← Nat.pow_add, Nat.sub_add_cancel (by omega)]
            have hd2 : 2 ^ (63 - i) = 2 * 2 ^ (62 - i) := by rw [← Nat.pow_succ']; congr 1; omega
            rw [hd, Nat.add_mul_div_right _ _ (Nat.two_pow_pos i), hd2]
            simp [Nat.add_mul_mod_self_left]
          · have hgt63 : 63 < i := by omega
            have hpow_ge : 2 ^ 64 ≤ 2 ^ i := Nat.pow_le_pow_right (by norm_num) (by omega)
            rw [Nat.testBit_eq_false_of_lt (by omega), Nat.testBit_eq_false_of_lt (by omega)]
        rw [← h263, hadd]
    · rw [ite_eq_right hlt]
      have hge : 9223372036854775808 ≤ u.val := by omega
      have htest : u.val.testBit 63 = true := by
        rw [Nat.testBit, Nat.shiftRight_eq_div_pow]
        have h1 : u.val / 2 ^ 63 = 1 := by omega
        rw [h1]; decide
      apply Nat.eq_of_testBit_eq; intro i
      rw [Nat.testBit_xor, Nat.testBit_two_pow]
      by_cases hi : i = 63
      · subst hi; simp [htest]
        exact Nat.testBit_eq_false_of_lt (by omega)
      · simp [Ne.symm hi]
        have hsub : (u.val - 2 ^ 63).testBit i = u.val.testBit i := by
          set r := u.val - 2 ^ 63
          have hu_eq : u.val = r + 2 ^ 63 := by omega
          rw [hu_eq]
          by_cases hlt63 : i < 63
          · rw [Nat.testBit, Nat.testBit, Nat.shiftRight_eq_div_pow, Nat.shiftRight_eq_div_pow]
            have hd : 2 ^ 63 = 2 ^ (63 - i) * 2 ^ i := by rw [← Nat.pow_add, Nat.sub_add_cancel (by omega)]
            have hd2 : 2 ^ (63 - i) = 2 * 2 ^ (62 - i) := by rw [← Nat.pow_succ']; congr 1; omega
            rw [hd, Nat.add_mul_div_right _ _ (Nat.two_pow_pos i), hd2]
            simp [Nat.add_mul_mod_self_left]
          · have hgt63 : 63 < i := by omega
            have hpow_ge : 2 ^ 64 ≤ 2 ^ i := Nat.pow_le_pow_right (by norm_num) (by omega)
            rw [Nat.testBit_eq_false_of_lt (by omega), Nat.testBit_eq_false_of_lt (by omega)]
        rw [← h263, hsub]
  rw [hxor_nat]
  split_ifs at hto ⊢ <;> omega

end GraphProofs
