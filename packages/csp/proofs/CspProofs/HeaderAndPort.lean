import Aeneas
import PionLean
import Csp.Types
import Csp.Funs

open Aeneas Aeneas.Std Result Pion csp

namespace CspProofs

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

private lemma i32_bne_iff (x y : Std.I32) : (x != y) = true ↔ x.val ≠ y.val := by
  simp only [bne_iff_ne, ne_eq]
  exact ⟨fun h hv => h (IScalar.eq_of_val_eq hv), fun h heq => h (congrArg IScalar.val heq)⟩

private lemma i32_val_neg1 : ((-1)#i32 : Std.I32).val = -1 := by
  change (BitVec.ofInt 32 (-1)).toInt = -1
  rw [BitVec.toInt_ofInt, Int.bmod_def]; omega

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

private lemma i32_mul_val (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val * y.val) (hhi : x.val * y.val ≤ 2147483647) :
    (Pion.I32.mul x y).val = x.val * y.val := by
  change (x.bv * y.bv).toInt = x.bv.toInt * y.bv.toInt
  rw [BitVec.toInt_mul, Int.bmod_def]
  change -2147483648 ≤ x.bv.toInt * y.bv.toInt at hlo
  change x.bv.toInt * y.bv.toInt ≤ 2147483647 at hhi
  omega

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

/-- HTAB (9), FF (12), printable ASCII `[32, 126]`, and non-ASCII (`> 127`) are legal CSP header bytes (CSP3 §2.2.1). -/
theorem csp_illegal_header_byte_allows_ws_and_printable (c : Std.I32)
    (h : c.val = 9 ∨ c.val = 12 ∨ (32 ≤ c.val ∧ c.val ≤ 126) ∨ 128 ≤ c.val) :
    csp_is_illegal_header_byte c = ok false := by
  unfold csp_is_illegal_header_byte
  apply congrArg ok
  rw [Bool.eq_false_iff]
  intro ht
  simp only [Bool.or_eq_true, Bool.and_eq_true, i32_beq_iff, i32_bne_iff, decide_eq_true_eq, i32_lt_iff] at ht
  change ((((c.val = 0 ∨ c.val = 10) ∨ c.val = 13) ∨ c.val = 127) ∨ ((c.val < 32 ∧ c.val ≠ 9) ∧ c.val ≠ 12)) at ht
  omega

/-- Every safe serialized token byte is printable ASCII `[33, 126] \ {';', ','}` and is strictly NOT an illegal header byte. -/
theorem csp_safe_serialized_byte_implies_legal_header (c : Std.I32)
    (hsafe : csp_is_safe_serialized_byte c = ok true) :
    33 ≤ c.val ∧ c.val ≤ 126 ∧ c.val ≠ 59 ∧ c.val ≠ 44 ∧
    csp_is_illegal_header_byte c = ok false := by
  unfold csp_is_safe_serialized_byte at hsafe
  simp only [ok.injEq, Bool.not_eq_true', Bool.or_eq_false_iff, decide_eq_false_iff_not,
             i32_le_iff, ge_iff_le, beq_eq_false_iff_ne] at hsafe
  have h1 : ¬ (c.val ≤ 32) := hsafe.1.1.1
  have h2 : ¬ (127 ≤ c.val) := hsafe.1.1.2
  have h3 : c.val ≠ 59 := fun heq => hsafe.1.2 (IScalar.eq_of_val_eq heq)
  have h4 : c.val ≠ 44 := fun heq => hsafe.2 (IScalar.eq_of_val_eq heq)
  have hlo : 33 ≤ c.val := by omega
  have hhi : c.val ≤ 126 := by omega
  exact ⟨hlo, hhi, h3, h4, csp_illegal_header_byte_allows_ws_and_printable c (Or.inr (Or.inr (Or.inl ⟨by omega, hhi⟩)))⟩

/-- Every safe directive-name byte (`[A-Za-z0-9-]`) is strictly a safe serialized token byte. -/
theorem csp_safe_directive_byte_implies_safe_serialized (c : Std.I32)
    (hdir : csp_is_safe_directive_byte c = ok true) :
    csp_is_safe_serialized_byte c = ok true := by
  unfold csp_is_safe_directive_byte at hdir
  unfold csp_is_alpha csp_is_digit at hdir
  rw [result_bind_ok] at hdir
  have hrange : (65 ≤ c.val ∧ c.val ≤ 90) ∨ (97 ≤ c.val ∧ c.val ≤ 122) ∨
                (48 ≤ c.val ∧ c.val ≤ 57) ∨ c.val = 45 := by
    by_cases ha : (((decide (c >= 65#i32)) && (decide (c <= 90#i32))) || ((decide (c >= 97#i32)) && (decide (c <= 122#i32)))) = true
    · simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at ha
      change (65 ≤ c.val ∧ c.val ≤ 90) ∨ (97 ≤ c.val ∧ c.val ≤ 122) at ha
      rcases ha with h1 | h2
      · exact Or.inl h1
      · exact Or.inr (Or.inl h2)
    · have haf : (((decide (c >= 65#i32)) && (decide (c <= 90#i32))) || ((decide (c >= 97#i32)) && (decide (c <= 122#i32)))) = false :=
        Bool.eq_false_iff.mpr ha
      rw [haf] at hdir
      simp only [Bool.false_eq_true, ↓reduceIte, result_bind_ok, ok.injEq, Bool.or_eq_true,
                 Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff, i32_beq_iff] at hdir
      change (48 ≤ c.val ∧ c.val ≤ 57) ∨ c.val = 45 at hdir
      rcases hdir with h3 | h4
      · exact Or.inr (Or.inr (Or.inl h3))
      · exact Or.inr (Or.inr (Or.inr h4))
  unfold csp_is_safe_serialized_byte
  apply congrArg ok
  simp only [Bool.not_eq_true', Bool.or_eq_false_iff, decide_eq_false_iff_not, i32_le_iff, ge_iff_le,
             beq_eq_false_iff_ne]
  refine ⟨⟨⟨?_, ?_⟩, ?_⟩, ?_⟩
  · change ¬ (c.val ≤ 32); omega
  · change ¬ (127 ≤ c.val); omega
  · intro heq; have hv : c.val = 59 := congrArg IScalar.val heq; omega
  · intro heq; have hv : c.val = 44 := congrArg IScalar.val heq; omega

/-- `csp_port_step` preserves `[0, 65535]` without `Int32` overflow or returns `-1` on invalid digit / port > 65535. -/
theorem csp_port_step_bounds (acc c : Std.I32) (hacc0 : 0 ≤ acc.val) (haccmax : acc.val ≤ 65535) :
    ∃ r : Std.I32, csp_port_step acc c = ok r ∧
      (r.val = -1 ∨ (48 ≤ c.val ∧ c.val ≤ 57 ∧ r.val = acc.val * 10 + (c.val - 48) ∧ 0 ≤ r.val ∧ r.val ≤ 65535)) := by
  unfold csp_port_step
  by_cases hbad : ((decide (c < 48#i32)) || (decide (c > 57#i32))) = true
  · simp only [hbad, ↓reduceIte]
    exact ⟨(-1)#i32, rfl, Or.inl i32_val_neg1⟩
  · have hbf : ((decide (c < 48#i32)) || (decide (c > 57#i32))) = false := Bool.eq_false_iff.mpr hbad
    simp only [hbf, Bool.false_eq_true, ↓reduceIte]
    simp only [Bool.or_eq_false_iff, decide_eq_false_iff_not, gt_iff_lt, i32_lt_iff] at hbf
    have hc48 : 48 ≤ c.val := by have := hbf.1; change ¬ (c.val < 48) at this; omega
    have hc57 : c.val ≤ 57 := by have := hbf.2; change ¬ (57 < c.val) at this; omega
    have hmul : (Pion.I32.mul acc 10#i32).val = acc.val * 10 :=
      i32_mul_val acc 10#i32 (by change -2147483648 ≤ acc.val * 10; omega)
                             (by change acc.val * 10 ≤ 2147483647; omega)
    have hsub : (Pion.I32.sub c 48#i32).val = c.val - 48 :=
      i32_sub_val c 48#i32 (by change -2147483648 ≤ c.val - 48; omega)
                           (by change c.val - 48 ≤ 2147483647; omega)
    set next := Pion.I32.add (Pion.I32.mul acc 10#i32) (Pion.I32.sub c 48#i32)
    have hnext : next.val = acc.val * 10 + (c.val - 48) := by
      have h1 := i32_add_val (Pion.I32.mul acc 10#i32) (Pion.I32.sub c 48#i32)
        (by rw [hmul, hsub]; omega) (by rw [hmul, hsub]; omega)
      rw [hmul, hsub] at h1
      exact h1
    by_cases hov : next > 65535#i32
    · simp only [hov, ↓reduceIte]
      exact ⟨(-1)#i32, rfl, Or.inl i32_val_neg1⟩
    · simp only [hov, ↓reduceIte]
      have hle : next.val ≤ 65535 := by
        have : ¬ (65535 < next.val) := fun h => hov ((i32_lt_iff 65535#i32 next).mpr h)
        omega
      exact ⟨next, rfl, Or.inr ⟨hc48, hc57, hnext, by omega, hle⟩⟩

end CspProofs
