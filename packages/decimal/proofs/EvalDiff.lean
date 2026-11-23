import Decimal.Funs

open Aeneas Aeneas.Std Result Pion decimal

namespace DecimalEvalDiff

private def u32 (n : Nat) : Std.U32 := ⟨BitVec.ofNat 32 n⟩
private def u64 (n : Nat) : Std.U64 := ⟨BitVec.ofNat 64 n⟩
private def u8 (n : Nat) : Std.U8 := ⟨BitVec.ofNat 8 n⟩

private def decZero : Decimal := ⟨u64 0, u32 0, u32 0⟩
private def decNegZero : Decimal := ⟨u64 0, u32 0, u32 0x80000000⟩
private def decNegZeroS2 : Decimal := ⟨u64 0, u32 0, u32 0x80020000⟩
private def decOne : Decimal := ⟨u64 1, u32 0, u32 0⟩
private def decOneS2 : Decimal := ⟨u64 100, u32 0, u32 0x00020000⟩
private def decOneS28 : Decimal := ⟨u64 0x3E25026110000000, u32 0x204FCE5E, u32 0x001C0000⟩
private def decTiny : Decimal := ⟨u64 1, u32 0, u32 0x001C0000⟩
private def decMax : Decimal := ⟨u64 0xFFFFFFFFFFFFFFFF, u32 0xFFFFFFFF, u32 0⟩
private def decMin : Decimal := ⟨u64 0xFFFFFFFFFFFFFFFF, u32 0xFFFFFFFF, u32 0x80000000⟩
private def decMaxS28 : Decimal := ⟨u64 0xFFFFFFFFFFFFFFFF, u32 0xFFFFFFFF, u32 0x001C0000⟩

private def wireBytes (f lo mid hi : Nat) : Pion.Bytes :=
  ⟨[u8 (f % 256), u8 ((f / 256) % 256), u8 ((f / 65536) % 256), u8 ((f / 16777216) % 256),
    u8 (lo % 256), u8 ((lo / 256) % 256), u8 ((lo / 65536) % 256), u8 ((lo / 16777216) % 256),
    u8 (mid % 256), u8 ((mid / 256) % 256), u8 ((mid / 65536) % 256), u8 ((mid / 16777216) % 256),
    u8 (hi % 256), u8 ((hi / 256) % 256), u8 ((hi / 65536) % 256), u8 ((hi / 16777216) % 256)]⟩

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtDec (d : Decimal) : String :=
  s!"({d.lo64.val},{d.hi.val},{d.flags.val})"

private def fmtDecR (r : Result Decimal) : String :=
  match r.match with | .ok d => fmtDec d | _ => "TRAP"

private def fmtDecRes (r : Result (Pion.Res Decimal DecimalError)) : String :=
  match r.match with
  | .ok (.Ok d) => s!"Ok{fmtDec d}"
  | .ok (.Err .EmptyData) => "Err(EmptyData)"
  | .ok (.Err .Overflow) => "Err(Overflow)"
  | .ok (.Err (.ScaleExceedsMaximumPrecision s)) => s!"Err(Scale:{s.val})"
  | .ok (.Err _) => "Err(Other)"
  | _ => "TRAP"

private def serdeRt (d : Decimal) : Result (Pion.Res Decimal DecimalError) := do
  let b ← Decimal.serialize d
  Decimal.deserialize b

private def runAll : List String :=
  [ s!"cmp_nz_z={fmtI32 (Decimal.compare decNegZero decZero)}"
  , s!"cmp_nzs2_z={fmtI32 (Decimal.compare decNegZeroS2 decZero)}"
  , s!"cmp_1_1s2={fmtI32 (Decimal.compare decOne decOneS2)}"
  , s!"cmp_1_1s28={fmtI32 (Decimal.compare decOne decOneS28)}"
  , s!"cmp_min_max={fmtI32 (Decimal.compare decMin decMax)}"
  , s!"cmp_max_min={fmtI32 (Decimal.compare decMax decMin)}"
  , s!"cmp_tiny_z={fmtI32 (Decimal.compare decTiny decZero)}"
  , s!"neg_z={fmtDecR (Decimal.neg decZero)}"
  , s!"neg_nz={fmtDecR (Decimal.neg decNegZero)}"
  , s!"abs_min={fmtDecR (Decimal.abs decMin)}"
  , s!"abs_nz={fmtDecR (Decimal.abs decNegZero)}"
  , s!"is_zero_nzs2={fmtBool (Decimal.is_zero decNegZeroS2)}"
  , s!"is_zero_tiny={fmtBool (Decimal.is_zero decTiny)}"
  , s!"from_parts_ok={fmtDecRes (Decimal.from_parts (u32 42) (u32 0) (u32 0) true (u32 2))}"
  , s!"from_parts_s29={fmtDecRes (Decimal.from_parts (u32 1) (u32 0) (u32 0) false (u32 29))}"
  , s!"set_scale_ok={fmtDecRes (Decimal.set_scale decOne (u32 4))}"
  , s!"set_scale_s29={fmtDecRes (Decimal.set_scale decOne (u32 29))}"
  , s!"trunc_max_s28={fmtDecR (Decimal.trunc decMaxS28)}"
  , s!"serde_z={fmtDecRes (serdeRt decZero)}"
  , s!"serde_nz={fmtDecRes (serdeRt decNegZero)}"
  , s!"serde_max={fmtDecRes (serdeRt decMax)}"
  , s!"serde_min={fmtDecRes (serdeRt decMin)}"
  , s!"serde_max_s28={fmtDecRes (serdeRt decMaxS28)}"
  , s!"deser_short={fmtDecRes (Decimal.deserialize ⟨[u8 1, u8 2, u8 3]⟩)}"
  , s!"deser_f5_20={fmtDecRes (Decimal.deserialize (wireBytes 0x00200000 12345 0 0))}"
  , s!"deser_f5_3c={fmtDecRes (Decimal.deserialize (wireBytes 0x003C0000 12345 0 0))}"
  , s!"deser_f5_30={fmtDecRes (Decimal.deserialize (wireBytes 0x001E0000 15 0 0))}"
  ]

#eval IO.println (String.intercalate "\n" runAll)

end DecimalEvalDiff
