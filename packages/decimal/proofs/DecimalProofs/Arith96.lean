import DecimalProofs.Core

open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 400000
set_option linter.unusedSimpArgs false

namespace DecimalProofs

open decimal

/-! ## 1. 96-bit & 128-bit Multi-Precision Arithmetic Kernels -/

/-- Exact specification of `u64_mul_wide`: 64×64 → 128-bit unsigned multiplication
    never traps and satisfies `lo + 2^64 * hi = a * b`. -/
theorem u64_mul_wide_spec (a b : Std.U64) :
    ∃ lo hi : Std.U64, u64_mul_wide a b = ok (lo, hi) ∧
      lo.val + 2 ^ 64 * hi.val = a.val * b.val := by
  unfold u64_mul_wide
  obtain ⟨a_hi, ha_hi, ha_hi_v⟩ := u64_shr32_ok a
  obtain ⟨b_hi, hb_hi, hb_hi_v⟩ := u64_shr32_ok b
  rw [ha_hi, b_ok, hb_hi, b_ok]
  dsimp only
  set a_lo := Pion.U64.band a 4294967295#u64
  set b_lo := Pion.U64.band b 4294967295#u64
  have ha_lo_v : a_lo.val = a.val % 2 ^ 32 := u64_band_mask32 a
  have hb_lo_v : b_lo.val = b.val % 2 ^ 32 := u64_band_mask32 b
  have ha_lt := u64_val_lt a
  have hb_lt := u64_val_lt b
  have ha_lo_lt : a_lo.val < 2 ^ 32 := by rw [ha_lo_v]; exact Nat.mod_lt _ (by norm_num)
  have hb_lo_lt : b_lo.val < 2 ^ 32 := by rw [hb_lo_v]; exact Nat.mod_lt _ (by norm_num)
  have ha_hi_lt : a_hi.val < 2 ^ 32 := by omega
  have hb_hi_lt : b_hi.val < 2 ^ 32 := by omega
  set p0 := Pion.U64.mul a_lo b_lo
  set p1 := Pion.U64.mul a_lo b_hi
  set p2 := Pion.U64.mul a_hi b_lo
  set p3 := Pion.U64.mul a_hi b_hi
  have hp0 : p0.val = a_lo.val * b_lo.val := by
    rw [u64_mul_val, Nat.mod_eq_of_lt]; nlinarith
  have hp1 : p1.val = a_lo.val * b_hi.val := by
    rw [u64_mul_val, Nat.mod_eq_of_lt]; nlinarith
  have hp2 : p2.val = a_hi.val * b_lo.val := by
    rw [u64_mul_val, Nat.mod_eq_of_lt]; nlinarith
  have hp3 : p3.val = a_hi.val * b_hi.val := by
    rw [u64_mul_val, Nat.mod_eq_of_lt]; nlinarith
  obtain ⟨t2, ht2, ht2_v⟩ := u64_shr32_ok p0
  rw [ht2, b_ok]
  set mid := Pion.U64.add (Pion.U64.add t2 (Pion.U64.band p1 4294967295#u64)) (Pion.U64.band p2 4294967295#u64)
  have ht2_lt : t2.val < 2 ^ 32 := by have := u64_val_lt p0; omega
  have hp1_lo_lt : (Pion.U64.band p1 4294967295#u64).val < 2 ^ 32 := by
    rw [u64_band_mask32]; exact Nat.mod_lt _ (by norm_num)
  have hp2_lo_lt : (Pion.U64.band p2 4294967295#u64).val < 2 ^ 32 := by
    rw [u64_band_mask32]; exact Nat.mod_lt _ (by norm_num)
  have hmid_v : mid.val = p0.val / 2 ^ 32 + p1.val % 2 ^ 32 + p2.val % 2 ^ 32 := by
    simp only [mid, u64_add_val, u64_band_mask32, ht2_v]
    rw [Nat.mod_eq_of_lt (by omega), Nat.mod_eq_of_lt (by omega)]
  obtain ⟨t3, ht3, ht3_v⟩ := u64_shl32_ok mid
  obtain ⟨t4, ht4, ht4_v⟩ := u64_shr32_ok p1
  obtain ⟨t5, ht5, ht5_v⟩ := u64_shr32_ok p2
  obtain ⟨t6, ht6, ht6_v⟩ := u64_shr32_ok mid
  rw [ht3, b_ok, ht4, b_ok, ht5, b_ok, ht6, b_ok]
  refine ⟨_, _, rfl, ?_⟩
  have hlo_v : (Pion.U64.bor (Pion.U64.band p0 4294967295#u64) t3).val =
      p0.val % 2 ^ 32 + (mid.val % 2 ^ 32) * 2 ^ 32 := by
    have h1 : (Pion.U64.band p0 4294967295#u64).val < 2 ^ 32 := by
      rw [u64_band_mask32]; exact Nat.mod_lt _ (by norm_num)
    have h2 : t3.val % 2 ^ 32 = 0 := by rw [ht3_v]; exact Nat.mul_mod_left _ _
    rw [u64_bor_disjoint_32 h1 h2, u64_band_mask32, ht3_v]
  have hp3_le : p3.val ≤ (2 ^ 32 - 1) * (2 ^ 32 - 1) := by
    rw [hp3]; exact Nat.mul_le_mul (by omega) (by omega)
  have ht4_le : t4.val ≤ 2 ^ 32 - 2 := by
    have : p1.val ≤ (2 ^ 32 - 1) * (2 ^ 32 - 1) := by rw [hp1]; exact Nat.mul_le_mul (by omega) (by omega)
    omega
  have ht5_le : t5.val ≤ 2 ^ 32 - 2 := by
    have : p2.val ≤ (2 ^ 32 - 1) * (2 ^ 32 - 1) := by rw [hp2]; exact Nat.mul_le_mul (by omega) (by omega)
    omega
  have ht6_le : t6.val ≤ 2 := by omega
  have hhi_v : (Pion.U64.add (Pion.U64.add (Pion.U64.add p3 t4) t5) t6).val =
      p3.val + p1.val / 2 ^ 32 + p2.val / 2 ^ 32 + mid.val / 2 ^ 32 := by
    simp only [u64_add_val, ht4_v, ht5_v, ht6_v]
    have hm1 : p3.val + p1.val / 2 ^ 32 < 2 ^ 64 := by omega
    rw [Nat.mod_eq_of_lt hm1]
    have hm2 : p3.val + p1.val / 2 ^ 32 + p2.val / 2 ^ 32 < 2 ^ 64 := by omega
    rw [Nat.mod_eq_of_lt hm2]
    have hm3 : p3.val + p1.val / 2 ^ 32 + p2.val / 2 ^ 32 + mid.val / 2 ^ 32 < 2 ^ 64 := by omega
    rw [Nat.mod_eq_of_lt hm3]
  rw [hlo_v, hhi_v]
  have ha_eq : a.val = a_lo.val + 2 ^ 32 * a_hi.val := by omega
  have hb_eq : b.val = b_lo.val + 2 ^ 32 * b_hi.val := by omega
  have hmid_split : mid.val = mid.val % 2 ^ 32 + 2 ^ 32 * (mid.val / 2 ^ 32) := by omega
  have hp0_split : p0.val = p0.val % 2 ^ 32 + 2 ^ 32 * (p0.val / 2 ^ 32) := by omega
  have hp1_split : p1.val = p1.val % 2 ^ 32 + 2 ^ 32 * (p1.val / 2 ^ 32) := by omega
  have hp2_split : p2.val = p2.val % 2 ^ 32 + 2 ^ 32 * (p2.val / 2 ^ 32) := by omega
  nlinarith

/-- Exact specification of `u96_cmp` on 3-word `[lo, mid, hi]` buffers:
    never traps and matches exact mathematical 96-bit natural number ordering. -/
theorem u96_cmp_spec (a0 a1 a2 b0 b1 b2 : Std.U32) :
    ∃ r : Std.I32, u96_cmp ⟨[a0, a1, a2]⟩ ⟨[b0, b1, b2]⟩ = ok r ∧
      (r = (-1)#i32 ↔ val96_parts a0 a1 a2 < val96_parts b0 b1 b2) ∧
      (r = 0#i32 ↔ val96_parts a0 a1 a2 = val96_parts b0 b1 b2) ∧
      (r = 1#i32 ↔ val96_parts a0 a1 a2 > val96_parts b0 b1 b2) := by
  have ha0 := u32_val_lt a0; have ha1 := u32_val_lt a1; have ha2 := u32_val_lt a2
  have hb0 := u32_val_lt b0; have hb1 := u32_val_lt b1; have hb2 := u32_val_lt b2
  have hstep_m1 : u96_cmp_loop0 ⟨[a0, a1, a2]⟩ ⟨[b0, b1, b2]⟩ (-1)#i32 = ok (.inr (-1)#i32) := by
    unfold u96_cmp_loop0
    rw [loop.eq_1]
    unfold u96_cmp_loop0.body
    simp [show ¬((-1)#i32 ≥ (0#i32 : Std.I32)) from by decide]
  have hstep_0 : u96_cmp_loop0 ⟨[a0, a1, a2]⟩ ⟨[b0, b1, b2]⟩ 0#i32 =
      ok (if a0 < b0 then .inl (-1)#i32 else if a0 > b0 then .inl 1#i32 else .inr (-1)#i32) := by
    conv_lhs => unfold u96_cmp_loop0; rw [loop.eq_1]; unfold u96_cmp_loop0.body
    have hge : (0#i32 : Std.I32) ≥ 0#i32 := by decide
    have hgeta : Pion.FixedArray.get ⟨[a0, a1, a2]⟩ 0#i32 = ok a0 := by
      unfold Pion.FixedArray.get Pion.listGet; simp
    have hgetb : Pion.FixedArray.get ⟨[b0, b1, b2]⟩ 0#i32 = ok b0 := by
      unfold Pion.FixedArray.get Pion.listGet; simp
    simp only [hge, ↓reduceIte, hgeta, hgetb, b_ok]
    by_cases hlt : a0 < b0
    · simp [hlt]
    · by_cases hgt : a0 > b0
      · simp [hlt, hgt]
      · simp only [hlt, hgt, ↓reduceIte, b_ok, show Pion.I32.sub 0#i32 1#i32 = (-1)#i32 from by decide]
        exact hstep_m1
  have hstep_1 : u96_cmp_loop0 ⟨[a0, a1, a2]⟩ ⟨[b0, b1, b2]⟩ 1#i32 =
      ok (if a1 < b1 then .inl (-1)#i32 else if a1 > b1 then .inl 1#i32 else
          if a0 < b0 then .inl (-1)#i32 else if a0 > b0 then .inl 1#i32 else .inr (-1)#i32) := by
    conv_lhs => unfold u96_cmp_loop0; rw [loop.eq_1]; unfold u96_cmp_loop0.body
    have hge : (1#i32 : Std.I32) ≥ 0#i32 := by decide
    have hgeta : Pion.FixedArray.get ⟨[a0, a1, a2]⟩ 1#i32 = ok a1 := by
      unfold Pion.FixedArray.get Pion.listGet; simp
    have hgetb : Pion.FixedArray.get ⟨[b0, b1, b2]⟩ 1#i32 = ok b1 := by
      unfold Pion.FixedArray.get Pion.listGet; simp
    simp only [hge, ↓reduceIte, hgeta, hgetb, b_ok]
    by_cases hlt : a1 < b1
    · simp [hlt]
    · by_cases hgt : a1 > b1
      · simp [hlt, hgt]
      · simp only [hlt, hgt, ↓reduceIte, b_ok, show Pion.I32.sub 1#i32 1#i32 = 0#i32 from by decide]
        exact hstep_0
  have hstep_2 : u96_cmp_loop0 ⟨[a0, a1, a2]⟩ ⟨[b0, b1, b2]⟩ 2#i32 =
      ok (if a2 < b2 then .inl (-1)#i32 else if a2 > b2 then .inl 1#i32 else
          if a1 < b1 then .inl (-1)#i32 else if a1 > b1 then .inl 1#i32 else
          if a0 < b0 then .inl (-1)#i32 else if a0 > b0 then .inl 1#i32 else .inr (-1)#i32) := by
    conv_lhs => unfold u96_cmp_loop0; rw [loop.eq_1]; unfold u96_cmp_loop0.body
    have hge : (2#i32 : Std.I32) ≥ 0#i32 := by decide
    have hgeta : Pion.FixedArray.get ⟨[a0, a1, a2]⟩ 2#i32 = ok a2 := by
      unfold Pion.FixedArray.get Pion.listGet; simp
    have hgetb : Pion.FixedArray.get ⟨[b0, b1, b2]⟩ 2#i32 = ok b2 := by
      unfold Pion.FixedArray.get Pion.listGet; simp
    simp only [hge, ↓reduceIte, hgeta, hgetb, b_ok]
    by_cases hlt : a2 < b2
    · simp [hlt]
    · by_cases hgt : a2 > b2
      · simp [hlt, hgt]
      · simp only [hlt, hgt, ↓reduceIte, b_ok, show Pion.I32.sub 2#i32 1#i32 = 1#i32 from by decide]
        exact hstep_1
  unfold u96_cmp
  dsimp only
  rw [hstep_2, b_ok]
  unfold val96_parts
  split_ifs with h1 h2 h3 h4 h5 h6
  · refine ⟨(-1)#i32, rfl, ?_, ?_, ?_⟩
    · constructor <;> intro _; · have : a2.val < b2.val := h1; omega
      · rfl
    · constructor <;> intro h; · exact absurd h (by decide)
      · have : a2.val < b2.val := h1; omega
    · constructor <;> intro h; · exact absurd h (by decide)
      · have : a2.val < b2.val := h1; omega
  · refine ⟨1#i32, rfl, ?_, ?_, ?_⟩
    · constructor <;> intro h; · exact absurd h (by decide)
      · have : b2.val < a2.val := h2; omega
    · constructor <;> intro h; · exact absurd h (by decide)
      · have : b2.val < a2.val := h2; omega
    · constructor <;> intro _; · have : b2.val < a2.val := h2; omega
      · rfl
  · have he2 : a2.val = b2.val := by
      have : ¬(a2.val < b2.val) := h1; have : ¬(b2.val < a2.val) := h2; omega
    refine ⟨(-1)#i32, rfl, ?_, ?_, ?_⟩
    · constructor <;> intro _; · have : a1.val < b1.val := h3; omega
      · rfl
    · constructor <;> intro h; · exact absurd h (by decide)
      · have : a1.val < b1.val := h3; omega
    · constructor <;> intro h; · exact absurd h (by decide)
      · have : a1.val < b1.val := h3; omega
  · have he2 : a2.val = b2.val := by
      have : ¬(a2.val < b2.val) := h1; have : ¬(b2.val < a2.val) := h2; omega
    refine ⟨1#i32, rfl, ?_, ?_, ?_⟩
    · constructor <;> intro h; · exact absurd h (by decide)
      · have : b1.val < a1.val := h4; omega
    · constructor <;> intro h; · exact absurd h (by decide)
      · have : b1.val < a1.val := h4; omega
    · constructor <;> intro _; · have : b1.val < a1.val := h4; omega
      · rfl
  · have he2 : a2.val = b2.val := by
      have : ¬(a2.val < b2.val) := h1; have : ¬(b2.val < a2.val) := h2; omega
    have he1 : a1.val = b1.val := by
      have : ¬(a1.val < b1.val) := h3; have : ¬(b1.val < a1.val) := h4; omega
    refine ⟨(-1)#i32, rfl, ?_, ?_, ?_⟩
    · constructor <;> intro _; · have : a0.val < b0.val := h5; omega
      · rfl
    · constructor <;> intro h; · exact absurd h (by decide)
      · have : a0.val < b0.val := h5; omega
    · constructor <;> intro h; · exact absurd h (by decide)
      · have : a0.val < b0.val := h5; omega
  · have he2 : a2.val = b2.val := by
      have : ¬(a2.val < b2.val) := h1; have : ¬(b2.val < a2.val) := h2; omega
    have he1 : a1.val = b1.val := by
      have : ¬(a1.val < b1.val) := h3; have : ¬(b1.val < a1.val) := h4; omega
    refine ⟨1#i32, rfl, ?_, ?_, ?_⟩
    · constructor <;> intro h; · exact absurd h (by decide)
      · have : b0.val < a0.val := h6; omega
    · constructor <;> intro h; · exact absurd h (by decide)
      · have : b0.val < a0.val := h6; omega
    · constructor <;> intro _; · have : b0.val < a0.val := h6; omega
      · rfl
  · have he2 : a2.val = b2.val := by
      have : ¬(a2.val < b2.val) := h1; have : ¬(b2.val < a2.val) := h2; omega
    have he1 : a1.val = b1.val := by
      have : ¬(a1.val < b1.val) := h3; have : ¬(b1.val < a1.val) := h4; omega
    have he0 : a0.val = b0.val := by
      have : ¬(a0.val < b0.val) := h5; have : ¬(b0.val < a0.val) := h6; omega
    refine ⟨0#i32, rfl, ?_, ?_, ?_⟩
    · constructor <;> intro h; · exact absurd h (by decide)
      · omega
    · constructor <;> intro _; · omega
      · rfl
    · constructor <;> intro h; · exact absurd h (by decide)
      · omega

theorem u96_cmp_refl (a0 a1 a2 : Std.U32) :
    u96_cmp ⟨[a0, a1, a2]⟩ ⟨[a0, a1, a2]⟩ = ok 0#i32 := by
  obtain ⟨r, hr, _, heq, _⟩ := u96_cmp_spec a0 a1 a2 a0 a1 a2
  rw [hr, heq.mpr rfl]

theorem u96_cmp_antisymm (a0 a1 a2 b0 b1 b2 : Std.U32) {r : Std.I32}
    (h : u96_cmp ⟨[a0, a1, a2]⟩ ⟨[b0, b1, b2]⟩ = ok r) :
    u96_cmp ⟨[b0, b1, b2]⟩ ⟨[a0, a1, a2]⟩ = ok (Pion.I32.neg r) := by
  obtain ⟨r1, hr1, hlt1, heq1, hgt1⟩ := u96_cmp_spec a0 a1 a2 b0 b1 b2
  obtain ⟨r2, hr2, hlt2, heq2, hgt2⟩ := u96_cmp_spec b0 b1 b2 a0 a1 a2
  rw [hr1] at h
  have hr : r1 = r := ok_inj h
  subst hr
  rcases lt_trichotomy (val96_parts a0 a1 a2) (val96_parts b0 b1 b2) with hlt | heq | hgt
  · have h1 := hlt1.mpr hlt
    have h2 := hgt2.mpr hlt
    rw [hr2, h1, h2]; rfl
  · have h1 := heq1.mpr heq
    have h2 := heq2.mpr heq.symm
    rw [hr2, h1, h2]; rfl
  · have h1 := hgt1.mpr hgt
    have h2 := hlt2.mpr hgt
    rw [hr2, h1, h2]; rfl

theorem u96_cmp_trans_lt (a0 a1 a2 b0 b1 b2 c0 c1 c2 : Std.U32)
    (hab : u96_cmp ⟨[a0, a1, a2]⟩ ⟨[b0, b1, b2]⟩ = ok (-1)#i32)
    (hbc : u96_cmp ⟨[b0, b1, b2]⟩ ⟨[c0, c1, c2]⟩ = ok (-1)#i32) :
    u96_cmp ⟨[a0, a1, a2]⟩ ⟨[c0, c1, c2]⟩ = ok (-1)#i32 := by
  obtain ⟨r1, hr1, hlt1, _, _⟩ := u96_cmp_spec a0 a1 a2 b0 b1 b2
  obtain ⟨r2, hr2, hlt2, _, _⟩ := u96_cmp_spec b0 b1 b2 c0 c1 c2
  obtain ⟨r3, hr3, hlt3, _, _⟩ := u96_cmp_spec a0 a1 a2 c0 c1 c2
  rw [hr1] at hab
  have h1 : r1 = (-1)#i32 := ok_inj hab
  rw [hr2] at hbc
  have h2 : r2 = (-1)#i32 := ok_inj hbc
  rw [hr3, hlt3.mpr (Nat.lt_trans (hlt1.mp h1) (hlt2.mp h2))]

/-- Exact specification of `inc96`: 96-bit `+ 1` with exact overflow detection. -/
theorem inc96_spec (lo64 : Std.U64) (hi : Std.U32) :
    ∃ nlo nhi ov, inc96 lo64 hi = ok (nlo, nhi, ov) ∧
      (ov = false → val96 nlo nhi = val96 lo64 hi + 1) ∧
      (ov = true ↔ val96 lo64 hi + 1 = 2 ^ 96) := by
  unfold inc96 val96
  dsimp only
  have hlo := u64_val_lt lo64
  have hhi := u32_val_lt hi
  set nlo := Pion.U64.add lo64 1#u64
  have hnlo : nlo.val = (lo64.val + 1) % 2 ^ 64 := u64_add_val lo64 1#u64
  by_cases h1 : nlo ≠ 0#u64
  · rw [if_pos h1]
    have hne : nlo.val ≠ 0 := fun hz => h1 (UScalar.eq_of_val_eq hz)
    have hlt : lo64.val + 1 < 2 ^ 64 := by omega
    exact ⟨nlo, hi, false, rfl, fun _ => by omega, ⟨fun h => Bool.noConfusion h, fun h => by omega⟩⟩
  · rw [if_neg h1]
    have hlo_max : lo64.val = 2 ^ 64 - 1 := by
      have h0 : nlo = 0#u64 := Classical.not_not.mp h1
      have : nlo.val = 0 := by rw [h0]; rfl
      omega
    set nhi := Pion.U32.add hi 1#u32
    have hnhi : nhi.val = (hi.val + 1) % 2 ^ 32 := u32_add_val hi 1#u32
    by_cases h2 : nhi ≠ 0#u32
    · rw [if_pos h2]
      have hne : nhi.val ≠ 0 := fun hz => h2 (UScalar.eq_of_val_eq hz)
      have hlt : hi.val + 1 < 2 ^ 32 := by omega
      exact ⟨0#u64, nhi, false, rfl,
        fun _ => by simp only [show (0#u64 : Std.U64).val = 0 from rfl]; omega,
        ⟨fun h => Bool.noConfusion h, fun h => by omega⟩⟩
    · rw [if_neg h2]
      have hhi_max : hi.val = 2 ^ 32 - 1 := by
        have h0 : nhi = 0#u32 := Classical.not_not.mp h2
        have : nhi.val = 0 := by rw [h0]; rfl
        omega
      exact ⟨0#u64, 0#u32, true, rfl, fun h => Bool.noConfusion h, ⟨fun _ => by omega, fun _ => rfl⟩⟩

/-- Exact specification of `mul10_add96`: 96-bit `* 10 + digit` with exact overflow detection
    (never silently truncates overflow). -/
theorem mul10_add96_spec (lo64 : Std.U64) (hi : Std.U32) (digit : Std.U64)
    (hdig : digit.val ≤ 9) :
    ∃ nlo nhi ov, mul10_add96 lo64 hi digit = ok (nlo, nhi, ov) ∧
      (ov = false → val96 nlo nhi = val96 lo64 hi * 10 + digit.val) ∧
      (ov = true ↔ val96 lo64 hi * 10 + digit.val ≥ 2 ^ 96) := by
  unfold mul10_add96 val96
  dsimp only
  have hlo := u64_val_lt lo64
  have hhi := u32_val_lt hi
  set lo_part := Pion.U64.add (Pion.U64.mul (Pion.U64.band lo64 4294967295#u64) 10#u64) digit
  have hlo_part : lo_part.val = (lo64.val % 2 ^ 32) * 10 + digit.val := by
    simp only [lo_part, u64_add_val, u64_mul_val, u64_band_mask32]
    have h1 : (lo64.val % 2 ^ 32) < 2 ^ 32 := Nat.mod_lt _ (by norm_num)
    have h10 : (10#u64 : Std.U64).val = 10 := by decide
    rw [h10]
    have hm1 : (lo64.val % 2 ^ 32) * 10 < 2 ^ 64 := by omega
    rw [Nat.mod_eq_of_lt hm1, Nat.mod_eq_of_lt (by omega)]
  obtain ⟨t, ht, htv⟩ := u64_shr32_ok lo64
  obtain ⟨t1, ht1, ht1v⟩ := u64_shr32_ok lo_part
  rw [ht, b_ok, ht1, b_ok]
  set mid_part := Pion.U64.add (Pion.U64.mul t 10#u64) t1
  have hmid_part : mid_part.val = (lo64.val / 2 ^ 32) * 10 + lo_part.val / 2 ^ 32 := by
    simp only [mid_part, u64_add_val, u64_mul_val, htv, ht1v]
    have h10 : (10#u64 : Std.U64).val = 10 := by decide
    rw [h10]
    have hm1 : (lo64.val / 2 ^ 32) * 10 < 2 ^ 64 := by omega
    rw [Nat.mod_eq_of_lt hm1, Nat.mod_eq_of_lt (by omega)]
  obtain ⟨t2, ht2, ht2v⟩ := u64_shr32_ok mid_part
  rw [ht2, b_ok]
  set hi_part := Pion.U64.add (Pion.U64.mul (Pion.U32.to_uint64 hi) 10#u64) t2
  have hhi_part : hi_part.val = hi.val * 10 + mid_part.val / 2 ^ 32 := by
    simp only [hi_part, u64_add_val, u64_mul_val, u32_to_uint64_val, ht2v]
    have h10 : (10#u64 : Std.U64).val = 10 := by decide
    rw [h10]
    have hm1 : hi.val * 10 < 2 ^ 64 := by omega
    rw [Nat.mod_eq_of_lt hm1, Nat.mod_eq_of_lt (by omega)]
  have hexact : (lo_part.val % 2 ^ 32) + (mid_part.val % 2 ^ 32) * 2 ^ 32 + 2 ^ 64 * hi_part.val =
      (lo64.val + 2 ^ 64 * hi.val) * 10 + digit.val := by
    omega
  by_cases hov : hi_part > 4294967295#u64
  · simp only [hov, ↓reduceIte]
    have hgt : hi_part.val ≥ 2 ^ 32 := by
      have : (4294967295#u64 : Std.U64).val < hi_part.val := hov
      have hv : (4294967295#u64 : Std.U64).val = 2 ^ 32 - 1 := by decide
      omega
    exact ⟨lo64, hi, true, rfl, fun h => Bool.noConfusion h, ⟨fun _ => by omega, fun _ => rfl⟩⟩
  · simp only [hov, ↓reduceIte]
    have hle : hi_part.val < 2 ^ 32 := by
      have : ¬((4294967295#u64 : Std.U64).val < hi_part.val) := hov
      have hv : (4294967295#u64 : Std.U64).val = 2 ^ 32 - 1 := by decide
      omega
    obtain ⟨t3, ht3, ht3v⟩ := u64_shl32_ok mid_part
    rw [ht3, b_ok]
    refine ⟨_, _, false, rfl, ?_, ?_⟩
    · intro _
      have h1 : (Pion.U64.band lo_part 4294967295#u64).val < 2 ^ 32 := by
        rw [u64_band_mask32]; exact Nat.mod_lt _ (by norm_num)
      have h2 : t3.val % 2 ^ 32 = 0 := by rw [ht3v]; exact Nat.mul_mod_left _ _
      rw [u64_bor_disjoint_32 h1 h2, u64_band_mask32, ht3v, u64_to_uint_val, Nat.mod_eq_of_lt hle]
      omega
    · constructor
      · intro h; cases h
      · intro hge
        have : lo_part.val % 2 ^ 32 < 2 ^ 32 := Nat.mod_lt _ (by norm_num)
        have : mid_part.val % 2 ^ 32 < 2 ^ 32 := Nat.mod_lt _ (by norm_num)
        omega

/-- Exact specification of `overflow96_div10`: equals `(2^96 + 4) / 10`. -/
theorem overflow96_div10_spec :
    ∃ lo hi, overflow96_div10 = ok (lo, hi) ∧ val96 lo hi = (2 ^ 96 + 4) / 10 := by
  unfold overflow96_div10 val96
  refine ⟨_, _, rfl, ?_⟩
  decide

/-- Exact specification of `pow10_u32` on `0..=9`. -/
theorem pow10_u32_spec (k : Std.I32) (hk0 : 0 ≤ k.val) (hk9 : k.val ≤ 9) :
    ∃ r, pow10_u32 k = ok r ∧ r.val = 10 ^ k.val.toNat := by
  unfold pow10_u32
  refine ⟨_, rfl, ?_⟩
  have hcases : k.val = 0 ∨ k.val = 1 ∨ k.val = 2 ∨ k.val = 3 ∨ k.val = 4 ∨
      k.val = 5 ∨ k.val = 6 ∨ k.val = 7 ∨ k.val = 8 ∨ k.val = 9 := by omega
  rcases hcases with h | h | h | h | h | h | h | h | h | h
  · have : k = 0#i32 := IScalar.eq_of_val_eq h; subst this; decide
  · have : k = 1#i32 := IScalar.eq_of_val_eq h; subst this; decide
  · have : k = 2#i32 := IScalar.eq_of_val_eq h; subst this; decide
  · have : k = 3#i32 := IScalar.eq_of_val_eq h; subst this; decide
  · have : k = 4#i32 := IScalar.eq_of_val_eq h; subst this; decide
  · have : k = 5#i32 := IScalar.eq_of_val_eq h; subst this; decide
  · have : k = 6#i32 := IScalar.eq_of_val_eq h; subst this; decide
  · have : k = 7#i32 := IScalar.eq_of_val_eq h; subst this; decide
  · have : k = 8#i32 := IScalar.eq_of_val_eq h; subst this; decide
  · have : k = 9#i32 := IScalar.eq_of_val_eq h; subst this; decide

/-- Exact specification of `pow10_u64` on `0..=19`. -/
theorem pow10_u64_spec (k : Std.I32) (hk0 : 0 ≤ k.val) (hk19 : k.val ≤ 19) :
    ∃ r, pow10_u64 k = ok r ∧ r.val = 10 ^ k.val.toNat := by
  unfold pow10_u64
  by_cases h10 : k < 10#i32
  · simp only [h10, ↓reduceIte]
    have hk9 : k.val ≤ 9 := by
      have : k.val < (10#i32 : Std.I32).val := h10
      have hv : (10#i32 : Std.I32).val = 10 := by decide
      omega
    obtain ⟨r, hr, hrv⟩ := pow10_u32_spec k hk0 hk9
    rw [hr, b_ok]
    exact ⟨_, rfl, by rw [u32_to_uint64_val, hrv]⟩
  · simp only [h10, ↓reduceIte]
    have hkge : 10 ≤ k.val := by
      have : ¬(k.val < (10#i32 : Std.I32).val) := h10
      have hv : (10#i32 : Std.I32).val = 10 := by decide
      omega
    refine ⟨_, rfl, ?_⟩
    have hcases : k.val = 10 ∨ k.val = 11 ∨ k.val = 12 ∨ k.val = 13 ∨ k.val = 14 ∨
        k.val = 15 ∨ k.val = 16 ∨ k.val = 17 ∨ k.val = 18 ∨ k.val = 19 := by omega
    rcases hcases with h | h | h | h | h | h | h | h | h | h
    · have : k = 10#i32 := IScalar.eq_of_val_eq h; subst this; decide
    · have : k = 11#i32 := IScalar.eq_of_val_eq h; subst this; decide
    · have : k = 12#i32 := IScalar.eq_of_val_eq h; subst this; decide
    · have : k = 13#i32 := IScalar.eq_of_val_eq h; subst this; decide
    · have : k = 14#i32 := IScalar.eq_of_val_eq h; subst this; decide
    · have : k = 15#i32 := IScalar.eq_of_val_eq h; subst this; decide
    · have : k = 16#i32 := IScalar.eq_of_val_eq h; subst this; decide
    · have : k = 17#i32 := IScalar.eq_of_val_eq h; subst this; decide
    · have : k = 18#i32 := IScalar.eq_of_val_eq h; subst this; decide
    · have : k = 19#i32 := IScalar.eq_of_val_eq h; subst this; decide


end DecimalProofs
