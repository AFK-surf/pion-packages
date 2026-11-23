import Aeneas
import PionLean
import Svg.Types
import Svg.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion svg

namespace SvgProofs

private lemma i32_le_iff' (x y : Std.I32) : (x <= y) ↔ (x.val <= y.val) := Iff.rfl
private lemma i32_beq_iff' (x y : Std.I32) : ((x == y) = true) ↔ (x.val = y.val) := by
  cases x; cases y; simp [BEq.beq, IScalar.val, BitVec.toInt_inj]

private lemma i32_add_val' (x y : Std.I32)
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

private lemma i32_sub_val' (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val - y.val) (hhi : x.val - y.val ≤ 2147483647) :
    (Pion.I32.sub x y).val = x.val - y.val := by
  unfold Pion.I32.sub
  have hv : (x.bv - y.bv).toInt = x.val - y.val := by
    rw [BitVec.toInt_sub]
    have hx : x.bv.toInt = x.val := rfl
    have hy : y.bv.toInt = y.val := rfl
    rw [hx, hy]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  exact hv

/-- Theorem 13: XML 1.0 §2.3 `is_xml_ws` exact characterization (`SP`, `TAB`, `LF`, `CR`). -/
theorem is_xml_ws_exact (c : Std.I32) :
    is_xml_ws c = ok true ↔ (c.val = 32 ∨ c.val = 9 ∨ c.val = 10 ∨ c.val = 13) := by
  unfold is_xml_ws
  simp only [ok.injEq, Bool.or_eq_true, i32_beq_iff']
  change ((c.val = 32 ∨ c.val = 9) ∨ c.val = 10) ∨ c.val = 13 ↔ _
  omega

/-- Theorem 14: W3C SVG 2 `is_svg_ws` exact characterization (`SP`, `TAB`, `LF`, `CR`, `FF`). -/
theorem is_svg_ws_exact (c : Std.I32) :
    is_svg_ws c = ok true ↔ (c.val = 32 ∨ c.val = 9 ∨ c.val = 10 ∨ c.val = 13 ∨ c.val = 12) := by
  unfold is_svg_ws
  simp only [ok.injEq, Bool.or_eq_true, i32_beq_iff']
  change (((c.val = 32 ∨ c.val = 9) ∨ c.val = 10) ∨ c.val = 13) ∨ c.val = 12 ↔ _
  omega

/-- Theorem 15: `is_xml_ws` is a strict subset of `is_svg_ws`, with form feed (`0x0C`) witnessing the difference. -/
theorem is_xml_ws_strict_subset_svg_ws (c : Std.I32) :
    (is_xml_ws c = ok true → is_svg_ws c = ok true) ∧
    (is_svg_ws 12#i32 = ok true ∧ is_xml_ws 12#i32 = ok false) := by
  refine ⟨fun h => ?_, by unfold is_svg_ws; rfl, by unfold is_xml_ws; rfl⟩
  have hx := (is_xml_ws_exact c).mp h
  exact (is_svg_ws_exact c).mpr (by omega)

/-- Theorem 16: `is_ascii_digit` exact range (`'0'..'9'`). -/
theorem is_ascii_digit_exact (c : Std.I32) :
    is_ascii_digit c = ok true ↔ (48 ≤ c.val ∧ c.val ≤ 57) := by
  unfold is_ascii_digit
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
  change (48 ≤ c.val ∧ c.val ≤ 57) ↔ _
  exact Iff.rfl

/-- Theorem 17: Every ASCII digit is a valid SVG number start character. -/
theorem is_ascii_digit_subset_number_start (c : Std.I32) (hd : is_ascii_digit c = ok true) :
    is_number_start c = ok true := by
  have ⟨h0, h9⟩ := (is_ascii_digit_exact c).mp hd
  unfold is_number_start
  apply congrArg ok
  simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff', i32_beq_iff']
  change (((48 ≤ c.val ∧ c.val ≤ 57) ∨ c.val = 45) ∨ c.val = 43) ∨ c.val = 46
  omega

/-- Theorem 18: `is_number_start` is strictly disjoint from both `is_svg_ws` and `is_ident_char`. -/
theorem is_number_start_disjoint_ws_and_ident (c : Std.I32) (hn : is_number_start c = ok true) :
    is_svg_ws c = ok false ∧ is_ident_char c = ok false := by
  unfold is_number_start at hn
  simp only [ok.injEq, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff', i32_beq_iff'] at hn
  change (((48 ≤ c.val ∧ c.val ≤ 57) ∨ c.val = 45) ∨ c.val = 43) ∨ c.val = 46 at hn
  constructor
  · unfold is_svg_ws; apply congrArg ok; rw [Bool.eq_false_iff]; intro h
    simp only [Bool.or_eq_true, i32_beq_iff'] at h
    change (((c.val = 32 ∨ c.val = 9) ∨ c.val = 10) ∨ c.val = 13) ∨ c.val = 12 at h; omega
  · unfold is_ident_char; apply congrArg ok; rw [Bool.eq_false_iff]; intro h
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h
    change (65 ≤ c.val ∧ c.val ≤ 90) ∨ (97 ≤ c.val ∧ c.val ≤ 122) at h; omega

/-- Theorem 19: `is_ident_char` exact characterization (`'A'..'Z'` or `'a'..'z'`). -/
theorem is_ident_char_exact (c : Std.I32) :
    is_ident_char c = ok true ↔ ((65 ≤ c.val ∧ c.val ≤ 90) ∨ (97 ≤ c.val ∧ c.val ≤ 122)) := by
  unfold is_ident_char
  simp only [ok.injEq, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
  change ((65 ≤ c.val ∧ c.val ≤ 90) ∨ (97 ≤ c.val ∧ c.val ≤ 122)) ↔ _
  exact Iff.rfl

/-- Theorem 20: MoveTo (`M`/`m`) and ClosePath (`Z`/`z`) are disjoint subsets of `is_ident_char`. -/
theorem is_path_moveto_and_closepath_disjoint (c : Std.I32) :
    (is_path_moveto c = ok true → is_ident_char c = ok true ∧ is_path_closepath c = ok false) ∧
    (is_path_closepath c = ok true → is_ident_char c = ok true) := by
  constructor
  · intro hm
    unfold is_path_moveto at hm
    simp only [ok.injEq, Bool.or_eq_true, i32_beq_iff'] at hm
    change c.val = 77 ∨ c.val = 109 at hm
    refine ⟨(is_ident_char_exact c).mpr (by omega), ?_⟩
    unfold is_path_closepath; apply congrArg ok; rw [Bool.eq_false_iff]; intro hz
    simp only [Bool.or_eq_true, i32_beq_iff'] at hz; change c.val = 90 ∨ c.val = 122 at hz; omega
  · intro hz
    unfold is_path_closepath at hz
    simp only [ok.injEq, Bool.or_eq_true, i32_beq_iff'] at hz
    change c.val = 90 ∨ c.val = 122 at hz
    exact (is_ident_char_exact c).mpr (by omega)

/-- Theorem 21: `hex_val` always returns a value in `[-1, 15]`, returning `≥ 0` iff `c` is an ASCII hex digit. -/
theorem hex_val_bounds (c : Std.I32) :
    ∃ r : Std.I32, hex_val c = ok r ∧
      -1 ≤ r.val ∧ r.val ≤ 15 ∧
      (0 ≤ r.val ↔ ((48 ≤ c.val ∧ c.val ≤ 57) ∨ (65 ≤ c.val ∧ c.val ≤ 70) ∨ (97 ≤ c.val ∧ c.val ≤ 102))) := by
  unfold hex_val
  by_cases hd : ((decide (c >= 48#i32)) && (decide (c <= 57#i32))) = true
  · simp only [hd, ↓reduceIte]
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at hd
    change 48 ≤ c.val ∧ c.val ≤ 57 at hd
    have hs := i32_sub_val' c 48#i32 (by change -2147483648 ≤ c.val - 48; omega) (by change c.val - 48 ≤ 2147483647; omega)
    change (Pion.I32.sub c 48#i32).val = c.val - 48 at hs
    exact ⟨Pion.I32.sub c 48#i32, rfl, by omega, by omega, ⟨fun _ => by omega, fun _ => by omega⟩⟩
  · have hdf := Bool.eq_false_iff.mpr hd
    simp only [hdf, Bool.false_eq_true, ↓reduceIte]
    have hdn : ¬ (48 ≤ c.val ∧ c.val ≤ 57) := fun h => hd (by
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']; change 48 ≤ c.val ∧ c.val ≤ 57; exact h)
    by_cases hu : ((decide (c >= 65#i32)) && (decide (c <= 70#i32))) = true
    · simp only [hu, ↓reduceIte]
      simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at hu
      change 65 ≤ c.val ∧ c.val ≤ 70 at hu
      set t := Pion.I32.sub c 65#i32
      have ht : t.val = c.val - 65 := i32_sub_val' c 65#i32 (by change -2147483648 ≤ c.val - 65; omega) (by change c.val - 65 ≤ 2147483647; omega)
      have ha := i32_add_val' t 10#i32 (by change -2147483648 ≤ t.val + 10; omega) (by change t.val + 10 ≤ 2147483647; omega)
      change (Pion.I32.add t 10#i32).val = t.val + 10 at ha
      exact ⟨Pion.I32.add t 10#i32, rfl, by omega, by omega, ⟨fun _ => by omega, fun _ => by omega⟩⟩
    · have huf := Bool.eq_false_iff.mpr hu
      simp only [huf, Bool.false_eq_true, ↓reduceIte]
      have hun : ¬ (65 ≤ c.val ∧ c.val ≤ 70) := fun h => hu (by
        simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']; change 65 ≤ c.val ∧ c.val ≤ 70; exact h)
      by_cases hl : ((decide (c >= 97#i32)) && (decide (c <= 102#i32))) = true
      · simp only [hl, ↓reduceIte]
        simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at hl
        change 97 ≤ c.val ∧ c.val ≤ 102 at hl
        set t := Pion.I32.sub c 97#i32
        have ht : t.val = c.val - 97 := i32_sub_val' c 97#i32 (by change -2147483648 ≤ c.val - 97; omega) (by change c.val - 97 ≤ 2147483647; omega)
        have ha := i32_add_val' t 10#i32 (by change -2147483648 ≤ t.val + 10; omega) (by change t.val + 10 ≤ 2147483647; omega)
        change (Pion.I32.add t 10#i32).val = t.val + 10 at ha
        exact ⟨Pion.I32.add t 10#i32, rfl, by omega, by omega, ⟨fun _ => by omega, fun _ => by omega⟩⟩
      · have hlf := Bool.eq_false_iff.mpr hl
        simp only [hlf, Bool.false_eq_true, ↓reduceIte]
        have hln : ¬ (97 ≤ c.val ∧ c.val ≤ 102) := fun h => hl (by
          simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']; change 97 ≤ c.val ∧ c.val ≤ 102; exact h)
        exact ⟨(-1)#i32, rfl, by decide, by decide, ⟨fun h => by change 0 ≤ (-1 : Int) at h; omega, fun h => by omega⟩⟩

/-- Theorem 22: On ASCII digits `'0'..'9'`, `hex_val c` equals `c - 48`. -/
theorem hex_val_digit_exact (c : Std.I32) (h0 : 48 ≤ c.val) (h9 : c.val ≤ 57) :
    ∃ r : Std.I32, hex_val c = ok r ∧ r.val = c.val - 48 := by
  unfold hex_val
  have hd : ((decide (c >= 48#i32)) && (decide (c <= 57#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
    change 48 ≤ c.val ∧ c.val ≤ 57; omega
  simp only [hd, ↓reduceIte]
  have hs := i32_sub_val' c 48#i32 (by change -2147483648 ≤ c.val - 48; omega) (by change c.val - 48 ≤ 2147483647; omega)
  change (Pion.I32.sub c 48#i32).val = c.val - 48 at hs
  exact ⟨Pion.I32.sub c 48#i32, rfl, hs⟩

/-- Theorem 23: `hex_val` is case-insensitive on `'A'..'F'` vs `'a'..'f'`. -/
theorem hex_val_case_insensitive (c : Std.I32) (hlo : 65 ≤ c.val) (hhi : c.val ≤ 70) :
    hex_val (Pion.I32.add c 32#i32) = hex_val c := by
  set cl := Pion.I32.add c 32#i32
  have hcl : cl.val = c.val + 32 :=
    i32_add_val' c 32#i32 (by change -2147483648 ≤ c.val + 32; omega) (by change c.val + 32 ≤ 2147483647; omega)
  unfold hex_val
  have d1 : ((decide (cl >= 48#i32)) && (decide (cl <= 57#i32))) = false := by
    rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 48 ≤ cl.val ∧ cl.val ≤ 57 at h; omega
  have u1 : ((decide (cl >= 65#i32)) && (decide (cl <= 70#i32))) = false := by
    rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 65 ≤ cl.val ∧ cl.val ≤ 70 at h; omega
  have l1 : ((decide (cl >= 97#i32)) && (decide (cl <= 102#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']; change 97 ≤ cl.val ∧ cl.val ≤ 102; omega
  have d2 : ((decide (c >= 48#i32)) && (decide (c <= 57#i32))) = false := by
    rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 48 ≤ c.val ∧ c.val ≤ 57 at h; omega
  have u2 : ((decide (c >= 65#i32)) && (decide (c <= 70#i32))) = true := by
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']; change 65 ≤ c.val ∧ c.val ≤ 70; omega
  simp only [d1, u1, l1, d2, u2, Bool.false_eq_true, ↓reduceIte]
  apply congrArg ok; apply IScalar.eq_of_val_eq
  set s1 := Pion.I32.sub cl 97#i32
  set s2 := Pion.I32.sub c 65#i32
  have hs1 : s1.val = cl.val - 97 := i32_sub_val' cl 97#i32 (by change -2147483648 ≤ cl.val - 97; omega) (by change cl.val - 97 ≤ 2147483647; omega)
  have hs2 : s2.val = c.val - 65 := i32_sub_val' c 65#i32 (by change -2147483648 ≤ c.val - 65; omega) (by change c.val - 65 ≤ 2147483647; omega)
  have ha1 := i32_add_val' s1 10#i32 (by change -2147483648 ≤ s1.val + 10; omega) (by change s1.val + 10 ≤ 2147483647; omega)
  have ha2 := i32_add_val' s2 10#i32 (by change -2147483648 ≤ s2.val + 10; omega) (by change s2.val + 10 ≤ 2147483647; omega)
  change (Pion.I32.add s1 10#i32).val = s1.val + 10 at ha1
  change (Pion.I32.add s2 10#i32).val = s2.val + 10 at ha2
  omega

/-- Theorem 24: SVG whitespace bytes are rejected by `hex_val` (returns `-1`) and `is_ident_char` (returns `false`). -/
theorem is_svg_ws_disjoint_hex_and_ident (c : Std.I32) (hw : is_svg_ws c = ok true) :
    hex_val c = ok (-1)#i32 ∧ is_ident_char c = ok false := by
  have hwe := (is_svg_ws_exact c).mp hw
  constructor
  · unfold hex_val
    have d : ((decide (c >= 48#i32)) && (decide (c <= 57#i32))) = false := by
      rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 48 ≤ c.val ∧ c.val ≤ 57 at h; omega
    have u : ((decide (c >= 65#i32)) && (decide (c <= 70#i32))) = false := by
      rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 65 ≤ c.val ∧ c.val ≤ 70 at h; omega
    have l : ((decide (c >= 97#i32)) && (decide (c <= 102#i32))) = false := by
      rw [Bool.eq_false_iff]; intro h; simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h; change 97 ≤ c.val ∧ c.val ≤ 102 at h; omega
    simp only [d, u, l, Bool.false_eq_true, ↓reduceIte]
  · unfold is_ident_char; apply congrArg ok; rw [Bool.eq_false_iff]; intro h
    simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff'] at h
    change (65 ≤ c.val ∧ c.val ≤ 90) ∨ (97 ≤ c.val ∧ c.val ≤ 122) at h; omega

end SvgProofs
