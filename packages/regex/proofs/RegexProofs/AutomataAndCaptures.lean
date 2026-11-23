import Aeneas
import PionLean
import Regex.Types
import Regex.Funs

open Aeneas Aeneas.Std Result Error Pion
open regex

namespace RegexProofs

private lemma i64_eq_of_bv {a b : Std.I64} (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

private lemma result_bind_ok {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by
  simp

private lemma i32_div_two_spec (x : Std.I32) :
    ∃ q : Std.I32,
      Pion.I32.div x 2#i32 = ok q ∧ q.val = Int.tdiv x.val 2 := by
  have hnz : (2#i32).val ≠ 0 := by decide
  have hno : ¬ (x.val = IScalar.min .I32 ∧ (2#i32).val = -1) := by
    intro h
    have h2 : (2#i32).val = 2 := by decide
    omega
  obtain ⟨q, hq, hqv⟩ := IScalar.div_spec (x := x) (y := 2#i32) hnz hno
  refine ⟨q, ?_, ?_⟩
  · simpa [Pion.I32.div] using hq
  · have h2 : (2#i32).val = 2 := by decide
    simpa [h2] using hqv

/-- Recording the same capture slot twice in a One-Pass transition bitmask is idempotent. -/
theorem onepass_mask_add_slot_idempotent
    (mask : Std.I64) (slot nslots : Std.I32) :
    ∃ m1 : Std.I64,
      onepass_mask_add_slot mask slot nslots = ok m1 ∧
      onepass_mask_add_slot m1 slot nslots = ok m1 := by
  unfold onepass_mask_add_slot
  have h0 : (0#i32).val = 0 := by decide
  have h63 : (63#i32).val = 63 := by decide
  by_cases hcond : ((((decide (slot >= 0#i32)) && (decide (slot < nslots))) &&
      (decide (slot < 63#i32))) = true)
  · have hbounds : 0 ≤ slot.val ∧ slot.val < 64 := by
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le,
        IScalar.le_equiv, IScalar.lt_equiv, h0, h63] at hcond
      omega
    have hshl : Pion.I64.shl_i32 1#i64 slot = ok ⟨(1#i64).bv <<< slot.val.toNat⟩ := by
      simp [Pion.I64.shl_i32, hbounds]
    refine ⟨Pion.I64.bor mask ⟨(1#i64).bv <<< slot.val.toNat⟩, ?_, ?_⟩
    · simp only [hcond, ↓reduceIte, hshl]
      rw [result_bind_ok]
    · simp only [hcond, ↓reduceIte, hshl]
      rw [result_bind_ok]
      congr 1
      apply i64_eq_of_bv
      simp only [Pion.I64.bor]
      rw [BitVec.or_assoc, BitVec.or_self]
  · have hf : (((decide (slot >= 0#i32)) && (decide (slot < nslots))) &&
        (decide (slot < 63#i32))) = false := by
      cases h : (((decide (slot >= 0#i32)) && (decide (slot < nslots))) &&
        (decide (slot < 63#i32)))
      · rfl
      · exact absurd h hcond
    exact ⟨mask, by rw [hf]; rfl, by rw [hf]; rfl⟩

/-- `captures_slot_valid idx slots_len = true` guarantees both `idx * 2` and
    `idx * 2 + 1` lie strictly inside `[0, slots_len)`. -/
theorem captures_slot_valid_bounds (idx slots_len : Std.I32) :
    captures_slot_valid idx slots_len = ok true →
    0 ≤ idx.val * 2 ∧ idx.val * 2 + 1 < slots_len.val := by
  unfold captures_slot_valid
  have h0 : (0#i32).val = 0 := by decide
  by_cases hge : idx >= 0#i32
  · simp only [hge, ↓reduceIte]
    obtain ⟨q, hq, hqv⟩ := i32_div_two_spec slots_len
    rw [hq, result_bind_ok]
    simp only [Result.ok.injEq, decide_eq_true_eq, IScalar.lt_equiv]
    intro hlt
    have hidx0 : 0 ≤ idx.val := by
      simpa [ge_iff_le, IScalar.le_equiv, h0] using hge
    cases hsn : slots_len.val with
    | ofNat m =>
      rw [hsn] at hqv
      have ht : Int.tdiv (Int.ofNat m) 2 = ((m / 2 : Nat) : Int) := rfl
      rw [ht] at hqv
      change 0 ≤ idx.val * 2 ∧ idx.val * 2 + 1 < (m : Int)
      omega
    | negSucc m =>
      rw [hsn] at hqv
      have ht : Int.tdiv (Int.negSucc m) 2 = -(((m + 1) / 2 : Nat) : Int) := rfl
      rw [ht] at hqv
      omega
  · simp [hge]

end RegexProofs
