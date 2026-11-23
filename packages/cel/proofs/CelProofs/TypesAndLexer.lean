import Aeneas
import PionLean
import Cel.Types
import Cel.Funs

open Aeneas Aeneas.Std Result Pion cel

namespace CelProofs

private lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

private lemma i32_add_val_of_bounds (a b : I32)
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  have hwrap : (Pion.I32.add a b).val = Int.bmod (a.val + b.val) (2 ^ 32) := by
    change (I32.wrapping_add a b).val = Int.bmod (a.val + b.val) (2 ^ 32)
    simp only [I32.wrapping_add, IScalar.wrapping_add, IScalar.val, BitVec.toInt_add]
    rfl
  rw [hwrap]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_sub_val_of_bounds (a b : I32)
    (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  have hwrap : (Pion.I32.sub a b).val = Int.bmod (a.val - b.val) (2 ^ 32) := by
    change (I32.wrapping_sub a b).val = Int.bmod (a.val - b.val) (2 ^ 32)
    simp only [I32.wrapping_sub, IScalar.wrapping_sub, IScalar.val, BitVec.toInt_sub]
    rfl
  rw [hwrap]
  exact Int.bmod_eq_of_le (by omega) (by omega)

/-- Theorem 13: `cel_type_eq` is total and exact structural equality on `CelType`. -/
theorem cel_type_eq_iff (a b : CelType) :
    ∃ r, cel_type_eq a b = ok r ∧ (r = true ↔ a = b) := by
  induction a generalizing b with
  | Dyn => cases b <;> rw [cel_type_eq] <;> simp
  | Null => cases b <;> rw [cel_type_eq] <;> simp
  | Bool => cases b <;> rw [cel_type_eq] <;> simp
  | Int => cases b <;> rw [cel_type_eq] <;> simp
  | UInt => cases b <;> rw [cel_type_eq] <;> simp
  | Double => cases b <;> rw [cel_type_eq] <;> simp
  | String => cases b <;> rw [cel_type_eq] <;> simp
  | Bytes => cases b <;> rw [cel_type_eq] <;> simp
  | Timestamp => cases b <;> rw [cel_type_eq] <;> simp
  | Duration => cases b <;> rw [cel_type_eq] <;> simp
  | «Type» => cases b <;> rw [cel_type_eq] <;> simp
  | List x ih =>
    cases b with
    | List y =>
      rw [cel_type_eq]
      rcases ih y with ⟨r, hr, hiff⟩
      rw [hr, result_bind_ok]
      exact ⟨r, rfl, by simp [hiff]⟩
    | Dyn | Null | Bool | Int | UInt | Double | String | Bytes | Map _ _ | Timestamp | Duration | «Type» =>
      rw [cel_type_eq]; all_goals simp
  | Map k1 v1 ihk ihv =>
    cases b with
    | Map k2 v2 =>
      rw [cel_type_eq]
      rcases ihk k2 with ⟨rk, hrk, hiffk⟩
      rw [hrk, result_bind_ok]
      cases rk
      · simp only [Bool.false_eq_true, ↓reduceIte]
        refine ⟨false, rfl, ?_⟩
        simp only [Bool.false_eq_true, false_iff]
        intro heq; cases heq
        exact absurd (hiffk.mpr rfl) (by decide)
      · simp only [↓reduceIte]
        rcases ihv v2 with ⟨rv, hrv, hiffv⟩
        rw [hrv, result_bind_ok]
        refine ⟨rv, rfl, ?_⟩
        have hk : k1 = k2 := hiffk.mp rfl
        subst hk
        simp [hiffv]
    | Dyn | Null | Bool | Int | UInt | Double | String | Bytes | List _ | Timestamp | Duration | «Type» =>
      rw [cel_type_eq]; all_goals simp

/-- Helper: `cel_type_eq` is reflexive. -/
private lemma cel_type_eq_refl (a : CelType) :
    cel_type_eq a a = ok true := by
  rcases cel_type_eq_iff a a with ⟨r, hr, hiff⟩
  rw [hr, hiff.mpr rfl]

/-- Helper: `cel_type_eq` is symmetric. -/
private lemma cel_type_eq_symm (a b : CelType) :
    cel_type_eq a b = cel_type_eq b a := by
  rcases cel_type_eq_iff a b with ⟨r1, hr1, hiff1⟩
  rcases cel_type_eq_iff b a with ⟨r2, hr2, hiff2⟩
  rw [hr1, hr2]
  apply congrArg ok
  apply Bool.eq_iff_iff.mpr
  rw [hiff1, hiff2, eq_comm]

/-- Theorem 17: `is_assignable` is reflexive (every CEL type is assignable to itself). -/
theorem is_assignable_refl (a : CelType) :
    is_assignable a a = ok true := by
  induction a with
  | Dyn => rw [is_assignable]
  | List x ih =>
    rw [is_assignable, ih, result_bind_ok]
  | Map k v ihk ihv =>
    rw [is_assignable, ihk, result_bind_ok]
    simp only [↓reduceIte]
    rw [ihv, result_bind_ok]
  | Null | Bool | Int | UInt | Double | String | Bytes | Timestamp | Duration | «Type» =>
    rw [is_assignable]
    · simp [cel_type_eq_refl]
    all_goals simp

/-- Theorem 18: `is_assignable` (gradual typing consistency) is symmetric. -/
theorem is_assignable_symm (a b : CelType) :
    is_assignable a b = is_assignable b a := by
  induction a generalizing b with
  | Dyn =>
    cases b <;> (first | rfl | (rw [is_assignable, is_assignable]; all_goals simp))
  | List x ih =>
    cases b with
    | Dyn => rw [is_assignable, is_assignable]
    | List y =>
      rw [is_assignable, is_assignable, ih y]
    | Map _ _ =>
      rw [is_assignable, is_assignable]
      all_goals simp
    | Null | Bool | Int | UInt | Double | String | Bytes | Timestamp | Duration | «Type» =>
      rw [is_assignable, is_assignable]
      · rw [cel_type_eq]; all_goals simp
      all_goals simp
  | Map k1 v1 ihk ihv =>
    cases b with
    | Dyn => rw [is_assignable, is_assignable]
    | Map k2 v2 =>
      rw [is_assignable, is_assignable, ihk k2, ihv v2]
    | List _ =>
      rw [is_assignable, is_assignable]
      all_goals simp
    | Null | Bool | Int | UInt | Double | String | Bytes | Timestamp | Duration | «Type» =>
      rw [is_assignable, is_assignable]
      · rw [cel_type_eq]; all_goals simp
      all_goals simp
  | Null | Bool | Int | UInt | Double | String | Bytes | Timestamp | Duration | «Type» =>
    cases b with
    | Dyn =>
      rw [is_assignable, is_assignable]
      all_goals simp
    | List _ =>
      rw [is_assignable, is_assignable]
      · rw [cel_type_eq]; all_goals simp
      all_goals simp
    | Map _ _ =>
      rw [is_assignable, is_assignable]
      · rw [cel_type_eq]; all_goals simp
      all_goals simp
    | Null | Bool | Int | UInt | Double | String | Bytes | Timestamp | Duration | «Type» =>
      first
      | rfl
      | (rw [is_assignable, is_assignable]
         · rw [cel_type_eq_symm]
         all_goals simp)

/-- Theorem 23: CEL identifier start bytes are a subset of continuation bytes, while ASCII digits are continuation bytes disjoint from identifier starts. -/
theorem lexer_ident_digit_invariants (b : I32) :
    (is_ident_start b = ok true → is_ident_cont b = ok true) ∧
    (is_digit b = ok true → is_ident_cont b = ok true ∧ is_ident_start b = ok false) := by
  constructor
  · intro hs
    unfold is_ident_cont
    rw [hs, result_bind_ok]
    simp
  · intro hd
    unfold is_digit at hd
    have hd' := result_ok_inj hd
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hd'
    have hlo : 48 ≤ b.val := hd'.1
    have hhi : b.val ≤ 57 := hd'.2
    have hnot : is_ident_start b = ok false := by
      unfold is_ident_start
      apply congrArg ok
      have h1 : ¬(65#i32 ≤ b) := fun h => by have : 65 ≤ b.val := h; omega
      have h2 : ¬(97#i32 ≤ b) := fun h => by have : 97 ≤ b.val := h; omega
      have h3 : (b == 95#i32) = false := by
        simp only [beq_eq_false_iff_ne]
        intro heq; rw [heq] at hhi; exact absurd hhi (by decide)
      change ((((decide (65#i32 ≤ b)) && (decide (b ≤ 90#i32))) || ((decide (97#i32 ≤ b)) && (decide (b ≤ 122#i32)))) || (b == 95#i32)) = false
      simp [h1, h2, h3]
    refine ⟨?_, hnot⟩
    unfold is_ident_cont
    rw [hnot, result_bind_ok]
    apply congrArg ok
    simp [hd'.1, hd'.2]

/-- Theorem 24: `hex_val` returns a value in `[-1, 15]`, non-negative iff `b` is an ASCII hex digit, and is case-insensitive on `'A'..'F'` vs `'a'..'f'`. -/
theorem hex_val_range_and_case (b : I32) :
    (∃ v, hex_val b = ok v ∧ -1 ≤ v.val ∧ v.val ≤ 15 ∧
      (0 ≤ v.val ↔ ((48 ≤ b.val ∧ b.val ≤ 57) ∨ (65 ≤ b.val ∧ b.val ≤ 70) ∨ (97 ≤ b.val ∧ b.val ≤ 102)))) ∧
    (65 ≤ b.val → b.val ≤ 70 → hex_val (Pion.I32.add b 32#i32) = hex_val b) := by
  constructor
  · unfold hex_val
    have c48 : (48#i32 : I32).val = 48 := rfl
    have c55 : (55#i32 : I32).val = 55 := rfl
    have c87 : (87#i32 : I32).val = 87 := rfl
    refine ⟨_, rfl, ?_, ?_, ?_⟩
    · split_ifs with h1 h2 h3
      · simp only [Bool.and_eq_true, decide_eq_true_eq] at h1
        have hlo : 48 ≤ b.val := h1.1; have hhi : b.val ≤ 57 := h1.2
        have hs := i32_sub_val_of_bounds b 48#i32 (by omega) (by omega)
        omega
      · simp only [Bool.and_eq_true, decide_eq_true_eq] at h2
        have hlo : 65 ≤ b.val := h2.1; have hhi : b.val ≤ 70 := h2.2
        have hs := i32_sub_val_of_bounds b 55#i32 (by omega) (by omega)
        omega
      · simp only [Bool.and_eq_true, decide_eq_true_eq] at h3
        have hlo : 97 ≤ b.val := h3.1; have hhi : b.val ≤ 102 := h3.2
        have hs := i32_sub_val_of_bounds b 87#i32 (by omega) (by omega)
        omega
      · decide
    · split_ifs with h1 h2 h3
      · simp only [Bool.and_eq_true, decide_eq_true_eq] at h1
        have hlo : 48 ≤ b.val := h1.1; have hhi : b.val ≤ 57 := h1.2
        have hs := i32_sub_val_of_bounds b 48#i32 (by omega) (by omega)
        omega
      · simp only [Bool.and_eq_true, decide_eq_true_eq] at h2
        have hlo : 65 ≤ b.val := h2.1; have hhi : b.val ≤ 70 := h2.2
        have hs := i32_sub_val_of_bounds b 55#i32 (by omega) (by omega)
        omega
      · simp only [Bool.and_eq_true, decide_eq_true_eq] at h3
        have hlo : 97 ≤ b.val := h3.1; have hhi : b.val ≤ 102 := h3.2
        have hs := i32_sub_val_of_bounds b 87#i32 (by omega) (by omega)
        omega
      · decide
    · split_ifs with h1 h2 h3
      · simp only [Bool.and_eq_true, decide_eq_true_eq] at h1
        have hlo : 48 ≤ b.val := h1.1; have hhi : b.val ≤ 57 := h1.2
        have hs := i32_sub_val_of_bounds b 48#i32 (by omega) (by omega)
        omega
      · simp only [Bool.and_eq_true, decide_eq_true_eq] at h2
        have hlo : 65 ≤ b.val := h2.1; have hhi : b.val ≤ 70 := h2.2
        have hs := i32_sub_val_of_bounds b 55#i32 (by omega) (by omega)
        omega
      · simp only [Bool.and_eq_true, decide_eq_true_eq] at h3
        have hlo : 97 ≤ b.val := h3.1; have hhi : b.val ≤ 102 := h3.2
        have hs := i32_sub_val_of_bounds b 87#i32 (by omega) (by omega)
        omega
      · have h1' : ¬(48 ≤ b.val ∧ b.val ≤ 57) := by
          intro ⟨ha, hb⟩; apply h1; simp only [Bool.and_eq_true, decide_eq_true_eq]; exact ⟨ha, hb⟩
        have h2' : ¬(65 ≤ b.val ∧ b.val ≤ 70) := by
          intro ⟨ha, hb⟩; apply h2; simp only [Bool.and_eq_true, decide_eq_true_eq]; exact ⟨ha, hb⟩
        have h3' : ¬(97 ≤ b.val ∧ b.val ≤ 102) := by
          intro ⟨ha, hb⟩; apply h3; simp only [Bool.and_eq_true, decide_eq_true_eq]; exact ⟨ha, hb⟩
        have cm1 : ((-1)#i32 : I32).val = -1 := rfl
        omega
  · intro hlo hhi
    unfold hex_val
    have c32 : (32#i32 : I32).val = 32 := rfl
    have c55 : (55#i32 : I32).val = 55 := rfl
    have c87 : (87#i32 : I32).val = 87 := rfl
    have hadd := i32_add_val_of_bounds b 32#i32 (by omega) (by omega)
    have h1l : ((decide (Pion.I32.add b 32#i32 >= 48#i32)) && (decide (Pion.I32.add b 32#i32 <= 57#i32))) = false := by
      have hne : ¬(Pion.I32.add b 32#i32 ≤ 57#i32) := fun h => by have : (Pion.I32.add b 32#i32).val ≤ 57 := h; omega
      simp only [hne, decide_false, Bool.and_false]
    have h2l : ((decide (Pion.I32.add b 32#i32 >= 65#i32)) && (decide (Pion.I32.add b 32#i32 <= 70#i32))) = false := by
      have hne : ¬(Pion.I32.add b 32#i32 ≤ 70#i32) := fun h => by have : (Pion.I32.add b 32#i32).val ≤ 70 := h; omega
      simp only [hne, decide_false, Bool.and_false]
    have h3l : ((decide (Pion.I32.add b 32#i32 >= 97#i32)) && (decide (Pion.I32.add b 32#i32 <= 102#i32))) = true := by
      have ha : 97#i32 ≤ Pion.I32.add b 32#i32 := by show 97 ≤ (Pion.I32.add b 32#i32).val; omega
      have hb : Pion.I32.add b 32#i32 ≤ 102#i32 := by show (Pion.I32.add b 32#i32).val ≤ 102; omega
      simp only [ge_iff_le, ha, hb, decide_true, Bool.and_true]
    have h1r : ((decide (b >= 48#i32)) && (decide (b <= 57#i32))) = false := by
      have hne : ¬(b ≤ 57#i32) := fun h => by have : b.val ≤ 57 := h; omega
      simp only [hne, decide_false, Bool.and_false]
    have h2r : ((decide (b >= 65#i32)) && (decide (b <= 70#i32))) = true := by
      have ha : 65#i32 ≤ b := by show 65 ≤ b.val; omega
      have hb : b ≤ 70#i32 := by show b.val ≤ 70; omega
      simp only [ge_iff_le, ha, hb, decide_true, Bool.and_true]
    simp only [h1l, h2l, h3l, h1r, h2r, Bool.false_eq_true, ↓reduceIte]
    apply congrArg ok
    apply IScalar.eq_of_val_eq
    have hs1 := i32_sub_val_of_bounds (Pion.I32.add b 32#i32) 87#i32 (by omega) (by omega)
    have hs2 := i32_sub_val_of_bounds b 55#i32 (by omega) (by omega)
    omega

end CelProofs
