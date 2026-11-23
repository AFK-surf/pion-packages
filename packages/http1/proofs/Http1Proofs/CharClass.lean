import Http1Proofs.Core

open Aeneas Aeneas.Std Result Pion http1

namespace Http1Proofs

/-- RFC 9110 §5.6.2: `is_tchar_byte` rejects all CTLs, SP, DEL, and non-ASCII bytes. -/
theorem is_tchar_byte_rejects_ctl_sp_nonascii (b : Std.I32)
    (h : b.val ≤ 32 ∨ b.val = 127 ∨ 128 ≤ b.val) :
    is_tchar_byte b = ok false := by
  unfold is_tchar_byte
  congr 1
  simp only [Bool.or_eq_false_iff, Bool.and_eq_false_iff, decide_eq_false_iff_not,
    beq_eq_false_iff_ne, ne_eq, iscalar_eq_iff, iscalar_le_iff]
  norm_num
  omega

/-- RFC 9110 §5.6.2: `is_tchar_byte` accepts all ASCII digits and letters. -/
theorem is_tchar_byte_accepts_alnum (b : Std.I32)
    (h : (48 ≤ b.val ∧ b.val ≤ 57) ∨ (65 ≤ b.val ∧ b.val ≤ 90) ∨ (97 ≤ b.val ∧ b.val ≤ 122)) :
    is_tchar_byte b = ok true := by
  unfold is_tchar_byte
  congr 1
  simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq,
    beq_iff_eq, iscalar_eq_iff, iscalar_le_iff]
  norm_num
  omega

/-- RFC 9112: `is_uri_byte` holds iff `b` is visible ASCII `VCHAR` (`0x21..0x7E`). -/
theorem is_uri_byte_spec (b : Std.I32) :
    is_uri_byte b = ok (decide (33 ≤ b.val ∧ b.val ≤ 126)) := by
  unfold is_uri_byte
  congr 1

/-- RFC 9110: `is_header_val_byte` accepts HTAB, SP..VCHAR, and obs-text (`0x80..0xFF`),
    and rejects all other bytes including CR, LF, NUL, and DEL. -/
theorem is_header_val_byte_spec (b : Std.I32) :
    is_header_val_byte b =
      ok (decide (b.val = 9 ∨ (32 ≤ b.val ∧ b.val ≤ 126) ∨ (128 ≤ b.val ∧ b.val ≤ 255))) := by
  unfold is_header_val_byte
  congr 1
  by_cases h : b.val = 9 ∨ (32 ≤ b.val ∧ b.val ≤ 126) ∨ (128 ≤ b.val ∧ b.val ≤ 255)
  · rw [decide_eq_true h]
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq,
      beq_iff_eq, iscalar_eq_iff, iscalar_le_iff]
    norm_num
    omega
  · rw [decide_eq_false h]
    simp only [Bool.or_eq_false_iff, Bool.and_eq_false_iff, decide_eq_false_iff_not,
      beq_eq_false_iff_ne, ne_eq, iscalar_eq_iff, iscalar_le_iff]
    norm_num
    omega

/-- Exact specification of `is_crlf_or_nul_byte`. -/
theorem is_crlf_or_nul_byte_spec (b : Std.I32) :
    is_crlf_or_nul_byte b = ok (decide (b.val = 13 ∨ b.val = 10 ∨ b.val = 0)) := by
  unfold is_crlf_or_nul_byte
  congr 1
  by_cases h : b.val = 13 ∨ b.val = 10 ∨ b.val = 0
  · rw [decide_eq_true h]
    simp only [Bool.or_eq_true, beq_iff_eq, iscalar_eq_iff]
    norm_num
    omega
  · rw [decide_eq_false h]
    simp only [Bool.or_eq_false_iff, beq_eq_false_iff_ne, ne_eq, iscalar_eq_iff]
    norm_num
    omega

/-- CRLF/NUL injection impossibility: no valid header-value byte can be CR, LF, or NUL. -/
theorem is_header_val_byte_rejects_crlf_nul (b : Std.I32)
    (h : is_crlf_or_nul_byte b = ok true) :
    is_header_val_byte b = ok false := by
  rw [is_crlf_or_nul_byte_spec] at h
  have h' : b.val = 13 ∨ b.val = 10 ∨ b.val = 0 := of_decide_eq_true (result_ok_inj h)
  rw [is_header_val_byte_spec]
  congr 1
  exact decide_eq_false (by omega)

/-- CRLF/NUL injection impossibility: no valid `tchar` byte can be CR, LF, or NUL. -/
theorem is_tchar_byte_rejects_crlf_nul (b : Std.I32)
    (h : is_crlf_or_nul_byte b = ok true) :
    is_tchar_byte b = ok false := by
  rw [is_crlf_or_nul_byte_spec] at h
  have h' : b.val = 13 ∨ b.val = 10 ∨ b.val = 0 := of_decide_eq_true (result_ok_inj h)
  exact is_tchar_byte_rejects_ctl_sp_nonascii b (by omega)

/-- CRLF/NUL injection impossibility: no valid URI byte can be CR, LF, or NUL. -/
theorem is_uri_byte_rejects_crlf_nul (b : Std.I32)
    (h : is_crlf_or_nul_byte b = ok true) :
    is_uri_byte b = ok false := by
  rw [is_crlf_or_nul_byte_spec] at h
  have h' : b.val = 13 ∨ b.val = 10 ∨ b.val = 0 := of_decide_eq_true (result_ok_inj h)
  rw [is_uri_byte_spec]
  congr 1
  exact decide_eq_false (by omega)

/-- Exact specification of `ascii_lower_byte`. -/
theorem ascii_lower_byte_spec (b : Std.I32) :
    ∃ r : Std.I32, ascii_lower_byte b = ok r ∧
      r.val = if 65 ≤ b.val ∧ b.val ≤ 90 then b.val + 32 else b.val := by
  unfold ascii_lower_byte
  by_cases h : 65 ≤ b.val ∧ b.val ≤ 90
  · have hcond : ((decide (b ≥ 65#i32)) && (decide (b ≤ 90#i32))) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff]; norm_num; omega
    refine ⟨Pion.I32.add b 32#i32, ?_, ?_⟩
    · rw [hcond]; rfl
    · have h32 : (32#i32).val = 32 := by norm_num
      rw [ite_eq_left h, i32_add_val] <;> omega
  · have hcond : ((decide (b ≥ 65#i32)) && (decide (b ≤ 90#i32))) = false := by
      simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, iscalar_le_iff]; norm_num; omega
    refine ⟨b, ?_, ?_⟩
    · rw [hcond]; rfl
    · rw [ite_eq_right h]

/-- `ascii_lower_byte` is idempotent on all `Std.I32` values. -/
theorem ascii_lower_byte_idempotent (b : Std.I32) :
    (do let x ← ascii_lower_byte b; ascii_lower_byte x) = ascii_lower_byte b := by
  obtain ⟨r1, hr1, hv1⟩ := ascii_lower_byte_spec b
  obtain ⟨r2, hr2, hv2⟩ := ascii_lower_byte_spec r1
  rw [hr1, result_bind_ok, hr2]
  congr 1
  apply (iscalar_eq_iff r2 r1).mpr
  split_ifs at hv1 hv2 <;> omega

/-- Exact specification of `hex_digit_value`. -/
theorem hex_digit_value_spec (b : Std.I32) :
    ∃ r : Std.I32, hex_digit_value b = ok r ∧
      r.val =
        if 48 ≤ b.val ∧ b.val ≤ 57 then b.val - 48
        else if 65 ≤ b.val ∧ b.val ≤ 70 then b.val - 55
        else if 97 ≤ b.val ∧ b.val ≤ 102 then b.val - 87
        else -1 := by
  unfold hex_digit_value
  by_cases h1 : 48 ≤ b.val ∧ b.val ≤ 57
  · have hc1 : ((decide (b ≥ 48#i32)) && (decide (b ≤ 57#i32))) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff]; norm_num; omega
    refine ⟨Pion.I32.sub b 48#i32, ?_, ?_⟩
    · rw [hc1]; rfl
    · have h48 : (48#i32).val = 48 := by norm_num
      rw [ite_eq_left h1, i32_sub_val] <;> omega
  · have hc1 : ((decide (b ≥ 48#i32)) && (decide (b ≤ 57#i32))) = false := by
      simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, iscalar_le_iff]; norm_num; omega
    by_cases h2 : 65 ≤ b.val ∧ b.val ≤ 70
    · have hc2 : ((decide (b ≥ 65#i32)) && (decide (b ≤ 70#i32))) = true := by
        simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff]; norm_num; omega
      refine ⟨Pion.I32.sub b 55#i32, ?_, ?_⟩
      · rw [hc1, hc2]; rfl
      · have h55 : (55#i32).val = 55 := by norm_num
        rw [ite_eq_right h1, ite_eq_left h2, i32_sub_val] <;> omega
    · have hc2 : ((decide (b ≥ 65#i32)) && (decide (b ≤ 70#i32))) = false := by
        simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, iscalar_le_iff]; norm_num; omega
      by_cases h3 : 97 ≤ b.val ∧ b.val ≤ 102
      · have hc3 : ((decide (b ≥ 97#i32)) && (decide (b ≤ 102#i32))) = true := by
          simp only [Bool.and_eq_true, decide_eq_true_eq, iscalar_le_iff]; norm_num; omega
        refine ⟨Pion.I32.sub b 87#i32, ?_, ?_⟩
        · rw [hc1, hc2, hc3]; rfl
        · have h87 : (87#i32).val = 87 := by norm_num
          rw [ite_eq_right h1, ite_eq_right h2, ite_eq_left h3, i32_sub_val] <;> omega
      · have hc3 : ((decide (b ≥ 97#i32)) && (decide (b ≤ 102#i32))) = false := by
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, iscalar_le_iff]; norm_num; omega
        refine ⟨(-1)#i32, ?_, ?_⟩
        · rw [hc1, hc2, hc3]; rfl
        · rw [ite_eq_right h1, ite_eq_right h2, ite_eq_right h3]; norm_num

/-- Whenever `hex_digit_value b` returns a non-negative value, it lies in `[0, 15]`. -/
theorem hex_digit_value_bounds (b v : Std.I32)
    (h : hex_digit_value b = ok v) (hge : 0 ≤ v.val) :
    v.val ≤ 15 := by
  obtain ⟨r, hr, hv⟩ := hex_digit_value_spec b
  have heq : v = r := result_ok_inj (h.symm.trans hr)
  subst heq
  split_ifs at hv <;> omega

/-- `hex_digit_value` is invariant under ASCII lowercasing. -/
theorem hex_digit_value_case_insensitive (b : Std.I32) :
    (do let lb ← ascii_lower_byte b; hex_digit_value lb) = hex_digit_value b := by
  obtain ⟨lb, hlb, hlbv⟩ := ascii_lower_byte_spec b
  obtain ⟨r1, hr1, hv1⟩ := hex_digit_value_spec lb
  obtain ⟨r2, hr2, hv2⟩ := hex_digit_value_spec b
  rw [hlb, result_bind_ok, hr1, hr2]
  congr 1
  apply (iscalar_eq_iff r1 r2).mpr
  split_ifs at hlbv hv1 hv2 <;> omega

/-- RFC 3986: `is_host_byte` rejects all CTLs, SP, DEL, and non-ASCII bytes. -/
theorem is_host_byte_rejects_ctl_sp_nonascii (b : Std.I32)
    (h : b.val ≤ 32 ∨ b.val = 127 ∨ 128 ≤ b.val) :
    is_host_byte b = ok false := by
  unfold is_host_byte
  congr 1
  simp only [Bool.or_eq_false_iff, Bool.and_eq_false_iff, decide_eq_false_iff_not,
    beq_eq_false_iff_ne, ne_eq, iscalar_eq_iff, iscalar_le_iff]
  norm_num
  omega

end Http1Proofs
