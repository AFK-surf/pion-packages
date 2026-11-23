import Aeneas
import PionLean
import Asn1.Types
import Asn1.Funs
import Asn1Proofs.TagDer

open Aeneas Aeneas.Std Result Pion asn1

namespace Asn1Proofs

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

private lemma is_leap_year_total (y : I32) (hlo : 0 ≤ y.val) :
    ∃ b, is_leap_year y = ok b := by
  unfold is_leap_year
  rcases i32_rem_ok y 4#i32 hlo (by decide) with ⟨r4, hr4, _⟩
  rcases i32_rem_ok y 100#i32 hlo (by decide) with ⟨r100, hr100, _⟩
  rcases i32_rem_ok y 400#i32 hlo (by decide) with ⟨r400, hr400, _⟩
  rw [hr4, result_bind_ok]
  by_cases h4 : r4 = 0#i32
  · simp only [h4, ↓reduceIte, hr100, result_bind_ok]
    by_cases h100 : (r100 != 0#i32) = true
    · simp only [h100, ↓reduceIte]; exact ⟨true, rfl⟩
    · rw [Bool.not_eq_true] at h100
      simp only [h100, result_bind_ok, Bool.false_eq_true, ↓reduceIte, hr400]
      exact ⟨_, rfl⟩
  · simp only [h4, ↓reduceIte, result_bind_ok, Bool.false_eq_true, hr400]
    exact ⟨_, rfl⟩

/-- Theorem 15: RFC 5280 Gregorian `is_leap_year` exact 4/100/400 specification for years `0..9999`. -/
theorem is_leap_year_spec (y : I32) (hlo : 0 ≤ y.val) (_hhi : y.val ≤ 9999) :
    is_leap_year y = ok true ↔ (y.val % 4 = 0 ∧ y.val % 100 ≠ 0) ∨ y.val % 400 = 0 := by
  unfold is_leap_year
  rcases i32_rem_ok y 4#i32 hlo (by decide) with ⟨r4, hr4, hv4⟩
  rcases i32_rem_ok y 100#i32 hlo (by decide) with ⟨r100, hr100, hv100⟩
  rcases i32_rem_ok y 400#i32 hlo (by decide) with ⟨r400, hr400, hv400⟩
  have c4 : (4#i32 : I32).val = 4 := rfl
  have c100 : (100#i32 : I32).val = 100 := rfl
  have c400 : (400#i32 : I32).val = 400 := rfl
  have c0 : (0#i32 : I32).val = 0 := rfl
  rw [c4] at hv4
  rw [c100] at hv100
  rw [c400] at hv400
  rw [hr4, result_bind_ok]
  by_cases h4 : r4 = 0#i32
  · simp only [h4, ↓reduceIte, hr100, result_bind_ok]
    have hy4 : y.val % 4 = 0 := by rw [← hv4, h4, c0]
    by_cases h100 : r100 = 0#i32
    · have hne : (r100 != 0#i32) = false := by rw [h100]; decide
      simp only [hne, result_bind_ok, Bool.false_eq_true, ↓reduceIte, hr400]
      have hy100 : y.val % 100 = 0 := by rw [← hv100, h100, c0]
      constructor
      · intro h
        have ht := beq_iff_eq.mp (result_ok_inj h)
        right; rw [← hv400, ht, c0]
      · intro h
        rcases h with ⟨_, hne100⟩ | h400z
        · exact absurd hy100 hne100
        · have hr400z : r400 = 0#i32 := iscalar_eq_of_val_eq (by omega)
          rw [hr400z]; rfl
    · have hne : (r100 != 0#i32) = true := by
        simp only [bne_iff_ne, ne_eq]; exact h100
      simp only [hne, ↓reduceIte]
      have hy100 : y.val % 100 ≠ 0 := by
        intro hz; apply h100; exact iscalar_eq_of_val_eq (by omega)
      simp [hy4, hy100]
  · simp only [h4, ↓reduceIte, result_bind_ok, Bool.false_eq_true, hr400]
    have hy4 : y.val % 4 ≠ 0 := by
      intro hz; apply h4; exact iscalar_eq_of_val_eq (by omega)
    have hy400 : y.val % 400 ≠ 0 := by omega
    have hr400nz : r400 ≠ 0#i32 := by
      intro hz; apply hy400; rw [← hv400, hz, c0]
    have hbeq : (r400 == 0#i32) = false := beq_false_of_ne hr400nz
    rw [hbeq]
    constructor
    · intro h; exact absurd (result_ok_inj h) (by decide)
    · intro h; rcases h with ⟨h4z, _⟩ | h400z <;> omega

/-- Theorem 16: Gregorian `is_leap_year` is strictly 400-year periodic. -/
theorem is_leap_year_period_400 (y : I32) (hlo : 0 ≤ y.val) (hhi : y.val ≤ 9599) :
    is_leap_year (Pion.I32.add y 400#i32) = is_leap_year y := by
  have c400 : (400#i32 : I32).val = 400 := rfl
  have hadd : (Pion.I32.add y 400#i32).val = y.val + 400 := by
    have := i32_add_val_of_bounds y 400#i32 (by omega) (by omega)
    omega
  have hspec1 := is_leap_year_spec (Pion.I32.add y 400#i32) (by omega) (by omega)
  have hspec2 := is_leap_year_spec y hlo (by omega)
  rcases is_leap_year_total (Pion.I32.add y 400#i32) (by omega) with ⟨b1, hb1⟩
  rcases is_leap_year_total y hlo with ⟨b2, hb2⟩
  rw [hb1, hb2]
  congr 1
  have hiff : (b1 = true) ↔ (b2 = true) := by
    have h1 : b1 = true ↔ is_leap_year (Pion.I32.add y 400#i32) = ok true := by
      rw [hb1]; constructor <;> intro h <;> [exact congrArg ok h; exact result_ok_inj h]
    have h2 : b2 = true ↔ is_leap_year y = ok true := by
      rw [hb2]; constructor <;> intro h <;> [exact congrArg ok h; exact result_ok_inj h]
    rw [h1, h2, hspec1, hspec2, hadd]
    omega
  cases b1 <;> cases b2 <;> simp_all

/-- Theorem 17: `days_in_month` returns `28..31` for valid months `1..12` and `0` outside `1..12`. -/
theorem days_in_month_bounds (y m : I32) (hlo : 0 ≤ y.val) (_hhi : y.val ≤ 9999) :
    (1 ≤ m.val ∧ m.val ≤ 12 → ∃ d, days_in_month y m = ok d ∧ 28 ≤ d.val ∧ d.val ≤ 31) ∧
    (m.val < 1 ∨ m.val > 12 → days_in_month y m = ok 0#i32) := by
  constructor
  · intro ⟨hm1, hm12⟩
    have hcases : m = 1#i32 ∨ m = 2#i32 ∨ m = 3#i32 ∨ m = 4#i32 ∨ m = 5#i32 ∨ m = 6#i32 ∨
                  m = 7#i32 ∨ m = 8#i32 ∨ m = 9#i32 ∨ m = 10#i32 ∨ m = 11#i32 ∨ m = 12#i32 := by
      have hm_eq : m.val = 1 ∨ m.val = 2 ∨ m.val = 3 ∨ m.val = 4 ∨ m.val = 5 ∨ m.val = 6 ∨
                   m.val = 7 ∨ m.val = 8 ∨ m.val = 9 ∨ m.val = 10 ∨ m.val = 11 ∨ m.val = 12 := by omega
      rcases hm_eq with h | h | h | h | h | h | h | h | h | h | h | h
      · exact Or.inl (iscalar_eq_of_val_eq h)
      · exact Or.inr (Or.inl (iscalar_eq_of_val_eq h))
      · exact Or.inr (Or.inr (Or.inl (iscalar_eq_of_val_eq h)))
      · exact Or.inr (Or.inr (Or.inr (Or.inl (iscalar_eq_of_val_eq h))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inl (iscalar_eq_of_val_eq h)))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl (iscalar_eq_of_val_eq h))))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl (iscalar_eq_of_val_eq h)))))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl (iscalar_eq_of_val_eq h))))))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl (iscalar_eq_of_val_eq h)))))))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl (iscalar_eq_of_val_eq h))))))))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl (iscalar_eq_of_val_eq h)))))))))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (iscalar_eq_of_val_eq h)))))))))))
    rcases hcases with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl
    · exact ⟨31#i32, by simp [days_in_month], by decide, by decide⟩
    · rcases is_leap_year_total y hlo with ⟨b, hb⟩
      cases b
      · exact ⟨28#i32, by simp [days_in_month, hb], by decide, by decide⟩
      · exact ⟨29#i32, by simp [days_in_month, hb], by decide, by decide⟩
    · exact ⟨31#i32, by simp [days_in_month], by decide, by decide⟩
    · exact ⟨30#i32, by simp [days_in_month], by decide, by decide⟩
    · exact ⟨31#i32, by simp [days_in_month], by decide, by decide⟩
    · exact ⟨30#i32, by simp [days_in_month], by decide, by decide⟩
    · exact ⟨31#i32, by simp [days_in_month], by decide, by decide⟩
    · exact ⟨31#i32, by simp [days_in_month], by decide, by decide⟩
    · exact ⟨30#i32, by simp [days_in_month], by decide, by decide⟩
    · exact ⟨31#i32, by simp [days_in_month], by decide, by decide⟩
    · exact ⟨30#i32, by simp [days_in_month], by decide, by decide⟩
    · exact ⟨31#i32, by simp [days_in_month], by decide, by decide⟩
  · intro hout
    unfold days_in_month
    have hne : ∀ c : I32, (1 ≤ c.val ∧ c.val ≤ 12) → (m == c) = false := by
      intro c hc
      apply beq_false_of_ne; intro heq; subst heq; omega
    have hne2 : m ≠ 2#i32 := by
      intro heq; subst heq; have : (2#i32 : I32).val = 2 := rfl; omega
    simp [hne 1#i32 (by decide), hne 3#i32 (by decide), hne 5#i32 (by decide),
          hne 7#i32 (by decide), hne 8#i32 (by decide), hne 10#i32 (by decide),
          hne 12#i32 (by decide), hne 4#i32 (by decide), hne 6#i32 (by decide),
          hne 9#i32 (by decide), hne 11#i32 (by decide), hne2]

/-- Theorem 18: February has 29 days iff `is_leap_year y = ok true`. -/
theorem days_in_month_feb_leap (y : I32) (hlo : 0 ≤ y.val) (_hhi : y.val ≤ 9999) :
    days_in_month y 2#i32 = ok 29#i32 ↔ is_leap_year y = ok true := by
  rcases is_leap_year_total y hlo with ⟨b, hb⟩
  cases b
  · have hd : days_in_month y 2#i32 = ok 28#i32 := by simp [days_in_month, hb]
    rw [hd, hb]
    constructor
    · intro h; exact absurd (result_ok_inj h) (by decide)
    · intro h; exact absurd (result_ok_inj h) (by decide)
  · simp [days_in_month, hb]

/-- Theorem 19: RFC 5280 §4.1.2.5.1 UTCTime 2-digit year expansion maps `[0, 99]` into `[1950, 2049]`. -/
theorem utc_time_expand_year_rfc5280 (yy : I32) (hlo : 0 ≤ yy.val) (hhi : yy.val ≤ 99) :
    ∃ y, utc_time_expand_year yy = ok y ∧ 1950 ≤ y.val ∧ y.val ≤ 2049 ∧
      (50 ≤ yy.val → y.val = 1900 + yy.val) ∧
      (yy.val < 50 → y.val = 2000 + yy.val) := by
  unfold utc_time_expand_year
  have c1900 : (1900#i32 : I32).val = 1900 := rfl
  have c2000 : (2000#i32 : I32).val = 2000 := rfl
  by_cases h50 : 50 ≤ yy.val
  · have hge : (50#i32 : I32) ≤ yy := h50
    simp only [hge, ↓reduceIte]
    have hv := i32_add_val_of_bounds 1900#i32 yy (by omega) (by omega)
    refine ⟨Pion.I32.add 1900#i32 yy, rfl, by omega, by omega, by omega, by omega⟩
  · have hlt : ¬((50#i32 : I32) ≤ yy) := h50
    simp only [hlt, ↓reduceIte]
    have hv := i32_add_val_of_bounds 2000#i32 yy (by omega) (by omega)
    refine ⟨Pion.I32.add 2000#i32 yy, rfl, by omega, by omega, by omega, by omega⟩

/-- Theorem 20: `is_valid_hms` characterizes `[0, 23] × [0, 59] × [0, 59]`. -/
theorem is_valid_hms_iff (h m s : I32) :
    is_valid_hms h m s = ok true ↔
      (0 ≤ h.val ∧ h.val ≤ 23) ∧ (0 ≤ m.val ∧ m.val ≤ 59) ∧ (0 ≤ s.val ∧ s.val ≤ 59) := by
  unfold is_valid_hms
  constructor
  · intro hok
    have ht := result_ok_inj hok
    simp only [Bool.and_eq_true, decide_eq_true_eq] at ht
    rcases ht with ⟨⟨⟨⟨⟨h1, h2⟩, m1⟩, m2⟩, s1⟩, s2⟩
    exact ⟨⟨h1, h2⟩, ⟨m1, m2⟩, ⟨s1, s2⟩⟩
  · intro ⟨⟨h1, h2⟩, ⟨m1, m2⟩, ⟨s1, s2⟩⟩
    have hh1 : (0#i32 : I32) ≤ h := h1
    have hh2 : h ≤ (23#i32 : I32) := h2
    have hm1 : (0#i32 : I32) ≤ m := m1
    have hm2 : m ≤ (59#i32 : I32) := m2
    have hs1 : (0#i32 : I32) ≤ s := s1
    have hs2 : s ≤ (59#i32 : I32) := s2
    simp [hh1, hh2, hm1, hm2, hs1, hs2]

/-- Theorem 21: RFC 7468 §3 PEM `labelchar` exact range `%x21-2C / %x2E-7E` (forbids SP, CTL, `-`, DEL, non-ASCII). -/
theorem pem_label_char_rfc7468_iff (c : I32) :
    is_pem_label_char c = ok true ↔ 33 ≤ c.val ∧ c.val ≤ 126 ∧ c.val ≠ 45 := by
  unfold is_pem_label_char
  constructor
  · intro h
    have ht := result_ok_inj h
    simp only [Bool.and_eq_true, decide_eq_true_eq, bne_iff_ne, ne_eq] at ht
    rcases ht with ⟨⟨hlo, hhi⟩, hne⟩
    refine ⟨hlo, hhi, ?_⟩
    intro heq
    apply hne
    exact iscalar_eq_of_val_eq heq
  · intro ⟨hlo, hhi, hne⟩
    have h1 : (33#i32 : I32) ≤ c := hlo
    have h2 : c ≤ (126#i32 : I32) := hhi
    have h3 : (c != 45#i32) = true := by
      simp only [bne_iff_ne, ne_eq]
      intro heq; subst heq; have : (45#i32 : I32).val = 45 := rfl; omega
    simp [h1, h2, h3]

end Asn1Proofs
