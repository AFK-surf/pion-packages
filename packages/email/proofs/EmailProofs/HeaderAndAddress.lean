import Aeneas
import PionLean
import Email.Types
import Email.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion email

namespace EmailProofs

private lemma result_bind_ok {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by simp
private lemma i32_le_iff (x y : Std.I32) : (x <= y) ↔ (x.val <= y.val) := Iff.rfl
private lemma i32_lt_iff (x y : Std.I32) : (x < y) ↔ (x.val < y.val) := Iff.rfl
private lemma i32_beq_iff (x y : Std.I32) : ((x == y) = true) ↔ (x.val = y.val) := by
  cases x; cases y; simp [BEq.beq, IScalar.val, BitVec.toInt_inj]
private lemma i32_bne_iff (x y : Std.I32) : ((x != y) = true) ↔ (x.val ≠ y.val) := by
  cases x; cases y; simp [bne, BEq.beq, IScalar.val, BitVec.toInt_inj]
private lemma i32_add_val (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val + y.val) (hhi : x.val + y.val ≤ 2147483647) :
    (Pion.I32.add x y).val = x.val + y.val := by
  unfold Pion.I32.add
  have hv : (x.bv + y.bv).toInt = x.val + y.val := by
    rw [BitVec.toInt_add]
    have hx : x.bv.toInt = x.val := rfl
    have hy : y.bv.toInt = y.val := rfl
    rw [hx, hy]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  exact hv

/-- Theorem 1: `EmailLimits::default` has strictly positive limits with `max_header_bytes < max_body_bytes`. -/
theorem email_limits_default_positive :
    ∃ l : EmailLimits, EmailLimits.default = ok l ∧
      l.max_depth.val = 16 ∧ l.max_parts.val = 1024 ∧ l.max_headers.val = 1024 ∧
      l.max_header_bytes.val = 262144 ∧ l.max_body_bytes.val = 67108864 ∧
      0 < l.max_depth.val ∧ l.max_header_bytes.val < l.max_body_bytes.val := by
  refine ⟨EmailLimits.mk 16#i32 1024#i32 1024#i32 262144#i32 67108864#i32, rfl, ?_⟩
  refine ⟨rfl, rfl, rfl, rfl, rfl, by decide, by decide⟩

/-- Theorem 2: RFC 5322 `email_is_ftext` exact range (`33..126` excluding `:` = 58), rejecting CTL/SP/DEL/non-ASCII. -/
theorem email_is_ftext_exact (c : Std.I32) :
    email_is_ftext c = ok true ↔ (33 ≤ c.val ∧ c.val ≤ 126 ∧ c.val ≠ 58) := by
  unfold email_is_ftext
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff, i32_bne_iff]
  change (33 ≤ c.val ∧ c.val ≤ 126) ∧ c.val ≠ 58 ↔ _
  omega

/-- Theorem 3: `email_is_injection_byte` exact characterization (`NUL`, `LF`, `CR`). -/
theorem email_is_injection_byte_exact (c : Std.I32) :
    email_is_injection_byte c = ok true ↔ (c.val = 0 ∨ c.val = 10 ∨ c.val = 13) := by
  unfold email_is_injection_byte
  simp only [ok.injEq, Bool.or_eq_true, i32_beq_iff]
  change (c.val = 0 ∨ c.val = 10) ∨ c.val = 13 ↔ _
  omega

/-- Theorem 4: Valid header-name bytes (`email_is_ftext`) are strictly disjoint from injection bytes (`CR/LF/NUL`). -/
theorem email_is_ftext_disjoint_injection (c : Std.I32)
    (hf : email_is_ftext c = ok true) :
    email_is_injection_byte c = ok false := by
  have hfe := (email_is_ftext_exact c).mp hf
  unfold email_is_injection_byte
  apply congrArg ok
  rw [Bool.eq_false_iff]
  intro h
  simp only [Bool.or_eq_true, i32_beq_iff] at h
  change (c.val = 0 ∨ c.val = 10) ∨ c.val = 13 at h
  omega

/-- Theorem 5: `email_effective_fold_limit` always returns at least `20` and defaults to RFC 5322 `78` when `< 20`. -/
theorem email_effective_fold_limit_bounds (max_col : Std.I32) :
    ∃ r : Std.I32, email_effective_fold_limit max_col = ok r ∧
      20 ≤ r.val ∧
      (max_col.val < 20 → r.val = 78) ∧
      (20 ≤ max_col.val → r.val = max_col.val) := by
  unfold email_effective_fold_limit
  by_cases h : max_col < 20#i32
  · simp only [h, ↓reduceIte]
    have hv := (i32_lt_iff max_col 20#i32).mp h
    change max_col.val < 20 at hv
    refine ⟨78#i32, rfl, by decide, fun _ => rfl, fun hge => by omega⟩
  · simp only [h, ↓reduceIte]
    have hv : ¬ (max_col.val < 20) := fun hlt => h ((i32_lt_iff max_col 20#i32).mpr hlt)
    refine ⟨max_col, rfl, by omega, fun hlt => by omega, fun _ => rfl⟩

/-- Theorem 6: `email_effective_fold_limit` is idempotent across all 32-bit inputs. -/
theorem email_effective_fold_limit_idempotent (max_col : Std.I32) :
    (do let r ← email_effective_fold_limit max_col; email_effective_fold_limit r) =
      email_effective_fold_limit max_col := by
  rcases email_effective_fold_limit_bounds max_col with ⟨r, hr, h20, _, _⟩
  rw [hr, result_bind_ok]
  unfold email_effective_fold_limit
  have hge : ¬ (r < 20#i32) := fun h => by
    have hv := (i32_lt_iff r 20#i32).mp h
    change r.val < 20 at hv; omega
  simp only [hge, ↓reduceIte]

/-- Theorem 7: `hdr_ascii_lower` is idempotent for all `Int` values. -/
theorem hdr_ascii_lower_idempotent (c : Std.I32) :
    (do let r ← hdr_ascii_lower c; hdr_ascii_lower r) = hdr_ascii_lower c := by
  unfold hdr_ascii_lower
  rw [result_bind_ok]
  by_cases h : ((decide (c >= 65#i32)) && (decide (c <= 90#i32))) = true
  · simp only [h, ↓reduceIte]
    have hcr := h
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at hcr
    change 65 ≤ c.val ∧ c.val ≤ 90 at hcr
    set r := Pion.I32.add c 32#i32
    have hrv : r.val = c.val + 32 :=
      i32_add_val c 32#i32 (by change -2147483648 ≤ c.val + 32; omega) (by change c.val + 32 ≤ 2147483647; omega)
    have hfalse : ((decide (r >= 65#i32)) && (decide (r <= 90#i32))) = false := by
      rw [Bool.eq_false_iff]; intro h2
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at h2
      change 65 ≤ r.val ∧ r.val ≤ 90 at h2; omega
    simp only [hfalse, Bool.false_eq_true, ↓reduceIte]
  · have hf := Bool.eq_false_iff.mpr h
    simp only [hf, Bool.false_eq_true, ↓reduceIte]

/-- Theorem 8: `hdr_ascii_lower` and `dt_lower` are extensionally identical on all `Int` values. -/
theorem hdr_ascii_lower_eq_dt_lower (c : Std.I32) :
    hdr_ascii_lower c = dt_lower c := by
  rfl

/-- Theorem 9: `addr_is_atext` accepts all ASCII alphanumerics (`A-Z`, `a-z`, `0-9`) and RFC 6532 UTF-8 (`>= 128`). -/
theorem addr_is_atext_accepts_alnum_and_utf8 (c : Std.I32)
    (h : (65 ≤ c.val ∧ c.val ≤ 90) ∨ (97 ≤ c.val ∧ c.val ≤ 122) ∨ (48 ≤ c.val ∧ c.val ≤ 57) ∨ 128 ≤ c.val) :
    addr_is_atext c = ok true := by
  unfold addr_is_atext
  by_cases h128 : c >= 128#i32
  · simp only [h128, ↓reduceIte]
  · simp only [h128, ↓reduceIte]
    have hlt : c.val < 128 := by
      have hn : ¬ (128 ≤ c.val) := fun hge => h128 ((i32_le_iff 128#i32 c).mpr hge)
      omega
    have hcond : ((((decide (c >= 65#i32)) && (decide (c <= 90#i32))) || ((decide (c >= 97#i32)) && (decide (c <= 122#i32)))) || ((decide (c >= 48#i32)) && (decide (c <= 57#i32)))) = true := by
      simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff]
      change ((65 ≤ c.val ∧ c.val ≤ 90) ∨ (97 ≤ c.val ∧ c.val ≤ 122)) ∨ (48 ≤ c.val ∧ c.val ≤ 57)
      omega
    simp only [hcond, ↓reduceIte]

/-- Theorem 10: `addr_is_atext` rejects all control/space bytes (`<= 32`), DEL (`127`), `.`, `@`, `"`, `\`, and RFC 5322 specials. -/
theorem addr_is_atext_rejects_ctl_and_specials (c : Std.I32)
    (h : c.val ≤ 32 ∨ c.val = 127 ∨ c.val = 46 ∨ c.val = 64 ∨ c.val = 34 ∨ c.val = 92 ∨
         c.val = 40 ∨ c.val = 41 ∨ c.val = 60 ∨ c.val = 62 ∨ c.val = 91 ∨ c.val = 93 ∨
         c.val = 58 ∨ c.val = 59 ∨ c.val = 44) :
    addr_is_atext c = ok false := by
  unfold addr_is_atext
  have h128 : ¬ (c >= 128#i32) := fun hge => by
    have hv := (i32_le_iff 128#i32 c).mp hge; change 128 ≤ c.val at hv; omega
  have halnum : ((((decide (c >= 65#i32)) && (decide (c <= 90#i32))) || ((decide (c >= 97#i32)) && (decide (c <= 122#i32)))) || ((decide (c >= 48#i32)) && (decide (c <= 57#i32)))) = false := by
    rw [Bool.eq_false_iff]; intro ht
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff] at ht
    change ((65 ≤ c.val ∧ c.val ≤ 90) ∨ (97 ≤ c.val ∧ c.val ≤ 122)) ∨ (48 ≤ c.val ∧ c.val ≤ 57) at ht
    omega
  simp only [h128, halnum, Bool.false_eq_true, ↓reduceIte]
  apply congrArg ok
  rw [Bool.eq_false_iff]; intro ht
  simp only [Bool.or_eq_true, i32_beq_iff] at ht
  change ((((((((((((((((((c.val = 33 ∨ c.val = 35) ∨ c.val = 36) ∨ c.val = 37) ∨ c.val = 38) ∨ c.val = 39) ∨ c.val = 42) ∨ c.val = 43) ∨ c.val = 45) ∨ c.val = 47) ∨ c.val = 61) ∨ c.val = 63) ∨ c.val = 94) ∨ c.val = 95) ∨ c.val = 96) ∨ c.val = 123) ∨ c.val = 124) ∨ c.val = 125) ∨ c.val = 126) at ht
  omega

/-- Theorem 11: RFC 5322 `addr_is_dtext` exact range (`33..126` excluding `[`, `\`, `]`) and disjointness from injection bytes. -/
theorem addr_is_dtext_exact_and_safe (c : Std.I32) :
    (addr_is_dtext c = ok true ↔ (33 ≤ c.val ∧ c.val ≤ 126 ∧ c.val ≠ 91 ∧ c.val ≠ 92 ∧ c.val ≠ 93)) ∧
    (addr_is_dtext c = ok true → email_is_injection_byte c = ok false) := by
  have hex : addr_is_dtext c = ok true ↔ (33 ≤ c.val ∧ c.val ≤ 126 ∧ c.val ≠ 91 ∧ c.val ≠ 92 ∧ c.val ≠ 93) := by
    unfold addr_is_dtext
    simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff, i32_bne_iff]
    change ((((33 ≤ c.val ∧ c.val ≤ 126) ∧ c.val ≠ 91) ∧ c.val ≠ 92) ∧ c.val ≠ 93) ↔ _
    omega
  refine ⟨hex, fun hd => ?_⟩
  have hde := hex.mp hd
  unfold email_is_injection_byte
  apply congrArg ok
  rw [Bool.eq_false_iff]; intro hi
  simp only [Bool.or_eq_true, i32_beq_iff] at hi
  change (c.val = 0 ∨ c.val = 10) ∨ c.val = 13 at hi
  omega

/-- Theorem 12: Quoted local-part bytes (`addr_is_qtext_char`) strictly exclude all injection bytes (`CR/LF/NUL`) and DEL. -/
theorem addr_is_qtext_char_disjoint_injection (c : Std.I32)
    (hq : addr_is_qtext_char c = ok true) :
    email_is_injection_byte c = ok false ∧ c.val ≠ 127 := by
  unfold addr_is_qtext_char at hq
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff, i32_bne_iff] at hq
  change 32 ≤ c.val ∧ c.val ≠ 127 at hq
  refine ⟨?_, hq.2⟩
  unfold email_is_injection_byte
  apply congrArg ok
  rw [Bool.eq_false_iff]; intro hi
  simp only [Bool.or_eq_true, i32_beq_iff] at hi
  change (c.val = 0 ∨ c.val = 10) ∨ c.val = 13 at hi
  omega

end EmailProofs
