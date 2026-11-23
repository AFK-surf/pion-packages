import TimeProofs.Core

open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 400000
set_option linter.unusedSimpArgs false

namespace TimeProofs

open time

/-! ## 4. `SignedDuration` Normalization Invariant, Checked Arithmetic & Strict Total Order -/

/-- Same-sign normalization invariant for `SignedDuration`. -/
def ValidSignedDuration (d : SignedDuration) : Prop :=
  -999999999 ≤ d.nanos.val ∧ d.nanos.val ≤ 999999999 ∧
  (d.secs.val > 0 → d.nanos.val ≥ 0) ∧
  (d.secs.val < 0 → d.nanos.val ≤ 0)

/-- Exact mathematical nanosecond value of a `SignedDuration`. -/
def totalNanos (d : SignedDuration) : Int :=
  d.secs.val * 1000000000 + d.nanos.val

def minTotalNanos : Int := -9223372036854775808 * 1000000000 - 999999999
def maxTotalNanos : Int :=  9223372036854775807 * 1000000000 + 999999999

private theorem i64_max_val : i64_max.val = 9223372036854775807 := by
  unfold i64_max
  change (BitVec.ofInt 64 9223372036854775807).toInt = 9223372036854775807
  rw [BitVec.toInt_ofInt]; norm_num

private theorem i64_one_val : (1#i64).val = 1 := by
  change (BitVec.ofInt 64 1).toInt = 1
  rw [BitVec.toInt_ofInt]; norm_num

private theorem i64_neg1_val : ((-1)#i64).val = -1 := by
  change (BitVec.ofInt 64 (-1)).toInt = -1
  rw [BitVec.toInt_ofInt]; norm_num

private theorem i64_zero_val : (0#i64).val = 0 := by
  change (BitVec.ofInt 64 0).toInt = 0
  rw [BitVec.toInt_ofInt]; norm_num

private theorem i64_min_expr_val :
    (Pion.I64.sub (-9223372036854775807)#i64 1#i64).val = -9223372036854775808 := by
  have h1 : ((-9223372036854775807)#i64).val = -9223372036854775807 := by
    change (BitVec.ofInt 64 (-9223372036854775807)).toInt = -9223372036854775807
    rw [BitVec.toInt_ofInt]; norm_num
  have h2 : (1#i64).val = 1 := i64_one_val
  rw [i64_sub_val (-9223372036854775807)#i64 1#i64 (by rw [h1, h2]; omega) (by rw [h1, h2]; omega), h1, h2]
  norm_num

theorem signed_duration_zero_valid :
    ∃ d, SignedDuration.zero = ok d ∧ ValidSignedDuration d ∧ totalNanos d = 0 := by
  unfold SignedDuration.zero ValidSignedDuration totalNanos
  refine ⟨_, rfl, ?_, ?_⟩
  · simp [i64_zero_val]
  · simp [i64_zero_val]

theorem signed_duration_min_valid :
    ∃ d, SignedDuration.min = ok d ∧ ValidSignedDuration d ∧ totalNanos d = minTotalNanos := by
  unfold SignedDuration.min ValidSignedDuration totalNanos minTotalNanos
  refine ⟨_, rfl, ?_, ?_⟩
  · simp [i64_min_expr_val]
  · simp [i64_min_expr_val]

theorem signed_duration_max_valid :
    ∃ d, SignedDuration.max = ok d ∧ ValidSignedDuration d ∧ totalNanos d = maxTotalNanos := by
  unfold SignedDuration.max ValidSignedDuration totalNanos maxTotalNanos
  refine ⟨_, rfl, ?_, ?_⟩
  · simp [i64_max_val]
  · simp [i64_max_val]

/-- Exact specification of `checked_add_i64` for all `Int64` inputs (including `INT64_MIN`/`MAX`). -/
theorem checked_add_i64_spec (a b : Std.I64) :
    if -9223372036854775808 ≤ a.val + b.val ∧ a.val + b.val ≤ 9223372036854775807 then
      ∃ s : Std.I64, checked_add_i64 a b = ok (some s) ∧ s.val = a.val + b.val
    else
      checked_add_i64 a b = ok none := by
  have ha := i64_bounds a
  have hb := i64_bounds b
  unfold checked_add_i64
  by_cases hpos : b.val > 0
  · have hpos' : b > 0#i64 := hpos
    have hsub : (Pion.I64.sub i64_max b).val = 9223372036854775807 - b.val := by
      have hm : i64_max.val = 9223372036854775807 := i64_max_val
      rw [i64_sub_val i64_max b (by rw [hm]; linarith) (by rw [hm]; linarith), hm]
    by_cases hov : a.val + b.val > 9223372036854775807
    · have hov' : a > Pion.I64.sub i64_max b := by
        change (Pion.I64.sub i64_max b).val < a.val; rw [hsub]; linarith
      have hcond : ¬ (-9223372036854775808 ≤ a.val + b.val ∧ a.val + b.val ≤ 9223372036854775807) := by
        intro h; linarith
      rw [if_neg hcond]
      have hc : ((decide (b > 0#i64)) && (decide (a > Pion.I64.sub i64_max b))) = true := by
        rw [decide_eq_true hpos', decide_eq_true hov']; rfl
      rw [if_pos hc]
    · have hnov' : ¬ (a > Pion.I64.sub i64_max b) := by
        change ¬ ((Pion.I64.sub i64_max b).val < a.val); rw [hsub]; linarith
      have hneg' : ¬ (b < 0#i64) := by change ¬ (b.val < 0); linarith
      have hcond : -9223372036854775808 ≤ a.val + b.val ∧ a.val + b.val ≤ 9223372036854775807 := by
        constructor <;> linarith
      rw [if_pos hcond]
      have hc1 : ((decide (b > 0#i64)) && (decide (a > Pion.I64.sub i64_max b))) = false := by
        rw [decide_eq_false hnov', Bool.and_false]
      have hc2 : ((decide (b < 0#i64)) && (decide (a < Pion.I64.sub (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b))) = false := by
        rw [decide_eq_false hneg', Bool.false_and]
      rw [if_neg (by rw [hc1]; decide), if_neg (by rw [hc2]; decide)]
      exact ⟨Pion.I64.add a b, rfl, i64_add_val a b hcond.1 hcond.2⟩
  · have hpos' : ¬ (b > 0#i64) := hpos
    have hc1 : ((decide (b > 0#i64)) && (decide (a > Pion.I64.sub i64_max b))) = false := by
      rw [decide_eq_false hpos', Bool.false_and]
    by_cases hneg : b.val < 0
    · have hneg' : b < 0#i64 := hneg
      have hsub : (Pion.I64.sub (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b).val =
          -9223372036854775808 - b.val := by
        rw [i64_sub_val _ b (by rw [i64_min_expr_val]; linarith) (by rw [i64_min_expr_val]; linarith), i64_min_expr_val]
      by_cases hov : a.val + b.val < -9223372036854775808
      · have hov' : a < Pion.I64.sub (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b := by
          change a.val < (Pion.I64.sub (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b).val; rw [hsub]; linarith
        have hcond : ¬ (-9223372036854775808 ≤ a.val + b.val ∧ a.val + b.val ≤ 9223372036854775807) := by
          intro h; linarith
        rw [if_neg hcond]
        have hc2 : ((decide (b < 0#i64)) && (decide (a < Pion.I64.sub (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b))) = true := by
          rw [decide_eq_true hneg', decide_eq_true hov']; rfl
        rw [if_neg (by rw [hc1]; decide), if_pos hc2]
      · have hnov' : ¬ (a < Pion.I64.sub (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b) := by
          change ¬ (a.val < (Pion.I64.sub (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b).val); rw [hsub]; linarith
        have hcond : -9223372036854775808 ≤ a.val + b.val ∧ a.val + b.val ≤ 9223372036854775807 := by
          constructor <;> linarith
        rw [if_pos hcond]
        have hc2 : ((decide (b < 0#i64)) && (decide (a < Pion.I64.sub (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b))) = false := by
          rw [decide_eq_false hnov', Bool.and_false]
        rw [if_neg (by rw [hc1]; decide), if_neg (by rw [hc2]; decide)]
        exact ⟨Pion.I64.add a b, rfl, i64_add_val a b hcond.1 hcond.2⟩
    · have hneg' : ¬ (b < 0#i64) := hneg
      have hcond : -9223372036854775808 ≤ a.val + b.val ∧ a.val + b.val ≤ 9223372036854775807 := by
        constructor <;> linarith
      rw [if_pos hcond]
      have hc2 : ((decide (b < 0#i64)) && (decide (a < Pion.I64.sub (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b))) = false := by
        rw [decide_eq_false hneg', Bool.false_and]
      rw [if_neg (by rw [hc1]; decide), if_neg (by rw [hc2]; decide)]
      exact ⟨Pion.I64.add a b, rfl, i64_add_val a b hcond.1 hcond.2⟩

/-- Exact specification of `checked_sub_i64` for all `Int64` inputs (including `INT64_MIN`/`MAX`). -/
theorem checked_sub_i64_spec (a b : Std.I64) :
    if -9223372036854775808 ≤ a.val - b.val ∧ a.val - b.val ≤ 9223372036854775807 then
      ∃ s : Std.I64, checked_sub_i64 a b = ok (some s) ∧ s.val = a.val - b.val
    else
      checked_sub_i64 a b = ok none := by
  have ha := i64_bounds a
  have hb := i64_bounds b
  unfold checked_sub_i64
  by_cases hneg : b.val < 0
  · have hneg' : b < 0#i64 := hneg
    have hadd : (Pion.I64.add i64_max b).val = 9223372036854775807 + b.val := by
      have hm : i64_max.val = 9223372036854775807 := i64_max_val
      rw [i64_add_val i64_max b (by rw [hm]; linarith) (by rw [hm]; linarith), hm]
    by_cases hov : a.val - b.val > 9223372036854775807
    · have hov' : a > Pion.I64.add i64_max b := by
        change (Pion.I64.add i64_max b).val < a.val; rw [hadd]; linarith
      have hcond : ¬ (-9223372036854775808 ≤ a.val - b.val ∧ a.val - b.val ≤ 9223372036854775807) := by
        intro h; linarith
      rw [if_neg hcond]
      have hc : ((decide (b < 0#i64)) && (decide (a > Pion.I64.add i64_max b))) = true := by
        rw [decide_eq_true hneg', decide_eq_true hov']; rfl
      rw [if_pos hc]
    · have hnov' : ¬ (a > Pion.I64.add i64_max b) := by
        change ¬ ((Pion.I64.add i64_max b).val < a.val); rw [hadd]; linarith
      have hpos' : ¬ (b > 0#i64) := by change ¬ (0 < b.val); linarith
      have hcond : -9223372036854775808 ≤ a.val - b.val ∧ a.val - b.val ≤ 9223372036854775807 := by
        constructor <;> linarith
      rw [if_pos hcond]
      have hc1 : ((decide (b < 0#i64)) && (decide (a > Pion.I64.add i64_max b))) = false := by
        rw [decide_eq_false hnov', Bool.and_false]
      have hc2 : ((decide (b > 0#i64)) && (decide (a < Pion.I64.add (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b))) = false := by
        rw [decide_eq_false hpos', Bool.false_and]
      rw [if_neg (by rw [hc1]; decide), if_neg (by rw [hc2]; decide)]
      exact ⟨Pion.I64.sub a b, rfl, i64_sub_val a b hcond.1 hcond.2⟩
  · have hneg' : ¬ (b < 0#i64) := hneg
    have hc1 : ((decide (b < 0#i64)) && (decide (a > Pion.I64.add i64_max b))) = false := by
      rw [decide_eq_false hneg', Bool.false_and]
    by_cases hpos : b.val > 0
    · have hpos' : b > 0#i64 := hpos
      have hadd : (Pion.I64.add (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b).val =
          -9223372036854775808 + b.val := by
        rw [i64_add_val _ b (by rw [i64_min_expr_val]; linarith) (by rw [i64_min_expr_val]; linarith), i64_min_expr_val]
      by_cases hov : a.val - b.val < -9223372036854775808
      · have hov' : a < Pion.I64.add (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b := by
          change a.val < (Pion.I64.add (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b).val; rw [hadd]; linarith
        have hcond : ¬ (-9223372036854775808 ≤ a.val - b.val ∧ a.val - b.val ≤ 9223372036854775807) := by
          intro h; linarith
        rw [if_neg hcond]
        have hc2 : ((decide (b > 0#i64)) && (decide (a < Pion.I64.add (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b))) = true := by
          rw [decide_eq_true hpos', decide_eq_true hov']; rfl
        rw [if_neg (by rw [hc1]; decide), if_pos hc2]
      · have hnov' : ¬ (a < Pion.I64.add (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b) := by
          change ¬ (a.val < (Pion.I64.add (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b).val); rw [hadd]; linarith
        have hcond : -9223372036854775808 ≤ a.val - b.val ∧ a.val - b.val ≤ 9223372036854775807 := by
          constructor <;> linarith
        rw [if_pos hcond]
        have hc2 : ((decide (b > 0#i64)) && (decide (a < Pion.I64.add (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b))) = false := by
          rw [decide_eq_false hnov', Bool.and_false]
        rw [if_neg (by rw [hc1]; decide), if_neg (by rw [hc2]; decide)]
        exact ⟨Pion.I64.sub a b, rfl, i64_sub_val a b hcond.1 hcond.2⟩
    · have hpos' : ¬ (b > 0#i64) := hpos
      have hcond : -9223372036854775808 ≤ a.val - b.val ∧ a.val - b.val ≤ 9223372036854775807 := by
        constructor <;> linarith
      rw [if_pos hcond]
      have hc2 : ((decide (b > 0#i64)) && (decide (a < Pion.I64.add (Pion.I64.sub (-9223372036854775807)#i64 1#i64) b))) = false := by
        rw [decide_eq_false hpos', Bool.false_and]
      rw [if_neg (by rw [hc1]; decide), if_neg (by rw [hc2]; decide)]
      exact ⟨Pion.I64.sub a b, rfl, i64_sub_val a b hcond.1 hcond.2⟩

/-- Helper: sign-normalization tail shared by `SignedDuration.new` and `SignedDuration.checked_add`. -/
private theorem normalize_pair_sound (s : Std.I64) (n : Std.I32)
    (hn1 : -999999999 ≤ n.val) (hn2 : n.val ≤ 999999999) :
    let res : SignedDuration :=
      if (decide (s < 0#i64) && decide (n > 0#i32)) then
        SignedDuration.mk (Pion.I64.add s 1#i64) (Pion.I32.sub n 1000000000#i32)
      else if (decide (s > 0#i64) && decide (n < 0#i32)) then
        SignedDuration.mk (Pion.I64.sub s 1#i64) (Pion.I32.add n 1000000000#i32)
      else
        SignedDuration.mk s n
    ValidSignedDuration res ∧ totalNanos res = s.val * 1000000000 + n.val := by
  have hs := i64_bounds s
  dsimp only
  by_cases h1 : s.val < 0 ∧ n.val > 0
  · have h1a : s < 0#i64 := h1.1
    have h1b : n > 0#i32 := h1.2
    simp only [h1a, h1b, decide_true, Bool.and_true, ↓reduceIte]
    have hsa : (Pion.I64.add s 1#i64).val = s.val + 1 := by
      simpa using i64_add_val s 1#i64 (by simp; omega) (by simp; omega)
    have hna : (Pion.I32.sub n 1000000000#i32).val = n.val - 1000000000 := by
      simpa using i32_sub_val n 1000000000#i32 (by simp; omega) (by simp; omega)
    constructor
    · unfold ValidSignedDuration; rw [hsa, hna]; omega
    · unfold totalNanos; rw [hsa, hna]; omega
  · have h1f : (decide (s < 0#i64) && decide (n > 0#i32)) = false := by
      by_cases hs0 : s.val < 0
      · have : ¬ (n.val > 0) := fun hn => h1 ⟨hs0, hn⟩
        have hnb : ¬ (n > 0#i32) := this
        simp [hnb]
      · have hsb : ¬ (s < 0#i64) := hs0
        simp [hsb]
    simp only [h1f, Bool.false_eq_true, ↓reduceIte]
    by_cases h2 : s.val > 0 ∧ n.val < 0
    · have h2a : s > 0#i64 := h2.1
      have h2b : n < 0#i32 := h2.2
      simp only [h2a, h2b, decide_true, Bool.and_true, ↓reduceIte]
      have hsa : (Pion.I64.sub s 1#i64).val = s.val - 1 := by
        simpa using i64_sub_val s 1#i64 (by simp; omega) (by simp; omega)
      have hna : (Pion.I32.add n 1000000000#i32).val = n.val + 1000000000 := by
        simpa using i32_add_val n 1000000000#i32 (by simp; omega) (by simp; omega)
      constructor
      · unfold ValidSignedDuration; rw [hsa, hna]; omega
      · unfold totalNanos; rw [hsa, hna]; omega
    · have h2f : (decide (s > 0#i64) && decide (n < 0#i32)) = false := by
        by_cases hs0 : s.val > 0
        · have : ¬ (n.val < 0) := fun hn => h2 ⟨hs0, hn⟩
          have hnb : ¬ (n < 0#i32) := this
          simp [hnb]
        · have hsb : ¬ (s > 0#i64) := hs0
          simp [hsb]
      simp only [h2f, Bool.false_eq_true, ↓reduceIte]
      constructor
      · unfold ValidSignedDuration; dsimp only; omega
      · unfold totalNanos; rfl

/-- `SignedDuration.new` never traps for any `(secs : Int64, nanos : Int32)`;
    returns `Ok r` with `ValidSignedDuration r` and exact `totalNanos` iff the total fits in
    `[minTotalNanos, maxTotalNanos]`, and `Err` iff it overflows! -/
theorem signed_duration_new_sound (secs : Std.I64) (nanos : Std.I32) :
    if minTotalNanos ≤ secs.val * 1000000000 + nanos.val ∧
       secs.val * 1000000000 + nanos.val ≤ maxTotalNanos then
      ∃ r : SignedDuration, SignedDuration.new secs nanos = ok (Pion.Res.Ok r) ∧
        ValidSignedDuration r ∧ totalNanos r = secs.val * 1000000000 + nanos.val
    else
      ∃ e : TimeError, SignedDuration.new secs nanos = ok (Pion.Res.Err e) := by
  have hs := i64_bounds secs
  have hn := i32_bounds nanos
  unfold SignedDuration.new minTotalNanos maxTotalNanos
  by_cases hbig : nanos.val ≤ -1000000000 ∨ nanos.val ≥ 1000000000
  · have hbig_b : (decide (nanos ≤ (-1000000000)#i32) || decide (nanos ≥ 1000000000#i32)) = true := by
      rcases hbig with h1 | h2
      · have h1' : nanos ≤ (-1000000000)#i32 := h1; simp [h1']
      · have h2' : nanos ≥ 1000000000#i32 := h2; simp [h2']
    simp only [hbig_b, ↓reduceIte]
    rcases i32_div_ok nanos 1000000000#i32 (by decide) (by simp) with ⟨q, hq_eq, hq_val⟩
    rw [hq_eq, b_ok]
    have hq_rng : q.val = Int.tdiv nanos.val 1000000000 := by
      simpa using hq_val
    have htmod_rng : -999999999 ≤ Int.tmod nanos.val 1000000000 ∧ Int.tmod nanos.val 1000000000 ≤ 999999999 := by
      have h1 := Int.tmod_lt_of_pos nanos.val (by decide : (0 : Int) < 1000000000)
      have h2 := Int.tmod_lt_of_pos (-nanos.val) (by decide : (0 : Int) < 1000000000)
      rw [Int.neg_tmod] at h2
      omega
    have hdiv_mod : q.val * 1000000000 + Int.tmod nanos.val 1000000000 = nanos.val := by
      have h := Int.mul_tdiv_add_tmod nanos.val 1000000000
      rw [hq_rng]; linarith
    have hsign_tmod : (nanos.val ≥ 0 → Int.tmod nanos.val 1000000000 ≥ 0) ∧
                      (nanos.val ≤ 0 → Int.tmod nanos.val 1000000000 ≤ 0) := by
      constructor
      · intro hge; exact Int.tmod_nonneg 1000000000 hge
      · intro hle
        have h := Int.tmod_nonneg 1000000000 (show 0 ≤ -nanos.val by omega)
        rw [Int.neg_tmod] at h; omega
    have hq_b : -2 ≤ q.val ∧ q.val ≤ 2 := by
      by_cases h0 : nanos.val ≥ 0
      · have := hsign_tmod.1 h0; omega
      · have := hsign_tmod.2 (by omega); omega
    have hq64 : (Pion.I32.to_int64 q).val = q.val := i32_to_int64_val q
    have hadd_spec := checked_add_i64_spec secs (Pion.I32.to_int64 q)
    by_cases hin : -9223372036854775808 ≤ secs.val + q.val ∧ secs.val + q.val ≤ 9223372036854775807
    · have hin64 : -9223372036854775808 ≤ secs.val + (Pion.I32.to_int64 q).val ∧
          secs.val + (Pion.I32.to_int64 q).val ≤ 9223372036854775807 := by omega
      simp only [hin64, ↓reduceIte] at hadd_spec
      rcases hadd_spec with ⟨s1, hs1_eq, hs1_val⟩
      rw [hs1_eq, b_ok]
      rcases i32_rem_ok nanos 1000000000#i32 (by decide) (by simp) with ⟨n1, hn1_eq, hn1_val⟩
      simp only [hn1_eq, b_ok]
      have hn1_exact : n1.val = Int.tmod nanos.val 1000000000 := by simpa using hn1_val
      have htot_in : -9223372036854775808 * 1000000000 - 999999999 ≤ secs.val * 1000000000 + nanos.val ∧
          secs.val * 1000000000 + nanos.val ≤ 9223372036854775807 * 1000000000 + 999999999 := by omega
      simp only [htot_in, ↓reduceIte]
      by_cases hzero : (n1 == 0#i32) || (s1 == 0#i64)
      · simp only [hzero, ↓reduceIte]
        have hz : n1.val = 0 ∨ s1.val = 0 := by
          rcases Bool.or_eq_true_iff.mp hzero with h | h
          · left; rw [beq_iff_eq] at h; rw [h]; decide
          · right; rw [beq_iff_eq] at h; rw [h]; exact i64_zero_val
        refine ⟨_, rfl, ?_, ?_⟩
        · unfold ValidSignedDuration; dsimp only; omega
        · unfold totalNanos; dsimp only; omega
      · simp only [hzero, Bool.false_eq_true, ↓reduceIte]
        have hnorm := normalize_pair_sound s1 n1 (by omega) (by omega)
        refine ⟨_, ?_, hnorm.1, ?_⟩
        · split_ifs <;> rfl
        · rw [hnorm.2]; omega
    · have hin64 : ¬ (-9223372036854775808 ≤ secs.val + (Pion.I32.to_int64 q).val ∧
          secs.val + (Pion.I32.to_int64 q).val ≤ 9223372036854775807) := by omega
      simp only [hin64, ↓reduceIte] at hadd_spec
      rw [hadd_spec, b_ok]
      have htot_out : ¬ (-9223372036854775808 * 1000000000 - 999999999 ≤ secs.val * 1000000000 + nanos.val ∧
          secs.val * 1000000000 + nanos.val ≤ 9223372036854775807 * 1000000000 + 999999999) := by omega
      simp only [htot_out, ↓reduceIte]
      unfold TimeError.new; rw [b_ok, b_ok]
      exact ⟨_, rfl⟩
  · have hbig_f : (decide (nanos ≤ (-1000000000)#i32) || decide (nanos ≥ 1000000000#i32)) = false := by
      have h1 : ¬ (nanos ≤ (-1000000000)#i32) := by show ¬ (nanos.val ≤ -1000000000); omega
      have h2 : ¬ (nanos ≥ 1000000000#i32) := by show ¬ (nanos.val ≥ 1000000000); omega
      simp [h1, h2]
    have htot_in : -9223372036854775808 * 1000000000 - 999999999 ≤ secs.val * 1000000000 + nanos.val ∧
        secs.val * 1000000000 + nanos.val ≤ 9223372036854775807 * 1000000000 + 999999999 := by omega
    simp only [hbig_f, Bool.false_eq_true, ↓reduceIte, b_ok, htot_in]
    by_cases hzero : (nanos == 0#i32) || (secs == 0#i64)
    · simp only [hzero, ↓reduceIte]
      have hz : nanos.val = 0 ∨ secs.val = 0 := by
        rcases Bool.or_eq_true_iff.mp hzero with h | h
        · left; rw [beq_iff_eq] at h; rw [h]; decide
        · right; rw [beq_iff_eq] at h; rw [h]; exact i64_zero_val
      refine ⟨_, rfl, ?_, ?_⟩
      · unfold ValidSignedDuration; dsimp only; omega
      · unfold totalNanos; rfl
    · simp only [hzero, Bool.false_eq_true, ↓reduceIte]
      have hnorm := normalize_pair_sound secs nanos (by omega) (by omega)
      refine ⟨_, ?_, hnorm.1, hnorm.2⟩
      split_ifs <;> rfl

/-- `SignedDuration.checked_neg` never traps on any `ValidSignedDuration`,
    succeeds iff `-totalNanos a` fits in `[minTotalNanos, maxTotalNanos]` (i.e. `a.secs ≠ INT64_MIN`),
    and preserves normalization and exact negation. -/
theorem signed_duration_checked_neg_sound (a : SignedDuration) (ha : ValidSignedDuration a) :
    if minTotalNanos ≤ -totalNanos a ∧ -totalNanos a ≤ maxTotalNanos then
      ∃ r : SignedDuration, SignedDuration.checked_neg a = ok (Pion.Res.Ok r) ∧
        ValidSignedDuration r ∧ totalNanos r = -totalNanos a
    else
      ∃ e : TimeError, SignedDuration.checked_neg a = ok (Pion.Res.Err e) := by
  have hs := i64_bounds a.secs
  rcases ha with ⟨hn1, hn2, hpos, hneg⟩
  unfold SignedDuration.checked_neg minTotalNanos maxTotalNanos totalNanos
  by_cases hmin : a.secs.val = -9223372036854775808
  · have hmin' : a.secs = Pion.I64.sub (-9223372036854775807)#i64 1#i64 :=
      i64_ext (hmin.trans i64_min_expr_val.symm)
    have hout : ¬ (-9223372036854775808 * 1000000000 - 999999999 ≤ -(a.secs.val * 1000000000 + a.nanos.val) ∧
        -(a.secs.val * 1000000000 + a.nanos.val) ≤ 9223372036854775807 * 1000000000 + 999999999) := by omega
    rw [if_neg hout, if_pos hmin']
    unfold TimeError.new; rw [b_ok]
    exact ⟨_, rfl⟩
  · have hmin' : a.secs ≠ Pion.I64.sub (-9223372036854775807)#i64 1#i64 := fun h =>
      hmin ((congrArg IScalar.val h).trans i64_min_expr_val)
    have hin : -9223372036854775808 * 1000000000 - 999999999 ≤ -(a.secs.val * 1000000000 + a.nanos.val) ∧
        -(a.secs.val * 1000000000 + a.nanos.val) ≤ 9223372036854775807 * 1000000000 + 999999999 := by omega
    rw [if_pos hin, if_neg hmin']
    have hns := i64_neg_val a.secs hmin
    have hnn := i32_neg_val a.nanos (by omega)
    refine ⟨_, rfl, ?_, ?_⟩
    · unfold ValidSignedDuration; rw [hns, hnn]; omega
    · rw [hns, hnn]; omega

/-- `SignedDuration.checked_add` never traps on any pair of `ValidSignedDuration`s,
    succeeds iff `totalNanos a + totalNanos b ∈ [minTotalNanos, maxTotalNanos]`,
    and preserves normalization and exact integer nanosecond sum! -/
theorem signed_duration_checked_add_sound (a b : SignedDuration)
    (ha : ValidSignedDuration a) (hb : ValidSignedDuration b) :
    if minTotalNanos ≤ totalNanos a + totalNanos b ∧
       totalNanos a + totalNanos b ≤ maxTotalNanos then
      ∃ r : SignedDuration, SignedDuration.checked_add a b = ok (Pion.Res.Ok r) ∧
        ValidSignedDuration r ∧ totalNanos r = totalNanos a + totalNanos b
    else
      ∃ e : TimeError, SignedDuration.checked_add a b = ok (Pion.Res.Err e) := by
  have hsa := i64_bounds a.secs
  have hsb := i64_bounds b.secs
  rcases ha with ⟨han1, han2, hapos, haneg⟩
  rcases hb with ⟨hbn1, hbn2, hbpos, hbneg⟩
  unfold SignedDuration.checked_add minTotalNanos maxTotalNanos totalNanos
  have hadd1 := checked_add_i64_spec a.secs b.secs
  by_cases hs_in : -9223372036854775808 ≤ a.secs.val + b.secs.val ∧
      a.secs.val + b.secs.val ≤ 9223372036854775807
  · simp only [hs_in, ↓reduceIte] at hadd1
    rcases hadd1 with ⟨s, hs_eq, hs_val⟩
    rw [hs_eq, b_ok]
    set n := Pion.I32.add a.nanos b.nanos
    have hn_val : n.val = a.nanos.val + b.nanos.val := i32_add_val a.nanos b.nanos (by omega) (by omega)
    by_cases hnge : n.val ≥ 1000000000
    · have hnge' : n ≥ 1000000000#i32 := hnge
      simp only [hnge', ↓reduceIte]
      set n1 := Pion.I32.sub n 1000000000#i32
      have hn1_val : n1.val = n.val - 1000000000 := by
        have h1e9 : (1000000000#i32).val = 1000000000 := by decide
        rw [i32_sub_val n 1000000000#i32 (by rw [h1e9]; omega) (by rw [h1e9]; omega), h1e9]
      have hadd2 := checked_add_i64_spec s 1#i64
      by_cases hs1_in : -9223372036854775808 ≤ s.val + 1 ∧ s.val + 1 ≤ 9223372036854775807
      · have hs1_in' : -9223372036854775808 ≤ s.val + (1#i64).val ∧ s.val + (1#i64).val ≤ 9223372036854775807 := by
          rw [i64_one_val]; exact hs1_in
        simp only [hs1_in', ↓reduceIte] at hadd2
        rcases hadd2 with ⟨s1, hs1_eq, hs1_val⟩
        rw [hs1_eq, b_ok, b_ok]
        have htot_in : -9223372036854775808 * 1000000000 - 999999999 ≤
            a.secs.val * 1000000000 + a.nanos.val + (b.secs.val * 1000000000 + b.nanos.val) ∧
            a.secs.val * 1000000000 + a.nanos.val + (b.secs.val * 1000000000 + b.nanos.val) ≤
            9223372036854775807 * 1000000000 + 999999999 := by omega
        simp only [htot_in, ↓reduceIte]
        have hnorm := normalize_pair_sound s1 n1 (by omega) (by omega)
        refine ⟨_, ?_, hnorm.1, ?_⟩
        · split_ifs <;> rfl
        · change totalNanos _ = _; rw [hnorm.2]; have h1v : (1#i64).val = 1 := i64_one_val; omega
      · have hs1_out' : ¬ (-9223372036854775808 ≤ s.val + (1#i64).val ∧ s.val + (1#i64).val ≤ 9223372036854775807) := by
          rw [i64_one_val]; exact hs1_in
        simp only [hs1_out', ↓reduceIte] at hadd2
        rw [hadd2, b_ok]
        have htot_out : ¬ (-9223372036854775808 * 1000000000 - 999999999 ≤
            a.secs.val * 1000000000 + a.nanos.val + (b.secs.val * 1000000000 + b.nanos.val) ∧
            a.secs.val * 1000000000 + a.nanos.val + (b.secs.val * 1000000000 + b.nanos.val) ≤
            9223372036854775807 * 1000000000 + 999999999) := by omega
        simp only [htot_out, ↓reduceIte]
        unfold TimeError.new; rw [b_ok, b_ok]
        exact ⟨_, rfl⟩
    · have hnge' : ¬ (n ≥ 1000000000#i32) := hnge
      simp only [hnge', ↓reduceIte]
      by_cases hnle : n.val ≤ -1000000000
      · have hnle' : n ≤ (-1000000000)#i32 := hnle
        simp only [hnle', ↓reduceIte]
        set n2 := Pion.I32.add n 1000000000#i32
        have hn2_val : n2.val = n.val + 1000000000 := by
          have h1e9 : (1000000000#i32).val = 1000000000 := by decide
          rw [i32_add_val n 1000000000#i32 (by rw [h1e9]; omega) (by rw [h1e9]; omega), h1e9]
        have hadd2 := checked_add_i64_spec s (-1)#i64
        by_cases hs2_in : -9223372036854775808 ≤ s.val + (-1) ∧ s.val + (-1) ≤ 9223372036854775807
        · have hs2_in' : -9223372036854775808 ≤ s.val + ((-1)#i64).val ∧ s.val + ((-1)#i64).val ≤ 9223372036854775807 := by
            have hm1 : ((-1)#i64).val = -1 := i64_neg1_val
            omega
          simp only [hs2_in', ↓reduceIte] at hadd2
          rcases hadd2 with ⟨s2, hs2_eq, hs2_val⟩
          rw [hs2_eq, b_ok, b_ok]
          have htot_in : -9223372036854775808 * 1000000000 - 999999999 ≤
              a.secs.val * 1000000000 + a.nanos.val + (b.secs.val * 1000000000 + b.nanos.val) ∧
              a.secs.val * 1000000000 + a.nanos.val + (b.secs.val * 1000000000 + b.nanos.val) ≤
              9223372036854775807 * 1000000000 + 999999999 := by omega
          simp only [htot_in, ↓reduceIte]
          have hnorm := normalize_pair_sound s2 n2 (by omega) (by omega)
          refine ⟨_, ?_, hnorm.1, ?_⟩
          · split_ifs <;> rfl
          · change totalNanos _ = _; rw [hnorm.2]; have hm1 : ((-1)#i64).val = -1 := i64_neg1_val; omega
        · have hs2_out' : ¬ (-9223372036854775808 ≤ s.val + ((-1)#i64).val ∧ s.val + ((-1)#i64).val ≤ 9223372036854775807) := by
            have hm1 : ((-1)#i64).val = -1 := i64_neg1_val
            omega
          simp only [hs2_out', ↓reduceIte] at hadd2
          rw [hadd2, b_ok]
          have htot_out : ¬ (-9223372036854775808 * 1000000000 - 999999999 ≤
              a.secs.val * 1000000000 + a.nanos.val + (b.secs.val * 1000000000 + b.nanos.val) ∧
              a.secs.val * 1000000000 + a.nanos.val + (b.secs.val * 1000000000 + b.nanos.val) ≤
              9223372036854775807 * 1000000000 + 999999999) := by omega
          simp only [htot_out, ↓reduceIte]
          unfold TimeError.new; rw [b_ok, b_ok]
          exact ⟨_, rfl⟩
      · have hnle' : ¬ (n ≤ (-1000000000)#i32) := hnle
        simp only [hnle', ↓reduceIte, b_ok]
        have htot_in : -9223372036854775808 * 1000000000 - 999999999 ≤
            a.secs.val * 1000000000 + a.nanos.val + (b.secs.val * 1000000000 + b.nanos.val) ∧
            a.secs.val * 1000000000 + a.nanos.val + (b.secs.val * 1000000000 + b.nanos.val) ≤
            9223372036854775807 * 1000000000 + 999999999 := by omega
        simp only [htot_in, ↓reduceIte]
        have hnorm := normalize_pair_sound s n (by omega) (by omega)
        refine ⟨_, ?_, hnorm.1, ?_⟩
        · split_ifs <;> rfl
        · change totalNanos _ = _; rw [hnorm.2]; omega
  · simp only [hs_in, ↓reduceIte] at hadd1
    rw [hadd1, b_ok]
    have htot_out : ¬ (-9223372036854775808 * 1000000000 - 999999999 ≤
        a.secs.val * 1000000000 + a.nanos.val + (b.secs.val * 1000000000 + b.nanos.val) ∧
        a.secs.val * 1000000000 + a.nanos.val + (b.secs.val * 1000000000 + b.nanos.val) ≤
        9223372036854775807 * 1000000000 + 999999999) := by omega
    simp only [htot_out, ↓reduceIte]
    unfold TimeError.new; rw [b_ok]
    exact ⟨_, rfl⟩

/-- `SignedDuration.checked_sub` never traps on any pair of `ValidSignedDuration`s
    (including `rhs = SignedDuration::min`), succeeds iff `totalNanos a - totalNanos b`
    fits in `[minTotalNanos, maxTotalNanos]`, and preserves normalization and exact difference! -/
theorem signed_duration_checked_sub_sound (a b : SignedDuration)
    (ha : ValidSignedDuration a) (hb : ValidSignedDuration b) :
    if minTotalNanos ≤ totalNanos a - totalNanos b ∧
       totalNanos a - totalNanos b ≤ maxTotalNanos then
      ∃ r : SignedDuration, SignedDuration.checked_sub a b = ok (Pion.Res.Ok r) ∧
        ValidSignedDuration r ∧ totalNanos r = totalNanos a - totalNanos b
    else
      ∃ e : TimeError, SignedDuration.checked_sub a b = ok (Pion.Res.Err e) := by
  have hsa := i64_bounds a.secs
  have hsb := i64_bounds b.secs
  rcases ha with ⟨han1, han2, hapos, haneg⟩
  rcases hb with ⟨hbn1, hbn2, hbpos, hbneg⟩
  unfold SignedDuration.checked_sub
  by_cases hmin : b.secs.val = -9223372036854775808
  · have hmin' : b.secs = Pion.I64.sub (-9223372036854775807)#i64 1#i64 :=
      i64_ext (hmin.trans i64_min_expr_val.symm)
    rw [if_pos hmin']
    by_cases hspec_zero : a.secs.val = 0 ∧ a.nanos.val < b.nanos.val
    · have hz1 : (a.secs == 0#i64) = true := beq_iff_eq.mpr (i64_ext (by simpa using hspec_zero.1))
      have hz2 : a.nanos < b.nanos := hspec_zero.2
      simp only [hz1, hz2, decide_true, Bool.and_true, ↓reduceIte]
      have htot_in : minTotalNanos ≤ totalNanos a - totalNanos b ∧
          totalNanos a - totalNanos b ≤ maxTotalNanos := by
        unfold minTotalNanos maxTotalNanos totalNanos; omega
      simp only [htot_in, ↓reduceIte]
      have ha1 : (Pion.I32.add 1000000000#i32 a.nanos).val = 1000000000 + a.nanos.val := by
        simpa using i32_add_val 1000000000#i32 a.nanos (by simp; omega) (by simp; omega)
      have hs1 := i32_sub_val (Pion.I32.add 1000000000#i32 a.nanos) b.nanos (by rw [ha1]; omega) (by rw [ha1]; omega)
      have hm : i64_max.val = 9223372036854775807 := i64_max_val
      refine ⟨_, rfl, ?_, ?_⟩
      · unfold ValidSignedDuration; rw [hm, hs1, ha1]; omega
      · unfold totalNanos; rw [hm, hs1, ha1]; omega
    · have hspec_f : ((a.secs == 0#i64) && decide (a.nanos < b.nanos)) = false := by
        by_cases hz : a.secs.val = 0
        · have hnot : ¬ (a.nanos < b.nanos) := fun h => hspec_zero ⟨hz, h⟩
          simp [hnot]
        · have hne : (a.secs == 0#i64) = false := beq_false_of_ne (fun h => hz (by rw [h]; exact i64_zero_val))
          simp [hne]
      simp only [hspec_f, Bool.false_eq_true, ↓reduceIte]
      have hsub_spec := checked_sub_i64_spec a.secs b.secs
      by_cases hs_in : -9223372036854775808 ≤ a.secs.val - b.secs.val ∧
          a.secs.val - b.secs.val ≤ 9223372036854775807
      · simp only [hs_in, ↓reduceIte] at hsub_spec
        rcases hsub_spec with ⟨s1, hs1_eq, hs1_val⟩
        rw [hs1_eq, b_ok]
        have hdn : (Pion.I32.sub a.nanos b.nanos).val = a.nanos.val - b.nanos.val :=
          i32_sub_val a.nanos b.nanos (by omega) (by omega)
        have hnew := signed_duration_new_sound s1 (Pion.I32.sub a.nanos b.nanos)
        have htot_eq : s1.val * 1000000000 + (Pion.I32.sub a.nanos b.nanos).val =
            totalNanos a - totalNanos b := by
          unfold totalNanos; rw [hs1_val, hdn]; omega
        rw [htot_eq] at hnew
        by_cases htot_in : minTotalNanos ≤ totalNanos a - totalNanos b ∧
            totalNanos a - totalNanos b ≤ maxTotalNanos
        · simp only [htot_in, ↓reduceIte] at hnew ⊢
          rcases hnew with ⟨r, hr_eq, hr_v, hr_t⟩
          exact ⟨r, by rw [hr_eq, b_ok], hr_v, hr_t⟩
        · simp only [htot_in, ↓reduceIte] at hnew ⊢
          rcases hnew with ⟨e, he_eq⟩
          exact ⟨e, by rw [he_eq, b_ok]⟩
      · simp only [hs_in, ↓reduceIte] at hsub_spec
        rw [hsub_spec, b_ok]
        have htot_out : ¬ (minTotalNanos ≤ totalNanos a - totalNanos b ∧
            totalNanos a - totalNanos b ≤ maxTotalNanos) := by
          unfold minTotalNanos maxTotalNanos totalNanos; omega
        simp only [htot_out, ↓reduceIte]
        unfold TimeError.new; rw [b_ok]
        exact ⟨_, rfl⟩
  · have hmin' : b.secs ≠ Pion.I64.sub (-9223372036854775807)#i64 1#i64 := fun h =>
      hmin ((congrArg IScalar.val h).trans i64_min_expr_val)
    rw [if_neg hmin']
    set nb := SignedDuration.mk (Pion.I64.neg b.secs) (Pion.I32.neg b.nanos)
    have hnb_s : nb.secs.val = -b.secs.val := i64_neg_val b.secs hmin
    have hnb_n : nb.nanos.val = -b.nanos.val := i32_neg_val b.nanos (by omega)
    have hnb_valid : ValidSignedDuration nb := by
      unfold ValidSignedDuration; rw [hnb_s, hnb_n]; omega
    have hnb_tot : totalNanos nb = -totalNanos b := by
      unfold totalNanos; rw [hnb_s, hnb_n]; omega
    have hadd := signed_duration_checked_add_sound a nb ⟨han1, han2, hapos, haneg⟩ hnb_valid
    have hsum_eq : totalNanos a + totalNanos nb = totalNanos a - totalNanos b := by omega
    rw [hsum_eq] at hadd
    by_cases htot_in : minTotalNanos ≤ totalNanos a - totalNanos b ∧
        totalNanos a - totalNanos b ≤ maxTotalNanos
    · simp only [htot_in, ↓reduceIte] at hadd ⊢
      rcases hadd with ⟨r, hr_eq, hr_v, hr_t⟩
      exact ⟨r, by rw [hr_eq, b_ok], hr_v, hr_t⟩
    · simp only [htot_in, ↓reduceIte] at hadd ⊢
      rcases hadd with ⟨e, he_eq⟩
      exact ⟨e, by rw [he_eq, b_ok]⟩

/-- `SignedDuration.cmp` agrees exactly with `totalNanos` ordering on all `ValidSignedDuration`s. -/
theorem signed_duration_cmp_spec (a b : SignedDuration)
    (ha : ValidSignedDuration a) (hb : ValidSignedDuration b) :
    SignedDuration.cmp a b = ok (if totalNanos a < totalNanos b then (-1)#i32
                                 else if totalNanos a = totalNanos b then 0#i32
                                 else 1#i32) := by
  rcases ha with ⟨han1, han2, hapos, haneg⟩
  rcases hb with ⟨hbn1, hbn2, hbpos, hbneg⟩
  unfold SignedDuration.cmp totalNanos
  by_cases hs : a.secs = b.secs
  · have hsv : a.secs.val = b.secs.val := congrArg IScalar.val hs
    simp only [hs, ne_eq, not_true_eq_false, ↓reduceIte]
    by_cases hn : a.nanos = b.nanos
    · have hnv : a.nanos.val = b.nanos.val := congrArg IScalar.val hn
      simp only [hn, ne_eq, not_true_eq_false, ↓reduceIte]
      congr 1; split_ifs <;> first | rfl | omega
    · have hnv : a.nanos.val ≠ b.nanos.val := fun h => hn (i32_ext h)
      simp only [hn, ne_eq, not_false_eq_true, ↓reduceIte]
      by_cases hlt : a.nanos.val < b.nanos.val
      · have hlt' : a.nanos < b.nanos := hlt
        simp only [hlt', ↓reduceIte]
        congr 1; split_ifs <;> first | rfl | omega
      · have hlt' : ¬ (a.nanos < b.nanos) := hlt
        simp only [hlt', ↓reduceIte]
        congr 1; split_ifs <;> first | rfl | omega
  · have hsv : a.secs.val ≠ b.secs.val := fun h => hs (i64_ext h)
    simp only [hs, ne_eq, not_false_eq_true, ↓reduceIte]
    by_cases hlt : a.secs.val < b.secs.val
    · have hlt' : a.secs < b.secs := hlt
      have htot : a.secs.val * 1000000000 + a.nanos.val < b.secs.val * 1000000000 + b.nanos.val := by omega
      simp only [hlt', htot, ↓reduceIte]
    · have hlt' : ¬ (a.secs < b.secs) := hlt
      have h1 : ¬ (a.secs.val * 1000000000 + a.nanos.val < b.secs.val * 1000000000 + b.nanos.val) := by omega
      have h2 : ¬ (a.secs.val * 1000000000 + a.nanos.val = b.secs.val * 1000000000 + b.nanos.val) := by omega
      simp only [hlt', h1, h2, ↓reduceIte]

theorem signed_duration_cmp_refl (a : SignedDuration) :
    SignedDuration.cmp a a = ok 0#i32 := by
  unfold SignedDuration.cmp; simp

theorem signed_duration_cmp_antisymm (a b : SignedDuration)
    (ha : ValidSignedDuration a) (hb : ValidSignedDuration b) :
    SignedDuration.cmp a b = ok (-1)#i32 ↔ SignedDuration.cmp b a = ok 1#i32 := by
  rw [signed_duration_cmp_spec a b ha hb, signed_duration_cmp_spec b a hb ha, ok_eq_iff, ok_eq_iff]
  split_ifs <;> first | exact Iff.rfl | decide | omega

theorem signed_duration_cmp_trans_lt (a b c : SignedDuration)
    (ha : ValidSignedDuration a) (hb : ValidSignedDuration b) (hc : ValidSignedDuration c)
    (hab : SignedDuration.cmp a b = ok (-1)#i32) (hbc : SignedDuration.cmp b c = ok (-1)#i32) :
    SignedDuration.cmp a c = ok (-1)#i32 := by
  rw [signed_duration_cmp_spec a b ha hb, ok_eq_iff] at hab
  rw [signed_duration_cmp_spec b c hb hc, ok_eq_iff] at hbc
  rw [signed_duration_cmp_spec a c ha hc, ok_eq_iff]
  split_ifs at hab hbc ⊢ <;> first | rfl | omega | (exfalso; revert hab; decide) | (exfalso; revert hbc; decide)


end TimeProofs
