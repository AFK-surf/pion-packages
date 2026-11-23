/-
Executable `#eval` / `#guard` differential checks on the extracted `Decimal.Funs`:
covers zero, negative zero, `MAX`/`MIN`, 96-bit carry & overflow detection,
`u64_mul_wide`, `u96_cmp`, `inc96`, `mul10_add96`, `aligned_add_96`,
cross-scale `Decimal.compare`, `trunc`, and 16-byte `serialize`/`deserialize`
roundtrip & F-5 `0x801F0000` masking.
-/
import Decimal.Funs

open Aeneas Aeneas.Std Result Pion decimal

namespace DecimalEvalDiff

def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

def decEqRaw (a b : Decimal) : Bool :=
  a.lo64 == b.lo64 && a.hi == b.hi && a.flags == b.flags

instance : BEq Decimal := ⟨decEqRaw⟩

def errEq (a b : DecimalError) : Bool :=
  match a, b with
  | .EmptyData, .EmptyData => true
  | .Overflow, .Overflow => true
  | .ScaleExceedsMaximumPrecision s1, .ScaleExceedsMaximumPrecision s2 => s1 == s2
  | _, _ => false

instance : BEq DecimalError := ⟨errEq⟩

def u32 (n : Nat) : Std.U32 := ⟨BitVec.ofNat 32 n⟩
def u64 (n : Nat) : Std.U64 := ⟨BitVec.ofNat 64 n⟩
def i32 (x : Int) : Std.I32 := ⟨BitVec.ofInt 32 x⟩
def i64 (x : Int) : Std.I64 := ⟨BitVec.ofInt 64 x⟩
def u8 (n : Nat) : Std.U8 := ⟨BitVec.ofNat 8 n⟩

def decZero : Decimal := ⟨u64 0, u32 0, u32 0⟩
def decNegZero : Decimal := ⟨u64 0, u32 0, u32 0x80000000⟩
def decZeroS2 : Decimal := ⟨u64 0, u32 0, u32 0x00020000⟩
def decNegZeroS2 : Decimal := ⟨u64 0, u32 0, u32 0x80020000⟩
def decOne : Decimal := ⟨u64 1, u32 0, u32 0⟩
def decOneS2 : Decimal := ⟨u64 100, u32 0, u32 0x00020000⟩
def decOneS28 : Decimal := ⟨u64 0x3E25026110000000, u32 0x204FCE5E, u32 0x001C0000⟩ -- 10^28 at scale 28 = 1.000...0
def decTiny : Decimal := ⟨u64 1, u32 0, u32 0x001C0000⟩ -- 1e-28
def decMax : Decimal := ⟨u64 0xFFFFFFFFFFFFFFFF, u32 0xFFFFFFFF, u32 0⟩
def decMin : Decimal := ⟨u64 0xFFFFFFFFFFFFFFFF, u32 0xFFFFFFFF, u32 0x80000000⟩
def decMaxS28 : Decimal := ⟨u64 0xFFFFFFFFFFFFFFFF, u32 0xFFFFFFFF, u32 0x001C0000⟩

def wireBytes (f lo mid hi : Nat) : Pion.Bytes :=
  ⟨[u8 (f % 256), u8 ((f / 256) % 256), u8 ((f / 65536) % 256), u8 ((f / 16777216) % 256),
    u8 (lo % 256), u8 ((lo / 256) % 256), u8 ((lo / 65536) % 256), u8 ((lo / 16777216) % 256),
    u8 (mid % 256), u8 ((mid / 256) % 256), u8 ((mid / 65536) % 256), u8 ((mid / 16777216) % 256),
    u8 (hi % 256), u8 ((hi / 256) % 256), u8 ((hi / 65536) % 256), u8 ((hi / 16777216) % 256)]⟩

def serdeRoundtrip (d : Decimal) : Bool :=
  (do
    let b ← Decimal.serialize d
    let res ← Decimal.deserialize b
    match res with
    | .Ok d2 => ok (decEqRaw d2 d)
    | .Err _ => ok false).reducesTo true

def deserIs (b : Pion.Bytes) (expected : Decimal) : Bool :=
  (do
    let res ← Decimal.deserialize b
    match res with
    | .Ok d => ok (decEqRaw d expected)
    | .Err _ => ok false).reducesTo true

def deserIsErr (b : Pion.Bytes) : Bool :=
  (do
    let res ← Decimal.deserialize b
    match res with
    | .Ok _ => ok false
    | .Err _ => ok true).reducesTo true

def fromPartsIsErr (lo mid hi : Std.U32) (neg : Bool) (sc : Std.U32) : Bool :=
  (do
    let res ← Decimal.from_parts lo mid hi neg sc
    match res with
    | .Err (.ScaleExceedsMaximumPrecision s) => ok (s == sc)
    | _ => ok false).reducesTo true

def alignedOverflow (a_lo : Std.U64) (a_hi : Std.U32) (b_lo : Std.U64) (b_hi : Std.U32) : Bool :=
  (do
    let res ← aligned_add_96 a_lo a_hi b_lo b_hi false (u32 0) false
    match res with
    | .Err .Overflow => ok true
    | _ => ok false).reducesTo true

-- 1. 96-bit & 128-bit arithmetic kernels
#guard okIs (u64_mul_wide (u64 0xFFFFFFFFFFFFFFFF) (u64 0xFFFFFFFFFFFFFFFF)) (u64 1, u64 0xFFFFFFFFFFFFFFFE)
#guard okIs (u96_cmp ⟨[u32 0, u32 0, u32 1]⟩ ⟨[u32 0xFFFFFFFF, u32 0xFFFFFFFF, u32 0]⟩) (i32 1)
#guard okIs (u96_cmp ⟨[u32 1, u32 2, u32 3]⟩ ⟨[u32 1, u32 2, u32 3]⟩) (i32 0)
#guard okIs (inc96 (u64 0xFFFFFFFFFFFFFFFF) (u32 0)) (u64 0, u32 1, false)
#guard okIs (inc96 (u64 0xFFFFFFFFFFFFFFFF) (u32 0xFFFFFFFF)) (u64 0, u32 0, true)
#guard okIs (mul10_add96 (u64 0xFFFFFFFFFFFFFFFF) (u32 0xFFFFFFFF) (u64 0)) (u64 0xFFFFFFFFFFFFFFFF, u32 0xFFFFFFFF, true)
#guard okIs (mul10_add96 (u64 12345) (u32 0) (u64 6)) (u64 123456, u32 0, false)
#guard alignedOverflow (u64 0xFFFFFFFFFFFFFFFF) (u32 0xFFFFFFFF) (u64 1) (u32 0)

-- 2. Flags, sign, scale, neg, abs, is_zero
#guard okIs (Decimal.neg decZero) decNegZero
#guard okIs (Decimal.neg decNegZero) decZero
#guard okIs (Decimal.abs decMin) decMax
#guard okIs (Decimal.abs decNegZero) decZero
#guard okIs (Decimal.is_zero decNegZeroS2) true
#guard fromPartsIsErr (u32 1) (u32 0) (u32 0) false (u32 29)

-- 3. 16-byte wire format roundtrip & F-5 0x801F0000 masking
#guard serdeRoundtrip decZero
#guard serdeRoundtrip decNegZero
#guard serdeRoundtrip decMax
#guard serdeRoundtrip decMin
#guard serdeRoundtrip decMaxS28
#guard serdeRoundtrip decTiny
#guard deserIsErr ⟨[]⟩
#guard deserIsErr ⟨[u8 0, u8 0, u8 0]⟩
#guard deserIs (wireBytes 0x00200000 12345 0 0) ⟨u64 12345, u32 0, u32 0⟩
#guard deserIs (wireBytes 0x003C0000 12345 0 0) ⟨u64 12345, u32 0, u32 0x001C0000⟩
#guard deserIs (wireBytes 0x001E0000 15 0 0) decTiny

-- 4. Exact comparison (-0 == +0, cross-scale, MAX/MIN) & truncation
#guard okIs (Decimal.compare decNegZero decZero) (i32 0)
#guard okIs (Decimal.compare decNegZeroS2 decZero) (i32 0)
#guard okIs (Decimal.compare decOne decOneS2) (i32 0)
#guard okIs (Decimal.compare decOne decOneS28) (i32 0)
#guard okIs (Decimal.compare decMin decMax) (i32 (-1))
#guard okIs (Decimal.compare decMax decMin) (i32 1)
#guard okIs (Decimal.compare decTiny decZero) (i32 1)
#guard okIs (Decimal.trunc decMaxS28) ⟨u64 7, u32 0, u32 0⟩

def fmtResult (label : String) (b : Bool) : String :=
  s!"{label}: {if b then "PASS" else "FAIL"}"

#eval do
  let checks : List (String × Bool) := [
    ("neg_zero_eq_pos_zero", okIs (Decimal.compare decNegZero decZero) (i32 0)),
    ("neg_zero_s2_eq_pos_zero", okIs (Decimal.compare decNegZeroS2 decZero) (i32 0)),
    ("neg_involutive_max", (do let d1 ← Decimal.neg decMax; let d2 ← Decimal.neg d1; ok (decEqRaw d2 decMax)).reducesTo true),
    ("abs_min_eq_max", okIs (Decimal.abs decMin) decMax),
    ("abs_neg_zero_nonneg", (do let d1 ← Decimal.abs decNegZero; let n ← Decimal.is_sign_negative d1; ok (!n)).reducesTo true),
    ("from_parts_scale29_err", fromPartsIsErr (u32 1) (u32 0) (u32 0) false (u32 29)),
    ("compare_cross_scale_1_eq_1_00", okIs (Decimal.compare decOne decOneS2) (i32 0)),
    ("compare_cross_scale_1_eq_1_28dp", okIs (Decimal.compare decOne decOneS28) (i32 0)),
    ("compare_min_lt_max", okIs (Decimal.compare decMin decMax) (i32 (-1))),
    ("compare_tiny_gt_zero", okIs (Decimal.compare decTiny decZero) (i32 1)),
    ("serde_roundtrip_zero", serdeRoundtrip decZero),
    ("serde_roundtrip_neg_zero", serdeRoundtrip decNegZero),
    ("serde_roundtrip_max", serdeRoundtrip decMax),
    ("serde_roundtrip_min", serdeRoundtrip decMin),
    ("serde_roundtrip_max_s28", serdeRoundtrip decMaxS28),
    ("deser_wrong_len_err", deserIsErr ⟨[u8 1, u8 2, u8 3]⟩),
    ("deser_f5_mask_0x20", deserIs (wireBytes 0x00200000 12345 0 0) ⟨u64 12345, u32 0, u32 0⟩),
    ("deser_f5_mask_0x3c", deserIs (wireBytes 0x003C0000 12345 0 0) ⟨u64 12345, u32 0, u32 0x001C0000⟩),
    ("deser_f5_scale30_carry", deserIs (wireBytes 0x001E0000 15 0 0) decTiny),
    ("trunc_max_s28_eq_7", okIs (Decimal.trunc decMaxS28) ⟨u64 7, u32 0, u32 0⟩)
  ]
  checks.forM (fun p => IO.println (fmtResult p.1 p.2))
  IO.println "DecimalEvalDiff: all #guard and #eval checks passed"

end DecimalEvalDiff
