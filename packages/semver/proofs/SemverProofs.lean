/-
Formal verification of `packages/semver` (`Semver.Funs`, extracted via
`pionc extract-lean` from `packages/semver/src/*.pion`).

All proofs are complete and kernel-checked, depending only on the three
standard Lean axioms: `propext`, `Classical.choice`, `Quot.sound`.
-/
import Semver.Funs

open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option linter.unusedSimpArgs false

namespace SemverProofs

open semver

/-! ## Helpers -/

/-- String UTF-8 byte length fits in Pion `Int` (`Std.I32`, `≤ 2^31 - 1`). -/
def StrValid (s : String) : Prop :=
  s.utf8ByteSize ≤ 2147483647

lemma b_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← (ok x : Result α); f y) = f x := by simp

lemma u64_ext {a b : Std.U64} (h : a.val = b.val) : a = b := by
  cases a; cases b
  congr 1
  exact BitVec.eq_of_toNat_eq h

lemma u64_ne_val {a b : Std.U64} (h : a ≠ b) : a.val ≠ b.val :=
  fun hv => h (u64_ext hv)

lemma str_length_eq (s : String) (h : StrValid s) :
    ∃ n : Std.I32, Pion.String.length s = ok n ∧ n.val = (s.utf8ByteSize : Int) := by
  unfold Pion.String.length Pion.lengthOf
  simp only [show s.utf8ByteSize ≤ 2147483647 from h, ↓reduceDIte]
  refine ⟨_, rfl, ?_⟩
  simp

lemma i32_eq_zero_iff (n : Std.I32) : (n = 0#i32) ↔ n.val = 0 := by
  constructor
  · intro h; subst h; decide
  · intro h
    cases n with
    | mk bv =>
      simp only [IScalar.val] at h
      have hbv : bv = 0#32 := BitVec.eq_of_toInt_eq (by simpa using h)
      subst hbv
      rfl

lemma i32_beq_zero_iff (n : Std.I32) : ((n == 0#i32) = true) ↔ n.val = 0 := by
  rw [beq_iff_eq, i32_eq_zero_iff]

lemma i32_neg_one : Pion.I32.neg 1#i32 = (-1)#i32 := by decide
lemma i32_neg_neg_one : Pion.I32.neg (-1)#i32 = 1#i32 := by decide
lemma i32_neg_zero : Pion.I32.neg 0#i32 = 0#i32 := by decide

lemma i32_neg_involution (r : Std.I32) : Pion.I32.neg (Pion.I32.neg r) = r := by
  cases r with
  | mk bv =>
    unfold Pion.I32.neg
    congr 1
    exact neg_neg bv

/-! ## 1. Core `(major, minor, patch : UInt64)` Lexicographic Strict Total Order -/

/-- `cmp_core` never panics or traps on any `UInt64` triple (`0 .. 2^64 - 1`) and returns `{-1, 0, 1}`. -/
lemma cmp_core_total (a1 a2 a3 b1 b2 b3 : Std.U64) :
    ∃ r : Std.I32, cmp_core a1 a2 a3 b1 b2 b3 = ok r ∧
      (r = (-1)#i32 ∨ r = 0#i32 ∨ r = 1#i32) := by
  unfold cmp_core
  split_ifs <;> exact ⟨_, rfl, by decide⟩

/-- Reflexivity: comparing a triple with itself always returns `ok 0`. -/
lemma cmp_core_refl (m n p : Std.U64) :
    cmp_core m n p m n p = ok 0#i32 := by
  unfold cmp_core
  simp only [ne_eq, not_true_eq_false, ↓reduceIte]

/-- Exact lexicographic `<` characterization of `cmp_core`. -/
theorem cmp_core_lt_iff (a1 a2 a3 b1 b2 b3 : Std.U64) :
    cmp_core a1 a2 a3 b1 b2 b3 = ok (-1)#i32 ↔
      (a1.val < b1.val ∨
        (a1 = b1 ∧ a2.val < b2.val) ∨
        (a1 = b1 ∧ a2 = b2 ∧ a3.val < b3.val)) := by
  unfold cmp_core
  by_cases h1 : a1 = b1
  · subst h1
    simp only [ne_eq, not_true_eq_false, ↓reduceIte, lt_self_iff_false, true_and, false_or]
    by_cases h2 : a2 = b2
    · subst h2
      simp only [ne_eq, not_true_eq_false, ↓reduceIte, lt_self_iff_false, true_and, false_or]
      by_cases h3 : a3 = b3
      · subst h3
        simp only [ne_eq, not_true_eq_false, ↓reduceIte, ok.injEq, lt_self_iff_false, iff_false]
        decide
      · simp only [ne_eq, h3, not_false_eq_true, ↓reduceIte, ok.injEq]
        by_cases h3lt : a3 < b3
        · have h3v : a3.val < b3.val := h3lt
          simp [h3lt, h3v]
        · have h3v : ¬ a3.val < b3.val := h3lt
          simp only [h3lt, ↓reduceIte, h3v, iff_false]
          decide
    · simp only [ne_eq, h2, not_false_eq_true, ↓reduceIte, ok.injEq, false_and, or_false]
      by_cases h2lt : a2 < b2
      · have h2v : a2.val < b2.val := h2lt
        simp [h2lt, h2v]
      · have h2v : ¬ a2.val < b2.val := h2lt
        simp only [h2lt, ↓reduceIte, h2v, iff_false]
        decide
  · simp only [ne_eq, h1, not_false_eq_true, ↓reduceIte, ok.injEq, false_and, or_false]
    by_cases h1lt : a1 < b1
    · have h1v : a1.val < b1.val := h1lt
      simp [h1lt, h1v]
    · have h1v : ¬ a1.val < b1.val := h1lt
      simp only [h1lt, ↓reduceIte, h1v, iff_false]
      decide

/-- Equivalence consistency: `cmp_core a b = ok 0 ↔ a = b`. -/
theorem cmp_core_eq_zero_iff (a1 a2 a3 b1 b2 b3 : Std.U64) :
    cmp_core a1 a2 a3 b1 b2 b3 = ok 0#i32 ↔ (a1 = b1 ∧ a2 = b2 ∧ a3 = b3) := by
  unfold cmp_core
  by_cases h1 : a1 = b1
  · subst h1
    simp only [ne_eq, not_true_eq_false, ↓reduceIte, true_and]
    by_cases h2 : a2 = b2
    · subst h2
      simp only [ne_eq, not_true_eq_false, ↓reduceIte, true_and]
      by_cases h3 : a3 = b3
      · subst h3
        simp only [ne_eq, not_true_eq_false, ↓reduceIte]
      · simp only [ne_eq, h3, not_false_eq_true, ↓reduceIte, ok.injEq, iff_false]
        split_ifs <;> decide
    · simp only [ne_eq, h2, not_false_eq_true, ↓reduceIte, ok.injEq, false_and, iff_false]
      split_ifs <;> decide
  · simp only [ne_eq, h1, not_false_eq_true, ↓reduceIte, ok.injEq, false_and, iff_false]
    split_ifs <;> decide

/-- Helper: `cmp_core a b = ok r → cmp_core b a = ok (-r)`. -/
lemma cmp_core_swap (a1 a2 a3 b1 b2 b3 : Std.U64) (r : Std.I32)
    (h : cmp_core a1 a2 a3 b1 b2 b3 = ok r) :
    cmp_core b1 b2 b3 a1 a2 a3 = ok (Pion.I32.neg r) := by
  unfold cmp_core at h ⊢
  by_cases h1 : a1 = b1
  · subst h1
    simp only [ne_eq, not_true_eq_false, ↓reduceIte] at h ⊢
    by_cases h2 : a2 = b2
    · subst h2
      simp only [ne_eq, not_true_eq_false, ↓reduceIte] at h ⊢
      by_cases h3 : a3 = b3
      · subst h3
        simp only [ne_eq, not_true_eq_false, ↓reduceIte, ok.injEq] at h ⊢
        subst h
        exact i32_neg_zero.symm
      · have h3' : b3 ≠ a3 := Ne.symm h3
        have h3v : a3.val ≠ b3.val := u64_ne_val h3
        simp only [ne_eq, h3, h3', not_false_eq_true, ↓reduceIte, ok.injEq] at h ⊢
        by_cases hlt : a3 < b3
        · have hgt : ¬ (b3 < a3) := by
            have : a3.val < b3.val := hlt
            change ¬ b3.val < a3.val; omega
          simp only [hlt, hgt, ↓reduceIte] at h ⊢
          subst h; exact i32_neg_neg_one.symm
        · have hgt : b3 < a3 := by
            have : ¬ a3.val < b3.val := hlt
            change b3.val < a3.val; omega
          simp only [hlt, hgt, ↓reduceIte] at h ⊢
          subst h; exact i32_neg_one.symm
    · have h2' : b2 ≠ a2 := Ne.symm h2
      have h2v : a2.val ≠ b2.val := u64_ne_val h2
      simp only [ne_eq, h2, h2', not_false_eq_true, ↓reduceIte, ok.injEq] at h ⊢
      by_cases hlt : a2 < b2
      · have hgt : ¬ (b2 < a2) := by
          have : a2.val < b2.val := hlt
          change ¬ b2.val < a2.val; omega
        simp only [hlt, hgt, ↓reduceIte] at h ⊢
        subst h; exact i32_neg_neg_one.symm
      · have hgt : b2 < a2 := by
          have : ¬ a2.val < b2.val := hlt
          change b2.val < a2.val; omega
        simp only [hlt, hgt, ↓reduceIte] at h ⊢
        subst h; exact i32_neg_one.symm
  · have h1' : b1 ≠ a1 := Ne.symm h1
    have h1v : a1.val ≠ b1.val := u64_ne_val h1
    simp only [ne_eq, h1, h1', not_false_eq_true, ↓reduceIte, ok.injEq] at h ⊢
    by_cases hlt : a1 < b1
    · have hgt : ¬ (b1 < a1) := by
        have : a1.val < b1.val := hlt
        change ¬ b1.val < a1.val; omega
      simp only [hlt, hgt, ↓reduceIte] at h ⊢
      subst h; exact i32_neg_neg_one.symm
    · have hgt : b1 < a1 := by
        have : ¬ a1.val < b1.val := hlt
        change b1.val < a1.val; omega
      simp only [hlt, hgt, ↓reduceIte] at h ⊢
      subst h; exact i32_neg_one.symm

/-! ## 2. SemVer 2.0.0 Prerelease (§11.3, §11.4) & Build Metadata (§10) Precedence -/

/-- SemVer 2.0.0 §11.3: a normal (release) version has strictly higher precedence
than any non-empty pre-release version with the same `(major, minor, patch)`. -/
theorem cmp_precedence_release_gt_pre (m n p : Std.U64) (pre_s : String)
    (hpre_ne : pre_s.utf8ByteSize > 0) (hpre_valid : StrValid pre_s)
    (b1 b2 : BuildMetadata) :
    cmp_precedence_core ⟨m, n, p, ⟨""⟩, b1⟩ ⟨m, n, p, ⟨pre_s⟩, b2⟩ = ok (some 1#i32) := by
  unfold cmp_precedence_core
  rw [cmp_core_refl]
  simp only [b_ok, ne_eq, not_true_eq_false, ↓reduceIte]
  obtain ⟨n_a, h_a, h_av⟩ := str_length_eq "" (by unfold StrValid; decide)
  obtain ⟨n_b, h_b, h_bv⟩ := str_length_eq pre_s hpre_valid
  rw [h_a]
  simp only [b_ok]
  rw [h_b]
  simp only [b_ok]
  have ha0 : n_a = 0#i32 := (i32_eq_zero_iff n_a).mpr (by simpa using h_av)
  have hb0 : n_b ≠ 0#i32 := by
    intro h
    have hv := (i32_eq_zero_iff n_b).mp h
    omega
  simp [ha0, hb0]

/-- SemVer 2.0.0 §10: build metadata is completely ignored by `cmp_precedence_core`. -/
theorem cmp_precedence_ignores_build (a b : Version) (b1 b2 : BuildMetadata) :
    cmp_precedence_core { a with build := b1 } { b with build := b2 } =
      cmp_precedence_core a b := by
  unfold cmp_precedence_core
  rfl

/-- Antisymmetry of `cmp_pre_segment_order` (when `lex_ba = -lex_ab`). -/
theorem cmp_pre_segment_order_antisymm (ad bd : Bool) (al bl lex_ab : Std.I32) (r : Std.I32)
    (h : cmp_pre_segment_order ad al bd bl lex_ab = ok r) :
    cmp_pre_segment_order bd bl ad al (Pion.I32.neg lex_ab) = ok (Pion.I32.neg r) := by
  unfold cmp_pre_segment_order at h ⊢
  cases ad <;> cases bd <;> simp only [Bool.and_self, Bool.and_false, Bool.false_and,
    Bool.true_eq_false, ↓reduceIte, ok.injEq] at h ⊢
  · subst h; rfl
  · subst h; exact i32_neg_one.symm
  · subst h; exact i32_neg_neg_one.symm
  · by_cases heq : al = bl
    · subst heq
      simp only [ne_eq, not_true_eq_false, ↓reduceIte] at h ⊢
      subst h; rfl
    · have hne' : bl ≠ al := Ne.symm heq
      have hne_v : al.val ≠ bl.val := by
        intro hv
        apply heq
        cases al; cases bl
        simp only [IScalar.val] at hv
        congr 1; exact BitVec.eq_of_toInt_eq hv
      simp only [ne_eq, heq, hne', not_false_eq_true, ↓reduceIte] at h ⊢
      by_cases hlt : al < bl
      · have hgt : ¬ (bl < al) := by
          have : al.val < bl.val := hlt
          change ¬ bl.val < al.val; omega
        simp only [hlt, hgt, ↓reduceIte] at h ⊢
        subst h; exact i32_neg_neg_one.symm
      · have hgt : bl < al := by
          have : ¬ al.val < bl.val := hlt
          change bl.val < al.val; omega
        simp only [hlt, hgt, ↓reduceIte] at h ⊢
        subst h; exact i32_neg_one.symm

/-- Strict `<` transitivity of `cmp_pre_segment_order` given a transitive lexicographic comparator. -/
theorem cmp_pre_segment_order_trans_lt
    (ad bd cd : Bool) (al bl cl lex_ab lex_bc lex_ac : Std.I32)
    (hlex_trans : lex_ab = (-1)#i32 → lex_bc = (-1)#i32 → lex_ac = (-1)#i32)
    (hab : cmp_pre_segment_order ad al bd bl lex_ab = ok (-1)#i32)
    (hbc : cmp_pre_segment_order bd bl cd cl lex_bc = ok (-1)#i32) :
    cmp_pre_segment_order ad al cd cl lex_ac = ok (-1)#i32 := by
  unfold cmp_pre_segment_order at hab hbc ⊢
  cases ad <;> cases bd <;> cases cd <;>
    simp only [Bool.and_self, Bool.and_false, Bool.false_and,
      Bool.false_eq_true, Bool.true_eq_false, ↓reduceIte, ok.injEq] at hab hbc ⊢
  · exact hlex_trans hab hbc
  · exact absurd hbc (by decide)
  · exact absurd hab (by decide)
  · exact absurd hab (by decide)
  · exact absurd hbc (by decide)
  · by_cases h1 : al = bl <;> by_cases h2 : bl = cl
    · subst h1; subst h2
      simp only [ne_eq, not_true_eq_false, ↓reduceIte] at hab hbc ⊢
      exact hlex_trans hab hbc
    · subst h1
      simp only [ne_eq, h2, not_false_eq_true, ↓reduceIte] at hbc ⊢
      exact hbc
    · subst h2
      simp only [ne_eq, h1, not_false_eq_true, ↓reduceIte] at hab ⊢
      exact hab
    · simp only [ne_eq, h1, h2, not_false_eq_true, ↓reduceIte] at hab hbc
      have hlt1 : al.val < bl.val := by
        by_contra hc
        have hlt1' : ¬ (al < bl) := hc
        simp only [hlt1', ↓reduceIte] at hab
        exact absurd hab (by decide)
      have hlt2 : bl.val < cl.val := by
        by_contra hc
        have hlt2' : ¬ (bl < cl) := hc
        simp only [hlt2', ↓reduceIte] at hbc
        exact absurd hbc (by decide)
      have hne3 : al ≠ cl := by
        intro heq; subst heq; omega
      have hlt3 : al < cl := by change al.val < cl.val; omega
      simp only [ne_eq, hne3, not_false_eq_true, ↓reduceIte, hlt3]

/-! ## 3. Cargo `Comparator` / `Op` Interval Matching Soundness & `UInt64::MAX` Overflow Immunity -/

/-- All 8 Cargo `Op` variants in `matches_release` never trap and never overflow across the
full `UInt64` domain (`0 .. 2^64 - 1`, including `UInt64::MAX`). -/
theorem matches_release_total_no_overflow (cmp : Comparator) (ver : Version)
    (hpre : StrValid cmp.pre.raw) :
    ∃ b : Bool, matches_release cmp ver = ok b := by
  unfold matches_release
  cases cmp.op
  · -- Exact
    by_cases hm : ver.major = cmp.major
    · simp only [hm, ne_eq, not_true_eq_false, ↓reduceIte]
      cases cmp.minor with
      | none =>
        simp only [b_ok]
        cases cmp.patch with
        | none =>
          simp only [b_ok]
          obtain ⟨n, hn, _⟩ := str_length_eq cmp.pre.raw hpre
          exact ⟨_, by rw [hn]; simp only [b_ok]; rfl⟩
        | some p =>
          by_cases hp : ver.patch = p
          · simp only [hp, ne_eq, not_true_eq_false, ↓reduceIte, b_ok]
            obtain ⟨n, hn, _⟩ := str_length_eq cmp.pre.raw hpre
            exact ⟨_, by rw [hn]; simp only [b_ok]; rfl⟩
          · exact ⟨false, by simp only [ne_eq, hp, not_false_eq_true, ↓reduceIte, b_ok]⟩
      | some m =>
        by_cases hmn : ver.minor = m
        · simp only [hmn, ne_eq, not_true_eq_false, ↓reduceIte, b_ok]
          cases cmp.patch with
          | none =>
            simp only [b_ok]
            obtain ⟨n, hn, _⟩ := str_length_eq cmp.pre.raw hpre
            exact ⟨_, by rw [hn]; simp only [b_ok]; rfl⟩
          | some p =>
            by_cases hp : ver.patch = p
            · simp only [hp, ne_eq, not_true_eq_false, ↓reduceIte, b_ok]
              obtain ⟨n, hn, _⟩ := str_length_eq cmp.pre.raw hpre
              exact ⟨_, by rw [hn]; simp only [b_ok]; rfl⟩
            · exact ⟨false, by simp only [ne_eq, hp, not_false_eq_true, ↓reduceIte, b_ok]⟩
        · exact ⟨false, by simp only [ne_eq, hmn, not_false_eq_true, ↓reduceIte, b_ok]⟩
    · exact ⟨false, by simp only [ne_eq, hm, not_false_eq_true, ↓reduceIte]⟩
  · -- Greater
    by_cases hm : ver.major = cmp.major
    · simp only [hm, ne_eq, not_true_eq_false, ↓reduceIte]
      cases cmp.minor with
      | none => exact ⟨false, rfl⟩
      | some m =>
        by_cases hmn : ver.minor = m
        · simp only [hmn, ne_eq, not_true_eq_false, ↓reduceIte]
          cases cmp.patch with
          | none => exact ⟨false, rfl⟩
          | some p =>
            by_cases hp : ver.patch = p
            · simp only [hp, ne_eq, not_true_eq_false, ↓reduceIte]
              obtain ⟨n, hn, _⟩ := str_length_eq cmp.pre.raw hpre
              exact ⟨_, by rw [hn]; simp only [b_ok]; rfl⟩
            · exact ⟨_, by simp only [ne_eq, hp, not_false_eq_true, ↓reduceIte]; rfl⟩
        · exact ⟨_, by simp only [ne_eq, hmn, not_false_eq_true, ↓reduceIte]; rfl⟩
    · exact ⟨_, by simp only [ne_eq, hm, not_false_eq_true, ↓reduceIte]; rfl⟩
  · -- GreaterEq
    by_cases hm : ver.major = cmp.major
    · simp only [hm, ne_eq, not_true_eq_false, ↓reduceIte]
      cases cmp.minor with
      | none => exact ⟨true, rfl⟩
      | some m =>
        by_cases hmn : ver.minor = m
        · simp only [hmn, ne_eq, not_true_eq_false, ↓reduceIte]
          cases cmp.patch with
          | none => exact ⟨true, rfl⟩
          | some p => exact ⟨_, rfl⟩
        · exact ⟨_, by simp only [ne_eq, hmn, not_false_eq_true, ↓reduceIte]; rfl⟩
    · exact ⟨_, by simp only [ne_eq, hm, not_false_eq_true, ↓reduceIte]; rfl⟩
  · -- Less
    by_cases hm : ver.major = cmp.major
    · simp only [hm, ne_eq, not_true_eq_false, ↓reduceIte]
      cases cmp.minor with
      | none => exact ⟨false, rfl⟩
      | some m =>
        by_cases hmn : ver.minor = m
        · simp only [hmn, ne_eq, not_true_eq_false, ↓reduceIte]
          cases cmp.patch with
          | none => exact ⟨false, rfl⟩
          | some p => exact ⟨_, rfl⟩
        · exact ⟨_, by simp only [ne_eq, hmn, not_false_eq_true, ↓reduceIte]; rfl⟩
    · exact ⟨_, by simp only [ne_eq, hm, not_false_eq_true, ↓reduceIte]; rfl⟩
  · -- LessEq
    by_cases hm : ver.major = cmp.major
    · simp only [hm, ne_eq, not_true_eq_false, ↓reduceIte]
      cases cmp.minor with
      | none => exact ⟨true, rfl⟩
      | some m =>
        by_cases hmn : ver.minor = m
        · simp only [hmn, ne_eq, not_true_eq_false, ↓reduceIte]
          cases cmp.patch with
          | none => exact ⟨true, rfl⟩
          | some p =>
            by_cases hp : ver.patch = p
            · simp only [hp, ne_eq, not_true_eq_false, ↓reduceIte]
              obtain ⟨n, hn, _⟩ := str_length_eq cmp.pre.raw hpre
              exact ⟨_, by rw [hn]; simp only [b_ok]; rfl⟩
            · exact ⟨_, by simp only [ne_eq, hp, not_false_eq_true, ↓reduceIte]; rfl⟩
        · exact ⟨_, by simp only [ne_eq, hmn, not_false_eq_true, ↓reduceIte]; rfl⟩
    · exact ⟨_, by simp only [ne_eq, hm, not_false_eq_true, ↓reduceIte]; rfl⟩
  · -- Tilde
    by_cases hm : ver.major = cmp.major
    · simp only [hm, ne_eq, not_true_eq_false, ↓reduceIte]
      cases cmp.minor with
      | none => exact ⟨true, rfl⟩
      | some m =>
        by_cases hmn : ver.minor = m
        · simp only [hmn, ne_eq, not_true_eq_false, ↓reduceIte]
          cases cmp.patch with
          | none => exact ⟨true, rfl⟩
          | some p => exact ⟨_, rfl⟩
        · exact ⟨false, by simp only [ne_eq, hmn, not_false_eq_true, ↓reduceIte]⟩
    · exact ⟨false, by simp only [ne_eq, hm, not_false_eq_true, ↓reduceIte]⟩
  · -- Caret
    by_cases hm : ver.major = cmp.major
    · simp only [hm, ne_eq, not_true_eq_false, ↓reduceIte]
      cases cmp.minor with
      | none => exact ⟨true, rfl⟩
      | some m =>
        cases cmp.patch with
        | none =>
          by_cases hpos : cmp.major > 0#u64 <;> exact ⟨_, by simp only [hpos, ↓reduceIte]; rfl⟩
        | some p => exact ⟨_, rfl⟩
    · exact ⟨false, by simp only [ne_eq, hm, not_false_eq_true, ↓reduceIte]⟩
  · -- Wildcard
    by_cases hm : ver.major = cmp.major
    · simp only [hm, ne_eq, not_true_eq_false, ↓reduceIte]
      cases cmp.minor with
      | none =>
        simp only [b_ok]
        cases cmp.patch with
        | none =>
          simp only [b_ok]
          obtain ⟨n, hn, _⟩ := str_length_eq cmp.pre.raw hpre
          exact ⟨_, by rw [hn]; simp only [b_ok]; rfl⟩
        | some p =>
          by_cases hp : ver.patch = p
          · simp only [hp, ne_eq, not_true_eq_false, ↓reduceIte, b_ok]
            obtain ⟨n, hn, _⟩ := str_length_eq cmp.pre.raw hpre
            exact ⟨_, by rw [hn]; simp only [b_ok]; rfl⟩
          · exact ⟨false, by simp only [ne_eq, hp, not_false_eq_true, ↓reduceIte, b_ok]⟩
      | some m =>
        by_cases hmn : ver.minor = m
        · simp only [hmn, ne_eq, not_true_eq_false, ↓reduceIte, b_ok]
          cases cmp.patch with
          | none =>
            simp only [b_ok]
            obtain ⟨n, hn, _⟩ := str_length_eq cmp.pre.raw hpre
            exact ⟨_, by rw [hn]; simp only [b_ok]; rfl⟩
          | some p =>
            by_cases hp : ver.patch = p
            · simp only [hp, ne_eq, not_true_eq_false, ↓reduceIte, b_ok]
              obtain ⟨n, hn, _⟩ := str_length_eq cmp.pre.raw hpre
              exact ⟨_, by rw [hn]; simp only [b_ok]; rfl⟩
            · exact ⟨false, by simp only [ne_eq, hp, not_false_eq_true, ↓reduceIte, b_ok]⟩
        · exact ⟨false, by simp only [ne_eq, hmn, not_false_eq_true, ↓reduceIte, b_ok]⟩
    · exact ⟨false, by simp only [ne_eq, hm, not_false_eq_true, ↓reduceIte]⟩

/-- Cargo `Caret` (`^M.m.p`) Regime 1 (`M > 0`): matches iff `v.major = M` and
`(v.minor > m ∨ (v.minor = m ∧ v.patch ≥ p))`. -/
theorem matches_release_caret_major_pos (M m p : Std.U64) (hM : M.val > 0)
    (pre : Prerelease) (v : Version) :
    matches_release ⟨.Caret, M, some m, some p, pre⟩ v = ok true ↔
      v.major = M ∧ (v.minor.val > m.val ∨ (v.minor = m ∧ v.patch.val ≥ p.val)) := by
  unfold matches_release
  have hMgt : M > 0#u64 := by change (0#u64).val < M.val; simpa using hM
  by_cases hm : v.major = M
  · simp only [hm, ne_eq, not_true_eq_false, ↓reduceIte, hMgt, true_and, ok.injEq]
    by_cases hmn : v.minor = m
    · subst hmn
      simp only [ne_eq, not_true_eq_false, ↓reduceIte, decide_eq_true_eq,
        gt_iff_lt, lt_self_iff_false, true_and, false_or]
      exact Iff.rfl
    · simp only [ne_eq, hmn, not_false_eq_true, ↓reduceIte, decide_eq_true_eq,
        false_and, or_false]
      exact Iff.rfl
  · simp only [ne_eq, hm, not_false_eq_true, ↓reduceIte, ok.injEq, Bool.false_eq_true, false_and]

/-- Cargo `Caret` (`^0.m.p`) Regime 2 (`M = 0, m > 0`): matches iff `v.major = 0`,
`v.minor = m`, and `v.patch ≥ p`. -/
theorem matches_release_caret_zero_minor_pos (m p : Std.U64) (hm : m.val > 0)
    (pre : Prerelease) (v : Version) :
    matches_release ⟨.Caret, 0#u64, some m, some p, pre⟩ v = ok true ↔
      v.major = 0#u64 ∧ v.minor = m ∧ v.patch.val ≥ p.val := by
  unfold matches_release
  have hM0 : ¬ (0#u64 > 0#u64) := by decide
  have hmgt : m > 0#u64 := by change (0#u64).val < m.val; simpa using hm
  by_cases hmaj : v.major = 0#u64
  · simp only [hmaj, ne_eq, not_true_eq_false, ↓reduceIte, hM0, hmgt, ok.injEq,
      Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq, true_and]
    exact Iff.rfl
  · simp only [ne_eq, hmaj, not_false_eq_true, ↓reduceIte, ok.injEq, Bool.false_eq_true, false_and]

/-- Cargo `Caret` (`^0.0.p`) Regime 3 (`M = 0, m = 0`): matches iff `v.major = 0`,
`v.minor = 0`, and `v.patch = p`. -/
theorem matches_release_caret_zero_zero (p : Std.U64) (pre : Prerelease) (v : Version) :
    matches_release ⟨.Caret, 0#u64, some 0#u64, some p, pre⟩ v = ok true ↔
      v.major = 0#u64 ∧ v.minor = 0#u64 ∧ v.patch = p := by
  unfold matches_release
  have h0 : ¬ (0#u64 > 0#u64) := by decide
  by_cases hmaj : v.major = 0#u64
  · simp only [hmaj, ne_eq, not_true_eq_false, ↓reduceIte, h0, ok.injEq,
      Bool.and_eq_true, beq_iff_eq, true_and]
  · simp only [ne_eq, hmaj, not_false_eq_true, ↓reduceIte, ok.injEq, Bool.false_eq_true, false_and]

/-- Cargo `Tilde` (`~M.m.p`): matches iff `v.major = M`, `v.minor = m`, and `v.patch ≥ p`. -/
theorem matches_release_tilde_spec (M m p : Std.U64) (pre : Prerelease) (v : Version) :
    matches_release ⟨.Tilde, M, some m, some p, pre⟩ v = ok true ↔
      v.major = M ∧ v.minor = m ∧ v.patch.val ≥ p.val := by
  unfold matches_release
  by_cases hmaj : v.major = M
  · simp only [hmaj, ne_eq, not_true_eq_false, ↓reduceIte, true_and]
    by_cases hmin : v.minor = m
    · simp only [hmin, ne_eq, not_true_eq_false, ↓reduceIte, ok.injEq, decide_eq_true_eq, true_and]
      exact Iff.rfl
    · simp only [ne_eq, hmin, not_false_eq_true, ↓reduceIte, ok.injEq, Bool.false_eq_true, false_and]
  · simp only [ne_eq, hmaj, not_false_eq_true, ↓reduceIte, ok.injEq, Bool.false_eq_true, false_and]

/-- `UInt64::MAX` overflow immunity for `^u64::MAX.0.0`: matches iff `v.major = u64::MAX`
(never wraps `major + 1` to `0`, so `0.0.0` is never matched). -/
theorem matches_release_caret_u64_max (pre : Prerelease) (v : Version) :
    matches_release ⟨.Caret, 18446744073709551615#u64, some 0#u64, some 0#u64, pre⟩ v = ok true ↔
      v.major = 18446744073709551615#u64 := by
  rw [matches_release_caret_major_pos _ _ _ (by decide)]
  constructor
  · intro h; exact h.1
  · intro hmaj
    refine ⟨hmaj, ?_⟩
    by_cases hmin : v.minor = 0#u64
    · right; exact ⟨hmin, Nat.zero_le _⟩
    · left
      have hne : v.minor.val ≠ (0#u64).val := u64_ne_val hmin
      have h0 : (0#u64).val = 0 := by decide
      omega

/-- `UInt64::MAX` overflow immunity for `>u64::MAX`: never matches any version. -/
theorem matches_release_greater_u64_max (pre : Prerelease) (v : Version) :
    matches_release ⟨.Greater, 18446744073709551615#u64, none, none, pre⟩ v = ok false := by
  unfold matches_release
  by_cases hmaj : v.major = 18446744073709551615#u64
  · simp only [hmaj, ne_eq, not_true_eq_false, ↓reduceIte]
  · simp only [ne_eq, hmaj, not_false_eq_true, ↓reduceIte, ok.injEq, decide_eq_false_iff_not]
    intro hgt
    have hlt : v.major.val < 2 ^ 64 := v.major.bv.isLt
    have hmax : (18446744073709551615#u64).val = 18446744073709551615 := by decide
    have hv : (18446744073709551615#u64).val < v.major.val := hgt
    omega

/-- `Exact` on a full release comparator matches iff `(major, minor, patch)` are all equal. -/
theorem matches_release_exact_iff (M m p : Std.U64) (v : Version) :
    matches_release ⟨.Exact, M, some m, some p, ⟨""⟩⟩ v = ok true ↔
      v.major = M ∧ v.minor = m ∧ v.patch = p := by
  unfold matches_release
  by_cases hmaj : v.major = M
  · simp only [hmaj, ne_eq, not_true_eq_false, ↓reduceIte, true_and]
    by_cases hmin : v.minor = m
    · simp only [hmin, ne_eq, not_true_eq_false, ↓reduceIte, b_ok, true_and]
      by_cases hpat : v.patch = p
      · simp only [hpat, ne_eq, not_true_eq_false, ↓reduceIte, b_ok, iff_true]
        obtain ⟨n, hn, hnv⟩ := str_length_eq "" (by unfold StrValid; decide)
        rw [hn]
        simp only [b_ok]
        have hn0 : (n == 0#i32) = true := (i32_beq_zero_iff n).mpr (by simpa using hnv)
        simp [hn0]
      · simp only [ne_eq, hpat, not_false_eq_true, ↓reduceIte, b_ok, ok.injEq,
          Bool.false_eq_true]
    · simp only [ne_eq, hmin, not_false_eq_true, ↓reduceIte, b_ok, ok.injEq,
        Bool.false_eq_true, false_and]
  · simp only [ne_eq, hmaj, not_false_eq_true, ↓reduceIte, ok.injEq,
      Bool.false_eq_true, false_and]

/-- Reflexivity of `Caret` on a full triple. -/
theorem matches_release_refl_caret (M m p : Std.U64) (cpre vpre : Prerelease) (vbuild : BuildMetadata) :
    matches_release ⟨.Caret, M, some m, some p, cpre⟩ ⟨M, m, p, vpre, vbuild⟩ = ok true := by
  by_cases hM : M.val > 0
  · exact (matches_release_caret_major_pos M m p hM cpre _).mpr ⟨rfl, Or.inr ⟨rfl, Nat.le_refl _⟩⟩
  · have hM0 : M = 0#u64 := u64_ext (by
      have h0 : (0#u64).val = 0 := by decide
      omega)
    subst hM0
    by_cases hm : m.val > 0
    · exact (matches_release_caret_zero_minor_pos m p hm cpre _).mpr ⟨rfl, rfl, Nat.le_refl _⟩
    · have hm0 : m = 0#u64 := u64_ext (by
        have h0 : (0#u64).val = 0 := by decide
        omega)
      subst hm0
      exact (matches_release_caret_zero_zero p cpre _).mpr ⟨rfl, rfl, rfl⟩

/-- Exact complementarity of `Less` and `GreaterEq` for ALL comparators (full or partial). -/
theorem matches_release_lt_ge_complement (M : Std.U64) (mo po : Option Std.U64)
    (pre : Prerelease) (v : Version) :
    ∃ b : Bool,
      matches_release ⟨.Less, M, mo, po, pre⟩ v = ok b ∧
      matches_release ⟨.GreaterEq, M, mo, po, pre⟩ v = ok (!b) := by
  unfold matches_release
  by_cases hmaj : v.major = M
  · simp only [hmaj, ne_eq, not_true_eq_false, ↓reduceIte]
    cases mo with
    | none => exact ⟨false, rfl, rfl⟩
    | some m =>
      by_cases hmin : v.minor = m
      · simp only [hmin, ne_eq, not_true_eq_false, ↓reduceIte]
        cases po with
        | none => exact ⟨false, rfl, rfl⟩
        | some p =>
          refine ⟨decide (v.patch < p), rfl, ?_⟩
          simp only [ok.injEq]
          by_cases hlt : v.patch < p
          · have hge : ¬ (v.patch ≥ p) := by
              have : v.patch.val < p.val := hlt
              change ¬ p.val ≤ v.patch.val; omega
            simp [hlt, hge]
          · have hge : v.patch ≥ p := by
              have : ¬ v.patch.val < p.val := hlt
              change p.val ≤ v.patch.val; omega
            simp [hlt, hge]
      · have hne : v.minor.val ≠ m.val := u64_ne_val hmin
        refine ⟨decide (v.minor < m), by simp only [ne_eq, hmin, not_false_eq_true, ↓reduceIte], ?_⟩
        simp only [ne_eq, hmin, not_false_eq_true, ↓reduceIte, ok.injEq]
        by_cases hlt : v.minor < m
        · have hgt : ¬ (v.minor > m) := by
            have : v.minor.val < m.val := hlt
            change ¬ m.val < v.minor.val; omega
          simp [hlt, hgt]
        · have hgt : v.minor > m := by
            have : ¬ v.minor.val < m.val := hlt
            change m.val < v.minor.val; omega
          simp [hlt, hgt]
  · have hne : v.major.val ≠ M.val := u64_ne_val hmaj
    refine ⟨decide (v.major < M), by simp only [ne_eq, hmaj, not_false_eq_true, ↓reduceIte], ?_⟩
    simp only [ne_eq, hmaj, not_false_eq_true, ↓reduceIte, ok.injEq]
    by_cases hlt : v.major < M
    · have hgt : ¬ (v.major > M) := by
        have : v.major.val < M.val := hlt
        change ¬ M.val < v.major.val; omega
      simp [hlt, hgt]
    · have hgt : v.major > M := by
        have : ¬ v.major.val < M.val := hlt
        change M.val < v.major.val; omega
      simp [hlt, hgt]

/-- Exact complementarity of `Greater` and `LessEq` for ALL comparators (full or partial). -/
theorem matches_release_gt_le_complement (M : Std.U64) (mo po : Option Std.U64)
    (pre : Prerelease) (hpre : StrValid pre.raw) (v : Version) :
    ∃ b : Bool,
      matches_release ⟨.Greater, M, mo, po, pre⟩ v = ok b ∧
      matches_release ⟨.LessEq, M, mo, po, pre⟩ v = ok (!b) := by
  unfold matches_release
  by_cases hmaj : v.major = M
  · simp only [hmaj, ne_eq, not_true_eq_false, ↓reduceIte]
    cases mo with
    | none => exact ⟨false, rfl, rfl⟩
    | some m =>
      by_cases hmin : v.minor = m
      · simp only [hmin, ne_eq, not_true_eq_false, ↓reduceIte]
        cases po with
        | none => exact ⟨false, rfl, rfl⟩
        | some p =>
          by_cases hpat : v.patch = p
          · simp only [hpat, ne_eq, not_true_eq_false, ↓reduceIte]
            obtain ⟨n, hn, hnv⟩ := str_length_eq pre.raw hpre
            rw [hn]
            simp only [b_ok]
            refine ⟨decide (n > 0#i32), rfl, ?_⟩
            simp only [ok.injEq]
            have h0v : (0#i32).val = 0 := by decide
            by_cases hpos : n > 0#i32
            · have hne0 : (n == 0#i32) = false := by
                cases hbeq : (n == 0#i32)
                · rfl
                · have hv := (i32_beq_zero_iff n).mp hbeq
                  have : (0#i32).val < n.val := hpos
                  omega
              simp [hpos, hne0]
            · have heq0 : (n == 0#i32) = true := by
                apply (i32_beq_zero_iff n).mpr
                have : ¬ (0#i32).val < n.val := hpos
                omega
              simp [hpos, heq0]
          · have hne : v.patch.val ≠ p.val := u64_ne_val hpat
            refine ⟨decide (v.patch > p), by simp only [ne_eq, hpat, not_false_eq_true, ↓reduceIte], ?_⟩
            simp only [ne_eq, hpat, not_false_eq_true, ↓reduceIte, ok.injEq]
            by_cases hgt : v.patch > p
            · have hlt : ¬ (v.patch < p) := by
                have : p.val < v.patch.val := hgt
                change ¬ v.patch.val < p.val; omega
              simp [hgt, hlt]
            · have hlt : v.patch < p := by
                have : ¬ p.val < v.patch.val := hgt
                change v.patch.val < p.val; omega
              simp [hgt, hlt]
      · have hne : v.minor.val ≠ m.val := u64_ne_val hmin
        refine ⟨decide (v.minor > m), by simp only [ne_eq, hmin, not_false_eq_true, ↓reduceIte], ?_⟩
        simp only [ne_eq, hmin, not_false_eq_true, ↓reduceIte, ok.injEq]
        by_cases hgt : v.minor > m
        · have hlt : ¬ (v.minor < m) := by
            have : m.val < v.minor.val := hgt
            change ¬ v.minor.val < m.val; omega
          simp [hgt, hlt]
        · have hlt : v.minor < m := by
            have : ¬ m.val < v.minor.val := hgt
            change v.minor.val < m.val; omega
          simp [hgt, hlt]
  · have hne : v.major.val ≠ M.val := u64_ne_val hmaj
    refine ⟨decide (v.major > M), by simp only [ne_eq, hmaj, not_false_eq_true, ↓reduceIte], ?_⟩
    simp only [ne_eq, hmaj, not_false_eq_true, ↓reduceIte, ok.injEq]
    by_cases hgt : v.major > M
    · have hlt : ¬ (v.major < M) := by
        have : M.val < v.major.val := hgt
        change ¬ v.major.val < M.val; omega
      simp [hgt, hlt]
    · have hlt : v.major < M := by
        have : ¬ M.val < v.major.val := hgt
        change v.major.val < M.val; omega
      simp [hgt, hlt]

/-- Monotonicity of `GreaterEq` with respect to `cmp_core` ordering. -/
theorem matches_release_ge_monotone (M : Std.U64) (mo po : Option Std.U64) (pre : Prerelease)
    (v1 v2 : Version) (r : Std.I32)
    (hle : cmp_core v1.major v1.minor v1.patch v2.major v2.minor v2.patch = ok r)
    (hr : r.val ≤ 0)
    (hm1 : matches_release ⟨.GreaterEq, M, mo, po, pre⟩ v1 = ok true) :
    matches_release ⟨.GreaterEq, M, mo, po, pre⟩ v2 = ok true := by
  obtain ⟨r', hr', hcases⟩ := cmp_core_total v1.major v1.minor v1.patch v2.major v2.minor v2.patch
  rw [hle, ok.injEq] at hr'; subst hr'
  have hlex : v1.major.val < v2.major.val ∨
      (v1.major = v2.major ∧ v1.minor.val < v2.minor.val) ∨
      (v1.major = v2.major ∧ v1.minor = v2.minor ∧ v1.patch.val ≤ v2.patch.val) := by
    rcases hcases with rfl | rfl | rfl
    · rw [cmp_core_lt_iff] at hle
      rcases hle with h | ⟨e1, h⟩ | ⟨e1, e2, h⟩
      · exact Or.inl h
      · exact Or.inr (Or.inl ⟨e1, h⟩)
      · exact Or.inr (Or.inr ⟨e1, e2, Nat.le_of_lt h⟩)
    · rw [cmp_core_eq_zero_iff] at hle
      obtain ⟨e1, e2, e3⟩ := hle
      exact Or.inr (Or.inr ⟨e1, e2, by rw [e3]⟩)
    · simp at hr
  unfold matches_release at hm1 ⊢
  by_cases h1m : v1.major = M
  · simp only [h1m, ne_eq, not_true_eq_false, ↓reduceIte] at hm1
    rcases hlex with hmaj_lt | ⟨emaj, hmin_lt⟩ | ⟨emaj, emin, hpat_le⟩
    · have h2gt : v2.major > M := by change M.val < v2.major.val; rw [← h1m]; exact hmaj_lt
      have h2m : v2.major ≠ M := fun heq => by rw [heq, ← h1m] at hmaj_lt; omega
      simp only [ne_eq, h2m, not_false_eq_true, ↓reduceIte, h2gt, decide_true]
    · have h2m : v2.major = M := emaj.symm.trans h1m
      simp only [h2m, ne_eq, not_true_eq_false, ↓reduceIte]
      cases mo with
      | none => rfl
      | some m =>
        by_cases h1n : v1.minor = m
        · have h2gt : v2.minor > m := by change m.val < v2.minor.val; rw [← h1n]; exact hmin_lt
          have h2n : v2.minor ≠ m := fun heq => by rw [heq, ← h1n] at hmin_lt; omega
          simp only [ne_eq, h2n, not_false_eq_true, ↓reduceIte, h2gt, decide_true]
        · simp only [ne_eq, h1n, not_false_eq_true, ↓reduceIte, ok.injEq, decide_eq_true_eq] at hm1
          have hgt1 : m.val < v1.minor.val := hm1
          have h2gt : v2.minor > m := by change m.val < v2.minor.val; omega
          have h2n : v2.minor ≠ m := fun heq => by rw [heq] at hmin_lt; omega
          simp only [ne_eq, h2n, not_false_eq_true, ↓reduceIte, h2gt, decide_true]
    · have h2m : v2.major = M := emaj.symm.trans h1m
      simp only [h2m, ne_eq, not_true_eq_false, ↓reduceIte]
      cases mo with
      | none => rfl
      | some m =>
        by_cases h1n : v1.minor = m
        · have h2n : v2.minor = m := emin.symm.trans h1n
          simp only [h1n, ne_eq, not_true_eq_false, ↓reduceIte] at hm1
          simp only [h2n, ne_eq, not_true_eq_false, ↓reduceIte]
          cases po with
          | none => rfl
          | some p =>
            simp only [ok.injEq, decide_eq_true_eq] at hm1 ⊢
            change p.val ≤ v2.patch.val
            have : p.val ≤ v1.patch.val := hm1
            omega
        · rw [← emin]
          simp only [ne_eq, h1n, not_false_eq_true, ↓reduceIte] at hm1 ⊢
          exact hm1
  · simp only [ne_eq, h1m, not_false_eq_true, ↓reduceIte, ok.injEq, decide_eq_true_eq] at hm1
    have hgt1 : M.val < v1.major.val := hm1
    have hgt2 : M.val < v2.major.val := by
      rcases hlex with h | ⟨e1, _⟩ | ⟨e1, _, _⟩
      · omega
      · rw [← e1]; exact hgt1
      · rw [← e1]; exact hgt1
    have h2m : v2.major ≠ M := fun heq => by rw [heq] at hgt2; omega
    have h2gt : v2.major > M := hgt2
    simp only [ne_eq, h2m, not_false_eq_true, ↓reduceIte, h2gt, decide_true]

/-- Cargo prerelease opt-in compatibility exact specification (`pre_is_compatible`). -/
theorem pre_is_compatible_spec (cmp : Comparator) (ver : Version) (hpre : StrValid cmp.pre.raw) :
    pre_is_compatible cmp ver = ok true ↔
      cmp.major = ver.major ∧
      cmp.minor = some ver.minor ∧
      cmp.patch = some ver.patch ∧
      cmp.pre.raw.utf8ByteSize > 0 := by
  unfold pre_is_compatible
  by_cases hmaj : cmp.major = ver.major
  · simp only [hmaj, ne_eq, not_true_eq_false, ↓reduceIte, true_and]
    obtain ⟨n, hn, hnv⟩ := str_length_eq cmp.pre.raw hpre
    rw [hn]
    simp only [b_ok]
    by_cases h0 : (n == 0#i32) = true
    · have hv0 : n.val = 0 := (i32_beq_zero_iff n).mp h0
      simp only [h0, ↓reduceIte, ok.injEq, Bool.false_eq_true, false_iff, not_and]
      intro _ _ hpos
      omega
    · have hvne : n.val ≠ 0 := fun hv => h0 ((i32_beq_zero_iff n).mpr hv)
      have hpos : cmp.pre.raw.utf8ByteSize > 0 := by omega
      simp only [h0, ↓reduceIte, hpos, and_true]
      cases cmp.minor with
      | none => simp
      | some m =>
        by_cases hmin : m = ver.minor
        · subst hmin
          simp only [ne_eq, not_true_eq_false, ↓reduceIte, true_and]
          cases cmp.patch with
          | none => simp
          | some p =>
            simp only [Bool.false_eq_true, ↓reduceIte, ok.injEq, beq_iff_eq, Option.some.injEq]
        · simp only [ne_eq, hmin, not_false_eq_true, ↓reduceIte, ok.injEq,
            Bool.false_eq_true, Option.some.injEq, false_and]
  · simp only [ne_eq, hmaj, not_false_eq_true, ↓reduceIte, b_ok, ok.injEq,
      Bool.false_eq_true, false_and]

end SemverProofs
