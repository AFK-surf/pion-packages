import Uuid.Funs

open Aeneas Aeneas.Std Result Pion uuid

namespace UuidEvalDiff

private def u64 (n : Nat) : Std.U64 := ⟨BitVec.ofNat 64 n⟩
private def i64 (n : Int) : Std.I64 := ⟨BitVec.ofInt 64 n⟩
private def i32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
private def maxTs48 : Std.I64 := i64 281474976710655

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtI64 (r : Result Std.I64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def versionTag : UuidVersion → String
  | .Nil => "Nil" | .Mac => "Mac" | .Dce => "Dce" | .Md5 => "Md5"
  | .Random => "Random" | .Sha1 => "Sha1" | .SortMac => "SortMac"
  | .SortRand => "SortRand" | .Custom => "Custom" | .Max => "Max"
  | .Unknown n => s!"Unknown({n.val})"

private def variantTag : UuidVariant → String
  | .Ncs => "Ncs" | .Rfc4122 => "Rfc4122" | .Microsoft => "Microsoft" | .Future => "Future"

private def fmtVer (r : Result UuidVersion) : String :=
  match r.match with | .ok v => versionTag v | _ => "TRAP"

private def fmtVar (r : Result UuidVariant) : String :=
  match r.match with | .ok v => variantTag v | _ => "TRAP"

private def fmtV7Ts (ts : Std.I64) (ra : Std.I32) (rb : Std.I64) : String :=
  match (Uuid.new_v7_from_parts ts ra rb).match with
  | .ok (.Ok u) =>
    match (Uuid.timestamp_ms u).match with
    | .ok (some t) => s!"Ok({t.val})"
    | .ok none => "Ok(None)"
    | _ => "TRAP"
  | .ok (.Err _) => "Err"
  | _ => "TRAP"

private def fmtUlidParts (ts rhi rlo : Std.I64) : String :=
  match (Ulid.from_parts ts rhi rlo).match with
  | .ok (.Ok u) =>
    match (Ulid.timestamp_ms u).match with
    | .ok t => s!"Ok({t.val})"
    | _ => "TRAP"
  | .ok (.Err _) => "Err"
  | _ => "TRAP"

private def fmtUlidInc (ts rhi rlo : Std.I64) : String :=
  match (Ulid.from_parts ts rhi rlo).match with
  | .ok (.Ok u) =>
    match (Ulid.increment u).match with
    | .ok (.Ok u') =>
      match (Ulid.timestamp_ms u').match, (Ulid.compare u u').match with
      | .ok t, .ok c => s!"Ok({t.val},{c.val})"
      | _, _ => "TRAP"
    | .ok (.Err _) => "Err"
    | _ => "TRAP"
  | _ => "TRAP"

private def runAll : List String :=
  [ s!"nil_max_cmp={fmtI32 (do let a ← Uuid.nil; let b ← Uuid.max; Uuid.compare a b)}"
  , s!"max_nil_cmp={fmtI32 (do let a ← Uuid.max; let b ← Uuid.nil; Uuid.compare a b)}"
  , s!"sign_bnd_cmp={fmtI32 (do let a ← Uuid.from_u64_pair (u64 0x7FFFFFFFFFFFFFFF) (u64 0xFFFFFFFFFFFFFFFF); let b ← Uuid.from_u64_pair (u64 0x8000000000000000) (u64 0); Uuid.compare a b)}"
  , s!"nil_ver={fmtVer (do let u ← Uuid.nil; Uuid.version u)}"
  , s!"max_ver={fmtVer (do let u ← Uuid.max; Uuid.version u)}"
  , s!"v7_ver={fmtVer (do let r ← Uuid.new_v7_from_parts (i64 1000) (i32 0xFFF) (i64 (-1)); match r with | .Ok u => Uuid.version u | .Err _ => ok .Nil)}"
  , s!"v7_var={fmtVar (do let r ← Uuid.new_v7_from_parts (i64 1000) (i32 0xFFF) (i64 (-1)); match r with | .Ok u => Uuid.variant u | .Err _ => ok .Ncs)}"
  , s!"v7_ts0={fmtV7Ts (i64 0) (i32 0) (i64 0)}"
  , s!"v7_tsmax={fmtV7Ts maxTs48 (i32 0xFFF) (i64 (-1))}"
  , s!"v7_bad={fmtV7Ts (i64 (-1)) (i32 0) (i64 0)}"
  , s!"ulid_ts0={fmtUlidParts (i64 0) (i64 0) (i64 0)}"
  , s!"ulid_tsmax={fmtUlidParts maxTs48 (i64 0xFFFF) (i64 (-1))}"
  , s!"ulid_neg={fmtUlidParts (i64 (-1)) (i64 0) (i64 0)}"
  , s!"ulid_over={fmtUlidParts (i64 281474976710656) (i64 0) (i64 0)}"
  , s!"ulid_inc_ok={fmtUlidInc (i64 42) (i64 0x0001) (i64 (-1))}"
  , s!"ulid_inc_ovf={fmtUlidInc (i64 42) (i64 0xFFFF) (i64 (-1))}"
  , s!"nil_is_nil={fmtBool (do let u ← Uuid.nil; Uuid.is_nil u)}"
  , s!"max_is_max={fmtBool (do let u ← Uuid.max; Uuid.is_max u)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)

end UuidEvalDiff
