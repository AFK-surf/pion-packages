import Aeneas
import PionLean
import Ical.Types
import Ical.Funs

open Aeneas Aeneas.Std Result Pion ical

namespace IcalProofs

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

private lemma i64_add_val_of_bounds (a b : I64)
    (hlo : -9223372036854775808 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 9223372036854775807) :
    (Pion.I64.add a b).val = a.val + b.val := by
  have hwrap : (Pion.I64.add a b).val = Int.bmod (a.val + b.val) (2 ^ 64) := by
    change (I64.wrapping_add a b).val = Int.bmod (a.val + b.val) (2 ^ 64)
    simp only [I64.wrapping_add, IScalar.wrapping_add, IScalar.val, BitVec.toInt_add]
    rfl
  rw [hwrap]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i64_sub_val_of_bounds (a b : I64)
    (hlo : -9223372036854775808 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 9223372036854775807) :
    (Pion.I64.sub a b).val = a.val - b.val := by
  have hwrap : (Pion.I64.sub a b).val = Int.bmod (a.val - b.val) (2 ^ 64) := by
    change (I64.wrapping_sub a b).val = Int.bmod (a.val - b.val) (2 ^ 64)
    simp only [I64.wrapping_sub, IScalar.wrapping_sub, IScalar.val, BitVec.toInt_sub]
    rfl
  rw [hwrap]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i64_mul_val_of_bounds (a b : I64)
    (hlo : -9223372036854775808 ≤ a.val * b.val) (hhi : a.val * b.val ≤ 9223372036854775807) :
    (Pion.I64.mul a b).val = a.val * b.val := by
  have hwrap : (Pion.I64.mul a b).val = Int.bmod (a.val * b.val) (2 ^ 64) := by
    change (I64.wrapping_mul a b).val = Int.bmod (a.val * b.val) (2 ^ 64)
    simp only [I64.wrapping_mul, IScalar.wrapping_mul, IScalar.val, BitVec.toInt_mul]
    rfl
  rw [hwrap]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i64_to_int_val_of_bounds (x : I64)
    (hlo : -2147483648 ≤ x.val) (hhi : x.val ≤ 2147483647) :
    (Pion.I64.to_int x).val = x.val := by
  have hbv : (Pion.I64.to_int x).bv = BitVec.signExtend 32 x.bv := rfl
  have hx : x.bv.toInt = x.val := rfl
  change (Pion.I64.to_int x).bv.toInt = x.val
  rw [hbv, BitVec.toInt_signExtend]
  have hmin : min 32 64 = 32 := rfl
  rw [hmin]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_rem_pos_ok (x d : I32) (hd : 0 < d.val) :
    ∃ r, Pion.I32.rem x d = ok r ∧ r.val = Int.tmod x.val d.val := by
  have hspec := Pion.I32.rem_spec (x := x) (y := d) (by omega) (by omega)
  have hok : Pion.I32.rem x d = ok (⟨BitVec.srem x.bv d.bv⟩ : I32) := by
    unfold Pion.I32.rem
    have h1 : ¬(x.val = -2147483648 ∧ d.val = -1) := by omega
    simp only [h1, ↓reduceIte]
    change IScalar.rem x d = _
    unfold IScalar.rem
    have h2 : (d.val != 0) = true := bne_iff_ne.mpr (by omega)
    simp only [h2, ↓reduceIte]
  rw [hok] at hspec
  simp only [WP.spec_ok] at hspec
  exact ⟨⟨BitVec.srem x.bv d.bv⟩, hok, hspec⟩

private lemma i64_div_pos_ok (x d : I64) (hd : 0 < d.val) :
    ∃ q, Pion.I64.div x d = ok q ∧ q.val = Int.tdiv x.val d.val := by
  have hspec := Pion.I64.div_spec (x := x) (y := d) (by omega) (by omega)
  have hok : Pion.I64.div x d = ok (⟨BitVec.sdiv x.bv d.bv⟩ : I64) := by
    change IScalar.div x d = _
    unfold IScalar.div
    have h2 : (d.val != 0) = true := bne_iff_ne.mpr (by omega)
    have h3 : ¬(x.val = IScalar.min .I64 && d.val = -1) := by
      simp [show d.val ≠ -1 by omega]
    simp only [h2, h3, Bool.false_eq_true, not_false_eq_true, ↓reduceIte]
  rw [hok] at hspec
  simp only [WP.spec_ok] at hspec
  exact ⟨⟨BitVec.sdiv x.bv d.bv⟩, hok, hspec⟩

private lemma int_tmod_cases (a d : Int) :
    (0 ≤ a → Int.tmod a d = a % d) ∧
    (a < 0 → Int.tmod a d = -((-a) % d)) := by
  constructor
  · intro ha
    exact Int.tmod_eq_emod_of_nonneg ha
  · intro ha
    have hneg : Int.tmod a d = -Int.tmod (-a) d := by
      have := Int.neg_tmod (-a) d
      rw [Int.neg_neg] at this
      omega
    rw [hneg, Int.tmod_eq_emod_of_nonneg (by omega)]

private lemma int_tdiv_neg_pos (a d : Int) (ha : a < 0) :
    Int.tdiv a d = -((-a) / d) := by
  have hneg : Int.tdiv a d = -Int.tdiv (-a) d := by
    have := Int.neg_tdiv (-a) d
    rw [Int.neg_neg] at this
    omega
  rw [hneg, Int.tdiv_eq_ediv_of_nonneg (by omega)]

/-- Theorem 1: `epoch_day_weekday_mon0 ed` computes `(ed + 3) mod 7 ∈ [0, 6]` for all civil epoch days. -/
theorem epoch_day_weekday_mon0_bounds (ed : I32)
    (hlo : -2000000000 ≤ ed.val) (hhi : ed.val ≤ 2000000000) :
    ∃ w, epoch_day_weekday_mon0 ed = ok w ∧ 0 ≤ w.val ∧ w.val ≤ 6 ∧ w.val = (ed.val + 3) % 7 := by
  unfold epoch_day_weekday_mon0
  have c3 : (3#i32 : I32).val = 3 := rfl
  have c7 : (7#i32 : I32).val = 7 := rfl
  have hadd := i32_add_val_of_bounds ed 3#i32 (by omega) (by omega)
  rcases i32_rem_pos_ok (Pion.I32.add ed 3#i32) 7#i32 (by omega) with ⟨r, hrem, hrval⟩
  rw [hrem, result_bind_ok]
  rw [hadd, c3, c7] at hrval
  have htc := int_tmod_cases (ed.val + 3) 7
  have hrmod : (0 ≤ ed.val + 3 → r.val = (ed.val + 3) % 7) ∧
      (ed.val + 3 < 0 → r.val = -((-(ed.val + 3)) % 7)) := by
    exact ⟨fun h => by rw [hrval, htc.1 h], fun h => by rw [hrval, htc.2 h]⟩
  by_cases hlt : r < 0#i32
  · simp only [hlt, ↓reduceIte]
    have hrneg : r.val < 0 := hlt
    have hr7 := i32_add_val_of_bounds r 7#i32 (by omega) (by omega)
    refine ⟨Pion.I32.add r 7#i32, rfl, ?_, ?_, ?_⟩ <;> omega
  · simp only [hlt, ↓reduceIte]
    have hrpos : 0 ≤ r.val := by change ¬(r.val < 0) at hlt; omega
    refine ⟨r, rfl, ?_, ?_, ?_⟩ <;> omega

/-- Theorem 4: Advancing an epoch day by 1 advances `epoch_day_weekday_mon0` by `+1 (mod 7)`. -/
theorem epoch_day_weekday_mon0_succ (ed : I32)
    (hlo : -1000000000 ≤ ed.val) (hhi : ed.val ≤ 1000000000) :
    ∃ w1 w2, epoch_day_weekday_mon0 ed = ok w1 ∧
      epoch_day_weekday_mon0 (Pion.I32.add ed 1#i32) = ok w2 ∧
      w2.val = (w1.val + 1) % 7 := by
  have c1 : (1#i32 : I32).val = 1 := rfl
  have hadd := i32_add_val_of_bounds ed 1#i32 (by omega) (by omega)
  rcases epoch_day_weekday_mon0_bounds ed (by omega) (by omega) with ⟨w1, hw1, _, _, hv1⟩
  rcases epoch_day_weekday_mon0_bounds (Pion.I32.add ed 1#i32) (by omega) (by omega) with ⟨w2, hw2, _, _, hv2⟩
  exact ⟨w1, w2, hw1, hw2, by omega⟩

/-- Theorem 6: `neg_ordinal_day day total` maps `day ∈ [1, total]` bijectively to `[-total, -1]` with `day - neg = total + 1`. -/
theorem neg_ordinal_day_bounds (day total : I32)
    (h1 : 1 ≤ day.val) (h2 : day.val ≤ total.val) (h3 : total.val ≤ 366) :
    ∃ neg, neg_ordinal_day day total = ok neg ∧
      -total.val ≤ neg.val ∧ neg.val ≤ -1 ∧ day.val - neg.val = total.val + 1 := by
  unfold neg_ordinal_day
  have c1 : (1#i32 : I32).val = 1 := rfl
  have hs1 := i32_sub_val_of_bounds day total (by omega) (by omega)
  have hs2 := i32_sub_val_of_bounds (Pion.I32.sub day total) 1#i32 (by omega) (by omega)
  exact ⟨_, rfl, by omega, by omega, by omega⟩

/-- Theorem 7: `floor_div_86400 sec` computes exact Euclidean floor division `sec / 86400` for signed timestamps. -/
theorem floor_div_86400_exact (sec : I64)
    (hlo : -100000000000000 ≤ sec.val) (hhi : sec.val ≤ 100000000000000) :
    ∃ d, floor_div_86400 sec = ok d ∧ d.val = sec.val / 86400 := by
  unfold floor_div_86400
  have c86400 : (86400#i64 : I64).val = 86400 := rfl
  have c86399 : (86399#i64 : I64).val = 86399 := rfl
  by_cases hge : sec >= 0#i64
  · simp only [hge, ↓reduceIte]
    have hpos : 0 ≤ sec.val := hge
    rcases i64_div_pos_ok sec 86400#i64 (by omega) with ⟨q, hdiv, hqval⟩
    rw [hdiv, result_bind_ok]
    rw [c86400, Int.tdiv_eq_ediv_of_nonneg hpos] at hqval
    have hto := i64_to_int_val_of_bounds q (by omega) (by omega)
    exact ⟨Pion.I64.to_int q, rfl, by omega⟩
  · simp only [hge, ↓reduceIte]
    have hneg : sec.val < 0 := by change ¬(0 ≤ sec.val) at hge; omega
    have hsub := i64_sub_val_of_bounds sec 86399#i64 (by omega) (by omega)
    rcases i64_div_pos_ok (Pion.I64.sub sec 86399#i64) 86400#i64 (by omega) with ⟨q, hdiv, hqval⟩
    rw [hdiv, result_bind_ok]
    rw [hsub, c86399, c86400, int_tdiv_neg_pos _ 86400 (by omega)] at hqval
    have hto := i64_to_int_val_of_bounds q (by omega) (by omega)
    exact ⟨Pion.I64.to_int q, rfl, by omega⟩

/-- Theorem 9: RFC 5545 §3.3.10 `week1_start_of jan1 wkst` lies in `[jan1 - 3, jan1 + 3]` and contains at least 4 days in the year. -/
theorem week1_start_of_range_and_4days (jan1 wkst : I32)
    (hlo : -1000000000 ≤ jan1.val) (hhi : jan1.val ≤ 1000000000)
    (hw0 : 0 ≤ wkst.val) (hw6 : wkst.val ≤ 6) :
    ∃ w1, week1_start_of jan1 wkst = ok w1 ∧
      jan1.val - 3 ≤ w1.val ∧ w1.val ≤ jan1.val + 3 ∧ jan1.val + 3 ≤ w1.val + 6 := by
  unfold week1_start_of
  have c7 : (7#i32 : I32).val = 7 := rfl
  rcases epoch_day_weekday_mon0_bounds jan1 (by omega) (by omega) with ⟨wd, hwd, hwd0, hwd6, _⟩
  rw [hwd, result_bind_ok]
  have hs1 := i32_sub_val_of_bounds wd wkst (by omega) (by omega)
  have ha1 := i32_add_val_of_bounds (Pion.I32.sub wd wkst) 7#i32 (by omega) (by omega)
  rcases i32_rem_pos_ok (Pion.I32.add (Pion.I32.sub wd wkst) 7#i32) 7#i32 (by omega) with ⟨off, hoff, hoffv⟩
  rw [hoff, result_bind_ok]
  rw [ha1, hs1, c7, Int.tmod_eq_emod_of_nonneg (by omega)] at hoffv
  have hsub7 := i32_sub_val_of_bounds 7#i32 off (by omega) (by omega)
  by_cases hge4 : Pion.I32.sub 7#i32 off >= 4#i32
  · simp only [hge4, ↓reduceIte]
    have h4 : 4 ≤ (Pion.I32.sub 7#i32 off).val := hge4
    have hres := i32_sub_val_of_bounds jan1 off (by omega) (by omega)
    exact ⟨Pion.I32.sub jan1 off, rfl, by omega, by omega, by omega⟩
  · simp only [hge4, ↓reduceIte]
    have hlt4 : (Pion.I32.sub 7#i32 off).val < 4 := by change ¬(4 ≤ (Pion.I32.sub 7#i32 off).val) at hge4; omega
    have hres := i32_add_val_of_bounds jan1 (Pion.I32.sub 7#i32 off) (by omega) (by omega)
    exact ⟨Pion.I32.add jan1 (Pion.I32.sub 7#i32 off), rfl, by omega, by omega, by omega⟩

/-- Theorem 10: The epoch day returned by `week1_start_of jan1 wkst` always has weekday equal to `wkst`. -/
theorem week1_start_of_weekday_eq_wkst (jan1 wkst : I32)
    (hlo : -1000000000 ≤ jan1.val) (hhi : jan1.val ≤ 1000000000)
    (hw0 : 0 ≤ wkst.val) (hw6 : wkst.val ≤ 6) :
    ∃ w1, week1_start_of jan1 wkst = ok w1 ∧ epoch_day_weekday_mon0 w1 = ok wkst := by
  unfold week1_start_of
  have c7 : (7#i32 : I32).val = 7 := rfl
  rcases epoch_day_weekday_mon0_bounds jan1 (by omega) (by omega) with ⟨wd, hwd, hwd0, hwd6, hwdv⟩
  rw [hwd, result_bind_ok]
  have hs1 := i32_sub_val_of_bounds wd wkst (by omega) (by omega)
  have ha1 := i32_add_val_of_bounds (Pion.I32.sub wd wkst) 7#i32 (by omega) (by omega)
  rcases i32_rem_pos_ok (Pion.I32.add (Pion.I32.sub wd wkst) 7#i32) 7#i32 (by omega) with ⟨off, hoff, hoffv⟩
  rw [hoff, result_bind_ok]
  rw [ha1, hs1, c7, Int.tmod_eq_emod_of_nonneg (by omega)] at hoffv
  have hsub7 := i32_sub_val_of_bounds 7#i32 off (by omega) (by omega)
  by_cases hge4 : Pion.I32.sub 7#i32 off >= 4#i32
  · simp only [hge4, ↓reduceIte]
    have h4 : 4 ≤ (Pion.I32.sub 7#i32 off).val := hge4
    have hres := i32_sub_val_of_bounds jan1 off (by omega) (by omega)
    rcases epoch_day_weekday_mon0_bounds (Pion.I32.sub jan1 off) (by omega) (by omega) with ⟨w, hw, _, _, hwv⟩
    refine ⟨Pion.I32.sub jan1 off, rfl, ?_⟩
    rw [hw]
    apply congrArg ok
    apply IScalar.eq_of_val_eq
    omega
  · simp only [hge4, ↓reduceIte]
    have hlt4 : (Pion.I32.sub 7#i32 off).val < 4 := by change ¬(4 ≤ (Pion.I32.sub 7#i32 off).val) at hge4; omega
    have hres := i32_add_val_of_bounds jan1 (Pion.I32.sub 7#i32 off) (by omega) (by omega)
    rcases epoch_day_weekday_mon0_bounds (Pion.I32.add jan1 (Pion.I32.sub 7#i32 off)) (by omega) (by omega) with ⟨w, hw, _, _, hwv⟩
    refine ⟨Pion.I32.add jan1 (Pion.I32.sub 7#i32 off), rfl, ?_⟩
    rw [hw]
    apply congrArg ok
    apply IScalar.eq_of_val_eq
    omega

/-- Theorem 11: `jump_grid_to cur target step` advances to the smallest grid point `cur + k * step ≥ max(target, cur + step)`. -/
theorem jump_grid_to_progress_minimality_alignment (cur target step : I64)
    (hstep_pos : 0 < step.val) (hstep_hi : step.val ≤ 1000000000)
    (hcur_lo : -1000000000000000 ≤ cur.val) (hcur_hi : cur.val ≤ 1000000000000000)
    (htgt_lo : -1000000000000000 ≤ target.val) (htgt_hi : target.val ≤ 1000000000000000) :
    ∃ nxt, jump_grid_to cur target step = ok nxt ∧
      cur.val + step.val ≤ nxt.val ∧
      target.val ≤ nxt.val ∧
      (cur.val < target.val → nxt.val - step.val < target.val) ∧
      (nxt.val - cur.val) % step.val = 0 := by
  unfold jump_grid_to
  by_cases hle : target <= cur
  · simp only [hle, ↓reduceIte]
    have htc : target.val ≤ cur.val := hle
    have hadd := i64_add_val_of_bounds cur step (by omega) (by omega)
    refine ⟨Pion.I64.add cur step, rfl, by omega, by omega, by omega, ?_⟩
    rw [hadd]
    have : cur.val + step.val - cur.val = step.val := by omega
    rw [this, Int.emod_self]
  · simp only [hle, ↓reduceIte]
    have hgt : cur.val < target.val := by change ¬(target.val ≤ cur.val) at hle; omega
    have c1 : (1#i64 : I64).val = 1 := rfl
    have hdiff := i64_sub_val_of_bounds target cur (by omega) (by omega)
    have hnum1 := i64_add_val_of_bounds (Pion.I64.sub target cur) step (by omega) (by omega)
    have hnum2 := i64_sub_val_of_bounds (Pion.I64.add (Pion.I64.sub target cur) step) 1#i64 (by omega) (by omega)
    rcases i64_div_pos_ok (Pion.I64.sub (Pion.I64.add (Pion.I64.sub target cur) step) 1#i64) step hstep_pos with ⟨q, hdiv, hqval⟩
    rw [hdiv, result_bind_ok]
    rw [hnum2, hnum1, hdiff, c1] at hqval
    have hnum_nonneg : 0 ≤ target.val - cur.val + step.val - 1 := by omega
    have hq_ediv : q.val = (target.val - cur.val + step.val - 1) / step.val := by
      rw [hqval, Int.tdiv_eq_ediv_of_nonneg hnum_nonneg]
    have hrem_lo : 0 ≤ (target.val - cur.val + step.val - 1) % step.val := Int.emod_nonneg _ (by omega)
    have hrem_hi : (target.val - cur.val + step.val - 1) % step.val < step.val := Int.emod_lt_of_pos _ hstep_pos
    have hdiv_mod : step.val * q.val + (target.val - cur.val + step.val - 1) % step.val = target.val - cur.val + step.val - 1 := by
      rw [hq_ediv]; exact Int.mul_ediv_add_emod _ _
    have hq_ge1 : 1 ≤ q.val := by
      by_contra h
      have hq0 : q.val ≤ 0 := by omega
      have hmp : step.val * q.val ≤ 0 := Int.mul_nonpos_of_nonneg_of_nonpos (by omega) hq0
      omega
    have hsq_ge : step.val ≤ step.val * q.val := by
      have := Int.mul_le_mul_of_nonneg_left hq_ge1 (by omega : 0 ≤ step.val)
      simpa using this
    have hmul_comm : q.val * step.val = step.val * q.val := Int.mul_comm _ _
    have hmul := i64_mul_val_of_bounds q step (by omega) (by omega)
    have hnxt := i64_add_val_of_bounds cur (Pion.I64.mul q step) (by omega) (by omega)
    refine ⟨Pion.I64.add cur (Pion.I64.mul q step), rfl, by omega, by omega, by omega, ?_⟩
    rw [hnxt, hmul]
    have : cur.val + q.val * step.val - cur.val = q.val * step.val := by omega
    rw [this, Int.mul_emod_left]

end IcalProofs
