import CronProofs.Core

open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 400000
set_option linter.unusedSimpArgs false

namespace CronProofs

open cron

/-! ## Part 1: 64-bit Bitmask Kernels (`ctz64`, `msb64`, `next_set_bit`, `prev_set_bit`) -/

section Bitmasks

lemma bitvec_ofNat_pow_sub_one (w : Nat) (_hw : w ≤ 64) :
    ∀ i, i < 64 → (BitVec.ofNat 64 (2 ^ w - 1)).getLsbD i = decide (i < w) := by
  intro i hi
  rw [BitVec.getLsbD_ofNat]
  simp only [hi, decide_true, Bool.true_and, Nat.testBit_two_pow_sub_one]

lemma bitvec_ofNat_band_hi (w : Nat) (hw : 2 * w ≤ 64) :
    ∀ i, i < 64 → (BitVec.ofNat 64 ((2 ^ w - 1) * 2 ^ w)).getLsbD i = (decide (w ≤ i) && decide (i < 2 * w)) := by
  intro i hi
  have hsh : BitVec.ofNat 64 ((2 ^ w - 1) * 2 ^ w) = (BitVec.ofNat 64 (2 ^ w - 1)) <<< w := by
    apply BitVec.eq_of_toNat_eq
    simp only [BitVec.toNat_ofNat, BitVec.toNat_shiftLeft]
    have h1 : 2 ^ w - 1 < 2 ^ 64 := by
      have : 2 ^ w ≤ 2 ^ 64 := Nat.pow_le_pow_right (by omega) (by omega)
      have : 0 < 2 ^ w := Nat.two_pow_pos w
      omega
    rw [Nat.mod_eq_of_lt h1, Nat.shiftLeft_eq]
  rw [hsh, BitVec.getLsbD_shiftLeft]
  simp only [hi, decide_true, Bool.true_and]
  by_cases hwi : i < w
  · simp [hwi, show ¬ w ≤ i by omega]
  · simp only [hwi, decide_false, Bool.not_false, Bool.true_and]
    rw [bitvec_ofNat_pow_sub_one w (by omega) (i - w) (by omega)]
    have h1 : w ≤ i := by omega
    simp only [h1, decide_true, Bool.true_and]
    by_cases h2 : i < 2 * w
    · simp [h2, show i - w < w by omega]
    · simp [h2, show ¬ (i - w < w) by omega]

lemma mask_lo32 : ∀ i, i < 64 → (4294967295#64).getLsbD i = decide (i < 32) :=
  bitvec_ofNat_pow_sub_one 32 (by omega)
lemma mask_lo16 : ∀ i, i < 64 → (65535#64).getLsbD i = decide (i < 16) :=
  bitvec_ofNat_pow_sub_one 16 (by omega)
lemma mask_lo8  : ∀ i, i < 64 → (255#64).getLsbD i = decide (i < 8) :=
  bitvec_ofNat_pow_sub_one 8 (by omega)
lemma mask_lo4  : ∀ i, i < 64 → (15#64).getLsbD i = decide (i < 4) :=
  bitvec_ofNat_pow_sub_one 4 (by omega)
lemma mask_lo2  : ∀ i, i < 64 → (3#64).getLsbD i = decide (i < 2) :=
  bitvec_ofNat_pow_sub_one 2 (by omega)
lemma mask_lo1  : ∀ i, i < 64 → (1#64).getLsbD i = decide (i < 1) :=
  bitvec_ofNat_pow_sub_one 1 (by omega)

lemma mask_hi32 : ∀ i, i < 64 → (18446744069414584320#64).getLsbD i = (decide (32 ≤ i) && decide (i < 64)) :=
  bitvec_ofNat_band_hi 32 (by omega)
lemma mask_hi16 : ∀ i, i < 64 → (4294901760#64).getLsbD i = (decide (16 ≤ i) && decide (i < 32)) :=
  bitvec_ofNat_band_hi 16 (by omega)
lemma mask_hi8  : ∀ i, i < 64 → (65280#64).getLsbD i = (decide (8 ≤ i) && decide (i < 16)) :=
  bitvec_ofNat_band_hi 8 (by omega)
lemma mask_hi4  : ∀ i, i < 64 → (240#64).getLsbD i = (decide (4 ≤ i) && decide (i < 8)) :=
  bitvec_ofNat_band_hi 4 (by omega)
lemma mask_hi2  : ∀ i, i < 64 → (12#64).getLsbD i = (decide (2 ≤ i) && decide (i < 4)) :=
  bitvec_ofNat_band_hi 2 (by omega)
lemma mask_hi1  : ∀ i, i < 64 → (2#64).getLsbD i = decide (i = 1) := by
  intro i hi
  have h := bitvec_ofNat_band_hi 1 (by omega) i hi
  change (BitVec.ofNat 64 ((2 ^ 1 - 1) * 2 ^ 1)).getLsbD i = decide (i = 1)
  rw [h]
  by_cases h1 : i = 1
  · subst h1; simp
  · simp [h1]; omega

/-- Helper for one binary-search step of `ctz64`. -/
lemma ctz_step {orig x : Std.U64} {n w : Nat} {mask : Std.U64}
    (_hw : 0 < w) (hnw : n + 2 * w ≤ 64)
    (hmask : ∀ i, i < 64 → mask.bv.getLsbD i = decide (i < w))
    (hshift : ∀ i, i < 2 * w → x.bv.getLsbD i = orig.bv.getLsbD (n + i))
    (hbelow : ∀ j, j < n → orig.bv.getLsbD j = false)
    (hex : ∃ i, i < 2 * w ∧ x.bv.getLsbD i = true) :
    let cond := (Pion.U64.band x mask) = 0#u64
    let x' : Std.U64 := if cond then ⟨x.bv >>> w⟩ else x
    let n' : Nat := if cond then n + w else n
    (∀ i, i < w → x'.bv.getLsbD i = orig.bv.getLsbD (n' + i)) ∧
    (∀ j, j < n' → orig.bv.getLsbD j = false) ∧
    (∃ i, i < w ∧ x'.bv.getLsbD i = true) := by
  by_cases hcond : Pion.U64.band x mask = 0#u64
  · simp only [hcond, ↓reduceIte]
    have hzero := (u64_band_eq_zero_iff x mask).mp hcond
    refine ⟨?_, ?_, ?_⟩
    · intro i hi
      change (x.bv >>> w).getLsbD i = orig.bv.getLsbD (n + w + i)
      rw [BitVec.getLsbD_ushiftRight, hshift (w + i) (by omega)]
      congr 1; omega
    · intro j hj
      by_cases hjn : j < n
      · exact hbelow j hjn
      · have hsub : j - n < w := by omega
        have h1 := hzero (j - n) (by omega) (by rw [hmask (j - n) (by omega)]; simp [hsub])
        rw [hshift (j - n) (by omega)] at h1
        have heq : n + (j - n) = j := by omega
        rwa [heq] at h1
    · obtain ⟨i, hi, hxi⟩ := hex
      have hge : w ≤ i := by
        by_contra hlt
        have h1 := hzero i (by omega) (by rw [hmask i (by omega)]; simp [show i < w by omega])
        simp [h1] at hxi
      refine ⟨i - w, by omega, ?_⟩
      change (x.bv >>> w).getLsbD (i - w) = true
      rw [BitVec.getLsbD_ushiftRight]
      have heq : w + (i - w) = i := by omega
      rwa [heq]
  · simp only [hcond, ↓reduceIte]
    obtain ⟨i, hi64, hmi, hxi⟩ := (u64_band_ne_zero_iff x mask).mp hcond
    rw [hmask i hi64] at hmi
    have hiw : i < w := of_decide_eq_true hmi
    refine ⟨fun k hk => hshift k (by omega), hbelow, ⟨i, hiw, hxi⟩⟩

/-- Exact specification of `ctz64` over all `2^64 - 1` non-zero `UInt64` inputs. -/
theorem ctz64_spec (x : Std.U64) (hx : x ≠ 0#u64) :
    ∃ k : Std.I32, ctz64 x = ok k ∧
      0 ≤ k.val ∧ k.val < 64 ∧
      x.bv.getLsbD k.val.toNat = true ∧
      ∀ j : Nat, j < k.val.toNat → x.bv.getLsbD j = false := by
  have hex0 : ∃ i, i < 64 ∧ x.bv.getLsbD i = true := (u64_ne_zero_iff x).mp hx
  have hs0 : ∀ i, i < 64 → x.bv.getLsbD i = x.bv.getLsbD (0 + i) := fun _ _ => by simp
  have hb0 : ∀ j, j < 0 → x.bv.getLsbD j = false := fun _ h => by omega
  -- Step 1: w = 32
  have s1 := ctz_step (orig := x) (x := x) (n := 0) (w := 32) (mask := 4294967295#u64)
    (by omega) (by omega) mask_lo32 hs0 hb0 hex0
  set c1 := (Pion.U64.band x 4294967295#u64 = 0#u64)
  set x1 : Std.U64 := if c1 then ⟨x.bv >>> 32⟩ else x
  set n1 : Nat := if c1 then 0 + 32 else 0
  have hn1 : n1 + 32 ≤ 64 := by dsimp [n1]; split <;> omega
  -- Step 2: w = 16
  have s2 := ctz_step (orig := x) (x := x1) (n := n1) (w := 16) (mask := 65535#u64)
    (by omega) (by omega) mask_lo16 s1.1 s1.2.1 s1.2.2
  set c2 := (Pion.U64.band x1 65535#u64 = 0#u64)
  set x2 : Std.U64 := if c2 then ⟨x1.bv >>> 16⟩ else x1
  set n2 : Nat := if c2 then n1 + 16 else n1
  have hn2 : n2 + 16 ≤ 64 := by dsimp [n2]; split <;> omega
  -- Step 3: w = 8
  have s3 := ctz_step (orig := x) (x := x2) (n := n2) (w := 8) (mask := 255#u64)
    (by omega) (by omega) mask_lo8 s2.1 s2.2.1 s2.2.2
  set c3 := (Pion.U64.band x2 255#u64 = 0#u64)
  set x3 : Std.U64 := if c3 then ⟨x2.bv >>> 8⟩ else x2
  set n3 : Nat := if c3 then n2 + 8 else n2
  have hn3 : n3 + 8 ≤ 64 := by dsimp [n3]; split <;> omega
  -- Step 4: w = 4
  have s4 := ctz_step (orig := x) (x := x3) (n := n3) (w := 4) (mask := 15#u64)
    (by omega) (by omega) mask_lo4 s3.1 s3.2.1 s3.2.2
  set c4 := (Pion.U64.band x3 15#u64 = 0#u64)
  set x4 : Std.U64 := if c4 then ⟨x3.bv >>> 4⟩ else x3
  set n4 : Nat := if c4 then n3 + 4 else n3
  have hn4 : n4 + 4 ≤ 64 := by dsimp [n4]; split <;> omega
  -- Step 5: w = 2
  have s5 := ctz_step (orig := x) (x := x4) (n := n4) (w := 2) (mask := 3#u64)
    (by omega) (by omega) mask_lo2 s4.1 s4.2.1 s4.2.2
  set c5 := (Pion.U64.band x4 3#u64 = 0#u64)
  set x5 : Std.U64 := if c5 then ⟨x4.bv >>> 2⟩ else x4
  set n5 : Nat := if c5 then n4 + 2 else n4
  have hn5 : n5 + 2 ≤ 64 := by dsimp [n5]; split <;> omega
  -- Step 6: w = 1
  have s6 := ctz_step (orig := x) (x := x5) (n := n5) (w := 1) (mask := 1#u64)
    (by omega) (by omega) mask_lo1 s5.1 s5.2.1 s5.2.2
  set c6 := (Pion.U64.band x5 1#u64 = 0#u64)
  set n6 : Nat := if c6 then n5 + 1 else n5
  have hn6 : n6 < 64 := by dsimp [n6]; split <;> omega
  -- Relate `ctz64 x` to `n6`
  have hr1 : (if c1 then Pion.I32.add 0#i32 32#i32 else 0#i32).val = (n1 : Int) := by
    dsimp only [n1]
    by_cases hc : c1
    · rw [ite_eq_left hc, ite_eq_left hc]; rfl
    · rw [ite_eq_right hc, ite_eq_right hc]; rfl
  set r1 : Std.I32 := if c1 then Pion.I32.add 0#i32 32#i32 else 0#i32
  have hr2 : (if c2 then Pion.I32.add r1 16#i32 else r1).val = (n2 : Int) := by
    dsimp only [n2]; by_cases hc : c2
    · rw [ite_eq_left hc, ite_eq_left hc, i32_add_val, hr1]
      all_goals (have hc : (16#i32).val = 16 := (by simp); rw [hc]; try omega)
    · rw [ite_eq_right hc, ite_eq_right hc]; exact hr1
  set r2 : Std.I32 := if c2 then Pion.I32.add r1 16#i32 else r1
  have hr3 : (if c3 then Pion.I32.add r2 8#i32 else r2).val = (n3 : Int) := by
    dsimp only [n3]; by_cases hc : c3
    · rw [ite_eq_left hc, ite_eq_left hc, i32_add_val, hr2]
      all_goals (have hc : (8#i32).val = 8 := (by simp); rw [hc]; try omega)
    · rw [ite_eq_right hc, ite_eq_right hc]; exact hr2
  set r3 : Std.I32 := if c3 then Pion.I32.add r2 8#i32 else r2
  have hr4 : (if c4 then Pion.I32.add r3 4#i32 else r3).val = (n4 : Int) := by
    dsimp only [n4]; by_cases hc : c4
    · rw [ite_eq_left hc, ite_eq_left hc, i32_add_val, hr3]
      all_goals (have hc : (4#i32).val = 4 := (by simp); rw [hc]; try omega)
    · rw [ite_eq_right hc, ite_eq_right hc]; exact hr3
  set r4 : Std.I32 := if c4 then Pion.I32.add r3 4#i32 else r3
  have hr5 : (if c5 then Pion.I32.add r4 2#i32 else r4).val = (n5 : Int) := by
    dsimp only [n5]; by_cases hc : c5
    · rw [ite_eq_left hc, ite_eq_left hc, i32_add_val, hr4]
      all_goals (have hc : (2#i32).val = 2 := (by simp); rw [hc]; try omega)
    · rw [ite_eq_right hc, ite_eq_right hc]; exact hr4
  set r5 : Std.I32 := if c5 then Pion.I32.add r4 2#i32 else r4
  have hr6 : (if c6 then Pion.I32.add r5 1#i32 else r5).val = (n6 : Int) := by
    dsimp only [n6]; by_cases hc : c6
    · rw [ite_eq_left hc, ite_eq_left hc, i32_add_val, hr5]
      all_goals (have hc : (1#i32).val = 1 := (by simp); rw [hc]; try omega)
    · rw [ite_eq_right hc, ite_eq_right hc]; exact hr5
  set r6 : Std.I32 := if c6 then Pion.I32.add r5 1#i32 else r5
  have heval : ctz64 x = ok r6 := by
    unfold ctz64
    have hstep1 : (if Pion.U64.band x 4294967295#u64 = 0#u64 then
        do let x2 ← Pion.U64.shr x 32#u64; ok (x2, Pion.I32.add 0#i32 32#i32)
        else ok (x, 0#i32)) = ok (x1, r1) := by
      dsimp only [x1, r1, c1]
      by_cases hc : Pion.U64.band x 4294967295#u64 = 0#u64
      · rw [ite_eq_left hc, ite_eq_left hc, ite_eq_left hc, u64_shr_lit x 32#u64 (by decide), b_ok]; rfl
      · rw [ite_eq_right hc, ite_eq_right hc, ite_eq_right hc]
    have hstep2 : (if Pion.U64.band x1 65535#u64 = 0#u64 then
        do let x4 ← Pion.U64.shr x1 16#u64; ok (x4, Pion.I32.add r1 16#i32)
        else ok (x1, r1)) = ok (x2, r2) := by
      dsimp only [x2, r2, c2]
      by_cases hc : Pion.U64.band x1 65535#u64 = 0#u64
      · rw [ite_eq_left hc, ite_eq_left hc, ite_eq_left hc, u64_shr_lit x1 16#u64 (by decide), b_ok]; rfl
      · rw [ite_eq_right hc, ite_eq_right hc, ite_eq_right hc]
    have hstep3 : (if Pion.U64.band x2 255#u64 = 0#u64 then
        do let x6 ← Pion.U64.shr x2 8#u64; ok (x6, Pion.I32.add r2 8#i32)
        else ok (x2, r2)) = ok (x3, r3) := by
      dsimp only [x3, r3, c3]
      by_cases hc : Pion.U64.band x2 255#u64 = 0#u64
      · rw [ite_eq_left hc, ite_eq_left hc, ite_eq_left hc, u64_shr_lit x2 8#u64 (by decide), b_ok]; rfl
      · rw [ite_eq_right hc, ite_eq_right hc, ite_eq_right hc]
    have hstep4 : (if Pion.U64.band x3 15#u64 = 0#u64 then
        do let x8 ← Pion.U64.shr x3 4#u64; ok (x8, Pion.I32.add r3 4#i32)
        else ok (x3, r3)) = ok (x4, r4) := by
      dsimp only [x4, r4, c4]
      by_cases hc : Pion.U64.band x3 15#u64 = 0#u64
      · rw [ite_eq_left hc, ite_eq_left hc, ite_eq_left hc, u64_shr_lit x3 4#u64 (by decide), b_ok]; rfl
      · rw [ite_eq_right hc, ite_eq_right hc, ite_eq_right hc]
    have hstep5 : (if Pion.U64.band x4 3#u64 = 0#u64 then
        do let x10 ← Pion.U64.shr x4 2#u64; ok (x10, Pion.I32.add r4 2#i32)
        else ok (x4, r4)) = ok (x5, r5) := by
      dsimp only [x5, r5, c5]
      by_cases hc : Pion.U64.band x4 3#u64 = 0#u64
      · rw [ite_eq_left hc, ite_eq_left hc, ite_eq_left hc, u64_shr_lit x4 2#u64 (by decide), b_ok]; rfl
      · rw [ite_eq_right hc, ite_eq_right hc, ite_eq_right hc]
    have hstep6 : (if Pion.U64.band x5 1#u64 = 0#u64 then
        ok (Pion.I32.add r5 1#i32) else ok r5) = ok r6 := by
      dsimp only [r6, c6]
      by_cases hc : Pion.U64.band x5 1#u64 = 0#u64
      · rw [ite_eq_left hc, ite_eq_left hc]
      · rw [ite_eq_right hc, ite_eq_right hc]
    dsimp only
    rw [hstep1, b_ok_pair, hstep2, b_ok_pair, hstep3, b_ok_pair, hstep4, b_ok_pair, hstep5, b_ok_pair, hstep6]
  refine ⟨r6, heval, by omega, by omega, ?_, ?_⟩
  · obtain ⟨i, hi1, hbit⟩ := s6.2.2
    have hi0 : i = 0 := by omega
    subst hi0
    have hget := s6.1 0 (by omega)
    rw [hbit, Nat.add_zero] at hget
    have hnat : r6.val.toNat = n6 := by omega
    rw [hnat]
    exact hget.symm
  · intro j hj
    have hnat : r6.val.toNat = n6 := by omega
    rw [hnat] at hj
    exact s6.2.1 j hj

/-- Helper for one binary-search step of `msb64`. -/
lemma msb_step {orig x : Std.U64} {r w : Nat} {mask : Std.U64}
    (_hw : 0 < w) (hrw : r + 2 * w ≤ 64)
    (hmask : ∀ i, i < 64 → mask.bv.getLsbD i = (decide (w ≤ i) && decide (i < 2 * w)))
    (hshift : ∀ i, i < 2 * w → x.bv.getLsbD i = orig.bv.getLsbD (r + i))
    (habove : ∀ j, r + 2 * w ≤ j → j < 64 → orig.bv.getLsbD j = false)
    (hex : ∃ i, i < 2 * w ∧ x.bv.getLsbD i = true) :
    let cond := (Pion.U64.band x mask) ≠ 0#u64
    let x' : Std.U64 := if cond then ⟨x.bv >>> w⟩ else x
    let r' : Nat := if cond then r + w else r
    (∀ i, i < w → x'.bv.getLsbD i = orig.bv.getLsbD (r' + i)) ∧
    (∀ j, r' + w ≤ j → j < 64 → orig.bv.getLsbD j = false) ∧
    (∃ i, i < w ∧ x'.bv.getLsbD i = true) := by
  dsimp only
  by_cases hcond : Pion.U64.band x mask ≠ 0#u64
  · rw [ite_eq_left hcond, ite_eq_left hcond]
    obtain ⟨i, hi64, hmi, hxi⟩ := (u64_band_ne_zero_iff x mask).mp hcond
    rw [hmask i hi64] at hmi
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hmi
    refine ⟨?_, ?_, ?_⟩
    · intro k hk
      change (x.bv >>> w).getLsbD k = orig.bv.getLsbD (r + w + k)
      rw [BitVec.getLsbD_ushiftRight, hshift (w + k) (by omega)]
      congr 1; omega
    · intro j hj1 hj2
      exact habove j (by omega) hj2
    · refine ⟨i - w, by omega, ?_⟩
      change (x.bv >>> w).getLsbD (i - w) = true
      rw [BitVec.getLsbD_ushiftRight]
      have heq : w + (i - w) = i := by omega
      rwa [heq]
  · rw [ite_eq_right hcond, ite_eq_right hcond]
    have hzero := (u64_band_eq_zero_iff x mask).mp (not_not.mp hcond)
    refine ⟨fun k hk => hshift k (by omega), ?_, ?_⟩
    · intro j hj1 hj2
      by_cases hjhi : r + 2 * w ≤ j
      · exact habove j hjhi hj2
      · have hsub1 : w ≤ j - r := by omega
        have hsub2 : j - r < 2 * w := by omega
        have h1 := hzero (j - r) (by omega) (by rw [hmask (j - r) (by omega)]; simp [hsub1, hsub2])
        rw [hshift (j - r) (by omega)] at h1
        have heq : r + (j - r) = j := by omega
        rwa [heq] at h1
    · obtain ⟨i, hi, hxi⟩ := hex
      have hlt : i < w := by
        by_contra hge
        have h1 := hzero i (by omega) (by rw [hmask i (by omega)]; simp [show w ≤ i by omega, hi])
        simp [h1] at hxi
      exact ⟨i, hlt, hxi⟩

/-- Exact specification of `msb64` over all `2^64 - 1` non-zero `UInt64` inputs. -/
theorem msb64_spec (x : Std.U64) (hx : x ≠ 0#u64) :
    ∃ k : Std.I32, msb64 x = ok k ∧
      0 ≤ k.val ∧ k.val < 64 ∧
      x.bv.getLsbD k.val.toNat = true ∧
      ∀ j : Nat, k.val.toNat < j → j < 64 → x.bv.getLsbD j = false := by
  have hex0 : ∃ i, i < 64 ∧ x.bv.getLsbD i = true := (u64_ne_zero_iff x).mp hx
  have hs0 : ∀ i, i < 64 → x.bv.getLsbD i = x.bv.getLsbD (0 + i) := fun _ _ => by simp
  have ha0 : ∀ j, 0 + 64 ≤ j → j < 64 → x.bv.getLsbD j = false := fun _ h1 h2 => by omega
  -- Step 1: w = 32
  have s1 := msb_step (orig := x) (x := x) (r := 0) (w := 32) (mask := 18446744069414584320#u64)
    (by omega) (by omega) mask_hi32 hs0 ha0 hex0
  set c1 := (Pion.U64.band x 18446744069414584320#u64 ≠ 0#u64)
  set x1 : Std.U64 := if c1 then ⟨x.bv >>> 32⟩ else x
  set n1 : Nat := if c1 then 0 + 32 else 0
  have hn1 : n1 + 32 ≤ 64 := by dsimp [n1]; split <;> omega
  -- Step 2: w = 16
  have s2 := msb_step (orig := x) (x := x1) (r := n1) (w := 16) (mask := 4294901760#u64)
    (by omega) (by omega) mask_hi16 s1.1 s1.2.1 s1.2.2
  set c2 := (Pion.U64.band x1 4294901760#u64 ≠ 0#u64)
  set x2 : Std.U64 := if c2 then ⟨x1.bv >>> 16⟩ else x1
  set n2 : Nat := if c2 then n1 + 16 else n1
  have hn2 : n2 + 16 ≤ 64 := by dsimp [n2]; split <;> omega
  -- Step 3: w = 8
  have s3 := msb_step (orig := x) (x := x2) (r := n2) (w := 8) (mask := 65280#u64)
    (by omega) (by omega) mask_hi8 s2.1 s2.2.1 s2.2.2
  set c3 := (Pion.U64.band x2 65280#u64 ≠ 0#u64)
  set x3 : Std.U64 := if c3 then ⟨x2.bv >>> 8⟩ else x2
  set n3 : Nat := if c3 then n2 + 8 else n2
  have hn3 : n3 + 8 ≤ 64 := by dsimp [n3]; split <;> omega
  -- Step 4: w = 4
  have s4 := msb_step (orig := x) (x := x3) (r := n3) (w := 4) (mask := 240#u64)
    (by omega) (by omega) mask_hi4 s3.1 s3.2.1 s3.2.2
  set c4 := (Pion.U64.band x3 240#u64 ≠ 0#u64)
  set x4 : Std.U64 := if c4 then ⟨x3.bv >>> 4⟩ else x3
  set n4 : Nat := if c4 then n3 + 4 else n3
  have hn4 : n4 + 4 ≤ 64 := by dsimp [n4]; split <;> omega
  -- Step 5: w = 2
  have s5 := msb_step (orig := x) (x := x4) (r := n4) (w := 2) (mask := 12#u64)
    (by omega) (by omega) mask_hi2 s4.1 s4.2.1 s4.2.2
  set c5 := (Pion.U64.band x4 12#u64 ≠ 0#u64)
  set x5 : Std.U64 := if c5 then ⟨x4.bv >>> 2⟩ else x4
  set n5 : Nat := if c5 then n4 + 2 else n4
  have hn5 : n5 + 2 ≤ 64 := by dsimp [n5]; split <;> omega
  -- Step 6: w = 1
  have hm1 : ∀ i, i < 64 → (2#64).getLsbD i = (decide (1 ≤ i) && decide (i < 2 * 1)) := by
    intro i hi; rw [mask_hi1 i hi]; by_cases h : i = 1 <;> (simp [h]; try omega)
  have s6 := msb_step (orig := x) (x := x5) (r := n5) (w := 1) (mask := 2#u64)
    (by omega) (by omega) hm1 s5.1 s5.2.1 s5.2.2
  set c6 := (Pion.U64.band x5 2#u64 ≠ 0#u64)
  set n6 : Nat := if c6 then n5 + 1 else n5
  have hn6 : n6 < 64 := by dsimp [n6]; split <;> omega
  -- Relate `msb64 x` to `n6`
  have hr1 : (if c1 then Pion.I32.add 0#i32 32#i32 else 0#i32).val = (n1 : Int) := by
    dsimp only [n1]
    by_cases hc : c1
    · rw [ite_eq_left hc, ite_eq_left hc]; rfl
    · rw [ite_eq_right hc, ite_eq_right hc]; rfl
  set r1 : Std.I32 := if c1 then Pion.I32.add 0#i32 32#i32 else 0#i32
  have hr2 : (if c2 then Pion.I32.add r1 16#i32 else r1).val = (n2 : Int) := by
    dsimp only [n2]; by_cases hc : c2
    · rw [ite_eq_left hc, ite_eq_left hc, i32_add_val, hr1]
      all_goals (have hc : (16#i32).val = 16 := (by simp); rw [hc]; try omega)
    · rw [ite_eq_right hc, ite_eq_right hc]; exact hr1
  set r2 : Std.I32 := if c2 then Pion.I32.add r1 16#i32 else r1
  have hr3 : (if c3 then Pion.I32.add r2 8#i32 else r2).val = (n3 : Int) := by
    dsimp only [n3]; by_cases hc : c3
    · rw [ite_eq_left hc, ite_eq_left hc, i32_add_val, hr2]
      all_goals (have hc : (8#i32).val = 8 := (by simp); rw [hc]; try omega)
    · rw [ite_eq_right hc, ite_eq_right hc]; exact hr2
  set r3 : Std.I32 := if c3 then Pion.I32.add r2 8#i32 else r2
  have hr4 : (if c4 then Pion.I32.add r3 4#i32 else r3).val = (n4 : Int) := by
    dsimp only [n4]; by_cases hc : c4
    · rw [ite_eq_left hc, ite_eq_left hc, i32_add_val, hr3]
      all_goals (have hc : (4#i32).val = 4 := (by simp); rw [hc]; try omega)
    · rw [ite_eq_right hc, ite_eq_right hc]; exact hr3
  set r4 : Std.I32 := if c4 then Pion.I32.add r3 4#i32 else r3
  have hr5 : (if c5 then Pion.I32.add r4 2#i32 else r4).val = (n5 : Int) := by
    dsimp only [n5]; by_cases hc : c5
    · rw [ite_eq_left hc, ite_eq_left hc, i32_add_val, hr4]
      all_goals (have hc : (2#i32).val = 2 := (by simp); rw [hc]; try omega)
    · rw [ite_eq_right hc, ite_eq_right hc]; exact hr4
  set r5 : Std.I32 := if c5 then Pion.I32.add r4 2#i32 else r4
  have hr6 : (if c6 then Pion.I32.add r5 1#i32 else r5).val = (n6 : Int) := by
    dsimp only [n6]; by_cases hc : c6
    · rw [ite_eq_left hc, ite_eq_left hc, i32_add_val, hr5]
      all_goals (have hc : (1#i32).val = 1 := (by simp); rw [hc]; try omega)
    · rw [ite_eq_right hc, ite_eq_right hc]; exact hr5
  set r6 : Std.I32 := if c6 then Pion.I32.add r5 1#i32 else r5
  have heval : msb64 x = ok r6 := by
    unfold msb64
    have hstep1 : (if Pion.U64.band x 18446744069414584320#u64 ≠ 0#u64 then
        do let x2 ← Pion.U64.shr x 32#u64; ok (x2, Pion.I32.add 0#i32 32#i32)
        else ok (x, 0#i32)) = ok (x1, r1) := by
      dsimp only [x1, r1, c1]
      by_cases hc : Pion.U64.band x 18446744069414584320#u64 ≠ 0#u64
      · rw [ite_eq_left hc, ite_eq_left hc, ite_eq_left hc, u64_shr_lit x 32#u64 (by decide), b_ok]; rfl
      · rw [ite_eq_right hc, ite_eq_right hc, ite_eq_right hc]
    have hstep2 : (if Pion.U64.band x1 4294901760#u64 ≠ 0#u64 then
        do let x4 ← Pion.U64.shr x1 16#u64; ok (x4, Pion.I32.add r1 16#i32)
        else ok (x1, r1)) = ok (x2, r2) := by
      dsimp only [x2, r2, c2]
      by_cases hc : Pion.U64.band x1 4294901760#u64 ≠ 0#u64
      · rw [ite_eq_left hc, ite_eq_left hc, ite_eq_left hc, u64_shr_lit x1 16#u64 (by decide), b_ok]; rfl
      · rw [ite_eq_right hc, ite_eq_right hc, ite_eq_right hc]
    have hstep3 : (if Pion.U64.band x2 65280#u64 ≠ 0#u64 then
        do let x6 ← Pion.U64.shr x2 8#u64; ok (x6, Pion.I32.add r2 8#i32)
        else ok (x2, r2)) = ok (x3, r3) := by
      dsimp only [x3, r3, c3]
      by_cases hc : Pion.U64.band x2 65280#u64 ≠ 0#u64
      · rw [ite_eq_left hc, ite_eq_left hc, ite_eq_left hc, u64_shr_lit x2 8#u64 (by decide), b_ok]; rfl
      · rw [ite_eq_right hc, ite_eq_right hc, ite_eq_right hc]
    have hstep4 : (if Pion.U64.band x3 240#u64 ≠ 0#u64 then
        do let x8 ← Pion.U64.shr x3 4#u64; ok (x8, Pion.I32.add r3 4#i32)
        else ok (x3, r3)) = ok (x4, r4) := by
      dsimp only [x4, r4, c4]
      by_cases hc : Pion.U64.band x3 240#u64 ≠ 0#u64
      · rw [ite_eq_left hc, ite_eq_left hc, ite_eq_left hc, u64_shr_lit x3 4#u64 (by decide), b_ok]; rfl
      · rw [ite_eq_right hc, ite_eq_right hc, ite_eq_right hc]
    have hstep5 : (if Pion.U64.band x4 12#u64 ≠ 0#u64 then
        do let x10 ← Pion.U64.shr x4 2#u64; ok (x10, Pion.I32.add r4 2#i32)
        else ok (x4, r4)) = ok (x5, r5) := by
      dsimp only [x5, r5, c5]
      by_cases hc : Pion.U64.band x4 12#u64 ≠ 0#u64
      · rw [ite_eq_left hc, ite_eq_left hc, ite_eq_left hc, u64_shr_lit x4 2#u64 (by decide), b_ok]; rfl
      · rw [ite_eq_right hc, ite_eq_right hc, ite_eq_right hc]
    have hstep6 : (if Pion.U64.band x5 2#u64 ≠ 0#u64 then
        ok (Pion.I32.add r5 1#i32) else ok r5) = ok r6 := by
      dsimp only [r6, c6]
      by_cases hc : Pion.U64.band x5 2#u64 ≠ 0#u64
      · rw [ite_eq_left hc, ite_eq_left hc]
      · rw [ite_eq_right hc, ite_eq_right hc]
    dsimp only
    rw [hstep1, b_ok_pair, hstep2, b_ok_pair, hstep3, b_ok_pair, hstep4, b_ok_pair, hstep5, b_ok_pair, hstep6]
  refine ⟨r6, heval, by omega, by omega, ?_, ?_⟩
  · obtain ⟨i, hi1, hbit⟩ := s6.2.2
    have hi0 : i = 0 := by omega
    subst hi0
    have hget := s6.1 0 (by omega)
    rw [hbit, Nat.add_zero] at hget
    have hnat : r6.val.toNat = n6 := by omega
    rw [hnat]
    exact hget.symm
  · intro j hj1 hj2
    have hnat : r6.val.toNat = n6 := by omega
    rw [hnat] at hj1
    exact s6.2.1 j (show n6 + 1 ≤ j by omega) hj2

/-- Exact specification of `next_set_bit` over all `mask : Std.U64` and `from : Std.I32`. -/
theorem next_set_bit_spec (mask : Std.U64) (frm : Std.I32) :
    ∃ r : Std.I32, next_set_bit mask frm = ok r ∧
      ((r = (-1)#i32 ∧ ∀ j : Nat, frm.val ≤ (j : Int) → j < 64 → mask.bv.getLsbD j = false) ∨
       (0 ≤ r.val ∧ r.val < 64 ∧ frm.val ≤ r.val ∧
        mask.bv.getLsbD r.val.toNat = true ∧
        ∀ j : Nat, frm.val ≤ (j : Int) → j < r.val.toNat → mask.bv.getLsbD j = false)) := by
  unfold next_set_bit
  by_cases hge : frm >= 64#i32
  · simp only [hge, ↓reduceIte]
    refine ⟨(-1)#i32, rfl, Or.inl ⟨rfl, fun j hj1 hj2 => by
      have h64 : (64#i32).val = 64 := by simp
      have : (64#i32).val ≤ frm.val := hge
      omega⟩⟩
  · simp only [hge, ↓reduceIte]
    have hlt64 : frm.val < 64 := by
      have : ¬ (64 : Int) ≤ frm.val := hge
      omega
    by_cases hle0 : frm <= 0#i32
    · simp only [hle0, ↓reduceIte, b_ok]
      have hfrm0 : frm.val ≤ 0 := hle0
      by_cases hm0 : mask = 0#u64
      · simp only [hm0, ↓reduceIte]
        exact ⟨(-1)#i32, rfl, Or.inl ⟨rfl, fun j _ _ => by simp⟩⟩
      · simp only [hm0, ↓reduceIte]
        obtain ⟨k, hctz, hk0, hk64, hkbit, hklo⟩ := ctz64_spec mask hm0
        rw [hctz, b_ok]
        have hadd : (Pion.I32.add 0#i32 k).val = k.val := by
          rw [i32_add_val]
          all_goals (have hc : (0#i32).val = 0 := (by simp); rw [hc]; try omega)
        refine ⟨Pion.I32.add 0#i32 k, rfl, Or.inr ⟨by omega, by omega, by omega, ?_, ?_⟩⟩
        · have : (Pion.I32.add 0#i32 k).val.toNat = k.val.toNat := by omega
          rw [this]; exact hkbit
        · intro j _ hjlt
          have : (Pion.I32.add 0#i32 k).val.toNat = k.val.toNat := by omega
          rw [this] at hjlt
          exact hklo j hjlt
    · simp only [hle0, ↓reduceIte]
      have hpos : 0 < frm.val := by
        have : ¬ frm.val ≤ 0 := hle0
        omega
      rw [u64_shr_i32_ok mask frm (by omega) hlt64, b_ok, b_ok]
      set sh : Std.U64 := ⟨mask.bv >>> frm.val.toNat⟩
      by_cases hsh0 : sh = 0#u64
      · simp only [hsh0, ↓reduceIte]
        refine ⟨(-1)#i32, rfl, Or.inl ⟨rfl, fun j hj1 hj2 => ?_⟩⟩
        have hbv : sh.bv = 0#64 := congrArg (fun u : Std.U64 => u.bv) hsh0
        have h0 := (bv_eq_zero_iff sh.bv).mp hbv (j - frm.val.toNat) (by omega)
        change (mask.bv >>> frm.val.toNat).getLsbD (j - frm.val.toNat) = false at h0
        rw [BitVec.getLsbD_ushiftRight] at h0
        have heq : frm.val.toNat + (j - frm.val.toNat) = j := by omega
        rwa [heq] at h0
      · simp only [hsh0, ↓reduceIte]
        obtain ⟨k, hctz, hk0, hk64, hkbit, hklo⟩ := ctz64_spec sh hsh0
        rw [hctz, b_ok]
        change (mask.bv >>> frm.val.toNat).getLsbD k.val.toNat = true at hkbit
        rw [BitVec.getLsbD_ushiftRight] at hkbit
        have hsumlt : frm.val.toNat + k.val.toNat < 64 := by
          by_contra hge64
          have hfalse := BitVec.getLsbD_of_ge mask.bv (frm.val.toNat + k.val.toNat) (by omega)
          simp [hfalse] at hkbit
        have hadd : (Pion.I32.add frm k).val = frm.val + k.val :=
          i32_add_val frm k (by omega) (by omega)
        have hnat : (Pion.I32.add frm k).val.toNat = frm.val.toNat + k.val.toNat := by omega
        refine ⟨Pion.I32.add frm k, rfl, Or.inr ⟨by omega, by omega, by omega, ?_, ?_⟩⟩
        · rw [hnat]; exact hkbit
        · intro j hj1 hj2
          rw [hnat] at hj2
          have h1 := hklo (j - frm.val.toNat) (by omega)
          change (mask.bv >>> frm.val.toNat).getLsbD (j - frm.val.toNat) = false at h1
          rw [BitVec.getLsbD_ushiftRight] at h1
          have heq : frm.val.toNat + (j - frm.val.toNat) = j := by omega
          rwa [heq] at h1

lemma low_mask_getLsbD (n : Nat) (hn : n < 64) (i : Nat) (_hi : i < 64) :
    ((1#64 <<< n) - 1#64).getLsbD i = decide (i < n) := by
  have h1 : (1#64 <<< n).toNat = 2 ^ n := by
    rw [BitVec.toNat_shiftLeft, BitVec.toNat_ofNat]
    simp only [Nat.one_mod, Nat.shiftLeft_eq, one_mul]
    exact Nat.mod_eq_of_lt (Nat.pow_lt_pow_right (by omega) hn)
  have hpow : 1 ≤ 2 ^ n := Nat.one_le_pow _ _ (by omega)
  have h2 : ((1#64 <<< n) - 1#64).toNat = 2 ^ n - 1 := by
    rw [BitVec.toNat_sub, h1, BitVec.toNat_ofNat]
    have hlt : 2 ^ n < 2 ^ 64 := Nat.pow_lt_pow_right (by omega) hn
    have hmod1 : (1 : Nat) % 2 ^ 64 = 1 := by simp
    rw [hmod1]
    have : 2 ^ 64 - 1 + 2 ^ n = (2 ^ n - 1) + 2 ^ 64 := by omega
    rw [this, Nat.add_mod_right, Nat.mod_eq_of_lt (by omega)]
  rw [BitVec.getLsbD, h2]
  by_cases h : i < n
  · simp [h, Nat.testBit_two_pow_sub_one]
  · simp only [h, decide_false]
    exact Nat.testBit_lt_two_pow
      (lt_of_lt_of_le (show 2 ^ n - 1 < 2 ^ n by omega) (Nat.pow_le_pow_right (by omega) (by omega)))

/-- Exact specification of `prev_set_bit` over all `mask : Std.U64` and `from : Std.I32`. -/
theorem prev_set_bit_spec (mask : Std.U64) (frm : Std.I32) :
    ∃ r : Std.I32, prev_set_bit mask frm = ok r ∧
      ((r = (-1)#i32 ∧ ∀ j : Nat, j < 64 → (j : Int) ≤ frm.val → mask.bv.getLsbD j = false) ∨
       (0 ≤ r.val ∧ r.val < 64 ∧ r.val ≤ frm.val ∧
        mask.bv.getLsbD r.val.toNat = true ∧
        ∀ j : Nat, r.val.toNat < j → j < 64 → (j : Int) ≤ frm.val → mask.bv.getLsbD j = false)) := by
  unfold prev_set_bit
  by_cases hneg : frm < 0#i32
  · simp only [hneg, ↓reduceIte]
    have hlt0 : frm.val < 0 := hneg
    exact ⟨(-1)#i32, rfl, Or.inl ⟨rfl, fun j _ hj => by omega⟩⟩
  · simp only [hneg, ↓reduceIte]
    have hge0 : 0 ≤ frm.val := by
      have : ¬ frm.val < 0 := hneg
      omega
    by_cases hge63 : frm >= 63#i32
    · simp only [hge63, ↓reduceIte, b_ok]
      have h63 : 63 ≤ frm.val := hge63
      by_cases hm0 : mask = 0#u64
      · simp only [hm0, ↓reduceIte]
        exact ⟨(-1)#i32, rfl, Or.inl ⟨rfl, fun j _ _ => by simp⟩⟩
      · simp only [hm0, ↓reduceIte]
        obtain ⟨k, hmsb, hk0, hk64, hkbit, hkhi⟩ := msb64_spec mask hm0
        rw [hmsb, b_ok]
        exact ⟨k, rfl, Or.inr ⟨hk0, hk64, by omega, hkbit, fun j hj1 hj2 _ => hkhi j hj1 hj2⟩⟩
    · simp only [hge63, ↓reduceIte]
      have hlt63 : frm.val < 63 := by
        have : ¬ (63 : Int) ≤ frm.val := hge63
        omega
      have hf1 : (Pion.I32.add frm 1#i32).val = frm.val + 1 := by
        rw [i32_add_val] <;> simp <;> omega
      rw [u64_shl_i32_ok 1#u64 (Pion.I32.add frm 1#i32) (by omega) (by omega), b_ok, b_ok]
      set m : Std.U64 := Pion.U64.band mask (Pion.U64.sub ⟨(1#u64).bv <<< (Pion.I32.add frm 1#i32).val.toNat⟩ 1#u64)
      have hm_bit : ∀ i, i < 64 → m.bv.getLsbD i = (mask.bv.getLsbD i && decide (i ≤ frm.val.toNat)) := by
        intro i hi
        have hnat : (Pion.I32.add frm 1#i32).val.toNat = frm.val.toNat + 1 := by omega
        change (mask.bv &&& ((1#64 <<< (Pion.I32.add frm 1#i32).val.toNat) - 1#64)).getLsbD i = _
        rw [BitVec.getLsbD_and, hnat, low_mask_getLsbD (frm.val.toNat + 1) (by omega) i hi]
        rw [show decide (i < frm.val.toNat + 1) = decide (i ≤ frm.val.toNat) from decide_eq_decide.mpr (by omega)]
      by_cases hm0 : m = 0#u64
      · simp only [hm0, ↓reduceIte]
        refine ⟨(-1)#i32, rfl, Or.inl ⟨rfl, fun j hj64 hjle => ?_⟩⟩
        have hbv : m.bv = 0#64 := congrArg (fun u : Std.U64 => u.bv) hm0
        have h0 := (bv_eq_zero_iff m.bv).mp hbv j hj64
        rw [hm_bit j hj64] at h0
        have hle : j ≤ frm.val.toNat := by omega
        simp [hle] at h0
        exact h0
      · simp only [hm0, ↓reduceIte]
        obtain ⟨k, hmsb, hk0, hk64, hkbit, hkhi⟩ := msb64_spec m hm0
        rw [hmsb, b_ok]
        rw [hm_bit k.val.toNat (by omega)] at hkbit
        simp only [Bool.and_eq_true, decide_eq_true_eq] at hkbit
        refine ⟨k, rfl, Or.inr ⟨hk0, hk64, by omega, hkbit.1, fun j hj1 hj2 hj3 => ?_⟩⟩
        have h0 := hkhi j hj1 hj2
        rw [hm_bit j hj2] at h0
        have hle : j ≤ frm.val.toNat := by omega
        simp [hle] at h0
        exact h0

end Bitmasks


end CronProofs
