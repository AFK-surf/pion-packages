import DecimalProofs.Flags

open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 400000
set_option linter.unusedSimpArgs false

namespace DecimalProofs

open decimal

/-! ## 3. 16-Byte Binary Wire Format `serialize` ↔ `deserialize` & F-5 Mask `0x801F0000` -/

/-- Helper: extract byte `k` (0..3) of a `Std.U32` as `Std.U8`. -/
def u32_byte (x : Std.U32) (shift : Nat) : Std.U8 :=
  Pion.I32.to_byte (Pion.U32.to_int (Pion.U32.band ⟨x.bv >>> shift⟩ 255#u32))

lemma u32_byte_to_u32_bv (x : Std.U32) (shift : Nat) :
    (Pion.I32.to_uint (Pion.U8.to_int (u32_byte x shift))).bv =
      (x.bv >>> shift) &&& MASK_BYTE := by
  unfold u32_byte
  dsimp only [Pion.I32.to_uint, Pion.U8.to_int, Pion.I32.to_byte, Pion.U32.to_int,
    Pion.U32.band, IScalar.hcast, UScalar.hcast, UScalarTy.numBits, IScalarTy.numBits]
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [BitVec.getLsbD_setWidth, BitVec.getLsbD_signExtend, BitVec.getLsbD_and,
    hi, decide_true, Bool.true_and]
  have hcases :
      i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 ∨ i = 5 ∨ i = 6 ∨ i = 7 ∨
      i = 8 ∨ i = 9 ∨ i = 10 ∨ i = 11 ∨ i = 12 ∨ i = 13 ∨ i = 14 ∨ i = 15 ∨
      i = 16 ∨ i = 17 ∨ i = 18 ∨ i = 19 ∨ i = 20 ∨ i = 21 ∨ i = 22 ∨ i = 23 ∨
      i = 24 ∨ i = 25 ∨ i = 26 ∨ i = 27 ∨ i = 28 ∨ i = 29 ∨ i = 30 ∨ i = 31 := by omega
  rcases hcases with
    rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
    rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
    rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
    rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    simp [MASK_BYTE, BitVec.getElem_signExtend, BitVec.getElem_ushiftRight, BitVec.getLsbD_ushiftRight]

lemma u32_reconstruct_le (x : Std.U32) :
    (((x.bv >>> 0) &&& MASK_BYTE) |||
     (((x.bv >>> 8) &&& MASK_BYTE) <<< 8) |||
     (((x.bv >>> 16) &&& MASK_BYTE) <<< 16) |||
     (((x.bv >>> 24) &&& MASK_BYTE) <<< 24)) = x.bv := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  have hcases :
      i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 ∨ i = 5 ∨ i = 6 ∨ i = 7 ∨
      i = 8 ∨ i = 9 ∨ i = 10 ∨ i = 11 ∨ i = 12 ∨ i = 13 ∨ i = 14 ∨ i = 15 ∨
      i = 16 ∨ i = 17 ∨ i = 18 ∨ i = 19 ∨ i = 20 ∨ i = 21 ∨ i = 22 ∨ i = 23 ∨
      i = 24 ∨ i = 25 ∨ i = 26 ∨ i = 27 ∨ i = 28 ∨ i = 29 ∨ i = 30 ∨ i = 31 := by omega
  rcases hcases with
    rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
    rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
    rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
    rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    simp [MASK_BYTE, BitVec.getLsbD_or, BitVec.getLsbD_shiftLeft, BitVec.getLsbD_and, BitVec.getLsbD_ushiftRight]

/-- `Decimal::serialize` always succeeds and emits the exact 16 little-endian bytes `[flags, lo, mid, hi]`. -/
theorem Decimal.serialize_spec (d : Decimal) :
    let f := d.flags
    let lo := Pion.U64.to_uint d.lo64
    let mid := Pion.U64.to_uint ⟨d.lo64.bv >>> 32⟩
    let hi := d.hi
    Decimal.serialize d = ok ⟨[
      u32_byte f 0, u32_byte f 8, u32_byte f 16, u32_byte f 24,
      u32_byte lo 0, u32_byte lo 8, u32_byte lo 16, u32_byte lo 24,
      u32_byte mid 0, u32_byte mid 8, u32_byte mid 16, u32_byte mid 24,
      u32_byte hi 0, u32_byte hi 8, u32_byte hi 16, u32_byte hi 24
    ]⟩ := by
  unfold Decimal.serialize
  obtain ⟨s32, hs32, _⟩ := u64_shr32_ok d.lo64
  have hs32_eq : s32 = ⟨d.lo64.bv >>> 32⟩ := by
    apply u64_eq_of_bv_eq
    unfold Pion.U64.shr at hs32
    simp only [show (32#u64 : Std.U64).val < 64 from by decide, ↓reduceIte] at hs32
    have := ok_inj hs32
    rw [← this]; rfl
  subst hs32_eq
  rw [hs32, b_ok]
  dsimp only
  simp only [Pion.Bytes.new, Pion.listMake]
  rw [bytes_set_ok _ 0#i32 _ (by decide) (by simp), b_ok]
  obtain ⟨f8, hf8, hf8bv⟩ := u32_shr_ok d.flags 8#u32 (by decide)
  rw [hf8, b_ok, bytes_set_ok _ 1#i32 _ (by decide) (by simp), b_ok]
  obtain ⟨f16, hf16, hf16bv⟩ := u32_shr_ok d.flags 16#u32 (by decide)
  rw [hf16, b_ok, bytes_set_ok _ 2#i32 _ (by decide) (by simp), b_ok]
  obtain ⟨f24, hf24, hf24bv⟩ := u32_shr_ok d.flags 24#u32 (by decide)
  rw [hf24, b_ok, bytes_set_ok _ 3#i32 _ (by decide) (by simp), b_ok]
  rw [bytes_set_ok _ 4#i32 _ (by decide) (by simp), b_ok]
  obtain ⟨l8, hl8, hl8bv⟩ := u32_shr_ok (Pion.U64.to_uint d.lo64) 8#u32 (by decide)
  rw [hl8, b_ok, bytes_set_ok _ 5#i32 _ (by decide) (by simp), b_ok]
  obtain ⟨l16, hl16, hl16bv⟩ := u32_shr_ok (Pion.U64.to_uint d.lo64) 16#u32 (by decide)
  rw [hl16, b_ok, bytes_set_ok _ 6#i32 _ (by decide) (by simp), b_ok]
  obtain ⟨l24, hl24, hl24bv⟩ := u32_shr_ok (Pion.U64.to_uint d.lo64) 24#u32 (by decide)
  rw [hl24, b_ok, bytes_set_ok _ 7#i32 _ (by decide) (by simp), b_ok]
  rw [bytes_set_ok _ 8#i32 _ (by decide) (by simp), b_ok]
  obtain ⟨m8, hm8, hm8bv⟩ := u32_shr_ok (Pion.U64.to_uint ⟨d.lo64.bv >>> 32⟩) 8#u32 (by decide)
  rw [hm8, b_ok, bytes_set_ok _ 9#i32 _ (by decide) (by simp), b_ok]
  obtain ⟨m16, hm16, hm16bv⟩ := u32_shr_ok (Pion.U64.to_uint ⟨d.lo64.bv >>> 32⟩) 16#u32 (by decide)
  rw [hm16, b_ok, bytes_set_ok _ 10#i32 _ (by decide) (by simp), b_ok]
  obtain ⟨m24, hm24, hm24bv⟩ := u32_shr_ok (Pion.U64.to_uint ⟨d.lo64.bv >>> 32⟩) 24#u32 (by decide)
  rw [hm24, b_ok, bytes_set_ok _ 11#i32 _ (by decide) (by simp), b_ok]
  rw [bytes_set_ok _ 12#i32 _ (by decide) (by simp), b_ok]
  obtain ⟨h8, hh8, hh8bv⟩ := u32_shr_ok d.hi 8#u32 (by decide)
  rw [hh8, b_ok, bytes_set_ok _ 13#i32 _ (by decide) (by simp), b_ok]
  obtain ⟨h16, hh16, hh16bv⟩ := u32_shr_ok d.hi 16#u32 (by decide)
  rw [hh16, b_ok, bytes_set_ok _ 14#i32 _ (by decide) (by simp), b_ok]
  obtain ⟨h24, hh24, hh24bv⟩ := u32_shr_ok d.hi 24#u32 (by decide)
  rw [hh24, b_ok, bytes_set_ok _ 15#i32 _ (by decide) (by simp), b_ok]
  have hf8' : f8 = ⟨d.flags.bv >>> 8⟩ := u32_eq_of_bv_eq hf8bv
  have hf16' : f16 = ⟨d.flags.bv >>> 16⟩ := u32_eq_of_bv_eq hf16bv
  have hf24' : f24 = ⟨d.flags.bv >>> 24⟩ := u32_eq_of_bv_eq hf24bv
  have hl8' : l8 = ⟨(Pion.U64.to_uint d.lo64).bv >>> 8⟩ := u32_eq_of_bv_eq hl8bv
  have hl16' : l16 = ⟨(Pion.U64.to_uint d.lo64).bv >>> 16⟩ := u32_eq_of_bv_eq hl16bv
  have hl24' : l24 = ⟨(Pion.U64.to_uint d.lo64).bv >>> 24⟩ := u32_eq_of_bv_eq hl24bv
  have hm8' : m8 = ⟨(Pion.U64.to_uint ⟨d.lo64.bv >>> 32⟩).bv >>> 8⟩ := u32_eq_of_bv_eq hm8bv
  have hm16' : m16 = ⟨(Pion.U64.to_uint ⟨d.lo64.bv >>> 32⟩).bv >>> 16⟩ := u32_eq_of_bv_eq hm16bv
  have hm24' : m24 = ⟨(Pion.U64.to_uint ⟨d.lo64.bv >>> 32⟩).bv >>> 24⟩ := u32_eq_of_bv_eq hm24bv
  have hh8' : h8 = ⟨d.hi.bv >>> 8⟩ := u32_eq_of_bv_eq hh8bv
  have hh16' : h16 = ⟨d.hi.bv >>> 16⟩ := u32_eq_of_bv_eq hh16bv
  have hh24' : h24 = ⟨d.hi.bv >>> 24⟩ := u32_eq_of_bv_eq hh24bv
  subst hf8' hf16' hf24' hl8' hl16' hl24' hm8' hm16' hm24' hh8' hh16' hh24'
  rfl

lemma bytes_get_eq_of_idx (l : List Std.U8) (i : Std.I32) (k : Nat) (v : Std.U8)
    (hk : i.val = (k : Int)) (hlt : k < l.length) (hv : l[k]? = some v) :
    Pion.Bytes.get ⟨l⟩ i = ok v := by
  have h0 : 0 ≤ i.val := by omega
  have h1 : i.val < (⟨l⟩ : Pion.Bytes).val.length := by simp; omega
  rw [bytes_get_ok ⟨l⟩ i h0 h1]
  have hi : i.val.toNat = k := by omega
  have hget : l.get ⟨i.val.toNat, by omega⟩ = l[k] := by
    change l[i.val.toNat]'(by omega) = l[k]'hlt
    congr 1
  change ok (l.get ⟨i.val.toNat, by omega⟩) = ok v
  rw [hget]
  have heq := List.getElem?_eq_getElem hlt
  rw [heq] at hv; injection hv with h; exact congrArg ok h

/-- `read_u32_le` on 4 serialized bytes of `x` recovers `x` identically. -/
lemma read_u32_le_of_bytes (l : List Std.U8) (off : Std.I32) (x : Std.U32)
    (h0 : 0 ≤ off.val) (h1 : off.val + 3 < l.length) (hmax : off.val ≤ 2147483640)
    (hb0 : l[off.val.toNat]? = some (u32_byte x 0))
    (hb1 : l[(off.val + 1).toNat]? = some (u32_byte x 8))
    (hb2 : l[(off.val + 2).toNat]? = some (u32_byte x 16))
    (hb3 : l[(off.val + 3).toNat]? = some (u32_byte x 24)) :
    read_u32_le ⟨l⟩ off = ok x := by
  have hv1 : (1#i32 : Std.I32).val = 1 := by decide
  have hv2 : (2#i32 : Std.I32).val = 2 := by decide
  have hv3 : (3#i32 : Std.I32).val = 3 := by decide
  have h1' : (Pion.I32.add off 1#i32).val = off.val + 1 := by
    have := i32_add_val (a := off) (b := 1#i32) (by omega) (by omega); omega
  have h2' : (Pion.I32.add off 2#i32).val = off.val + 2 := by
    have := i32_add_val (a := off) (b := 2#i32) (by omega) (by omega); omega
  have h3' : (Pion.I32.add off 3#i32).val = off.val + 3 := by
    have := i32_add_val (a := off) (b := 3#i32) (by omega) (by omega); omega
  unfold read_u32_le
  rw [bytes_get_eq_of_idx l off off.val.toNat _ (by omega) (by omega) hb0, b_ok]
  rw [bytes_get_eq_of_idx l _ (off.val + 1).toNat _ (by omega) (by omega) hb1, b_ok]
  obtain ⟨s1, hs1, hs1bv⟩ := u32_shl_ok _ 8#u32 (by decide)
  rw [hs1, b_ok]
  rw [bytes_get_eq_of_idx l _ (off.val + 2).toNat _ (by omega) (by omega) hb2, b_ok]
  obtain ⟨s2, hs2, hs2bv⟩ := u32_shl_ok _ 16#u32 (by decide)
  rw [hs2, b_ok]
  rw [bytes_get_eq_of_idx l _ (off.val + 3).toNat _ (by omega) (by omega) hb3, b_ok]
  obtain ⟨s3, hs3, hs3bv⟩ := u32_shl_ok _ 24#u32 (by decide)
  rw [hs3, b_ok]
  congr 1
  apply u32_eq_of_bv_eq
  dsimp only [Pion.U32.bor]
  rw [hs1bv, hs2bv, hs3bv, u32_byte_to_u32_bv, u32_byte_to_u32_bv, u32_byte_to_u32_bv, u32_byte_to_u32_bv]
  exact u32_reconstruct_le x

lemma valid_flags_mask_eq (f : Std.U32) (hf : valid_flags f) :
    Pion.U32.band f 2149515264#u32 = f := by
  apply u32_eq_of_bv_eq
  dsimp only [Pion.U32.band]
  change f.bv &&& MASK_F5 = f.bv
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [BitVec.getLsbD_and]
  by_cases hm : MASK_F5.getLsbD i = true
  · rw [hm, Bool.and_true]
  · have hcomp : MASK_RES.getLsbD i = true := by
      have hxor : (MASK_F5 ^^^ MASK_RES) = BitVec.allOnes 32 := by decide
      have hget := congrArg (fun bv => bv.getLsbD i) hxor
      simp only [BitVec.getLsbD_xor, BitVec.getLsbD_allOnes, hi, decide_true] at hget
      cases h1 : MASK_F5.getLsbD i <;> cases h2 : MASK_RES.getLsbD i <;> simp_all
    have hzero := congrArg (fun bv => bv.getLsbD i) hf.1
    simp only [BitVec.getLsbD_and, hcomp, Bool.and_true] at hzero
    have hz : ZERO_BV32.getLsbD i = false := by simp [ZERO_BV32]
    rw [hz] at hzero
    rw [hzero, Bool.false_and]

/-- Strict 16-byte wire format roundtrip: for EVERY valid `Decimal`,
    `deserialize (serialize d) = ok (Res.Ok d)`. -/
theorem Decimal.deserialize_serialize_roundtrip (d : Decimal) (hd : valid_decimal d) :
    (do let b ← Decimal.serialize d; Decimal.deserialize b) = ok (Res.Ok d) := by
  rw [Decimal.serialize_spec d, b_ok]
  unfold Decimal.deserialize
  set bs : List Std.U8 := [
      u32_byte d.flags 0, u32_byte d.flags 8, u32_byte d.flags 16, u32_byte d.flags 24,
      u32_byte (Pion.U64.to_uint d.lo64) 0, u32_byte (Pion.U64.to_uint d.lo64) 8,
      u32_byte (Pion.U64.to_uint d.lo64) 16, u32_byte (Pion.U64.to_uint d.lo64) 24,
      u32_byte (Pion.U64.to_uint ⟨d.lo64.bv >>> 32⟩) 0, u32_byte (Pion.U64.to_uint ⟨d.lo64.bv >>> 32⟩) 8,
      u32_byte (Pion.U64.to_uint ⟨d.lo64.bv >>> 32⟩) 16, u32_byte (Pion.U64.to_uint ⟨d.lo64.bv >>> 32⟩) 24,
      u32_byte d.hi 0, u32_byte d.hi 8, u32_byte d.hi 16, u32_byte d.hi 24
    ]
  have hbs_len : bs.length = 16 := rfl
  obtain ⟨n16, hlen, hn16v⟩ := bytes_length_ok ⟨bs⟩ (by rw [hbs_len]; omega)
  have hn16 : n16 = 16#i32 := IScalar.eq_of_val_eq (by rw [hn16v, hbs_len]; decide)
  rw [hlen, hn16, b_ok]
  simp only [ne_eq, not_true_eq_false, ↓reduceIte]
  rw [read_u32_le_of_bytes bs 0#i32 d.flags (by decide) (by rw [hbs_len]; decide) (by decide) rfl rfl rfl rfl, b_ok]
  rw [read_u32_le_of_bytes bs 4#i32 (Pion.U64.to_uint d.lo64) (by decide) (by rw [hbs_len]; decide) (by decide) rfl rfl rfl rfl, b_ok]
  rw [read_u32_le_of_bytes bs 8#i32 (Pion.U64.to_uint ⟨d.lo64.bv >>> 32⟩) (by decide) (by rw [hbs_len]; decide) (by decide) rfl rfl rfl rfl, b_ok]
  rw [read_u32_le_of_bytes bs 12#i32 d.hi (by decide) (by rw [hbs_len]; decide) (by decide) rfl rfl rfl rfl, b_ok]
  rw [valid_flags_mask_eq d.flags hd]
  obtain ⟨sc, hsc, hscbv⟩ := u32_shr16_ok (Pion.U32.band d.flags SCALE_MASK)
  rw [hsc, b_ok]
  have hsc_le : sc ≤ MAX_SCALE := by
    show sc.val ≤ (28#u32 : Std.U32).val
    simp only [UScalar.val, hscbv, Pion.U32.band, SCALE_MASK]
    exact hd.2
  simp only [hsc_le, ↓reduceIte]
  obtain ⟨s32, hs32, hs32v⟩ := u64_shl32_ok (Pion.U32.to_uint64 (Pion.U64.to_uint ⟨d.lo64.bv >>> 32⟩))
  rw [hs32, b_ok]
  congr 1; congr 1
  cases d with
  | mk lo64 hi flags =>
    congr 1
    apply UScalar.eq_of_val_eq
    have hlo_lt : (Pion.U32.to_uint64 (Pion.U64.to_uint lo64)).val < 2 ^ 32 := by
      rw [u32_to_uint64_val, u64_to_uint_val]; exact Nat.mod_lt _ (by norm_num)
    have hs_mod : s32.val % 2 ^ 32 = 0 := by rw [hs32v]; exact Nat.mul_mod_left _ _
    have hshr : (⟨lo64.bv >>> 32⟩ : Std.U64).val = lo64.val / 2 ^ 32 := by
      simp only [UScalar.val, BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
    have hlt := u64_val_lt lo64
    have hmid_lt : lo64.val / 2 ^ 32 < 2 ^ 32 := by omega
    rw [u64_bor_disjoint_32 hlo_lt hs_mod, u32_to_uint64_val, u64_to_uint_val, hs32v,
      u32_to_uint64_val, u64_to_uint_val]
    simp only [hshr, Nat.mod_eq_of_lt hmid_lt]
    omega

/-- `read_u32_le` never traps when `0 ≤ off` and `off + 3 < b.val.length`. -/
lemma read_u32_le_total (b : Pion.Bytes) (off : Std.I32)
    (h0 : 0 ≤ off.val) (h1 : off.val + 3 < b.val.length) (hmax : off.val ≤ 2147483640) :
    ∃ w : Std.U32, read_u32_le b off = ok w := by
  have hv1 : (1#i32 : Std.I32).val = 1 := by decide
  have hv2 : (2#i32 : Std.I32).val = 2 := by decide
  have hv3 : (3#i32 : Std.I32).val = 3 := by decide
  have h1' : (Pion.I32.add off 1#i32).val = off.val + 1 := by
    have := i32_add_val (a := off) (b := 1#i32) (by omega) (by omega); omega
  have h2' : (Pion.I32.add off 2#i32).val = off.val + 2 := by
    have := i32_add_val (a := off) (b := 2#i32) (by omega) (by omega); omega
  have h3' : (Pion.I32.add off 3#i32).val = off.val + 3 := by
    have := i32_add_val (a := off) (b := 3#i32) (by omega) (by omega); omega
  unfold read_u32_le
  rw [bytes_get_ok b off h0 (by omega), b_ok]
  rw [bytes_get_ok b _ (by omega) (by omega), b_ok]
  obtain ⟨s1, hs1, _⟩ := u32_shl_ok _ 8#u32 (by decide)
  rw [hs1, b_ok]
  rw [bytes_get_ok b _ (by omega) (by omega), b_ok]
  obtain ⟨s2, hs2, _⟩ := u32_shl_ok _ 16#u32 (by decide)
  rw [hs2, b_ok]
  rw [bytes_get_ok b _ (by omega) (by omega), b_ok]
  obtain ⟨s3, hs3, _⟩ := u32_shl_ok _ 24#u32 (by decide)
  rw [hs3, b_ok]
  exact ⟨_, rfl⟩

/-- Red-Team F-5 (`0x801F0000` mask) safety & canonicalization theorem:
    For ANY 16-byte input (even with arbitrary illegal reserved bits or scale 29..255),
    `Decimal::deserialize` NEVER traps and ALWAYS produces a strictly valid `Decimal`
    (`reserved bits = 0` and `scale ≤ 28`, matching `rust_decimal =1.37.2`). -/
theorem Decimal.deserialize_always_valid (b : Pion.Bytes) (hlen : b.val.length = 16) :
    ∃ d : Decimal, Decimal.deserialize b = ok (Res.Ok d) ∧ valid_decimal d := by
  unfold Decimal.deserialize
  obtain ⟨n, hn, hnv⟩ := bytes_length_ok b (by omega)
  rw [hn, b_ok]
  have hn16 : n = 16#i32 := IScalar.eq_of_val_eq (by rw [hnv, hlen]; decide)
  simp only [hn16, ne_eq, not_true_eq_false, ↓reduceIte]
  obtain ⟨w0, hw0⟩ := read_u32_le_total b 0#i32 (by decide) (by rw [hlen]; decide) (by decide)
  obtain ⟨lo, hlo⟩ := read_u32_le_total b 4#i32 (by decide) (by rw [hlen]; decide) (by decide)
  obtain ⟨mid, hmid⟩ := read_u32_le_total b 8#i32 (by decide) (by rw [hlen]; decide) (by decide)
  obtain ⟨hi, hhi⟩ := read_u32_le_total b 12#i32 (by decide) (by rw [hlen]; decide) (by decide)
  rw [hw0, b_ok, hlo, b_ok, hmid, b_ok, hhi, b_ok]
  set raw_flags := Pion.U32.band w0 2149515264#u32
  have hres0 : (raw_flags.bv &&& MASK_RES) = ZERO_BV32 := by
    dsimp only [raw_flags, Pion.U32.band]
    change (w0.bv &&& MASK_F5) &&& MASK_RES = ZERO_BV32
    rw [BitVec.and_assoc]
    have h0 : (MASK_F5 &&& MASK_RES) = ZERO_BV32 := by decide
    rw [h0]
    change w0.bv &&& 0#32 = ZERO_BV32
    rw [BitVec.and_zero]; rfl
  obtain ⟨raw_scale, hsc, hscbv⟩ := u32_shr16_ok (Pion.U32.band raw_flags SCALE_MASK)
  rw [hsc, b_ok]
  by_cases hle : raw_scale ≤ MAX_SCALE
  · simp only [hle, ↓reduceIte]
    obtain ⟨s32, hs32, _⟩ := u64_shl32_ok (Pion.U32.to_uint64 mid)
    rw [hs32, b_ok]
    refine ⟨_, rfl, hres0, ?_⟩
    dsimp only
    have h28 : raw_scale.val ≤ 28 := by
      have : raw_scale.val ≤ (28#u32 : Std.U32).val := hle
      have hv : (28#u32 : Std.U32).val = 28 := by decide
      omega
    have hsc_eq : ((raw_flags.bv &&& MASK_SCALE) >>> 16).toNat = raw_scale.val := by
      simp only [UScalar.val, hscbv]; rfl
    omega
  · simp only [hle, ↓reduceIte]
    set div64 : Std.U64 := if raw_scale = 29#u32 then 10#u64 else if raw_scale = 30#u32 then 100#u64 else 1000#u64
    have hdiv_nz : div64.val ≠ 0 := by
      simp only [div64]; split_ifs <;> decide
    obtain ⟨t7, ht7, _⟩ := u64_div_ok (Pion.U32.to_uint64 hi) hdiv_nz
    rw [ht7, b_ok]
    obtain ⟨t8, ht8, _⟩ := u64_shl32_ok _
    rw [ht8, b_ok]
    obtain ⟨t9, ht9, _⟩ := u64_div_ok _ hdiv_nz
    rw [ht9, b_ok]
    obtain ⟨t10, ht10, _⟩ := u64_shl32_ok _
    rw [ht10, b_ok]
    obtain ⟨t11, ht11, _⟩ := u64_div_ok _ hdiv_nz
    rw [ht11, b_ok]
    have hcarry : ∃ q01 q11 q21,
        (if Pion.U64.to_uint (Pion.U64.sub (Pion.U64.bor t10 (Pion.U32.to_uint64 lo))
              (Pion.U64.mul (Pion.U32.to_uint64 (Pion.U64.to_uint t11)) div64)) >= 5#u32 then
          let s0 := Pion.U64.add (Pion.U32.to_uint64 (Pion.U64.to_uint t11)) 1#u64
          let q02 := Pion.U64.to_uint s0
          if s0 > 4294967295#u64 then
            let s1 := Pion.U64.add (Pion.U32.to_uint64 (Pion.U64.to_uint t9)) 1#u64
            let q12 := Pion.U64.to_uint s1
            if s1 > 4294967295#u64 then
              ok (q02, q12, Pion.U32.add (Pion.U64.to_uint t7) 1#u32)
            else ok (q02, q12, Pion.U64.to_uint t7)
          else ok (q02, Pion.U64.to_uint t9, Pion.U64.to_uint t7)
        else ok (Pion.U64.to_uint t11, Pion.U64.to_uint t9, Pion.U64.to_uint t7)) =
        ok (q01, q11, q21) := by
      by_cases hc0 : Pion.U64.to_uint (Pion.U64.sub (Pion.U64.bor t10 (Pion.U32.to_uint64 lo))
            (Pion.U64.mul (Pion.U32.to_uint64 (Pion.U64.to_uint t11)) div64)) >= 5#u32
      · rw [ite_eq_left hc0]
        dsimp only
        by_cases hc1 : Pion.U64.add (Pion.U32.to_uint64 (Pion.U64.to_uint t11)) 1#u64 > 4294967295#u64
        · rw [ite_eq_left hc1]
          by_cases hc2 : Pion.U64.add (Pion.U32.to_uint64 (Pion.U64.to_uint t9)) 1#u64 > 4294967295#u64
          · rw [ite_eq_left hc2]; exact ⟨_, _, _, rfl⟩
          · rw [ite_eq_right hc2]; exact ⟨_, _, _, rfl⟩
        · rw [ite_eq_right hc1]; exact ⟨_, _, _, rfl⟩
      · rw [ite_eq_right hc0]; exact ⟨_, _, _, rfl⟩
    obtain ⟨q01, q11, q21, hcar⟩ := hcarry
    rw [hcar, b_ok]
    obtain ⟨t12, ht12, _⟩ := u64_shl32_ok (Pion.U32.to_uint64 q11)
    obtain ⟨f, hf, hfv, _, _⟩ := make_flags_spec (Pion.U32.band raw_flags SIGN_MASK != 0#u32) MAX_SCALE (by decide)
    exact ⟨Decimal.mk (Pion.U64.bor (Pion.U32.to_uint64 q01) t12) q21 f, by
      change (do let __t_12 ← Pion.U64.shl (Pion.U32.to_uint64 q11) 32#u64
                 let __t_13 ← make_flags _ MAX_SCALE
                 ok (Pion.Res.Ok (Decimal.mk (Pion.U64.bor (Pion.U32.to_uint64 q01) __t_12) q21 __t_13))) = _
      rw [ht12, hf]; simp, hfv⟩


end DecimalProofs
