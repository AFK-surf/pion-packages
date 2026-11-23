import Aeneas
import PionLean
import Email.Types
import Email.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion email

namespace EmailProofs

private lemma result_bind_ok' {α β : Type} (a : α) (f : α → Result β) :
    (do let x ← ok a; f x) = f a := by simp
private lemma i32_le_iff' (x y : Std.I32) : (x <= y) ↔ (x.val <= y.val) := Iff.rfl
private lemma i32_lt_iff' (x y : Std.I32) : (x < y) ↔ (x.val < y.val) := Iff.rfl
private lemma i64_lt_iff' (x y : Std.I64) : (x < y) ↔ (x.val < y.val) := Iff.rfl
private lemma i32_bne_iff' (x y : Std.I32) : ((x != y) = true) ↔ (x.val ≠ y.val) := by
  cases x; cases y; simp [bne, BEq.beq, IScalar.val, BitVec.toInt_inj]

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

private lemma i32_mul_val' (x y : Std.I32)
    (hlo : -2147483648 ≤ x.val * y.val) (hhi : x.val * y.val ≤ 2147483647) :
    (Pion.I32.mul x y).val = x.val * y.val := by
  unfold Pion.I32.mul
  have hv : (x.bv * y.bv).toInt = x.val * y.val := by
    rw [BitVec.toInt_mul]
    have hx : x.bv.toInt = x.val := rfl
    have hy : y.bv.toInt = y.val := rfl
    rw [hx, hy]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  exact hv

private lemma i32_neg_val' (x : Std.I32) (hlo : -2147483647 ≤ x.val) :
    (Pion.I32.neg x).val = -x.val := by
  unfold Pion.I32.neg
  have hv : (-x.bv).toInt = -x.val := by
    rw [BitVec.toInt_neg]
    have hx : x.bv.toInt = x.val := rfl
    rw [hx]
    have hhi := x.hBounds.2
    change x.val < 2147483648 at hhi
    exact Int.bmod_eq_of_le (by omega) (by omega)
  exact hv

private lemma i64_add_val' (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val + y.val) (hhi : x.val + y.val ≤ 9223372036854775807) :
    (Pion.I64.add x y).val = x.val + y.val := by
  unfold Pion.I64.add
  have hv : (x.bv + y.bv).toInt = x.val + y.val := by
    rw [BitVec.toInt_add]
    have hx : x.bv.toInt = x.val := rfl
    have hy : y.bv.toInt = y.val := rfl
    rw [hx, hy]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  exact hv

private lemma i64_sub_val' (x y : Std.I64)
    (hlo : -9223372036854775808 ≤ x.val - y.val) (hhi : x.val - y.val ≤ 9223372036854775807) :
    (Pion.I64.sub x y).val = x.val - y.val := by
  unfold Pion.I64.sub
  have hv : (x.bv - y.bv).toInt = x.val - y.val := by
    rw [BitVec.toInt_sub]
    have hx : x.bv.toInt = x.val := rfl
    have hy : y.bv.toInt = y.val := rfl
    rw [hx, hy]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  exact hv

private lemma i64_div_86400 (x : Std.I64) :
    ∃ q : Std.I64, Pion.I64.div x 86400#i64 = ok q ∧ q.val = x.val.tdiv 86400 := by
  unfold Pion.I64.div
  have hne : (86400#i64 : Std.I64).val ≠ 0 := by decide
  rcases IScalar.div_spec (x := x) (y := 86400#i64) hne (fun h => absurd h.2 (by decide)) with ⟨q, hq, hqv⟩
  exact ⟨q, hq, hqv⟩

private lemma i64_rem_86400 (x : Std.I64) :
    ∃ r : Std.I64, Pion.I64.rem x 86400#i64 = ok r ∧ r.val = x.val.tmod 86400 := by
  unfold Pion.I64.rem
  have hnotovf : ¬ (x.val = -9223372036854775808 ∧ (86400#i64 : Std.I64).val = -1) := by
    intro h; exact absurd h.2 (by decide)
  simp only [hnotovf, ↓reduceIte]
  have hne : (86400#i64 : Std.I64).val ≠ 0 := by decide
  refine ⟨⟨BitVec.srem x.bv (86400#i64).bv⟩, ?_, ?_⟩
  · change IScalar.rem x 86400#i64 = ok ⟨BitVec.srem x.bv (86400#i64).bv⟩
    simp only [IScalar.rem, bne_iff_ne, ne_eq, hne, not_false_eq_true, ↓reduceIte]
  · change (BitVec.srem x.bv (86400#i64).bv).toInt = x.val.tmod 86400
    rw [BitVec.toInt_srem]
    rfl

/-- Theorem 13: `dt_is_digit` exact range (`'0'..'9'`, i.e., `48..57`). -/
theorem dt_is_digit_exact (c : Std.I32) :
    dt_is_digit c = ok true ↔ (48 ≤ c.val ∧ c.val ≤ 57) := by
  unfold dt_is_digit
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
  change (48 ≤ c.val ∧ c.val ≤ 57) ↔ _
  exact Iff.rfl

/-- Theorem 14: Every ASCII digit is accepted by `addr_is_atext`, `email_is_ftext`, and `addr_is_dtext`. -/
theorem dt_is_digit_subset_email_classes (c : Std.I32) (hd : dt_is_digit c = ok true) :
    addr_is_atext c = ok true ∧ email_is_ftext c = ok true ∧ addr_is_dtext c = ok true := by
  have ⟨hlo, hhi⟩ := (dt_is_digit_exact c).mp hd
  refine ⟨?_, ?_, ?_⟩
  · unfold addr_is_atext
    have h128 : ¬ (c >= 128#i32) := fun h => by
      have hv := (i32_le_iff' 128#i32 c).mp h; change 128 ≤ c.val at hv; omega
    have halnum : ((((decide (c >= 65#i32)) && (decide (c <= 90#i32))) || ((decide (c >= 97#i32)) && (decide (c <= 122#i32)))) || ((decide (c >= 48#i32)) && (decide (c <= 57#i32)))) = true := by
      simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
      change ((65 ≤ c.val ∧ c.val ≤ 90) ∨ (97 ≤ c.val ∧ c.val ≤ 122)) ∨ (48 ≤ c.val ∧ c.val ≤ 57)
      omega
    simp only [h128, halnum, ↓reduceIte]
  · unfold email_is_ftext
    apply congrArg ok
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff', i32_bne_iff']
    change (33 ≤ c.val ∧ c.val ≤ 126) ∧ c.val ≠ 58; omega
  · unfold addr_is_dtext
    apply congrArg ok
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff', i32_bne_iff']
    change ((((33 ≤ c.val ∧ c.val ≤ 126) ∧ c.val ≠ 91) ∧ c.val ≠ 92) ∧ c.val ≠ 93); omega

/-- Theorem 15: RFC 5322 §4.3 2-digit year normalization maps `[0, 99]` into `[1950, 2049]` with exact pivot at 49/50. -/
theorem dt_normalize_year_2digit_bounds (year : Std.I32) (h0 : 0 ≤ year.val) (h99 : year.val ≤ 99) :
    ∃ r : Std.I32, dt_normalize_year year 2#i32 = ok r ∧
      1950 ≤ r.val ∧ r.val ≤ 2049 ∧
      (year.val ≤ 49 → r.val = year.val + 2000) ∧
      (50 ≤ year.val → r.val = year.val + 1900) := by
  unfold dt_normalize_year
  simp only [↓reduceIte]
  by_cases h49 : year <= 49#i32
  · simp only [h49, ↓reduceIte]
    have hv := (i32_le_iff' year 49#i32).mp h49; change year.val ≤ 49 at hv
    have ha := i32_add_val' year 2000#i32 (by change -2147483648 ≤ year.val + 2000; omega) (by change year.val + 2000 ≤ 2147483647; omega)
    change (Pion.I32.add year 2000#i32).val = year.val + 2000 at ha
    refine ⟨Pion.I32.add year 2000#i32, rfl, by omega, by omega, fun _ => ha, fun hge => by omega⟩
  · simp only [h49, ↓reduceIte]
    have hv : ¬ (year.val ≤ 49) := fun hle => h49 ((i32_le_iff' year 49#i32).mpr hle)
    have ha := i32_add_val' year 1900#i32 (by change -2147483648 ≤ year.val + 1900; omega) (by change year.val + 1900 ≤ 2147483647; omega)
    change (Pion.I32.add year 1900#i32).val = year.val + 1900 at ha
    refine ⟨Pion.I32.add year 1900#i32, rfl, by omega, by omega, fun hle => by omega, fun _ => ha⟩

/-- Theorem 16: RFC 5322 §4.3 3-digit year normalization maps `[0, 999]` to `year + 1900 ∈ [1900, 2899]`. -/
theorem dt_normalize_year_3digit_bounds (year : Std.I32) (h0 : 0 ≤ year.val) (h999 : year.val ≤ 999) :
    ∃ r : Std.I32, dt_normalize_year year 3#i32 = ok r ∧
      r.val = year.val + 1900 ∧ 1900 ≤ r.val ∧ r.val ≤ 2899 := by
  unfold dt_normalize_year
  have h32 : (3#i32 : Std.I32) ≠ 2#i32 := by decide
  simp only [h32, ↓reduceIte]
  have ha := i32_add_val' year 1900#i32 (by change -2147483648 ≤ year.val + 1900; omega) (by change year.val + 1900 ≤ 2147483647; omega)
  change (Pion.I32.add year 1900#i32).val = year.val + 1900 at ha
  exact ⟨Pion.I32.add year 1900#i32, rfl, ha, by omega, by omega⟩

/-- Theorem 17: 4-digit years are preserved identically by `dt_normalize_year`. -/
theorem dt_normalize_year_4digit_identity (year : Std.I32) :
    dt_normalize_year year 4#i32 = ok year := by
  unfold dt_normalize_year
  have h42 : (4#i32 : Std.I32) ≠ 2#i32 := by decide
  have h43 : (4#i32 : Std.I32) ≠ 3#i32 := by decide
  simp only [h42, h43, ↓reduceIte]

/-- Theorem 18: `dt_clamp_leap_second` maps `[0, 60]` into `[0, 59]`, clamping `60 → 59` and preserving `[0, 59]`. -/
theorem dt_clamp_leap_second_bounds (sec : Std.I32) (h0 : 0 ≤ sec.val) (h60 : sec.val ≤ 60) :
    ∃ r : Std.I32, dt_clamp_leap_second sec = ok r ∧
      0 ≤ r.val ∧ r.val ≤ 59 ∧
      (sec.val = 60 → r.val = 59) ∧
      (sec.val ≤ 59 → r.val = sec.val) := by
  unfold dt_clamp_leap_second
  by_cases h : sec = 60#i32
  · simp only [h, ↓reduceIte]
    refine ⟨59#i32, rfl, by decide, by decide, fun _ => rfl, fun hle => by change (60 : Int) ≤ 59 at hle; omega⟩
  · simp only [h, ↓reduceIte]
    have hv : sec.val ≠ 60 := fun heq => h (IScalar.eq_of_val_eq heq)
    refine ⟨sec, rfl, by omega, by omega, fun heq => by omega, fun _ => rfl⟩

/-- Theorem 19: `dt_clamp_leap_second` is idempotent across all 32-bit inputs. -/
theorem dt_clamp_leap_second_idempotent (sec : Std.I32) :
    (do let r ← dt_clamp_leap_second sec; dt_clamp_leap_second r) = dt_clamp_leap_second sec := by
  unfold dt_clamp_leap_second
  rw [result_bind_ok']
  by_cases h : sec = 60#i32
  · simp only [h, ↓reduceIte]
    have hne : (59#i32 : Std.I32) ≠ 60#i32 := by decide
    simp only [hne, ↓reduceIte]
  · simp only [h, ↓reduceIte]

/-- Theorem 20: Every valid RFC 5322 numeric timezone `±HHMM` (`0 ≤ hh ≤ 23`, `0 ≤ mm ≤ 59`) passes `dt_is_valid_offset_seconds`. -/
theorem dt_numeric_offset_in_valid_range (sign hh mm : Std.I32)
    (hh0 : 0 ≤ hh.val) (hh23 : hh.val ≤ 23) (mm0 : 0 ≤ mm.val) (mm59 : mm.val ≤ 59) :
    (do let off ← dt_numeric_offset_seconds sign hh mm; dt_is_valid_offset_seconds off) = ok true := by
  unfold dt_numeric_offset_seconds
  rw [result_bind_ok']
  set hsec := Pion.I32.mul hh 3600#i32
  set msec := Pion.I32.mul mm 60#i32
  set mag := Pion.I32.add hsec msec
  have hh_v : hsec.val = hh.val * 3600 :=
    i32_mul_val' hh 3600#i32 (by change -2147483648 ≤ hh.val * 3600; omega) (by change hh.val * 3600 ≤ 2147483647; omega)
  have hm_v : msec.val = mm.val * 60 :=
    i32_mul_val' mm 60#i32 (by change -2147483648 ≤ mm.val * 60; omega) (by change mm.val * 60 ≤ 2147483647; omega)
  have hmag_v : mag.val = hh.val * 3600 + mm.val * 60 := by
    have ha := i32_add_val' hsec msec (by omega) (by omega)
    change mag.val = hsec.val + msec.val at ha
    omega
  unfold dt_is_valid_offset_seconds
  by_cases hs : sign = 45#i32
  · simp only [hs, ↓reduceIte]
    have hn_v : (Pion.I32.neg mag).val = -mag.val := i32_neg_val' mag (by omega)
    apply congrArg ok
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
    change -86340 ≤ (Pion.I32.neg mag).val ∧ (Pion.I32.neg mag).val ≤ 86340
    omega
  · simp only [hs, ↓reduceIte]
    apply congrArg ok
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff']
    change -86340 ≤ mag.val ∧ mag.val ≤ 86340
    omega

/-- Theorem 21: `-HHMM` and `+HHMM` produce exact opposite signed offset seconds. -/
theorem dt_numeric_offset_negation_symmetry (hh mm : Std.I32)
    (hh0 : 0 ≤ hh.val) (hh23 : hh.val ≤ 23) (mm0 : 0 ≤ mm.val) (mm59 : mm.val ≤ 59) :
    ∃ pos neg : Std.I32,
      dt_numeric_offset_seconds 43#i32 hh mm = ok pos ∧
      dt_numeric_offset_seconds 45#i32 hh mm = ok neg ∧
      neg.val = -pos.val ∧ pos.val = hh.val * 3600 + mm.val * 60 := by
  unfold dt_numeric_offset_seconds
  have h43 : (43#i32 : Std.I32) ≠ 45#i32 := by decide
  simp only [h43, ↓reduceIte]
  set hsec := Pion.I32.mul hh 3600#i32
  set msec := Pion.I32.mul mm 60#i32
  set mag := Pion.I32.add hsec msec
  have hh_v : hsec.val = hh.val * 3600 :=
    i32_mul_val' hh 3600#i32 (by change -2147483648 ≤ hh.val * 3600; omega) (by change hh.val * 3600 ≤ 2147483647; omega)
  have hm_v : msec.val = mm.val * 60 :=
    i32_mul_val' mm 60#i32 (by change -2147483648 ≤ mm.val * 60; omega) (by change mm.val * 60 ≤ 2147483647; omega)
  have hmag_v : mag.val = hh.val * 3600 + mm.val * 60 := by
    have ha := i32_add_val' hsec msec (by omega) (by omega)
    change mag.val = hsec.val + msec.val at ha
    omega
  have hn_v : (Pion.I32.neg mag).val = -mag.val := i32_neg_val' mag (by omega)
  exact ⟨mag, Pion.I32.neg mag, rfl, rfl, hn_v, hmag_v⟩

/-- Theorem 22: Both `+0000` and `-0000` evaluate to offset `0`. -/
theorem dt_numeric_offset_zero_both_signs :
    dt_numeric_offset_seconds 43#i32 0#i32 0#i32 = ok 0#i32 ∧
    dt_numeric_offset_seconds 45#i32 0#i32 0#i32 = ok 0#i32 := by
  constructor <;> (unfold dt_numeric_offset_seconds; rfl)

/-- Theorem 23: `dt_epoch_rem_sec` always yields a non-negative second-of-day in `[0, 86399]` for any `Int64` timestamp. -/
theorem dt_epoch_rem_sec_bounds (local_sec : Std.I64) :
    ∃ r : Std.I64, dt_epoch_rem_sec local_sec = ok r ∧ 0 ≤ r.val ∧ r.val < 86400 := by
  unfold dt_epoch_rem_sec
  rcases i64_rem_86400 local_sec with ⟨rem, hrem, hrem_v⟩
  rw [hrem, result_bind_ok']
  have hrem_lo : -86399 ≤ rem.val := by
    rw [hrem_v]
    have hgt := Int.tmod_lt_of_pos (-local_sec.val) (by decide : (0 : Int) < 86400)
    rw [Int.neg_tmod] at hgt
    omega
  have hrem_hi : rem.val < 86400 := by
    rw [hrem_v]
    exact Int.tmod_lt_of_pos local_sec.val (by decide : (0 : Int) < 86400)
  by_cases hneg : rem < 0#i64
  · simp only [hneg, ↓reduceIte]
    have hv := (i64_lt_iff' rem 0#i64).mp hneg; change rem.val < 0 at hv
    have ha := i64_add_val' rem 86400#i64 (by change -9223372036854775808 ≤ rem.val + 86400; omega) (by change rem.val + 86400 ≤ 9223372036854775807; omega)
    change (Pion.I64.add rem 86400#i64).val = rem.val + 86400 at ha
    exact ⟨Pion.I64.add rem 86400#i64, rfl, by omega, by omega⟩
  · simp only [hneg, ↓reduceIte]
    have hv : ¬ (rem.val < 0) := fun hlt => hneg ((i64_lt_iff' rem 0#i64).mpr hlt)
    exact ⟨rem, rfl, by omega, by omega⟩

/-- Theorem 24: Exact Euclidean division law `dt_epoch_floor_day * 86400 + dt_epoch_rem_sec = local_sec` for both negative (pre-1970) and non-negative timestamps. -/
theorem dt_epoch_floor_rem_identity (local_sec : Std.I64)
    (hlo : -1000000000000000 ≤ local_sec.val) (hhi : local_sec.val ≤ 1000000000000000) :
    ∃ d r : Std.I64,
      dt_epoch_floor_day local_sec = ok d ∧
      dt_epoch_rem_sec local_sec = ok r ∧
      d.val * 86400 + r.val = local_sec.val ∧
      0 ≤ r.val ∧ r.val < 86400 := by
  unfold dt_epoch_floor_day dt_epoch_rem_sec
  rcases i64_div_86400 local_sec with ⟨days, hdays, hdays_v⟩
  rcases i64_rem_86400 local_sec with ⟨rem, hrem, hrem_v⟩
  rw [hdays, hrem, result_bind_ok', result_bind_ok', result_bind_ok']
  have hdiv_law : days.val * 86400 + rem.val = local_sec.val := by
    rw [hdays_v, hrem_v]
    cases local_sec.val with
    | ofNat n => simp only [Int.tdiv, Int.tmod, Int.ofNat_eq_natCast]; omega
    | negSucc n => simp only [Int.tdiv, Int.tmod, Int.ofNat_eq_natCast, Int.negSucc_eq]; omega
  have hrem_lo : -86399 ≤ rem.val := by
    rw [hrem_v]
    have hgt := Int.tmod_lt_of_pos (-local_sec.val) (by decide : (0 : Int) < 86400)
    rw [Int.neg_tmod] at hgt
    omega
  have hrem_hi : rem.val < 86400 := by
    rw [hrem_v]
    exact Int.tmod_lt_of_pos local_sec.val (by decide : (0 : Int) < 86400)
  by_cases hneg : rem < 0#i64
  · simp only [hneg, ↓reduceIte]
    have hv := (i64_lt_iff' rem 0#i64).mp hneg; change rem.val < 0 at hv
    have hs := i64_sub_val' days 1#i64 (by change -9223372036854775808 ≤ days.val - 1; omega) (by change days.val - 1 ≤ 9223372036854775807; omega)
    change (Pion.I64.sub days 1#i64).val = days.val - 1 at hs
    have ha := i64_add_val' rem 86400#i64 (by change -9223372036854775808 ≤ rem.val + 86400; omega) (by change rem.val + 86400 ≤ 9223372036854775807; omega)
    change (Pion.I64.add rem 86400#i64).val = rem.val + 86400 at ha
    refine ⟨Pion.I64.sub days 1#i64, Pion.I64.add rem 86400#i64, rfl, rfl, ?_, by omega, by omega⟩
    linarith
  · simp only [hneg, ↓reduceIte]
    have hv : ¬ (rem.val < 0) := fun hlt => hneg ((i64_lt_iff' rem 0#i64).mpr hlt)
    exact ⟨days, rem, rfl, rfl, hdiv_law, by omega, by omega⟩

end EmailProofs
