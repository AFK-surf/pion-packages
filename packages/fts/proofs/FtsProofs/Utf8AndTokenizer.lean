import Aeneas
import PionLean
import Fts.Types
import Fts.Funs

open Aeneas Aeneas.Std Result Error Pion
open fts

namespace FtsProofs

private lemma result_bind_ok {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by
  simp

private lemma i32_beq_iff (x y : Std.I32) : (x == y) = true ↔ x.val = y.val := by
  cases x; cases y
  simp [BEq.beq, IScalar.val, BitVec.toInt_inj]

private lemma i32_add_val (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val + y.val) (hhi : x.val + y.val < 2 ^ 31) :
    (Pion.I32.add x y).val = x.val + y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le (by omega) (by omega)

/-- `sanitize_scalar` always outputs a valid Unicode scalar value (non-surrogate, `[0, 0x10FFFF]`). -/
theorem sanitize_scalar_valid (cp : Std.I32) :
    ∃ v : Std.I32,
      sanitize_scalar cp = ok v ∧
      0 ≤ v.val ∧ v.val ≤ 1114111 ∧ (v.val < 55296 ∨ 57343 < v.val) := by
  unfold sanitize_scalar
  have h0 : (0#i32).val = 0 := by decide
  have hmax : (1114111#i32).val = 1114111 := by decide
  have hs1 : (55296#i32).val = 55296 := by decide
  have hs2 : (57343#i32).val = 57343 := by decide
  have hrep : (65533#i32).val = 65533 := by decide
  refine ⟨_, rfl, ?_⟩
  split_ifs with h
  · omega
  · simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq,
      IScalar.lt_equiv, gt_iff_lt, ge_iff_le, IScalar.le_equiv, h0, hmax, hs1, hs2] at h
    omega

/-- Any UTF-16 surrogate codepoint (`0xD800..0xDFFF`) is replaced with `U+FFFD` (3 UTF-8 bytes). -/
theorem cp_utf8_len_surrogate (cp : Std.I32) (hlo : 55296 ≤ cp.val) (hhi : cp.val ≤ 57343) :
    cp_utf8_len cp = ok 3#i32 := by
  unfold cp_utf8_len sanitize_scalar
  have hs1 : (55296#i32).val = 55296 := by decide
  have hs2 : (57343#i32).val = 57343 := by decide
  have hcond : (((decide (cp < 0#i32)) || (decide (cp > 1114111#i32))) ||
      ((decide (cp >= 55296#i32)) && (decide (cp <= 57343#i32)))) = true := by
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq,
      ge_iff_le, IScalar.le_equiv, hs1, hs2]
    right; exact ⟨hlo, hhi⟩
  simp only [hcond, ↓reduceIte, result_bind_ok]
  have h1 : ¬ (65533#i32 < 128#i32) := by decide
  have h2 : ¬ (65533#i32 < 2048#i32) := by decide
  have h3 : (65533#i32 < 65536#i32) := by decide
  simp [h1, h2, h3]

/-- `fold_ascii_cp` is idempotent across all `2^32` inputs. -/
theorem fold_ascii_cp_idempotent (c : Std.I32) :
    ∃ r : Std.I32,
      fold_ascii_cp c = ok r ∧ fold_ascii_cp r = ok r := by
  unfold fold_ascii_cp
  have h65 : (65#i32).val = 65 := by decide
  have h90 : (90#i32).val = 90 := by decide
  have h32 : (32#i32).val = 32 := by decide
  by_cases h : ((decide (c >= 65#i32)) && (decide (c <= 90#i32))) = true
  · have hr : 65 ≤ c.val ∧ c.val ≤ 90 := by
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, IScalar.le_equiv, h65, h90] at h
      exact h
    have ha : (Pion.I32.add c 32#i32).val = c.val + 32 := by
      rw [i32_add_val c 32#i32 (by omega) (by omega), h32]
    have h2 : ((decide (Pion.I32.add c 32#i32 >= 65#i32)) &&
        (decide (Pion.I32.add c 32#i32 <= 90#i32))) = false := by
      simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, ge_iff_le,
        IScalar.le_equiv, h65, h90, ha]
      omega
    exact ⟨Pion.I32.add c 32#i32, by rw [h]; rfl, by rw [h2]; rfl⟩
  · have hf : ((decide (c >= 65#i32)) && (decide (c <= 90#i32))) = false := by
      cases hc : ((decide (c >= 65#i32)) && (decide (c <= 90#i32)))
      · rfl
      · exact absurd hc h
    exact ⟨c, by rw [hf]; rfl, by rw [hf]; rfl⟩

/-- Cyrillic case folding (`U+0400..U+045F`) maps into lowercase `U+0430..U+045F` and is idempotent. -/
theorem fold_cyrillic_idempotent (v : Std.I32) (hlo : 1024 ≤ v.val) (hhi : v.val ≤ 1119) :
    ∃ r : Std.I32,
      fold_greek_cyrillic v = ok r ∧
      1072 ≤ r.val ∧ r.val ≤ 1119 ∧
      fold_greek_cyrillic r = ok r := by
  have h_low : ∀ x : Std.I32, 1072 ≤ x.val → x.val ≤ 1119 → fold_greek_cyrillic x = ok x := by
    intro x hxlo hxhi
    unfold fold_greek_cyrillic
    have c1 : x ≠ 902#i32 := by intro heq; subst heq; exact absurd hxlo (by decide)
    have c2 : ((decide (x >= 904#i32)) && (decide (x <= 906#i32))) = false := by
      have h906 : (906#i32).val = 906 := by decide
      simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, IScalar.le_equiv, h906]; omega
    have c3 : x ≠ 908#i32 := by intro heq; subst heq; exact absurd hxlo (by decide)
    have c4 : ((decide (x >= 910#i32)) && (decide (x <= 911#i32))) = false := by
      have h911 : (911#i32).val = 911 := by decide
      simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, IScalar.le_equiv, h911]; omega
    have c5 : (((decide (x >= 913#i32)) && (decide (x <= 937#i32))) && (x != 930#i32)) = false := by
      have h937 : (937#i32).val = 937 := by decide
      simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, IScalar.le_equiv, h937]; omega
    have c6 : x ≠ 962#i32 := by intro heq; subst heq; exact absurd hxlo (by decide)
    have c7 : ((decide (x >= 940#i32)) && (decide (x <= 974#i32))) = false := by
      have h974 : (974#i32).val = 974 := by decide
      simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, IScalar.le_equiv, h974]; omega
    have c8 : ((decide (x >= 1040#i32)) && (decide (x <= 1071#i32))) = false := by
      have h1071 : (1071#i32).val = 1071 := by decide
      simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, IScalar.le_equiv, h1071]; omega
    have c9 : ((decide (x >= 1024#i32)) && (decide (x <= 1039#i32))) = false := by
      have h1039 : (1039#i32).val = 1039 := by decide
      simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, IScalar.le_equiv, h1039]; omega
    have c10 : ((decide (x >= 1072#i32)) && (decide (x <= 1119#i32))) = true := by
      have h1072 : (1072#i32).val = 1072 := by decide
      have h1119 : (1119#i32).val = 1119 := by decide
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, IScalar.le_equiv, h1072, h1119]; omega
    simp only [c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, Bool.false_eq_true, ↓reduceIte]
  by_cases h1 : 1072 ≤ v.val
  · exact ⟨v, h_low v h1 hhi, h1, hhi, h_low v h1 hhi⟩
  · by_cases h2 : 1040 ≤ v.val
    · have hv : fold_greek_cyrillic v = ok (Pion.I32.add v 32#i32) := by
        unfold fold_greek_cyrillic
        have c1 : v ≠ 902#i32 := by intro heq; subst heq; exact absurd hlo (by decide)
        have c2 : ((decide (v >= 904#i32)) && (decide (v <= 906#i32))) = false := by
          have h906 : (906#i32).val = 906 := by decide
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, IScalar.le_equiv, h906]; omega
        have c3 : v ≠ 908#i32 := by intro heq; subst heq; exact absurd hlo (by decide)
        have c4 : ((decide (v >= 910#i32)) && (decide (v <= 911#i32))) = false := by
          have h911 : (911#i32).val = 911 := by decide
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, IScalar.le_equiv, h911]; omega
        have c5 : (((decide (v >= 913#i32)) && (decide (v <= 937#i32))) && (v != 930#i32)) = false := by
          have h937 : (937#i32).val = 937 := by decide
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, IScalar.le_equiv, h937]; omega
        have c6 : v ≠ 962#i32 := by intro heq; subst heq; exact absurd hlo (by decide)
        have c7 : ((decide (v >= 940#i32)) && (decide (v <= 974#i32))) = false := by
          have h974 : (974#i32).val = 974 := by decide
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, IScalar.le_equiv, h974]; omega
        have c8 : ((decide (v >= 1040#i32)) && (decide (v <= 1071#i32))) = true := by
          have h1040 : (1040#i32).val = 1040 := by decide
          have h1071 : (1071#i32).val = 1071 := by decide
          simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, IScalar.le_equiv, h1040, h1071]; omega
        simp only [c1, c2, c3, c4, c5, c6, c7, c8, Bool.false_eq_true, ↓reduceIte]
      have h32 : (32#i32).val = 32 := by decide
      have ha : (Pion.I32.add v 32#i32).val = v.val + 32 := by
        rw [i32_add_val v 32#i32 (by omega) (by omega), h32]
      exact ⟨Pion.I32.add v 32#i32, hv, by omega, by omega, h_low _ (by omega) (by omega)⟩
    · have hv : fold_greek_cyrillic v = ok (Pion.I32.add v 80#i32) := by
        unfold fold_greek_cyrillic
        have c1 : v ≠ 902#i32 := by intro heq; subst heq; exact absurd hlo (by decide)
        have c2 : ((decide (v >= 904#i32)) && (decide (v <= 906#i32))) = false := by
          have h906 : (906#i32).val = 906 := by decide
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, IScalar.le_equiv, h906]; omega
        have c3 : v ≠ 908#i32 := by intro heq; subst heq; exact absurd hlo (by decide)
        have c4 : ((decide (v >= 910#i32)) && (decide (v <= 911#i32))) = false := by
          have h911 : (911#i32).val = 911 := by decide
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, IScalar.le_equiv, h911]; omega
        have c5 : (((decide (v >= 913#i32)) && (decide (v <= 937#i32))) && (v != 930#i32)) = false := by
          have h937 : (937#i32).val = 937 := by decide
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, IScalar.le_equiv, h937]; omega
        have c6 : v ≠ 962#i32 := by intro heq; subst heq; exact absurd hlo (by decide)
        have c7 : ((decide (v >= 940#i32)) && (decide (v <= 974#i32))) = false := by
          have h974 : (974#i32).val = 974 := by decide
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, IScalar.le_equiv, h974]; omega
        have c8 : ((decide (v >= 1040#i32)) && (decide (v <= 1071#i32))) = false := by
          have h1040 : (1040#i32).val = 1040 := by decide
          simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, ge_iff_le, IScalar.le_equiv, h1040]; omega
        have c9 : ((decide (v >= 1024#i32)) && (decide (v <= 1039#i32))) = true := by
          have h1024 : (1024#i32).val = 1024 := by decide
          have h1039 : (1039#i32).val = 1039 := by decide
          simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, IScalar.le_equiv, h1024, h1039]; omega
        simp only [c1, c2, c3, c4, c5, c6, c7, c8, c9, Bool.false_eq_true, ↓reduceIte]
      have h80 : (80#i32).val = 80 := by decide
      have ha : (Pion.I32.add v 80#i32).val = v.val + 80 := by
        rw [i32_add_val v 80#i32 (by omega) (by omega), h80]
      exact ⟨Pion.I32.add v 80#i32, hv, by omega, by omega, h_low _ (by omega) (by omega)⟩

/-- ASCII word codepoints and CJK codepoints are strictly disjoint. -/
theorem is_cjk_ascii_disjoint (c : Std.I32) :
    is_ascii_word_cp c = ok true → is_cjk_cp c = ok false := by
  unfold is_ascii_word_cp is_cjk_cp
  have h122 : (122#i32).val = 122 := by decide
  have h90 : (90#i32).val = 90 := by decide
  have h57 : (57#i32).val = 57 := by decide
  have h95 : (95#i32).val = 95 := by decide
  intro h
  have hlt : c.val ≤ 122 := by
    simp only [Result.ok.injEq, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq,
      ge_iff_le, IScalar.le_equiv, i32_beq_iff, h122, h90, h57, h95] at h
    omega
  split_ifs
  · rfl
  · simp only [Result.ok.injEq, Bool.or_eq_false_iff, Bool.and_eq_false_iff,
      decide_eq_false_iff_not, ge_iff_le, IScalar.le_equiv]
    have ha : (13312#i32).val = 13312 := by decide
    have hb : (19968#i32).val = 19968 := by decide
    have hc : (63744#i32).val = 63744 := by decide
    have hd : (131072#i32).val = 131072 := by decide
    have he : (12352#i32).val = 12352 := by decide
    have hf : (12784#i32).val = 12784 := by decide
    have hg : (44032#i32).val = 44032 := by decide
    have hh : (4352#i32).val = 4352 := by decide
    omega

end FtsProofs
