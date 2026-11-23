/-
Formal verification of `packages/decimal` (`Decimal.Funs`, extracted via
`pionc extract-lean` from `packages/decimal/src/*.pion`).

All proofs are complete and kernel-checked, depending only on the three
standard Lean axioms: `propext`, `Classical.choice`, `Quot.sound`.
-/
import Decimal.Funs

open Aeneas Aeneas.Std Result ControlFlow Error Pion WP

set_option maxRecDepth 100000
set_option maxHeartbeats 2000000
set_option linter.unusedSimpArgs false

namespace DecimalProofs

open decimal

/-! ## 0. Common Scalar, BitVec & Mathematical Model Helpers -/

lemma b_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← (ok x : Result α); f y) = f x := by simp

lemma b_ok2 {α β γ : Type} (x : α) (y : β) (f : α → β → Result γ) :
    (do let (a, b) ← (ok (x, y) : Result (α × β)); f a b) = f x y := by simp

lemma b_ok3 {α β γ δ : Type} (x : α) (y : β) (z : γ) (f : α → β → γ → Result δ) :
    (do let (a, b, c) ← (ok (x, y, z) : Result (α × β × γ)); f a b c) = f x y z := by simp

lemma wp_ok_iff {α : Type u} (r : Result α) (P : α → Prop) :
    r ⦃ P ⦄ ↔ ∃ y, r = ok y ∧ P y := by
  cases r with
  | ret y => simp [WP.spec_ok]
  | vis e k => simp [WP.spec_vis]
  | div => simp [WP.spec_div]

/-- Exact unsigned 96-bit value of 3 little-endian 32-bit words `[lo, mid, hi]`. -/
def val96_parts (lo mid hi : Std.U32) : Nat :=
  lo.val + 2 ^ 32 * mid.val + 2 ^ 64 * hi.val

/-- Exact unsigned 96-bit value of `(lo64, hi)`. -/
def val96 (lo64 : Std.U64) (hi : Std.U32) : Nat :=
  lo64.val + 2 ^ 64 * hi.val

/-- Bitwise masks at width 32 so every `BitVec 32` shares one width type. -/
private abbrev BV32 := BitVec 32
def MASK_RES : BV32 := BitVec.ofNat 32 0x7FE0FFFF
def MASK_SCALE : BV32 := BitVec.ofNat 32 0x00FF0000
def MASK_SIGN : BV32 := BitVec.ofNat 32 0x80000000
def MASK_ABS : BV32 := BitVec.ofNat 32 0x7FFFFFFF
def MASK_F5 : BV32 := BitVec.ofNat 32 0x801F0000
def MASK_BYTE : BV32 := BitVec.ofNat 32 0xFF
def ZERO_BV32 : BV32 := BitVec.ofNat 32 0

/-- Valid `Decimal.flags` invariant:
    - All reserved bits outside `0x801F_0000` (sign bit 31 and 5-bit scale 16..20) are 0;
    - The decoded scale `(flags & 0x00FF_0000) >> 16` is in `0..=28`. -/
def valid_flags (f : Std.U32) : Prop :=
  (f.bv &&& MASK_RES) = ZERO_BV32 ∧
  ((f.bv &&& MASK_SCALE) >>> 16).toNat ≤ 28

/-- Valid `Decimal` invariant. -/
def valid_decimal (d : Decimal) : Prop :=
  valid_flags d.flags

/-- Decoded mathematical scale of `d` (`0..=28` when `valid_decimal d`). -/
def dec_scale (d : Decimal) : Nat :=
  ((d.flags.bv &&& MASK_SCALE) >>> 16).toNat

/-- Decoded sign bit of `d`. -/
def dec_neg (d : Decimal) : Bool :=
  (d.flags.bv &&& MASK_SIGN) != ZERO_BV32

/-- Decoded unsigned 96-bit mantissa of `d`. -/
def dec_mag (d : Decimal) : Nat :=
  val96 d.lo64 d.hi

/-- Signed integer mantissa of `d` (value = `dec_signed_val d / 10^(dec_scale d)`). -/
def dec_signed_val (d : Decimal) : Int :=
  if dec_neg d then -(dec_mag d : Int) else (dec_mag d : Int)

/-- Exact rational strict less-than (`a / 10^s1 < b / 10^s2`), cross-multiplied. -/
def dec_lt_rat (a b : Decimal) : Prop :=
  dec_signed_val a * (10 ^ dec_scale b : Int) < dec_signed_val b * (10 ^ dec_scale a : Int)

/-- Exact rational equality (`a / 10^s1 = b / 10^s2`), cross-multiplied. -/
def dec_eq_rat (a b : Decimal) : Prop :=
  dec_signed_val a * (10 ^ dec_scale b : Int) = dec_signed_val b * (10 ^ dec_scale a : Int)

/-! ### Scalar arithmetic & bitwise helper lemmas -/

lemma u32_val_lt (x : Std.U32) : x.val < 2 ^ 32 := x.bv.isLt
lemma u64_val_lt (x : Std.U64) : x.val < 2 ^ 64 := x.bv.isLt
lemma u8_val_lt (x : Std.U8) : x.val < 2 ^ 8 := x.bv.isLt

lemma u32_eq_of_bv_eq {a b : Std.U32} (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

lemma u64_eq_of_bv_eq {a b : Std.U64} (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

lemma u8_eq_of_bv_eq {a b : Std.U8} (h : a.bv = b.bv) : a = b := by
  cases a; cases b; congr

lemma u32_to_uint64_val (x : Std.U32) : (Pion.U32.to_uint64 x).val = x.val := by
  cases x with
  | mk bv =>
    have hlt : bv.toNat < 2 ^ 32 := bv.isLt
    simp only [Pion.U32.to_uint64, UScalar.cast, UScalar.val, UScalarTy.numBits,
      BitVec.toNat_setWidth]
    omega

lemma u64_to_uint_val (x : Std.U64) : (Pion.U64.to_uint x).val = x.val % 2 ^ 32 := by
  cases x with
  | mk bv =>
    simp only [Pion.U64.to_uint, UScalar.cast, UScalar.val, UScalarTy.numBits,
      BitVec.toNat_setWidth]

lemma u32_to_int_val {x : Std.U32} (h : x.val < 2 ^ 31) :
    (Pion.U32.to_int x).val = (x.val : Int) := by
  cases x with
  | mk bv =>
    simp only [UScalar.val] at h
    simp only [Pion.U32.to_int, UScalar.hcast, IScalar.val, IScalarTy.numBits, UScalarTy.numBits,
      UScalar.val, BitVec.toInt_setWidth, BitVec.toInt_ofNat]
    rw [Int.bmod_eq_of_le_mul_two] <;> omega

lemma i32_add_val {a b : Std.I32}
    (hlo : -2147483648 ≤ a.val + b.val) (hhi : a.val + b.val ≤ 2147483647) :
    (Pion.I32.add a b).val = a.val + b.val := by
  simp only [IScalar.val] at hlo hhi
  simp only [Pion.I32.add, Std.I32.wrapping_add, IScalar.wrapping_add, IScalar.val,
    IScalarTy.numBits]
  rw [BitVec.toInt_add]
  exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)

lemma i32_sub_val {a b : Std.I32}
    (hlo : -2147483648 ≤ a.val - b.val) (hhi : a.val - b.val ≤ 2147483647) :
    (Pion.I32.sub a b).val = a.val - b.val := by
  simp only [IScalar.val] at hlo hhi
  simp only [Pion.I32.sub, Std.I32.wrapping_sub, IScalar.wrapping_sub, IScalar.val,
    IScalarTy.numBits]
  rw [BitVec.toInt_sub]
  exact Int.bmod_eq_of_le_mul_two (by omega) (by omega)

lemma u32_add_val (a b : Std.U32) :
    (Pion.U32.add a b).val = (a.val + b.val) % 2 ^ 32 := by
  simp only [Pion.U32.add, Std.U32.wrapping_add, UScalar.wrapping_add, UScalar.val,
    UScalarTy.numBits, BitVec.toNat_add]

lemma u32_sub_val {a b : Std.U32} (h : b.val ≤ a.val) :
    (Pion.U32.sub a b).val = a.val - b.val := by
  have ha := u32_val_lt a
  have hb := u32_val_lt b
  simp only [UScalar.val] at h ha hb
  simp only [Pion.U32.sub, Std.U32.wrapping_sub, UScalar.wrapping_sub, UScalar.val,
    UScalarTy.numBits, BitVec.toNat_sub]
  omega

lemma u32_mul_val (a b : Std.U32) :
    (Pion.U32.mul a b).val = (a.val * b.val) % 2 ^ 32 := by
  simp only [Pion.U32.mul, Std.U32.wrapping_mul, UScalar.wrapping_mul, UScalar.val,
    UScalarTy.numBits, BitVec.toNat_mul]

lemma u64_add_val (a b : Std.U64) :
    (Pion.U64.add a b).val = (a.val + b.val) % 2 ^ 64 := by
  simp only [Pion.U64.add, Std.U64.wrapping_add, UScalar.wrapping_add, UScalar.val,
    UScalarTy.numBits, BitVec.toNat_add]

lemma u64_sub_val {a b : Std.U64} (h : b.val ≤ a.val) :
    (Pion.U64.sub a b).val = a.val - b.val := by
  have ha := u64_val_lt a
  have hb := u64_val_lt b
  simp only [UScalar.val] at h ha hb
  simp only [Pion.U64.sub, Std.U64.wrapping_sub, UScalar.wrapping_sub, UScalar.val,
    UScalarTy.numBits, BitVec.toNat_sub]
  omega

lemma u64_sub_wrap_val {a b : Std.U64} (h : a.val < b.val) :
    (Pion.U64.sub a b).val = 2 ^ 64 + a.val - b.val := by
  have ha := u64_val_lt a
  have hb := u64_val_lt b
  simp only [UScalar.val] at h ha hb
  simp only [Pion.U64.sub, Std.U64.wrapping_sub, UScalar.wrapping_sub, UScalar.val,
    UScalarTy.numBits, BitVec.toNat_sub]
  omega

lemma u64_mul_val (a b : Std.U64) :
    (Pion.U64.mul a b).val = (a.val * b.val) % 2 ^ 64 := by
  simp only [Pion.U64.mul, Std.U64.wrapping_mul, UScalar.wrapping_mul, UScalar.val,
    UScalarTy.numBits, BitVec.toNat_mul]

lemma u64_band_mask32 (x : Std.U64) :
    (Pion.U64.band x 4294967295#u64).val = x.val % 2 ^ 32 := by
  cases x with
  | mk bv =>
    simp only [Pion.U64.band, UScalar.val, BitVec.toNat_and]
    have h2 : (4294967295#u64 : Std.U64).bv.toNat = 2 ^ 32 - 1 := by decide
    rw [h2, Nat.and_two_pow_sub_one_eq_mod]

lemma u64_shr32_ok (x : Std.U64) :
    ∃ y, Pion.U64.shr x 32#u64 = ok y ∧ y.val = x.val / 2 ^ 32 := by
  unfold Pion.U64.shr
  have hlt : (32#u64 : Std.U64).val < 64 := by decide
  simp only [hlt, ↓reduceIte]
  refine ⟨_, rfl, ?_⟩
  simp only [UScalar.val, BitVec.toNat_ushiftRight]
  have hv : (32#u64 : Std.U64).bv.toNat = 32 := by decide
  rw [hv, Nat.shiftRight_eq_div_pow]

lemma u64_shl32_ok (x : Std.U64) :
    ∃ y, Pion.U64.shl x 32#u64 = ok y ∧ y.val = (x.val % 2 ^ 32) * 2 ^ 32 := by
  unfold Pion.U64.shl
  have hlt : (32#u64 : Std.U64).val < 64 := by decide
  simp only [hlt, ↓reduceIte]
  refine ⟨_, rfl, ?_⟩
  simp only [UScalar.val, UScalarTy.numBits, BitVec.toNat_shiftLeft]
  have hv : (32#u64 : Std.U64).bv.toNat = 32 := by decide
  rw [hv, Nat.shiftLeft_eq]
  have h64 : (2 : Nat) ^ 64 = 2 ^ 32 * 2 ^ 32 := by norm_num
  rw [h64, Nat.mul_mod_mul_right]

lemma ok_inj {α : Type u} {x y : α} (h : (ok x : Result α) = ok y) : x = y := by
  simpa using h

lemma bv_and_xor_distrib_right {w : Nat} (a b c : BitVec w) :
    (a ^^^ b) &&& c = (a &&& c) ^^^ (b &&& c) := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [BitVec.getLsbD_and, BitVec.getLsbD_xor]
  cases a.getLsbD i <;> cases b.getLsbD i <;> cases c.getLsbD i <;> rfl

/-- Pure Nat identity: for `a < 2^n`, `a ||| (k * 2^n) = a + k * 2^n`. -/
lemma nat_or_mul_pow2 : ∀ (n a k : Nat), a < 2 ^ n →
    (a ||| (k * 2 ^ n)) = a + k * 2 ^ n
  | 0, a, k, ha => by
    have ha0 : a = 0 := by omega
    subst ha0; simp
  | n + 1, a, k, ha => by
    have hpow : 2 ^ (n + 1) = 2 ^ n * 2 := Nat.pow_succ 2 n
    have ha' : a / 2 < 2 ^ n := by omega
    have ih := nat_or_mul_pow2 n (a / 2) k ha'
    have hmul : k * 2 ^ (n + 1) = (k * 2 ^ n) * 2 := by rw [hpow, Nat.mul_assoc]
    have hdiv : (a ||| (k * 2 ^ (n + 1))) / 2 = a / 2 + k * 2 ^ n := by
      rw [Nat.or_div_two, hmul, Nat.mul_div_cancel _ (by omega), ih]
    have hmod : (a ||| (k * 2 ^ (n + 1))) % 2 = a % 2 := by
      rw [Nat.or_mod_two, hmul, Nat.mul_mod_left]; simp
    have hsplit1 : (a ||| (k * 2 ^ (n + 1))) = 2 * ((a ||| (k * 2 ^ (n + 1))) / 2) + (a ||| (k * 2 ^ (n + 1))) % 2 := by
      omega
    have hsplit2 : a = 2 * (a / 2) + a % 2 := by omega
    rw [hsplit1, hdiv, hmod, hmul]
    omega

lemma u64_bor_disjoint_32 {lo hi : Std.U64}
    (hlo : lo.val < 2 ^ 32) (hhi : hi.val % 2 ^ 32 = 0) :
    (Pion.U64.bor lo hi).val = lo.val + hi.val := by
  simp only [UScalar.val] at hlo hhi
  simp only [Pion.U64.bor, UScalar.val, BitVec.toNat_or]
  have hdiv : hi.bv.toNat = hi.bv.toNat / 2 ^ 32 * 2 ^ 32 := by
    have := Nat.div_add_mod hi.bv.toNat (2 ^ 32)
    rw [hhi, Nat.add_zero] at this
    rw [Nat.mul_comm] at this
    exact this.symm
  conv_lhs => rw [hdiv]
  rw [nat_or_mul_pow2 32 lo.bv.toNat (hi.bv.toNat / 2 ^ 32) hlo, ← hdiv]

lemma u64_div_ok (a : Std.U64) {b : Std.U64} (hb : b.val ≠ 0) :
    ∃ q, Pion.U64.div a b = ok q ∧ q.val = a.val / b.val := by
  have h := Pion.U64.div_spec a hb
  rw [wp_ok_iff] at h
  exact h

lemma u32_shr16_ok (x : Std.U32) :
    ∃ y, Pion.U32.shr x 16#u32 = ok y ∧ y.bv = x.bv >>> 16 := by
  unfold Pion.U32.shr
  have hlt : (16#u32 : Std.U32).val < 32 := by decide
  simp only [hlt, ↓reduceIte]
  exact ⟨_, rfl, rfl⟩

lemma u32_shl16_ok (x : Std.U32) :
    ∃ y, Pion.U32.shl x 16#u32 = ok y ∧ y.bv = x.bv <<< 16 := by
  unfold Pion.U32.shl
  have hlt : (16#u32 : Std.U32).val < 32 := by decide
  simp only [hlt, ↓reduceIte]
  exact ⟨_, rfl, rfl⟩

lemma u32_shr_ok (x : Std.U32) (n : Std.U32) (hn : n.val < 32) :
    ∃ y, Pion.U32.shr x n = ok y ∧ y.bv = x.bv >>> n.val := by
  unfold Pion.U32.shr
  simp only [hn, ↓reduceIte]
  exact ⟨_, rfl, rfl⟩

lemma u32_shl_ok (x : Std.U32) (n : Std.U32) (hn : n.val < 32) :
    ∃ y, Pion.U32.shl x n = ok y ∧ y.bv = x.bv <<< n.val := by
  unfold Pion.U32.shl
  simp only [hn, ↓reduceIte]
  exact ⟨_, rfl, rfl⟩

lemma bytes_set_ok (b : Pion.Bytes) (i : Std.I32) (x : Std.U8)
    (h0 : 0 ≤ i.val) (h1 : i.val < b.val.length) :
    Pion.Bytes.set b i x = ok ⟨b.val.set i.val.toNat x⟩ := by
  unfold Pion.Bytes.set Pion.listSet
  simp [h0, h1]

lemma bytes_get_ok (b : Pion.Bytes) (i : Std.I32)
    (h0 : 0 ≤ i.val) (h1 : i.val < b.val.length) :
    Pion.Bytes.get b i = ok (b.val.get ⟨i.val.toNat, by omega⟩) := by
  unfold Pion.Bytes.get Pion.listGet
  simp [h0, h1]

lemma bytes_length_ok (b : Pion.Bytes) (h : b.val.length ≤ 2147483647) :
    ∃ n, Pion.Bytes.length b = ok n ∧ n.val = b.val.length := by
  unfold Pion.Bytes.length Pion.lengthOf
  simp only [h, ↓reduceDIte]
  exact ⟨_, rfl, by simp⟩


end DecimalProofs
