import CronProofs.CalendarBase

open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 400000
set_option linter.unusedSimpArgs false

namespace CronProofs

open cron

private theorem i64_719468_val : (719468#i64).val = 719468 := by
  change (BitVec.ofInt 64 719468).toInt = 719468; rw [BitVec.toInt_ofInt]; norm_num

private theorem i64_146097_val : (146097#i64).val = 146097 := by
  change (BitVec.ofInt 64 146097).toInt = 146097; rw [BitVec.toInt_ofInt]; norm_num

private theorem i64_86400_val : (86400#i64).val = 86400 := by
  change (BitVec.ofInt 64 86400).toInt = 86400; rw [BitVec.toInt_ofInt]; norm_num

private theorem i64_86399_val : (86399#i64).val = 86399 := by
  change (BitVec.ofInt 64 86399).toInt = 86399; rw [BitVec.toInt_ofInt]; norm_num

/-- `civil_from_days` computes `civilFromDaysMath` without trap or overflow on `[-719162, 2932896]`. -/
theorem civil_from_days_eq (z_in : Std.I64)
    (hz1 : -719162 ≤ z_in.val) (hz2 : z_in.val ≤ 2932896) :
    ∃ yr m d : Std.I32, civil_from_days z_in = ok (yr, m, d) ∧
      (yr.val, m.val, d.val) = civilFromDaysMath z_in.val := by
  unfold civil_from_days civilFromDaysMath
  set z : Std.I64 := Pion.I64.add z_in 719468#i64
  have hz_val : z.val = z_in.val + 719468 := by
    dsimp only [z]; rw [i64_add_val]; all_goals (rw [i64_719468_val]; try omega)
  have hz_b : 306 ≤ z.val ∧ z.val ≤ 3652364 := by omega
  have hz_ge0 : z >= 0#i64 := by show (0 : Int) ≤ z.val; omega
  obtain ⟨era, hera, hera_val⟩ := i64_div_pos_ok z 146097#i64 (by rw [i64_146097_val]; omega)
  have hera_step :
      (if Pion.I64.add z_in 719468#i64 >= 0#i64 then (do let __t ← Pion.I64.div (Pion.I64.add z_in 719468#i64) 146097#i64; ok __t)
       else (do let __t_1 ← Pion.I64.div (Pion.I64.sub (Pion.I64.add z_in 719468#i64) 146096#i64) 146097#i64; ok __t_1)) = ok era := by
    change (if z >= 0#i64 then (do let __t ← Pion.I64.div z 146097#i64; ok __t)
            else (do let __t_1 ← Pion.I64.div (Pion.I64.sub z 146096#i64) 146097#i64; ok __t_1)) = ok era
    rw [if_pos hz_ge0, hera, b_ok]
  dsimp only
  rw [hera_step, b_ok]
  have hera_ediv : era.val = z.val / 146097 := by
    rw [hera_val, i64_146097_val]; exact tdiv_eq_ediv_of_nonneg _ 146097 (by omega) (by omega)
  have hera_b : 0 ≤ era.val ∧ era.val ≤ 24 := by omega
  have h_era146 : (Pion.I64.mul era 146097#i64).val = era.val * 146097 := by
    rw [i64_mul_val]; all_goals (rw [i64_146097_val]; try omega)
  have h_zsub : (Pion.I64.sub z (Pion.I64.mul era 146097#i64)).val = z.val - era.val * 146097 := by
    rw [i64_sub_val, h_era146] <;> omega
  set doe : Std.I32 := Pion.I64.to_int (Pion.I64.sub z (Pion.I64.mul era 146097#i64))
  have hdoe_val : doe.val = z.val - era.val * 146097 := by
    dsimp only [doe]; rw [i64_to_i32_val, h_zsub] <;> omega
  have hdoe_b : 0 ≤ doe.val ∧ doe.val ≤ 146096 := by omega
  obtain ⟨t3, ht3, ht3_val⟩ := i32_div_pos_ok doe 1460#i32 (by change (0 : Int) < (BitVec.ofInt 32 1460).toInt; rw [BitVec.toInt_ofInt]; norm_num)
  rw [ht3, b_ok]
  have ht3_ediv : t3.val = doe.val / 1460 := by
    rw [ht3_val]; exact tdiv_eq_ediv_of_nonneg _ 1460 hdoe_b.1 (by omega)
  have ht3_b : 0 ≤ t3.val ∧ t3.val ≤ 100 := by
    rw [ht3_ediv]; clear * - hdoe_b; omega
  obtain ⟨t4, ht4, ht4_val⟩ := i32_div_pos_ok doe 36524#i32 (by change (0 : Int) < (BitVec.ofInt 32 36524).toInt; rw [BitVec.toInt_ofInt]; norm_num)
  rw [ht4, b_ok]
  have ht4_ediv : t4.val = doe.val / 36524 := by
    rw [ht4_val]; exact tdiv_eq_ediv_of_nonneg _ 36524 hdoe_b.1 (by omega)
  have ht4_b : 0 ≤ t4.val ∧ t4.val ≤ 4 := by
    rw [ht4_ediv]; clear * - hdoe_b; omega
  obtain ⟨t5, ht5, ht5_val⟩ := i32_div_pos_ok doe 146096#i32 (by change (0 : Int) < (BitVec.ofInt 32 146096).toInt; rw [BitVec.toInt_ofInt]; norm_num)
  rw [ht5, b_ok]
  have ht5_ediv : t5.val = doe.val / 146096 := by
    rw [ht5_val]; exact tdiv_eq_ediv_of_nonneg _ 146096 hdoe_b.1 (by omega)
  have ht5_b : 0 ≤ t5.val ∧ t5.val ≤ 1 := by
    rw [ht5_ediv]; clear * - hdoe_b; omega
  have hn1 : (Pion.I32.sub doe t3).val = doe.val - t3.val := by
    rw [i32_sub_val] <;> (clear * - hdoe_b ht3_b; omega)
  have hn2 : (Pion.I32.add (Pion.I32.sub doe t3) t4).val = doe.val - t3.val + t4.val := by
    rw [i32_add_val, hn1] <;> (clear * - hdoe_b ht3_b ht4_b hn1; omega)
  set num : Std.I32 := Pion.I32.sub (Pion.I32.add (Pion.I32.sub doe t3) t4) t5
  have hnum_val : num.val = doe.val - t3.val + t4.val - t5.val := by
    dsimp only [num]; rw [i32_sub_val, hn2] <;> (clear * - hdoe_b ht3_b ht4_b ht5_b hn2; omega)
  have hnum_ge0 : 0 ≤ num.val := by
    clear * - hdoe_b ht3_ediv ht4_ediv ht5_ediv hnum_val ht3_b ht4_b ht5_b
    have h1 : doe.val / 1460 ≤ doe.val := by omega
    have h2 : t5.val ≤ doe.val - t3.val + t4.val := by
      by_cases hd0 : doe.val = 0
      · have : t3.val = 0 := by rw [ht3_ediv, hd0]; decide
        have : t5.val = 0 := by rw [ht5_ediv, hd0]; decide
        omega
      · have : doe.val / 1460 ≤ doe.val - 1 := by omega
        omega
    omega
  obtain ⟨yoe, hyoe, hyoe_val⟩ := i32_div_pos_ok num 365#i32 (by change (0 : Int) < (BitVec.ofInt 32 365).toInt; rw [BitVec.toInt_ofInt]; norm_num)
  rw [hyoe, b_ok]
  have hyoe_ediv : yoe.val = num.val / 365 := by
    rw [hyoe_val]; exact tdiv_eq_ediv_of_nonneg _ 365 hnum_ge0 (by omega)
  have hyoe_eq_math : yoe.val = yoeOfDoe doe.val := by
    rw [hyoe_ediv, hnum_val, ht3_ediv, ht4_ediv, ht5_ediv]; rfl
  clear ht3_val ht3_ediv ht3_b ht4_val ht4_ediv ht4_b ht5_val ht5_ediv ht5_b hn1 hn2 hnum_val hnum_ge0 hyoe_val hyoe_ediv
  have hb_doe := yoeOfDoe_bounds doe.val hdoe_b.1 hdoe_b.2
  dsimp only at hb_doe
  rw [← hyoe_eq_math] at hb_doe
  have hyoe_b : 0 ≤ yoe.val ∧ yoe.val ≤ 399 := ⟨hb_doe.1, hb_doe.2.1⟩
  have hera_i32 : (Pion.I64.to_int era).val = era.val := by
    rw [i64_to_i32_val] <;> omega
  have h_era400 : (Pion.I32.mul (Pion.I64.to_int era) 400#i32).val = era.val * 400 := by
    rw [i32_mul_val, hera_i32]; all_goals (have hc : (400#i32).val = 400 := (by change (BitVec.ofInt 32 400).toInt = 400; rw [BitVec.toInt_ofInt]; norm_num); rw [hc]; try omega)
  set y : Std.I32 := Pion.I32.add yoe (Pion.I32.mul (Pion.I64.to_int era) 400#i32)
  have hy_val : y.val = yoe.val + era.val * 400 := by
    dsimp only [y]; rw [i32_add_val, h_era400] <;> omega
  obtain ⟨t7, ht7, ht7_val⟩ := i32_div_pos_ok yoe 4#i32 (by change (0 : Int) < (BitVec.ofInt 32 4).toInt; rw [BitVec.toInt_ofInt]; norm_num)
  rw [ht7, b_ok]
  have ht7_ediv : t7.val = yoe.val / 4 := by
    rw [ht7_val]; exact tdiv_eq_ediv_of_nonneg _ 4 hyoe_b.1 (by omega)
  have ht7_b : 0 ≤ t7.val ∧ t7.val ≤ 99 := by
    rw [ht7_ediv]; clear * - hyoe_b; omega
  obtain ⟨t8, ht8, ht8_val⟩ := i32_div_pos_ok yoe 100#i32 (by change (0 : Int) < (BitVec.ofInt 32 100).toInt; rw [BitVec.toInt_ofInt]; norm_num)
  rw [ht8, b_ok]
  have ht8_ediv : t8.val = yoe.val / 100 := by
    rw [ht8_val]; exact tdiv_eq_ediv_of_nonneg _ 100 hyoe_b.1 (by omega)
  have ht8_b : 0 ≤ t8.val ∧ t8.val ≤ 3 := by
    rw [ht8_ediv]; clear * - hyoe_b; omega
  have h_365y : (Pion.I32.mul 365#i32 yoe).val = 365 * yoe.val := by
    rw [i32_mul_val]; all_goals (have hc : (365#i32).val = 365 := (by change (BitVec.ofInt 32 365).toInt = 365; rw [BitVec.toInt_ofInt]; norm_num); rw [hc]; try omega)
  have h_365a : (Pion.I32.add (Pion.I32.mul 365#i32 yoe) t7).val = 365 * yoe.val + t7.val := by
    rw [i32_add_val, h_365y] <;> omega
  have h_365b : (Pion.I32.sub (Pion.I32.add (Pion.I32.mul 365#i32 yoe) t7) t8).val =
      365 * yoe.val + t7.val - t8.val := by
    rw [i32_sub_val, h_365a] <;> omega
  set doy : Std.I32 := Pion.I32.sub doe (Pion.I32.sub (Pion.I32.add (Pion.I32.mul 365#i32 yoe) t7) t8)
  have hdoy_val : doy.val = doe.val - (365 * yoe.val + yoe.val / 4 - yoe.val / 100) := by
    dsimp only [doy]; rw [i32_sub_val, h_365b, ht7_ediv, ht8_ediv] <;> omega
  have hdoy_b : 0 ≤ doy.val ∧ doy.val ≤ 365 := by
    have h1 := hb_doe.2.2.1
    have h2 := hb_doe.2.2.2
    unfold yoeStart at h1 h2; unfold yoeLen at h2
    clear * - h1 h2 hdoy_val
    split at h2 <;> omega
  have h5doy : (Pion.I32.mul 5#i32 doy).val = 5 * doy.val := by
    rw [i32_mul_val]; all_goals (have hc : (5#i32).val = 5 := (by change (BitVec.ofInt 32 5).toInt = 5; rw [BitVec.toInt_ofInt]; norm_num); rw [hc]; try (clear * - hdoy_b; omega))
  set mp_num : Std.I32 := Pion.I32.add (Pion.I32.mul 5#i32 doy) 2#i32
  have hmp_num : mp_num.val = 5 * doy.val + 2 := by
    dsimp only [mp_num]; rw [i32_add_val, h5doy]; all_goals (have hc : (2#i32).val = 2 := (by change (BitVec.ofInt 32 2).toInt = 2; rw [BitVec.toInt_ofInt]; norm_num); rw [hc]; try (clear * - hdoy_b h5doy; omega))
  obtain ⟨mp, hmp, hmp_val⟩ := i32_div_pos_ok mp_num 153#i32 (by change (0 : Int) < (BitVec.ofInt 32 153).toInt; rw [BitVec.toInt_ofInt]; norm_num)
  rw [hmp, b_ok]
  have hmp_ediv : mp.val = (5 * doy.val + 2) / 153 := by
    rw [hmp_val, hmp_num]; exact tdiv_eq_ediv_of_nonneg _ 153 (by clear * - hdoy_b; omega) (by norm_num)
  have hmp_b : 0 ≤ mp.val ∧ mp.val ≤ 11 := by
    rw [hmp_ediv]; clear * - hdoy_b; omega
  have h153mp : (Pion.I32.mul 153#i32 mp).val = 153 * mp.val := by
    rw [i32_mul_val]; all_goals (have hc : (153#i32).val = 153 := (by change (BitVec.ofInt 32 153).toInt = 153; rw [BitVec.toInt_ofInt]; norm_num); rw [hc]; try (clear * - hmp_b; omega))
  set d_num : Std.I32 := Pion.I32.add (Pion.I32.mul 153#i32 mp) 2#i32
  have hd_num : d_num.val = 153 * mp.val + 2 := by
    dsimp only [d_num]; rw [i32_add_val, h153mp]; all_goals (have hc : (2#i32).val = 2 := (by change (BitVec.ofInt 32 2).toInt = 2; rw [BitVec.toInt_ofInt]; norm_num); rw [hc]; try (clear * - hmp_b h153mp; omega))
  obtain ⟨t10, ht10, ht10_val⟩ := i32_div_pos_ok d_num 5#i32 (by change (0 : Int) < (BitVec.ofInt 32 5).toInt; rw [BitVec.toInt_ofInt]; norm_num)
  rw [ht10, b_ok]
  have ht10_ediv : t10.val = (153 * mp.val + 2) / 5 := by
    rw [ht10_val, hd_num]; exact tdiv_eq_ediv_of_nonneg _ 5 (by clear * - hmp_b; omega) (by norm_num)
  have hd_sub : (Pion.I32.sub doy t10).val = doy.val - (153 * mp.val + 2) / 5 := by
    rw [i32_sub_val, ht10_ediv] <;> (clear * - hdoy_b hmp_b ht10_ediv; omega)
  set d : Std.I32 := Pion.I32.add (Pion.I32.sub doy t10) 1#i32
  have hd_val : d.val = doy.val - (153 * mp.val + 2) / 5 + 1 := by
    dsimp only [d]; rw [i32_add_val, hd_sub]; all_goals (have hc : (1#i32).val = 1 := (by change (BitVec.ofInt 32 1).toInt = 1; rw [BitVec.toInt_ofInt]; norm_num); rw [hc]; try (clear * - hdoy_b hmp_b hd_sub; omega))
  set m : Std.I32 := if mp < 10#i32 then Pion.I32.add mp 3#i32 else Pion.I32.sub mp 9#i32
  have hm_val : m.val = if mp.val < 10 then mp.val + 3 else mp.val - 9 := by
    dsimp only [m]
    by_cases h : mp.val < 10
    · have h' : mp < 10#i32 := h
      rw [if_pos h', if_pos h, i32_add_val]; all_goals (have hc : (3#i32).val = 3 := (by change (BitVec.ofInt 32 3).toInt = 3; rw [BitVec.toInt_ofInt]; norm_num); rw [hc]; try (clear * - hmp_b; omega))
    · have h' : ¬ (mp < 10#i32) := h
      rw [if_neg h', if_neg h, i32_sub_val]; all_goals (have hc : (9#i32).val = 9 := (by change (BitVec.ofInt 32 9).toInt = 9; rw [BitVec.toInt_ofInt]; norm_num); rw [hc]; try (clear * - hmp_b; omega))
  set yr : Std.I32 := if m <= 2#i32 then Pion.I32.add y 1#i32 else y
  have hyr_val : yr.val = if m.val ≤ 2 then y.val + 1 else y.val := by
    dsimp only [yr]
    by_cases h : m.val ≤ 2
    · have h' : m <= 2#i32 := h
      rw [if_pos h', if_pos h, i32_add_val]; all_goals (have hc : (1#i32).val = 1 := (by change (BitVec.ofInt 32 1).toInt = 1; rw [BitVec.toInt_ofInt]; norm_num); rw [hc]; try (clear * - hy_val hyoe_b hera_b; omega))
    · have h' : ¬ (m <= 2#i32) := h
      rw [if_neg h', if_neg h]
  refine ⟨yr, m, d, rfl, ?_⟩
  have hyoe_unf : yoe.val = (doe.val - doe.val / 1460 + doe.val / 36524 - doe.val / 146096) / 365 := hyoe_eq_math
  refine Prod.ext ?_ (Prod.ext ?_ ?_)
  · rw [hyr_val, hm_val, hy_val, hmp_ediv, hdoy_val, hyoe_unf, hdoe_val, hera_ediv, hz_val]
  · rw [hm_val, hmp_ediv, hdoy_val, hyoe_unf, hdoe_val, hera_ediv, hz_val]
  · rw [hd_val, hmp_ediv, hdoy_val, hyoe_unf, hdoe_val, hera_ediv, hz_val]

theorem civil_days_roundtrip_math (year month day : Int)
    (hy1 : 1 ≤ year) (hy2 : year ≤ 9999)
    (hm1 : 1 ≤ month) (hm2 : month ≤ 12)
    (hd1 : 1 ≤ day) (hd2 : day ≤ daysInMonthMath year month) :
    civilFromDaysMath (daysFromCivilMath year month day) = (year, month, day) := by
  unfold civilFromDaysMath daysFromCivilMath
  dsimp only
  let y := if month ≤ 2 then year - 1 else year
  let era := y / 400
  let yoe := y - era * 400
  let m_adj := if month > 2 then month - 3 else month + 9
  let doy := (153 * m_adj + 2) / 5 + day - 1
  have hyoe_b : 0 ≤ yoe ∧ yoe ≤ 399 := by omega
  have hdoy_len : 0 ≤ doy ∧ doy < yoeLen yoe := by
    have hm_c : month = 1 ∨ month = 2 ∨ month = 3 ∨ month = 4 ∨ month = 5 ∨ month = 6 ∨
        month = 7 ∨ month = 8 ∨ month = 9 ∨ month = 10 ∨ month = 11 ∨ month = 12 := by omega
    rcases hm_c with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl
    · unfold daysInMonthMath at hd2; rcases yoeLen_cases yoe with h | h <;> simp at hd2 <;> omega
    · unfold daysInMonthMath at hd2
      have hy_eq : year = yoe + era * 400 + 1 := by omega
      rw [hy_eq, leap_iff_yoe era yoe hyoe_b.1 hyoe_b.2] at hd2
      simp only [beq_self_eq_true, ↓reduceIte] at hd2
      rcases yoeLen_cases yoe with h | h <;> simp [h] at hd2 <;> omega
    · unfold daysInMonthMath at hd2; rcases yoeLen_cases yoe with h | h <;> simp at hd2 <;> omega
    · unfold daysInMonthMath at hd2; rcases yoeLen_cases yoe with h | h <;> simp at hd2 <;> omega
    · unfold daysInMonthMath at hd2; rcases yoeLen_cases yoe with h | h <;> simp at hd2 <;> omega
    · unfold daysInMonthMath at hd2; rcases yoeLen_cases yoe with h | h <;> simp at hd2 <;> omega
    · unfold daysInMonthMath at hd2; rcases yoeLen_cases yoe with h | h <;> simp at hd2 <;> omega
    · unfold daysInMonthMath at hd2; rcases yoeLen_cases yoe with h | h <;> simp at hd2 <;> omega
    · unfold daysInMonthMath at hd2; rcases yoeLen_cases yoe with h | h <;> simp at hd2 <;> omega
    · unfold daysInMonthMath at hd2; rcases yoeLen_cases yoe with h | h <;> simp at hd2 <;> omega
    · unfold daysInMonthMath at hd2; rcases yoeLen_cases yoe with h | h <;> simp at hd2 <;> omega
    · unfold daysInMonthMath at hd2; rcases yoeLen_cases yoe with h | h <;> simp at hd2 <;> omega
  have hdoe_b : 0 ≤ yoeStart yoe + doy ∧ yoeStart yoe + doy ≤ 146096 := by
    unfold yoeStart; rcases yoeLen_cases yoe with h | h <;> omega
  have hz_eq : era * 146097 + (yoe * 365 + yoe / 4 - yoe / 100 + doy) - 719468 + 719468 =
      era * 146097 + (yoeStart yoe + doy) := by unfold yoeStart; omega
  have hera_back : (era * 146097 + (yoeStart yoe + doy)) / 146097 = era := by omega
  have hdoe_back : era * 146097 + (yoeStart yoe + doy) - era * 146097 = yoeStart yoe + doy := by omega
  have hyoe_back : yoeOfDoe (yoeStart yoe + doy) = yoe :=
    yoeOfDoe_yoeStart yoe doy hyoe_b.1 hyoe_b.2 hdoy_len.1 hdoy_len.2
  change (let z := era * 146097 + (yoe * 365 + yoe / 4 - yoe / 100 + doy) - 719468 + 719468;
          let era' := z / 146097;
          let doe' := z - era' * 146097;
          let yoe' := yoeOfDoe doe';
          let y' := yoe' + era' * 400;
          let doy' := doe' - yoeStart yoe';
          let mp := (5 * doy' + 2) / 153;
          let d' := doy' - (153 * mp + 2) / 5 + 1;
          let m' := if mp < 10 then mp + 3 else mp - 9;
          let yr' := if m' ≤ 2 then y' + 1 else y';
          (yr', m', d')) = (year, month, day)
  dsimp only
  rw [hz_eq, hera_back, hdoe_back, hyoe_back]
  have hdoy_back : yoeStart yoe + doy - yoeStart yoe = doy := by omega
  rw [hdoy_back]
  have hmp_back : (5 * doy + 2) / 153 = m_adj := by
    have hm_c : month = 1 ∨ month = 2 ∨ month = 3 ∨ month = 4 ∨ month = 5 ∨ month = 6 ∨
        month = 7 ∨ month = 8 ∨ month = 9 ∨ month = 10 ∨ month = 11 ∨ month = 12 := by omega
    rcases hm_c with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl
    · unfold daysInMonthMath at hd2; simp at hd2; dsimp only [doy, m_adj]; omega
    · unfold daysInMonthMath at hd2; simp only [beq_self_eq_true, ↓reduceIte] at hd2
      have : day ≤ 29 := by split at hd2 <;> omega
      dsimp only [doy, m_adj]; omega
    · unfold daysInMonthMath at hd2; simp at hd2; dsimp only [doy, m_adj]; omega
    · unfold daysInMonthMath at hd2; simp at hd2; dsimp only [doy, m_adj]; omega
    · unfold daysInMonthMath at hd2; simp at hd2; dsimp only [doy, m_adj]; omega
    · unfold daysInMonthMath at hd2; simp at hd2; dsimp only [doy, m_adj]; omega
    · unfold daysInMonthMath at hd2; simp at hd2; dsimp only [doy, m_adj]; omega
    · unfold daysInMonthMath at hd2; simp at hd2; dsimp only [doy, m_adj]; omega
    · unfold daysInMonthMath at hd2; simp at hd2; dsimp only [doy, m_adj]; omega
    · unfold daysInMonthMath at hd2; simp at hd2; dsimp only [doy, m_adj]; omega
    · unfold daysInMonthMath at hd2; simp at hd2; dsimp only [doy, m_adj]; omega
    · unfold daysInMonthMath at hd2; simp at hd2; dsimp only [doy, m_adj]; omega
  rw [hmp_back]
  have hm_back : (if m_adj < 10 then m_adj + 3 else m_adj - 9) = month := by
    dsimp only [m_adj]; by_cases h : month > 2 <;> simp [h] <;> omega
  simp only [hz_eq, hera_back, hdoe_back, hyoe_back, hdoy_back, hmp_back, hm_back, Prod.mk.injEq]
  refine ⟨?_, ?_⟩
  · dsimp only [yoe, era, y]; by_cases h : month ≤ 2 <;> simp [h] <;> omega
  · exact ⟨trivial, by dsimp only [doy]; ring⟩

theorem days_civil_roundtrip_math (z_in : Int)
    (hz1 : -719162 ≤ z_in) (hz2 : z_in ≤ 2932896) :
    let (yr, m, d) := civilFromDaysMath z_in
    1 ≤ yr ∧ yr ≤ 9999 ∧ 1 ≤ m ∧ m ≤ 12 ∧ 1 ≤ d ∧ d ≤ daysInMonthMath yr m ∧
    daysFromCivilMath yr m d = z_in := by
  unfold civilFromDaysMath
  dsimp only
  let z := z_in + 719468
  let era := z / 146097
  let doe := z - era * 146097
  have hdoe_b : 0 ≤ doe ∧ doe ≤ 146096 := by omega
  have hb := yoeOfDoe_bounds doe hdoe_b.1 hdoe_b.2
  dsimp only at hb
  let yoe := yoeOfDoe doe
  have hyoe_b : 0 ≤ yoe ∧ yoe ≤ 399 := ⟨hb.1, hb.2.1⟩
  let doy := doe - yoeStart yoe
  have hdoy_len : 0 ≤ doy ∧ doy < yoeLen yoe := ⟨hb.2.2.1, hb.2.2.2⟩
  have hdoy_365 : 0 ≤ doy ∧ doy ≤ 365 := by rcases yoeLen_cases yoe with h | h <;> omega
  have hmp_s := doy_mp_spec doy hdoy_365.1 hdoy_365.2
  dsimp only at hmp_s
  obtain ⟨hmp0, hmp11, hm1, hm12, hd1, hmadj, hnonfeb, hfeb⟩ := hmp_s
  let mp := (5 * doy + 2) / 153
  let d := doy - (153 * mp + 2) / 5 + 1
  let m := if mp < 10 then mp + 3 else mp - 9
  let y := yoe + era * 400
  let yr := if m ≤ 2 then y + 1 else y
  have hyr_b : 1 ≤ yr ∧ yr ≤ 9999 := by
    have hera_b : 0 ≤ era ∧ era ≤ 24 := by omega
    dsimp only [yr, y, m]
    by_cases h0 : era = 0 ∧ yoe = 0
    · have : yoeStart yoe = 0 := by unfold yoeStart; omega
      have : doy ≥ 306 := by omega
      have : mp ≥ 10 := by omega
      omega
    · by_cases h24 : era = 24 ∧ yoe = 399
      · have : yoeStart yoe = 145731 := by unfold yoeStart; omega
        have : doy ≤ 305 := by omega
        have : mp ≤ 9 := by omega
        omega
      · omega
  have hd2 : d ≤ daysInMonthMath yr m := by
    by_cases hm2 : m = 2
    · rw [hm2]
      have hyr_eq : yr = yoe + era * 400 + 1 := by dsimp only [yr, y]; rw [hm2]; simp
      rw [hyr_eq]; unfold daysInMonthMath
      simp only [beq_self_eq_true, ↓reduceIte, leap_iff_yoe era yoe hyoe_b.1 hyoe_b.2]
      have hf := hfeb hm2
      rcases yoeLen_cases yoe with h | h
      · simp [h]; exact hf.1 (by omega)
      · simp [h]; exact hf.2
    · rw [daysInMonthMath_nonfeb yr 2001 m hm2]
      exact hnonfeb hm2
  have hdfc : daysFromCivilMath yr m d = z_in := by
    unfold daysFromCivilMath; dsimp only
    have hy_back : (if m ≤ 2 then yr - 1 else yr) = y := by dsimp only [yr]; split <;> omega
    have hera_back : y / 400 = era := by dsimp only [y]; omega
    have hyoe_back : y - era * 400 = yoe := by dsimp only [y]; omega
    have hmadj' : (if m > 2 then m - 3 else m + 9) = mp := hmadj
    rw [hy_back, hera_back, hyoe_back, hmadj']
    have hdoy_eq : (153 * mp + 2) / 5 + d - 1 = doy := by dsimp only [d]; omega
    rw [hdoy_eq]
    have hdoy_def : doy = doe - (365 * yoe + yoe / 4 - yoe / 100) := rfl
    have hdoe_eq : yoe * 365 + yoe / 4 - yoe / 100 + doy = doe := by omega
    rw [hdoe_eq]; dsimp only [doe, z]; omega
  exact ⟨hyr_b.1, hyr_b.2, hm1, hm12, hd1, hd2, hdfc⟩

theorem min_unix_secs_val : MIN_UNIX_SECS.val = -62135596800 := by
  unfold MIN_UNIX_SECS
  have h0 : (0#i64).val = 0 := by
    change (BitVec.ofInt 64 0).toInt = 0; rw [BitVec.toInt_ofInt]; norm_num
  have h1 : (62135596800#i64).val = 62135596800 := by
    change (BitVec.ofInt 64 62135596800).toInt = 62135596800; rw [BitVec.toInt_ofInt]; norm_num
  rw [i64_sub_val]
  · rw [h0, h1]; norm_num
  · rw [h0, h1]; omega
  · rw [h0, h1]; omega

theorem max_unix_secs_val : MAX_UNIX_SECS.val = 253402300799 := by
  unfold MAX_UNIX_SECS
  change (BitVec.ofInt 64 253402300799).toInt = 253402300799
  rw [BitVec.toInt_ofInt]; norm_num

/-- Red-team F3 guard: `from_unix_secs` rejects every timestamp outside `[-62135596800, 253402300799]`. -/
theorem from_unix_secs_rejects_out_of_range (secs : Std.I64)
    (h : secs.val < -62135596800 ∨ secs.val > 253402300799) :
    ∃ msg, DateTime.from_unix_secs secs = ok (Pion.Res.Err (CronError.InvalidDateTime msg)) := by
  unfold DateTime.from_unix_secs
  have hcond : ((decide (secs < MIN_UNIX_SECS)) || (decide (secs > MAX_UNIX_SECS))) = true := by
    rcases h with hlo | hhi
    · have h1 : secs < MIN_UNIX_SECS := by
        change secs.val < MIN_UNIX_SECS.val; rw [min_unix_secs_val]; exact hlo
      rw [decide_eq_true h1, Bool.true_or]
    · have h2 : secs > MAX_UNIX_SECS := by
        change MAX_UNIX_SECS.val < secs.val; rw [max_unix_secs_val]; exact hhi
      rw [decide_eq_true h2, Bool.or_true]
  rw [if_pos hcond]
  exact ⟨_, rfl⟩

theorem unix_combine_val (dfc : Std.I64) (h m s : Std.I32)
    (hdlo : -719162 ≤ dfc.val) (hdhi : dfc.val ≤ 2932896)
    (hh1 : 0 ≤ h.val) (hh2 : h.val ≤ 23)
    (hm1 : 0 ≤ m.val) (hm2 : m.val ≤ 59)
    (hs1 : 0 ≤ s.val) (hs2 : s.val ≤ 59) :
    (Pion.I64.add (Pion.I64.mul dfc 86400#i64)
      (Pion.I32.to_int64 (Pion.I32.add (Pion.I32.add (Pion.I32.mul h 3600#i32) (Pion.I32.mul m 60#i32)) s))).val =
    dfc.val * 86400 + (h.val * 3600 + m.val * 60 + s.val) := by
  have h1 : (Pion.I32.mul h 3600#i32).val = h.val * 3600 := by
    rw [i32_mul_val]; all_goals (have hc : (3600#i32).val = 3600 := (by change (BitVec.ofInt 32 3600).toInt = 3600; rw [BitVec.toInt_ofInt]; norm_num); rw [hc]; try omega)
  have h2 : (Pion.I32.mul m 60#i32).val = m.val * 60 := by
    rw [i32_mul_val]; all_goals (have hc : (60#i32).val = 60 := (by change (BitVec.ofInt 32 60).toInt = 60; rw [BitVec.toInt_ofInt]; norm_num); rw [hc]; try omega)
  have h3 : (Pion.I32.add (Pion.I32.mul h 3600#i32) (Pion.I32.mul m 60#i32)).val = h.val * 3600 + m.val * 60 := by
    rw [i32_add_val, h1, h2] <;> omega
  have h4 : (Pion.I32.add (Pion.I32.add (Pion.I32.mul h 3600#i32) (Pion.I32.mul m 60#i32)) s).val =
      h.val * 3600 + m.val * 60 + s.val := by
    rw [i32_add_val, h3] <;> omega
  have h5 : (Pion.I32.to_int64 (Pion.I32.add (Pion.I32.add (Pion.I32.mul h 3600#i32) (Pion.I32.mul m 60#i32)) s)).val =
      h.val * 3600 + m.val * 60 + s.val := by
    rw [i32_to_i64_val, h4]
  have h6 : (Pion.I64.mul dfc 86400#i64).val = dfc.val * 86400 := by
    rw [i64_mul_val]; all_goals (rw [i64_86400_val]; try omega)
  rw [i64_add_val, h6, h5] <;> omega

/-- Exact evaluation and validity of `DateTime.from_unix_secs` on `[-62135596800, 253402300799]`. -/
theorem from_unix_secs_in_range_spec (secs : Std.I64)
    (hlo : -62135596800 ≤ secs.val) (hhi : secs.val ≤ 253402300799) :
    ∃ dt : DateTime, DateTime.from_unix_secs secs = ok (Pion.Res.Ok dt) ∧
      DateTime.is_valid dt = ok true ∧
      DateTime.to_unix_secs dt = ok secs := by
  unfold DateTime.from_unix_secs
  have hcond : ((decide (secs < MIN_UNIX_SECS)) || (decide (secs > MAX_UNIX_SECS))) = false := by
    have h1 : ¬ secs < MIN_UNIX_SECS := by
      change ¬ secs.val < MIN_UNIX_SECS.val; rw [min_unix_secs_val]; omega
    have h2 : ¬ secs > MAX_UNIX_SECS := by
      change ¬ MAX_UNIX_SECS.val < secs.val; rw [max_unix_secs_val]; omega
    rw [decide_eq_false h1, decide_eq_false h2]; rfl
  rw [if_neg (by rw [hcond]; decide)]
  -- Compute Euclidean `days = secs / 86400`
  have hdays_step : ∃ days : Std.I64,
      (if secs >= 0#i64 then do let t ← Pion.I64.div secs 86400#i64; ok t
       else do let t ← Pion.I64.div (Pion.I64.sub secs 86399#i64) 86400#i64; ok t) = ok days ∧
      days.val = secs.val / 86400 := by
    by_cases h0 : secs >= 0#i64
    · rw [if_pos h0]
      obtain ⟨d, hd, hd_val⟩ := i64_div_pos_ok secs 86400#i64 (by rw [i64_86400_val]; omega)
      rw [hd, b_ok]
      have hge0 : 0 ≤ secs.val := h0
      exact ⟨d, rfl, by rw [hd_val, i64_86400_val]; exact tdiv_eq_ediv_of_nonneg _ 86400 hge0 (by omega)⟩
    · rw [if_neg h0]
      have hlt0 : secs.val < 0 := by
        have : ¬ (0 : Int) ≤ secs.val := h0; omega
      have hsub : (Pion.I64.sub secs 86399#i64).val = secs.val - 86399 := by
        rw [i64_sub_val]; all_goals (rw [i64_86399_val]; try omega)
      obtain ⟨d, hd, hd_val⟩ := i64_div_pos_ok (Pion.I64.sub secs 86399#i64) 86400#i64 (by rw [i64_86400_val]; omega)
      rw [hd, b_ok]
      refine ⟨d, rfl, ?_⟩
      rw [hd_val, hsub, i64_86400_val]
      rw [Int.tdiv_eq_ediv]
      simp only [show ¬ 0 ≤ secs.val - 86399 by omega, false_or]
      have hsign : Int.sign 86400 = 1 := rfl
      rw [hsign]
      split <;> omega
  obtain ⟨days, hdays_eq, hdays_val⟩ := hdays_step
  rw [hdays_eq, b_ok]
  have hdays_b : -719162 ≤ days.val ∧ days.val ≤ 2932896 := by omega
  have h_d864 : (Pion.I64.mul days 86400#i64).val = days.val * 86400 := by
    rw [i64_mul_val]; all_goals (rw [i64_86400_val]; try omega)
  have h_r64 : (Pion.I64.sub secs (Pion.I64.mul days 86400#i64)).val = secs.val - days.val * 86400 := by
    rw [i64_sub_val, h_d864] <;> omega
  set rem : Std.I32 := Pion.I64.to_int (Pion.I64.sub secs (Pion.I64.mul days 86400#i64))
  have hrem_val : rem.val = secs.val - days.val * 86400 := by
    dsimp only [rem]; rw [i64_to_i32_val, h_r64] <;> omega
  have hrem_b : 0 ≤ rem.val ∧ rem.val ≤ 86399 := by omega
  obtain ⟨yr, m, d, hciv, hciv_eq⟩ := civil_from_days_eq days hdays_b.1 hdays_b.2
  rw [hciv, b_ok]
  have hmath := days_civil_roundtrip_math days.val hdays_b.1 hdays_b.2
  rw [← hciv_eq] at hmath
  dsimp only at hmath
  obtain ⟨hyr1, hyr2, hm1, hm2, hd1, hd2, hdfc_inv⟩ := hmath
  have hy_ok : ((decide (yr < MIN_YEAR)) || (decide (yr > MAX_YEAR))) = false := by
    unfold MIN_YEAR MAX_YEAR
    have h1 : ¬ yr < 1#i32 := by show ¬ yr.val < 1; omega
    have h2 : ¬ yr > 9999#i32 := by show ¬ 9999 < yr.val; omega
    simp [h1, h2]
  simp only [hy_ok, Bool.false_eq_true, ↓reduceIte]
  obtain ⟨hour, hhour, hhour_val⟩ := i32_div_pos_ok rem 3600#i32 (by change (0 : Int) < (BitVec.ofInt 32 3600).toInt; rw [BitVec.toInt_ofInt]; norm_num)
  simp only [hhour, b_ok]
  have hhour_ediv : hour.val = rem.val / 3600 := by
    rw [hhour_val]; exact tdiv_eq_ediv_of_nonneg _ 3600 (by omega) (by omega)
  have h_h3600 : (Pion.I32.mul hour 3600#i32).val = hour.val * 3600 := by
    rw [i32_mul_val]; all_goals (have hc : (3600#i32).val = 3600 := (by change (BitVec.ofInt 32 3600).toInt = 3600; rw [BitVec.toInt_ofInt]; norm_num); rw [hc]; try omega)
  set rem2 : Std.I32 := Pion.I32.sub rem (Pion.I32.mul hour 3600#i32)
  have hrem2_val : rem2.val = rem.val - hour.val * 3600 := by
    dsimp only [rem2]; rw [i32_sub_val, h_h3600] <;> omega
  obtain ⟨minute, hmin, hmin_val⟩ := i32_div_pos_ok rem2 60#i32 (by change (0 : Int) < (BitVec.ofInt 32 60).toInt; rw [BitVec.toInt_ofInt]; norm_num)
  simp only [hmin, b_ok]
  have hmin_ediv : minute.val = rem2.val / 60 := by
    rw [hmin_val]; exact tdiv_eq_ediv_of_nonneg _ 60 (by omega) (by omega)
  have h_m60 : (Pion.I32.mul minute 60#i32).val = minute.val * 60 := by
    rw [i32_mul_val]; all_goals (have hc : (60#i32).val = 60 := (by change (BitVec.ofInt 32 60).toInt = 60; rw [BitVec.toInt_ofInt]; norm_num); rw [hc]; try omega)
  set second : Std.I32 := Pion.I32.sub rem2 (Pion.I32.mul minute 60#i32)
  have hsec_val : second.val = rem2.val - minute.val * 60 := by
    dsimp only [second]; rw [i32_sub_val, h_m60] <;> omega
  set dt : DateTime := DateTime.mk yr m d hour minute second
  refine ⟨dt, ?_, ?_, ?_⟩
  · change (if (decide (yr < MIN_YEAR) || decide (yr > MAX_YEAR)) = true then _ else ok (Pion.Res.Ok dt)) = ok (Pion.Res.Ok dt)
    rw [if_neg (by rw [hy_ok]; decide)]
  · rw [datetime_is_valid_spec]
    dsimp only [dt]
    congr 1
    exact decide_eq_true (by unfold DateTimeValid; dsimp only; exact ⟨hyr1, hyr2, hm1, hm2, hd1, hd2, by omega, by omega, by omega, by omega, by omega, by omega⟩)
  · unfold DateTime.to_unix_secs
    dsimp only [dt]
    obtain ⟨dfc, hdfc, hdfc_val, hdfc_lo, hdfc_hi⟩ := days_from_civil_eq yr m d hyr1 hyr2 hm1 hm2 hd1 hd2
    rw [hdfc, b_ok]
    congr 1
    apply i64_ext
    rw [unix_combine_val dfc hour minute second hdfc_lo hdfc_hi (by omega) (by omega) (by omega) (by omega) (by omega) (by omega)]
    omega

/-- Corollary: `from_unix_secs` in range always yields `Ok dt` with `is_valid dt = ok true`. -/
theorem from_unix_secs_in_range_valid (secs : Std.I64)
    (hlo : -62135596800 ≤ secs.val) (hhi : secs.val ≤ 253402300799) :
    ∃ dt : DateTime, DateTime.from_unix_secs secs = ok (Pion.Res.Ok dt) ∧
      DateTime.is_valid dt = ok true := by
  obtain ⟨dt, h1, h2, _⟩ := from_unix_secs_in_range_spec secs hlo hhi
  exact ⟨dt, h1, h2⟩

/-- Inverse roundtrip: `to_unix_secs (from_unix_secs secs) = ok secs` on `[-62135596800, 253402300799]`. -/
theorem from_to_unix_secs_roundtrip (secs : Std.I64)
    (hlo : -62135596800 ≤ secs.val) (hhi : secs.val ≤ 253402300799) :
    ∃ dt : DateTime, DateTime.from_unix_secs secs = ok (Pion.Res.Ok dt) ∧
      DateTime.to_unix_secs dt = ok secs := by
  obtain ⟨dt, h1, _, h3⟩ := from_unix_secs_in_range_spec secs hlo hhi
  exact ⟨dt, h1, h3⟩

/-- Forward roundtrip: for every valid `dt`, `from_unix_secs (to_unix_secs dt) = ok (Ok dt)`. -/
theorem to_from_unix_secs_roundtrip (dt : DateTime) (hv : DateTime.is_valid dt = ok true) :
    ∃ secs : Std.I64, DateTime.to_unix_secs dt = ok secs ∧
      -62135596800 ≤ secs.val ∧ secs.val ≤ 253402300799 ∧
      DateTime.from_unix_secs secs = ok (Pion.Res.Ok dt) := by
  rw [datetime_is_valid_spec] at hv
  obtain ⟨hy1, hy2, hm1, hm2, hd1, hd2, hh1, hh2, hmi1, hmi2, hs1, hs2⟩ :=
    of_decide_eq_true (ok_inj hv)
  unfold DateTime.to_unix_secs
  obtain ⟨dfc, hdfc, hdfc_val, hdfc_lo, hdfc_hi⟩ :=
    days_from_civil_eq dt.year dt.month dt.day hy1 hy2 hm1 hm2 hd1 hd2
  rw [hdfc, b_ok]
  set secs : Std.I64 := Pion.I64.add (Pion.I64.mul dfc 86400#i64)
    (Pion.I32.to_int64 (Pion.I32.add (Pion.I32.add (Pion.I32.mul dt.hour 3600#i32) (Pion.I32.mul dt.minute 60#i32)) dt.second))
  have hsecs_val : secs.val = dfc.val * 86400 + (dt.hour.val * 3600 + dt.minute.val * 60 + dt.second.val) :=
    unix_combine_val dfc dt.hour dt.minute dt.second hdfc_lo hdfc_hi hh1 hh2 hmi1 hmi2 hs1 hs2
  have hsecs_lo : -62135596800 ≤ secs.val := by omega
  have hsecs_hi : secs.val ≤ 253402300799 := by omega
  refine ⟨secs, rfl, hsecs_lo, hsecs_hi, ?_⟩
  obtain ⟨dt', hfrom, hvalid', hto'⟩ := from_unix_secs_in_range_spec secs hsecs_lo hsecs_hi
  -- Uniqueness: `dt'` has the same `days` and `rem` as `dt`, hence `dt' = dt`
  rw [datetime_is_valid_spec] at hvalid'
  obtain ⟨hy1', hy2', hm1', hm2', hd1', hd2', hh1', hh2', hmi1', hmi2', hs1', hs2'⟩ :=
    of_decide_eq_true (ok_inj hvalid')
  unfold DateTime.to_unix_secs at hto'
  obtain ⟨dfc', hdfc', hdfc_val', hdfc_lo', hdfc_hi'⟩ :=
    days_from_civil_eq dt'.year dt'.month dt'.day hy1' hy2' hm1' hm2' hd1' hd2'
  rw [hdfc', b_ok] at hto'
  have hsecs_eq : (Pion.I64.add (Pion.I64.mul dfc' 86400#i64)
      (Pion.I32.to_int64 (Pion.I32.add (Pion.I32.add (Pion.I32.mul dt'.hour 3600#i32) (Pion.I32.mul dt'.minute 60#i32)) dt'.second))).val = secs.val :=
    congrArg (fun s : Std.I64 => s.val) (ok_inj hto')
  have hsecs_val' : dfc'.val * 86400 + (dt'.hour.val * 3600 + dt'.minute.val * 60 + dt'.second.val) = secs.val := by
    rw [← hsecs_eq]
    exact (unix_combine_val dfc' dt'.hour dt'.minute dt'.second hdfc_lo' hdfc_hi' hh1' hh2' hmi1' hmi2' hs1' hs2').symm
  have hdfceq : dfc'.val = dfc.val := by omega
  have hheq : dt'.hour.val = dt.hour.val := by omega
  have hmseq : dt'.minute.val = dt.minute.val := by omega
  have hseq : dt'.second.val = dt.second.val := by omega
  have hciv_eq : civilFromDaysMath (daysFromCivilMath dt'.year.val dt'.month.val dt'.day.val) =
      civilFromDaysMath (daysFromCivilMath dt.year.val dt.month.val dt.day.val) := by
    rw [← hdfc_val', ← hdfc_val, hdfceq]
  rw [civil_days_roundtrip_math dt'.year.val dt'.month.val dt'.day.val hy1' hy2' hm1' hm2' hd1' hd2',
      civil_days_roundtrip_math dt.year.val dt.month.val dt.day.val hy1 hy2 hm1 hm2 hd1 hd2] at hciv_eq
  simp only [Prod.mk.injEq] at hciv_eq
  have hdt_eq : dt' = dt := by
    cases dt' with | mk y' m' d' h' mi' s' =>
    cases dt with | mk y m d h mi s =>
    simp only at hciv_eq hheq hmseq hseq
    congr 1
    · exact i32_ext hciv_eq.1
    · exact i32_ext hciv_eq.2.1
    · exact i32_ext hciv_eq.2.2
    · exact i32_ext hheq
    · exact i32_ext hmseq
    · exact i32_ext hseq
  rwa [hdt_eq] at hfrom

/-- `daysFromCivilMath` is strictly monotone in lexicographic `(year, month, day)`. -/
theorem daysFromCivilMath_strict_mono {y1 m1 d1 y2 m2 d2 : Int}
    (hy1 : 1 ≤ y1) (hy1' : y1 ≤ 9999) (hm1 : 1 ≤ m1) (hm1' : m1 ≤ 12) (hd1 : 1 ≤ d1) (hd1' : d1 ≤ daysInMonthMath y1 m1)
    (hy2 : 1 ≤ y2) (hy2' : y2 ≤ 9999) (hm2 : 1 ≤ m2) (hm2' : m2 ≤ 12) (hd2 : 1 ≤ d2) (hd2' : d2 ≤ daysInMonthMath y2 m2)
    (hlt : y1 < y2 ∨ (y1 = y2 ∧ m1 < m2) ∨ (y1 = y2 ∧ m1 = m2 ∧ d1 < d2)) :
    daysFromCivilMath y1 m1 d1 < daysFromCivilMath y2 m2 d2 := by
  -- Helper: within any year `y`, the cumulative days before month `m` strictly increases with `m`
  have hstep : ∀ y m d, 1 ≤ y → y ≤ 9999 → 1 ≤ m → m ≤ 12 → 1 ≤ d → d ≤ daysInMonthMath y m →
      daysFromCivilMath y m d <
      (if m < 12 then daysFromCivilMath y (m + 1) 1 else daysFromCivilMath (y + 1) 1 1) := by
    intro y m d _ _ _ _ _ hdm
    have hm_c : m = 1 ∨ m = 2 ∨ m = 3 ∨ m = 4 ∨ m = 5 ∨ m = 6 ∨
        m = 7 ∨ m = 8 ∨ m = 9 ∨ m = 10 ∨ m = 11 ∨ m = 12 := by omega
    rcases hm_c with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl
    · unfold daysInMonthMath at hdm; simp at hdm; unfold daysFromCivilMath; dsimp only; omega
    · unfold daysInMonthMath isLeapYearMath at hdm; simp only [beq_self_eq_true, ↓reduceIte] at hdm
      unfold daysFromCivilMath; dsimp only
      by_cases hl : (y % 4 = 0 ∧ y % 100 ≠ 0) ∨ y % 400 = 0
      · have hlt : ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) = true := by
          rcases hl with ⟨h4, h100⟩ | h400
          · simp [h4, h100]
          · simp [h400]
        simp [hlt] at hdm; omega
      · have hlf : ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) = false := by
          simp [Bool.or_eq_false_iff, Bool.and_eq_false_iff]; omega
        simp [hlf] at hdm; omega
    · unfold daysInMonthMath at hdm; simp at hdm; unfold daysFromCivilMath; dsimp only; omega
    · unfold daysInMonthMath at hdm; simp at hdm; unfold daysFromCivilMath; dsimp only; omega
    · unfold daysInMonthMath at hdm; simp at hdm; unfold daysFromCivilMath; dsimp only; omega
    · unfold daysInMonthMath at hdm; simp at hdm; unfold daysFromCivilMath; dsimp only; omega
    · unfold daysInMonthMath at hdm; simp at hdm; unfold daysFromCivilMath; dsimp only; omega
    · unfold daysInMonthMath at hdm; simp at hdm; unfold daysFromCivilMath; dsimp only; omega
    · unfold daysInMonthMath at hdm; simp at hdm; unfold daysFromCivilMath; dsimp only; omega
    · unfold daysInMonthMath at hdm; simp at hdm; unfold daysFromCivilMath; dsimp only; omega
    · unfold daysInMonthMath at hdm; simp at hdm; unfold daysFromCivilMath; dsimp only; omega
    · unfold daysInMonthMath at hdm; simp at hdm; unfold daysFromCivilMath; dsimp only; omega
  -- Monotonicity of Jan 1 across years
  have hjan : ∀ a b, 1 ≤ a → a ≤ b → daysFromCivilMath a 1 1 ≤ daysFromCivilMath b 1 1 := by
    intro a b _ _; unfold daysFromCivilMath; dsimp only; omega
  -- Monotonicity of 1st-of-month within a year (no 12x12 explosion)
  have hmo : ∀ y a b, 1 ≤ y → y ≤ 9999 → 1 ≤ a → a ≤ b → b ≤ 12 →
      daysFromCivilMath y a 1 ≤ daysFromCivilMath y b 1 := by
    intro y a b _ _ _ _ _
    unfold daysFromCivilMath; dsimp only
    by_cases ha2 : a ≤ 2 <;> by_cases hb2 : b ≤ 2
    · -- both in {1, 2}
      simp only [ha2, hb2, ↓reduceIte]; omega
    · -- a in {1, 2}, b in {3..12}
      simp only [ha2, hb2, ↓reduceIte]
      have ha_le : a = 1 ∨ a = 2 := by omega
      have hb_ge : b > 2 := by omega
      have ha_gt : ¬ (a > 2) := by omega
      simp only [hb_ge, ha_gt, ↓reduceIte]
      omega
    · omega
    · -- both in {3..12}
      have ha_gt : a > 2 := by omega
      have hb_gt : b > 2 := by omega
      simp only [ha2, hb2, ha_gt, hb_gt, ↓reduceIte]
      omega
  have hday_ge : ∀ y m d, 1 ≤ d → daysFromCivilMath y m 1 ≤ daysFromCivilMath y m d := by
    intro y m d _; unfold daysFromCivilMath; dsimp only; omega
  rcases hlt with hylt | ⟨rfl, hmlt⟩ | ⟨rfl, rfl, hdlt⟩
  · have h1 := hstep y1 m1 d1 hy1 hy1' hm1 hm1' hd1 hd1'
    have h2 : daysFromCivilMath y1 m1 d1 < daysFromCivilMath (y1 + 1) 1 1 := by
      by_cases hm12 : m1 < 12
      · simp only [hm12, ↓reduceIte] at h1
        have h3 := hmo y1 (m1 + 1) 12 hy1 hy1' (by omega) (by omega) (by omega)
        have h4 := hstep y1 12 1 hy1 hy1' (by omega) (by omega) (by omega) (by unfold daysInMonthMath; simp)
        simp only [show ¬ (12 : Int) < 12 by omega, ↓reduceIte] at h4
        omega
      · simp only [hm12, ↓reduceIte] at h1; exact h1
    have h3 := hjan (y1 + 1) y2 (by omega) (by omega)
    have h4 := hmo y2 1 m2 hy2 hy2' (by omega) (by omega) hm2'
    have h5 := hday_ge y2 m2 d2 hd2
    omega
  · have h1 := hstep y1 m1 d1 hy1 hy1' hm1 hm1' hd1 hd1'
    simp only [show m1 < 12 by omega, ↓reduceIte] at h1
    have h2 := hmo y1 (m1 + 1) m2 hy1 hy1' (by omega) (by omega) hm2'
    have h3 := hday_ge y1 m2 d2 hd2
    omega
  · unfold daysFromCivilMath; dsimp only; omega

/-- `DateTime.to_unix_secs` is strictly order-preserving with respect to `DateTime.cmp`. -/
theorem to_unix_secs_strict_mono (a b : DateTime)
    (ha : DateTime.is_valid a = ok true) (hb : DateTime.is_valid b = ok true)
    (hcmp : DateTime.cmp a b = ok (-1)#i32) :
    ∃ sa sb : Std.I64, DateTime.to_unix_secs a = ok sa ∧
      DateTime.to_unix_secs b = ok sb ∧ sa.val < sb.val := by
  rw [datetime_is_valid_spec] at ha hb
  obtain ⟨ay1, ay2, am1, am2, ad1, ad2, ah1, ah2, ami1, ami2, as1, as2⟩ :=
    of_decide_eq_true (ok_inj ha)
  obtain ⟨by1, by2, bm1, bm2, bd1, bd2, bh1, bh2, bmi1, bmi2, bs1, bs2⟩ :=
    of_decide_eq_true (ok_inj hb)
  unfold DateTime.to_unix_secs
  obtain ⟨da, hda, hda_val, hda_lo, hda_hi⟩ :=
    days_from_civil_eq a.year a.month a.day ay1 ay2 am1 am2 ad1 ad2
  obtain ⟨db, hdb, hdb_val, hdb_lo, hdb_hi⟩ :=
    days_from_civil_eq b.year b.month b.day by1 by2 bm1 bm2 bd1 bd2
  rw [hda, hdb, b_ok, b_ok]
  set sa : Std.I64 := Pion.I64.add (Pion.I64.mul da 86400#i64)
    (Pion.I32.to_int64 (Pion.I32.add (Pion.I32.add (Pion.I32.mul a.hour 3600#i32) (Pion.I32.mul a.minute 60#i32)) a.second))
  set sb : Std.I64 := Pion.I64.add (Pion.I64.mul db 86400#i64)
    (Pion.I32.to_int64 (Pion.I32.add (Pion.I32.add (Pion.I32.mul b.hour 3600#i32) (Pion.I32.mul b.minute 60#i32)) b.second))
  have hsa : sa.val = da.val * 86400 + (a.hour.val * 3600 + a.minute.val * 60 + a.second.val) :=
    unix_combine_val da a.hour a.minute a.second hda_lo hda_hi ah1 ah2 ami1 ami2 as1 as2
  have hsb : sb.val = db.val * 86400 + (b.hour.val * 3600 + b.minute.val * 60 + b.second.val) :=
    unix_combine_val db b.hour b.minute b.second hdb_lo hdb_hi bh1 bh2 bmi1 bmi2 bs1 bs2
  refine ⟨sa, sb, rfl, rfl, ?_⟩
  -- Unpack `DateTime.cmp a b = ok (-1)#i32`
  unfold DateTime.cmp at hcmp
  by_cases hy : a.year ≠ b.year
  · simp only [hy, ne_eq, not_false_eq_true, bne_iff_ne, ↓reduceIte] at hcmp
    have hylt : a.year.val < b.year.val := by
      by_contra hge
      have hnot : ¬ a.year < b.year := hge
      simp only [hnot, ↓reduceIte] at hcmp
      have := ok_inj hcmp
      exact absurd (congrArg (fun u : Std.I32 => u.val) this) (by decide)
    have hdlt := daysFromCivilMath_strict_mono ay1 ay2 am1 am2 ad1 ad2 by1 by2 bm1 bm2 bd1 bd2 (Or.inl hylt)
    omega
  · simp only [hy, ne_eq, not_true_eq_false, bne_iff_ne, ↓reduceIte] at hcmp
    have hyeq : a.year.val = b.year.val := congrArg (fun u : Std.I32 => u.val) (not_not.mp hy)
    by_cases hm : a.month ≠ b.month
    · simp only [hm, ne_eq, not_false_eq_true, bne_iff_ne, ↓reduceIte] at hcmp
      have hmlt : a.month.val < b.month.val := by
        by_contra hge
        have hnot : ¬ a.month < b.month := hge
        simp only [hnot, ↓reduceIte] at hcmp
        have := ok_inj hcmp
        exact absurd (congrArg (fun u : Std.I32 => u.val) this) (by decide)
      have hdlt := daysFromCivilMath_strict_mono ay1 ay2 am1 am2 ad1 ad2 by1 by2 bm1 bm2 bd1 bd2 (Or.inr (Or.inl ⟨hyeq, hmlt⟩))
      omega
    · simp only [hm, ne_eq, not_true_eq_false, bne_iff_ne, ↓reduceIte] at hcmp
      have hmeq : a.month.val = b.month.val := congrArg (fun u : Std.I32 => u.val) (not_not.mp hm)
      by_cases hd : a.day ≠ b.day
      · simp only [hd, ne_eq, not_false_eq_true, bne_iff_ne, ↓reduceIte] at hcmp
        have hdlt : a.day.val < b.day.val := by
          by_contra hge
          have hnot : ¬ a.day < b.day := hge
          simp only [hnot, ↓reduceIte] at hcmp
          have := ok_inj hcmp
          exact absurd (congrArg (fun u : Std.I32 => u.val) this) (by decide)
        have hdl := daysFromCivilMath_strict_mono ay1 ay2 am1 am2 ad1 ad2 by1 by2 bm1 bm2 bd1 bd2 (Or.inr (Or.inr ⟨hyeq, hmeq, hdlt⟩))
        omega
      · simp only [hd, ne_eq, not_true_eq_false, bne_iff_ne, ↓reduceIte] at hcmp
        have hdeq : a.day.val = b.day.val := congrArg (fun u : Std.I32 => u.val) (not_not.mp hd)
        have hda_eq_db : da.val = db.val := by rw [hda_val, hdb_val, hyeq, hmeq, hdeq]
        by_cases hh : a.hour ≠ b.hour
        · simp only [hh, ne_eq, not_false_eq_true, bne_iff_ne, ↓reduceIte] at hcmp
          have hhlt : a.hour.val < b.hour.val := by
            by_contra hge
            have hnot : ¬ a.hour < b.hour := hge
            simp only [hnot, ↓reduceIte] at hcmp
            have := ok_inj hcmp
            exact absurd (congrArg (fun u : Std.I32 => u.val) this) (by decide)
          omega
        · simp only [hh, ne_eq, not_true_eq_false, bne_iff_ne, ↓reduceIte] at hcmp
          have hheq : a.hour.val = b.hour.val := congrArg (fun u : Std.I32 => u.val) (not_not.mp hh)
          by_cases hmi : a.minute ≠ b.minute
          · simp only [hmi, ne_eq, not_false_eq_true, bne_iff_ne, ↓reduceIte] at hcmp
            have hmilt : a.minute.val < b.minute.val := by
              by_contra hge
              have hnot : ¬ a.minute < b.minute := hge
              simp only [hnot, ↓reduceIte] at hcmp
              have := ok_inj hcmp
              exact absurd (congrArg (fun u : Std.I32 => u.val) this) (by decide)
            omega
          · simp only [hmi, ne_eq, not_true_eq_false, bne_iff_ne, ↓reduceIte] at hcmp
            have hmieq : a.minute.val = b.minute.val := congrArg (fun u : Std.I32 => u.val) (not_not.mp hmi)
            by_cases hs : a.second ≠ b.second
            · simp only [hs, ne_eq, not_false_eq_true, bne_iff_ne, ↓reduceIte] at hcmp
              have hslt : a.second.val < b.second.val := by
                by_contra hge
                have hnot : ¬ a.second < b.second := hge
                simp only [hnot, ↓reduceIte] at hcmp
                have := ok_inj hcmp
                exact absurd (congrArg (fun u : Std.I32 => u.val) this) (by decide)
              omega
            · simp only [hs, ne_eq, not_true_eq_false, bne_iff_ne, ↓reduceIte] at hcmp
              have := ok_inj hcmp
              exact absurd (congrArg (fun u : Std.I32 => u.val) this) (by decide)

end CronProofs
