import Aeneas
import PionLean
import Regex.Types
import Regex.Funs

open Aeneas Aeneas.Std Result Error Pion
open regex

namespace RegexProofs

private lemma i32_beq_iff (x y : Std.I32) : (x == y) = true ↔ x.val = y.val := by
  cases x; cases y
  simp [BEq.beq, IScalar.val, BitVec.toInt_inj]

private lemma i32_eq_of_val {x y : Std.I32} (h : x.val = y.val) : x = y := by
  cases x; cases y
  simp [IScalar.val, BitVec.toInt_inj] at h
  congr

private lemma char_range_le_iff (a b : CharRange) :
    char_range_le a b = ok true ↔
      (a.lo.val < b.lo.val ∨ (a.lo.val = b.lo.val ∧ a.hi.val ≤ b.hi.val)) := by
  unfold char_range_le
  simp only [Result.ok.injEq, Bool.or_eq_true, Bool.and_eq_true,
    decide_eq_true_eq, IScalar.lt_equiv, IScalar.le_equiv, i32_beq_iff]

/-- 13. `char_range_le` is reflexive. -/
theorem char_range_le_refl (a : CharRange) :
    char_range_le a a = ok true := by
  rw [char_range_le_iff]
  right
  exact ⟨rfl, le_refl _⟩

/-- 14. `char_range_le` is antisymmetric on `CharRange`. -/
theorem char_range_le_antisymm (a b : CharRange) :
    char_range_le a b = ok true →
    char_range_le b a = ok true →
    a = b := by
  rw [char_range_le_iff, char_range_le_iff]
  intro hab hba
  have hlo : a.lo = b.lo := i32_eq_of_val (by omega)
  have hhi : a.hi = b.hi := i32_eq_of_val (by omega)
  cases a; cases b
  simp only at hlo hhi
  subst hlo; subst hhi; rfl

/-- 15. `char_range_le` is transitive. -/
theorem char_range_le_trans (a b c : CharRange) :
    char_range_le a b = ok true →
    char_range_le b c = ok true →
    char_range_le a c = ok true := by
  rw [char_range_le_iff, char_range_le_iff, char_range_le_iff]
  intro hab hbc
  omega

/-- 16. `char_range_le` is total (any two `CharRange`s are comparable). -/
theorem char_range_le_total (a b : CharRange) :
    char_range_le a b = ok true ∨ char_range_le b a = ok true := by
  rw [char_range_le_iff, char_range_le_iff]
  omega

/-- 17. `char_range_intersect` is commutative. -/
theorem char_range_intersect_comm (a b : CharRange) :
    char_range_intersect a b = char_range_intersect b a := by
  unfold char_range_intersect
  simp only [Result.ok.injEq, CharRange.mk.injEq]
  constructor
  · by_cases h1 : a.lo > b.lo <;> by_cases h2 : b.lo > a.lo <;> simp only [h1, h2, ↓reduceIte]
    · exact absurd h2 (by simp only [gt_iff_lt, IScalar.lt_equiv] at h1 ⊢; omega)
    · exact i32_eq_of_val (by simp only [gt_iff_lt, IScalar.lt_equiv] at h1 h2; omega)
  · by_cases h1 : a.hi < b.hi <;> by_cases h2 : b.hi < a.hi <;> simp only [h1, h2, ↓reduceIte]
    · exact absurd h2 (by simp only [IScalar.lt_equiv] at h1 ⊢; omega)
    · exact i32_eq_of_val (by simp only [IScalar.lt_equiv] at h1 h2; omega)

/-- 18. `char_range_intersect` is idempotent. -/
theorem char_range_intersect_idem (a : CharRange) :
    char_range_intersect a a = ok a := by
  unfold char_range_intersect
  simp

/-- 19. Point membership in `char_range_intersect a b` is exact set intersection. -/
theorem char_range_intersect_mem_iff (a b : CharRange) (x : Int) :
    ∃ r : CharRange,
      char_range_intersect a b = ok r ∧
      ((r.lo.val ≤ x ∧ x ≤ r.hi.val) ↔
        ((a.lo.val ≤ x ∧ x ≤ a.hi.val) ∧ (b.lo.val ≤ x ∧ x ≤ b.hi.val))) := by
  refine ⟨⟨if a.lo > b.lo then a.lo else b.lo, if a.hi < b.hi then a.hi else b.hi⟩, rfl, ?_⟩
  simp only
  split_ifs with h1 h2 h2
  · simp only [gt_iff_lt, IScalar.lt_equiv] at h1 h2; omega
  · simp only [gt_iff_lt, IScalar.lt_equiv] at h1 h2; omega
  · simp only [gt_iff_lt, IScalar.lt_equiv] at h1 h2; omega
  · simp only [gt_iff_lt, IScalar.lt_equiv] at h1 h2; omega

/-- 20. For any byte `0 ≤ b ≤ 255`, `is_utf8_cont_byte b` holds iff `0x80 ≤ b ≤ 0xBF`. -/
theorem is_utf8_cont_byte_iff (b : Std.I32) (hlo : 0 ≤ b.val) (hhi : b.val ≤ 255) :
    is_utf8_cont_byte b = ok true ↔ (128 ≤ b.val ∧ b.val ≤ 191) := by
  unfold is_utf8_cont_byte
  simp only [Result.ok.injEq, i32_beq_iff]
  have hbnat : b.bv.toNat = b.val.toNat := by
    have hlt : 2 * b.bv.toNat < 2 ^ 32 := by
      have hbv := BitVec.toInt_eq_toNat_cond b.bv
      split_ifs at hbv with hc
      · omega
      · change b.bv.toInt ≤ 255 at hhi
        change 0 ≤ b.bv.toInt at hlo
        omega
    have hti : b.bv.toInt = (b.bv.toNat : Int) :=
      BitVec.toInt_eq_toNat_of_lt hlt
    change b.bv.toNat = b.bv.toInt.toNat
    rw [hti]; omega
  have hbeq : (Pion.I32.band b 192#i32).val = (128#i32).val ↔
      (b.bv &&& BitVec.ofNat 32 192) = BitVec.ofNat 32 128 := by
    have h192 : (192#i32).bv = BitVec.ofNat 32 192 := rfl
    have h128 : (128#i32).bv = BitVec.ofNat 32 128 := rfl
    change (b.bv &&& BitVec.ofNat 32 192).toInt = (BitVec.ofNat 32 128).toInt ↔ _
    exact BitVec.toInt_inj
  rw [hbeq]
  have hlt256 : b.val.toNat < 256 := by omega
  constructor
  · intro heq
    have h7 := congrArg (fun v : BitVec 32 => v.getLsbD 7) heq
    have h6 := congrArg (fun v : BitVec 32 => v.getLsbD 6) heq
    have hb7 : b.bv[7] = true := by
      simpa [BitVec.getLsbD_and] using h7
    have hb6 : b.bv[6] = false := by
      simpa [BitVec.getLsbD_and] using h6
    rw [BitVec.getElem_eq_testBit_toNat, hbnat, Nat.testBit_eq_decide_div_mod_eq] at hb7 hb6
    have hd7 : (b.val.toNat / 2 ^ 7) % 2 = 1 := by simpa using hb7
    have hd6 : (b.val.toNat / 2 ^ 6) % 2 ≠ 1 := by simpa using hb6
    omega
  · intro hrange
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    rw [BitVec.getLsbD_and]
    change (b.bv.toNat.testBit i && (BitVec.ofNat 32 192).getLsbD i) = (BitVec.ofNat 32 128).getLsbD i
    rw [hbnat]
    by_cases h7 : i = 7
    · subst h7
      have ht : b.val.toNat.testBit 7 = true := by
        rw [Nat.testBit_eq_decide_div_mod_eq]; simp; omega
      simp [ht]
    · by_cases h6 : i = 6
      · subst h6
        have ht : b.val.toNat.testBit 6 = false := by
          rw [Nat.testBit_eq_decide_div_mod_eq]; simp; omega
        simp [ht]
      · have hm : (BitVec.ofNat 32 192).getLsbD i = false := by
          rw [BitVec.getLsbD_ofNat]
          have : Nat.testBit 192 i = false := by
            rw [Nat.testBit_eq_decide_div_mod_eq]
            have hpow : i < 6 ∨ 8 ≤ i := by omega
            rcases hpow with hlt6 | hge8
            · rcases (show i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 ∨ i = 5 by omega) with
                rfl | rfl | rfl | rfl | rfl | rfl <;> decide
            · have h2 : 2 ^ 8 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) hge8
              have hdiv : 192 / 2 ^ i = 0 := Nat.div_eq_of_lt (by omega)
              simp [hdiv]
          simp [this]
        have hr : (BitVec.ofNat 32 128).getLsbD i = false := by
          rw [BitVec.getLsbD_ofNat]
          have : Nat.testBit 128 i = false := by
            rw [Nat.testBit_eq_decide_div_mod_eq]
            have hpow : i < 6 ∨ 8 ≤ i := by omega
            rcases hpow with hlt6 | hge8
            · rcases (show i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 ∨ i = 5 by omega) with
                rfl | rfl | rfl | rfl | rfl | rfl <;> decide
            · have h2 : 2 ^ 8 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) hge8
              have hdiv : 128 / 2 ^ i = 0 := Nat.div_eq_of_lt (by omega)
              simp [hdiv]
          simp [this]
        simp [hm, hr]

/-- 21. `utf8_lead_len` always returns a nominal UTF-8 byte length in `[1, 4]`. -/
theorem utf8_lead_len_bounds (b : Std.I32) :
    ∃ len : Std.I32,
      utf8_lead_len b = ok len ∧ 1 ≤ len.val ∧ len.val ≤ 4 := by
  unfold utf8_lead_len
  refine ⟨_, rfl, ?_⟩
  split_ifs
  · exact ⟨by decide, by decide⟩
  · exact ⟨by decide, by decide⟩
  · exact ⟨by decide, by decide⟩
  · exact ⟨by decide, by decide⟩

private lemma i32_add_val (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val + y.val) (hhi : x.val + y.val < 2 ^ 31) :
    (Pion.I32.add x y).val = x.val + y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_sub_val (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val - y.val) (hhi : x.val - y.val < 2 ^ 31) :
    (Pion.I32.sub x y).val = x.val - y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt - y.bv.toInt at hlo
  change x.bv.toInt - y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv - y.bv).toInt = x.bv.toInt - y.bv.toInt
  rw [BitVec.toInt_sub]
  exact Int.bmod_eq_of_le (by omega) (by omega)

/-- 22. `hex_val` always returns `-1` or a valid hex nibble in `[0, 15]`. -/
theorem hex_val_bounds (b : Std.I32) :
    ∃ v : Std.I32,
      hex_val b = ok v ∧ -1 ≤ v.val ∧ v.val ≤ 15 := by
  unfold hex_val
  have h48 : (48#i32).val = 48 := by decide
  have h57 : (57#i32).val = 57 := by decide
  have h65 : (65#i32).val = 65 := by decide
  have h70 : (70#i32).val = 70 := by decide
  have h97 : (97#i32).val = 97 := by decide
  have h102 : (102#i32).val = 102 := by decide
  have h10 : (10#i32).val = 10 := by decide
  have hm1 : ((-1)#i32).val = -1 := by decide
  refine ⟨_, rfl, ?_⟩
  split_ifs with h1 h2 h3
  · simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, IScalar.le_equiv, h48, h57] at h1
    have hsub : (Pion.I32.sub b 48#i32).val = b.val - 48 := by
      rw [i32_sub_val b 48#i32 (by omega) (by omega), h48]
    omega
  · simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, IScalar.le_equiv, h65, h70] at h2
    have hsub : (Pion.I32.sub b 65#i32).val = b.val - 65 := by
      rw [i32_sub_val b 65#i32 (by omega) (by omega), h65]
    have hadd : (Pion.I32.add (Pion.I32.sub b 65#i32) 10#i32).val = b.val - 65 + 10 := by
      rw [i32_add_val _ 10#i32 (by omega) (by omega), hsub, h10]
    omega
  · simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, IScalar.le_equiv, h97, h102] at h3
    have hsub : (Pion.I32.sub b 97#i32).val = b.val - 97 := by
      rw [i32_sub_val b 97#i32 (by omega) (by omega), h97]
    have hadd : (Pion.I32.add (Pion.I32.sub b 97#i32) 10#i32).val = b.val - 97 + 10 := by
      rw [i32_add_val _ 10#i32 (by omega) (by omega), hsub, h10]
    omega
  · omega

/-- 23. `hex_val` is case-insensitive on `'A'..'F'` vs `'a'..'f'`. -/
theorem hex_val_case_insensitive (b : Std.I32) (hlo : 65 ≤ b.val) (hhi : b.val ≤ 70) :
    hex_val (Pion.I32.add b 32#i32) = hex_val b := by
  have h32 : (32#i32).val = 32 := by decide
  have h48 : (48#i32).val = 48 := by decide
  have h57 : (57#i32).val = 57 := by decide
  have h65 : (65#i32).val = 65 := by decide
  have h70 : (70#i32).val = 70 := by decide
  have h97 : (97#i32).val = 97 := by decide
  have h102 : (102#i32).val = 102 := by decide
  have h10 : (10#i32).val = 10 := by decide
  have hadd32 : (Pion.I32.add b 32#i32).val = b.val + 32 := by
    rw [i32_add_val b 32#i32 (by omega) (by omega), h32]
  unfold hex_val
  have hc1 : ((decide (b >= 48#i32)) && (decide (b <= 57#i32))) = false := by
    simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, ge_iff_le, IScalar.le_equiv, h48, h57]; omega
  have hc2 : ((decide (b >= 65#i32)) && (decide (b <= 70#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, IScalar.le_equiv, h65, h70]; omega
  have hd1 : ((decide (Pion.I32.add b 32#i32 >= 48#i32)) && (decide (Pion.I32.add b 32#i32 <= 57#i32))) = false := by
    simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, ge_iff_le, IScalar.le_equiv, h48, h57, hadd32]; omega
  have hd2 : ((decide (Pion.I32.add b 32#i32 >= 65#i32)) && (decide (Pion.I32.add b 32#i32 <= 70#i32))) = false := by
    simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, ge_iff_le, IScalar.le_equiv, h65, h70, hadd32]; omega
  have hd3 : ((decide (Pion.I32.add b 32#i32 >= 97#i32)) && (decide (Pion.I32.add b 32#i32 <= 102#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, IScalar.le_equiv, h97, h102, hadd32]; omega
  simp only [hc1, hc2, hd1, hd2, hd3, Bool.false_eq_true, ↓reduceIte, Result.ok.injEq]
  apply i32_eq_of_val
  have hs1 : (Pion.I32.sub (Pion.I32.add b 32#i32) 97#i32).val = b.val - 65 := by
    rw [i32_sub_val _ 97#i32 (by omega) (by omega), hadd32, h97]; omega
  have hs2 : (Pion.I32.sub b 65#i32).val = b.val - 65 := by
    rw [i32_sub_val b 65#i32 (by omega) (by omega), h65]
  have ha1 : (Pion.I32.add (Pion.I32.sub (Pion.I32.add b 32#i32) 97#i32) 10#i32).val = b.val - 55 := by
    rw [i32_add_val _ 10#i32 (by omega) (by omega), hs1, h10]; omega
  have ha2 : (Pion.I32.add (Pion.I32.sub b 65#i32) 10#i32).val = b.val - 55 := by
    rw [i32_add_val _ 10#i32 (by omega) (by omega), hs2, h10]; omega
  rw [ha1, ha2]

/-- 24. `(?x)` regex whitespace bytes and `escape()` metacharacters are disjoint. -/
theorem regex_ws_meta_disjoint (b : Std.I32) :
    is_regex_ws_byte b = ok true → is_regex_meta_byte b = ok false := by
  unfold is_regex_ws_byte is_regex_meta_byte
  simp only [Result.ok.injEq, Bool.or_eq_true,
    Bool.eq_false_iff, ne_eq, i32_beq_iff]
  intro h
  rcases h with (((((h | h) | h) | h) | h) | h) <;>
    simp only [h] <;> decide

end RegexProofs
