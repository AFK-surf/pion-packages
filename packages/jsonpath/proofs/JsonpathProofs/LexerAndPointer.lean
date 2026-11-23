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

/-- Theorem 1: `JsonPathLimits::default` has exact strictly positive limits with `max_results ≤ max_nodes_visited`. -/
theorem jsonpath_limits_default_spec :
    ∃ l : JsonPathLimits, JsonPathLimits.default = ok l ∧
      l.max_depth.val = 128 ∧ l.max_nodes_visited.val = 1000000 ∧
      l.max_results.val = 100000 ∧ l.max_patch_ops.val = 100000 ∧
      0 < l.max_depth.val ∧ l.max_results.val ≤ l.max_nodes_visited.val := by
  refine ⟨JsonPathLimits.mk 128#i32 1000000#i32 100000#i32 100000#i32, rfl, ?_⟩
  refine ⟨rfl, rfl, rfl, rfl, by decide, by decide⟩

/-- Theorem 2: Strict RFC 9535 §2.1 whitespace (`B = %x20 / %x09 / %x0A / %x0D`), excluding `\v`, `\f`, NBSP. -/
theorem is_rfc9535_ws_exact (b : Std.I32) :
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

/-- Theorem 8: Exact I-JSON `2^53 - 1` boundary: `900719925474099 * 10 + 1` succeeds while `+ 2` overflows. -/
theorem rfc9535_ijson_step_overflow_boundary :
    rfc9535_ijson_step_overflow 900719925474099#i64 1#i64 = ok false ∧
    rfc9535_ijson_step_overflow 900719925474099#i64 2#i64 = ok true := by
  constructor
  · exact (rfc9535_ijson_step_overflow_exact 900719925474099#i64 1#i64 (by decide) (by decide) (by decide)).mpr (by decide)
  · have h := (rfc9535_ijson_step_overflow_exact 900719925474099#i64 2#i64 (by decide) (by decide) (by decide))
    unfold rfc9535_ijson_step_overflow at h ⊢
    rcases i64_div_10 (Pion.I64.sub 9007199254740991#i64 2#i64) with ⟨q, hq, hqv⟩
    rw [hq, result_bind_ok] at h ⊢
    cases hb : decide (900719925474099#i64 > q)
    · exfalso; have hle := h.mp (congrArg ok hb); revert hle; decide
    · rfl

/-- Theorem 9: RFC 9535 §2.7 `norm_name_byte_len` is always in `{1, 2, 6}` (strictly in `[1, 6]`). -/
theorem norm_name_byte_len_bounds (b : Std.I32) :
    ∃ r : Std.I32, norm_name_byte_len b = ok r ∧ (r.val = 1 ∨ r.val = 2 ∨ r.val = 6) := by
  unfold norm_name_byte_len
  by_cases h2 : (((((((b == 8#i32) || (b == 9#i32)) || (b == 10#i32)) || (b == 12#i32)) || (b == 13#i32)) || (b == 39#i32)) || (b == 92#i32)) = true
  · simp only [h2, ↓reduceIte]; exact ⟨2#i32, rfl, Or.inr (Or.inl rfl)⟩
  · have h2f := Bool.eq_false_iff.mpr h2
    simp only [h2f, Bool.false_eq_true, ↓reduceIte]
    by_cases h6 : b < 32#i32
    · simp only [h6, ↓reduceIte]; exact ⟨6#i32, rfl, Or.inr (Or.inr rfl)⟩
    · simp only [h6, ↓reduceIte]; exact ⟨1#i32, rfl, Or.inl rfl⟩

/-- Theorem 10: Printable non-quote/non-backslash bytes have normalized length `1`, while `'` (39) and `\` (92) have length `2`. -/
theorem norm_name_byte_len_printable_and_quotes (b : Std.I32) :
    (32 ≤ b.val ∧ b.val ≠ 39 ∧ b.val ≠ 92 → norm_name_byte_len b = ok 1#i32) ∧
    (b.val = 39 ∨ b.val = 92 → norm_name_byte_len b = ok 2#i32) := by
  constructor
  · rintro ⟨h32, h39, h92⟩
    unfold norm_name_byte_len
    have h2f : (((((((b == 8#i32) || (b == 9#i32)) || (b == 10#i32)) || (b == 12#i32)) || (b == 13#i32)) || (b == 39#i32)) || (b == 92#i32)) = false := by
      rw [Bool.eq_false_iff]; intro ht
      simp only [Bool.or_eq_true, i32_beq_iff] at ht
      change ((((((b.val = 8 ∨ b.val = 9) ∨ b.val = 10) ∨ b.val = 12) ∨ b.val = 13) ∨ b.val = 39) ∨ b.val = 92) at ht
      omega
    have h6f : ¬ (b < 32#i32) := fun h => by
      have hv := (i32_lt_iff b 32#i32).mp h; change b.val < 32 at hv; omega
    simp only [h2f, h6f, Bool.false_eq_true, ↓reduceIte]
  · intro hq
    unfold norm_name_byte_len
    have h2t : (((((((b == 8#i32) || (b == 9#i32)) || (b == 10#i32)) || (b == 12#i32)) || (b == 13#i32)) || (b == 39#i32)) || (b == 92#i32)) = true := by
      simp only [Bool.or_eq_true, i32_beq_iff]
      change ((((((b.val = 8 ∨ b.val = 9) ∨ b.val = 10) ∨ b.val = 12) ∨ b.val = 13) ∨ b.val = 39) ∨ b.val = 92)
      omega
    simp only [h2t, ↓reduceIte]

/-- Theorem 11: RFC 6901 `pointer_needs_escape` exact characterization (`~` = 126 or `/` = 47). -/
theorem pointer_needs_escape_exact (b : Std.I32) :
    pointer_needs_escape b = ok true ↔ (b.val = 126 ∨ b.val = 47) := by
  unfold pointer_needs_escape
  simp only [ok.injEq, Bool.or_eq_true, i32_beq_iff]
  change (b.val = 126 ∨ b.val = 47) ↔ _
  exact Iff.rfl

/-- Theorem 12: RFC 6901 `pointer_unescape_tilde` is a bijection from `{'0', '1'}` onto `pointer_needs_escape` (`'~'`, `'/'`), returning `-1` otherwise. -/
theorem pointer_unescape_tilde_bijection (next : Std.I32) :
    pointer_unescape_tilde 48#i32 = ok 126#i32 ∧
    pointer_unescape_tilde 49#i32 = ok 47#i32 ∧
    (next.val ≠ 48 ∧ next.val ≠ 49 → pointer_unescape_tilde next = ok (-1)#i32) := by
  refine ⟨by unfold pointer_unescape_tilde; rfl, by unfold pointer_unescape_tilde; rfl, ?_⟩
  rintro ⟨h48, h49⟩
  unfold pointer_unescape_tilde
  have n48 : next ≠ 48#i32 := fun h => h48 (by rw [h]; rfl)
  have n49 : next ≠ 49#i32 := fun h => h49 (by rw [h]; rfl)
  simp only [n48, n49, ↓reduceIte]

end JsonpathProofs
