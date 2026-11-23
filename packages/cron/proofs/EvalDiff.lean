/-
Executable `#eval` / `#guard` differential test suite for extracted `Cron.Funs`.
Prints deterministic `name=value` lines that `run_proofs.sh` compares via `diff -u`
against the native Pion binary running the exact same inputs.
-/
import Cron.Funs
open Aeneas Aeneas.Std Result Pion cron

namespace CronEvalDiff

private def i32 (x : Int) : Std.I32 := ⟨BitVec.ofInt 32 x⟩
private def i64 (x : Int) : Std.I64 := ⟨BitVec.ofInt 64 x⟩
private def u64 (x : Nat) : Std.U64 := ⟨BitVec.ofNat 64 x⟩
private def u32 (x : Nat) : Std.U32 := ⟨BitVec.ofNat 32 x⟩

private def unwrapI32 (r : Result Std.I32) : String :=
  match r.match with
  | .ok v => toString v.val
  | _ => "TRAP"

private def unwrapI64 (r : Result Std.I64) : String :=
  match r.match with
  | .ok v => toString v.val
  | _ => "TRAP"

private def unwrapBool (r : Result Bool) : String :=
  match r.match with
  | .ok b => if b then "true" else "false"
  | _ => "TRAP"

private def unwrapDtRes (r : Result (Pion.Res DateTime CronError)) : String :=
  match r.match with
  | .ok (.Ok dt) =>
    s!"Ok({dt.year.val},{dt.month.val},{dt.day.val},{dt.hour.val},{dt.minute.val},{dt.second.val})"
  | .ok (.Err _) => "Err"
  | _ => "TRAP"

private def sampleCron : Cron :=
  { seconds_mask := u64 1
  , minutes_mask := u64 (1 <<< 30)
  , hours_mask := u64 (1 <<< 12)
  , dom_mask := u64 (1 <<< 15)
  , months_mask := u64 (1 <<< 6)
  , dow_mask := u64 0x7F
  , flags := u32 2 -- FLAG_DOW_STAR
  , dom_last_offset_mask := u64 0
  , dom_nearest_weekday_mask := u64 0
  , dow_last_mask := u32 0
  , dow_nth_mask := u64 0
  , year_min := i32 1
  , year_max := i32 9999
  , year_step := i32 1
  , year_spec := ""
  , year_bitmap := "" }

private def mkDt (y mo d h mi s : Int) : DateTime :=
  DateTime.mk (i32 y) (i32 mo) (i32 d) (i32 h) (i32 mi) (i32 s)

private def lines : List String :=
  [ s!"ctz64_1={unwrapI32 (ctz64 (u64 1))}"
  , s!"ctz64_bit32={unwrapI32 (ctz64 (u64 (1 <<< 32)))}"
  , s!"ctz64_bit63={unwrapI32 (ctz64 (u64 (1 <<< 63)))}"
  , s!"ctz64_mix={unwrapI32 (ctz64 (u64 0x0010000000080000))}"
  , s!"msb64_1={unwrapI32 (msb64 (u64 1))}"
  , s!"msb64_bit32={unwrapI32 (msb64 (u64 (1 <<< 32)))}"
  , s!"msb64_bit63={unwrapI32 (msb64 (u64 (1 <<< 63)))}"
  , s!"msb64_mix={unwrapI32 (msb64 (u64 0x0010000000080000))}"
  , s!"next_bit_0={unwrapI32 (next_set_bit (u64 0x14) (i32 0))}"
  , s!"next_bit_3={unwrapI32 (next_set_bit (u64 0x14) (i32 3))}"
  , s!"next_bit_5={unwrapI32 (next_set_bit (u64 0x14) (i32 5))}"
  , s!"next_bit_64={unwrapI32 (next_set_bit (u64 0xFFFFFFFFFFFFFFFF) (i32 64))}"
  , s!"prev_bit_63={unwrapI32 (prev_set_bit (u64 0x14) (i32 63))}"
  , s!"prev_bit_3={unwrapI32 (prev_set_bit (u64 0x14) (i32 3))}"
  , s!"prev_bit_1={unwrapI32 (prev_set_bit (u64 0x14) (i32 1))}"
  , s!"prev_bit_neg={unwrapI32 (prev_set_bit (u64 0xFFFFFFFFFFFFFFFF) (i32 (-1)))}"
  , s!"leap_1900={unwrapBool (is_leap_year (i32 1900))}"
  , s!"leap_2000={unwrapBool (is_leap_year (i32 2000))}"
  , s!"leap_2024={unwrapBool (is_leap_year (i32 2024))}"
  , s!"leap_2025={unwrapBool (is_leap_year (i32 2025))}"
  , s!"leap_2100={unwrapBool (is_leap_year (i32 2100))}"
  , s!"leap_2400={unwrapBool (is_leap_year (i32 2400))}"
  , s!"dim_2024_2={unwrapI32 (days_in_month (i32 2024) (i32 2))}"
  , s!"dim_2100_2={unwrapI32 (days_in_month (i32 2100) (i32 2))}"
  , s!"dim_2000_2={unwrapI32 (days_in_month (i32 2000) (i32 2))}"
  , s!"dim_2025_4={unwrapI32 (days_in_month (i32 2025) (i32 4))}"
  , s!"dim_2025_7={unwrapI32 (days_in_month (i32 2025) (i32 7))}"
  , s!"dim_2025_8={unwrapI32 (days_in_month (i32 2025) (i32 8))}"
  , s!"from_unix_0={unwrapDtRes (DateTime.from_unix_secs (i64 0))}"
  , s!"from_unix_neg1={unwrapDtRes (DateTime.from_unix_secs (i64 (-1)))}"
  , s!"from_unix_min={unwrapDtRes (DateTime.from_unix_secs (i64 (-62135596800)))}"
  , s!"from_unix_max={unwrapDtRes (DateTime.from_unix_secs (i64 253402300799))}"
  , s!"from_unix_under={unwrapDtRes (DateTime.from_unix_secs (i64 (-62135596801)))}"
  , s!"from_unix_over={unwrapDtRes (DateTime.from_unix_secs (i64 253402300800))}"
  , s!"from_unix_f3_alias={unwrapDtRes (DateTime.from_unix_secs (i64 (4294967296 * 86400)))}"
  , s!"to_unix_epoch={unwrapI64 (DateTime.to_unix_secs (mkDt 1970 1 1 0 0 0))}"
  , s!"to_unix_min={unwrapI64 (DateTime.to_unix_secs (mkDt 1 1 1 0 0 0))}"
  , s!"to_unix_max={unwrapI64 (DateTime.to_unix_secs (mkDt 9999 12 31 23 59 59))}"
  , s!"to_unix_leap={unwrapI64 (DateTime.to_unix_secs (mkDt 2024 2 29 12 34 56))}"
  , s!"valid_ok={unwrapBool (DateTime.is_valid (mkDt 2024 2 29 23 59 59))}"
  , s!"valid_bad_feb={unwrapBool (DateTime.is_valid (mkDt 2100 2 29 0 0 0))}"
  , s!"valid_bad_f5={unwrapBool (DateTime.is_valid (mkDt 2025 6 15 12 30 64))}"
  , s!"match_fixed_ok={unwrapBool (matches_fixed_fields sampleCron (mkDt 2025 6 15 12 30 0))}"
  , s!"match_fixed_f5={unwrapBool (matches_fixed_fields sampleCron (mkDt 2025 6 15 12 30 64))}"
  ]

#eval do
  for l in lines do
    IO.println l

end CronEvalDiff
