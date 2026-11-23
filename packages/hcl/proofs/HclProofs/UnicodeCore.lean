import Aeneas
import PionLean
import Hcl.Types
import Hcl.Funs

open Aeneas Aeneas.Std Result Pion hcl

namespace HclProofs

private lemma result_bind_ok' {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

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

private lemma i32_add_val' (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val + y.val) (hhi : x.val + y.val ≤ 2147483647) :
    (Pion.I32.add x y).val = x.val + y.val := by
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add, Int.bmod_def]
  change -2147483648 ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt ≤ 2147483647 at hhi
  omega

private lemma i32_sub_val' (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val - y.val) (hhi : x.val - y.val ≤ 2147483647) :
    (Pion.I32.sub x y).val = x.val - y.val := by
  change (x.bv - y.bv).toInt = x.bv.toInt - y.bv.toInt
  rw [BitVec.toInt_sub, Int.bmod_def]
  change -2147483648 ≤ x.bv.toInt - y.bv.toInt at hlo
  change x.bv.toInt - y.bv.toInt ≤ 2147483647 at hhi
  omega

/-- Theorem 13: On ASCII `[0, 127]`, `is_unicode_space` matches `{HTAB(9), LF(10), VT(11), FF(12), CR(13), SP(32)}` exactly. -/
theorem is_unicode_space_ascii_exact (cp : Std.I32) (h0 : 0 ≤ cp.val) (h127 : cp.val ≤ 127) :
    is_unicode_space cp = ok true ↔
      cp.val = 32 ∨ cp.val = 9 ∨ cp.val = 10 ∨ cp.val = 11 ∨ cp.val = 12 ∨ cp.val = 13 := by
  unfold is_unicode_space
  by_cases hle : cp <= 32#i32
  · simp only [hle, ↓reduceIte, ok.injEq, Bool.or_eq_true, i32_beq_iff']
    change (((((cp.val = 32 ∨ cp.val = 9) ∨ cp.val = 10) ∨ cp.val = 11) ∨ cp.val = 12) ∨ cp.val = 13) ↔ _
    tauto
  · simp only [hle, ↓reduceIte]
    have hgt : 32 < cp.val := by
      have : ¬ (cp.val ≤ 32) := fun h => hle ((i32_le_iff' cp 32#i32).mpr h)
      omega
    have hf : ((((((((cp == 133#i32) || (cp == 160#i32)) || (cp == 5760#i32)) || (cp == 8232#i32)) || (cp == 8233#i32)) || (cp == 8239#i32)) || (cp == 8287#i32)) || (cp == 12288#i32)) = false := by
      rw [Bool.eq_false_iff]; intro ht
      simp only [Bool.or_eq_true, i32_beq_iff'] at ht
      change (((((((cp.val = 133 ∨ cp.val = 160) ∨ cp.val = 5760) ∨ cp.val = 8232) ∨ cp.val = 8233) ∨ cp.val = 8239) ∨ cp.val = 8287) ∨ cp.val = 12288) at ht
      omega
    simp only [hf, Bool.false_eq_true, ↓reduceIte, ok.injEq, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
    change (8192 ≤ cp.val ∧ cp.val ≤ 8202) ↔ _
    omega

/-- Theorem 15: On ASCII `[0, 127]`, `is_unicode_space` and `is_hcl_ident_cont` are strictly disjoint. -/
theorem is_unicode_space_disjoint_ascii_ident (cp : Std.I32) (h0 : 0 ≤ cp.val) (h127 : cp.val ≤ 127) :
    ¬ (is_unicode_space cp = ok true ∧ is_hcl_ident_cont cp = ok true) := by
  rintro ⟨hsp, hid⟩
  rw [is_unicode_space_ascii_exact cp h0 h127] at hsp
  unfold is_hcl_ident_cont is_hcl_ident_start at hid
  rw [result_bind_ok'] at hid
  simp only [ok.injEq, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff', i32_beq_iff'] at hid
  change (((((((65 ≤ cp.val ∧ cp.val ≤ 90) ∨ (97 ≤ cp.val ∧ cp.val ≤ 122)) ∨ cp.val = 95) ∨ 128 ≤ cp.val) ∨
           (48 ≤ cp.val ∧ cp.val ≤ 57)) ∨ cp.val = 45)) at hid
  omega

/-- Theorem 16: `unicode_cp_to_lower` maps ASCII uppercase `'A'..'Z'` exactly to `cp + 32`. -/
lemma unicode_cp_to_lower_ascii_upper (cp : Std.I32) (hlo : 65 ≤ cp.val) (hhi : cp.val ≤ 90) :
    ∃ r : Std.I32, unicode_cp_to_lower cp = ok r ∧ r.val = cp.val + 32 := by
  unfold unicode_cp_to_lower
  have ht : ((decide (cp >= 65#i32)) && (decide (cp <= 90#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
    change 65 ≤ cp.val ∧ cp.val ≤ 90; omega
  simp only [ht, ↓reduceIte]
  exact ⟨Pion.I32.add cp 32#i32, rfl,
    i32_add_val' cp 32#i32 (by change -2147483648 ≤ cp.val + 32; omega) (by change cp.val + 32 ≤ 2147483647; omega)⟩

/-- Theorem 17: `unicode_cp_to_upper` maps ASCII lowercase `'a'..'z'` exactly to `cp - 32`. -/
lemma unicode_cp_to_upper_ascii_lower (cp : Std.I32) (hlo : 97 ≤ cp.val) (hhi : cp.val ≤ 122) :
    ∃ r : Std.I32, unicode_cp_to_upper cp = ok r ∧ r.val = cp.val - 32 := by
  unfold unicode_cp_to_upper
  have ht : ((decide (cp >= 97#i32)) && (decide (cp <= 122#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
    change 97 ≤ cp.val ∧ cp.val ≤ 122; omega
  simp only [ht, ↓reduceIte]
  exact ⟨Pion.I32.sub cp 32#i32, rfl,
    i32_sub_val' cp 32#i32 (by change -2147483648 ≤ cp.val - 32; omega) (by change cp.val - 32 ≤ 2147483647; omega)⟩

/-- Theorem 18: ASCII uppercase `'A'..'Z'` roundtrips losslessly under `to_lower >>= to_upper`. -/
theorem unicode_ascii_case_roundtrip_upper (cp : Std.I32) (hlo : 65 ≤ cp.val) (hhi : cp.val ≤ 90) :
    (do let lo ← unicode_cp_to_lower cp; unicode_cp_to_upper lo) = ok cp := by
  obtain ⟨lo, hlo_eq, hlo_val⟩ := unicode_cp_to_lower_ascii_upper cp hlo hhi
  rw [hlo_eq, result_bind_ok']
  obtain ⟨up, hup_eq, hup_val⟩ := unicode_cp_to_upper_ascii_lower lo (by omega) (by omega)
  have heq : up = cp := IScalar.eq_of_val_eq (by omega)
  rw [hup_eq, heq]

/-- Theorem 20: `unicode_cp_to_lower` is idempotent on all ASCII codepoints `cp < 128`. -/
theorem unicode_cp_to_lower_ascii_idempotent (cp : Std.I32) (h128 : cp.val < 128) :
    (do let r ← unicode_cp_to_lower cp; unicode_cp_to_lower r) = unicode_cp_to_lower cp := by
  by_cases hup : 65 ≤ cp.val ∧ cp.val ≤ 90
  · obtain ⟨r, hr, hrv⟩ := unicode_cp_to_lower_ascii_upper cp hup.1 hup.2
    rw [hr, result_bind_ok']
    unfold unicode_cp_to_lower
    have hf : ((decide (r >= 65#i32)) && (decide (r <= 90#i32))) = false := by
      rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h
      change 65 ≤ r.val ∧ r.val ≤ 90 at h; omega
    have hlt : r < 128#i32 := (i32_lt_iff' r 128#i32).mpr (by change r.val < 128; omega)
    simp only [hf, Bool.false_eq_true, hlt, ↓reduceIte]
  · have hfix : unicode_cp_to_lower cp = ok cp := by
      unfold unicode_cp_to_lower
      have hf : ((decide (cp >= 65#i32)) && (decide (cp <= 90#i32))) = false := by
        rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h
        change 65 ≤ cp.val ∧ cp.val ≤ 90 at h; omega
      have hlt : cp < 128#i32 := (i32_lt_iff' cp 128#i32).mpr (by change cp.val < 128; omega)
      simp only [hf, Bool.false_eq_true, hlt, ↓reduceIte]
    rw [hfix, result_bind_ok', hfix]

/-- Theorem 22: Latin-1 Supplement uppercase `À..Ö` (`0xC0..0xD6`) lowers by `+32` and roundtrips via `to_upper`. -/
theorem unicode_latin1_case_roundtrip (cp : Std.I32) (hlo : 192 ≤ cp.val) (hhi : cp.val ≤ 214) :
    (do let lo ← unicode_cp_to_lower cp; unicode_cp_to_upper lo) = ok cp := by
  have h1 : unicode_cp_to_lower cp = ok (Pion.I32.add cp 32#i32) := by
    unfold unicode_cp_to_lower
    have f1 : ((decide (cp >= 65#i32)) && (decide (cp <= 90#i32))) = false := by
      rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h
      change 65 ≤ cp.val ∧ cp.val ≤ 90 at h; omega
    have f2 : ¬ (cp < 128#i32) := fun h => by have := (i32_lt_iff' cp 128#i32).mp h; change cp.val < 128 at this; omega
    have t3 : (((decide (cp >= 192#i32)) && (decide (cp <= 214#i32))) || ((decide (cp >= 216#i32)) && (decide (cp <= 222#i32)))) = true := by
      simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
      exact Or.inl ⟨by change 192 ≤ cp.val; omega, by change cp.val ≤ 214; omega⟩
    simp only [f1, f2, t3, Bool.false_eq_true, ↓reduceIte]
  rw [h1, result_bind_ok']
  set lo := Pion.I32.add cp 32#i32
  have hlo_v : lo.val = cp.val + 32 :=
    i32_add_val' cp 32#i32 (by change -2147483648 ≤ cp.val + 32; omega) (by change cp.val + 32 ≤ 2147483647; omega)
  unfold unicode_cp_to_upper
  have f1 : ((decide (lo >= 97#i32)) && (decide (lo <= 122#i32))) = false := by
    rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h
    change 97 ≤ lo.val ∧ lo.val ≤ 122 at h; omega
  have f2 : ¬ (lo < 128#i32) := fun h => by have := (i32_lt_iff' lo 128#i32).mp h; change lo.val < 128 at this; omega
  have t3 : (((decide (lo >= 224#i32)) && (decide (lo <= 246#i32))) || ((decide (lo >= 248#i32)) && (decide (lo <= 254#i32)))) = true := by
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
    exact Or.inl ⟨by change 224 ≤ lo.val; omega, by change lo.val ≤ 246; omega⟩
  simp only [f1, f2, t3, Bool.false_eq_true, ↓reduceIte]
  apply congrArg ok
  apply IScalar.eq_of_val_eq
  have hs := i32_sub_val' lo 32#i32 (by change -2147483648 ≤ lo.val - 32; omega) (by change lo.val - 32 ≤ 2147483647; omega)
  change (Pion.I32.sub lo 32#i32).val = lo.val - 32 at hs
  omega

end HclProofs
