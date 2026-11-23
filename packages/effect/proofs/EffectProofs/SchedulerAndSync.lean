import Aeneas
import PionLean
import Effect.Types
import Effect.Funs

open Aeneas Aeneas.Std Result Error Pion
open effect

namespace EffectProofs

private lemma result_bind_ok {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by
  simp

private lemma i32_eq_of_val {x y : Std.I32} (h : x.val = y.val) : x = y := by
  cases x; cases y
  simp [IScalar.val, BitVec.toInt_inj] at h
  congr

private lemma i32_add_val (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val + y.val) (hhi : x.val + y.val < 2 ^ 31) :
    (Pion.I32.add x y).val = x.val + y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_sub_val (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val - y.val) (hhi : x.val - y.val < 2 ^ 31) :
    (Pion.I32.sub x y).val = x.val - y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt - y.bv.toInt at hlo
  change x.bv.toInt - y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv - y.bv).toInt = x.bv.toInt - y.bv.toInt
  rw [BitVec.toInt_sub]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_mul_val (x y : Std.I32)
    (hlo : -(2 ^ 31 : Int) ≤ x.val * y.val) (hhi : x.val * y.val < 2 ^ 31) :
    (Pion.I32.mul x y).val = x.val * y.val := by
  change -(2 ^ 31 : Int) ≤ x.bv.toInt * y.bv.toInt at hlo
  change x.bv.toInt * y.bv.toInt < 2 ^ 31 at hhi
  change (x.bv * y.bv).toInt = x.bv.toInt * y.bv.toInt
  rw [BitVec.toInt_mul]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_div_two_nonneg (x : Std.I32) (hx : 0 ≤ x.val) :
    ∃ q : Std.I32,
      Pion.I32.div x 2#i32 = ok q ∧ q.val = x.val / 2 := by
  have hnz : (2#i32).val ≠ 0 := by decide
  have hno : ¬ (x.val = IScalar.min .I32 ∧ (2#i32).val = -1) := by
    intro h
    have h2 : (2#i32).val = 2 := by decide
    omega
  obtain ⟨q, hq, hqv⟩ := IScalar.div_spec (x := x) (y := 2#i32) hnz hno
  refine ⟨q, ?_, ?_⟩
  · simpa [Pion.I32.div] using hq
  · have h2 : (2#i32).val = 2 := by decide
    rw [h2] at hqv
    rw [hqv, Int.tdiv_eq_ediv_of_nonneg hx]

/-- Binary heap `heap_parent` strictly decreases positive indices while staying non-negative. -/
theorem heap_parent_lt (i : Std.I32) (hi : 0 < i.val) :
    ∃ p : Std.I32,
      heap_parent i = ok p ∧ 0 ≤ p.val ∧ p.val < i.val := by
  unfold heap_parent
  have h1 : (1#i32).val = 1 := by decide
  have hib := i.hBounds
  simp at hib
  have hs : (Pion.I32.sub i 1#i32).val = i.val - 1 := by
    rw [i32_sub_val i 1#i32 (by omega) (by omega), h1]
  obtain ⟨q, hq, hqv⟩ := i32_div_two_nonneg (Pion.I32.sub i 1#i32) (by omega)
  rw [hq, result_bind_ok]
  exact ⟨q, rfl, by omega, by omega⟩

/-- `heap_parent (heap_left i) = i` for all valid heap indices `0 ≤ i < 2^30`. -/
theorem heap_left_parent_inv (i : Std.I32) (hlo : 0 ≤ i.val) (hhi : i.val < 2 ^ 30) :
    ∃ l : Std.I32,
      heap_left i = ok l ∧ heap_parent l = ok i := by
  unfold heap_left heap_parent
  have h1 : (1#i32).val = 1 := by decide
  have h2 : (2#i32).val = 2 := by decide
  have hm : (Pion.I32.mul 2#i32 i).val = 2 * i.val := by
    rw [i32_mul_val 2#i32 i (by rw [h2]; omega) (by rw [h2]; omega), h2]
  have ha : (Pion.I32.add (Pion.I32.mul 2#i32 i) 1#i32).val = 2 * i.val + 1 := by
    rw [i32_add_val _ 1#i32 (by omega) (by omega), hm, h1]
  set l := Pion.I32.add (Pion.I32.mul 2#i32 i) 1#i32
  have hs : (Pion.I32.sub l 1#i32).val = 2 * i.val := by
    rw [i32_sub_val l 1#i32 (by omega) (by omega), ha, h1]; omega
  obtain ⟨q, hq, hqv⟩ := i32_div_two_nonneg (Pion.I32.sub l 1#i32) (by omega)
  refine ⟨l, rfl, ?_⟩
  rw [hq, result_bind_ok]
  congr 1
  exact i32_eq_of_val (by omega)

end EffectProofs
