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

/-- 1. Lazy DFA `LeftmostFirst` and `SetAll` modes are mutually exclusive. -/
theorem dfa_mode_exclusive (mode : DfaMode) :
    dfa_is_leftmost mode = ok true → dfa_is_set_all mode = ok false := by
  cases mode <;> simp [dfa_is_leftmost, dfa_is_set_all]

/-- 2. ASCII word boundary `\b` and non-word boundary `\B` are exact complements. -/
theorem dfa_look_word_ascii_complement
    (st sl pw nl nw eoi : Bool) :
    ∃ r1 r2 : Bool,
      dfa_look_holds .WordBoundaryAscii st sl pw nl nw eoi = ok r1 ∧
      dfa_look_holds .NotWordBoundaryAscii st sl pw nl nw eoi = ok r2 ∧
      r1 = !r2 := by
  refine ⟨pw != nw, pw == nw, rfl, rfl, ?_⟩
  cases pw <;> cases nw <;> rfl

/-- 3. Unicode word boundary `\b` and non-word boundary `\B` are exact complements. -/
theorem dfa_look_word_unicode_complement
    (st sl pw nl nw eoi : Bool) :
    ∃ r1 r2 : Bool,
      dfa_look_holds .WordBoundaryUnicode st sl pw nl nw eoi = ok r1 ∧
      dfa_look_holds .NotWordBoundaryUnicode st sl pw nl nw eoi = ok r2 ∧
      r1 = !r2 := by
  refine ⟨pw != nw, pw == nw, rfl, rfl, ?_⟩
  cases pw <;> cases nw <;> rfl

/-- 4. End-of-text `\z` implies multiline end-of-line `(?m)$`. -/
theorem dfa_look_end_text_implies_end_line
    (st sl pw nl nw eoi : Bool) :
    dfa_look_holds .EndText st sl pw nl nw eoi = ok true →
    dfa_look_holds .EndLine st sl pw nl nw eoi = ok true := by
  simp [dfa_look_holds]
  intro h
  simp [h]

/-- 5. Multiline end-of-line `(?m)$` holds iff at end-of-input or before `\n`. -/
theorem dfa_look_end_line_iff
    (st sl pw nl nw eoi : Bool) :
    dfa_look_holds .EndLine st sl pw nl nw eoi = ok (eoi || nl) := by
  rfl

/-- 6. Reverse-NFA lookaround reversal is an involution. -/
theorem reverse_look_kind_involutive (lk : LookKind) :
    ∃ r : LookKind,
      reverse_look_kind lk = ok r ∧ reverse_look_kind r = ok lk := by
  cases lk <;> exact ⟨_, rfl, rfl⟩

/-- 7. Reverse-NFA lookaround reversal preserves word-boundary classification. -/
theorem reverse_look_preserves_word_boundary (lk : LookKind) :
    ∃ r : LookKind, ∃ b : Bool,
      reverse_look_kind lk = ok r ∧
      look_is_word_boundary lk = ok b ∧
      look_is_word_boundary r = ok b := by
  cases lk <;> exact ⟨_, _, rfl, rfl, rfl⟩

/-- 8. One-Pass DFA compilation guard guarantees no lookarounds, 1..31 captures
    (`nslots ∈ [2, 62]`, fitting in a signed 64-bit bitmask), and `≤ 512` NFA states. -/
theorem onepass_can_compile_iff
    (has_look : Bool) (num_captures num_nfa : Std.I32) :
    onepass_can_compile has_look num_captures num_nfa = ok true ↔
    (has_look = false ∧
      1 ≤ num_captures.val ∧ num_captures.val ≤ 31 ∧ num_nfa.val ≤ 512) := by
  unfold onepass_can_compile
  have h1 : (1#i32).val = 1 := by decide
  have h31 : (31#i32).val = 31 := by decide
  have h512 : (512#i32).val = 512 := by decide
  simp only [Result.ok.injEq, Bool.and_eq_true, Bool.not_eq_true', decide_eq_true_eq,
    ge_iff_le, IScalar.le_equiv, h1, h31, h512]
  constructor
  · rintro ⟨⟨⟨h0, ha⟩, hb⟩, hc⟩
    exact ⟨h0, ha, hb, hc⟩
  · rintro ⟨h0, ha, hb, hc⟩
    exact ⟨⟨⟨h0, ha⟩, hb⟩, hc⟩

/-- 9. Out-of-range capture slots leave the One-Pass 64-bit transition bitmask unchanged. -/
theorem onepass_mask_add_slot_oob
    (mask : Std.I64) (slot nslots : Std.I32)
    (h : slot.val < 0 ∨ slot.val ≥ nslots.val ∨ slot.val ≥ 63) :
    onepass_mask_add_slot mask slot nslots = ok mask := by
  unfold onepass_mask_add_slot
  have h0 : (0#i32).val = 0 := by decide
  have h63 : (63#i32).val = 63 := by decide
  have hcond : (((decide (slot >= 0#i32)) && (decide (slot < nslots))) &&
      (decide (slot < 63#i32))) = false := by
    simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, ge_iff_le,
      IScalar.le_equiv, IScalar.lt_equiv, h0, h63]
    omega
  rw [hcond]
  rfl

/-- 10. Recording the same capture slot twice in a One-Pass transition bitmask is idempotent. -/
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

/-- 11. `captures_slot_valid idx slots_len = true` guarantees both `idx * 2` and
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

/-- 12. Negative capture group indices are always rejected by `captures_slot_valid`. -/
theorem captures_slot_valid_neg (idx slots_len : Std.I32) (h : idx.val < 0) :
    captures_slot_valid idx slots_len = ok false := by
  unfold captures_slot_valid
  have h0 : (0#i32).val = 0 := by decide
  have hnge : ¬ (idx >= 0#i32) := by
    simp only [ge_iff_le, IScalar.le_equiv, h0]
    omega
  simp [hnge]

end RegexProofs
