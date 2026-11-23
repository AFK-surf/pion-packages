import Aeneas
import PionLean
import HttpCache.Types
import HttpCache.Funs

open Aeneas Aeneas.Std Result Pion http_cache

namespace HttpCacheProofs

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private lemma i64_add_val (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val + y.val)
    (hhi : x.val + y.val ≤ 9223372036854775807) :
    (Pion.I64.add x y).val = x.val + y.val := by
  change (x.bv + y.bv).toInt = x.bv.toInt + y.bv.toInt
  rw [BitVec.toInt_add, Int.bmod_def]
  change -9223372036854775808 ≤ x.bv.toInt + y.bv.toInt at hlo
  change x.bv.toInt + y.bv.toInt ≤ 9223372036854775807 at hhi
  omega

private lemma i64_sub_val (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val - y.val)
    (hhi : x.val - y.val ≤ 9223372036854775807) :
    (Pion.I64.sub x y).val = x.val - y.val := by
  change (x.bv - y.bv).toInt = x.bv.toInt - y.bv.toInt
  rw [BitVec.toInt_sub, Int.bmod_def]
  change -9223372036854775808 ≤ x.bv.toInt - y.bv.toInt at hlo
  change x.bv.toInt - y.bv.toInt ≤ 9223372036854775807 at hhi
  omega

private lemma i64_val_2147483648 : (2147483648#i64 : Std.I64).val = 2147483648 := by
  change (BitVec.ofInt 64 2147483648).toInt = 2147483648
  rw [BitVec.toInt_ofInt, Int.bmod_def]; omega

private lemma i64_val_0 : (0#i64 : Std.I64).val = 0 := rfl

private lemma i64_val_max : (9223372036854775807#i64 : Std.I64).val = 9223372036854775807 := by
  change (BitVec.ofInt 64 9223372036854775807).toInt = 9223372036854775807
  rw [BitVec.toInt_ofInt, Int.bmod_def]; omega

private lemma i64_bounds (x : Std.I64) :
    -9223372036854775808 ≤ x.val ∧ x.val ≤ 9223372036854775807 := by
  have h := x.hBounds
  change -(2 ^ 63 : Int) ≤ x.val ∧ x.val < 2 ^ 63 at h
  omega

private lemma i64_lt_iff (x y : Std.I64) : (x < y) ↔ (x.val < y.val) := Iff.rfl
private lemma i64_le_iff (x y : Std.I64) : (x ≤ y) ↔ (x.val ≤ y.val) := Iff.rfl

/-- Theorem 1: `clamped_add_i64` computes `min (a + b) 2^31` without overflow for non-negative `a` and `0 ≤ b ≤ 2^31`. -/
theorem clamped_add_i64_exact (a b : Std.I64)
    (ha : 0 ≤ a.val) (hb0 : 0 ≤ b.val) (hbmax : b.val ≤ 2147483648) :
    ∃ r : Std.I64, clamped_add_i64 a b = ok r ∧ r.val = min (a.val + b.val) 2147483648 := by
  unfold clamped_add_i64
  set s := Pion.I64.sub 2147483648#i64 b
  have hsub : s.val = 2147483648 - b.val := by
    have hlo : -9223372036854775808 ≤ (2147483648#i64 : Std.I64).val - b.val := by rw [i64_val_2147483648]; linarith only [hb0, hbmax]
    have hhi : (2147483648#i64 : Std.I64).val - b.val ≤ 9223372036854775807 := by rw [i64_val_2147483648]; linarith only [hb0, hbmax]
    rw [i64_sub_val 2147483648#i64 b hlo hhi, i64_val_2147483648]
  by_cases hcond : ((decide (b > 0#i64)) && (decide (a > s))) = true
  · simp only [hcond, ↓reduceIte]
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hcond
    have h2 : s.val < a.val := (i64_lt_iff s a).mp hcond.2
    rw [hsub] at h2
    refine ⟨2147483648#i64, rfl, ?_⟩
    rw [i64_val_2147483648]
    symm; exact min_eq_right (by linarith only [h2])
  · have hcf : ((decide (b > 0#i64)) && (decide (a > s))) = false :=
      Bool.eq_false_iff.mpr hcond
    simp only [hcf, Bool.false_eq_true, ↓reduceIte]
    clear hcf
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hcond
    have ha_le : a.val ≤ 9223372036854775807 := (i64_bounds a).2
    have hab : a.val + b.val ≤ 9223372036854775807 := by
      by_cases hbpos : b.val > 0
      · have hnot : ¬ (2147483648 - b.val < a.val) := fun h =>
          hcond ⟨(i64_lt_iff 0#i64 b).mpr (by rw [i64_val_0]; exact hbpos),
                 (i64_lt_iff s a).mpr (by rw [hsub]; exact h)⟩
        linarith only [hnot]
      · linarith only [hb0, hbpos, ha_le]
    clear hcond hsub s
    set sum := Pion.I64.add a b
    have hsum : sum.val = a.val + b.val := i64_add_val a b (by linarith only [ha, hb0]) hab
    by_cases hgt : sum > 2147483648#i64
    · simp only [hgt, ↓reduceIte]
      have hgt' : 2147483648 < sum.val := by
        have := (i64_lt_iff 2147483648#i64 sum).mp hgt
        rw [i64_val_2147483648] at this; exact this
      refine ⟨2147483648#i64, rfl, ?_⟩
      rw [i64_val_2147483648]
      symm; exact min_eq_right (by linarith only [hgt', hsum])
    · simp only [hgt, ↓reduceIte]
      have hgt' : ¬ (2147483648 < sum.val) := fun h =>
        hgt ((i64_lt_iff 2147483648#i64 sum).mpr (by rw [i64_val_2147483648]; exact h))
      have hnotlt : ¬ (sum < 0#i64) := by
        intro hlt
        have hlt' := (i64_lt_iff sum 0#i64).mp hlt
        rw [i64_val_0] at hlt'; linarith only [ha, hb0, hsum, hlt']
      simp only [hnotlt, ↓reduceIte]
      refine ⟨sum, rfl, ?_⟩
      rw [hsum]
      symm; exact min_eq_left (by linarith only [hgt', hsum])

/-- Theorem 2: `clamped_add_i64` always lands in RFC 9111 §1.2.2 `[0, 2^31]`. -/
theorem clamped_add_i64_bounds (a b : Std.I64)
    (ha : 0 ≤ a.val) (hb0 : 0 ≤ b.val) (hbmax : b.val ≤ 2147483648) :
    ∃ r : Std.I64, clamped_add_i64 a b = ok r ∧ 0 ≤ r.val ∧ r.val ≤ 2147483648 := by
  obtain ⟨r, hr, hval⟩ := clamped_add_i64_exact a b ha hb0 hbmax
  refine ⟨r, hr, ?_, ?_⟩
  · rw [hval]; exact le_min (by linarith only [ha, hb0]) (by linarith only [])
  · rw [hval]; exact min_le_right _ _

/-- Theorem 3: `clamped_add_i64` is monotonic in both arguments on `[0, 2^31]`. -/
theorem clamped_add_i64_mono (a1 a2 b1 b2 : Std.I64)
    (ha1 : 0 ≤ a1.val) (ha : a1.val ≤ a2.val)
    (hb1 : 0 ≤ b1.val) (hb : b1.val ≤ b2.val) (hb2max : b2.val ≤ 2147483648) :
    ∃ r1 r2 : Std.I64, clamped_add_i64 a1 b1 = ok r1 ∧ clamped_add_i64 a2 b2 = ok r2 ∧ r1.val ≤ r2.val := by
  obtain ⟨r1, hr1, hv1⟩ := clamped_add_i64_exact a1 b1 ha1 hb1 (by linarith only [hb, hb2max])
  obtain ⟨r2, hr2, hv2⟩ := clamped_add_i64_exact a2 b2 (by linarith only [ha1, ha]) (by linarith only [hb1, hb]) hb2max
  refine ⟨r1, r2, hr1, hr2, ?_⟩
  rw [hv1, hv2]
  exact min_le_min (by linarith only [ha, hb]) (le_refl _)

/-- Theorem 4: `clamped_sub_i64` returns `0` whenever `hi ≤ lo`. -/
theorem clamped_sub_i64_le_zero (hi lo : Std.I64) (hle : hi.val ≤ lo.val) :
    clamped_sub_i64 hi lo = ok 0#i64 := by
  unfold clamped_sub_i64
  have hc : hi ≤ lo := (i64_le_iff hi lo).mpr hle
  simp only [hc, ↓reduceIte]

/-- Theorem 5: `clamped_sub_i64` computes exact overflow-free `min (hi - lo) 2^31` across ALL `Int64` pairs with `lo ≤ hi`. -/
theorem clamped_sub_i64_exact (hi lo : Std.I64) (hle : lo.val ≤ hi.val) :
    ∃ r : Std.I64, clamped_sub_i64 hi lo = ok r ∧ r.val = min (hi.val - lo.val) 2147483648 := by
  unfold clamped_sub_i64
  have hlo_b := i64_bounds lo
  have hhi_b := i64_bounds hi
  by_cases h1 : hi ≤ lo
  · simp only [h1, ↓reduceIte]
    have h1' : hi.val ≤ lo.val := (i64_le_iff hi lo).mp h1
    refine ⟨0#i64, rfl, ?_⟩
    rw [i64_val_0]
    have h0 : hi.val - lo.val = 0 := by linarith only [hle, h1']
    rw [h0]
    symm; exact min_eq_left (by linarith only [])
  · simp only [h1, ↓reduceIte]
    clear h1
    by_cases h2 : ((decide (lo < 0#i64)) && (decide (hi > (Pion.I64.add 9223372036854775807#i64 lo)))) = true
    · simp only [h2, ↓reduceIte]
      simp only [Bool.and_eq_true, decide_eq_true_eq] at h2
      have hloneg : lo.val < 0 := by
        have := (i64_lt_iff lo 0#i64).mp h2.1
        rw [i64_val_0] at this; exact this
      have hadd : (Pion.I64.add 9223372036854775807#i64 lo).val = 9223372036854775807 + lo.val := by
        have hlo' : -9223372036854775808 ≤ (9223372036854775807#i64 : Std.I64).val + lo.val := by rw [i64_val_max]; linarith only [hlo_b.1, hloneg]
        have hhi' : (9223372036854775807#i64 : Std.I64).val + lo.val ≤ 9223372036854775807 := by rw [i64_val_max]; linarith only [hlo_b.2, hloneg]
        rw [i64_add_val 9223372036854775807#i64 lo hlo' hhi', i64_val_max]
      have hhiov : 9223372036854775807 + lo.val < hi.val := by
        have := (i64_lt_iff (Pion.I64.add 9223372036854775807#i64 lo) hi).mp h2.2
        rw [hadd] at this; exact this
      refine ⟨2147483648#i64, rfl, ?_⟩
      rw [i64_val_2147483648]
      symm; exact min_eq_right (by linarith only [hhiov])
    · have h2f : ((decide (lo < 0#i64)) && (decide (hi > (Pion.I64.add 9223372036854775807#i64 lo)))) = false :=
        Bool.eq_false_iff.mpr h2
      simp only [h2f, Bool.false_eq_true, ↓reduceIte]
      clear h2f
      simp only [Bool.and_eq_true, decide_eq_true_eq] at h2
      have hsub_le : hi.val - lo.val ≤ 9223372036854775807 := by
        by_cases hloneg : lo.val < 0
        · have hadd : (Pion.I64.add 9223372036854775807#i64 lo).val = 9223372036854775807 + lo.val := by
            have hlo' : -9223372036854775808 ≤ (9223372036854775807#i64 : Std.I64).val + lo.val := by rw [i64_val_max]; linarith only [hlo_b.1, hloneg]
            have hhi' : (9223372036854775807#i64 : Std.I64).val + lo.val ≤ 9223372036854775807 := by rw [i64_val_max]; linarith only [hlo_b.2, hloneg]
            rw [i64_add_val 9223372036854775807#i64 lo hlo' hhi', i64_val_max]
          have hnot : ¬ (9223372036854775807 + lo.val < hi.val) := fun h =>
            h2 ⟨(i64_lt_iff lo 0#i64).mpr (by rw [i64_val_0]; exact hloneg),
                (i64_lt_iff (Pion.I64.add 9223372036854775807#i64 lo) hi).mpr (by rw [hadd]; exact h)⟩
          linarith only [hnot]
        · linarith only [hhi_b.2, hloneg]
      clear h2
      set diff := Pion.I64.sub hi lo
      have hdiff : diff.val = hi.val - lo.val := i64_sub_val hi lo (by linarith only [hle]) hsub_le
      by_cases hcap : diff > 2147483648#i64
      · simp only [hcap, ↓reduceIte]
        have hcap' : 2147483648 < diff.val := by
          have := (i64_lt_iff 2147483648#i64 diff).mp hcap
          rw [i64_val_2147483648] at this; exact this
        refine ⟨2147483648#i64, rfl, ?_⟩
        rw [i64_val_2147483648]
        symm; exact min_eq_right (by linarith only [hcap', hdiff])
      · simp only [hcap, ↓reduceIte]
        have hcap' : ¬ (2147483648 < diff.val) := fun h =>
          hcap ((i64_lt_iff 2147483648#i64 diff).mpr (by rw [i64_val_2147483648]; exact h))
        refine ⟨diff, rfl, ?_⟩
        rw [hdiff]
        symm; exact min_eq_left (by linarith only [hcap', hdiff])

/-- Theorem 6: `clamped_sub_i64` is total and always returns a value in `[0, 2^31]` for ALL `Int64` inputs. -/
theorem clamped_sub_i64_bounds (hi lo : Std.I64) :
    ∃ r : Std.I64, clamped_sub_i64 hi lo = ok r ∧ 0 ≤ r.val ∧ r.val ≤ 2147483648 := by
  by_cases hle : hi.val ≤ lo.val
  · refine ⟨0#i64, clamped_sub_i64_le_zero hi lo hle, ?_, ?_⟩
    · rw [i64_val_0]
    · rw [i64_val_0]; linarith only []
  · obtain ⟨r, hr, hval⟩ := clamped_sub_i64_exact hi lo (by linarith only [hle])
    refine ⟨r, hr, ?_, ?_⟩
    · rw [hval]; exact le_min (by linarith only [hle]) (by linarith only [])
    · rw [hval]; exact min_le_right _ _

/-- Theorem 7: `clamped_sub_i64` is monotonic in `hi` over all `Int64` timestamps. -/
theorem clamped_sub_i64_mono_hi (hi1 hi2 lo : Std.I64) (hle : hi1.val ≤ hi2.val) :
    ∃ r1 r2 : Std.I64, clamped_sub_i64 hi1 lo = ok r1 ∧ clamped_sub_i64 hi2 lo = ok r2 ∧ r1.val ≤ r2.val := by
  by_cases c1 : hi1.val ≤ lo.val
  · obtain ⟨r2, hr2, h2lo, _⟩ := clamped_sub_i64_bounds hi2 lo
    refine ⟨0#i64, r2, clamped_sub_i64_le_zero hi1 lo c1, hr2, ?_⟩
    rw [i64_val_0]; exact h2lo
  · obtain ⟨r1, hr1, hv1⟩ := clamped_sub_i64_exact hi1 lo (by linarith only [c1])
    obtain ⟨r2, hr2, hv2⟩ := clamped_sub_i64_exact hi2 lo (by linarith only [c1, hle])
    refine ⟨r1, r2, hr1, hr2, ?_⟩
    rw [hv1, hv2]
    exact min_le_min (by linarith only [hle]) (le_refl _)

/-- Theorem 8: `compute_initial_age_core` satisfies exact RFC 9111 §4.2.3 formula `max apparent_age (min (age_value + response_delay) 2^31)`. -/
theorem compute_initial_age_core_exact (apparent_age age_value request_time response_time : Std.I64)
    (hage0 : 0 ≤ age_value.val) :
    ∃ (delay corr res : Std.I64),
      clamped_sub_i64 response_time request_time = ok delay ∧
      clamped_add_i64 age_value delay = ok corr ∧
      compute_initial_age_core apparent_age age_value request_time response_time = ok res ∧
      res.val = max apparent_age.val corr.val := by
  obtain ⟨delay, hdelay, hd0, hdmax⟩ := clamped_sub_i64_bounds response_time request_time
  obtain ⟨corr, hcorr, _⟩ := clamped_add_i64_exact age_value delay hage0 hd0 hdmax
  unfold compute_initial_age_core
  rw [hdelay, result_bind_ok, hcorr, result_bind_ok]
  by_cases hgt : apparent_age > corr
  · simp only [hgt, ↓reduceIte]
    have : corr.val < apparent_age.val := (i64_lt_iff corr apparent_age).mp hgt
    refine ⟨delay, corr, apparent_age, rfl, hcorr, rfl, ?_⟩
    symm; exact max_eq_left (by linarith only [this])
  · simp only [hgt, ↓reduceIte]
    have : ¬ (corr.val < apparent_age.val) := fun h => hgt ((i64_lt_iff corr apparent_age).mpr h)
    refine ⟨delay, corr, corr, rfl, hcorr, rfl, ?_⟩
    symm; exact max_eq_right (by linarith only [this])

/-- Theorem 9: `compute_initial_age_core` stays within `[0, 2^31]` and dominates both `apparent_age` and `age_value`. -/
theorem compute_initial_age_core_bounds (apparent_age age_value request_time response_time : Std.I64)
    (happ0 : 0 ≤ apparent_age.val) (happmax : apparent_age.val ≤ 2147483648)
    (hage0 : 0 ≤ age_value.val) (hagemax : age_value.val ≤ 2147483648) :
    ∃ res : Std.I64,
      compute_initial_age_core apparent_age age_value request_time response_time = ok res ∧
      0 ≤ res.val ∧ res.val ≤ 2147483648 ∧
      apparent_age.val ≤ res.val ∧ age_value.val ≤ res.val := by
  obtain ⟨delay, corr, res, hdelay, hcorr, hres, hval⟩ :=
    compute_initial_age_core_exact apparent_age age_value request_time response_time hage0
  obtain ⟨d', hd', hd0, hdmax⟩ := clamped_sub_i64_bounds response_time request_time
  rw [hdelay] at hd'; simp only [ok.injEq] at hd'; subst hd'
  obtain ⟨c', hc', hcval⟩ := clamped_add_i64_exact age_value delay hage0 hd0 hdmax
  rw [hcorr] at hc'; simp only [ok.injEq] at hc'; subst hc'
  have hcorr_lo : age_value.val ≤ corr.val := by rw [hcval]; exact le_min (by linarith only [hd0]) hagemax
  have hcorr_hi : corr.val ≤ 2147483648 := by rw [hcval]; exact min_le_right _ _
  have hres_app : apparent_age.val ≤ res.val := by rw [hval]; exact le_max_left _ _
  have hres_corr : corr.val ≤ res.val := by rw [hval]; exact le_max_right _ _
  have hres_hi : res.val ≤ 2147483648 := by rw [hval]; exact max_le happmax hcorr_hi
  exact ⟨res, hres, by linarith only [happ0, hres_app], hres_hi, hres_app, by linarith only [hcorr_lo, hres_corr]⟩

/-- Theorem 10: `compute_current_age_core` stays within `[0, 2^31]` and never drops below `initial_age`. -/
theorem compute_current_age_core_bounds (initial_age response_time now : Std.I64)
    (hinit0 : 0 ≤ initial_age.val) (hinitmax : initial_age.val ≤ 2147483648) :
    ∃ age : Std.I64,
      compute_current_age_core initial_age response_time now = ok age ∧
      initial_age.val ≤ age.val ∧ age.val ≤ 2147483648 := by
  obtain ⟨res_t, hres, hr0, hrmax⟩ := clamped_sub_i64_bounds now response_time
  obtain ⟨age, hage, hagev⟩ := clamped_add_i64_exact initial_age res_t hinit0 hr0 hrmax
  unfold compute_current_age_core
  rw [hres, result_bind_ok, hage, result_bind_ok]
  refine ⟨age, rfl, ?_, ?_⟩
  · rw [hagev]; exact le_min (by linarith only [hr0]) hinitmax
  · rw [hagev]; exact min_le_right _ _

/-- Theorem 11: RFC 9111 §4.2.3 current age is monotonically non-decreasing in wall-clock timestamp `now`. -/
theorem compute_current_age_core_mono_now (initial_age response_time now1 now2 : Std.I64)
    (hinit0 : 0 ≤ initial_age.val) (hnow : now1.val ≤ now2.val) :
    ∃ age1 age2 : Std.I64,
      compute_current_age_core initial_age response_time now1 = ok age1 ∧
      compute_current_age_core initial_age response_time now2 = ok age2 ∧
      age1.val ≤ age2.val := by
  obtain ⟨r1, r2, hr1, hr2, hrle⟩ := clamped_sub_i64_mono_hi now1 now2 response_time hnow
  obtain ⟨r1', hr1', hr10, _⟩ := clamped_sub_i64_bounds now1 response_time
  rw [hr1] at hr1'; simp only [ok.injEq] at hr1'; subst hr1'
  obtain ⟨r2', hr2', _, hr2max⟩ := clamped_sub_i64_bounds now2 response_time
  rw [hr2] at hr2'; simp only [ok.injEq] at hr2'; subst hr2'
  obtain ⟨a1, a2, ha1, ha2, hale⟩ := clamped_add_i64_mono initial_age initial_age r1 r2 hinit0 (le_refl _) hr10 hrle hr2max
  unfold compute_current_age_core
  rw [hr1, hr2, result_bind_ok, result_bind_ok, ha1, ha2, result_bind_ok, result_bind_ok]
  exact ⟨a1, a2, rfl, rfl, hale⟩

/-- Theorem 12: At or before `response_time`, `compute_current_age_core` equals `initial_age` exactly. -/
theorem compute_current_age_core_at_response_time (initial_age response_time now : Std.I64)
    (hinit0 : 0 ≤ initial_age.val) (hinitmax : initial_age.val ≤ 2147483648)
    (hnow : now.val ≤ response_time.val) :
    compute_current_age_core initial_age response_time now = ok initial_age := by
  unfold compute_current_age_core
  rw [clamped_sub_i64_le_zero now response_time hnow, result_bind_ok]
  obtain ⟨age, hage, hagev⟩ := clamped_add_i64_exact initial_age 0#i64 hinit0 (by rw [i64_val_0]) (by rw [i64_val_0]; linarith only [])
  rw [i64_val_0, add_zero, min_eq_left hinitmax] at hagev
  have heq : age = initial_age := IScalar.eq_of_val_eq hagev
  rw [hage, result_bind_ok, heq]

end HttpCacheProofs
