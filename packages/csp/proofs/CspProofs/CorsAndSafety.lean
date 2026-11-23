import Aeneas
import PionLean
import Csp.Types
import Csp.Funs
import CspProofs.HeaderAndPort

open Aeneas Aeneas.Std Result Pion csp

namespace CspProofs

private lemma i32_lt_iff' (x y : Std.I32) : (x < y) ↔ (x.val < y.val) := Iff.rfl
private lemma i32_le_iff' (x y : Std.I32) : (x ≤ y) ↔ (x.val ≤ y.val) := Iff.rfl

private lemma i32_beq_iff' (x y : Std.I32) : (x == y) = true ↔ x.val = y.val := by
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

private lemma i32_bne_iff' (x y : Std.I32) : (x != y) = true ↔ x.val ≠ y.val := by
  simp only [bne_iff_ne, ne_eq]
  exact ⟨fun h hv => h (IScalar.eq_of_val_eq hv), fun h heq => h (congrArg IScalar.val heq)⟩

/-- Theorem 13: `cors_is_include` returns `true` iff `mode = CredentialsMode.Include`. -/
theorem cors_is_include_iff (mode : CredentialsMode) :
    cors_is_include mode = ok true ↔ mode = CredentialsMode.Include := by
  cases mode <;> unfold cors_is_include <;> simp

/-- Theorem 14: `cors_clamp_max_age` computes exact Fetch §4.9 clamping `if v < 0 then 0 else min v 86400` for ALL `Int32`. -/
theorem cors_clamp_max_age_exact (v : Std.I32) :
    ∃ r : Std.I32, cors_clamp_max_age v = ok r ∧
      r.val = (if v.val < 0 then 0 else min v.val 86400) := by
  unfold cors_clamp_max_age
  by_cases hhi : v > 86400#i32
  · simp only [hhi, ↓reduceIte]
    have hv : 86400 < v.val := (i32_lt_iff' 86400#i32 v).mp hhi
    refine ⟨86400#i32, rfl, ?_⟩
    change (86400 : Int) = if v.val < 0 then 0 else min v.val 86400
    have hnot : ¬ (v.val < 0) := by omega
    simp only [hnot, ↓reduceIte]
    symm; exact min_eq_right (by omega)
  · simp only [hhi, ↓reduceIte]
    have hvle : v.val ≤ 86400 := by
      have : ¬ (86400 < v.val) := fun h => hhi ((i32_lt_iff' 86400#i32 v).mpr h)
      omega
    by_cases hge : v >= 0#i32
    · simp only [hge, ↓reduceIte]
      have hv0 : 0 ≤ v.val := (i32_le_iff' 0#i32 v).mp hge
      refine ⟨v, rfl, ?_⟩
      have hnot : ¬ (v.val < 0) := by omega
      simp only [hnot, ↓reduceIte]
      symm; exact min_eq_left hvle
    · simp only [hge, ↓reduceIte]
      have hvneg : v.val < 0 := by
        have : ¬ (0 ≤ v.val) := fun h => hge ((i32_le_iff' 0#i32 v).mpr h)
        omega
      refine ⟨0#i32, rfl, ?_⟩
      change (0 : Int) = if v.val < 0 then 0 else min v.val 86400
      simp only [hvneg, ↓reduceIte]

/-- Theorem 15: `cors_clamp_max_age` always lands in `[0, 86400]` for ALL `Int32`. -/
theorem cors_clamp_max_age_bounds (v : Std.I32) :
    ∃ r : Std.I32, cors_clamp_max_age v = ok r ∧ 0 ≤ r.val ∧ r.val ≤ 86400 := by
  obtain ⟨r, hr, hval⟩ := cors_clamp_max_age_exact v
  refine ⟨r, hr, ?_, ?_⟩
  · rw [hval]
    split_ifs with h
    · omega
    · exact le_min (by omega) (by omega)
  · rw [hval]
    split_ifs with h
    · omega
    · exact min_le_right _ _

/-- Theorem 16: `cors_clamp_max_age` is monotonically non-decreasing across all `Int32`. -/
theorem cors_clamp_max_age_mono (v1 v2 : Std.I32) (hle : v1.val ≤ v2.val) :
    ∃ r1 r2 : Std.I32, cors_clamp_max_age v1 = ok r1 ∧ cors_clamp_max_age v2 = ok r2 ∧ r1.val ≤ r2.val := by
  obtain ⟨r1, hr1, hv1⟩ := cors_clamp_max_age_exact v1
  obtain ⟨r2, hr2, hv2⟩ := cors_clamp_max_age_exact v2
  refine ⟨r1, r2, hr1, hr2, ?_⟩
  rw [hv1, hv2]
  split_ifs with h1 h2
  · omega
  · exact le_min (by omega) (by omega)
  · omega
  · exact min_le_min hle (le_refl _)

/-- Theorem 17: `cors_clamp_max_age` is idempotent. -/
theorem cors_clamp_max_age_idempotent (v : Std.I32) :
    ∃ r : Std.I32, cors_clamp_max_age v = ok r ∧ cors_clamp_max_age r = ok r := by
  obtain ⟨r, hr, hlo, hhi⟩ := cors_clamp_max_age_bounds v
  obtain ⟨r2, hr2, hv2⟩ := cors_clamp_max_age_exact r
  have hnot : ¬ (r.val < 0) := by omega
  simp only [hnot, ↓reduceIte, min_eq_left hhi] at hv2
  have heq : r2 = r := IScalar.eq_of_val_eq hv2
  rw [heq] at hr2
  exact ⟨r, hr, hr2⟩

/-- Theorem 18: Every C0 control byte (except HTAB=9) and DEL (127) is CORS-unsafe (Fetch §2.2.2). -/
theorem cors_unsafe_header_byte_rejects_controls (c : Std.I32)
    (h : (c.val < 32 ∧ c.val ≠ 9) ∨ c.val = 127) :
    cors_is_unsafe_request_header_byte c = ok true := by
  unfold cors_is_unsafe_request_header_byte
  have hcond : (((decide (c < 32#i32)) && (c != 9#i32)) || (c == 127#i32)) = true := by
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, i32_lt_iff', i32_bne_iff', i32_beq_iff']
    exact h
  simp only [hcond, ↓reduceIte]

/-- Theorem 19: HTAB (9) and ASCII alphanumerics (`0-9`, `A-Z`, `a-z`) are all CORS-safe request-header bytes. -/
theorem cors_unsafe_header_byte_allows_htab_and_alnum (c : Std.I32)
    (h : c.val = 9 ∨ (48 ≤ c.val ∧ c.val ≤ 57) ∨ (65 ≤ c.val ∧ c.val ≤ 90) ∨ (97 ≤ c.val ∧ c.val ≤ 122)) :
    cors_is_unsafe_request_header_byte c = ok false := by
  unfold cors_is_unsafe_request_header_byte
  have hcf : (((decide (c < 32#i32)) && (c != 9#i32)) || (c == 127#i32)) = false := by
    rw [Bool.eq_false_iff]
    intro ht
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, i32_lt_iff', i32_bne_iff', i32_beq_iff'] at ht
    change (c.val < 32 ∧ c.val ≠ 9) ∨ c.val = 127 at ht
    omega
  simp only [hcf, Bool.false_eq_true, ↓reduceIte]
  apply congrArg ok
  rw [Bool.eq_false_iff]
  intro ht
  simp only [Bool.or_eq_true, i32_beq_iff'] at ht
  change ((((((((((((c.val = 34 ∨ c.val = 40) ∨ c.val = 41) ∨ c.val = 58) ∨ c.val = 60) ∨ c.val = 62) ∨ c.val = 63) ∨ c.val = 64) ∨ c.val = 91) ∨ c.val = 92) ∨ c.val = 93) ∨ c.val = 123) ∨ c.val = 125) at ht
  omega

/-- Theorem 20: All 13 Fetch §2.2.2 forbidden punctuation bytes `" ( ) : < > ? @ [ \ ] { }` are CORS-unsafe. -/
theorem cors_unsafe_header_byte_rejects_13_punct (c : Std.I32)
    (h : c.val = 34 ∨ c.val = 40 ∨ c.val = 41 ∨ c.val = 58 ∨ c.val = 60 ∨ c.val = 62 ∨
         c.val = 63 ∨ c.val = 64 ∨ c.val = 91 ∨ c.val = 92 ∨ c.val = 93 ∨ c.val = 123 ∨ c.val = 125) :
    cors_is_unsafe_request_header_byte c = ok true := by
  unfold cors_is_unsafe_request_header_byte
  have hcf : (((decide (c < 32#i32)) && (c != 9#i32)) || (c == 127#i32)) = false := by
    rw [Bool.eq_false_iff]
    intro ht
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, i32_lt_iff', i32_bne_iff', i32_beq_iff'] at ht
    change (c.val < 32 ∧ c.val ≠ 9) ∨ c.val = 127 at ht
    omega
  simp only [hcf, Bool.false_eq_true, ↓reduceIte]
  apply congrArg ok
  simp only [Bool.or_eq_true, i32_beq_iff']
  change ((((((((((((c.val = 34 ∨ c.val = 40) ∨ c.val = 41) ∨ c.val = 58) ∨ c.val = 60) ∨ c.val = 62) ∨ c.val = 63) ∨ c.val = 64) ∨ c.val = 91) ∨ c.val = 92) ∨ c.val = 93) ∨ c.val = 123) ∨ c.val = 125)
  omega

/-- Theorem 21: Every CORS-safelisted language byte is strictly CORS-safe (never a CORS-unsafe request-header byte). -/
theorem cors_language_byte_implies_safe_header_byte (c : Std.I32)
    (hlang : cors_is_language_byte c = ok true) :
    cors_is_unsafe_request_header_byte c = ok false := by
  unfold cors_is_language_byte at hlang
  simp only [ok.injEq, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff', i32_beq_iff'] at hlang
  change ((((((((((48 ≤ c.val ∧ c.val ≤ 57) ∨ (65 ≤ c.val ∧ c.val ≤ 90)) ∨ (97 ≤ c.val ∧ c.val ≤ 122)) ∨ c.val = 32) ∨ c.val = 42) ∨ c.val = 44) ∨ c.val = 45) ∨ c.val = 46) ∨ c.val = 59) ∨ c.val = 61) at hlang
  unfold cors_is_unsafe_request_header_byte
  have hcf : (((decide (c < 32#i32)) && (c != 9#i32)) || (c == 127#i32)) = false := by
    rw [Bool.eq_false_iff]
    intro ht
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, i32_lt_iff', i32_bne_iff', i32_beq_iff'] at ht
    change (c.val < 32 ∧ c.val ≠ 9) ∨ c.val = 127 at ht
    omega
  simp only [hcf, Bool.false_eq_true, ↓reduceIte]
  apply congrArg ok
  rw [Bool.eq_false_iff]
  intro ht
  simp only [Bool.or_eq_true, i32_beq_iff'] at ht
  change ((((((((((((c.val = 34 ∨ c.val = 40) ∨ c.val = 41) ∨ c.val = 58) ∨ c.val = 60) ∨ c.val = 62) ∨ c.val = 63) ∨ c.val = 64) ∨ c.val = 91) ∨ c.val = 92) ∨ c.val = 93) ∨ c.val = 123) ∨ c.val = 125) at ht
  omega

/-- Theorem 22: Every CORS-safelisted language byte lies strictly within printable ASCII `[32, 122]`. -/
theorem cors_language_byte_subset_printable (c : Std.I32)
    (hlang : cors_is_language_byte c = ok true) :
    32 ≤ c.val ∧ c.val ≤ 122 := by
  unfold cors_is_language_byte at hlang
  simp only [ok.injEq, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff', i32_beq_iff'] at hlang
  change ((((((((((48 ≤ c.val ∧ c.val ≤ 57) ∨ (65 ≤ c.val ∧ c.val ≤ 90)) ∨ (97 ≤ c.val ∧ c.val ≤ 122)) ∨ c.val = 32) ∨ c.val = 42) ∨ c.val = 44) ∨ c.val = 45) ∨ c.val = 46) ∨ c.val = 59) ∨ c.val = 61) at hlang
  omega

/-- Theorem 23: `cors_is_http_ws` characterizes exactly `{HTAB(9), LF(10), CR(13), SP(32)}`. -/
theorem cors_http_ws_spec (c : Std.I32) :
    cors_is_http_ws c = ok true ↔ c.val = 32 ∨ c.val = 9 ∨ c.val = 10 ∨ c.val = 13 := by
  unfold cors_is_http_ws
  simp only [ok.injEq, Bool.or_eq_true, i32_beq_iff']
  change (((c.val = 32 ∨ c.val = 9) ∨ c.val = 10) ∨ c.val = 13) ↔ _
  tauto

/-- Theorem 24: `csp_is_ws` characterizes `{HTAB(9), FF(12), SP(32)}` and every CSP whitespace byte is a legal header byte. -/
theorem csp_ws_spec_and_legal_header (c : Std.I32) :
    (csp_is_ws c = ok true ↔ c.val = 32 ∨ c.val = 9 ∨ c.val = 12) ∧
    (csp_is_ws c = ok true → csp_is_illegal_header_byte c = ok false) := by
  have hspec : csp_is_ws c = ok true ↔ c.val = 32 ∨ c.val = 9 ∨ c.val = 12 := by
    unfold csp_is_ws
    simp only [ok.injEq, Bool.or_eq_true, i32_beq_iff']
    change ((c.val = 32 ∨ c.val = 9) ∨ c.val = 12) ↔ _
    tauto
  refine ⟨hspec, ?_⟩
  intro hws
  have hv := hspec.mp hws
  rcases hv with h32 | h9 | h12
  · exact csp_illegal_header_byte_allows_ws_and_printable c (Or.inr (Or.inr (Or.inl ⟨by omega, by omega⟩)))
  · exact csp_illegal_header_byte_allows_ws_and_printable c (Or.inl h9)
  · exact csp_illegal_header_byte_allows_ws_and_printable c (Or.inr (Or.inl h12))

end CspProofs
