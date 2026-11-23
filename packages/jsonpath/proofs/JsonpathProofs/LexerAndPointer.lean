import Aeneas
import PionLean
import Jsonpath.Types
import Jsonpath.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion jsonpath

namespace JsonpathProofs

private lemma result_bind_ok {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by simp
private lemma i32_le_iff (x y : Std.I32) : (x <= y) ↔ (x.val <= y.val) := Iff.rfl
private lemma i32_lt_iff (x y : Std.I32) : (x < y) ↔ (x.val < y.val) := Iff.rfl
private lemma i64_lt_iff (x y : Std.I64) : (x < y) ↔ (x.val < y.val) := Iff.rfl
private lemma i32_beq_iff (x y : Std.I32) : ((x == y) = true) ↔ (x.val = y.val) := by
  cases x; cases y; simp [BEq.beq, IScalar.val, BitVec.toInt_inj]

private lemma i64_sub_val (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val - y.val) (hhi : x.val - y.val ≤ 9223372036854775807) :
    (Pion.I64.sub x y).val = x.val - y.val := by
  unfold Pion.I64.sub
  have hv : (x.bv - y.bv).toInt = x.val - y.val := by
    rw [BitVec.toInt_sub]
    have hx : x.bv.toInt = x.val := rfl
    have hy : y.bv.toInt = y.val := rfl
    rw [hx, hy]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  exact hv

private lemma i64_div_10 (x : Std.I64) :
    ∃ q : Std.I64, Pion.I64.div x 10#i64 = ok q ∧ q.val = x.val.tdiv 10 := by
  unfold Pion.I64.div
  have hne : (10#i64 : Std.I64).val ≠ 0 := by decide
  rcases IScalar.div_spec (x := x) (y := 10#i64) hne (fun h => absurd h.2 (by decide)) with ⟨q, hq, hqv⟩
  exact ⟨q, hq, hqv⟩

/-- Theorem 2: Strict RFC 9535 §2.1 whitespace (`B = %x20 / %x09 / %x0A / %x0D`), excluding `\v`, `\f`, NBSP. -/
lemma is_rfc9535_ws_exact (b : Std.I32) :
    is_rfc9535_ws b = ok true ↔ (b.val = 32 ∨ b.val = 9 ∨ b.val = 10 ∨ b.val = 13) := by
  unfold is_rfc9535_ws
  simp only [ok.injEq, Bool.or_eq_true, i32_beq_iff]
  change ((b.val = 32 ∨ b.val = 9) ∨ b.val = 10) ∨ b.val = 13 ↔ _
  omega

/-- Theorem 3: RFC 9535 §2.5.1.1 `is_name_first` rejects all UTF-16 surrogates (`0xD800..0xDFFF`), negatives, and `> 0x10FFFF`. -/
theorem is_name_first_excludes_surrogates_and_invalid (cp : Std.I32)
    (h : cp.val < 0 ∨ (55296 ≤ cp.val ∧ cp.val ≤ 57343) ∨ 1114111 < cp.val) :
    is_name_first cp = ok false := by
  unfold is_name_first
  apply congrArg ok
  rw [Bool.eq_false_iff]; intro ht
  simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff, i32_beq_iff] at ht
  change (((((65 ≤ cp.val ∧ cp.val ≤ 90) ∨ (97 ≤ cp.val ∧ cp.val ≤ 122)) ∨ cp.val = 95) ∨
           (128 ≤ cp.val ∧ cp.val ≤ 55295)) ∨ (57344 ≤ cp.val ∧ cp.val ≤ 1114111)) at ht
  omega

/-- Theorem 4: Every `name-first` codepoint is also a valid `name-char`. -/
theorem is_name_first_subset_name_char (cp : Std.I32) (hf : is_name_first cp = ok true) :
    is_name_char cp = ok true := by
  unfold is_name_char
  rw [hf, result_bind_ok]
  simp only [Bool.true_or]

/-- Theorem 5: ASCII digits `'0'..'9'` are rejected by `is_name_first` but accepted by `is_name_char`. -/
theorem is_name_first_disjoint_digit (cp : Std.I32) (h0 : 48 ≤ cp.val) (h9 : cp.val ≤ 57) :
    is_name_first cp = ok false ∧ is_name_char cp = ok true := by
  have hnf : is_name_first cp = ok false := by
    unfold is_name_first
    apply congrArg ok
    rw [Bool.eq_false_iff]; intro ht
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff, i32_beq_iff] at ht
    change (((((65 ≤ cp.val ∧ cp.val ≤ 90) ∨ (97 ≤ cp.val ∧ cp.val ≤ 122)) ∨ cp.val = 95) ∨
             (128 ≤ cp.val ∧ cp.val ≤ 55295)) ∨ (57344 ≤ cp.val ∧ cp.val ≤ 1114111)) at ht
    omega
  refine ⟨hnf, ?_⟩
  unfold is_name_char
  rw [hnf, result_bind_ok]
  apply congrArg ok
  simp only [Bool.false_or, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff]
  change 48 ≤ cp.val ∧ cp.val ≤ 57; omega

/-- Theorem 6: RFC 9535 whitespace and `name-char` are strictly disjoint. -/
theorem is_rfc9535_ws_disjoint_name_char (b : Std.I32) (hw : is_rfc9535_ws b = ok true) :
    is_name_char b = ok false := by
  have hwe := (is_rfc9535_ws_exact b).mp hw
  have hnf : is_name_first b = ok false := by
    unfold is_name_first
    apply congrArg ok
    rw [Bool.eq_false_iff]; intro ht
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff, i32_beq_iff] at ht
    change (((((65 ≤ b.val ∧ b.val ≤ 90) ∨ (97 ≤ b.val ∧ b.val ≤ 122)) ∨ b.val = 95) ∨
             (128 ≤ b.val ∧ b.val ≤ 55295)) ∨ (57344 ≤ b.val ∧ b.val ≤ 1114111)) at ht
    omega
  unfold is_name_char
  rw [hnf, result_bind_ok]
  apply congrArg ok
  rw [Bool.eq_false_iff]; intro ht
  simp only [Bool.false_or, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at ht
  change 48 ≤ b.val ∧ b.val ≤ 57 at ht
  omega

/-- Theorem 7: Exact I-JSON `2^53 - 1` overflow guard: `rfc9535_ijson_step_overflow acc d = ok false ↔ acc * 10 + d ≤ 2^53 - 1`. -/
theorem rfc9535_ijson_step_overflow_exact (acc d : Std.I64)
    (_ha0 : 0 ≤ acc.val) (hd0 : 0 ≤ d.val) (hd9 : d.val ≤ 9) :
    rfc9535_ijson_step_overflow acc d = ok false ↔ acc.val * 10 + d.val ≤ 9007199254740991 := by
  unfold rfc9535_ijson_step_overflow
  set diff := Pion.I64.sub 9007199254740991#i64 d
  have hdiff_v : diff.val = 9007199254740991 - d.val :=
    i64_sub_val 9007199254740991#i64 d (by change -9223372036854775808 ≤ 9007199254740991 - d.val; omega)
      (by change 9007199254740991 - d.val ≤ 9223372036854775807; omega)
  rcases i64_div_10 diff with ⟨q, hq, hqv⟩
  rw [hq, result_bind_ok]
  have hq_exact : q.val = (9007199254740991 - d.val) / 10 := by
    rw [hqv, hdiff_v]
    have hnn : 0 ≤ 9007199254740991 - d.val := by omega
    rw [Int.tdiv_eq_ediv_of_nonneg hnn]
  simp only [ok.injEq, decide_eq_false_iff_not, gt_iff_lt, i64_lt_iff]
  omega

end JsonpathProofs
