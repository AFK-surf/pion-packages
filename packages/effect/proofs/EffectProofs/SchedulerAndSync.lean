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

/-- 13. Binary heap `heap_parent` strictly decreases positive indices while staying non-negative. -/
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

/-- 14. `heap_parent (heap_left i) = i` for all valid heap indices `0 ≤ i < 2^30`. -/
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

/-- 15. `heap_parent (heap_left i + 1) = i` (right child parent inverse). -/
theorem heap_right_parent_inv (i : Std.I32) (hlo : 0 ≤ i.val) (hhi : i.val < 2 ^ 30 - 1) :
    ∃ l : Std.I32,
      heap_left i = ok l ∧ heap_parent (Pion.I32.add l 1#i32) = ok i := by
  unfold heap_left heap_parent
  have h1 : (1#i32).val = 1 := by decide
  have h2 : (2#i32).val = 2 := by decide
  have hm : (Pion.I32.mul 2#i32 i).val = 2 * i.val := by
    rw [i32_mul_val 2#i32 i (by rw [h2]; omega) (by rw [h2]; omega), h2]
  have ha : (Pion.I32.add (Pion.I32.mul 2#i32 i) 1#i32).val = 2 * i.val + 1 := by
    rw [i32_add_val _ 1#i32 (by omega) (by omega), hm, h1]
  set l := Pion.I32.add (Pion.I32.mul 2#i32 i) 1#i32
  have hr : (Pion.I32.add l 1#i32).val = 2 * i.val + 2 := by
    rw [i32_add_val l 1#i32 (by omega) (by omega), ha, h1]; omega
  have hs : (Pion.I32.sub (Pion.I32.add l 1#i32) 1#i32).val = 2 * i.val + 1 := by
    rw [i32_sub_val _ 1#i32 (by omega) (by omega), hr, h1]; omega
  obtain ⟨q, hq, hqv⟩ := i32_div_two_nonneg (Pion.I32.sub (Pion.I32.add l 1#i32) 1#i32) (by omega)
  refine ⟨l, rfl, ?_⟩
  rw [hq, result_bind_ok]
  congr 1
  exact i32_eq_of_val (by omega)

/-- 16. Unbounded queues (`cap < 0`) always have room. -/
theorem queue_unbounded_always_has_room (cap len : Std.I32) (h : cap.val < 0) :
    queue_has_room cap len = ok true := by
  unfold queue_has_room
  have h0 : (0#i32).val = 0 := by decide
  simp only [Result.ok.injEq, Bool.or_eq_true, decide_eq_true_eq, IScalar.lt_equiv, h0]
  left; exact h

/-- 17. Bounded queues (`cap ≥ 0`) have room iff `len < cap`. -/
theorem queue_bounded_has_room_iff (cap len : Std.I32) (h : 0 ≤ cap.val) :
    queue_has_room cap len = ok true ↔ len.val < cap.val := by
  unfold queue_has_room
  have h0 : (0#i32).val = 0 := by decide
  simp only [Result.ok.injEq, Bool.or_eq_true, decide_eq_true_eq, IScalar.lt_equiv, h0]
  omega

/-- 18. A shut-down queue never accepts `try_offer`. -/
theorem queue_shutdown_rejects_offer (cap len : Std.I32) :
    queue_can_offer true cap len = ok false := by
  rfl

/-- 19. The 6 scheduler priority tiers form a strict total descending hierarchy. -/
theorem priority_strict_hierarchy :
    ∃ pa pf ps pd pb pi : Std.I32,
      priority_asked = ok pa ∧
      priority_focused = ok pf ∧
      priority_shown = ok ps ∧
      priority_detail = ok pd ∧
      priority_background = ok pb ∧
      priority_idle = ok pi ∧
      pa.val > pf.val ∧ pf.val > ps.val ∧ ps.val > pd.val ∧
      pd.val > pb.val ∧ pb.val > pi.val := by
  refine ⟨30#i32, 20#i32, 10#i32, 5#i32, 0#i32, (-10)#i32,
    rfl, rfl, rfl, rfl, rfl, rfl, ?_⟩
  decide

/-- 20. Focused/asked tasks (`best_p ≥ 20`) are admitted iff `busy < width + urgent_room`. -/
theorem sched_lane_focused_urgent_room
    (best_p busy width urgent_room foreground : Std.I32)
    (above_bg has_bg_running above_idle : Bool)
    (hp : 20 ≤ best_p.val) :
    sched_lane_admits best_p busy width urgent_room foreground above_bg has_bg_running above_idle =
      ok (decide (busy < Pion.I32.add width urgent_room)) := by
  unfold sched_lane_admits
  have h20 : (20#i32).val = 20 := by decide
  have hge : best_p ≥ 20#i32 := by
    simp only [ge_iff_le, IScalar.le_equiv, h20]; exact hp
  simp [hge]

/-- 21. Background tasks (`-10 < best_p ≤ 0`) are strictly serialized: never admitted
    when another background task is already running (`has_bg_running = true`). -/
theorem sched_lane_background_serialized
    (best_p busy width urgent_room foreground : Std.I32)
    (above_bg above_idle : Bool)
    (hlo : -10 < best_p.val) (hhi : best_p.val ≤ 0) :
    sched_lane_admits best_p busy width urgent_room foreground above_bg true above_idle = ok false := by
  unfold sched_lane_admits
  have h20 : (20#i32).val = 20 := by decide
  have h0 : (0#i32).val = 0 := by decide
  have hm10 : ((-10)#i32).val = -10 := by decide
  have h1 : ¬ (best_p ≥ 20#i32) := by
    simp only [ge_iff_le, IScalar.le_equiv, h20]; omega
  have h2 : ¬ (best_p > 0#i32) := by
    simp only [gt_iff_lt, IScalar.lt_equiv, h0]; omega
  have h3 : best_p > (-10)#i32 := by
    simp only [gt_iff_lt, IScalar.lt_equiv, hm10]; omega
  simp [h1, h2, h3]

/-- 22. Idle tasks (`best_p ≤ -10`) always yield whenever any task is busy,
    foreground is active, or higher-priority work exists. -/
theorem sched_lane_idle_yields
    (best_p busy width urgent_room foreground : Std.I32)
    (above_bg has_bg_running above_idle : Bool)
    (hp : best_p.val ≤ -10)
    (hyield : 0 < busy.val ∨ 0 < foreground.val ∨ above_idle = true) :
    sched_lane_admits best_p busy width urgent_room foreground above_bg has_bg_running above_idle =
      ok false := by
  unfold sched_lane_admits
  have h20 : (20#i32).val = 20 := by decide
  have h0 : (0#i32).val = 0 := by decide
  have hm10 : ((-10)#i32).val = -10 := by decide
  have h1 : ¬ (best_p ≥ 20#i32) := by
    simp only [ge_iff_le, IScalar.le_equiv, h20]; omega
  have h2 : ¬ (best_p > 0#i32) := by
    simp only [gt_iff_lt, IScalar.lt_equiv, h0]; omega
  have h3 : ¬ (best_p > (-10)#i32) := by
    simp only [gt_iff_lt, IScalar.lt_equiv, hm10]; omega
  simp only [h1, h2, h3, ↓reduceIte, Result.ok.injEq, Bool.and_eq_false_iff,
    Bool.not_eq_false', decide_eq_false_iff_not, IScalar.le_equiv, h0]
  rcases hyield with hb | hf | ha
  · left; left; omega
  · left; right; omega
  · right; exact ha

/-- 23. Non-idle tasks (`eff_p > -10`) are never preempted by `sched_is_preempted`. -/
theorem sched_non_idle_never_preempted
    (eff_p foreground : Std.I32) (above_bg : Bool) (h : -10 < eff_p.val) :
    sched_is_preempted eff_p foreground above_bg = ok false := by
  unfold sched_is_preempted
  have hm10 : ((-10)#i32).val = -10 := by decide
  have hnot : ¬ (eff_p ≤ (-10)#i32) := by
    simp only [IScalar.le_equiv, hm10]; omega
  simp [hnot]

/-- 24. A fiber inside an `uninterruptible_k` shield (`shield > 0`) is never cut. -/
theorem fiber_shielded_never_cut (interrupted : Bool) (shield : Std.I32) (h : 0 < shield.val) :
    fiber_should_cut interrupted shield = ok false := by
  unfold fiber_should_cut
  have h0 : (0#i32).val = 0 := by decide
  have hne : (shield == 0#i32) = false := by
    cases hb : (shield == 0#i32)
    · rfl
    · rw [i32_beq_iff] at hb; omega
  simp [hne]

end EffectProofs
