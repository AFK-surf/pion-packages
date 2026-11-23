import Aeneas
import PionLean
import Http2.Types
import Http2.Funs

open Aeneas Aeneas.Std Result Pion http2

namespace Http2Proofs

@[simp]
lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by
  simp

lemma result_ok_inj {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b := by
  simpa using h

lemma iscalar_eq_of_bv_eq {ty} {a b : IScalar ty} (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

lemma iscalar_eq_of_val_eq {ty} {a b : IScalar ty} (h : a.val = b.val) : a = b :=
  iscalar_eq_of_bv_eq (BitVec.eq_of_toInt_eq h)

lemma i32_band_bv (a b : I32) : (Pion.I32.band a b).bv = a.bv &&& b.bv := by
  rfl

lemma i32_bor_bv (a b : I32) : (Pion.I32.bor a b).bv = a.bv ||| b.bv := by
  rfl

lemma i64_band_bv (a b : I64) : (Pion.I64.band a b).bv = a.bv &&& b.bv := by
  rfl

lemma i64_bor_bv (a b : I64) : (Pion.I64.bor a b).bv = a.bv ||| b.bv := by
  rfl

lemma i32_shl_ok (x : I32) (s : I32) (hs0 : 0 ≤ s.val) (hs1 : s.val < 32) :
    Pion.I32.shl x s = ok (⟨x.bv <<< s.val.toNat⟩ : I32) := by
  unfold Pion.I32.shl
  simp [hs0, hs1]

lemma i32_shr_ok (x : I32) (s : I32) (hs0 : 0 ≤ s.val) (hs1 : s.val < 32) :
    Pion.I32.shr x s = ok (⟨x.bv.sshiftRight s.val.toNat⟩ : I32) := by
  unfold Pion.I32.shr
  simp [hs0, hs1]

lemma i32_val_nonneg_toNat (x : I32) (hx : 0 ≤ x.val) :
    x.bv.toNat = x.val.toNat := by
  have h1 : x.val = x.bv.toInt := rfl
  have h2 : x.bv.toInt = if 2 * x.bv.toNat < 2 ^ 32 then (x.bv.toNat : Int) else (x.bv.toNat : Int) - 2 ^ 32 := by
    rw [BitVec.toInt_eq_toNat_cond]; rfl
  have hlt : x.bv.toNat < 2 ^ 32 := x.bv.isLt
  omega

lemma bv32_getElem_high_false (x : I32) (hx0 : 0 ≤ x.val) {k : Nat} (hx : x.val < ((2 ^ k : Nat) : Int))
    (i : Nat) (hi : i < 32) (hki : k ≤ i) : x.bv[i] = false := by
  rw [BitVec.getElem_eq_testBit_toNat, i32_val_nonneg_toNat x hx0]
  apply Nat.testBit_lt_two_pow
  have hlt : x.val.toNat < 2 ^ k := by omega
  exact Nat.lt_of_lt_of_le hlt (Nat.pow_le_pow_right (by omega) hki)

lemma bv32_nonneg_of_msb_false (x : I32) (hmsb : x.bv[31] = false) :
    0 ≤ x.val ∧ x.val ≤ 2147483647 := by
  have hval : x.val = x.bv.toInt := rfl
  have h2 : x.bv.toInt = if 2 * x.bv.toNat < 2 ^ 32 then (x.bv.toNat : Int) else (x.bv.toNat : Int) - 2 ^ 32 := by
    rw [BitVec.toInt_eq_toNat_cond]; rfl
  have htb : x.bv.toNat.testBit 31 = false := by
    rw [← BitVec.getElem_eq_testBit_toNat]; exact hmsb
  have hlt32 : x.bv.toNat < 2 ^ 32 := x.bv.isLt
  have hlt31 : x.bv.toNat < 2 ^ 31 := by
    by_contra hge
    have hge' : 2 ^ 31 ≤ x.bv.toNat := by omega
    have hdiv : x.bv.toNat / 2 ^ 31 = 1 := by omega
    rw [Nat.testBit, Nat.shiftRight_eq_div_pow, hdiv] at htb
    simp at htb
  omega

lemma i32_add_val_of_bounds (a b : I32)
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  have h1 : (Pion.I32.add a b).val = (a.bv + b.bv).toInt := rfl
  rw [h1, BitVec.toInt_add]
  have ha : a.bv.toInt = a.val := rfl
  have hb : b.bv.toInt = b.val := rfl
  rw [ha, hb]
  by_cases h0 : 0 ≤ a.val + b.val
  · have hm : (a.val + b.val) % ((2 ^ 32 : Nat) : Int) = a.val + b.val :=
      Int.emod_eq_of_lt h0 (by omega)
    simp only [Int.bmod, hm]; split <;> omega
  · have hm : (a.val + b.val) % ((2 ^ 32 : Nat) : Int) = a.val + b.val + ((2 ^ 32 : Nat) : Int) := by
      have h' : (a.val + b.val + ((2 ^ 32 : Nat) : Int)) % ((2 ^ 32 : Nat) : Int) =
          a.val + b.val + ((2 ^ 32 : Nat) : Int) :=
        Int.emod_eq_of_lt (by omega) (by omega)
      simpa [Int.add_emod_right] using h'
    simp only [Int.bmod, hm]; split <;> omega

lemma i64_sub_val_of_bounds (a b : I64)
    (hlo : -9223372036854775808 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 9223372036854775807) :
    (Pion.I64.sub a b).val = a.val - b.val := by
  have h1 : (Pion.I64.sub a b).val = (a.bv - b.bv).toInt := rfl
  rw [h1, BitVec.toInt_sub]
  have ha : a.bv.toInt = a.val := rfl
  have hb : b.bv.toInt = b.val := rfl
  rw [ha, hb]
  by_cases h0 : 0 ≤ a.val - b.val
  · have hm : (a.val - b.val) % ((2 ^ 64 : Nat) : Int) = a.val - b.val :=
      Int.emod_eq_of_lt h0 (by omega)
    simp only [Int.bmod, hm]; split <;> omega
  · have hm : (a.val - b.val) % ((2 ^ 64 : Nat) : Int) = a.val - b.val + ((2 ^ 64 : Nat) : Int) := by
      have h' : (a.val - b.val + ((2 ^ 64 : Nat) : Int)) % ((2 ^ 64 : Nat) : Int) =
          a.val - b.val + ((2 ^ 64 : Nat) : Int) :=
        Int.emod_eq_of_lt (by omega) (by omega)
      simpa [Int.add_emod_right] using h'
    simp only [Int.bmod, hm]; split <;> omega

/-- Theorem 3: RFC 9113 §5.1.1 server (odd) and client (even) remote stream parities partition all stream IDs. -/
theorem is_remote_stream_parity_complement (sid : I32) :
    ∃ bs bc, is_remote_stream_parity true sid = ok bs ∧
      is_remote_stream_parity false sid = ok bc ∧ bs = !bc := by
  unfold is_remote_stream_parity
  refine ⟨(Pion.I32.band sid 1#i32 == 1#i32), (Pion.I32.band sid 1#i32 == 0#i32), rfl, rfl, ?_⟩
  have hbits : (Pion.I32.band sid 1#i32).bv = 0#32 ∨ (Pion.I32.band sid 1#i32).bv = 1#32 := by
    cases h0 : sid.bv[0]
    · left
      apply BitVec.eq_of_getElem_eq
      intro i hi
      rw [i32_band_bv, BitVec.getElem_and]
      by_cases hiz : i = 0
      · subst hiz; simp [h0]
      · have h1f : (1#i32).bv[i] = false := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (1#i32).bv.toNat = 1 := by decide
          rw [this]
          exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 1 ≤ i)))
        rw [h1f]; simp
    · right
      apply BitVec.eq_of_getElem_eq
      intro i hi
      rw [i32_band_bv, BitVec.getElem_and]
      by_cases hiz : i = 0
      · subst hiz; simp [h0]
      · have h1f : (1#i32).bv[i] = false := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (1#i32).bv.toNat = 1 := by decide
          rw [this]
          exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 1 ≤ i)))
        have h132f : (1#32)[i] = false := by
          rw [BitVec.getElem_eq_testBit_toNat]
          have : (1#32).toNat = 1 := by decide
          rw [this]
          exact Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (by omega) (Nat.pow_le_pow_right (by omega) (by omega : 1 ≤ i)))
        rw [h1f, h132f]; simp
  rcases hbits with h0 | h1
  · have heq : Pion.I32.band sid 1#i32 = 0#i32 := iscalar_eq_of_bv_eq h0
    rw [heq]; decide
  · have heq : Pion.I32.band sid 1#i32 = 1#i32 := iscalar_eq_of_bv_eq h1
    rw [heq]; decide

/-- Theorem 4: RFC 9113 §6.9.1 flow-control window addition guard guarantees no overflow past 2^31 - 1. -/
theorem flow_window_add_ok_bounds (cur inc : I64)
    (hinc_max : inc.val ≤ 2147483647) :
    flow_window_add_ok cur inc = ok true →
      0 < inc.val ∧ cur.val + inc.val ≤ 2147483647 := by
  unfold flow_window_add_ok
  intro h
  have htrue : (decide (inc > 0#i64) && decide (cur <= Pion.I64.sub 2147483647#i64 inc)) = true :=
    result_ok_inj h
  simp only [Bool.and_eq_true, decide_eq_true_eq] at htrue
  rcases htrue with ⟨hpos, hle⟩
  have hpos' : 0 < inc.val := hpos
  have hmax : (2147483647#i64 : I64).val = 2147483647 := rfl
  have hsub : (Pion.I64.sub 2147483647#i64 inc).val = 2147483647 - inc.val := by
    have := i64_sub_val_of_bounds 2147483647#i64 inc (by omega) (by omega)
    omega
  have hle' : cur.val ≤ (Pion.I64.sub 2147483647#i64 inc).val := hle
  omega

/-- Theorem 6: RFC 9113 §5.1 receiving END_STREAM on any DATA-receiving state blocks all subsequent DATA. -/
theorem recv_end_stream_blocks_further_data (st : StreamState)
    (hok : can_recv_data_in_state st = ok 0#i32) :
    ∃ st', next_state_on_recv_end_stream st = ok st' ∧
      can_recv_data_in_state st' = ok 1#i32 := by
  cases st <;> simp [can_recv_data_in_state] at hok <;>
    simp [next_state_on_recv_end_stream, can_recv_data_in_state]

end Http2Proofs
