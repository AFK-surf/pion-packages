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

private lemma i64_beq_iff (x y : Std.I64) : (x == y) = true ↔ x.val = y.val := by
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

private lemma i64_band_u32_bounds (x : Std.I64) :
    0 ≤ (Pion.I64.band x 4294967295#i64).val ∧
    (Pion.I64.band x 4294967295#i64).val ≤ 4294967295 := by
  have hm : (4294967295#i64).bv = BitVec.ofNat 64 4294967295 := rfl
  have hnat : (Pion.I64.band x 4294967295#i64).bv.toNat = x.bv.toNat &&& 4294967295 := by
    change (x.bv &&& BitVec.ofNat 64 4294967295).toNat = _
    rw [BitVec.toNat_and]
    rfl
  have hle : x.bv.toNat &&& 4294967295 ≤ 4294967295 := Nat.and_le_right
  have hlt : 2 * (Pion.I64.band x 4294967295#i64).bv.toNat < 2 ^ 64 := by omega
  have hval : (Pion.I64.band x 4294967295#i64).val =
      ((Pion.I64.band x 4294967295#i64).bv.toNat : Int) := by
    change (Pion.I64.band x 4294967295#i64).bv.toInt = _
    exact BitVec.toInt_eq_toNat_of_lt hlt
  omega

private lemma i32_rem_nonneg (x y : Std.I32) (hx : 0 ≤ x.val) (hy : 0 < y.val) :
    ∃ r : Std.I32,
      Pion.I32.rem x y = ok r ∧
      r.val = x.val % y.val ∧ 0 ≤ r.val ∧ r.val < y.val := by
  have hnz : y.val ≠ 0 := by omega
  have hrem : Pion.I32.rem x y = ok ⟨x.bv.srem y.bv⟩ := by
    simp [Pion.I32.rem, HMod.hMod, IScalar.rem, hnz]
    omega
  refine ⟨⟨x.bv.srem y.bv⟩, hrem, ?_, ?_, ?_⟩
  · change (x.bv.srem y.bv).toInt = x.bv.toInt % y.bv.toInt
    rw [BitVec.toInt_srem]
    change Int.tmod x.val y.val = x.val % y.val
    exact Int.tmod_eq_emod_of_nonneg hx
  · change 0 ≤ (x.bv.srem y.bv).toInt
    rw [BitVec.toInt_srem]
    change 0 ≤ Int.tmod x.val y.val
    rw [Int.tmod_eq_emod_of_nonneg hx]
    exact Int.emod_nonneg x.val (by omega)
  · change (x.bv.srem y.bv).toInt < y.val
    rw [BitVec.toInt_srem]
    change Int.tmod x.val y.val < y.val
    rw [Int.tmod_eq_emod_of_nonneg hx]
    exact Int.emod_lt_of_pos x.val hy

private lemma i64_rem_nonneg (x y : Std.I64) (hx : 0 ≤ x.val) (hy : 0 < y.val) :
    ∃ r : Std.I64,
      Pion.I64.rem x y = ok r ∧
      0 ≤ r.val ∧ r.val < y.val := by
  have hnz : y.val ≠ 0 := by omega
  have hrem : Pion.I64.rem x y = ok ⟨x.bv.srem y.bv⟩ := by
    simp [Pion.I64.rem, HMod.hMod, IScalar.rem, hnz]
    omega
  refine ⟨⟨x.bv.srem y.bv⟩, hrem, ?_, ?_⟩
  · change 0 ≤ (x.bv.srem y.bv).toInt
    rw [BitVec.toInt_srem]
    change 0 ≤ Int.tmod x.val y.val
    rw [Int.tmod_eq_emod_of_nonneg hx]
    exact Int.emod_nonneg x.val (by omega)
  · change (x.bv.srem y.bv).toInt < y.val
    rw [BitVec.toInt_srem]
    change Int.tmod x.val y.val < y.val
    rw [Int.tmod_eq_emod_of_nonneg hx]
    exact Int.emod_lt_of_pos x.val hy

/-- 1. `rng_init_state` always produces a non-zero unsigned 32-bit state in `[1, 2^32 - 1]`. -/
theorem rng_init_state_nonzero_u32 (seed : Std.I32) :
    ∃ s : Std.I64,
      rng_init_state seed = ok s ∧ 1 ≤ s.val ∧ s.val ≤ 4294967295 := by
  unfold rng_init_state
  set u := Pion.I64.band (Pion.I32.to_int64 seed) 4294967295#i64
  set m := Pion.I64.band (Pion.I64.mul u 2654435761#i64) 4294967295#i64
  set mixed := Pion.I64.bxor m 2654435769#i64
  have hm_lt : m.bv.toNat < 2 ^ 32 := by
    have hb := i64_band_u32_bounds (Pion.I64.mul u 2654435761#i64)
    have hnat : m.bv.toNat = (Pion.I64.mul u 2654435761#i64).bv.toNat &&& 4294967295 := by
      change ((Pion.I64.mul u 2654435761#i64).bv &&& BitVec.ofNat 64 4294967295).toNat = _
      rw [BitVec.toNat_and]; rfl
    have hle : (Pion.I64.mul u 2654435761#i64).bv.toNat &&& 4294967295 ≤ 4294967295 := Nat.and_le_right
    omega
  have hmix_nat : mixed.bv.toNat = m.bv.toNat ^^^ 2654435769 := by
    change (m.bv ^^^ BitVec.ofNat 64 2654435769).toNat = _
    rw [BitVec.toNat_xor]; rfl
  have hmix_lt : mixed.bv.toNat < 2 ^ 32 := by
    rw [hmix_nat]
    exact Nat.xor_lt_two_pow hm_lt (by decide)
  have hmix_val : mixed.val = (mixed.bv.toNat : Int) := by
    change mixed.bv.toInt = _
    exact BitVec.toInt_eq_toNat_of_lt (by omega)
  refine ⟨if mixed = 0#i64 then 1#i64 else mixed, rfl, ?_⟩
  by_cases hz : mixed = 0#i64
  · simp [hz]
  · simp only [hz, ↓reduceIte]
    have hnz : mixed.val ≠ 0 := by
      intro h0
      apply hz
      have h0bv : (0#i64).bv.toInt = 0 := by decide
      cases hmx : mixed with | mk bv =>
        rw [hmx] at h0
        change bv.toInt = 0 at h0
        have : bv = (0#i64).bv := by
          rw [← BitVec.toInt_inj]
          omega
        cases h0i : (0#i64) with | mk bv0 =>
          rw [h0i] at this
          exact congrArg IScalar.mk this
    omega

private lemma shl_i32_13 (x : Std.I64) :
    Pion.I64.shl_i32 x 13#i32 = ok ⟨x.bv <<< (13#i32).val.toNat⟩ := by
  have h : 0 ≤ (13#i32).val ∧ (13#i32).val < 64 := by decide
  simp only [Pion.I64.shl_i32, h, and_self, ↓reduceIte]

private lemma shr_i32_17 (x : Std.I64) :
    Pion.I64.shr_i32 x 17#i32 = ok ⟨x.bv.sshiftRight (17#i32).val.toNat⟩ := by
  have h : 0 ≤ (17#i32).val ∧ (17#i32).val < 64 := by decide
  simp only [Pion.I64.shr_i32, h, and_self, ↓reduceIte]

private lemma shl_i32_5 (x : Std.I64) :
    Pion.I64.shl_i32 x 5#i32 = ok ⟨x.bv <<< (5#i32).val.toNat⟩ := by
  have h : 0 ≤ (5#i32).val ∧ (5#i32).val < 64 := by decide
  simp only [Pion.I64.shl_i32, h, and_self, ↓reduceIte]

/-- 2. `rng_step_u32` always returns a valid unsigned 32-bit state in `[0, 2^32 - 1]`. -/
theorem rng_step_u32_bounds (s : Std.I64) :
    ∃ s' : Std.I64,
      rng_step_u32 s = ok s' ∧ 0 ≤ s'.val ∧ s'.val ≤ 4294967295 := by
  simp only [rng_step_u32, shl_i32_13, shr_i32_17, shl_i32_5, result_bind_ok]
  exact ⟨_, rfl, i64_band_u32_bounds _⟩

/-- 3. `0` is a fixed point of `rng_step_u32` (showing why `rng_init_state` must avoid `0`). -/
theorem rng_step_u32_zero_fixed :
    rng_step_u32 0#i64 = ok 0#i64 := by
  simp only [rng_step_u32, shl_i32_13, shr_i32_17, shl_i32_5, result_bind_ok]
  rfl

/-- 4. `rng_below_val` returns `0` whenever `n ≤ 1`. -/
theorem rng_below_val_le_one (draw : Std.I64) (n : Std.I32) (hn : n.val ≤ 1) :
    rng_below_val draw n = ok 0#i32 := by
  unfold rng_below_val
  have h1 : (1#i32).val = 1 := by decide
  have hle : n ≤ 1#i32 := by
    simp only [IScalar.le_equiv, h1]; omega
  simp [hle]

/-- 5. For any non-negative `draw` and `n ≥ 2`, `rng_below_val draw n` lies strictly in `[0, n)`. -/
theorem rng_below_val_bounds (draw : Std.I64) (n : Std.I32)
    (hd : 0 ≤ draw.val) (hn : 2 ≤ n.val) :
    ∃ v : Std.I32,
      rng_below_val draw n = ok v ∧ 0 ≤ v.val ∧ v.val < n.val := by
  unfold rng_below_val
  have h1 : (1#i32).val = 1 := by decide
  have hnle : ¬ (n ≤ 1#i32) := by
    simp only [IScalar.le_equiv, h1]; omega
  simp only [hnle, ↓reduceIte]
  have hn64 : (Pion.I32.to_int64 n).val = n.val := by
    simp [Pion.I32.to_int64]
  obtain ⟨r, hr, hr0, hrlt⟩ := i64_rem_nonneg draw (Pion.I32.to_int64 n) hd (by omega)
  rw [hr, result_bind_ok]
  refine ⟨Pion.I64.to_int r, rfl, ?_⟩
  have hcast : (Pion.I64.to_int r).val = r.val := by
    have hn_le : n.val < 2 ^ 31 := by
      have := n.hBounds
      simp at this
      omega
    simp only [Pion.I64.to_int, IScalar.cast, IScalar.val]
    change (r.bv.signExtend 32).toInt = r.bv.toInt
    rw [BitVec.toInt_signExtend]
    have : r.bv.toInt.bmod (2 ^ 32) = r.bv.toInt :=
      Int.bmod_eq_of_le (by change 0 ≤ r.bv.toInt at hr0; omega)
        (by change r.bv.toInt < (Pion.I32.to_int64 n).val at hrlt; omega)
    simpa using this
  omega

/-- 6. `ring_next_cap` strictly grows capacity without overflow for `0 ≤ old_cap < 2^30`. -/
theorem ring_next_cap_grows (old_cap : Std.I32)
    (hlo : 0 ≤ old_cap.val) (hhi : old_cap.val < 2 ^ 30) :
    ∃ c : Std.I32,
      ring_next_cap old_cap = ok c ∧ old_cap.val < c.val ∧ 2 ≤ c.val := by
  unfold ring_next_cap
  refine ⟨_, rfl, ?_⟩
  by_cases hz : old_cap = 0#i32
  · simp [hz]
  · simp only [hz, ↓reduceIte]
    have hnz : old_cap.val ≠ 0 := by
      intro h0
      exact hz (i32_eq_of_val (by simpa using h0))
    have h2 : (2#i32).val = 2 := by decide
    have hm : (Pion.I32.mul old_cap 2#i32).val = old_cap.val * 2 := by
      rw [i32_mul_val old_cap 2#i32 (by rw [h2]; omega) (by rw [h2]; omega), h2]
    omega

/-- 7. `ring_slot_add` always produces an in-bounds buffer index `[0, cap)`. -/
theorem ring_slot_add_bounds (head offset cap : Std.I32)
    (hh : 0 ≤ head.val) (ho : 0 ≤ offset.val) (hc : 0 < cap.val)
    (hsum : head.val + offset.val < 2 ^ 31) :
    ∃ slot : Std.I32,
      ring_slot_add head offset cap = ok slot ∧ 0 ≤ slot.val ∧ slot.val < cap.val := by
  unfold ring_slot_add
  have ha : (Pion.I32.add head offset).val = head.val + offset.val :=
    i32_add_val head offset (by omega) (by omega)
  obtain ⟨r, hr, _, hr0, hrlt⟩ := i32_rem_nonneg (Pion.I32.add head offset) cap (by omega) hc
  rw [hr, result_bind_ok]
  exact ⟨r, rfl, hr0, hrlt⟩

/-- 8. `ring_slot_prev` always produces an in-bounds buffer index `[0, cap)`. -/
theorem ring_slot_prev_bounds (head cap : Std.I32)
    (hh0 : 0 ≤ head.val) (hhc : head.val < cap.val) (hc : cap.val < 2 ^ 30) :
    ∃ prev : Std.I32,
      ring_slot_prev head cap = ok prev ∧ 0 ≤ prev.val ∧ prev.val < cap.val := by
  unfold ring_slot_prev
  have h1 : (1#i32).val = 1 := by decide
  have hs : (Pion.I32.sub head 1#i32).val = head.val - 1 := by
    rw [i32_sub_val head 1#i32 (by omega) (by omega), h1]
  have ha : (Pion.I32.add (Pion.I32.sub head 1#i32) cap).val = head.val - 1 + cap.val := by
    rw [i32_add_val _ cap (by omega) (by omega), hs]
  obtain ⟨r, hr, _, hr0, hrlt⟩ :=
    i32_rem_nonneg (Pion.I32.add (Pion.I32.sub head 1#i32) cap) cap (by omega) (by omega)
  rw [hr, result_bind_ok]
  exact ⟨r, rfl, hr0, hrlt⟩

/-- 9. `ring_slot_add (ring_slot_prev head cap) 1 cap = head` (exact `push_front`/`pop_front` inverse). -/
theorem ring_slot_prev_add_one_inv (head cap : Std.I32)
    (hh0 : 0 ≤ head.val) (hhc : head.val < cap.val) (hc : cap.val < 2 ^ 30) :
    ∃ prev : Std.I32,
      ring_slot_prev head cap = ok prev ∧
      ring_slot_add prev 1#i32 cap = ok head := by
  unfold ring_slot_prev ring_slot_add
  have h1 : (1#i32).val = 1 := by decide
  have hs : (Pion.I32.sub head 1#i32).val = head.val - 1 := by
    rw [i32_sub_val head 1#i32 (by omega) (by omega), h1]
  have ha : (Pion.I32.add (Pion.I32.sub head 1#i32) cap).val = head.val - 1 + cap.val := by
    rw [i32_add_val _ cap (by omega) (by omega), hs]
  obtain ⟨prev, hprev, hprev_eq, hprev0, hprevlt⟩ :=
    i32_rem_nonneg (Pion.I32.add (Pion.I32.sub head 1#i32) cap) cap (by omega) (by omega)
  rw [hprev, result_bind_ok]
  have ha2 : (Pion.I32.add prev 1#i32).val = prev.val + 1 := by
    rw [i32_add_val prev 1#i32 (by omega) (by omega), h1]
  obtain ⟨res, hres, hres_eq, _, _⟩ :=
    i32_rem_nonneg (Pion.I32.add prev 1#i32) cap (by omega) (by omega)
  refine ⟨prev, rfl, ?_⟩
  rw [hres, result_bind_ok]
  congr 1
  apply i32_eq_of_val
  rw [hres_eq, ha2, hprev_eq, ha]
  by_cases hhead0 : head.val = 0
  · have hm1 : (head.val - 1 + cap.val) % cap.val = cap.val - 1 := by
      have heq : head.val - 1 + cap.val = cap.val - 1 := by omega
      rw [heq]
      exact Int.emod_eq_of_lt (by omega) (by omega)
    rw [hm1]
    have : (cap.val - 1 + 1) % cap.val = 0 := by
      have hcap : cap.val - 1 + 1 = cap.val := by omega
      rw [hcap, Int.emod_self]
    omega
  · have hm1 : (head.val - 1 + cap.val) % cap.val = head.val - 1 := by
      have heq : head.val - 1 + cap.val = (head.val - 1) + cap.val * 1 := by omega
      rw [heq, Int.add_mul_emod_self_left]
      exact Int.emod_eq_of_lt (by omega) (by omega)
    rw [hm1]
    have : head.val - 1 + 1 = head.val := by omega
    rw [this]
    exact Int.emod_eq_of_lt hh0 hhc

/-- 10. `timer_before` is irreflexive. -/
theorem timer_before_irrefl (at1 : Std.I64) (seq1 : Std.I32) :
    timer_before at1 seq1 at1 seq1 = ok false := by
  unfold timer_before
  simp

/-- 11. `timer_before` is asymmetric. -/
theorem timer_before_asymm (at1 : Std.I64) (seq1 : Std.I32) (at2 : Std.I64) (seq2 : Std.I32) :
    timer_before at1 seq1 at2 seq2 = ok true →
    timer_before at2 seq2 at1 seq1 = ok false := by
  unfold timer_before
  simp only [Result.ok.injEq, Bool.or_eq_true, Bool.and_eq_true, Bool.or_eq_false_iff,
    Bool.and_eq_false_iff, decide_eq_true_eq, decide_eq_false_iff_not,
    IScalar.lt_equiv, i64_beq_iff]
  intro h
  constructor
  · omega
  · by_cases heq : at2.val = at1.val
    · right; omega
    · left
      cases hb : (at2 == at1)
      · rfl
      · rw [i64_beq_iff] at hb; omega

/-- 12. `timer_before` is transitive. -/
theorem timer_before_trans
    (at1 : Std.I64) (seq1 : Std.I32)
    (at2 : Std.I64) (seq2 : Std.I32)
    (at3 : Std.I64) (seq3 : Std.I32) :
    timer_before at1 seq1 at2 seq2 = ok true →
    timer_before at2 seq2 at3 seq3 = ok true →
    timer_before at1 seq1 at3 seq3 = ok true := by
  unfold timer_before
  simp only [Result.ok.injEq, Bool.or_eq_true, Bool.and_eq_true,
    decide_eq_true_eq, IScalar.lt_equiv, i64_beq_iff]
  intro h12 h23
  omega

end EffectProofs
