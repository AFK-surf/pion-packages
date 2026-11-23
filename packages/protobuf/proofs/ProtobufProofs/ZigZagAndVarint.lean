import Aeneas
import PionLean
import Protobuf.Types
import Protobuf.Funs

open Aeneas Aeneas.Std Result Pion protobuf

namespace ProtobufProofs

private lemma result_bind_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private lemma iscalar_eq_of_bv_eq {ty : IScalarTy} {a b : IScalar ty} (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

private lemma uscalar_eq_of_bv_eq {ty : UScalarTy} {a b : UScalar ty} (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

private lemma bv64_getLsbD_64 (x : BitVec 64) : x.getLsbD 64 = false := by
  rw [BitVec.getLsbD]
  exact Nat.testBit_lt_two_pow x.isLt

private lemma bv64_neg_and1_getLsbD (u : BitVec 64) (i : Nat) (hi : i < 64) :
    (-(u &&& 1#64)).getLsbD i = u.getLsbD 0 := by
  have h1 : (u &&& 1#64) = if u.getLsbD 0 then 1#64 else 0#64 := by
    apply BitVec.eq_of_getLsbD_eq
    intro j hj
    rw [BitVec.getLsbD_and]
    by_cases hj0 : j = 0
    · subst hj0
      cases u.getLsbD 0 <;> simp
    · have h1j : (1#64 : BitVec 64).getLsbD j = false := by
        rw [BitVec.getLsbD_ofNat]
        simp only [hj, decide_true, Bool.true_and, Nat.testBit_eq_decide_div_mod_eq]
        have hdiv : 1 / 2 ^ j = 0 := Nat.div_eq_of_lt (by
          have : 2 ^ 1 ≤ 2 ^ j := Nat.pow_le_pow_right (by omega) (by omega)
          omega)
        simp [hdiv]
      rw [h1j, Bool.and_false]
      cases u.getLsbD 0 <;> simp [h1j]
  rw [h1]
  cases u.getLsbD 0
  · simp
  · simp only [↓reduceIte]
    have hneg1 : -(1#64 : BitVec 64) = BitVec.allOnes 64 := by decide
    rw [hneg1, BitVec.getLsbD_allOnes]
    simp [hi]

private lemma bv64_sshiftRight63_getLsbD (x : BitVec 64) (i : Nat) (hi : i < 64) :
    (x.sshiftRight 63).getLsbD i = x.msb := by
  rw [BitVec.getLsbD_sshiftRight]
  have hlt : ¬ (63 + i < 64) ∨ i = 0 := by omega
  rcases hlt with hge | hi0
  · simp [hi, hge]
  · subst hi0
    simp [BitVec.msb_eq_getLsbD_last]

private lemma bv64_zigzag_roundtrip (x : BitVec 64) :
    let e := (x <<< 1) ^^^ (x.sshiftRight 63)
    (e >>> 1) ^^^ (-(e &&& 1#64)) = x := by
  dsimp only
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  rw [BitVec.getLsbD_xor, BitVec.getLsbD_ushiftRight, bv64_neg_and1_getLsbD _ i hi]
  have he0 : (((x <<< 1) ^^^ (x.sshiftRight 63)).getLsbD 0) = x.msb := by
    rw [BitVec.getLsbD_xor, BitVec.getLsbD_shiftLeft, bv64_sshiftRight63_getLsbD x 0 (by omega)]
    simp
  rw [he0]
  by_cases h63 : i < 63
  · have hlt : 1 + i < 64 := by omega
    rw [BitVec.getLsbD_xor, BitVec.getLsbD_shiftLeft, bv64_sshiftRight63_getLsbD x (1 + i) hlt]
    have hnotlt : ¬ (1 + i < 1) := by omega
    have hsub : 1 + i - 1 = i := by omega
    simp only [hlt, hnotlt, hsub, decide_true, decide_false, Bool.not_false, Bool.true_and]
    cases x.getLsbD i <;> cases x.msb <;> rfl
  · have hi63 : i = 63 := by omega
    subst hi63
    have h64 : (1 + 63 : Nat) = 64 := rfl
    rw [h64, bv64_getLsbD_64, BitVec.msb_eq_getLsbD_last]
    cases x.getLsbD 63 <;> rfl

private lemma bv64_zigzag_decode_encode (u : BitVec 64) :
    let d := (u >>> 1) ^^^ (-(u &&& 1#64))
    (d <<< 1) ^^^ (d.sshiftRight 63) = u := by
  dsimp only
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  rw [BitVec.getLsbD_xor, BitVec.getLsbD_shiftLeft, bv64_sshiftRight63_getLsbD _ i hi]
  have hmsb : ((u >>> 1) ^^^ (-(u &&& 1#64))).msb = u.getLsbD 0 := by
    rw [BitVec.msb_eq_getLsbD_last]
    change ((u >>> 1) ^^^ (-(u &&& 1#64))).getLsbD 63 = u.getLsbD 0
    rw [BitVec.getLsbD_xor, BitVec.getLsbD_ushiftRight, bv64_neg_and1_getLsbD u 63 (by omega)]
    have h64 : (1 + 63 : Nat) = 64 := rfl
    rw [h64, bv64_getLsbD_64]
    simp
  rw [hmsb]
  by_cases hi0 : i = 0
  · subst hi0
    simp
  · have hnotlt : ¬ (i < 1) := by omega
    have hlt1 : i - 1 < 64 := by omega
    simp only [hi, hnotlt, decide_true, decide_false, Bool.not_false, Bool.true_and]
    rw [BitVec.getLsbD_xor, BitVec.getLsbD_ushiftRight, bv64_neg_and1_getLsbD u (i - 1) hlt1]
    have hre : 1 + (i - 1) = i := by omega
    rw [hre]
    cases u.getLsbD i <;> cases u.getLsbD 0 <;> rfl

private lemma i64_shl_i32_ok (x : Std.I64) (k : Std.I32) (h0 : 0 ≤ k.val) (h64 : k.val < 64) :
    Pion.I64.shl_i32 x k = ok ⟨x.bv <<< k.val.toNat⟩ := by
  unfold Pion.I64.shl_i32
  simp only [h0, h64, and_self, ↓reduceIte]

private lemma i64_shr_i32_ok (x : Std.I64) (k : Std.I32) (h0 : 0 ≤ k.val) (h64 : k.val < 64) :
    Pion.I64.shr_i32 x k = ok ⟨x.bv.sshiftRight k.val.toNat⟩ := by
  unfold Pion.I64.shr_i32
  simp only [h0, h64, and_self, ↓reduceIte]

private lemma u64_shr_ok (x : Std.U64) (k : Std.U64) (h64 : k.val < 64) :
    Pion.U64.shr x k = ok ⟨x.bv >>> k.val⟩ := by
  unfold Pion.U64.shr
  simp only [h64, ↓reduceIte]

private lemma i64_to_u64_bv (x : Std.I64) : (Pion.I64.to_uint64 x).bv = x.bv := by
  unfold Pion.I64.to_uint64 IScalar.hcast
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  change (BitVec.signExtend 64 x.bv).getLsbD i = x.bv.getLsbD i
  rw [BitVec.getLsbD_signExtend]
  have h64 : i < 64 := hi
  simp [h64]

private lemma u64_to_i64_bv (x : Std.U64) : (Pion.U64.to_int64 x).bv = x.bv := by
  unfold Pion.U64.to_int64 UScalar.hcast
  exact BitVec.setWidth_eq x.bv

private lemma zigzag_encode_i64_bv (n : Std.I64) :
    zigzag_encode_i64 n = ok ⟨(n.bv <<< 1) ^^^ (n.bv.sshiftRight 63)⟩ := by
  unfold zigzag_encode_i64
  rw [i64_shl_i32_ok n 1#i32 (by decide) (by decide), result_bind_ok]
  rw [i64_shr_i32_ok n 63#i32 (by decide) (by decide), result_bind_ok]
  apply congrArg ok
  apply uscalar_eq_of_bv_eq
  trans (Pion.I64.bxor ⟨n.bv <<< (1#i32 : Std.I32).val.toNat⟩ ⟨n.bv.sshiftRight (63#i32 : Std.I32).val.toNat⟩).bv
  · exact i64_to_u64_bv _
  · rfl

private lemma zigzag_decode_i64_bv (u : Std.U64) :
    zigzag_decode_i64 u = ok ⟨(u.bv >>> 1) ^^^ (-(u.bv &&& 1#64))⟩ := by
  unfold zigzag_decode_i64
  rw [u64_shr_ok u 1#u64 (by decide), result_bind_ok]
  apply congrArg ok
  apply iscalar_eq_of_bv_eq
  simp only [Pion.I64.bxor, Pion.I64.neg, u64_to_i64_bv, Pion.U64.band]
  rfl

/-- Theorem 1: `zigzag_encode_i64` followed by `zigzag_decode_i64` is the exact identity on all `2^64` `Int64` values. -/
theorem zigzag_i64_roundtrip (n : Std.I64) :
    (do let u ← zigzag_encode_i64 n; zigzag_decode_i64 u) = ok n := by
  rw [zigzag_encode_i64_bv, result_bind_ok, zigzag_decode_i64_bv]
  congr 1
  apply iscalar_eq_of_bv_eq
  exact bv64_zigzag_roundtrip n.bv

/-- Theorem 2: `zigzag_decode_i64` followed by `zigzag_encode_i64` is the exact identity on all `2^64` `UInt64` values. -/
theorem zigzag_i64_decode_encode_roundtrip (u : Std.U64) :
    (do let n ← zigzag_decode_i64 u; zigzag_encode_i64 n) = ok u := by
  rw [zigzag_decode_i64_bv, result_bind_ok, zigzag_encode_i64_bv]
  congr 1
  apply uscalar_eq_of_bv_eq
  exact bv64_zigzag_decode_encode u.bv

/-- Theorem 3: `zigzag_encode_i64` is injective over all 64-bit signed integers. -/
theorem zigzag_i64_injective (a b : Std.I64)
    (h : zigzag_encode_i64 a = zigzag_encode_i64 b) : a = b := by
  have ha := zigzag_i64_roundtrip a
  have hb := zigzag_i64_roundtrip b
  rw [h] at ha
  rw [ha] at hb
  simp only [ok.injEq] at hb
  exact hb

/-- Theorem 4: Non-negative `Int64` values ZigZag-encode to even `UInt64` values `2 * n`. -/
theorem zigzag_i64_nonneg_even (n : Std.I64) (hn : 0 ≤ n.val) :
    ∃ u : Std.U64, zigzag_encode_i64 n = ok u ∧ u.val = 2 * n.val.toNat := by
  rw [zigzag_encode_i64_bv]
  refine ⟨⟨(n.bv <<< 1) ^^^ (n.bv.sshiftRight 63)⟩, rfl, ?_⟩
  have hcond : (n.bv.toNat : Int) = n.val ∧ 2 * n.bv.toNat < 2 ^ 64 := by
    have h := n.bv.toInt_eq_toNat_cond
    change 0 ≤ n.bv.toInt at hn
    split_ifs at h with hc
    · exact ⟨h.symm, hc⟩
    · have := n.bv.isLt; omega
  have hmsb : n.bv.msb = false := by
    rw [BitVec.msb_eq_decide]
    exact decide_eq_false (by omega)
  have hsr : n.bv.sshiftRight 63 = 0#64 := by
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    rw [bv64_sshiftRight63_getLsbD n.bv i hi, hmsb]
    simp
  change ((n.bv <<< 1) ^^^ (n.bv.sshiftRight 63)).toNat = 2 * n.val.toNat
  rw [hsr, BitVec.xor_zero, BitVec.toNat_shiftLeft, Nat.shiftLeft_eq]
  rw [Nat.mod_eq_of_lt (by omega)]
  omega

/-- Theorem 5: Negative `Int64` values ZigZag-encode to odd `UInt64` values `-2 * n - 1`. -/
theorem zigzag_i64_neg_odd (n : Std.I64) (hn : n.val < 0) :
    ∃ u : Std.U64, zigzag_encode_i64 n = ok u ∧ (u.val : Int) = -2 * n.val - 1 := by
  rw [zigzag_encode_i64_bv]
  refine ⟨⟨(n.bv <<< 1) ^^^ (n.bv.sshiftRight 63)⟩, rfl, ?_⟩
  have hcond : n.val = (n.bv.toNat : Int) - 2 ^ 64 ∧ 2 ^ 63 ≤ n.bv.toNat := by
    have h := n.bv.toInt_eq_toNat_cond
    change n.bv.toInt < 0 at hn
    split_ifs at h with hc
    · omega
    · exact ⟨h, by omega⟩
  have hmsb : n.bv.msb = true := by
    rw [BitVec.msb_eq_decide]
    exact decide_eq_true (by omega)
  have hsr : n.bv.sshiftRight 63 = BitVec.allOnes 64 := by
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    rw [bv64_sshiftRight63_getLsbD n.bv i hi, hmsb, BitVec.getLsbD_allOnes]
    simp [hi]
  change (((n.bv <<< 1) ^^^ (n.bv.sshiftRight 63)).toNat : Int) = -2 * n.val - 1
  rw [hsr, BitVec.xor_allOnes, BitVec.toNat_not, BitVec.toNat_shiftLeft, Nat.shiftLeft_eq]
  have hlt : n.bv.toNat < 2 ^ 64 := n.bv.isLt
  have hmod : (n.bv.toNat * 2 ^ 1) % 2 ^ 64 = n.bv.toNat * 2 - 2 ^ 64 := by
    have h1 : n.bv.toNat * 2 ^ 1 = (n.bv.toNat * 2 - 2 ^ 64) + 2 ^ 64 := by omega
    rw [h1, Nat.add_mod_right, Nat.mod_eq_of_lt (by omega)]
  rw [hmod]
  omega

private lemma bv64_sext32_getLsbD (x : BitVec 32) (i : Nat) (hi : i < 64) :
    ((x.signExtend 64 <<< 32).sshiftRight 32).getLsbD i =
      if i < 32 then x.getLsbD i else x.msb := by
  rw [BitVec.getLsbD_sshiftRight]
  have hnot64 : ¬ (64 ≤ i) := by omega
  by_cases hi32 : i < 32
  · have hlt : 32 + i < 64 := by omega
    simp only [hi32, hlt, ↓reduceIte]
    rw [BitVec.getLsbD_shiftLeft]
    have hnotlt : ¬ (32 + i < 32) := by omega
    have hsub : 32 + i - 32 = i := by omega
    simp only [hlt, hnotlt, hsub, decide_true, decide_false, Bool.not_false, Bool.true_and]
    rw [BitVec.getLsbD_signExtend]
    simp [hi, hi32]
  · have hge : ¬ (32 + i < 64) := by omega
    simp only [hi32, hge, hnot64, ↓reduceIte, decide_false, Bool.not_false, Bool.true_and]
    rw [BitVec.msb_eq_getLsbD_last, BitVec.getLsbD_shiftLeft]
    simp only [show (64 - 1 : Nat) < 64 by omega, show ¬ ((64 - 1 : Nat) < 32) by omega,
               decide_true, decide_false, Bool.not_false, Bool.true_and]
    rw [BitVec.getLsbD_signExtend]
    simp [BitVec.msb_eq_getLsbD_last]

private lemma bv64_mask32_getLsbD (x : BitVec 64) (i : Nat) (hi : i < 64) :
    (x &&& 4294967295#64).getLsbD i = if i < 32 then x.getLsbD i else false := by
  rw [BitVec.getLsbD_and]
  have hm : (4294967295#64 : BitVec 64).getLsbD i = decide (i < 32) := by
    have h4294 : (4294967295#64 : BitVec 64) = BitVec.ofNat 64 (2 ^ 32 - 1) := by decide
    rw [h4294, BitVec.getLsbD_ofNat]
    simp only [hi, decide_true, Bool.true_and]
    exact Nat.testBit_two_pow_sub_one 32 i
  rw [hm]
  by_cases h32 : i < 32 <;> simp [h32]

private lemma mask32_i64_bv : (4294967295#i64 : Std.I64).bv = 4294967295#64 := rfl

private lemma zigzag_encode_i32_bv (n : Std.I32) :
    let n32 := (n.bv.signExtend 64 <<< 32).sshiftRight 32
    zigzag_encode_i32 n = ok ⟨((n32 <<< 1) ^^^ (n32.sshiftRight 63)) &&& 4294967295#64⟩ := by
  unfold zigzag_encode_i32
  dsimp only
  rw [i64_shl_i32_ok _ 32#i32 (by decide) (by decide), result_bind_ok]
  rw [i64_shr_i32_ok _ 32#i32 (by decide) (by decide), result_bind_ok]
  rw [i64_shl_i32_ok _ 1#i32 (by decide) (by decide), result_bind_ok]
  rw [i64_shr_i32_ok _ 63#i32 (by decide) (by decide), result_bind_ok]
  congr 1

private lemma zigzag_decode_i32_bv (u : Std.I64) :
    let u32 := u.bv &&& 4294967295#64
    let v := (u32.sshiftRight 1) ^^^ (-(u32 &&& 1#64))
    zigzag_decode_i32 u = ok ⟨((v <<< 32).sshiftRight 32).signExtend 32⟩ := by
  unfold zigzag_decode_i32
  dsimp only
  rw [i64_shr_i32_ok _ 1#i32 (by decide) (by decide), result_bind_ok]
  rw [i64_shl_i32_ok _ 32#i32 (by decide) (by decide), result_bind_ok]
  rw [i64_shr_i32_ok _ 32#i32 (by decide) (by decide), result_bind_ok]
  congr 1

private lemma i64_band_u32_bounds (x : BitVec 64) :
    let r : Std.I64 := ⟨x &&& 4294967295#64⟩
    0 ≤ r.val ∧ r.val ≤ 4294967295 := by
  dsimp only
  have hm : (4294967295#64 : BitVec 64).toNat = 4294967295 := rfl
  have hnat : (x &&& 4294967295#64).toNat ≤ 4294967295 := by
    rw [BitVec.toNat_and, hm]
    exact Nat.and_le_right
  generalize hr : (⟨x &&& 4294967295#64⟩ : Std.I64) = r
  have hrbv : r.bv.toNat ≤ 4294967295 := by rw [← hr]; exact hnat
  have hval : r.val = (r.bv.toNat : Int) := by
    have h := r.bv.toInt_eq_toNat_cond
    split_ifs at h with hc
    · exact h
    · change ¬ 2 * r.bv.toNat < 2 ^ 64 at hc
      omega
  omega

/-- Theorem 6: `zigzag_encode_i32` always returns an unsigned 32-bit value in `[0, 2^32 - 1]`. -/
theorem zigzag_i32_bounds (n : Std.I32) :
    ∃ u : Std.I64, zigzag_encode_i32 n = ok u ∧ 0 ≤ u.val ∧ u.val ≤ 4294967295 := by
  rw [zigzag_encode_i32_bv]
  exact ⟨_, rfl, i64_band_u32_bounds _⟩

/-- Theorem 7: `zigzag_encode_i32` followed by `zigzag_decode_i32` is the exact identity on all `2^32` `Int32` values. -/
theorem zigzag_i32_roundtrip (n : Std.I32) :
    (do let u ← zigzag_encode_i32 n; zigzag_decode_i32 u) = ok n := by
  rw [zigzag_encode_i32_bv, result_bind_ok, zigzag_decode_i32_bv]
  apply congrArg ok
  apply iscalar_eq_of_bv_eq
  set n32 := (n.bv.signExtend 64 <<< 32).sshiftRight 32
  set e := ((n32 <<< 1) ^^^ (n32.sshiftRight 63)) &&& 4294967295#64
  set u32 := e &&& 4294967295#64
  set v := (u32.sshiftRight 1) ^^^ (-(u32 &&& 1#64))
  have hn32_msb : n32.msb = n.bv.msb := by
    rw [BitVec.msb_eq_getLsbD_last]
    change n32.getLsbD 63 = n.bv.msb
    rw [bv64_sext32_getLsbD n.bv 63 (by omega)]
    simp
  have hu32 : ∀ j, j < 64 → u32.getLsbD j = if j < 32 then (if j = 0 then n.bv.msb else xor (n.bv.getLsbD (j - 1)) n.bv.msb) else false := by
    intro j hj
    dsimp only [u32, e]
    rw [bv64_mask32_getLsbD _ j hj, bv64_mask32_getLsbD _ j hj]
    by_cases hj32 : j < 32
    · simp only [hj32, ↓reduceIte]
      rw [BitVec.getLsbD_xor, BitVec.getLsbD_shiftLeft, bv64_sshiftRight63_getLsbD n32 j hj, hn32_msb]
      by_cases hj0 : j = 0
      · subst hj0; simp
      · have hnotlt : ¬ (j < 1) := by omega
        have hj1 : j - 1 < 32 := by omega
        simp only [hj, hnotlt, hj0, decide_true, decide_false, Bool.not_false, Bool.true_and, ↓reduceIte]
        rw [bv64_sext32_getLsbD n.bv (j - 1) (by omega)]
        simp [hj1]
    · simp [hj32]
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  have hi32 : i < 32 := hi
  have h64 : i < 64 := by omega
  change (BitVec.signExtend 32 ((v <<< 32).sshiftRight 32)).getLsbD i = n.bv.getLsbD i
  rw [BitVec.getLsbD_signExtend]
  simp only [hi32, h64, ↓reduceIte, decide_true, Bool.true_and]
  rw [BitVec.getLsbD_sshiftRight]
  have hlt : 32 + i < 64 := by omega
  simp only [hlt, ↓reduceIte]
  rw [BitVec.getLsbD_shiftLeft]
  have hnotlt32 : ¬ (32 + i < 32) := by omega
  have hsub32 : 32 + i - 32 = i := by omega
  simp only [hlt, hnotlt32, hsub32, decide_true, decide_false, Bool.not_false, Bool.true_and]
  dsimp only [v]
  rw [BitVec.getLsbD_xor, BitVec.getLsbD_sshiftRight, bv64_neg_and1_getLsbD u32 i h64]
  have hu0 : u32.getLsbD 0 = n.bv.msb := by rw [hu32 0 (by omega)]; simp
  rw [hu0]
  have hi1 : 1 + i < 64 := by omega
  have hnot64 : ¬ (64 ≤ i) := by omega
  simp only [hi1, hnot64, ↓reduceIte, decide_false, Bool.not_false, Bool.true_and]
  rw [hu32 (1 + i) hi1]
  by_cases hi31 : i < 31
  · have hlt32 : 1 + i < 32 := by omega
    have hne0 : 1 + i ≠ 0 := by omega
    have hsub1 : 1 + i - 1 = i := by omega
    simp only [hlt32, hne0, hsub1, ↓reduceIte]
    cases n.bv.getLsbD i <;> cases n.bv.msb <;> rfl
  · have hi31eq : i = 31 := by omega
    subst hi31eq
    simp only [show ¬ (1 + 31 < 32) by omega, ↓reduceIte]
    rw [BitVec.msb_eq_getLsbD_last]
    cases n.bv.getLsbD 31 <;> rfl

/-- Theorem 8: `zigzag_decode_i32` followed by `zigzag_encode_i32` is the exact identity on `[0, 2^32 - 1]`. -/
theorem zigzag_i32_decode_encode_roundtrip (u : Std.I64)
    (hlo : 0 ≤ u.val) (hhi : u.val ≤ 4294967295) :
    (do let n ← zigzag_decode_i32 u; zigzag_encode_i32 n) = ok u := by
  rw [zigzag_decode_i32_bv, result_bind_ok, zigzag_encode_i32_bv]
  congr 1
  apply iscalar_eq_of_bv_eq
  have hu_hi : ∀ j, j < 64 → ¬ (j < 32) → u.bv.getLsbD j = false := by
    intro j hj hge
    have hnat : (u.bv.toNat : Int) = u.val := by
      have h := u.bv.toInt_eq_toNat_cond
      change 0 ≤ u.bv.toInt at hlo
      split_ifs at h with hc
      · exact h.symm
      · have := u.bv.isLt; omega
    rw [BitVec.getLsbD]
    apply Nat.testBit_lt_two_pow
    have hle : 2 ^ 32 ≤ 2 ^ j := Nat.pow_le_pow_right (by omega) (by omega)
    omega
  have hu32_eq : u.bv &&& 4294967295#64 = u.bv := by
    apply BitVec.eq_of_getLsbD_eq
    intro j hj
    rw [bv64_mask32_getLsbD u.bv j hj]
    by_cases h32 : j < 32
    · simp [h32]
    · simp [h32, hu_hi j hj h32]
  set u32 := u.bv &&& 4294967295#64
  set v := (u32.sshiftRight 1) ^^^ (-(u32 &&& 1#64))
  set d := ((v <<< 32).sshiftRight 32).signExtend 32
  set n32 := (d.signExtend 64 <<< 32).sshiftRight 32
  have hd_bit : ∀ j, j < 32 → d.getLsbD j = xor (u.bv.getLsbD (1 + j)) (u.bv.getLsbD 0) := by
    intro j hj
    dsimp only [d]
    have hj64 : j < 64 := by omega
    rw [BitVec.getLsbD_signExtend]
    simp only [hj, hj64, ↓reduceIte, decide_true, Bool.true_and]
    rw [BitVec.getLsbD_sshiftRight]
    have h32j : 32 + j < 64 := by omega
    simp only [h32j, ↓reduceIte]
    rw [BitVec.getLsbD_shiftLeft]
    simp only [h32j, show ¬ (32 + j < 32) by omega, show 32 + j - 32 = j by omega,
               decide_true, decide_false, Bool.not_false, Bool.true_and]
    dsimp only [v]
    rw [hu32_eq, BitVec.getLsbD_xor, BitVec.getLsbD_sshiftRight, bv64_neg_and1_getLsbD u.bv j hj64]
    have h1j : 1 + j < 64 := by omega
    have hnot64 : ¬ (64 ≤ j) := by omega
    simp only [h1j, hnot64, ↓reduceIte, decide_false, Bool.not_false, Bool.true_and]
  have hd_msb : d.msb = u.bv.getLsbD 0 := by
    rw [BitVec.msb_eq_getLsbD_last]
    change d.getLsbD 31 = u.bv.getLsbD 0
    rw [hd_bit 31 (by omega), hu_hi (1 + 31) (by omega) (by omega)]
    simp
  have hn32_msb : n32.msb = u.bv.getLsbD 0 := by
    rw [BitVec.msb_eq_getLsbD_last]
    change n32.getLsbD 63 = u.bv.getLsbD 0
    rw [bv64_sext32_getLsbD d 63 (by omega)]
    simp [hd_msb]
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  have hi64 : i < 64 := hi
  rw [bv64_mask32_getLsbD _ i hi64]
  by_cases hi32 : i < 32
  · simp only [hi32, ↓reduceIte]
    rw [BitVec.getLsbD_xor, BitVec.getLsbD_shiftLeft, bv64_sshiftRight63_getLsbD n32 i hi64, hn32_msb]
    by_cases hi0 : i = 0
    · subst hi0; simp
    · have hnotlt : ¬ (i < 1) := by omega
      have hi1 : i - 1 < 32 := by omega
      simp only [hi64, hnotlt, decide_true, decide_false, Bool.not_false, Bool.true_and]
      rw [bv64_sext32_getLsbD d (i - 1) (by omega)]
      simp only [hi1, ↓reduceIte]
      rw [hd_bit (i - 1) hi1]
      have hre : 1 + (i - 1) = i := by omega
      rw [hre]
      cases u.bv.getLsbD i <;> cases u.bv.getLsbD 0 <;> rfl
  · simp only [hi32, ↓reduceIte]
    exact (hu_hi i hi64 hi32).symm

/-- Theorem 9: `zigzag_encode_i32` is injective over all 32-bit signed integers. -/
theorem zigzag_i32_injective (a b : Std.I32)
    (h : zigzag_encode_i32 a = zigzag_encode_i32 b) : a = b := by
  have ha := zigzag_i32_roundtrip a
  have hb := zigzag_i32_roundtrip b
  rw [h] at ha
  rw [ha] at hb
  simp only [ok.injEq] at hb
  exact hb

/-- Theorem 10: `varint_len_u64` always succeeds and returns a byte count in `[1, 10]`. -/
theorem varint_len_u64_bounds (v : Std.U64) :
    ∃ n : Std.I32, varint_len_u64 v = ok n ∧ 1 ≤ n.val ∧ n.val ≤ 10 := by
  unfold varint_len_u64
  refine ⟨_, rfl, ?_⟩
  split_ifs <;> decide

/-- Theorem 11: `varint_len_u64` exactly partitions `UInt64` into the 10 Protobuf base-128 byte-length tiers. -/
theorem varint_len_u64_exact_tiers (v : Std.U64) :
    ∃ n : Std.I32, varint_len_u64 v = ok n ∧
      ((n.val = 1 ↔ v.val < 128) ∧
       (n.val = 2 ↔ 128 ≤ v.val ∧ v.val < 16384) ∧
       (n.val = 3 ↔ 16384 ≤ v.val ∧ v.val < 2097152) ∧
       (n.val = 4 ↔ 2097152 ≤ v.val ∧ v.val < 268435456) ∧
       (n.val = 5 ↔ 268435456 ≤ v.val ∧ v.val < 34359738368) ∧
       (n.val = 6 ↔ 34359738368 ≤ v.val ∧ v.val < 4398046511104) ∧
       (n.val = 7 ↔ 4398046511104 ≤ v.val ∧ v.val < 562949953421312) ∧
       (n.val = 8 ↔ 562949953421312 ≤ v.val ∧ v.val < 72057594037927936) ∧
       (n.val = 9 ↔ 72057594037927936 ≤ v.val ∧ v.val < 9223372036854775808) ∧
       (n.val = 10 ↔ 9223372036854775808 ≤ v.val)) := by
  unfold varint_len_u64
  have c1 : (1#i32 : Std.I32).val = 1 := rfl
  have c2 : (2#i32 : Std.I32).val = 2 := rfl
  have c3 : (3#i32 : Std.I32).val = 3 := rfl
  have c4 : (4#i32 : Std.I32).val = 4 := rfl
  have c5 : (5#i32 : Std.I32).val = 5 := rfl
  have c6 : (6#i32 : Std.I32).val = 6 := rfl
  have c7 : (7#i32 : Std.I32).val = 7 := rfl
  have c8 : (8#i32 : Std.I32).val = 8 := rfl
  have c9 : (9#i32 : Std.I32).val = 9 := rfl
  have c10 : (10#i32 : Std.I32).val = 10 := rfl
  refine ⟨_, rfl, ?_⟩
  by_cases h1 : v < 128#u64
  · simp only [h1, ↓reduceIte]; have : v.val < 128 := h1; exact by omega
  simp only [h1, ↓reduceIte]; have h1' : ¬ (v.val < 128) := h1
  by_cases h2 : v < 16384#u64
  · simp only [h2, ↓reduceIte]; have : v.val < 16384 := h2; exact by omega
  simp only [h2, ↓reduceIte]; have h2' : ¬ (v.val < 16384) := h2
  by_cases h3 : v < 2097152#u64
  · simp only [h3, ↓reduceIte]; have : v.val < 2097152 := h3; exact by omega
  simp only [h3, ↓reduceIte]; have h3' : ¬ (v.val < 2097152) := h3
  by_cases h4 : v < 268435456#u64
  · simp only [h4, ↓reduceIte]; have : v.val < 268435456 := h4; exact by omega
  simp only [h4, ↓reduceIte]; have h4' : ¬ (v.val < 268435456) := h4
  by_cases h5 : v < 34359738368#u64
  · simp only [h5, ↓reduceIte]; have : v.val < 34359738368 := h5; exact by omega
  simp only [h5, ↓reduceIte]; have h5' : ¬ (v.val < 34359738368) := h5
  by_cases h6 : v < 4398046511104#u64
  · simp only [h6, ↓reduceIte]; have : v.val < 4398046511104 := h6; exact by omega
  simp only [h6, ↓reduceIte]; have h6' : ¬ (v.val < 4398046511104) := h6
  by_cases h7 : v < 562949953421312#u64
  · simp only [h7, ↓reduceIte]; have : v.val < 562949953421312 := h7; exact by omega
  simp only [h7, ↓reduceIte]; have h7' : ¬ (v.val < 562949953421312) := h7
  by_cases h8 : v < 72057594037927936#u64
  · simp only [h8, ↓reduceIte]; have : v.val < 72057594037927936 := h8; exact by omega
  simp only [h8, ↓reduceIte]; have h8' : ¬ (v.val < 72057594037927936) := h8
  by_cases h9 : v < 9223372036854775808#u64
  · simp only [h9, ↓reduceIte]; have : v.val < 9223372036854775808 := h9; exact by omega
  simp only [h9, ↓reduceIte]; have h9' : ¬ (v.val < 9223372036854775808) := h9
  exact by omega

/-- Theorem 12: `varint_len_u64` is monotonic over all `UInt64` values. -/
theorem varint_len_u64_mono (a b : Std.U64) (hab : a.val ≤ b.val) :
    ∃ na nb : Std.I32, varint_len_u64 a = ok na ∧ varint_len_u64 b = ok nb ∧ na.val ≤ nb.val := by
  unfold varint_len_u64
  refine ⟨_, _, rfl, rfl, ?_⟩
  have hle : ∀ (t : Std.U64), b < t → a < t := fun t hb => by
    change a.val < t.val; change b.val < t.val at hb; omega
  by_cases ha1 : a < 128#u64
  · simp only [ha1, ↓reduceIte]; split_ifs <;> decide
  simp only [ha1, ↓reduceIte]
  have hb1 : ¬ (b < 128#u64) := fun h => ha1 (hle _ h)
  simp only [hb1, ↓reduceIte]
  by_cases ha2 : a < 16384#u64
  · simp only [ha2, ↓reduceIte]; split_ifs <;> decide
  simp only [ha2, ↓reduceIte]
  have hb2 : ¬ (b < 16384#u64) := fun h => ha2 (hle _ h)
  simp only [hb2, ↓reduceIte]
  by_cases ha3 : a < 2097152#u64
  · simp only [ha3, ↓reduceIte]; split_ifs <;> decide
  simp only [ha3, ↓reduceIte]
  have hb3 : ¬ (b < 2097152#u64) := fun h => ha3 (hle _ h)
  simp only [hb3, ↓reduceIte]
  by_cases ha4 : a < 268435456#u64
  · simp only [ha4, ↓reduceIte]; split_ifs <;> decide
  simp only [ha4, ↓reduceIte]
  have hb4 : ¬ (b < 268435456#u64) := fun h => ha4 (hle _ h)
  simp only [hb4, ↓reduceIte]
  by_cases ha5 : a < 34359738368#u64
  · simp only [ha5, ↓reduceIte]; split_ifs <;> decide
  simp only [ha5, ↓reduceIte]
  have hb5 : ¬ (b < 34359738368#u64) := fun h => ha5 (hle _ h)
  simp only [hb5, ↓reduceIte]
  by_cases ha6 : a < 4398046511104#u64
  · simp only [ha6, ↓reduceIte]; split_ifs <;> decide
  simp only [ha6, ↓reduceIte]
  have hb6 : ¬ (b < 4398046511104#u64) := fun h => ha6 (hle _ h)
  simp only [hb6, ↓reduceIte]
  by_cases ha7 : a < 562949953421312#u64
  · simp only [ha7, ↓reduceIte]; split_ifs <;> decide
  simp only [ha7, ↓reduceIte]
  have hb7 : ¬ (b < 562949953421312#u64) := fun h => ha7 (hle _ h)
  simp only [hb7, ↓reduceIte]
  by_cases ha8 : a < 72057594037927936#u64
  · simp only [ha8, ↓reduceIte]; split_ifs <;> decide
  simp only [ha8, ↓reduceIte]
  have hb8 : ¬ (b < 72057594037927936#u64) := fun h => ha8 (hle _ h)
  simp only [hb8, ↓reduceIte]
  by_cases ha9 : a < 9223372036854775808#u64
  · simp only [ha9, ↓reduceIte]; split_ifs <;> decide
  simp only [ha9, ↓reduceIte]
  have hb9 : ¬ (b < 9223372036854775808#u64) := fun h => ha9 (hle _ h)
  simp only [hb9, ↓reduceIte]
  decide

end ProtobufProofs
