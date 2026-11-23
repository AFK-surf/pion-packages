import Aeneas
import PionLean
import Git.Types
import Git.Funs

open Aeneas Aeneas.Std Result Pion git

namespace GitProofs

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private lemma i32_bv_toNat_of_nonneg (x : Std.I32) (h0 : 0 ≤ x.val) :
    (x.bv.toNat : Int) = x.val := by
  have h := x.bv.toInt_eq_toNat_cond
  change 0 ≤ x.bv.toInt at h0
  split_ifs at h with hcond
  · exact h.symm
  · have := x.bv.isLt; omega

private lemma i32_val_of_bv_toNat_lt (x : Std.I32) (hlt : x.bv.toNat < 2 ^ 31) :
    x.val = (x.bv.toNat : Int) := by
  have h := x.bv.toInt_eq_toNat_cond
  have h2 : 2 * x.bv.toNat < 2 ^ 32 := by omega
  simp only [h2, ↓reduceIte] at h
  exact h

private lemma i32_add_val (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  change -2147483648 ≤ a.bv.toInt + b.bv.toInt at hlo
  change a.bv.toInt + b.bv.toInt ≤ 2147483647 at hhi
  change (a.bv + b.bv).toInt = a.bv.toInt + b.bv.toInt
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_sub_val (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  change -2147483648 ≤ a.bv.toInt - b.bv.toInt at hlo
  change a.bv.toInt - b.bv.toInt ≤ 2147483647 at hhi
  change (a.bv - b.bv).toInt = a.bv.toInt - b.bv.toInt
  rw [BitVec.toInt_sub]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_shl_nonneg (x : Std.I32) (k : Std.I32)
    (hk0 : 0 ≤ k.val) (hk31 : k.val < 32)
    (hfit : x.bv.toNat * 2 ^ k.bv.toNat < 2 ^ 31) :
    ∃ r : Std.I32, Pion.I32.shl x k = ok r ∧
      r.bv.toNat = x.bv.toNat * 2 ^ k.bv.toNat := by
  have hk_nat : (k.bv.toNat : Int) = k.val := i32_bv_toNat_of_nonneg k hk0
  have hknat_eq : k.val.toNat = k.bv.toNat := by omega
  have hshl : Pion.I32.shl x k = ok ⟨x.bv <<< k.bv.toNat⟩ := by
    unfold Pion.I32.shl
    simp only [hk0, hk31, and_self, ↓reduceIte, hknat_eq]
  refine ⟨⟨x.bv <<< k.bv.toNat⟩, hshl, ?_⟩
  rw [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq]
  exact Nat.mod_eq_of_lt (by omega)

private lemma testBit_mul_pow2 (x k i : Nat) :
    (x * 2 ^ k).testBit i = if i < k then false else x.testBit (i - k) := by
  rw [← Nat.shiftLeft_eq, Nat.testBit_shiftLeft]
  by_cases h : i < k
  · have h1 : ¬ (k ≤ i) := by omega
    simp [h, h1]
  · have h1 : k ≤ i := by omega
    simp [h, h1]

private lemma testBit_lt_pow2 (x k i : Nat) (hx : x < 2 ^ k) (hi : k ≤ i) :
    x.testBit i = false := by
  apply Nat.testBit_lt_two_pow
  have hle : 2 ^ k ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) hi
  omega

private lemma nat_or_mul_pow2_add (m b k : Nat) (hb : b < 2 ^ k) :
    (m * 2 ^ k) ||| b = m * 2 ^ k + b := by
  apply Nat.eq_of_testBit_eq
  intro i
  rw [Nat.testBit_or, testBit_mul_pow2]
  by_cases hi : i < k
  · simp only [hi, ↓reduceIte, Bool.false_or]
    rw [Nat.testBit_eq_decide_div_mod_eq, Nat.testBit_eq_decide_div_mod_eq]
    have hpow : 2 ^ k = 2 ^ (k - i) * 2 ^ i := by
      rw [← Nat.pow_add]; congr 1; omega
    have hpos : 0 < 2 ^ i := Nat.two_pow_pos i
    have hdiv : (m * 2 ^ k + b) / 2 ^ i = m * 2 ^ (k - i) + b / 2 ^ i := by
      rw [hpow, ← Nat.mul_assoc, Nat.add_comm, Nat.add_mul_div_right _ _ hpos, Nat.add_comm]
    have heven : 2 ∣ 2 ^ (k - i) := by
      have : 2 ^ (k - i) = 2 * 2 ^ (k - i - 1) := by
        conv => lhs; rw [show k - i = (k - i - 1) + 1 by omega, Nat.pow_succ, Nat.mul_comm]
      exact ⟨2 ^ (k - i - 1), this⟩
    rcases heven with ⟨q, hq⟩
    rw [hdiv, hq]
    have hmod : (m * (2 * q) + b / 2 ^ i) % 2 = (b / 2 ^ i) % 2 := by
      have hre : m * (2 * q) = 2 * (m * q) := by
        rw [← Nat.mul_assoc, Nat.mul_comm m 2, Nat.mul_assoc]
      rw [hre, Nat.add_comm, Nat.add_mul_mod_self_left]
    rw [hmod]
  · simp only [hi, ↓reduceIte]
    rw [testBit_lt_pow2 b k i hb (by omega), Bool.or_false]
    rw [Nat.testBit_eq_decide_div_mod_eq, Nat.testBit_eq_decide_div_mod_eq]
    have hpow : 2 ^ i = 2 ^ k * 2 ^ (i - k) := by
      rw [← Nat.pow_add]; congr 1; omega
    have hposk : 0 < 2 ^ k := Nat.two_pow_pos k
    have hdiv1 : (m * 2 ^ k + b) / 2 ^ k = m := by
      rw [Nat.add_comm, Nat.add_mul_div_right _ _ hposk, Nat.div_eq_of_lt hb, Nat.zero_add]
    rw [hpow, ← Nat.div_div_eq_div_mul, hdiv1]

/-- Theorem 1: `hex_nibble` always returns either `-1` or a valid nibble in `[0, 15]`. -/
theorem hex_nibble_range (c : Std.I32) :
    ∃ r : Std.I32, hex_nibble c = ok r ∧ (r.val = -1 ∨ (0 ≤ r.val ∧ r.val ≤ 15)) := by
  unfold hex_nibble
  have c48 : (48#i32 : Std.I32).val = 48 := rfl
  have c97 : (97#i32 : Std.I32).val = 97 := rfl
  have c65 : (65#i32 : Std.I32).val = 65 := rfl
  have c10 : (10#i32 : Std.I32).val = 10 := rfl
  refine ⟨_, rfl, ?_⟩
  split_ifs with h1 h2 h3
  · right
    simp only [Bool.and_eq_true, decide_eq_true_eq] at h1
    have ha : (48 : Int) ≤ c.val := h1.1
    have hb : c.val ≤ (57 : Int) := h1.2
    have hsub := i32_sub_val c 48#i32 (by omega) (by omega)
    omega
  · right
    simp only [Bool.and_eq_true, decide_eq_true_eq] at h2
    have ha : (97 : Int) ≤ c.val := h2.1
    have hb : c.val ≤ (102 : Int) := h2.2
    have hsub := i32_sub_val c 97#i32 (by omega) (by omega)
    have hadd := i32_add_val (Pion.I32.sub c 97#i32) 10#i32 (by omega) (by omega)
    omega
  · right
    simp only [Bool.and_eq_true, decide_eq_true_eq] at h3
    have ha : (65 : Int) ≤ c.val := h3.1
    have hb : c.val ≤ (70 : Int) := h3.2
    have hsub := i32_sub_val c 65#i32 (by omega) (by omega)
    have hadd := i32_add_val (Pion.I32.sub c 65#i32) 10#i32 (by omega) (by omega)
    omega
  · left; rfl

/-- Theorem 3: `pkt_line_decode_len` computes the exact 16-bit big-endian hex value in `[0, 65535]`. -/
theorem pkt_line_decode_len_exact (n0 n1 n2 n3 : Std.I32)
    (h0 : 0 ≤ n0.val ∧ n0.val ≤ 15)
    (h1 : 0 ≤ n1.val ∧ n1.val ≤ 15)
    (h2 : 0 ≤ n2.val ∧ n2.val ≤ 15)
    (h3 : 0 ≤ n3.val ∧ n3.val ≤ 15) :
    ∃ r : Std.I32, pkt_line_decode_len n0 n1 n2 n3 = ok r ∧
      r.val = n0.val * 4096 + n1.val * 256 + n2.val * 16 + n3.val ∧
      0 ≤ r.val ∧ r.val ≤ 65535 := by
  have hn0 : (n0.bv.toNat : Int) = n0.val := i32_bv_toNat_of_nonneg n0 h0.1
  have hn1 : (n1.bv.toNat : Int) = n1.val := i32_bv_toNat_of_nonneg n1 h1.1
  have hn2 : (n2.bv.toNat : Int) = n2.val := i32_bv_toNat_of_nonneg n2 h2.1
  have hn3 : (n3.bv.toNat : Int) = n3.val := i32_bv_toNat_of_nonneg n3 h3.1
  have hs0 := i32_shl_nonneg n0 12#i32 (by decide) (by decide) (by
    change n0.bv.toNat * 2 ^ 12 < 2 ^ 31; omega)
  have hs1 := i32_shl_nonneg n1 8#i32 (by decide) (by decide) (by
    change n1.bv.toNat * 2 ^ 8 < 2 ^ 31; omega)
  have hs2 := i32_shl_nonneg n2 4#i32 (by decide) (by decide) (by
    change n2.bv.toNat * 2 ^ 4 < 2 ^ 31; omega)
  rcases hs0 with ⟨t0, ht0, ht0n⟩
  rcases hs1 with ⟨t1, ht1, ht1n⟩
  rcases hs2 with ⟨t2, ht2, ht2n⟩
  change t0.bv.toNat = n0.bv.toNat * 2 ^ 12 at ht0n
  change t1.bv.toNat = n1.bv.toNat * 2 ^ 8 at ht1n
  change t2.bv.toNat = n2.bv.toNat * 2 ^ 4 at ht2n
  unfold pkt_line_decode_len
  simp only [ht0, ht1, ht2, result_bind_ok]
  set r := Pion.I32.bor (Pion.I32.bor (Pion.I32.bor t0 t1) t2) n3
  have hbor1 : (t0.bv ||| t1.bv).toNat = n0.bv.toNat * 2 ^ 12 + n1.bv.toNat * 2 ^ 8 := by
    rw [BitVec.toNat_or, ht0n, ht1n]
    exact nat_or_mul_pow2_add n0.bv.toNat (n1.bv.toNat * 2 ^ 8) 12 (by omega)
  have hbor2 : ((t0.bv ||| t1.bv) ||| t2.bv).toNat =
      n0.bv.toNat * 2 ^ 12 + n1.bv.toNat * 2 ^ 8 + n2.bv.toNat * 2 ^ 4 := by
    rw [BitVec.toNat_or, hbor1, ht2n]
    have hfac : n0.bv.toNat * 2 ^ 12 + n1.bv.toNat * 2 ^ 8 = (n0.bv.toNat * 16 + n1.bv.toNat) * 2 ^ 8 := by omega
    rw [hfac, nat_or_mul_pow2_add _ (n2.bv.toNat * 2 ^ 4) 8 (by omega)]
  have hbor3 : (((t0.bv ||| t1.bv) ||| t2.bv) ||| n3.bv).toNat =
      n0.bv.toNat * 2 ^ 12 + n1.bv.toNat * 2 ^ 8 + n2.bv.toNat * 2 ^ 4 + n3.bv.toNat := by
    rw [BitVec.toNat_or, hbor2]
    have hfac : n0.bv.toNat * 2 ^ 12 + n1.bv.toNat * 2 ^ 8 + n2.bv.toNat * 2 ^ 4 =
        (n0.bv.toNat * 256 + n1.bv.toNat * 16 + n2.bv.toNat) * 2 ^ 4 := by omega
    rw [hfac, nat_or_mul_pow2_add _ n3.bv.toNat 4 (by omega)]
  have hrv : r.bv = (((t0.bv ||| t1.bv) ||| t2.bv) ||| n3.bv) := rfl
  have hval := i32_val_of_bv_toNat_lt r (by rw [hrv, hbor3]; omega)
  rw [hrv, hbor3] at hval
  exact ⟨r, rfl, by omega, by omega, by omega⟩

/-- Theorem 5: `pkt_line_classify_len` exactly partitions all 32-bit lengths into Flush/Delim/ResponseEnd/Data/Invalid. -/
lemma pkt_line_classify_len_spec (total : Std.I32) :
    ∃ cls : Std.I32, pkt_line_classify_len total = ok cls ∧
      ((cls.val = 0 ↔ total.val = 0) ∧
       (cls.val = 1 ↔ total.val = 1) ∧
       (cls.val = 2 ↔ total.val = 2) ∧
       (cls.val = 3 ↔ 4 ≤ total.val ∧ total.val ≤ 65520) ∧
       (cls.val = -1 ↔ total.val < 0 ∨ total.val = 3 ∨ total.val > 65520)) := by
  unfold pkt_line_classify_len
  have c3 : (3#i32 : Std.I32).val = 3 := rfl
  have cm1 : ((-1)#i32 : Std.I32).val = -1 := rfl
  refine ⟨_, rfl, ?_⟩
  split_ifs with h0 h1 h2 h3
  · subst h0
    refine ⟨by simp, by decide, by decide, by decide, by decide⟩
  · subst h1
    refine ⟨by decide, by simp, by decide, by decide, by decide⟩
  · subst h2
    refine ⟨by decide, by decide, by simp, by decide, by decide⟩
  · simp only [Bool.and_eq_true, decide_eq_true_eq] at h3
    have ha : (4 : Int) ≤ total.val := h3.1
    have hb : total.val ≤ (65520 : Int) := h3.2
    refine ⟨⟨fun h => by omega, fun h => by omega⟩,
            ⟨fun h => by omega, fun h => by omega⟩,
            ⟨fun h => by omega, fun h => by omega⟩,
            ⟨fun _ => ⟨ha, hb⟩, fun _ => c3⟩,
            ⟨fun h => by omega, fun h => by omega⟩⟩
  · simp only [Bool.and_eq_true, decide_eq_true_eq, not_and] at h3
    have hne0 : total.val ≠ 0 := fun h => h0 (IScalar.eq_of_val_eq h)
    have hne1 : total.val ≠ 1 := fun h => h1 (IScalar.eq_of_val_eq h)
    have hne2 : total.val ≠ 2 := fun h => h2 (IScalar.eq_of_val_eq h)
    have hnot : ¬((4 : Int) ≤ total.val ∧ total.val ≤ 65520) := fun ⟨a, b⟩ => h3 a b
    refine ⟨⟨fun h => by omega, fun h => by omega⟩,
            ⟨fun h => by omega, fun h => by omega⟩,
            ⟨fun h => by omega, fun h => by omega⟩,
            ⟨fun h => by omega, fun h => by exfalso; exact hnot h⟩,
            ⟨fun _ => by omega, fun _ => cm1⟩⟩

/-- Theorem 6: End-to-end pkt-line length encode/decode roundtrip for all valid payload sizes `[0, 65516]`. -/
theorem pkt_line_encode_decode_roundtrip (plen : Int) (hplen : 0 ≤ plen ∧ plen ≤ 65516) :
    let total := plen + 4
    let n0 : Std.I32 := ⟨BitVec.ofInt 32 (total / 4096)⟩
    let n1 : Std.I32 := ⟨BitVec.ofInt 32 ((total / 256) % 16)⟩
    let n2 : Std.I32 := ⟨BitVec.ofInt 32 ((total / 16) % 16)⟩
    let n3 : Std.I32 := ⟨BitVec.ofInt 32 (total % 16)⟩
    ∃ r cls : Std.I32,
      pkt_line_decode_len n0 n1 n2 n3 = ok r ∧
      r.val = total ∧
      pkt_line_classify_len r = ok cls ∧
      cls.val = 3 := by
  intro total n0 n1 n2 n3
  have hn0 : n0.val = total / 4096 := by
    change (BitVec.ofInt 32 (total / 4096)).toInt = total / 4096
    rw [BitVec.toInt_ofInt]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  have hn1 : n1.val = (total / 256) % 16 := by
    change (BitVec.ofInt 32 ((total / 256) % 16)).toInt = (total / 256) % 16
    rw [BitVec.toInt_ofInt]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  have hn2 : n2.val = (total / 16) % 16 := by
    change (BitVec.ofInt 32 ((total / 16) % 16)).toInt = (total / 16) % 16
    rw [BitVec.toInt_ofInt]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  have hn3 : n3.val = total % 16 := by
    change (BitVec.ofInt 32 (total % 16)).toInt = total % 16
    rw [BitVec.toInt_ofInt]
    exact Int.bmod_eq_of_le (by omega) (by omega)
  obtain ⟨r, hr, hrv, _, _⟩ := pkt_line_decode_len_exact n0 n1 n2 n3
    (by omega) (by omega) (by omega) (by omega)
  have hrtot : r.val = total := by omega
  obtain ⟨cls, hcls, _, _, _, h3, _⟩ := pkt_line_classify_len_spec r
  exact ⟨r, cls, hr, hrtot, hcls, h3.mpr (by omega)⟩

end GitProofs
