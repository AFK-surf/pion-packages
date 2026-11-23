import Tar.Funs

open Aeneas Aeneas.Std Result Pion tar

namespace TarEvalDiff

private def i32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
private def i64 (n : Int) : Std.I64 := ⟨BitVec.ofInt 64 n⟩
private def u8 (n : Nat) : Std.U8 := ⟨BitVec.ofNat 8 n⟩
private def maxI64 : Std.I64 := i64 9223372036854775807
private def minI64 : Std.I64 := i64 (-9223372036854775808)

private def strBytes (s : String) : Pion.Bytes :=
  ⟨s.toUTF8.toList.map (fun b => u8 b.toNat)⟩

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI64 (r : Result Std.I64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtBytesLenRes (r : Result (Pion.Res Pion.Bytes TarError)) : String :=
  match r.match with
  | .ok (.Ok b) => s!"Ok(len={b.val.length})"
  | .ok (.Err _) => "Err"
  | _ => "TRAP"

private def runAll : List String :=
  [ s!"path_ok={fmtBool (validate_extract_path_bytes (strBytes "a/b/c.txt"))}"
  , s!"path_dots={fmtBool (validate_extract_path_bytes (strBytes "a..b/.../c"))}"
  , s!"path_empty={fmtBool (validate_extract_path_bytes (strBytes ""))}"
  , s!"path_dot={fmtBool (validate_extract_path_bytes (strBytes "."))}"
  , s!"path_dotdot={fmtBool (validate_extract_path_bytes (strBytes "../etc/passwd"))}"
  , s!"path_mid_dd={fmtBool (validate_extract_path_bytes (strBytes "a/b/../c"))}"
  , s!"path_abs={fmtBool (validate_extract_path_bytes (strBytes "/etc/passwd"))}"
  , s!"path_drive={fmtBool (validate_extract_path_bytes (strBytes "C:/Windows/win.ini"))}"
  , s!"path_ads={fmtBool (validate_extract_path_bytes (strBytes "file.txt::$DATA"))}"
  , s!"path_con={fmtBool (validate_extract_path_bytes (strBytes "dir/con.txt"))}"
  , s!"path_com1={fmtBool (validate_extract_path_bytes (strBytes "COM1"))}"
  , s!"pad_0={fmtI64 (padded_size (i64 0))}"
  , s!"pad_1={fmtI64 (padded_size (i64 1))}"
  , s!"pad_512={fmtI64 (padded_size (i64 512))}"
  , s!"pad_513={fmtI64 (padded_size (i64 513))}"
  , s!"pad_max={fmtI64 (padded_size (i64 9223372036854775296))}"
  , s!"oct_neg={fmtBool (fits_in_octal (i32 12) (i64 (-1)))}"
  , s!"oct_8_ok={fmtBool (fits_in_octal (i32 8) (i64 2097151))}"
  , s!"oct_8_hi={fmtBool (fits_in_octal (i32 8) (i64 2097152))}"
  , s!"b256_max={fmtBool (fits_in_base256 (i32 9) maxI64)}"
  , s!"b256_min={fmtBool (fits_in_base256 (i32 9) minI64)}"
  , s!"fmt_12_ok={fmtBytesLenRes (format_numeric (i32 12) (i64 8589934591))}"
  , s!"fmt_12_max={fmtBytesLenRes (format_numeric (i32 12) maxI64)}"
  , s!"fmt_12_min={fmtBytesLenRes (format_numeric (i32 12) minI64)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)

end TarEvalDiff
