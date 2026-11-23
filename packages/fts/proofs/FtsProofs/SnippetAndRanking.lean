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

private lemma i64_eq_of_val {x y : Std.I64} (h : x.val = y.val) : x = y := by
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

/-- `snippet_normalize_ws` is idempotent across all `2^32` codepoints. -/
theorem snippet_normalize_ws_idempotent (c : Std.I32) :
    ∃ r : Std.I32,
      snippet_normalize_ws c = ok r ∧ snippet_normalize_ws r = ok r := by
  unfold snippet_normalize_ws
  by_cases h : (((c == 10#i32) || (c == 13#i32)) || (c == 9#i32)) = true
  · refine ⟨32#i32, by simp [h], ?_⟩
    rfl
  · have hf : (((c == 10#i32) || (c == 13#i32)) || (c == 9#i32)) = false := by
      cases hc : (((c == 10#i32) || (c == 13#i32)) || (c == 9#i32))
      · rfl
      · exact absurd hc h
    exact ⟨c, by simp [hf], by simp [hf]⟩

/-- For any positive `max_chars` (guarded in `packages/fts/src/snippet.pion`),
    `snippet_context_before` lies in `[0, min(16, max_chars)]`. -/
theorem snippet_context_before_bounds (max_chars : Std.I32) (hpos : 0 < max_chars.val) :
    ∃ ctx : Std.I32,
      snippet_context_before max_chars = ok ctx ∧
      0 ≤ ctx.val ∧ ctx.val ≤ 16 ∧ ctx.val ≤ max_chars.val := by
  unfold snippet_context_before
  have h32 : (32#i32).val = 32 := by decide
  by_cases hgt : max_chars > 32#i32
  · simp only [hgt, ↓reduceIte]
    have hgtv : 32 < max_chars.val := by
      simpa [gt_iff_lt, IScalar.lt_equiv, h32] using hgt
    have h16 : (16#i32).val = 16 := by decide
    exact ⟨16#i32, rfl, by omega, by omega, by omega⟩
  · simp only [hgt, ↓reduceIte]
    have hle : max_chars.val ≤ 32 := by
      simp only [gt_iff_lt, IScalar.lt_equiv, h32] at hgt; omega
    have hnz : (4#i32).val ≠ 0 := by decide
    have hno : ¬ (max_chars.val = IScalar.min .I32 ∧ (4#i32).val = -1) := by
      intro hc
      have h4 : (4#i32).val = 4 := by decide
      have := hc.2
      omega
    obtain ⟨q, hq, hqv⟩ := IScalar.div_spec (x := max_chars) (y := 4#i32) hnz hno
    have hdiv : Pion.I32.div max_chars 4#i32 = ok q := by simpa [Pion.I32.div] using hq
    rw [hdiv, result_bind_ok]
    have h4 : (4#i32).val = 4 := by decide
    rw [h4, Int.tdiv_eq_ediv_of_nonneg (by omega)] at hqv
    exact ⟨q, rfl, by omega, by omega, by omega⟩

/-- RT-3 overflow safety: for all `0 ≤ win_start ≤ total_cps` and `0 < max_chars`
    (even `max_chars = Int::MAX`), `snippet_win_end` never overflows and satisfies
    `win_start ≤ win_end ≤ total_cps` and `win_end - win_start ≤ max_chars`. -/
theorem snippet_win_end_rt3_safe (win_start total_cps max_chars : Std.I32)
    (hw0 : 0 ≤ win_start.val) (hwt : win_start.val ≤ total_cps.val) (hm : 0 < max_chars.val) :
    ∃ we : Std.I32,
      snippet_win_end win_start total_cps max_chars = ok we ∧
      win_start.val ≤ we.val ∧ we.val ≤ total_cps.val ∧
      we.val - win_start.val ≤ max_chars.val := by
  unfold snippet_win_end
  have htb := total_cps.hBounds
  simp at htb
  have hsub : (Pion.I32.sub total_cps win_start).val = total_cps.val - win_start.val :=
    i32_sub_val total_cps win_start (by omega) (by omega)
  refine ⟨_, rfl, ?_⟩
  by_cases hlt : max_chars < Pion.I32.sub total_cps win_start
  · simp only [hlt, ↓reduceIte]
    have hltv : max_chars.val < total_cps.val - win_start.val := by
      rw [IScalar.lt_equiv, hsub] at hlt
      exact hlt
    have hadd : (Pion.I32.add win_start max_chars).val = win_start.val + max_chars.val :=
      i32_add_val win_start max_chars (by omega) (by omega)
    omega
  · simp only [hlt, ↓reduceIte]
    have hge : total_cps.val - win_start.val ≤ max_chars.val := by
      rw [IScalar.lt_equiv, hsub] at hlt
      omega
    omega

/-- `snippet_range_gt` is irreflexive. -/
theorem snippet_range_gt_irrefl (a0 a1 : Std.I32) :
    snippet_range_gt a0 a1 a0 a1 = ok false := by
  unfold snippet_range_gt
  simp

/-- `snippet_range_gt` is transitive. -/
theorem snippet_range_gt_trans (a0 a1 b0 b1 c0 c1 : Std.I32) :
    snippet_range_gt a0 a1 b0 b1 = ok true →
    snippet_range_gt b0 b1 c0 c1 = ok true →
    snippet_range_gt a0 a1 c0 c1 = ok true := by
  unfold snippet_range_gt
  simp only [Result.ok.injEq, Bool.or_eq_true, Bool.and_eq_true,
    decide_eq_true_eq, gt_iff_lt, IScalar.lt_equiv, i32_beq_iff]
  intro h1 h2
  omega

/-- `hit_tiebreak_cmp` is antisymmetric (`cmp a b = -cmp b a`). -/
theorem hit_tiebreak_cmp_antisymm (ok1 id1 ok2 id2 : Std.I64) :
    ∃ r1 r2 : Std.I32,
      hit_tiebreak_cmp ok1 id1 ok2 id2 = ok r1 ∧
      hit_tiebreak_cmp ok2 id2 ok1 id1 = ok r2 ∧
      r1.val = -r2.val := by
  unfold hit_tiebreak_cmp
  refine ⟨_, _, rfl, rfl, ?_⟩
  have hm1 : ((-1)#i32).val = -1 := by decide
  have hp1 : (1#i32).val = 1 := by decide
  have h0 : (0#i32).val = 0 := by decide
  split_ifs <;> simp only [gt_iff_lt, IScalar.lt_equiv] at * <;> omega

/-- `hit_tiebreak_cmp` returns `0` iff both `order_key` and `doc_id` are equal. -/
theorem hit_tiebreak_cmp_zero_iff (ok1 id1 ok2 id2 : Std.I64) :
    hit_tiebreak_cmp ok1 id1 ok2 id2 = ok 0#i32 ↔ ok1 = ok2 ∧ id1 = id2 := by
  constructor
  · unfold hit_tiebreak_cmp
    simp only [Result.ok.injEq]
    split_ifs with h1 h2 h3 h4
    · intro heq; exact absurd heq (by decide)
    · intro heq; exact absurd heq (by decide)
    · intro heq; exact absurd heq (by decide)
    · intro heq; exact absurd heq (by decide)
    · intro _
      simp only [gt_iff_lt, IScalar.lt_equiv] at h1 h2 h3 h4
      exact ⟨i64_eq_of_val (by omega), i64_eq_of_val (by omega)⟩
  · rintro ⟨rfl, rfl⟩
    unfold hit_tiebreak_cmp
    simp

end FtsProofs
