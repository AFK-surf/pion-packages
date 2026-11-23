import Aeneas
import PionLean
import Zip.Types
import Zip.Funs
import ZipProofs.Security

open Aeneas Aeneas.Std Result Pion zip

namespace ZipProofs

private lemma i32_to_uint_bv (x : I32) : (Pion.I32.to_uint x).bv = x.bv := by
  change x.bv.signExtend 32 = x.bv
  exact BitVec.signExtend_eq x.bv

private lemma u32_to_int_bv (x : U32) : (Pion.U32.to_int x).bv = x.bv := by
  change BitVec.setWidth 32 x.bv = x.bv
  exact BitVec.setWidth_eq x.bv

private lemma i32_rem_ok (x d : I32) (hx : 0 ≤ x.val) (hd : 0 < d.val) :
    ∃ r, Pion.I32.rem x d = ok r ∧ r.val = x.val % d.val := by
  have hspec := Pion.I32.rem_spec (x := x) (y := d) (by omega) (by omega)
  have hok : Pion.I32.rem x d = ok (⟨BitVec.srem x.bv d.bv⟩ : I32) := by
    unfold Pion.I32.rem
    have h1 : ¬(x.val = -2147483648 ∧ d.val = -1) := by omega
    simp only [h1, ↓reduceIte]
    change IScalar.rem x d = _
    unfold IScalar.rem
    have h2 : (d.val != 0) = true := by simp; omega
    simp only [h2, ↓reduceIte]
  rw [hok] at hspec
  simp only [WP.spec_ok] at hspec
  have htmod : Int.tmod x.val d.val = x.val % d.val := by
    have hx' : x.val = (x.val.toNat : Int) := by omega
    have hd' : d.val = (d.val.toNat : Int) := by omega
    rw [hx', hd']; rfl
  exact ⟨⟨BitVec.srem x.bv d.bv⟩, hok, by rw [hspec, htmod]⟩

/-- Theorem 13: `clamp_int` always returns a value inside `[lo, hi]` when `lo ≤ hi`. -/
theorem clamp_int_bounds (v lo hi : I32) (hle : lo.val ≤ hi.val) :
    ∃ r, clamp_int v lo hi = ok r ∧ lo.val ≤ r.val ∧ r.val ≤ hi.val := by
  unfold clamp_int
  by_cases h1 : v.val < lo.val
  · have ht : v < lo := h1
    simp only [ht, ↓reduceIte]
    exact ⟨lo, rfl, le_refl _, hle⟩
  · have hf1 : ¬(v < lo) := h1
    by_cases h2 : hi.val < v.val
    · have ht : hi < v := h2
      simp only [hf1, ht, ↓reduceIte]
      exact ⟨hi, rfl, hle, le_refl _⟩
    · have hf2 : ¬(hi < v) := h2
      simp only [hf1, hf2, ↓reduceIte]
      exact ⟨v, rfl, by omega, by omega⟩

/-- Theorem 14: `clamp_int` is the identity when `lo ≤ v ≤ hi`. -/
theorem clamp_int_id_of_in_range (v lo hi : I32) (h1 : lo.val ≤ v.val) (h2 : v.val ≤ hi.val) :
    clamp_int v lo hi = ok v := by
  unfold clamp_int
  have hf1 : ¬(v < lo) := by change ¬(v.val < lo.val); omega
  have hf2 : ¬(hi < v) := by change ¬(hi.val < v.val); omega
  simp only [hf1, hf2, ↓reduceIte]

/-- Theorem 15: `days_in_month` always returns a valid day count in `[28, 31]` for MS-DOS years `1980..2107`. -/
theorem days_in_month_bounds (y m : I32) (hlo : 1980 ≤ y.val) (_hhi : y.val ≤ 2107) :
    ∃ d, days_in_month y m = ok d ∧ 28 ≤ d.val ∧ d.val ≤ 31 := by
  unfold days_in_month
  by_cases hm2 : m = 2#i32
  · simp only [hm2, ↓reduceIte]
    rcases i32_rem_ok y 4#i32 (by omega) (by decide) with ⟨r4, hr4, _⟩
    rcases i32_rem_ok y 100#i32 (by omega) (by decide) with ⟨r100, hr100, _⟩
    rcases i32_rem_ok y 400#i32 (by omega) (by decide) with ⟨r400, hr400, _⟩
    rw [hr4, result_bind_ok]
    by_cases h4 : r4 = 0#i32
    · simp only [h4, ↓reduceIte, hr100, result_bind_ok]
      by_cases h100 : (r100 != 0#i32) = true
      · simp only [h100, ↓reduceIte]; exact ⟨29#i32, rfl, by decide, by decide⟩
      · rw [Bool.not_eq_true] at h100
        simp only [h100, Bool.false_eq_true, ↓reduceIte, hr400, result_bind_ok]
        cases (r400 == 0#i32)
        · exact ⟨28#i32, rfl, by decide, by decide⟩
        · exact ⟨29#i32, rfl, by decide, by decide⟩
    · simp only [h4, ↓reduceIte, result_bind_ok, Bool.false_eq_true, hr400]
      cases (r400 == 0#i32)
      · exact ⟨28#i32, rfl, by decide, by decide⟩
      · exact ⟨29#i32, rfl, by decide, by decide⟩
  · simp only [hm2, ↓reduceIte]
    cases ((((m == 4#i32) || (m == 6#i32)) || (m == 9#i32)) || (m == 11#i32))
    · exact ⟨31#i32, rfl, by decide, by decide⟩
    · exact ⟨30#i32, rfl, by decide, by decide⟩

/-- Theorem 16: `days_in_month` distinguishes century leap year 2000 (29 days) from non-leap 2100 (28 days). -/
theorem days_in_month_feb_2000_2100 :
    days_in_month 2000#i32 2#i32 = ok 29#i32 ∧ days_in_month 2100#i32 2#i32 = ok 28#i32 := by
  constructor
  · unfold days_in_month
    simp only [↓reduceIte]
    rcases i32_rem_ok 2000#i32 4#i32 (by decide) (by decide) with ⟨r4, hr4, hv4⟩
    rcases i32_rem_ok 2000#i32 100#i32 (by decide) (by decide) with ⟨r100, hr100, hv100⟩
    rcases i32_rem_ok 2000#i32 400#i32 (by decide) (by decide) with ⟨r400, hr400, hv400⟩
    have er4 : r4 = 0#i32 := iscalar_eq_of_val_eq (by change r4.val = 0; rw [hv4]; decide)
    have er100 : r100 = 0#i32 := iscalar_eq_of_val_eq (by change r100.val = 0; rw [hv100]; decide)
    have er400 : r400 = 0#i32 := iscalar_eq_of_val_eq (by change r400.val = 0; rw [hv400]; decide)
    rw [hr4, er4, result_bind_ok]
    simp only [↓reduceIte, hr100, er100, result_bind_ok, bne_self_eq_false, Bool.false_eq_true, hr400, er400, beq_self_eq_true]
  · unfold days_in_month
    simp only [↓reduceIte]
    rcases i32_rem_ok 2100#i32 4#i32 (by decide) (by decide) with ⟨r4, hr4, hv4⟩
    rcases i32_rem_ok 2100#i32 100#i32 (by decide) (by decide) with ⟨r100, hr100, hv100⟩
    rcases i32_rem_ok 2100#i32 400#i32 (by decide) (by decide) with ⟨r400, hr400, hv400⟩
    have er4 : r4 = 0#i32 := iscalar_eq_of_val_eq (by change r4.val = 0; rw [hv4]; decide)
    have er100 : r100 = 0#i32 := iscalar_eq_of_val_eq (by change r100.val = 0; rw [hv100]; decide)
    have er400 : r400 = 100#i32 := iscalar_eq_of_val_eq (by change r400.val = 100; rw [hv400]; decide)
    rw [hr4, er4, result_bind_ok]
    simp only [↓reduceIte, hr100, er100, result_bind_ok, bne_self_eq_false, Bool.false_eq_true, hr400, er400]
    congr 1

private lemma band_254_range_and_even (s : I32) (hlo : 0 ≤ s.val) (hhi : s.val ≤ 58) :
    0 ≤ (Pion.I32.band s 254#i32).val ∧ (Pion.I32.band s 254#i32).val ≤ 58 ∧
    (Pion.I32.band s 254#i32).bv[0] = false := by
  have htoNat : (Pion.I32.band s 254#i32).bv.toNat ≤ 58 := by
    rw [i32_band_bv, BitVec.toNat_and]
    have hs : s.bv.toNat = s.val.toNat := i32_val_nonneg_toNat s hlo
    exact Nat.le_trans Nat.and_le_left (by omega)
  have hval : (Pion.I32.band s 254#i32).val = (Pion.I32.band s 254#i32).bv.toInt := rfl
  have h2 : (Pion.I32.band s 254#i32).bv.toInt =
      if 2 * (Pion.I32.band s 254#i32).bv.toNat < 2 ^ 32 then ((Pion.I32.band s 254#i32).bv.toNat : Int)
      else ((Pion.I32.band s 254#i32).bv.toNat : Int) - 2 ^ 32 := by
    rw [BitVec.toInt_eq_toNat_cond]; rfl
  have hbit0 : (Pion.I32.band s 254#i32).bv[0] = false := by
    simp only [i32_band_bv, BitVec.getElem_and]
    have h254 : (254#i32).bv[0]'(by decide) = false := by decide
    rw [h254, Bool.and_false]
  exact ⟨by omega, by omega, hbit0⟩

/-- Theorem 17: `DosDateTime.new` is total and always clamps all 6 fields into valid MS-DOS calendar bounds (with even seconds). -/
theorem dos_datetime_new_bounds (y m d h min s : I32) :
    ∃ dt, DosDateTime.new y m d h min s = ok dt ∧
      1980 ≤ dt.year.val ∧ dt.year.val ≤ 2107 ∧
      1 ≤ dt.month.val ∧ dt.month.val ≤ 12 ∧
      1 ≤ dt.day.val ∧ dt.day.val ≤ 31 ∧
      0 ≤ dt.hour.val ∧ dt.hour.val ≤ 23 ∧
      0 ≤ dt.minute.val ∧ dt.minute.val ≤ 59 ∧
      0 ≤ dt.second.val ∧ dt.second.val ≤ 58 ∧ dt.second.bv[0] = false := by
  unfold DosDateTime.new
  have c1 : (1#i32 : I32).val = 1 := rfl
  by_cases hlo : y.val < 1980
  · have ht : y < (1980#i32 : I32) := hlo
    simp only [ht, ↓reduceIte]
    exact ⟨_, rfl, by decide, by decide, by decide, by decide, by decide, by decide,
           by decide, by decide, by decide, by decide, by decide, by decide, by decide⟩
  · have hf1 : ¬(y < (1980#i32 : I32)) := hlo
    by_cases hhi : 2107 < y.val
    · have ht : (2107#i32 : I32) < y := hhi
      simp only [hf1, ht, ↓reduceIte]
      exact ⟨_, rfl, by decide, by decide, by decide, by decide, by decide, by decide,
             by decide, by decide, by decide, by decide, by decide, by decide, by decide⟩
    · have hf2 : ¬((2107#i32 : I32) < y) := hhi
      simp only [hf1, hf2, ↓reduceIte]
      rcases clamp_int_bounds m 1#i32 12#i32 (by decide) with ⟨mc, hmc, hm1, hm2⟩
      rcases days_in_month_bounds y mc (by omega) (by omega) with ⟨md, hmd, hmd1, hmd2⟩
      rcases clamp_int_bounds d 1#i32 md (by omega) with ⟨dc, hdc, hd1, hd2⟩
      rcases clamp_int_bounds h 0#i32 23#i32 (by decide) with ⟨hc, hhc, hh1, hh2⟩
      rcases clamp_int_bounds min 0#i32 59#i32 (by decide) with ⟨minc, hminc, hmin1, hmin2⟩
      rcases clamp_int_bounds s 0#i32 58#i32 (by decide) with ⟨sc, hsc, hs1, hs2⟩
      rw [hmc, result_bind_ok, hmd, result_bind_ok, hdc, result_bind_ok,
          hhc, result_bind_ok, hminc, result_bind_ok, hsc, result_bind_ok]
      have hsec := band_254_range_and_even sc hs1 hs2
      refine ⟨_, rfl, ?_⟩
      dsimp only
      exact ⟨by omega, by omega, hm1, hm2, hd1, by omega, hh1, hh2, hmin1, hmin2,
             hsec.1, hsec.2.1, hsec.2.2⟩

/-- Theorem 18: `DosDateTime.new` is the identity on any valid MS-DOS `DosDateTime` with even seconds. -/
theorem dos_datetime_new_idempotent_on_valid (dt : DosDateTime)
    (hy0 : 1980 ≤ dt.year.val) (hy1 : dt.year.val ≤ 2107)
    (hm0 : 1 ≤ dt.month.val) (hm1 : dt.month.val ≤ 12)
    (max_d : I32) (hdim : days_in_month dt.year dt.month = ok max_d)
    (hd0 : 1 ≤ dt.day.val) (hd1 : dt.day.val ≤ max_d.val)
    (hh0 : 0 ≤ dt.hour.val) (hh1 : dt.hour.val ≤ 23)
    (hmin0 : 0 ≤ dt.minute.val) (hmin1 : dt.minute.val ≤ 59)
    (hs0 : 0 ≤ dt.second.val) (hs1 : dt.second.val ≤ 58) (hseven : dt.second.bv[0] = false) :
    DosDateTime.new dt.year dt.month dt.day dt.hour dt.minute dt.second = ok dt := by
  unfold DosDateTime.new
  have hf1 : ¬(dt.year < (1980#i32 : I32)) := by change ¬(dt.year.val < 1980); omega
  have hf2 : ¬((2107#i32 : I32) < dt.year) := by change ¬(2107 < dt.year.val); omega
  simp only [hf1, hf2, ↓reduceIte]
  rw [clamp_int_id_of_in_range dt.month 1#i32 12#i32 hm0 hm1, result_bind_ok]
  rw [hdim, result_bind_ok]
  rw [clamp_int_id_of_in_range dt.day 1#i32 max_d hd0 hd1, result_bind_ok]
  rw [clamp_int_id_of_in_range dt.hour 0#i32 23#i32 hh0 hh1, result_bind_ok]
  rw [clamp_int_id_of_in_range dt.minute 0#i32 59#i32 hmin0 hmin1, result_bind_ok]
  rw [clamp_int_id_of_in_range dt.second 0#i32 58#i32 hs0 hs1, result_bind_ok]
  have hsband : Pion.I32.band dt.second 254#i32 = dt.second := by
    apply iscalar_eq_of_bv_eq
    apply BitVec.eq_of_getElem_eq
    intro i hi
    have hi32 : i < 32 := hi
    simp only [i32_band_bv, BitVec.getElem_and]
    by_cases h0 : i = 0
    · subst h0; rw [hseven]; simp
    · by_cases h8 : i < 8
      · have h254t : (254#i32).bv[i] = true := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (254#i32).bv.toNat = 254 := by decide
          rw [this]; revert i h0 h8; decide
        rw [h254t, Bool.and_true]
      · have hs_hi := bv32_getElem_high_false dt.second hs0 (by omega : dt.second.val < ((2 ^ 8 : Nat) : Int)) i hi32 (by omega)
        rw [hs_hi, Bool.false_and]
  rw [hsband]

private lemma u32_band_to_int_bounds (x m : U32) (hm : m.val ≤ 127) :
    0 ≤ (Pion.U32.to_int (Pion.U32.band x m)).val ∧ (Pion.U32.to_int (Pion.U32.band x m)).val ≤ m.val := by
  have htn : (Pion.U32.band x m).bv.toNat ≤ m.val := by
    rw [u32_band_bv, BitVec.toNat_and]
    exact Nat.and_le_right
  have hval : (Pion.U32.to_int (Pion.U32.band x m)).val = (Pion.U32.band x m).bv.toInt := rfl
  have h2 : (Pion.U32.band x m).bv.toInt =
      if 2 * (Pion.U32.band x m).bv.toNat < 2 ^ 32 then ((Pion.U32.band x m).bv.toNat : Int)
      else ((Pion.U32.band x m).bv.toNat : Int) - 2 ^ 32 := by
    rw [BitVec.toInt_eq_toNat_cond]; rfl
  omega

/-- Theorem 19: `DosDateTime.from_dos` is total on ANY untrusted `(dos_date, dos_time : U32)` and always produces valid calendar bounds. -/
theorem dos_datetime_from_dos_total_valid (dos_date dos_time : U32) :
    ∃ dt, DosDateTime.from_dos dos_date dos_time = ok dt ∧
      1980 ≤ dt.year.val ∧ dt.year.val ≤ 2107 ∧
      1 ≤ dt.month.val ∧ dt.month.val ≤ 12 ∧
      1 ≤ dt.day.val ∧ dt.day.val ≤ 31 ∧
      0 ≤ dt.hour.val ∧ dt.hour.val ≤ 23 ∧
      0 ≤ dt.minute.val ∧ dt.minute.val ≤ 59 ∧
      0 ≤ dt.second.val ∧ dt.second.val ≤ 58 := by
  unfold DosDateTime.from_dos
  rw [u32_shr_ok dos_date 9#u32 (by decide), result_bind_ok]
  rw [u32_shr_ok dos_date 5#u32 (by decide), result_bind_ok]
  have hy_off := u32_band_to_int_bounds (⟨dos_date.bv >>> (9#u32 : U32).val⟩ : U32) 127#u32 (by decide)
  have c127 : (127#u32 : U32).val = 127 := rfl
  have c1980 : (1980#i32 : I32).val = 1980 := rfl
  have c1 : (1#i32 : I32).val = 1 := rfl
  have hy_val := i32_add_val_of_bounds (Pion.U32.to_int (Pion.U32.band (⟨dos_date.bv >>> (9#u32 : U32).val⟩ : U32) 127#u32)) 1980#i32 (by omega) (by omega)
  rcases clamp_int_bounds (Pion.U32.to_int (Pion.U32.band (⟨dos_date.bv >>> (5#u32 : U32).val⟩ : U32) 15#u32)) 1#i32 12#i32 (by decide) with ⟨mc, hmc, hm1, hm2⟩
  rcases days_in_month_bounds (Pion.I32.add (Pion.U32.to_int (Pion.U32.band (⟨dos_date.bv >>> (9#u32 : U32).val⟩ : U32) 127#u32)) 1980#i32) mc (by omega) (by omega) with ⟨md, hmd, hmd1, hmd2⟩
  rcases clamp_int_bounds (Pion.U32.to_int (Pion.U32.band dos_date 31#u32)) 1#i32 md (by omega) with ⟨dc, hdc, hd1, hd2⟩
  rw [hmc, result_bind_ok, hmd, result_bind_ok, hdc, result_bind_ok]
  rw [u32_shr_ok dos_time 11#u32 (by decide), result_bind_ok]
  rcases clamp_int_bounds (Pion.U32.to_int (Pion.U32.band (⟨dos_time.bv >>> (11#u32 : U32).val⟩ : U32) 31#u32)) 0#i32 23#i32 (by decide) with ⟨hc, hhc, hh1, hh2⟩
  rw [hhc, result_bind_ok]
  rw [u32_shr_ok dos_time 5#u32 (by decide), result_bind_ok]
  rcases clamp_int_bounds (Pion.U32.to_int (Pion.U32.band (⟨dos_time.bv >>> (5#u32 : U32).val⟩ : U32) 63#u32)) 0#i32 59#i32 (by decide) with ⟨minc, hminc, hmin1, hmin2⟩
  rw [hminc, result_bind_ok]
  rcases clamp_int_bounds (Pion.I32.mul (Pion.U32.to_int (Pion.U32.band dos_time 31#u32)) 2#i32) 0#i32 58#i32 (by decide) with ⟨sc, hsc, hs1, hs2⟩
  rw [hsc, result_bind_ok]
  refine ⟨_, rfl, ?_⟩
  dsimp only
  exact ⟨by omega, by omega, hm1, hm2, hd1, by omega, hh1, hh2, hmin1, hmin2, hs1, hs2⟩

/-- Theorem 20: `DosDateTime.to_dos` always produces 16-bit wire values `(dos_date, dos_time) ∈ [0, 65535]²`. -/
theorem dos_datetime_to_dos_u16_range (dt : DosDateTime) :
    ∃ dd dtm, DosDateTime.to_dos dt = ok (dd, dtm) ∧ dd.val ≤ 65535 ∧ dtm.val ≤ 65535 := by
  unfold DosDateTime.to_dos
  rcases dos_datetime_new_bounds dt.year dt.month dt.day dt.hour dt.minute dt.second with
    ⟨c, hc, hy0, hy1, hm0, hm1, hd0, hd1, hh0, hh1, hmin0, hmin1, hs0, hs1, _⟩
  rw [hc, result_bind_ok]
  rw [i32_shr_ok c.second 1#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok _ 9#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok c.month 5#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok c.hour 11#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok c.minute 5#i32 (by decide) (by decide), result_bind_ok]
  refine ⟨_, _, rfl, ?_, ?_⟩
  · have c1980 : (1980#i32 : I32).val = 1980 := rfl
    have hy := i32_sub_val_of_bounds c.year 1980#i32 (by omega) (by omega)
    have hdd_hi : ∀ i (hi : i < 32), 16 ≤ i →
        (Pion.I32.to_uint (Pion.I32.bor (Pion.I32.bor (⟨(Pion.I32.sub c.year 1980#i32).bv <<< (9#i32 : I32).val.toNat⟩ : I32)
          (⟨c.month.bv <<< (5#i32 : I32).val.toNat⟩ : I32)) c.day)).bv[i] = false := by
      intro i hi h16
      have h9n : (9#i32 : I32).val.toNat = 9 := rfl
      have h5n : (5#i32 : I32).val.toNat = 5 := rfl
      simp only [i32_to_uint_bv, i32_bor_bv, i32_mk_bv, h9n, h5n, BitVec.getElem_or, BitVec.getElem_shiftLeft]
      have hyf := bv32_getElem_high_false (Pion.I32.sub c.year 1980#i32) (by omega) (by omega : (Pion.I32.sub c.year 1980#i32).val < ((2 ^ 7 : Nat) : Int)) (i - 9) (by omega) (by omega)
      have hmf := bv32_getElem_high_false c.month (by omega) (by omega : c.month.val < ((2 ^ 4 : Nat) : Int)) (i - 5) (by omega) (by omega)
      have hdf := bv32_getElem_high_false c.day (by omega) (by omega : c.day.val < ((2 ^ 5 : Nat) : Int)) i hi (by omega)
      simp only [show ¬(i < 9) by omega, show ¬(i < 5) by omega, decide_false, Bool.not_false,
                 Bool.true_and, hyf, hmf, hdf, Bool.or_false]
    set dd := Pion.I32.to_uint (Pion.I32.bor (Pion.I32.bor (⟨(Pion.I32.sub c.year 1980#i32).bv <<< (9#i32 : I32).val.toNat⟩ : I32)
      (⟨c.month.bv <<< (5#i32 : I32).val.toNat⟩ : I32)) c.day)
    have hlt : dd.bv.toNat < 2 ^ 16 := by
      have hsub : ∀ j, 16 ≤ j → dd.bv.toNat.testBit j = false := by
        intro j hj
        by_cases hj32 : j < 32
        · rw [← BitVec.getElem_eq_testBit_toNat]; exact hdd_hi j hj32 hj
        · exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le dd.bv.isLt (Nat.pow_le_pow_right (by omega) (by omega)))
      have hmod : dd.bv.toNat % 2 ^ 16 = dd.bv.toNat := by
        apply Nat.eq_of_testBit_eq
        intro j
        rw [Nat.testBit_mod_two_pow]
        by_cases hj16 : j < 16
        · simp only [hj16, decide_true, Bool.true_and]
        · simp only [hj16, decide_false, Bool.false_and, hsub j (by omega)]
      have := Nat.mod_lt dd.bv.toNat (by decide : 0 < 2 ^ 16)
      omega
    change dd.bv.toNat ≤ 65535
    omega
  · have hdt_hi : ∀ i (hi : i < 32), 16 ≤ i →
        (Pion.I32.to_uint (Pion.I32.bor (Pion.I32.bor (⟨c.hour.bv <<< (11#i32 : I32).val.toNat⟩ : I32)
          (⟨c.minute.bv <<< (5#i32 : I32).val.toNat⟩ : I32)) (⟨c.second.bv.sshiftRight (1#i32 : I32).val.toNat⟩ : I32))).bv[i] = false := by
      intro i hi h16
      have h11n : (11#i32 : I32).val.toNat = 11 := rfl
      have h5n : (5#i32 : I32).val.toNat = 5 := rfl
      have h1n : (1#i32 : I32).val.toNat = 1 := rfl
      simp only [i32_to_uint_bv, i32_bor_bv, i32_mk_bv, h11n, h5n, h1n, BitVec.getElem_or, BitVec.getElem_shiftLeft, BitVec.getElem_sshiftRight]
      have hhf := bv32_getElem_high_false c.hour (by omega) (by omega : c.hour.val < ((2 ^ 5 : Nat) : Int)) (i - 11) (by omega) (by omega)
      have hmf := bv32_getElem_high_false c.minute (by omega) (by omega : c.minute.val < ((2 ^ 6 : Nat) : Int)) (i - 5) (by omega) (by omega)
      have hsf : (if h : 1 + i < 32 then c.second.bv[1 + i] else c.second.bv.msb) = false := by
        by_cases hlt : 1 + i < 32
        · simp only [hlt, ↓reduceDIte]
          exact bv32_getElem_high_false c.second (by omega) (by omega : c.second.val < ((2 ^ 6 : Nat) : Int)) (1 + i) hlt (by omega)
        · simp only [hlt, ↓reduceDIte, BitVec.msb_eq_getLsbD_last, BitVec.getLsbD_eq_getElem (by omega : 32 - 1 < 32)]
          exact bv32_getElem_high_false c.second (by omega) (by omega : c.second.val < ((2 ^ 6 : Nat) : Int)) 31 (by omega) (by omega)
      simp only [show ¬(i < 11) by omega, show ¬(i < 5) by omega, decide_false, Bool.not_false,
                 Bool.true_and, hhf, hmf, hsf, Bool.or_false]
    set dt' := Pion.I32.to_uint (Pion.I32.bor (Pion.I32.bor (⟨c.hour.bv <<< (11#i32 : I32).val.toNat⟩ : I32)
      (⟨c.minute.bv <<< (5#i32 : I32).val.toNat⟩ : I32)) (⟨c.second.bv.sshiftRight (1#i32 : I32).val.toNat⟩ : I32))
    have hlt : dt'.bv.toNat < 2 ^ 16 := by
      have hsub : ∀ j, 16 ≤ j → dt'.bv.toNat.testBit j = false := by
        intro j hj
        by_cases hj32 : j < 32
        · rw [← BitVec.getElem_eq_testBit_toNat]; exact hdt_hi j hj32 hj
        · exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le dt'.bv.isLt (Nat.pow_le_pow_right (by omega) (by omega)))
      have hmod : dt'.bv.toNat % 2 ^ 16 = dt'.bv.toNat := by
        apply Nat.eq_of_testBit_eq
        intro j
        rw [Nat.testBit_mod_two_pow]
        by_cases hj16 : j < 16
        · simp only [hj16, decide_true, Bool.true_and]
        · simp only [hj16, decide_false, Bool.false_and, hsub j (by omega)]
      have := Nat.mod_lt dt'.bv.toNat (by decide : 0 < 2 ^ 16)
      omega
    change dt'.bv.toNat ≤ 65535
    omega

/-- Theorem 21: MS-DOS epoch `1980-01-01 00:00:00` (`DosDateTime.default`) round-trips cleanly through `to_dos`/`from_dos`. -/
theorem dos_datetime_default_roundtrip :
    (do
      let dt ← DosDateTime.default
      let p ← DosDateTime.to_dos dt
      DosDateTime.from_dos p.1 p.2) = ok (DosDateTime.mk 1980#i32 1#i32 1#i32 0#i32 0#i32 0#i32) := by
  unfold DosDateTime.default DosDateTime.to_dos DosDateTime.from_dos
  simp only [result_bind_ok]
  have hnew : DosDateTime.new 1980#i32 1#i32 1#i32 0#i32 0#i32 0#i32 =
      ok (DosDateTime.mk 1980#i32 1#i32 1#i32 0#i32 0#i32 0#i32) :=
    dos_datetime_new_idempotent_on_valid (DosDateTime.mk 1980#i32 1#i32 1#i32 0#i32 0#i32 0#i32)
      (by decide) (by decide) (by decide) (by decide) 31#i32 (by simp [days_in_month])
      (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide) (by decide)
  rw [hnew, result_bind_ok]
  rw [i32_shr_ok 0#i32 1#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok _ 9#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok 1#i32 5#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok 0#i32 11#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok 0#i32 5#i32 (by decide) (by decide), result_bind_ok, result_bind_ok]
  rw [u32_shr_ok _ 9#u32 (by decide), result_bind_ok]
  rw [u32_shr_ok _ 5#u32 (by decide), result_bind_ok]
  have hdd : (Pion.I32.to_uint (Pion.I32.bor (Pion.I32.bor (⟨(Pion.I32.sub 1980#i32 1980#i32).bv <<< (9#i32 : I32).val.toNat⟩ : I32)
      (⟨(1#i32 : I32).bv <<< (5#i32 : I32).val.toNat⟩ : I32)) 1#i32)) = 33#u32 := by decide
  have hdt : (Pion.I32.to_uint (Pion.I32.bor (Pion.I32.bor (⟨(0#i32 : I32).bv <<< (11#i32 : I32).val.toNat⟩ : I32)
      (⟨(0#i32 : I32).bv <<< (5#i32 : I32).val.toNat⟩ : I32)) (⟨(0#i32 : I32).bv.sshiftRight (1#i32 : I32).val.toNat⟩ : I32))) = 0#u32 := by decide
  rw [hdd, hdt]
  have hy : Pion.I32.add (Pion.U32.to_int (Pion.U32.band (⟨(33#u32 : U32).bv >>> (9#u32 : U32).val⟩ : U32) 127#u32)) 1980#i32 = 1980#i32 := by decide
  have hm : Pion.U32.to_int (Pion.U32.band (⟨(33#u32 : U32).bv >>> (5#u32 : U32).val⟩ : U32) 15#u32) = 1#i32 := by decide
  have hd : Pion.U32.to_int (Pion.U32.band 33#u32 31#u32) = 1#i32 := by decide
  rw [hy, hm, hd]
  rw [clamp_int_id_of_in_range 1#i32 1#i32 12#i32 (by decide) (by decide), result_bind_ok]
  have hdim : days_in_month 1980#i32 1#i32 = ok 31#i32 := by simp [days_in_month]
  rw [hdim, result_bind_ok]
  rw [clamp_int_id_of_in_range 1#i32 1#i32 31#i32 (by decide) (by decide), result_bind_ok]
  rw [u32_shr_ok 0#u32 11#u32 (by decide), result_bind_ok]
  have hh : Pion.U32.to_int (Pion.U32.band (⟨(0#u32 : U32).bv >>> (11#u32 : U32).val⟩ : U32) 31#u32) = 0#i32 := by decide
  rw [hh, clamp_int_id_of_in_range 0#i32 0#i32 23#i32 (by decide) (by decide), result_bind_ok]
  rw [u32_shr_ok 0#u32 5#u32 (by decide), result_bind_ok]
  have hmin : Pion.U32.to_int (Pion.U32.band (⟨(0#u32 : U32).bv >>> (5#u32 : U32).val⟩ : U32) 63#u32) = 0#i32 := by decide
  rw [hmin, clamp_int_id_of_in_range 0#i32 0#i32 59#i32 (by decide) (by decide), result_bind_ok]
  have hs : Pion.I32.mul (Pion.U32.to_int (Pion.U32.band 0#u32 31#u32)) 2#i32 = 0#i32 := by decide
  rw [hs, clamp_int_id_of_in_range 0#i32 0#i32 58#i32 (by decide) (by decide), result_bind_ok]

/-- Theorem 22: Full APPNOTE 6.3.10 MS-DOS timestamp bijection (`from_dos ∘ to_dos = id`) for ALL valid even-second `DosDateTime`s. -/
theorem dos_datetime_roundtrip (dt : DosDateTime)
    (hy0 : 1980 ≤ dt.year.val) (hy1 : dt.year.val ≤ 2107)
    (hm0 : 1 ≤ dt.month.val) (hm1 : dt.month.val ≤ 12)
    (max_d : I32) (hdim : days_in_month dt.year dt.month = ok max_d)
    (hd0 : 1 ≤ dt.day.val) (hd1 : dt.day.val ≤ max_d.val)
    (hh0 : 0 ≤ dt.hour.val) (hh1 : dt.hour.val ≤ 23)
    (hmin0 : 0 ≤ dt.minute.val) (hmin1 : dt.minute.val ≤ 59)
    (hs0 : 0 ≤ dt.second.val) (hs1 : dt.second.val ≤ 58) (hseven : dt.second.bv[0] = false) :
    (do
      let p ← DosDateTime.to_dos dt
      DosDateTime.from_dos p.1 p.2) = ok dt := by
  have hmax_le : max_d.val ≤ 31 := by
    rcases days_in_month_bounds dt.year dt.month hy0 hy1 with ⟨md, hmd, _, hmd2⟩
    have heq := result_ok_inj (hdim.symm.trans hmd)
    subst heq; exact hmd2
  unfold DosDateTime.to_dos DosDateTime.from_dos
  rw [dos_datetime_new_idempotent_on_valid dt hy0 hy1 hm0 hm1 max_d hdim hd0 hd1 hh0 hh1 hmin0 hmin1 hs0 hs1 hseven, result_bind_ok]
  rw [i32_shr_ok dt.second 1#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok _ 9#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok dt.month 5#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok dt.hour 11#i32 (by decide) (by decide), result_bind_ok]
  rw [i32_shl_ok dt.minute 5#i32 (by decide) (by decide), result_bind_ok, result_bind_ok]
  rw [u32_shr_ok _ 9#u32 (by decide), result_bind_ok]
  rw [u32_shr_ok _ 5#u32 (by decide), result_bind_ok]
  have c1980 : (1980#i32 : I32).val = 1980 := rfl
  have hy_sub := i32_sub_val_of_bounds dt.year 1980#i32 (by omega) (by omega)
  have h9n : (9#i32 : I32).val.toNat = 9 := rfl
  have h5n : (5#i32 : I32).val.toNat = 5 := rfl
  have h11n : (11#i32 : I32).val.toNat = 11 := rfl
  have h1n : (1#i32 : I32).val.toNat = 1 := rfl
  have u9n : (9#u32 : U32).val = 9 := rfl
  have u5n : (5#u32 : U32).val = 5 := rfl
  have u11n : (11#u32 : U32).val = 11 := rfl
  -- Recover year offset
  have hy_rec : Pion.U32.to_int (Pion.U32.band (⟨(Pion.I32.to_uint (Pion.I32.bor (Pion.I32.bor
      (⟨(Pion.I32.sub dt.year 1980#i32).bv <<< (9#i32 : I32).val.toNat⟩ : I32)
      (⟨dt.month.bv <<< (5#i32 : I32).val.toNat⟩ : I32)) dt.day)).bv >>> (9#u32 : U32).val⟩ : U32) 127#u32) =
      Pion.I32.sub dt.year 1980#i32 := by
    apply iscalar_eq_of_bv_eq
    apply BitVec.eq_of_getElem_eq
    intro i hi
    have hi32 : i < 32 := hi
    simp only [u32_to_int_bv, u32_band_bv, u32_mk_bv, u9n, BitVec.getElem_and, BitVec.getElem_ushiftRight]
    by_cases h7 : i < 7
    · have h127t : (127#u32).bv[i] = true := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (127#u32).bv.toNat = 127 := by decide
        rw [this]; revert i h7; decide
      have hlt : 9 + i < 32 := by omega
      simp only [h127t, Bool.and_true, BitVec.getLsbD_eq_getElem hlt, i32_to_uint_bv, i32_bor_bv, i32_mk_bv, h9n, h5n,
                 BitVec.getElem_or, BitVec.getElem_shiftLeft,
                 show ¬(9 + i < 9) by omega, show ¬(9 + i < 5) by omega, decide_false, Bool.not_false, Bool.true_and]
      have hmf := bv32_getElem_high_false dt.month (by omega) (by omega : dt.month.val < ((2 ^ 4 : Nat) : Int)) (9 + i - 5) (by omega) (by omega)
      have hdf := bv32_getElem_high_false dt.day (by omega) (by omega : dt.day.val < ((2 ^ 5 : Nat) : Int)) (9 + i) (by omega) (by omega)
      rw [hmf, hdf, Bool.or_false, Bool.or_false]
      congr 1; omega
    · have h127f : (127#u32).bv[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (127#u32).bv.toNat = 127 := by decide
        rw [this]
        exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 7 ≤ i)))
      have hyf := bv32_getElem_high_false (Pion.I32.sub dt.year 1980#i32) (by omega) (by omega : (Pion.I32.sub dt.year 1980#i32).val < ((2 ^ 7 : Nat) : Int)) i hi32 (by omega)
      rw [h127f, hyf, Bool.and_false]
  have hy_eq : Pion.I32.add (Pion.I32.sub dt.year 1980#i32) 1980#i32 = dt.year := by
    apply iscalar_eq_of_val_eq
    have ha := i32_add_val_of_bounds (Pion.I32.sub dt.year 1980#i32) 1980#i32 (by omega) (by omega)
    omega
  -- Recover month
  have hm_rec : Pion.U32.to_int (Pion.U32.band (⟨(Pion.I32.to_uint (Pion.I32.bor (Pion.I32.bor
      (⟨(Pion.I32.sub dt.year 1980#i32).bv <<< (9#i32 : I32).val.toNat⟩ : I32)
      (⟨dt.month.bv <<< (5#i32 : I32).val.toNat⟩ : I32)) dt.day)).bv >>> (5#u32 : U32).val⟩ : U32) 15#u32) =
      dt.month := by
    apply iscalar_eq_of_bv_eq
    apply BitVec.eq_of_getElem_eq
    intro i hi
    have hi32 : i < 32 := hi
    simp only [u32_to_int_bv, u32_band_bv, u32_mk_bv, u5n, BitVec.getElem_and, BitVec.getElem_ushiftRight]
    by_cases h4 : i < 4
    · have h15t : (15#u32).bv[i] = true := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (15#u32).bv.toNat = 15 := by decide
        rw [this]; revert i h4; decide
      have hlt : 5 + i < 32 := by omega
      simp only [h15t, Bool.and_true, BitVec.getLsbD_eq_getElem hlt, i32_to_uint_bv, i32_bor_bv, i32_mk_bv, h9n, h5n,
                 BitVec.getElem_or, BitVec.getElem_shiftLeft,
                 show 5 + i < 9 by omega, show ¬(5 + i < 5) by omega, decide_true, decide_false,
                 Bool.not_true, Bool.not_false, Bool.false_and, Bool.true_and, Bool.false_or]
      have hdf := bv32_getElem_high_false dt.day (by omega) (by omega : dt.day.val < ((2 ^ 5 : Nat) : Int)) (5 + i) (by omega) (by omega)
      rw [hdf, Bool.or_false]
      congr 1; omega
    · have h15f : (15#u32).bv[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (15#u32).bv.toNat = 15 := by decide
        rw [this]
        exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 4 ≤ i)))
      have hmf := bv32_getElem_high_false dt.month (by omega) (by omega : dt.month.val < ((2 ^ 4 : Nat) : Int)) i hi32 (by omega)
      rw [h15f, hmf, Bool.and_false]
  -- Recover day
  have hd_rec : Pion.U32.to_int (Pion.U32.band (Pion.I32.to_uint (Pion.I32.bor (Pion.I32.bor
      (⟨(Pion.I32.sub dt.year 1980#i32).bv <<< (9#i32 : I32).val.toNat⟩ : I32)
      (⟨dt.month.bv <<< (5#i32 : I32).val.toNat⟩ : I32)) dt.day)) 31#u32) = dt.day := by
    apply iscalar_eq_of_bv_eq
    apply BitVec.eq_of_getElem_eq
    intro i hi
    have hi32 : i < 32 := hi
    simp only [u32_to_int_bv, u32_band_bv, BitVec.getElem_and]
    by_cases h5 : i < 5
    · have h31t : (31#u32).bv[i] = true := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (31#u32).bv.toNat = 31 := by decide
        rw [this]; revert i h5; decide
      simp only [h31t, Bool.and_true, i32_to_uint_bv, i32_bor_bv, i32_mk_bv, h9n, h5n,
                 BitVec.getElem_or, BitVec.getElem_shiftLeft,
                 show i < 9 by omega, show i < 5 by omega, decide_true, Bool.not_true, Bool.false_and, Bool.false_or]
    · have h31f : (31#u32).bv[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (31#u32).bv.toNat = 31 := by decide
        rw [this]
        exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 5 ≤ i)))
      have hdf := bv32_getElem_high_false dt.day (by omega) (by omega : dt.day.val < ((2 ^ 5 : Nat) : Int)) i hi32 (by omega)
      rw [h31f, hdf, Bool.and_false]
  rw [hy_rec, hy_eq, hm_rec, hd_rec]
  rw [clamp_int_id_of_in_range dt.month 1#i32 12#i32 hm0 hm1, result_bind_ok]
  rw [hdim, result_bind_ok]
  rw [clamp_int_id_of_in_range dt.day 1#i32 max_d hd0 hd1, result_bind_ok]
  rw [u32_shr_ok _ 11#u32 (by decide), result_bind_ok]
  -- Recover hour
  have hh_rec : Pion.U32.to_int (Pion.U32.band (⟨(Pion.I32.to_uint (Pion.I32.bor (Pion.I32.bor
      (⟨dt.hour.bv <<< (11#i32 : I32).val.toNat⟩ : I32)
      (⟨dt.minute.bv <<< (5#i32 : I32).val.toNat⟩ : I32))
      (⟨dt.second.bv.sshiftRight (1#i32 : I32).val.toNat⟩ : I32))).bv >>> (11#u32 : U32).val⟩ : U32) 31#u32) =
      dt.hour := by
    apply iscalar_eq_of_bv_eq
    apply BitVec.eq_of_getElem_eq
    intro i hi
    have hi32 : i < 32 := hi
    simp only [u32_to_int_bv, u32_band_bv, u32_mk_bv, u11n, BitVec.getElem_and, BitVec.getElem_ushiftRight]
    by_cases h5 : i < 5
    · have h31t : (31#u32).bv[i] = true := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (31#u32).bv.toNat = 31 := by decide
        rw [this]; revert i h5; decide
      have hlt : 11 + i < 32 := by omega
      simp only [h31t, Bool.and_true, BitVec.getLsbD_eq_getElem hlt, i32_to_uint_bv, i32_bor_bv, i32_mk_bv, h11n, h5n, h1n,
                 BitVec.getElem_or, BitVec.getElem_shiftLeft,
                 BitVec.getElem_sshiftRight, show ¬(11 + i < 11) by omega, show ¬(11 + i < 5) by omega,
                 show 1 + (11 + i) < 32 by omega, decide_false, Bool.not_false, Bool.true_and, ↓reduceDIte]
      have hmf := bv32_getElem_high_false dt.minute (by omega) (by omega : dt.minute.val < ((2 ^ 6 : Nat) : Int)) (11 + i - 5) (by omega) (by omega)
      have hsf := bv32_getElem_high_false dt.second (by omega) (by omega : dt.second.val < ((2 ^ 6 : Nat) : Int)) (1 + (11 + i)) (by omega) (by omega)
      rw [hmf, hsf, Bool.or_false, Bool.or_false]
      congr 1; omega
    · have h31f : (31#u32).bv[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (31#u32).bv.toNat = 31 := by decide
        rw [this]
        exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 5 ≤ i)))
      have hhf := bv32_getElem_high_false dt.hour (by omega) (by omega : dt.hour.val < ((2 ^ 5 : Nat) : Int)) i hi32 (by omega)
      rw [h31f, hhf, Bool.and_false]
  rw [hh_rec, clamp_int_id_of_in_range dt.hour 0#i32 23#i32 hh0 hh1, result_bind_ok]
  rw [u32_shr_ok _ 5#u32 (by decide), result_bind_ok]
  -- Recover minute
  have hmin_rec : Pion.U32.to_int (Pion.U32.band (⟨(Pion.I32.to_uint (Pion.I32.bor (Pion.I32.bor
      (⟨dt.hour.bv <<< (11#i32 : I32).val.toNat⟩ : I32)
      (⟨dt.minute.bv <<< (5#i32 : I32).val.toNat⟩ : I32))
      (⟨dt.second.bv.sshiftRight (1#i32 : I32).val.toNat⟩ : I32))).bv >>> (5#u32 : U32).val⟩ : U32) 63#u32) =
      dt.minute := by
    apply iscalar_eq_of_bv_eq
    apply BitVec.eq_of_getElem_eq
    intro i hi
    have hi32 : i < 32 := hi
    simp only [u32_to_int_bv, u32_band_bv, u32_mk_bv, u5n, BitVec.getElem_and, BitVec.getElem_ushiftRight]
    by_cases h6 : i < 6
    · have h63t : (63#u32).bv[i] = true := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (63#u32).bv.toNat = 63 := by decide
        rw [this]; revert i h6; decide
      have hlt : 5 + i < 32 := by omega
      simp only [h63t, Bool.and_true, BitVec.getLsbD_eq_getElem hlt, i32_to_uint_bv, i32_bor_bv, i32_mk_bv, h11n, h5n, h1n,
                 BitVec.getElem_or, BitVec.getElem_shiftLeft,
                 BitVec.getElem_sshiftRight, show 5 + i < 11 by omega, show ¬(5 + i < 5) by omega,
                 show 1 + (5 + i) < 32 by omega, decide_true, decide_false,
                 Bool.not_true, Bool.not_false, Bool.false_and, Bool.true_and, Bool.false_or, ↓reduceDIte]
      have hsf := bv32_getElem_high_false dt.second (by omega) (by omega : dt.second.val < ((2 ^ 6 : Nat) : Int)) (1 + (5 + i)) (by omega) (by omega)
      rw [hsf, Bool.or_false]
      congr 1; omega
    · have h63f : (63#u32).bv[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (63#u32).bv.toNat = 63 := by decide
        rw [this]
        exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 6 ≤ i)))
      have hmf := bv32_getElem_high_false dt.minute (by omega) (by omega : dt.minute.val < ((2 ^ 6 : Nat) : Int)) i hi32 (by omega)
      rw [h63f, hmf, Bool.and_false]
  rw [hmin_rec, clamp_int_id_of_in_range dt.minute 0#i32 59#i32 hmin0 hmin1, result_bind_ok]
  -- Recover second (even)
  have hs_half : Pion.U32.to_int (Pion.U32.band (Pion.I32.to_uint (Pion.I32.bor (Pion.I32.bor
      (⟨dt.hour.bv <<< (11#i32 : I32).val.toNat⟩ : I32)
      (⟨dt.minute.bv <<< (5#i32 : I32).val.toNat⟩ : I32))
      (⟨dt.second.bv.sshiftRight (1#i32 : I32).val.toNat⟩ : I32))) 31#u32) =
      (⟨dt.second.bv.sshiftRight 1⟩ : I32) := by
    apply iscalar_eq_of_bv_eq
    apply BitVec.eq_of_getElem_eq
    intro i hi
    have hi32 : i < 32 := hi
    simp only [u32_to_int_bv, u32_band_bv, BitVec.getElem_and]
    by_cases h5 : i < 5
    · have h31t : (31#u32).bv[i] = true := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (31#u32).bv.toNat = 31 := by decide
        rw [this]; revert i h5; decide
      simp only [h31t, Bool.and_true, i32_to_uint_bv, i32_bor_bv, i32_mk_bv, h11n, h5n, h1n,
                 BitVec.getElem_or, BitVec.getElem_shiftLeft,
                 show i < 11 by omega, show i < 5 by omega, decide_true, Bool.not_true, Bool.false_and, Bool.false_or]
    · have h31f : (31#u32).bv[i] = false := by
        rw [BitVec.getElem_eq_testBit_toNat]
        have : (31#u32).bv.toNat = 31 := by decide
        rw [this]
        exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 5 ≤ i)))
      rw [h31f, Bool.and_false, BitVec.getElem_sshiftRight]
      by_cases hlt : 1 + i < 32
      · simp only [hlt, ↓reduceDIte]
        exact (bv32_getElem_high_false dt.second hs0 (by omega : dt.second.val < ((2 ^ 6 : Nat) : Int)) (1 + i) hlt (by omega)).symm
      · simp only [hlt, ↓reduceDIte, BitVec.msb_eq_getLsbD_last, BitVec.getLsbD_eq_getElem (by omega : 32 - 1 < 32)]
        exact (bv32_getElem_high_false dt.second hs0 (by omega : dt.second.val < ((2 ^ 6 : Nat) : Int)) 31 (by omega) (by omega)).symm
  have hs_mul : Pion.I32.mul (⟨dt.second.bv.sshiftRight 1⟩ : I32) 2#i32 = dt.second := by
    apply iscalar_eq_of_bv_eq
    apply BitVec.eq_of_getElem_eq
    intro i hi
    have hi32 : i < 32 := hi
    have hmul_shl : (Pion.I32.mul (⟨dt.second.bv.sshiftRight 1⟩ : I32) 2#i32).bv =
        (dt.second.bv.sshiftRight 1) <<< 1 := by
      change (dt.second.bv.sshiftRight 1) * (2#32) = (dt.second.bv.sshiftRight 1) <<< 1
      rw [BitVec.shiftLeft_eq_mul_twoPow]; rfl
    simp only [hmul_shl, BitVec.getElem_shiftLeft]
    by_cases h0 : i = 0
    · subst h0; simp [hseven]
    · have hge : ¬(i < 1) := by omega
      have hlt : 1 + (i - 1) < 32 := by omega
      simp only [hge, decide_false, Bool.not_false, Bool.true_and, BitVec.getElem_sshiftRight, hlt, ↓reduceDIte]
      congr 1; omega
  rw [hs_half, hs_mul, clamp_int_id_of_in_range dt.second 0#i32 58#i32 hs0 hs1, result_bind_ok]

end ZipProofs
