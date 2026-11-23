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

/-- Theorem 14: All Go `unicode.IsSpace` non-ASCII whitespace codepoints (`U+0085`, `U+00A0`, `U+1680`, `U+2000..U+200A`, `U+2028`, `U+2029`, `U+202F`, `U+205F`, `U+3000`) are accepted. -/
theorem is_unicode_space_non_ascii_members (cp : Std.I32)
    (h : cp.val = 0x85 ∨ cp.val = 0xA0 ∨ cp.val = 0x1680 ∨ (0x2000 ≤ cp.val ∧ cp.val ≤ 0x200A) ∨
         cp.val = 0x2028 ∨ cp.val = 0x2029 ∨ cp.val = 0x202F ∨ cp.val = 0x205F ∨ cp.val = 0x3000) :
    is_unicode_space cp = ok true := by
  unfold is_unicode_space
  have hgt : ¬ (cp <= 32#i32) := fun hle => by
    have hv := (i32_le_iff' cp 32#i32).mp hle
    change cp.val ≤ 32 at hv; omega
  simp only [hgt, ↓reduceIte]
  by_cases hmid : ((((((((cp == 133#i32) || (cp == 160#i32)) || (cp == 5760#i32)) || (cp == 8232#i32)) || (cp == 8233#i32)) || (cp == 8239#i32)) || (cp == 8287#i32)) || (cp == 12288#i32)) = true
  · simp only [hmid, ↓reduceIte]
  · have hmf := Bool.eq_false_iff.mpr hmid
    simp only [hmf, Bool.false_eq_true, ↓reduceIte]
    simp only [Bool.or_eq_false_iff] at hmf
    simp only [Bool.eq_false_iff, ne_eq, i32_beq_iff'] at hmf
    apply congrArg ok
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
    change 8192 ≤ cp.val ∧ cp.val ≤ 8202
    have h133 : cp.val ≠ 133 := hmf.1.1.1.1.1.1.1
    have h160 : cp.val ≠ 160 := hmf.1.1.1.1.1.1.2
    have h5760 : cp.val ≠ 5760 := hmf.1.1.1.1.1.2
    have h8232 : cp.val ≠ 8232 := hmf.1.1.1.1.2
    have h8233 : cp.val ≠ 8233 := hmf.1.1.1.2
    have h8239 : cp.val ≠ 8239 := hmf.1.1.2
    have h8287 : cp.val ≠ 8287 := hmf.1.2
    have h12288 : cp.val ≠ 12288 := hmf.2
    clear hmid hmf
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
theorem unicode_cp_to_lower_ascii_upper (cp : Std.I32) (hlo : 65 ≤ cp.val) (hhi : cp.val ≤ 90) :
    ∃ r : Std.I32, unicode_cp_to_lower cp = ok r ∧ r.val = cp.val + 32 := by
  unfold unicode_cp_to_lower
  have ht : ((decide (cp >= 65#i32)) && (decide (cp <= 90#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
    change 65 ≤ cp.val ∧ cp.val ≤ 90; omega
  simp only [ht, ↓reduceIte]
  exact ⟨Pion.I32.add cp 32#i32, rfl,
    i32_add_val' cp 32#i32 (by change -2147483648 ≤ cp.val + 32; omega) (by change cp.val + 32 ≤ 2147483647; omega)⟩

/-- Theorem 17: `unicode_cp_to_upper` maps ASCII lowercase `'a'..'z'` exactly to `cp - 32`. -/
theorem unicode_cp_to_upper_ascii_lower (cp : Std.I32) (hlo : 97 ≤ cp.val) (hhi : cp.val ≤ 122) :
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

/-- Theorem 19: ASCII lowercase `'a'..'z'` roundtrips losslessly under `to_upper >>= to_lower`. -/
theorem unicode_ascii_case_roundtrip_lower (cp : Std.I32) (hlo : 97 ≤ cp.val) (hhi : cp.val ≤ 122) :
    (do let up ← unicode_cp_to_upper cp; unicode_cp_to_lower up) = ok cp := by
  obtain ⟨up, hup_eq, hup_val⟩ := unicode_cp_to_upper_ascii_lower cp hlo hhi
  rw [hup_eq, result_bind_ok']
  obtain ⟨lo, hlo_eq, hlo_val⟩ := unicode_cp_to_lower_ascii_upper up (by omega) (by omega)
  have heq : lo = cp := IScalar.eq_of_val_eq (by omega)
  rw [hlo_eq, heq]

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

/-- Theorem 21: `unicode_cp_to_upper` is idempotent on all ASCII codepoints `cp < 128`. -/
theorem unicode_cp_to_upper_ascii_idempotent (cp : Std.I32) (h128 : cp.val < 128) :
    (do let r ← unicode_cp_to_upper cp; unicode_cp_to_upper r) = unicode_cp_to_upper cp := by
  by_cases hlo : 97 ≤ cp.val ∧ cp.val ≤ 122
  · obtain ⟨r, hr, hrv⟩ := unicode_cp_to_upper_ascii_lower cp hlo.1 hlo.2
    rw [hr, result_bind_ok']
    unfold unicode_cp_to_upper
    have hf : ((decide (r >= 97#i32)) && (decide (r <= 122#i32))) = false := by
      rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h
      change 97 ≤ r.val ∧ r.val ≤ 122 at h; omega
    have hlt : r < 128#i32 := (i32_lt_iff' r 128#i32).mpr (by change r.val < 128; omega)
    simp only [hf, Bool.false_eq_true, hlt, ↓reduceIte]
  · have hfix : unicode_cp_to_upper cp = ok cp := by
      unfold unicode_cp_to_upper
      have hf : ((decide (cp >= 97#i32)) && (decide (cp <= 122#i32))) = false := by
        rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h
        change 97 ≤ cp.val ∧ cp.val ≤ 122 at h; omega
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

/-- Theorem 23: Fullwidth Latin `Ａ..Ｚ` (`0xFF21..0xFF3A`) lowers by `+32` and roundtrips via `to_upper`. -/
theorem unicode_fullwidth_case_roundtrip (cp : Std.I32) (hlo : 65313 ≤ cp.val) (hhi : cp.val ≤ 65338) :
    (do let lo ← unicode_cp_to_lower cp; unicode_cp_to_upper lo) = ok cp := by
  have h1 : unicode_cp_to_lower cp = ok (Pion.I32.add cp 32#i32) := by
    unfold unicode_cp_to_lower
    have f1 : ((decide (cp >= 65#i32)) && (decide (cp <= 90#i32))) = false := by
      rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 65 ≤ cp.val ∧ cp.val ≤ 90 at h; omega
    have f2 : ¬ (cp < 128#i32) := fun h => by have := (i32_lt_iff' cp 128#i32).mp h; change cp.val < 128 at this; omega
    have f3 : (((decide (cp >= 192#i32)) && (decide (cp <= 214#i32))) || ((decide (cp >= 216#i32)) && (decide (cp <= 222#i32)))) = false := by
      rw [Bool.eq_false_iff]; intro h; simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change (192 ≤ cp.val ∧ cp.val ≤ 214) ∨ (216 ≤ cp.val ∧ cp.val ≤ 222) at h; omega
    have f4 : cp ≠ 304#i32 := fun h => by rw [h] at hlo; change 65313 ≤ (304 : Int) at hlo; omega
    have f5 : cp ≠ 376#i32 := fun h => by rw [h] at hlo; change 65313 ≤ (376 : Int) at hlo; omega
    have f6 : (((((((decide (cp >= 256#i32)) && (decide (cp <= 302#i32))) && ((Pion.I32.band cp 1#i32) == 0#i32)) || (((decide (cp >= 306#i32)) && (decide (cp <= 310#i32))) && ((Pion.I32.band cp 1#i32) == 0#i32))) || (((decide (cp >= 313#i32)) && (decide (cp <= 327#i32))) && ((Pion.I32.band cp 1#i32) == 1#i32))) || (((decide (cp >= 330#i32)) && (decide (cp <= 374#i32))) && ((Pion.I32.band cp 1#i32) == 0#i32))) || (((decide (cp >= 377#i32)) && (decide (cp <= 381#i32))) && ((Pion.I32.band cp 1#i32) == 1#i32))) = false := by
      rw [Bool.eq_false_iff]; intro h
      simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h
      rcases h with (((⟨⟨_, h⟩, _⟩ | ⟨⟨_, h⟩, _⟩) | ⟨⟨_, h⟩, _⟩) | ⟨⟨_, h⟩, _⟩) | ⟨⟨_, h⟩, _⟩
      · change cp.val ≤ 302 at h; omega
      · change cp.val ≤ 310 at h; omega
      · change cp.val ≤ 327 at h; omega
      · change cp.val ≤ 374 at h; omega
      · change cp.val ≤ 381 at h; omega
    have f7 : (((decide (cp >= 913#i32)) && (decide (cp <= 929#i32))) || ((decide (cp >= 931#i32)) && (decide (cp <= 939#i32)))) = false := by
      rw [Bool.eq_false_iff]; intro h; simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change (913 ≤ cp.val ∧ cp.val ≤ 929) ∨ (931 ≤ cp.val ∧ cp.val ≤ 939) at h; omega
    have f8 : ((decide (cp >= 1040#i32)) && (decide (cp <= 1071#i32))) = false := by
      rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 1040 ≤ cp.val ∧ cp.val ≤ 1071 at h; omega
    have f9 : ((decide (cp >= 1024#i32)) && (decide (cp <= 1039#i32))) = false := by
      rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 1024 ≤ cp.val ∧ cp.val ≤ 1039 at h; omega
    have t10 : ((decide (cp >= 65313#i32)) && (decide (cp <= 65338#i32))) = true := by
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
      change 65313 ≤ cp.val ∧ cp.val ≤ 65338; omega
    simp only [f1, f2, f3, f4, f5, f6, f7, f8, f9, t10, Bool.false_eq_true, ↓reduceIte]
  rw [h1, result_bind_ok']
  set lo := Pion.I32.add cp 32#i32
  have hlo_v : lo.val = cp.val + 32 :=
    i32_add_val' cp 32#i32 (by change -2147483648 ≤ cp.val + 32; omega) (by change cp.val + 32 ≤ 2147483647; omega)
  unfold unicode_cp_to_upper
  have f1 : ((decide (lo >= 97#i32)) && (decide (lo <= 122#i32))) = false := by
    rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 97 ≤ lo.val ∧ lo.val ≤ 122 at h; omega
  have f2 : ¬ (lo < 128#i32) := fun h => by have := (i32_lt_iff' lo 128#i32).mp h; change lo.val < 128 at this; omega
  have f3 : (((decide (lo >= 224#i32)) && (decide (lo <= 246#i32))) || ((decide (lo >= 248#i32)) && (decide (lo <= 254#i32)))) = false := by
    rw [Bool.eq_false_iff]; intro h; simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change (224 ≤ lo.val ∧ lo.val ≤ 246) ∨ (248 ≤ lo.val ∧ lo.val ≤ 254) at h; omega
  have f4 : lo ≠ 255#i32 := fun h => by rw [h] at hlo_v; change (255 : Int) = cp.val + 32 at hlo_v; omega
  have f5 : lo ≠ 181#i32 := fun h => by rw [h] at hlo_v; change (181 : Int) = cp.val + 32 at hlo_v; omega
  have f6 : lo ≠ 305#i32 := fun h => by rw [h] at hlo_v; change (305 : Int) = cp.val + 32 at hlo_v; omega
  have f7 : (((((((decide (lo >= 257#i32)) && (decide (lo <= 303#i32))) && ((Pion.I32.band lo 1#i32) == 1#i32)) || (((decide (lo >= 307#i32)) && (decide (lo <= 311#i32))) && ((Pion.I32.band lo 1#i32) == 1#i32))) || (((decide (lo >= 314#i32)) && (decide (lo <= 328#i32))) && ((Pion.I32.band lo 1#i32) == 0#i32))) || (((decide (lo >= 331#i32)) && (decide (lo <= 375#i32))) && ((Pion.I32.band lo 1#i32) == 1#i32))) || (((decide (lo >= 378#i32)) && (decide (lo <= 382#i32))) && ((Pion.I32.band lo 1#i32) == 0#i32))) = false := by
    rw [Bool.eq_false_iff]; intro h
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h
    rcases h with (((⟨⟨_, h⟩, _⟩ | ⟨⟨_, h⟩, _⟩) | ⟨⟨_, h⟩, _⟩) | ⟨⟨_, h⟩, _⟩) | ⟨⟨_, h⟩, _⟩
    · change lo.val ≤ 303 at h; omega
    · change lo.val ≤ 311 at h; omega
    · change lo.val ≤ 328 at h; omega
    · change lo.val ≤ 375 at h; omega
    · change lo.val ≤ 382 at h; omega
  have f8 : ((decide (lo >= 945#i32)) && (decide (lo <= 961#i32))) = false := by
    rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 945 ≤ lo.val ∧ lo.val ≤ 961 at h; omega
  have f9 : ((decide (lo >= 963#i32)) && (decide (lo <= 971#i32))) = false := by
    rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 963 ≤ lo.val ∧ lo.val ≤ 971 at h; omega
  have f10 : lo ≠ 962#i32 := fun h => by rw [h] at hlo_v; change (962 : Int) = cp.val + 32 at hlo_v; omega
  have f11 : ((decide (lo >= 1072#i32)) && (decide (lo <= 1103#i32))) = false := by
    rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 1072 ≤ lo.val ∧ lo.val ≤ 1103 at h; omega
  have f12 : ((decide (lo >= 1104#i32)) && (decide (lo <= 1119#i32))) = false := by
    rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 1104 ≤ lo.val ∧ lo.val ≤ 1119 at h; omega
  have t13 : ((decide (lo >= 65345#i32)) && (decide (lo <= 65370#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
    change 65345 ≤ lo.val ∧ lo.val ≤ 65370; omega
  simp only [f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, t13, Bool.false_eq_true, ↓reduceIte]
  apply congrArg ok
  apply IScalar.eq_of_val_eq
  have hs := i32_sub_val' lo 32#i32 (by change -2147483648 ≤ lo.val - 32; omega) (by change lo.val - 32 ≤ 2147483647; omega)
  change (Pion.I32.sub lo 32#i32).val = lo.val - 32 at hs
  omega

/-- Theorem 24: Special Go `unicode.ToLower`/`ToUpper` mappings (`İ→i`, `ı→I`, `ÿ↔Ÿ`, `ς→Σ`, `µ→Μ`). -/
theorem unicode_special_go_mappings :
    unicode_cp_to_lower 304#i32 = ok 105#i32 ∧
    unicode_cp_to_upper 305#i32 = ok 73#i32 ∧
    unicode_cp_to_lower 376#i32 = ok 255#i32 ∧
    unicode_cp_to_upper 255#i32 = ok 376#i32 ∧
    unicode_cp_to_upper 962#i32 = ok 931#i32 ∧
    unicode_cp_to_upper 181#i32 = ok 924#i32 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · unfold unicode_cp_to_lower; rfl
  · unfold unicode_cp_to_upper; rfl
  · unfold unicode_cp_to_lower; rfl
  · unfold unicode_cp_to_upper; rfl
  · unfold unicode_cp_to_upper; rfl
  · unfold unicode_cp_to_upper; rfl

end HclProofs
