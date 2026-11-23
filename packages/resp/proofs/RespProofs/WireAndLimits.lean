import Aeneas
import PionLean
import Resp.Types
import Resp.Funs

open Aeneas Aeneas.Std Result Pion resp

namespace RespProofs

private lemma i32_lt_iff (x y : Std.I32) : (x < y) ↔ (x.val < y.val) := Iff.rfl
private lemma i32_le_iff (x y : Std.I32) : (x ≤ y) ↔ (x.val ≤ y.val) := Iff.rfl

private lemma i32_beq_iff (x y : Std.I32) : (x == y) = true ↔ x.val = y.val := by
  constructor
  · intro h
    have hbv : x.bv = y.bv := by
      change (x.bv == y.bv) = true at h
      exact eq_of_beq h
    exact congrArg BitVec.toInt hbv
  · intro h
    have hbv : x.bv = y.bv := BitVec.eq_of_toInt_eq h
    change (x.bv == y.bv) = true
    rw [hbv, beq_self_eq_true]

private lemma i64_lt_iff (x y : Std.I64) : (x < y) ↔ (x.val < y.val) := Iff.rfl

private lemma i64_beq_iff (x y : Std.I64) : (x == y) = true ↔ x.val = y.val := by
  constructor
  · intro h
    have hbv : x.bv = y.bv := by
      change (x.bv == y.bv) = true at h
      exact eq_of_beq h
    exact congrArg BitVec.toInt hbv
  · intro h
    have hbv : x.bv = y.bv := BitVec.eq_of_toInt_eq h
    change (x.bv == y.bv) = true
    rw [hbv, beq_self_eq_true]

private lemma i32_val_neg1 : ((-1)#i32 : Std.I32).val = -1 := by
  change (BitVec.ofInt 32 (-1)).toInt = -1
  rw [BitVec.toInt_ofInt, Int.bmod_def]; omega

private lemma i32_val_max_minus_16 : (Pion.I32.sub 2147483647#i32 16#i32).val = 2147483631 := by
  decide

private lemma i64_val_pos_lim : (922337203685477580#i64 : Std.I64).val = 922337203685477580 := by
  change (BitVec.ofInt 64 922337203685477580).toInt = 922337203685477580
  rw [BitVec.toInt_ofInt, Int.bmod_def]; omega

private lemma i64_val_neg_lim : ((-922337203685477580)#i64 : Std.I64).val = -922337203685477580 := by
  change (BitVec.ofInt 64 (-922337203685477580)).toInt = -922337203685477580
  rw [BitVec.toInt_ofInt, Int.bmod_def]; omega

private lemma i64_val_7 : (7#i64 : Std.I64).val = 7 := rfl
private lemma i64_val_8 : (8#i64 : Std.I64).val = 8 := rfl

private lemma i32_add_val (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val + y.val) (hhi : x.val + y.val ≤ 2147483647) :
    (Pion.I32.add x y).val = x.val + y.val := by
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add, Int.bmod_def]
  change -2147483648 ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt ≤ 2147483647 at hhi
  omega

private lemma i32_sub_val (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val - y.val) (hhi : x.val - y.val ≤ 2147483647) :
    (Pion.I32.sub x y).val = x.val - y.val := by
  change (x.bv - y.bv).toInt = x.bv.toInt - y.bv.toInt
  rw [BitVec.toInt_sub, Int.bmod_def]
  change -2147483648 ≤ x.bv.toInt - y.bv.toInt at hlo
  change x.bv.toInt - y.bv.toInt ≤ 2147483647 at hhi
  omega

private lemma i32_bounds (x : Std.I32) : -2147483648 ≤ x.val ∧ x.val ≤ 2147483647 := by
  have h := x.hBounds
  change -(2 ^ 31 : Int) ≤ x.val ∧ x.val < 2 ^ 31 at h
  omega

/-- Theorem 3: `effective_max_buffer_bytes` never shrinks `max_buffer_bytes` for any `RespLimits`. -/
theorem effective_max_buffer_bytes_ge_original (lim : RespLimits) :
    ∃ r : Std.I32, effective_max_buffer_bytes lim = ok r ∧ lim.max_buffer_bytes.val ≤ r.val := by
  unfold effective_max_buffer_bytes
  by_cases h : (((decide (lim.max_buffer_bytes >= lim.max_bulk_len)) &&
                 (decide (lim.max_bulk_len <= Pion.I32.sub 2147483647#i32 16#i32))) &&
                (decide (lim.max_buffer_bytes < Pion.I32.add lim.max_bulk_len 16#i32))) = true
  · simp only [h, ↓reduceIte]
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff, i32_lt_iff] at h
    have hlt : lim.max_buffer_bytes.val < (Pion.I32.add lim.max_bulk_len 16#i32).val := h.2
    exact ⟨Pion.I32.add lim.max_bulk_len 16#i32, rfl, by omega⟩
  · have hf := Bool.eq_false_iff.mpr h
    simp only [hf, Bool.false_eq_true, ↓reduceIte]
    exact ⟨lim.max_buffer_bytes, rfl, le_refl _⟩

/-- Theorem 4: When `max_buffer_bytes ≥ max_bulk_len` and `max_bulk_len ≤ 2^31 - 17`, `effective_max_buffer_bytes` guarantees ≥ 16 B framing slack without overflow. -/
theorem effective_max_buffer_bytes_slack (lim : RespLimits)
    (hge : lim.max_bulk_len.val ≤ lim.max_buffer_bytes.val)
    (hcap : lim.max_bulk_len.val ≤ 2147483631) :
    ∃ r : Std.I32, effective_max_buffer_bytes lim = ok r ∧ lim.max_bulk_len.val + 16 ≤ r.val := by
  have hb := i32_bounds lim.max_bulk_len
  have hadd : (Pion.I32.add lim.max_bulk_len 16#i32).val = lim.max_bulk_len.val + 16 :=
    i32_add_val lim.max_bulk_len 16#i32 (by change -2147483648 ≤ lim.max_bulk_len.val + 16; omega)
                                         (by change lim.max_bulk_len.val + 16 ≤ 2147483647; omega)
  unfold effective_max_buffer_bytes
  by_cases h : (((decide (lim.max_buffer_bytes >= lim.max_bulk_len)) &&
                 (decide (lim.max_bulk_len <= Pion.I32.sub 2147483647#i32 16#i32))) &&
                (decide (lim.max_buffer_bytes < Pion.I32.add lim.max_bulk_len 16#i32))) = true
  · simp only [h, ↓reduceIte]
    exact ⟨Pion.I32.add lim.max_bulk_len 16#i32, rfl, by omega⟩
  · have hf := Bool.eq_false_iff.mpr h
    simp only [hf, Bool.false_eq_true, ↓reduceIte]
    have h1 : decide (lim.max_buffer_bytes >= lim.max_bulk_len) = true := by
      simp only [decide_eq_true_eq, ge_iff_le, i32_le_iff]; exact hge
    have h2 : decide (lim.max_bulk_len <= Pion.I32.sub 2147483647#i32 16#i32) = true := by
      simp only [decide_eq_true_eq, i32_le_iff, i32_val_max_minus_16]; exact hcap
    have hnotlt : ¬ (lim.max_buffer_bytes.val < (Pion.I32.add lim.max_bulk_len 16#i32).val) := by
      intro hlt
      have h3 : decide (lim.max_buffer_bytes < Pion.I32.add lim.max_bulk_len 16#i32) = true := by
        simp only [decide_eq_true_eq, i32_lt_iff]; exact hlt
      rw [h1, h2, h3] at h
      exact h rfl
    exact ⟨lim.max_buffer_bytes, rfl, by omega⟩

/-- Theorem 6: `is_resp_prefix` characterizes exactly the 15 RESP2/RESP3 wire prefix bytes. -/
lemma is_resp_prefix_exact_15 (b : Std.I32) :
    is_resp_prefix b = ok true ↔
      b.val = 43 ∨ b.val = 45 ∨ b.val = 58 ∨ b.val = 36 ∨ b.val = 42 ∨
      b.val = 95 ∨ b.val = 35 ∨ b.val = 44 ∨ b.val = 40 ∨ b.val = 33 ∨
      b.val = 61 ∨ b.val = 37 ∨ b.val = 126 ∨ b.val = 124 ∨ b.val = 62 := by
  unfold is_resp_prefix
  simp only [ok.injEq, Bool.or_eq_true, i32_beq_iff]
  change ((((((((((((((b.val = 43 ∨ b.val = 45) ∨ b.val = 58) ∨ b.val = 36) ∨ b.val = 42) ∨ b.val = 95) ∨ b.val = 35) ∨ b.val = 44) ∨ b.val = 40) ∨ b.val = 33) ∨ b.val = 61) ∨ b.val = 37) ∨ b.val = 126) ∨ b.val = 124) ∨ b.val = 62) ↔ _
  tauto

/-- Theorem 7: `is_resp_prefix` and `is_inline_space` are strictly disjoint across all `Int32`. -/
theorem is_resp_prefix_disjoint_inline_space (b : Std.I32) :
    ¬ (is_resp_prefix b = ok true ∧ is_inline_space b = ok true) := by
  rintro ⟨hp, hs⟩
  rw [is_resp_prefix_exact_15] at hp
  unfold is_inline_space at hs
  simp only [ok.injEq, Bool.or_eq_true, i32_beq_iff] at hs
  change (((((b.val = 32 ∨ b.val = 9) ∨ b.val = 10) ∨ b.val = 11) ∨ b.val = 12) ∨ b.val = 13) at hs
  omega

/-- Theorem 8: `is_resp_prefix` is strictly disjoint from ASCII alphanumerics (`0-9`, `A-Z`, `a-z`) so inline commands are never misclassified. -/
theorem is_resp_prefix_disjoint_alnum (b : Std.I32)
    (halnum : (48 ≤ b.val ∧ b.val ≤ 57) ∨ (65 ≤ b.val ∧ b.val ≤ 90) ∨ (97 ≤ b.val ∧ b.val ≤ 122)) :
    is_resp_prefix b = ok false := by
  unfold is_resp_prefix
  apply congrArg ok
  rw [Bool.eq_false_iff]
  intro ht
  have hp : is_resp_prefix b = ok true := by unfold is_resp_prefix; exact congrArg ok ht
  rw [is_resp_prefix_exact_15] at hp
  omega

/-- Theorem 10: `hex_nibble` always returns `-1` (invalid) or a nibble in `[0, 15]`. -/
theorem hex_nibble_bounds (c : Std.I32) :
    ∃ r : Std.I32, hex_nibble c = ok r ∧ (r.val = -1 ∨ (0 ≤ r.val ∧ r.val ≤ 15)) := by
  unfold hex_nibble
  by_cases h1 : ((decide (c >= 48#i32)) && (decide (c <= 57#i32))) = true
  · simp only [h1, ↓reduceIte]
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at h1
    change 48 ≤ c.val ∧ c.val ≤ 57 at h1
    have hsub := i32_sub_val c 48#i32 (by change -2147483648 ≤ c.val - 48; omega) (by change c.val - 48 ≤ 2147483647; omega)
    change (Pion.I32.sub c 48#i32).val = c.val - 48 at hsub
    exact ⟨Pion.I32.sub c 48#i32, rfl, Or.inr ⟨by omega, by omega⟩⟩
  · have h1f := Bool.eq_false_iff.mpr h1
    simp only [h1f, Bool.false_eq_true, ↓reduceIte]
    by_cases h2 : ((decide (c >= 65#i32)) && (decide (c <= 70#i32))) = true
    · simp only [h2, ↓reduceIte]
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at h2
      change 65 ≤ c.val ∧ c.val ≤ 70 at h2
      have hsub := i32_sub_val c 55#i32 (by change -2147483648 ≤ c.val - 55; omega) (by change c.val - 55 ≤ 2147483647; omega)
      change (Pion.I32.sub c 55#i32).val = c.val - 55 at hsub
      exact ⟨Pion.I32.sub c 55#i32, rfl, Or.inr ⟨by omega, by omega⟩⟩
    · have h2f := Bool.eq_false_iff.mpr h2
      simp only [h2f, Bool.false_eq_true, ↓reduceIte]
      by_cases h3 : ((decide (c >= 97#i32)) && (decide (c <= 102#i32))) = true
      · simp only [h3, ↓reduceIte]
        simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at h3
        change 97 ≤ c.val ∧ c.val ≤ 102 at h3
        have hsub := i32_sub_val c 87#i32 (by change -2147483648 ≤ c.val - 87; omega) (by change c.val - 87 ≤ 2147483647; omega)
        change (Pion.I32.sub c 87#i32).val = c.val - 87 at hsub
        exact ⟨Pion.I32.sub c 87#i32, rfl, Or.inr ⟨by omega, by omega⟩⟩
      · have h3f := Bool.eq_false_iff.mpr h3
        simp only [h3f, Bool.false_eq_true, ↓reduceIte]
        exact ⟨(-1)#i32, rfl, Or.inl i32_val_neg1⟩

/-- Theorem 12: `i64_parse_will_overflow` is an exact iff characterization of signed 64-bit decimal overflow for `0 ≤ d ≤ 9`. -/
theorem i64_parse_will_overflow_exact (acc d : Std.I64) (hd0 : 0 ≤ d.val) (hd9 : d.val ≤ 9) :
    (i64_parse_will_overflow acc d false = ok false ↔ acc.val * 10 + d.val ≤ 9223372036854775807) ∧
    (i64_parse_will_overflow acc d true = ok false ↔ -9223372036854775808 ≤ acc.val * 10 - d.val) := by
  constructor
  · unfold i64_parse_will_overflow
    simp only [Bool.false_eq_true, ↓reduceIte, ok.injEq, Bool.or_eq_false_iff, Bool.and_eq_false_iff,
               decide_eq_false_iff_not, gt_iff_lt, i64_lt_iff, i64_val_pos_lim, i64_val_7]
    rw [Bool.eq_false_iff, ne_eq, i64_beq_iff, i64_val_pos_lim]
    omega
  · unfold i64_parse_will_overflow
    simp only [↓reduceIte, ok.injEq, Bool.or_eq_false_iff, Bool.and_eq_false_iff,
               decide_eq_false_iff_not, gt_iff_lt, i64_lt_iff, i64_val_neg_lim, i64_val_8]
    rw [Bool.eq_false_iff, ne_eq, i64_beq_iff, i64_val_neg_lim]
    omega

end RespProofs
