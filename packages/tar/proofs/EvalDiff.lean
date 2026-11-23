/-
Executable sanity checks (`#guard` and `#eval`) on the extracted `Tar.Funs`
functions, plus structured output cross-checked against Pion native execution
by `packages/tar/proofs/run_proofs.sh`.
-/
import Tar.Funs

open Aeneas Aeneas.Std Result Pion tar

namespace TarEvalDiff

def i32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
def i64 (n : Int) : Std.I64 := ⟨BitVec.ofInt 64 n⟩
def u8 (n : Nat) : Std.U8 := ⟨BitVec.ofNat 8 n⟩

def maxI64 : Std.I64 := i64 9223372036854775807
def minI64 : Std.I64 := i64 (-9223372036854775808)

def strBytes (s : String) : Pion.Bytes :=
  ⟨s.toUTF8.toList.map (fun b => u8 b.toNat)⟩

def hexDigit (c : Char) : Nat :=
  if '0' ≤ c ∧ c ≤ '9' then c.toNat - '0'.toNat
  else if 'a' ≤ c ∧ c ≤ 'f' then c.toNat - 'a'.toNat + 10
  else c.toNat - 'A'.toNat + 10

def hexBytes (s : String) : Pion.Bytes :=
  let rec go : List Char → List Std.U8
    | a :: b :: rest => u8 (hexDigit a * 16 + hexDigit b) :: go rest
    | _ => []
  ⟨go s.toList⟩

def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

def parseOkEq (b : Pion.Bytes) (want : Std.I64) : Bool :=
  (do
    let res ← parse_numeric b
    match res with
    | .Ok v => ok (v == want)
    | .Err _ => ok false).reducesTo true

def parseIsErr (b : Pion.Bytes) : Bool :=
  (do
    let res ← parse_numeric b
    match res with
    | .Ok _ => ok false
    | .Err _ => ok true).reducesTo true

def roundtripEq (width : Int) (x : Std.I64) : Bool :=
  (do
    let res ← format_numeric (i32 width) x
    match res with
    | .Ok b =>
      let res2 ← parse_numeric b
      match res2 with
      | .Ok v => ok (v == x)
      | .Err _ => ok false
    | .Err _ => ok false).reducesTo true

-- 1. Zip-Slip & extraction path safety
#guard okIs (validate_extract_path_bytes (strBytes "a/b/c.txt")) true
#guard okIs (validate_extract_path_bytes (strBytes "a..b/.../c")) true
#guard okIs (validate_extract_path_bytes (strBytes "")) false
#guard okIs (validate_extract_path_bytes (strBytes ".")) false
#guard okIs (validate_extract_path_bytes (strBytes "../etc/passwd")) false
#guard okIs (validate_extract_path_bytes (strBytes "a/b/../c")) false
#guard okIs (validate_extract_path_bytes (strBytes "a\\..\\b")) false
#guard okIs (validate_extract_path_bytes (strBytes "/etc/passwd")) false
#guard okIs (validate_extract_path_bytes (strBytes "\\etc\\passwd")) false
#guard okIs (validate_extract_path_bytes (strBytes "C:/Windows/win.ini")) false
#guard okIs (validate_extract_path_bytes (strBytes "file.txt::$DATA")) false
#guard okIs (validate_extract_path_bytes (hexBytes "666f6f00626172")) false
#guard okIs (validate_extract_path_bytes (strBytes "dir/con.txt")) false
#guard okIs (validate_extract_path_bytes (strBytes "COM1")) false
#guard okIs (validate_extract_path_bytes (strBytes "x/lpt9.bin")) false

-- 2. 512-byte block alignment
#guard okIs (padded_size (i64 0)) (i64 0)
#guard okIs (padded_size (i64 1)) (i64 512)
#guard okIs (padded_size (i64 512)) (i64 512)
#guard okIs (padded_size (i64 513)) (i64 1024)
#guard okIs (padded_size (i64 9223372036854775296)) (i64 9223372036854775296)

-- 3. Octal & GNU base-256 numeric parsing / formatting / roundtrip
#guard okIs (fits_in_octal (i32 12) (i64 (-1))) false
#guard okIs (fits_in_octal (i32 8) (i64 2097151)) true
#guard okIs (fits_in_octal (i32 8) (i64 2097152)) false
#guard okIs (fits_in_base256 (i32 9) maxI64) true
#guard okIs (fits_in_base256 (i32 9) minI64) true
#guard parseOkEq (hexBytes "3030303036343400") (i64 420)
#guard parseIsErr (hexBytes "3030303036343800")
#guard parseIsErr (strBytes "7777777777777777777777")
#guard parseOkEq (hexBytes "807fffffffffffffff") maxI64
#guard parseOkEq (hexBytes "ff8000000000000000") minI64
#guard parseIsErr (hexBytes "808000000000000000")
#guard parseIsErr (hexBytes "ff7fffffffffffffff")
#guard roundtripEq 12 (i64 8589934591)
#guard roundtripEq 12 maxI64
#guard roundtripEq 12 minI64
#guard roundtripEq 8 (i64 (-1))

-- 4. Typeflags & TarFormat
#guard okIs (do let t ← type_dir; is_header_only_type t) true
#guard okIs (do let t ← type_reg; is_header_only_type t) false
#guard okIs (format_equals .Pax .Pax) true
#guard okIs (format_equals .Ustar .Gnu) false

def fmtResult (label : String) (b : Bool) : String :=
  s!"{label}: {if b then "PASS" else "FAIL"}"

#eval do
  let checks : List (String × Bool) := [
    ("path_valid_simple", okIs (validate_extract_path_bytes (strBytes "a/b/c.txt")) true),
    ("path_valid_dots_in_name", okIs (validate_extract_path_bytes (strBytes "a..b/.../c")) true),
    ("path_reject_empty", okIs (validate_extract_path_bytes (strBytes "")) false),
    ("path_reject_dot", okIs (validate_extract_path_bytes (strBytes ".")) false),
    ("path_reject_dotdot", okIs (validate_extract_path_bytes (strBytes "../etc/passwd")) false),
    ("path_reject_mid_dotdot", okIs (validate_extract_path_bytes (strBytes "a/b/../c")) false),
    ("path_reject_win_dotdot", okIs (validate_extract_path_bytes (strBytes "a\\..\\b")) false),
    ("path_reject_abs_unix", okIs (validate_extract_path_bytes (strBytes "/etc/passwd")) false),
    ("path_reject_abs_win", okIs (validate_extract_path_bytes (strBytes "\\etc\\passwd")) false),
    ("path_reject_drive", okIs (validate_extract_path_bytes (strBytes "C:/Windows/win.ini")) false),
    ("path_reject_ads", okIs (validate_extract_path_bytes (strBytes "file.txt::$DATA")) false),
    ("path_reject_nul", okIs (validate_extract_path_bytes (hexBytes "666f6f00626172")) false),
    ("path_reject_con", okIs (validate_extract_path_bytes (strBytes "dir/con.txt")) false),
    ("path_reject_com1", okIs (validate_extract_path_bytes (strBytes "COM1")) false),
    ("path_reject_lpt9", okIs (validate_extract_path_bytes (strBytes "x/lpt9.bin")) false),
    ("padded_zero", okIs (padded_size (i64 0)) (i64 0)),
    ("padded_1", okIs (padded_size (i64 1)) (i64 512)),
    ("padded_512", okIs (padded_size (i64 512)) (i64 512)),
    ("padded_513", okIs (padded_size (i64 513)) (i64 1024)),
    ("padded_max_safe", okIs (padded_size (i64 9223372036854775296)) (i64 9223372036854775296)),
    ("fits_octal_neg_false", okIs (fits_in_octal (i32 12) (i64 (-1))) false),
    ("fits_octal_8_max", okIs (fits_in_octal (i32 8) (i64 2097151)) true && okIs (fits_in_octal (i32 8) (i64 2097152)) false),
    ("fits_b256_9_extremes", okIs (fits_in_base256 (i32 9) maxI64) true && okIs (fits_in_base256 (i32 9) minI64) true),
    ("parse_octal_0644", parseOkEq (hexBytes "3030303036343400") (i64 420)),
    ("parse_octal_bad_digit", parseIsErr (hexBytes "3030303036343800")),
    ("parse_octal_overflow", parseIsErr (strBytes "7777777777777777777777")),
    ("parse_b256_max", parseOkEq (hexBytes "807fffffffffffffff") maxI64),
    ("parse_b256_min", parseOkEq (hexBytes "ff8000000000000000") minI64),
    ("parse_b256_overflow_pos", parseIsErr (hexBytes "808000000000000000")),
    ("parse_b256_overflow_neg", parseIsErr (hexBytes "ff7fffffffffffffff")),
    ("roundtrip_octal_12", roundtripEq 12 (i64 8589934591)),
    ("roundtrip_b256_12_max", roundtripEq 12 maxI64),
    ("roundtrip_b256_12_min", roundtripEq 12 minI64),
    ("roundtrip_b256_8_neg1", roundtripEq 8 (i64 (-1))),
    ("type_dir_header_only", okIs (do let t ← type_dir; is_header_only_type t) true),
    ("type_reg_not_header_only", okIs (do let t ← type_reg; is_header_only_type t) false),
    ("format_eq_refl", okIs (format_equals .Pax .Pax) true),
    ("format_eq_ne", okIs (format_equals .Ustar .Gnu) false)
  ]
  checks.forM (fun p => IO.println (fmtResult p.1 p.2))
  IO.println "TarEvalDiff: all #guard and #eval checks passed"

end TarEvalDiff
