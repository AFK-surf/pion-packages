import Aeneas
import PionLean
import Git.Types
import Git.Funs

open Aeneas Aeneas.Std Result Pion git

namespace GitProofs

private lemma result_bind_ok' {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private lemma i32_bv_toNat_of_nonneg' (x : Std.I32) (h0 : 0 ≤ x.val) :
    (x.bv.toNat : Int) = x.val := by
  have h := x.bv.toInt_eq_toNat_cond
  change 0 ≤ x.bv.toInt at h0
  split_ifs at h with hcond
  · exact h.symm
  · have := x.bv.isLt; omega

private lemma i32_val_of_bv_toNat_lt' (x : Std.I32) (hlt : x.bv.toNat < 2 ^ 31) :
    x.val = (x.bv.toNat : Int) := by
  have h := x.bv.toInt_eq_toNat_cond
  have h2 : 2 * x.bv.toNat < 2 ^ 32 := by omega
  simp only [h2, ↓reduceIte] at h
  exact h

private lemma i32_add_val' (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  change -2147483648 ≤ a.bv.toInt + b.bv.toInt at hlo
  change a.bv.toInt + b.bv.toInt ≤ 2147483647 at hhi
  change (a.bv + b.bv).toInt = a.bv.toInt + b.bv.toInt
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma i32_sub_val' (a b : Std.I32)
    (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  change -2147483648 ≤ a.bv.toInt - b.bv.toInt at hlo
  change a.bv.toInt - b.bv.toInt ≤ 2147483647 at hhi
  change (a.bv - b.bv).toInt = a.bv.toInt - b.bv.toInt
  rw [BitVec.toInt_sub]
  exact Int.bmod_eq_of_le (by omega) (by omega)

private lemma nat_and_7 (n : Nat) : n &&& 7 = n % 8 := by
  have h : (7 : Nat) = 2 ^ 3 - 1 := rfl
  rw [h, Nat.and_two_pow_sub_one_eq_mod]

private lemma nat_and_neg8_u32 (n : Nat) (hn : n < 2 ^ 31) :
    n &&& (BitVec.ofInt 32 (-8)).toNat = (n / 8) * 8 := by
  have hm : (BitVec.ofInt 32 (-8)).toNat = (2 ^ 29 - 1) <<< 3 := by decide
  rw [hm]
  apply Nat.eq_of_testBit_eq
  intro i
  rw [Nat.testBit_and, Nat.testBit_shiftLeft]
  by_cases hi3 : i < 3
  · have hnot : ¬ (3 ≤ i) := by omega
    have hrhs : ((n / 8) * 8).testBit i = false := by
      have : (n / 8) * 8 = (n / 8) <<< 3 := by rw [Nat.shiftLeft_eq]
      rw [this, Nat.testBit_shiftLeft]
      simp [hnot]
    simp [hnot, hrhs]
  · by_cases hi31 : i < 31
    · have hge : 3 ≤ i := by omega
      have hmask : (2 ^ 29 - 1).testBit (i - 3) = true := by
        rw [Nat.testBit_two_pow_sub_one]
        exact decide_eq_true (by omega)
      have hrhs : ((n / 8) * 8).testBit i = n.testBit i := by
        have h1 : (n / 8) * 8 = (n >>> 3) <<< 3 := by
          rw [Nat.shiftLeft_eq, Nat.shiftRight_eq_div_pow]
        rw [h1, Nat.testBit_shiftLeft]
        simp only [hge, decide_true, Bool.true_and, Nat.testBit_shiftRight]
        congr 1; omega
      simp only [hge, decide_true, hmask, Bool.and_true, hrhs]
    · have hlhs : n.testBit i = false := by
        apply Nat.testBit_lt_two_pow
        have hle : 2 ^ 31 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
        omega
      have hrhs : ((n / 8) * 8).testBit i = false := by
        apply Nat.testBit_lt_two_pow
        have hle : 2 ^ 31 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
        omega
      simp [hlhs, hrhs]

/-- Theorem 17: `index_v2_padded_len` aligns `raw_len` up to the next multiple of 8. -/
theorem index_v2_padded_len_spec (raw_len : Std.I32)
    (hlo : 0 ≤ raw_len.val) (hhi : raw_len.val ≤ 1000000000) :
    ∃ p : Std.I32, index_v2_padded_len raw_len = ok p ∧
      raw_len.val ≤ p.val ∧ p.val < raw_len.val + 8 ∧ p.val % 8 = 0 := by
  unfold index_v2_padded_len
  have c7 : (7#i32 : Std.I32).val = 7 := rfl
  set s := Pion.I32.add raw_len 7#i32
  have hsval : s.val = raw_len.val + 7 := by
    have h := i32_add_val' raw_len 7#i32 (by omega) (by omega)
    change s.val = raw_len.val + (7#i32 : Std.I32).val at h
    omega
  have hsnat : (s.bv.toNat : Int) = raw_len.val + 7 := by
    rw [i32_bv_toNat_of_nonneg' s (by omega), hsval]
  set p := Pion.I32.band s (-8)#i32
  have hpnat : p.bv.toNat = (s.bv.toNat / 8) * 8 := by
    change (s.bv &&& BitVec.ofInt 32 (-8)).toNat = (s.bv.toNat / 8) * 8
    rw [BitVec.toNat_and]
    exact nat_and_neg8_u32 s.bv.toNat (by omega)
  have hpval : p.val = (p.bv.toNat : Int) := by
    apply i32_val_of_bv_toNat_lt' p
    rw [hpnat]; omega
  refine ⟨p, rfl, ?_, ?_, ?_⟩ <;> omega

/-- Theorem 18: `index_v2_pad_bytes` returns `pad ∈ [0, 7]` such that `(raw_len + pad) % 8 = 0`. -/
theorem index_v2_pad_bytes_spec (raw_len : Std.I32)
    (hlo : 0 ≤ raw_len.val) :
    ∃ pad : Std.I32, index_v2_pad_bytes raw_len = ok pad ∧
      0 ≤ pad.val ∧ pad.val ≤ 7 ∧ (raw_len.val + pad.val) % 8 = 0 := by
  unfold index_v2_pad_bytes
  have c0 : (0#i32 : Std.I32).val = 0 := rfl
  have c8 : (8#i32 : Std.I32).val = 8 := rfl
  have hrnat : (raw_len.bv.toNat : Int) = raw_len.val := i32_bv_toNat_of_nonneg' raw_len hlo
  set rem := Pion.I32.band raw_len 7#i32
  have hremnat : rem.bv.toNat = raw_len.bv.toNat % 8 := by
    change (raw_len.bv &&& (7#32 : BitVec 32)).toNat = raw_len.bv.toNat % 8
    rw [BitVec.toNat_and]
    exact nat_and_7 raw_len.bv.toNat
  have hremval : rem.val = raw_len.val % 8 := by
    have hv := i32_val_of_bv_toNat_lt' rem (by rw [hremnat]; omega)
    rw [hv, hremnat]; omega
  refine ⟨_, rfl, ?_, ?_, ?_⟩
  · split_ifs with h0
    · omega
    · have hne : rem.val ≠ 0 := fun h => h0 (IScalar.eq_of_val_eq h)
      have hsub := i32_sub_val' 8#i32 rem (by omega) (by omega)
      omega
  · split_ifs with h0
    · omega
    · have hne : rem.val ≠ 0 := fun h => h0 (IScalar.eq_of_val_eq h)
      have hsub := i32_sub_val' 8#i32 rem (by omega) (by omega)
      omega
  · split_ifs with h0
    · have heq : rem.val = 0 := congrArg IScalar.val h0
      omega
    · have hne : rem.val ≠ 0 := fun h => h0 (IScalar.eq_of_val_eq h)
      have hsub := i32_sub_val' 8#i32 rem (by omega) (by omega)
      omega

/-- Theorem 19: Encoder-decoder alignment equivalence for `.git/index` v2/v3:
    `raw_len + index_v2_pad_bytes(raw_len) = index_v2_padded_len(raw_len)`. -/
theorem index_v2_encode_decode_alignment_eq (raw_len : Std.I32)
    (hlo : 0 ≤ raw_len.val) (hhi : raw_len.val ≤ 1000000000) :
    ∃ pad padded : Std.I32,
      index_v2_pad_bytes raw_len = ok pad ∧
      index_v2_padded_len raw_len = ok padded ∧
      raw_len.val + pad.val = padded.val := by
  obtain ⟨pad, hpad, hpad0, hpad7, hpadmod⟩ := index_v2_pad_bytes_spec raw_len hlo
  obtain ⟨padded, hpadded, hp1, hp2, hpmod⟩ := index_v2_padded_len_spec raw_len hlo hhi
  exact ⟨pad, padded, hpad, hpadded, by omega⟩

/-- Theorem 20: `delta_copy_size_encode` and `delta_copy_size_decode` form an exact roundtrip on `[1, 65536]`. -/
theorem delta_copy_size_roundtrip (chunk : Std.I32)
    (hlo : 1 ≤ chunk.val) (hhi : chunk.val ≤ 65536) :
    (do let enc ← delta_copy_size_encode chunk; delta_copy_size_decode enc) = ok chunk := by
  unfold delta_copy_size_encode delta_copy_size_decode
  simp only [result_bind_ok']
  split_ifs with h1 h2 h3
  · rw [h1]
  · exfalso; exact h2 rfl
  · exfalso
    have h0 : chunk.val = 0 := congrArg IScalar.val h3
    omega
  · rfl

/-- Theorem 22: `delta_copy_range_ok` guarantees overflow-free base read and target write bounds. -/
theorem delta_copy_range_ok_sound (cp_off cp_size base_size out_pos target_size : Std.I32)
    (hok : delta_copy_range_ok cp_off cp_size base_size out_pos target_size = ok true) :
    0 ≤ cp_off.val ∧ 0 ≤ cp_size.val ∧ 0 ≤ out_pos.val ∧
    cp_off.val + cp_size.val ≤ base_size.val ∧
    out_pos.val + cp_size.val ≤ target_size.val := by
  unfold delta_copy_range_ok at hok
  simp only [ok.injEq, Bool.and_eq_true, decide_eq_true_eq] at hok
  rcases hok with ⟨⟨⟨⟨⟨⟨⟨⟨h1, h2⟩, h3⟩, h4⟩, h5⟩, h6⟩, h7⟩, h8⟩, h9⟩
  have hb1 : (0 : Int) ≤ cp_off.val := h1
  have hb2 : (0 : Int) ≤ cp_size.val := h2
  have hb3 : (0 : Int) ≤ base_size.val := h3
  have hb4 : (0 : Int) ≤ out_pos.val := h4
  have hb5 : (0 : Int) ≤ target_size.val := h5
  have hb6 : out_pos.val ≤ target_size.val := h6
  have hb7 : cp_size.val ≤ base_size.val := h7
  have hbase_max : base_size.val ≤ 2147483647 := by
    have h := base_size.hBounds
    simp [IScalarTy.numBits] at h
    omega
  have htgt_max : target_size.val ≤ 2147483647 := by
    have h := target_size.hBounds
    simp [IScalarTy.numBits] at h
    omega
  have hsub1 : (Pion.I32.sub base_size cp_size).val = base_size.val - cp_size.val :=
    i32_sub_val' base_size cp_size (by omega) (by omega)
  have hsub2 : (Pion.I32.sub target_size out_pos).val = target_size.val - out_pos.val :=
    i32_sub_val' target_size out_pos (by omega) (by omega)
  have hb8 : cp_off.val ≤ (Pion.I32.sub base_size cp_size).val := h8
  have hb9 : cp_size.val ≤ (Pion.I32.sub target_size out_pos).val := h9
  omega

end GitProofs
