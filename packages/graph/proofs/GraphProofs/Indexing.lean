import GraphProofs.Core

open Aeneas Aeneas.Std Result Pion graph

namespace GraphProofs

private lemma i32_shl_1 (x : Std.I32) :
    Pion.I32.shl x 1#i32 = ok (⟨x.bv <<< 1⟩ : Std.I32) := by
  unfold Pion.I32.shl
  have h1 : (1#i32).val = 1 := by norm_num
  have h1n : (1#i32).val.toNat = 1 := by norm_num
  have hc : 0 ≤ (1#i32).val ∧ (1#i32).val < 32 := by omega
  simp only [hc, and_self, ↓reduceIte, h1n]

private lemma i32_shr_1 (x : Std.I32) :
    Pion.I32.shr x 1#i32 = ok (⟨x.bv.sshiftRight 1⟩ : Std.I32) := by
  unfold Pion.I32.shr
  have h1 : (1#i32).val = 1 := by norm_num
  have h1n : (1#i32).val.toNat = 1 := by norm_num
  have hc : 0 ≤ (1#i32).val ∧ (1#i32).val < 32 := by omega
  simp only [hc, and_self, ↓reduceIte, h1n]

/-- Dinic residual graph: `residual_twin` is an involution (`(e ^ 1) ^ 1 = e`) for all `e : Int`. -/
theorem residual_twin_involution (e : Std.I32) :
    (do let t ← residual_twin e; residual_twin t) = ok e := by
  unfold residual_twin
  rw [result_bind_ok]
  congr 1
  unfold Pion.I32.bxor
  cases e with | mk bv =>
  congr 1
  rw [BitVec.xor_assoc, BitVec.xor_self]
  exact BitVec.xor_zero

/-- Dinic residual graph: no half-edge is its own residual twin (`e ^ 1 ≠ e`). -/
theorem residual_twin_ne_self (e : Std.I32) :
    residual_twin e ≠ ok e := by
  unfold residual_twin Pion.I32.bxor
  intro h
  have heq : (⟨e.bv ^^^ (1#32 : BitVec 32)⟩ : Std.I32) = e := result_ok_inj h
  have hbv : e.bv ^^^ (1#32 : BitVec 32) = e.bv := congrArg IScalar.bv heq
  have hlsb := congrArg (fun (x : BitVec 32) => x.getLsbD 0) hbv
  rw [BitVec.getLsbD_xor] at hlsb
  have h1 : (1#32 : BitVec 32).getLsbD 0 = true := by decide
  rw [h1] at hlsb
  cases h0 : e.bv.getLsbD 0 <;> simp at hlsb

private lemma i32_shl1_val (x : Std.I32) (hlo : 0 ≤ x.val) (hhi : x.val < 1073741824) :
    (⟨x.bv <<< 1⟩ : Std.I32).val = 2 * x.val := by
  have hpow : (2 : Nat) ^ 32 = 4294967296 := by norm_num
  have hxlt : x.bv.toNat < 4294967296 := by have := x.bv.isLt; rw [hpow] at this; exact this
  have hti := BitVec.toInt_eq_toNat_cond x.bv
  rw [hpow] at hti
  have hxval : x.val = x.bv.toInt := rfl
  have hxnat : x.bv.toNat = x.val.toNat := by
    by_cases hlt : 2 * x.bv.toNat < 4294967296
    · rw [ite_eq_left hlt] at hti; omega
    · rw [ite_eq_right hlt] at hti; omega
  have hshl_nat : (x.bv <<< 1).toNat = 2 * x.bv.toNat := by
    rw [BitVec.toNat_shiftLeft, hpow, Nat.shiftLeft_eq]
    rw [Nat.mod_eq_of_lt (by omega)]; omega
  have hti2 := BitVec.toInt_eq_toNat_cond (x.bv <<< 1)
  rw [hpow, hshl_nat] at hti2
  change (x.bv <<< 1).toInt = 2 * x.val
  rw [ite_eq_left (by omega)] at hti2
  omega

/-- Dinic forward half-edge index equals `2 * i` for all `0 <= i < 2^30`. -/
lemma forward_half_edge_val (i : Std.I32) (h0 : 0 ≤ i.val) (hhi : i.val < 1073741824) :
    ∃ f : Std.I32, forward_half_edge i = ok f ∧ f.val = 2 * i.val := by
  unfold forward_half_edge
  rw [i32_shl_1, result_bind_ok]
  exact ⟨⟨i.bv <<< 1⟩, rfl, i32_shl1_val i h0 hhi⟩

/-- Dinic forward/reverse half-edge pairing: `residual_twin (2*i) = 2*i + 1` and `residual_twin (2*i + 1) = 2*i`. -/
theorem forward_reverse_half_edge_pair (i : Std.I32) (h0 : 0 ≤ i.val) (hhi : i.val < 1073741824) :
    ∃ f r : Std.I32,
      forward_half_edge i = ok f ∧
      residual_twin f = ok r ∧
      residual_twin r = ok f ∧
      f.val = 2 * i.val ∧
      r.val = 2 * i.val + 1 := by
  obtain ⟨f, hf, hfv⟩ := forward_half_edge_val i h0 hhi
  set r := Pion.I32.bxor f 1#i32
  have hr_twin : residual_twin f = ok r := rfl
  have hr_back : residual_twin r = ok f := by
    have hinv := residual_twin_involution f
    rw [hr_twin, result_bind_ok] at hinv
    exact hinv
  have hrv : r.val = 2 * i.val + 1 := by
    have hpow : (2 : Nat) ^ 32 = 4294967296 := by norm_num
    have hfnat : f.bv.toNat = (2 * i.val).toNat := by
      have hti := BitVec.toInt_eq_toNat_cond f.bv
      have hflt : f.bv.toNat < 4294967296 := by have := f.bv.isLt; rw [hpow] at this; exact this
      rw [hpow] at hti
      have : f.bv.toInt = 2 * i.val := hfv
      by_cases hlt : 2 * f.bv.toNat < 4294967296
      · rw [ite_eq_left hlt] at hti; omega
      · rw [ite_eq_right hlt] at hti; omega
    have hrnat : r.bv.toNat = f.bv.toNat + 1 := by
      change (f.bv ^^^ (1#32 : BitVec 32)).toNat = f.bv.toNat + 1
      rw [BitVec.toNat_xor]
      have h1nat : (1#32 : BitVec 32).toNat = 1 := by norm_num
      rw [h1nat]
      have heven : f.bv.toNat % 2 = 0 := by omega
      apply Nat.eq_of_testBit_eq; intro k
      rw [Nat.testBit_xor]
      cases k with
      | zero =>
        simp [Nat.testBit_zero, heven]
        omega
      | succ k' =>
        have h1k : (1 : Nat).testBit (k' + 1) = false := Nat.testBit_eq_false_of_lt (by
          have : 2 ≤ 2 ^ (k' + 1) := by
            have := Nat.pow_le_pow_right (by norm_num : 1 ≤ 2) (Nat.succ_le_succ (Nat.zero_le k'))
            simpa using this
          omega)
        rw [h1k, Bool.xor_false]
        rw [Nat.testBit, Nat.testBit, Nat.shiftRight_eq_div_pow, Nat.shiftRight_eq_div_pow]
        have hdiv : (f.bv.toNat + 1) / 2 ^ (k' + 1) = f.bv.toNat / 2 ^ (k' + 1) := by
          have hp : 2 ^ (k' + 1) = 2 * 2 ^ k' := by rw [Nat.pow_succ]; ring
          rw [hp, ← Nat.div_div_eq_div_mul, ← Nat.div_div_eq_div_mul]
          congr 1; omega
        rw [hdiv]
    have hti2 := BitVec.toInt_eq_toNat_cond r.bv
    rw [hpow, hrnat] at hti2
    change r.bv.toInt = 2 * i.val + 1
    rw [ite_eq_left (by omega)] at hti2
    omega
  exact ⟨f, r, hf, hr_twin, hr_back, hfv, hrv⟩

/-- Binary heap `heap_parent` computes `(idx - 1) / 2` for all `idx > 0`. -/
lemma heap_parent_val (idx : Std.I32) (hpos : 0 < idx.val) :
    ∃ p : Std.I32, heap_parent idx = ok p ∧ p.val = (idx.val - 1) / 2 := by
  have hidx := i32_bounds idx
  unfold heap_parent
  rw [i32_shr_1, result_bind_ok]
  refine ⟨⟨(Pion.I32.sub idx 1#i32).bv.sshiftRight 1⟩, rfl, ?_⟩
  have hsub : (Pion.I32.sub idx 1#i32).val = idx.val - 1 := by
    have h1 : (1#i32).val = 1 := by norm_num
    rw [i32_sub_val idx 1#i32 (by omega) (by omega), h1]
  change ((Pion.I32.sub idx 1#i32).bv.sshiftRight 1).toInt = (idx.val - 1) / 2
  rw [BitVec.toInt_sshiftRight]
  have : (Pion.I32.sub idx 1#i32).bv.toInt = (Pion.I32.sub idx 1#i32).val := rfl
  rw [this, hsub]
  simp [Int.shiftRight_eq_div_pow]

/-- Binary heap sift-up termination: `0 <= heap_parent idx < idx` for all `idx > 0`. -/
theorem heap_parent_strict_decrease (idx : Std.I32) (hpos : 0 < idx.val) :
    ∃ p : Std.I32, heap_parent idx = ok p ∧ 0 ≤ p.val ∧ p.val < idx.val := by
  obtain ⟨p, hp, hpv⟩ := heap_parent_val idx hpos
  exact ⟨p, hp, by omega, by omega⟩

/-- Binary heap `heap_left_child` computes `2 * idx + 1` for all `0 <= idx < 2^30`. -/
lemma heap_left_child_val (idx : Std.I32) (h0 : 0 ≤ idx.val) (hhi : idx.val < 1073741824) :
    ∃ l : Std.I32, heap_left_child idx = ok l ∧ l.val = 2 * idx.val + 1 := by
  unfold heap_left_child
  rw [i32_shl_1, result_bind_ok]
  refine ⟨Pion.I32.add ⟨idx.bv <<< 1⟩ 1#i32, rfl, ?_⟩
  have hshl := i32_shl1_val idx h0 hhi
  have h1 : (1#i32).val = 1 := by norm_num
  rw [i32_add_val _ 1#i32 (by omega) (by omega), hshl, h1]

/-- Binary heap parent-child bijection: `heap_parent` is the exact left-inverse of both `heap_left_child` and `heap_left_child + 1`. -/
theorem heap_parent_children_inverse (idx : Std.I32) (h0 : 0 ≤ idx.val) (hhi : idx.val < 1073741823) :
    (do let l ← heap_left_child idx; heap_parent l) = ok idx ∧
    (do let l ← heap_left_child idx; heap_parent (Pion.I32.add l 1#i32)) = ok idx := by
  obtain ⟨l, hl, hlv⟩ := heap_left_child_val idx h0 (by omega)
  constructor
  · rw [hl, result_bind_ok]
    obtain ⟨p, hp, hpv⟩ := heap_parent_val l (by omega)
    rw [hp]; congr 1; exact (iscalar_eq_iff p idx).mpr (by omega)
  · rw [hl, result_bind_ok]
    have h1 : (1#i32).val = 1 := by norm_num
    have hr_val : (Pion.I32.add l 1#i32).val = 2 * idx.val + 2 := by
      rw [i32_add_val l 1#i32 (by omega) (by omega), hlv, h1]; omega
    obtain ⟨p, hp, hpv⟩ := heap_parent_val (Pion.I32.add l 1#i32) (by omega)
    rw [hp]; congr 1; exact (iscalar_eq_iff p idx).mpr (by omega)

end GraphProofs
