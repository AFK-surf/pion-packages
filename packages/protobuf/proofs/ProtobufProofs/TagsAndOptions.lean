import Aeneas
import PionLean
import Protobuf.Types
import Protobuf.Funs
import ProtobufProofs.ZigZagAndVarint

open Aeneas Aeneas.Std Result Pion protobuf

namespace ProtobufProofs

private lemma result_bind_ok' {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← ok x; f y) = f x := by simp

private lemma i32_nonneg_to_u64_val (x : Std.I32) (h0 : 0 ≤ x.val) :
    (Pion.I64.to_uint64 (Pion.I32.to_int64 x)).val = x.val.toNat := by
  have hcond : (x.bv.toNat : Int) = x.val ∧ 2 * x.bv.toNat < 2 ^ 32 := by
    have h := x.bv.toInt_eq_toNat_cond
    change 0 ≤ x.bv.toInt at h0
    split_ifs at h with hc
    · exact ⟨h.symm, hc⟩
    · have := x.bv.isLt; omega
  have hmsb : x.bv.msb = false := by
    rw [BitVec.msb_eq_decide]
    exact decide_eq_false (by omega)
  have hsext : (x.bv.signExtend 64).toNat = x.bv.toNat := by
    rw [BitVec.signExtend_eq_setWidth_of_msb_false hmsb, BitVec.toNat_setWidth]
    have := x.bv.isLt
    exact Nat.mod_eq_of_lt (by omega)
  have hbv : (Pion.I64.to_uint64 (Pion.I32.to_int64 x)).bv = x.bv.signExtend 64 := by
    unfold Pion.I64.to_uint64 Pion.I32.to_int64 IScalar.hcast IScalar.cast
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    change (BitVec.signExtend 64 (x.bv.signExtend 64)).getLsbD i = (x.bv.signExtend 64).getLsbD i
    rw [BitVec.getLsbD_signExtend]
    have h64 : i < 64 := hi
    simp [h64]
  change (Pion.I64.to_uint64 (Pion.I32.to_int64 x)).bv.toNat = x.val.toNat
  rw [hbv, hsext]
  omega

private lemma u64_to_i32_val (x : Std.U64) (hlt : x.val < 2 ^ 31) :
    (Pion.U64.to_int x).val = (x.val : Int) := by
  have hbv : (Pion.U64.to_int x).bv = x.bv.setWidth 32 := rfl
  have hlt' : x.bv.toNat < 2 ^ 31 := hlt
  have hnat : (Pion.U64.to_int x).bv.toNat = x.val := by
    rw [hbv, BitVec.toNat_setWidth]
    exact Nat.mod_eq_of_lt (by omega)
  have h := (Pion.U64.to_int x).bv.toInt_eq_toNat_cond
  have h2 : 2 * (Pion.U64.to_int x).bv.toNat < 2 ^ 32 := by omega
  simp only [h2, ↓reduceIte] at h
  change (Pion.U64.to_int x).bv.toInt = (x.val : Int)
  rw [h, hnat]

private lemma u64_shl3_ok (x : Std.U64) :
    Pion.U64.shl x 3#u64 = ok ⟨x.bv <<< 3⟩ := by
  unfold Pion.U64.shl
  have h3 : (3#u64 : Std.U64).val < 64 := by decide
  simp only [h3, ↓reduceIte]
  rfl

private lemma u64_shr3_ok (x : Std.U64) :
    Pion.U64.shr x 3#u64 = ok ⟨x.bv >>> 3⟩ := by
  unfold Pion.U64.shr
  have h3 : (3#u64 : Std.U64).val < 64 := by decide
  simp only [h3, ↓reduceIte]
  rfl

private lemma nat_or_shl3 (a b : Nat) (hb : b < 8) :
    (a * 8) ||| b = a * 8 + b := by
  apply Nat.eq_of_testBit_eq
  intro i
  rw [Nat.testBit_or]
  have hmul : (a * 8).testBit i = if i < 3 then false else a.testBit (i - 3) := by
    have h8 : a * 8 = a <<< 3 := by rw [Nat.shiftLeft_eq]
    rw [h8, Nat.testBit_shiftLeft]
    by_cases hi : i < 3
    · have hnot : ¬ (3 ≤ i) := by omega
      simp [hi, hnot]
    · have hge : 3 ≤ i := by omega
      simp [hi, hge]
  rw [hmul]
  by_cases hi : i < 3
  · simp only [hi, ↓reduceIte, Bool.false_or]
    rw [Nat.testBit_eq_decide_div_mod_eq, Nat.testBit_eq_decide_div_mod_eq]
    have hpow : 8 = 2 ^ (3 - i) * 2 ^ i := by
      have : 2 ^ 3 = 2 ^ (3 - i) * 2 ^ i := by rw [← Nat.pow_add]; congr 1; omega
      exact this
    have hpos : 0 < 2 ^ i := Nat.two_pow_pos i
    have hdiv : (a * 8 + b) / 2 ^ i = b / 2 ^ i + a * 2 ^ (3 - i) := by
      rw [Nat.add_comm, hpow, ← Nat.mul_assoc, Nat.add_mul_div_right _ _ hpos]
    have heven : 2 ∣ 2 ^ (3 - i) := by
      refine ⟨2 ^ (3 - i - 1), ?_⟩
      conv => lhs; rw [show 3 - i = (3 - i - 1) + 1 by omega, Nat.pow_succ, Nat.mul_comm]
    rcases heven with ⟨q, hq⟩
    rw [hdiv, hq]
    have hre : a * (2 * q) = 2 * (a * q) := by
      rw [← Nat.mul_assoc, Nat.mul_comm a 2, Nat.mul_assoc]
    rw [hre, Nat.add_mul_mod_self_left]
  · simp only [hi, ↓reduceIte]
    have hlt : b.testBit i = false := by
      apply Nat.testBit_lt_two_pow
      have hle : 2 ^ 3 ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
      omega
    rw [hlt, Bool.or_false, Nat.testBit_eq_decide_div_mod_eq, Nat.testBit_eq_decide_div_mod_eq]
    have hpow : 2 ^ i = 8 * 2 ^ (i - 3) := by
      have : 2 ^ i = 2 ^ 3 * 2 ^ (i - 3) := by rw [← Nat.pow_add]; congr 1; omega
      exact this
    have hdiv1 : (a * 8 + b) / 8 = a := by
      rw [Nat.add_comm, Nat.add_mul_div_right _ _ (by omega), Nat.div_eq_of_lt hb, Nat.zero_add]
    rw [hpow, ← Nat.div_div_eq_div_mul, hdiv1]

/-- Theorem 15: `wire_type_code` and `wire_type_from_code` form an exact roundtrip on all 6 Protobuf wire types. -/
lemma wire_type_roundtrip (wt : WireType) :
    (do let c ← wire_type_code wt; wire_type_from_code c) = ok (some wt) := by
  cases wt <;> simp [wire_type_code, wire_type_from_code]

/-- Theorem 16: `wire_type_from_code` accepts exactly `{0, 1, 2, 3, 4, 5}` (rejecting 6, 7, and out-of-range codes). -/
theorem wire_type_from_code_valid_iff (code : Std.I32) :
    (∃ wt : WireType, wire_type_from_code code = ok (some wt)) ↔ (0 ≤ code.val ∧ code.val ≤ 5) := by
  unfold wire_type_from_code
  constructor
  · rintro ⟨wt, hwt⟩
    by_cases h0 : code = 0#i32; · subst h0; decide
    simp only [h0, ↓reduceIte] at hwt
    by_cases h1 : code = 1#i32; · subst h1; decide
    simp only [h1, ↓reduceIte] at hwt
    by_cases h2 : code = 2#i32; · subst h2; decide
    simp only [h2, ↓reduceIte] at hwt
    by_cases h3 : code = 3#i32; · subst h3; decide
    simp only [h3, ↓reduceIte] at hwt
    by_cases h4 : code = 4#i32; · subst h4; decide
    simp only [h4, ↓reduceIte] at hwt
    by_cases h5 : code = 5#i32; · subst h5; decide
    simp only [h5, ↓reduceIte] at hwt
    simp only [ok.injEq, reduceCtorEq] at hwt
  · intro ⟨hlo, hhi⟩
    have hc : code.val = 0 ∨ code.val = 1 ∨ code.val = 2 ∨ code.val = 3 ∨ code.val = 4 ∨ code.val = 5 := by omega
    rcases hc with h | h | h | h | h | h
    · have heq : code = 0#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.Varint, rfl⟩
    · have heq : code = 1#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.Fixed64, rfl⟩
    · have heq : code = 2#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.LengthDelimited, rfl⟩
    · have heq : code = 3#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.StartGroup, rfl⟩
    · have heq : code = 4#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.EndGroup, rfl⟩
    · have heq : code = 5#i32 := IScalar.eq_of_val_eq h; subst heq; exact ⟨.Fixed32, rfl⟩

/-- Theorem 18: `encode_tag_raw` computes exact `field_number * 8 + wire_type_code` within 32-bit unsigned range. -/
theorem encode_tag_raw_exact (f : Std.I32) (wt : WireType)
    (hlo : 1 ≤ f.val) (hhi : f.val ≤ 536870911) :
    ∃ (raw : Std.U64) (c : Std.I32),
      wire_type_code wt = ok c ∧
      encode_tag_raw f wt = ok raw ∧
      raw.val = f.val.toNat * 8 + c.val.toNat ∧
      raw.val ≤ 4294967295 := by
  have hwt : ∃ c : Std.I32, wire_type_code wt = ok c ∧ 0 ≤ c.val ∧ c.val ≤ 5 := by
    cases wt <;> exact ⟨_, rfl, by decide, by decide⟩
  obtain ⟨c, hc, hclo, hchi⟩ := hwt
  unfold encode_tag_raw
  rw [hc, result_bind_ok', u64_shl3_ok, result_bind_ok']
  set fu := Pion.I64.to_uint64 (Pion.I32.to_int64 f)
  set cu := Pion.I64.to_uint64 (Pion.I32.to_int64 c)
  have hfu : fu.val = f.val.toNat := i32_nonneg_to_u64_val f (by omega)
  have hcu : cu.val = c.val.toNat := i32_nonneg_to_u64_val c hclo
  set raw : Std.U64 := Pion.U64.bor ⟨fu.bv <<< 3⟩ cu
  have hraw : raw.val = f.val.toNat * 8 + c.val.toNat := by
    change ((fu.bv <<< 3) ||| cu.bv).toNat = f.val.toNat * 8 + c.val.toNat
    rw [BitVec.toNat_or, BitVec.toNat_shiftLeft, Nat.shiftLeft_eq]
    have hmod : (fu.bv.toNat * 2 ^ 3) % 2 ^ 64 = f.val.toNat * 8 := by
      change (fu.val * 8) % 2 ^ 64 = f.val.toNat * 8
      rw [hfu]
      exact Nat.mod_eq_of_lt (by omega)
    rw [hmod]
    change (f.val.toNat * 8) ||| cu.val = f.val.toNat * 8 + c.val.toNat
    rw [hcu]
    exact nat_or_shl3 f.val.toNat c.val.toNat (by omega)
  exact ⟨raw, c, rfl, rfl, hraw, by omega⟩

/-- Theorem 19: Tag encoding and decoding (`encode_tag_raw` -> `decode_tag_field_num` / `decode_tag_wire_type`) roundtrip losslessly for all legal field numbers `1..536870911`. -/
theorem tag_encode_decode_roundtrip (f : Std.I32) (wt : WireType)
    (hlo : 1 ≤ f.val) (hhi : f.val ≤ 536870911) :
    ∃ (raw : Std.U64) (c : Std.I32),
      encode_tag_raw f wt = ok raw ∧
      decode_tag_field_num raw = ok f ∧
      decode_tag_wire_type raw = ok c ∧
      wire_type_from_code c = ok (some wt) := by
  obtain ⟨raw, c, hc, hraw, hrawv, hrawle⟩ := encode_tag_raw_exact f wt hlo hhi
  have hcr : 0 ≤ c.val ∧ c.val ≤ 5 := by cases wt <;> (simp [wire_type_code] at hc; subst hc; decide)
  have hfn : decode_tag_field_num raw = ok f := by
    unfold decode_tag_field_num
    rw [u64_shr3_ok, result_bind_ok']
    congr 1
    set s : Std.U64 := ⟨raw.bv >>> 3⟩
    have hsv : s.val = f.val.toNat := by
      change (raw.bv >>> 3).toNat = f.val.toNat
      rw [BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
      change raw.val / 8 = f.val.toNat
      rw [hrawv]
      omega
    apply IScalar.eq_of_val_eq
    rw [u64_to_i32_val s (by omega), hsv]
    omega
  have hwt_dec : decode_tag_wire_type raw = ok c := by
    unfold decode_tag_wire_type
    congr 1
    set m : Std.U64 := Pion.U64.band raw 7#u64
    have hmv : m.val = c.val.toNat := by
      change (raw.bv &&& (7#64 : BitVec 64)).toNat = c.val.toNat
      rw [BitVec.toNat_and]
      have h7 : (7#64 : BitVec 64).toNat = 2 ^ 3 - 1 := rfl
      rw [h7, Nat.and_two_pow_sub_one_eq_mod]
      change raw.val % 8 = c.val.toNat
      rw [hrawv]
      omega
    apply IScalar.eq_of_val_eq
    rw [u64_to_i32_val m (by omega), hmv]
    omega
  have hfrom : wire_type_from_code c = ok (some wt) := by
    have hrt := wire_type_roundtrip wt
    rw [hc, result_bind_ok'] at hrt
    exact hrt
  exact ⟨raw, c, hraw, hfn, hwt_dec, hfrom⟩

end ProtobufProofs
