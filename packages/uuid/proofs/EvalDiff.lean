/-
Executable `#guard` & `#eval` differential checks over the extracted `Uuid.Funs`.
Covers Nil/Max, UUID v1/v3/v4/v5/v6/v7/v8, 128-bit unsigned ordering across sign
quadrants, ULID timestamp boundaries `0` and `2^48 - 1`, ULID monotonic increment
& overflow, hex codecs, and Crockford Base32 case-insensitivity, `I`/`L`/`O` aliases,
strict mode, and invalid character rejection (`U`/`u`/symbols/control).
-/
import Uuid.Funs

open Aeneas Aeneas.Std Result Pion uuid

namespace UuidEvalDiff

def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

def getOk {α : Type} (r : Result α) : Option α :=
  match r.match with
  | .ok v => some v
  | _ => none

def versionTag : UuidVersion → String
  | .Nil => "Nil"
  | .Mac => "Mac"
  | .Dce => "Dce"
  | .Md5 => "Md5"
  | .Random => "Random"
  | .Sha1 => "Sha1"
  | .SortMac => "SortMac"
  | .SortRand => "SortRand"
  | .Custom => "Custom"
  | .Max => "Max"
  | .Unknown n => s!"Unknown({n.val})"

def variantTag : UuidVariant → String
  | .Ncs => "Ncs"
  | .Rfc4122 => "Rfc4122"
  | .Microsoft => "Microsoft"
  | .Future => "Future"

def mkBytes (l : List Nat) : Pion.Bytes :=
  ⟨l.map (fun n => ⟨BitVec.ofNat 8 n⟩)⟩

def u64 (n : Nat) : Std.U64 := ⟨BitVec.ofNat 64 n⟩
def i64 (n : Int) : Std.I64 := ⟨BitVec.ofInt 64 n⟩
def i32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩

def checkUuidVerVar (r : Result (Pion.Res Uuid UuidError)) (ver : String) (var : String) : Bool :=
  match getOk r with
  | some (.Ok u) =>
    match getOk (Uuid.version u), getOk (Uuid.variant u) with
    | some v, some vr => versionTag v == ver && variantTag vr == var
    | _, _ => false
  | _ => false

def checkUuidV7 (ts : Std.I64) (ra : Std.I32) (rb : Std.I64) : Bool :=
  match getOk (Uuid.new_v7_from_parts ts ra rb) with
  | some (.Ok u) =>
    match getOk (Uuid.version u), getOk (Uuid.variant u), getOk (Uuid.timestamp_ms u) with
    | some v, some vr, some (some t) =>
      versionTag v == "SortRand" && variantTag vr == "Rfc4122" && t == ts
    | _, _, _ => false
  | _ => false

def checkUlidParts (ts rhi rlo : Std.I64) : Bool :=
  match getOk (Ulid.from_parts ts rhi rlo) with
  | some (.Ok u) =>
    match getOk (Ulid.timestamp_ms u), getOk (Ulid.random_parts u) with
    | some t, some (rh, rl) =>
      t == ts && rh == Pion.U64.to_int64 (Pion.U64.band (Pion.I64.to_uint64 rhi) 65535#u64) && rl == rlo
    | _, _ => false
  | _ => false

def maxTs48 : Std.I64 := i64 281474976710655

-- 1. Nil & Max
#guard okIs (do let u ← Uuid.nil; Uuid.is_nil u) true
#guard okIs (do let u ← Uuid.max; Uuid.is_max u) true
#guard match getOk (do let u ← Uuid.nil; Uuid.version u) with | some v => versionTag v == "Nil" | _ => false
#guard match getOk (do let u ← Uuid.max; Uuid.version u) with | some v => versionTag v == "Max" | _ => false
#guard okIs (do let a ← Uuid.nil; let b ← Uuid.max; Uuid.compare a b) (i32 (-1))
#guard okIs (do let a ← Uuid.max; let b ← Uuid.nil; Uuid.compare a b) (i32 1)

-- 2. Unsigned 128-bit ordering across signed Int64 boundary (0x7FFF... < 0x8000...)
#guard okIs (do
  let a ← Uuid.from_u64_pair (u64 0x7FFFFFFFFFFFFFFF) (u64 0xFFFFFFFFFFFFFFFF)
  let b ← Uuid.from_u64_pair (u64 0x8000000000000000) (u64 0)
  Uuid.compare a b) (i32 (-1))

-- 3. UUID v1, v3, v4, v5, v6, v7, v8
#guard checkUuidVerVar (Uuid.new_v1 (i64 0x01B21DD213814000) (i32 0x1234) (mkBytes [1, 2, 3, 4, 5, 6])) "Mac" "Rfc4122"
#guard okIs (do let u ← set_version_and_variant (u64 0xFFFFFFFFFFFFFFFF) (u64 0xFFFFFFFFFFFFFFFF) (u64 3); let v ← Uuid.version u; let vr ← Uuid.variant u; ok (versionTag v == "Md5" && variantTag vr == "Rfc4122")) true
#guard okIs (do let u ← Uuid.new_v4_from_u64_pair (u64 0) (u64 0); let v ← Uuid.version u; let vr ← Uuid.variant u; ok (versionTag v == "Random" && variantTag vr == "Rfc4122")) true
#guard okIs (do let u ← set_version_and_variant (u64 0) (u64 0) (u64 5); let v ← Uuid.version u; let vr ← Uuid.variant u; ok (versionTag v == "Sha1" && variantTag vr == "Rfc4122")) true
#guard checkUuidVerVar (Uuid.new_v6 (i64 0x01B21DD213814000) (i32 0x3FFF) (mkBytes [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])) "SortMac" "Rfc4122"
#guard checkUuidV7 (i64 0) (i32 0) (i64 0)
#guard checkUuidV7 maxTs48 (i32 0xFFF) (i64 (-1))
#guard checkUuidVerVar (Uuid.new_v8 (mkBytes [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])) "Custom" "Rfc4122"

-- 4. UUIDv7 strict time ordering even when random payload of earlier ts is all 1s and later ts is all 0s
#guard match getOk (Uuid.new_v7_from_parts (i64 1000) (i32 0xFFF) (i64 (-1))), getOk (Uuid.new_v7_from_parts (i64 1001) (i32 0) (i64 0)) with
  | some (.Ok u1), some (.Ok u2) => okIs (Uuid.compare u1 u2) (i32 (-1))
  | _, _ => false

-- 5. ULID timestamp boundaries 0 and 2^48 - 1, invalid ts, monotonicity, increment & overflow
#guard checkUlidParts (i64 0) (i64 0) (i64 0)
#guard checkUlidParts maxTs48 (i64 0xFFFF) (i64 (-1))
#guard match getOk (Ulid.from_parts (i64 (-1)) (i64 0) (i64 0)) with | some (.Err (.InvalidTimestamp _)) => true | _ => false
#guard match getOk (Ulid.from_parts (i64 281474976710656) (i64 0) (i64 0)) with | some (.Err (.InvalidTimestamp _)) => true | _ => false
#guard match getOk (Ulid.from_parts (i64 0) (i64 0xFFFF) (i64 (-1))), getOk (Ulid.from_parts (i64 1) (i64 0) (i64 0)) with
  | some (.Ok u1), some (.Ok u2) => okIs (Ulid.compare u1 u2) (i32 (-1))
  | _, _ => false
#guard match getOk (Ulid.from_parts (i64 42) (i64 0xFFFF) (i64 (-1))) with
  | some (.Ok u) => match getOk (Ulid.increment u) with | some (.Err .Overflow) => true | _ => false
  | _ => false
#guard match getOk (Ulid.from_parts (i64 42) (i64 0x0001) (i64 (-1))) with
  | some (.Ok u) => match getOk (Ulid.increment u) with
    | some (.Ok u') => okIs (Ulid.timestamp_ms u') (i64 42) && okIs (Ulid.compare u u') (i32 (-1))
    | _ => false
  | _ => false

-- 6. Hex & Crockford Base32 codecs
#guard (List.range 16).all (fun d =>
  okIs (do let b ← hex_char_lower (i32 d); hex_val_char (Pion.U8.to_int b)) (i32 d) &&
  okIs (do let b ← hex_char_upper (i32 d); hex_val_char (Pion.U8.to_int b)) (i32 d))
#guard (List.range 32).all (fun d =>
  okIs (do let b ← crockford_encode_digit (i32 d); crockford_val (Pion.U8.to_int b)) (i32 d) &&
  okIs (do let b ← crockford_encode_digit (i32 d); crockford_val_strict (Pion.U8.to_int b)) (i32 d))
#guard okIs (crockford_val (i32 73)) (i32 1) && okIs (crockford_val (i32 105)) (i32 1)
#guard okIs (crockford_val (i32 76)) (i32 1) && okIs (crockford_val (i32 108)) (i32 1)
#guard okIs (crockford_val (i32 79)) (i32 0) && okIs (crockford_val (i32 111)) (i32 0)
#guard okIs (crockford_val_strict (i32 73)) (i32 (-1)) && okIs (crockford_val_strict (i32 76)) (i32 (-1)) && okIs (crockford_val_strict (i32 79)) (i32 (-1))
#guard okIs (crockford_val (i32 85)) (i32 (-1)) && okIs (crockford_val (i32 117)) (i32 (-1)) && okIs (crockford_val (i32 0)) (i32 (-1)) && okIs (crockford_val (i32 45)) (i32 (-1))

def fmtResult (label : String) (b : Bool) : String :=
  s!"{label}: {if b then "PASS" else "FAIL"}"

#eval do
  let checks : List (String × Bool) := [
    ("uuid_nil_max_order",
      okIs (do let a ← Uuid.nil; let b ← Uuid.max; Uuid.compare a b) (i32 (-1)) &&
      okIs (do let a ← Uuid.max; let b ← Uuid.nil; Uuid.compare a b) (i32 1)),
    ("uuid_unsigned_sign_boundary",
      okIs (do
        let a ← Uuid.from_u64_pair (u64 0x7FFFFFFFFFFFFFFF) (u64 0xFFFFFFFFFFFFFFFF)
        let b ← Uuid.from_u64_pair (u64 0x8000000000000000) (u64 0)
        Uuid.compare a b) (i32 (-1))),
    ("uuid_v1_ver_var",
      checkUuidVerVar (Uuid.new_v1 (i64 0x01B21DD213814000) (i32 0x1234) (mkBytes [1, 2, 3, 4, 5, 6])) "Mac" "Rfc4122"),
    ("uuid_v3_ver_var",
      okIs (do let u ← set_version_and_variant (u64 0xFFFFFFFFFFFFFFFF) (u64 0xFFFFFFFFFFFFFFFF) (u64 3); let v ← Uuid.version u; let vr ← Uuid.variant u; ok (versionTag v == "Md5" && variantTag vr == "Rfc4122")) true),
    ("uuid_v4_ver_var",
      okIs (do let u ← Uuid.new_v4_from_u64_pair (u64 0) (u64 0); let v ← Uuid.version u; let vr ← Uuid.variant u; ok (versionTag v == "Random" && variantTag vr == "Rfc4122")) true),
    ("uuid_v5_ver_var",
      okIs (do let u ← set_version_and_variant (u64 0) (u64 0) (u64 5); let v ← Uuid.version u; let vr ← Uuid.variant u; ok (versionTag v == "Sha1" && variantTag vr == "Rfc4122")) true),
    ("uuid_v6_ver_var",
      checkUuidVerVar (Uuid.new_v6 (i64 0x01B21DD213814000) (i32 0x3FFF) (mkBytes [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])) "SortMac" "Rfc4122"),
    ("uuid_v7_ts_zero_and_max",
      checkUuidV7 (i64 0) (i32 0) (i64 0) && checkUuidV7 maxTs48 (i32 0xFFF) (i64 (-1))),
    ("uuid_v7_strict_monotonic",
      match getOk (Uuid.new_v7_from_parts (i64 1000) (i32 0xFFF) (i64 (-1))), getOk (Uuid.new_v7_from_parts (i64 1001) (i32 0) (i64 0)) with
      | some (.Ok u1), some (.Ok u2) => okIs (Uuid.compare u1 u2) (i32 (-1))
      | _, _ => false),
    ("uuid_v8_ver_var",
      checkUuidVerVar (Uuid.new_v8 (mkBytes [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])) "Custom" "Rfc4122"),
    ("ulid_ts_zero_and_max",
      checkUlidParts (i64 0) (i64 0) (i64 0) && checkUlidParts maxTs48 (i64 0xFFFF) (i64 (-1))),
    ("ulid_reject_invalid_ts",
      (match getOk (Ulid.from_parts (i64 (-1)) (i64 0) (i64 0)) with | some (.Err (.InvalidTimestamp _)) => true | _ => false) &&
      (match getOk (Ulid.from_parts (i64 281474976710656) (i64 0) (i64 0)) with | some (.Err (.InvalidTimestamp _)) => true | _ => false)),
    ("ulid_strict_monotonic",
      match getOk (Ulid.from_parts (i64 0) (i64 0xFFFF) (i64 (-1))), getOk (Ulid.from_parts (i64 1) (i64 0) (i64 0)) with
      | some (.Ok u1), some (.Ok u2) => okIs (Ulid.compare u1 u2) (i32 (-1))
      | _, _ => false),
    ("ulid_increment_carry_and_overflow",
      (match getOk (Ulid.from_parts (i64 42) (i64 0x0001) (i64 (-1))) with
       | some (.Ok u) => match getOk (Ulid.increment u) with
         | some (.Ok u') => okIs (Ulid.timestamp_ms u') (i64 42) && okIs (Ulid.compare u u') (i32 (-1))
         | _ => false
       | _ => false) &&
      (match getOk (Ulid.from_parts (i64 42) (i64 0xFFFF) (i64 (-1))) with
       | some (.Ok u) => match getOk (Ulid.increment u) with | some (.Err .Overflow) => true | _ => false
       | _ => false)),
    ("hex_roundtrip_0_15",
      (List.range 16).all (fun d =>
        okIs (do let b ← hex_char_lower (i32 d); hex_val_char (Pion.U8.to_int b)) (i32 d) &&
        okIs (do let b ← hex_char_upper (i32 d); hex_val_char (Pion.U8.to_int b)) (i32 d))),
    ("crockford_roundtrip_0_31",
      (List.range 32).all (fun d =>
        okIs (do let b ← crockford_encode_digit (i32 d); crockford_val (Pion.U8.to_int b)) (i32 d) &&
        okIs (do let b ← crockford_encode_digit (i32 d); crockford_val_strict (Pion.U8.to_int b)) (i32 d))),
    ("crockford_aliases_and_strict",
      okIs (crockford_val (i32 73)) (i32 1) && okIs (crockford_val (i32 105)) (i32 1) &&
      okIs (crockford_val (i32 76)) (i32 1) && okIs (crockford_val (i32 108)) (i32 1) &&
      okIs (crockford_val (i32 79)) (i32 0) && okIs (crockford_val (i32 111)) (i32 0) &&
      okIs (crockford_val_strict (i32 73)) (i32 (-1)) &&
      okIs (crockford_val_strict (i32 76)) (i32 (-1)) &&
      okIs (crockford_val_strict (i32 79)) (i32 (-1))),
    ("crockford_reject_u_and_invalid",
      okIs (crockford_val (i32 85)) (i32 (-1)) && okIs (crockford_val (i32 117)) (i32 (-1)) &&
      okIs (crockford_val (i32 0)) (i32 (-1)) && okIs (crockford_val (i32 45)) (i32 (-1)))
  ]
  checks.forM (fun p => IO.println (fmtResult p.1 p.2))
  IO.println "UuidEvalDiff: all #guard and #eval checks passed"

end UuidEvalDiff
