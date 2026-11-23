import Aeneas
import PionLean
import Jq.Types
import Jq.Funs

open Aeneas Aeneas.Std Result Pion jq

namespace JqProofs

private lemma result_bind_ok' {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private lemma i32_add_val' (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  change -2147483648 ≤ a.bv.toInt + b.bv.toInt at hlo
  change a.bv.toInt + b.bv.toInt ≤ 2147483647 at hhi
  change (a.bv + b.bv).toInt = a.bv.toInt + b.bv.toInt
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_bounds (x : Std.I32) : -2147483648 ≤ x.val ∧ x.val ≤ 2147483647 := by
  have h := x.hBounds
  simp [IScalarTy.numBits] at h
  omega

/-- Theorem 12: `JqLimits.default` is valid and all 4 limits are strictly positive. -/
theorem jq_limits_default_valid :
    ∃ l : JqLimits, JqLimits.default = ok l ∧
      jq_limits_is_valid l = ok true ∧
      0 < l.max_depth.val ∧ 0 < l.max_steps.val ∧
      0 < l.max_outputs.val ∧ 0 < l.max_output_bytes.val := by
  refine ⟨_, rfl, rfl, ?_, ?_, ?_, ?_⟩ <;> decide

/-- Theorem 13: Exact iff characterization of `jq_limits_is_valid`. -/
theorem jq_limits_is_valid_iff (l : JqLimits) :
    jq_limits_is_valid l = ok true ↔
      (0 < l.max_depth.val ∧ 0 < l.max_steps.val ∧
       0 < l.max_outputs.val ∧ 0 < l.max_output_bytes.val) := by
  unfold jq_limits_is_valid
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq]
  constructor
  · intro ⟨⟨⟨h1, h2⟩, h3⟩, h4⟩
    exact ⟨h1, h2, h3, h4⟩
  · intro ⟨h1, h2, h3, h4⟩
    exact ⟨⟨⟨h1, h2⟩, h3⟩, h4⟩

/-- Theorem 14: `clamp_slice_idx` always succeeds and returns a value in `[0, len]` for ALL 32-bit `idx` (including `I32.min`). -/
theorem clamp_slice_idx_bounds (idx len : Std.I32) (hlen : 0 ≤ len.val) :
    ∃ r : Std.I32, clamp_slice_idx idx len = ok r ∧ 0 ≤ r.val ∧ r.val ≤ len.val := by
  unfold clamp_slice_idx
  dsimp only
  have c0 : (0#i32 : Std.I32).val = 0 := rfl
  have hidxb := i32_bounds idx
  have hlenb := i32_bounds len
  split_ifs with h1
  · simp only [result_bind_ok']
    have h1v : idx.val < 0 := h1
    have hadd := i32_add_val' len idx (by omega) (by omega)
    split_ifs with h2
    · simp only [result_bind_ok']
      split_ifs with h3
      · exact ⟨len, rfl, hlen, le_refl _⟩
      · exact ⟨0#i32, rfl, by omega, by omega⟩
    · simp only [result_bind_ok']
      have h2v : ¬ ((Pion.I32.add len idx).val < 0) := h2
      split_ifs with h3
      · exact ⟨len, rfl, hlen, le_refl _⟩
      · have h3v : ¬ ((Pion.I32.add len idx).val > len.val) := h3
        exact ⟨Pion.I32.add len idx, rfl, by omega, by omega⟩
  · simp only [result_bind_ok']
    have h1v : ¬ (idx.val < 0) := h1
    have hnot2 : ¬ (idx < 0#i32) := h1
    simp only [hnot2, ↓reduceIte, result_bind_ok']
    split_ifs with h3
    · exact ⟨len, rfl, hlen, le_refl _⟩
    · have h3v : ¬ (idx.val > len.val) := h3
      exact ⟨idx, rfl, by omega, by omega⟩

/-- Theorem 15: `clamp_slice_idx` is the identity on `[0, len]`. -/
theorem clamp_slice_idx_in_range_id (idx len : Std.I32)
    (h0 : 0 ≤ idx.val) (hle : idx.val ≤ len.val) :
    clamp_slice_idx idx len = ok idx := by
  unfold clamp_slice_idx
  dsimp only
  have hnot1 : ¬ (idx < 0#i32) := by
    change ¬ (idx.val < 0); omega
  have hnot2 : ¬ (idx > len) := by
    change ¬ (idx.val > len.val); omega
  simp only [hnot1, hnot2, ↓reduceIte, result_bind_ok']

/-- Theorem 16: For `-len ≤ idx < 0`, `clamp_slice_idx idx len` resolves to `len + idx`. -/
theorem clamp_slice_idx_neg_spec (idx len : Std.I32)
    (hlen : 0 ≤ len.val) (hlo : -len.val ≤ idx.val) (hneg : idx.val < 0) :
    ∃ r : Std.I32, clamp_slice_idx idx len = ok r ∧ r.val = len.val + idx.val := by
  unfold clamp_slice_idx
  dsimp only
  have hlenb := i32_bounds len
  have hlt1 : idx < 0#i32 := hneg
  have hadd := i32_add_val' len idx (by omega) (by omega)
  have hnot2 : ¬ (Pion.I32.add len idx < 0#i32) := by
    change ¬ ((Pion.I32.add len idx).val < 0); omega
  have hnot3 : ¬ (Pion.I32.add len idx > len) := by
    change ¬ ((Pion.I32.add len idx).val > len.val); omega
  simp only [hlt1, hnot2, hnot3, ↓reduceIte, result_bind_ok']
  exact ⟨Pion.I32.add len idx, rfl, hadd⟩

/-- Theorem 17: For `idx < -len` (with `0 ≤ len`), `clamp_slice_idx idx len` clamps to `0`. -/
theorem clamp_slice_idx_underflow_zero (idx len : Std.I32)
    (hlen : 0 ≤ len.val) (hunder : idx.val < -len.val) :
    clamp_slice_idx idx len = ok 0#i32 := by
  unfold clamp_slice_idx
  dsimp only
  have hidxb := i32_bounds idx
  have hlenb := i32_bounds len
  have hlt1 : idx < 0#i32 := by change idx.val < 0; omega
  have hadd := i32_add_val' len idx (by omega) (by omega)
  have hlt2 : Pion.I32.add len idx < 0#i32 := by
    change (Pion.I32.add len idx).val < 0; omega
  have hnot3 : ¬ (0#i32 > len) := by
    change ¬ ((0 : Int) > len.val); omega
  simp only [hlt1, hlt2, hnot3, ↓reduceIte, result_bind_ok']

/-- Theorem 18: For `len < idx` (with `0 ≤ len`), `clamp_slice_idx idx len` clamps to `len`. -/
theorem clamp_slice_idx_overflow_len (idx len : Std.I32)
    (hlen : 0 ≤ len.val) (hover : len.val < idx.val) :
    clamp_slice_idx idx len = ok len := by
  unfold clamp_slice_idx
  dsimp only
  have hnot1 : ¬ (idx < 0#i32) := by
    change ¬ (idx.val < 0); omega
  have hgt3 : idx > len := hover
  simp only [hnot1, hgt3, ↓reduceIte, result_bind_ok']

/-- Theorem 19: `clamp_slice_idx` is idempotent for all `idx` and `0 ≤ len`. -/
theorem clamp_slice_idx_idempotent (idx len : Std.I32) (hlen : 0 ≤ len.val) :
    (do let r ← clamp_slice_idx idx len; clamp_slice_idx r len) = clamp_slice_idx idx len := by
  obtain ⟨r, hr, hr0, hrle⟩ := clamp_slice_idx_bounds idx len hlen
  rw [hr, result_bind_ok']
  exact clamp_slice_idx_in_range_id r len hr0 hrle

/-- Theorem 20: `clamp_slice_idx` is monotonic on non-negative indices (`0 ≤ a ≤ b`). -/
theorem clamp_slice_idx_nonneg_mono (a b len : Std.I32)
    (hlen : 0 ≤ len.val) (ha : 0 ≤ a.val) (hab : a.val ≤ b.val) :
    ∃ ra rb : Std.I32,
      clamp_slice_idx a len = ok ra ∧
      clamp_slice_idx b len = ok rb ∧
      ra.val ≤ rb.val := by
  by_cases ha_le : a.val ≤ len.val
  · have hra := clamp_slice_idx_in_range_id a len ha ha_le
    by_cases hb_le : b.val ≤ len.val
    · have hrb := clamp_slice_idx_in_range_id b len (by omega) hb_le
      exact ⟨a, b, hra, hrb, hab⟩
    · have hrb := clamp_slice_idx_overflow_len b len hlen (by omega)
      exact ⟨a, len, hra, hrb, ha_le⟩
  · have hra := clamp_slice_idx_overflow_len a len hlen (by omega)
    have hrb := clamp_slice_idx_overflow_len b len hlen (by omega)
    exact ⟨len, len, hra, hrb, le_refl _⟩

/-- Theorem 21: `clamp_slice_i64` succeeds and returns a value in `[0, len]` for ALL 64-bit `i : Std.I64`. -/
theorem clamp_slice_i64_bounds (i : Std.I64) (len : Std.I32) (hlen : 0 ≤ len.val) :
    ∃ r : Std.I32, clamp_slice_i64 i len = ok r ∧ 0 ≤ r.val ∧ r.val ≤ len.val := by
  unfold clamp_slice_i64
  have c0 : (0#i32 : Std.I32).val = 0 := rfl
  split_ifs with h1 h2
  · exact ⟨0#i32, rfl, by omega, by omega⟩
  · exact ⟨len, rfl, hlen, le_refl _⟩
  · obtain ⟨r, hr, hr0, hrle⟩ := clamp_slice_idx_bounds (Pion.I64.to_int i) len hlen
    rw [hr, result_bind_ok']
    exact ⟨r, rfl, hr0, hrle⟩

/-- Theorem 22: Extreme 64-bit indices (`i < -2^31` or `i > 2^31 - 1`) clamp directly to `0` and `len` without 32-bit overflow. -/
theorem clamp_slice_i64_extreme_spec (i : Std.I64) (len : Std.I32) :
    (i.val < -2147483648 → clamp_slice_i64 i len = ok 0#i32) ∧
    (i.val > 2147483647 → clamp_slice_i64 i len = ok len) := by
  unfold clamp_slice_i64
  constructor
  · intro hlt
    have h1 : i < (-2147483648)#i64 := hlt
    simp only [h1, ↓reduceIte]
  · intro hgt
    have hnot1 : ¬ (i < (-2147483648)#i64) := by
      change ¬ (i.val < -2147483648); omega
    have h2 : i > 2147483647#i64 := hgt
    simp only [hnot1, h2, ↓reduceIte]

end JqProofs
