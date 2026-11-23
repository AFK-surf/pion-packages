import Time.Types
import Time.Funs

open Aeneas Aeneas.Std Result Pion time

namespace TimeEvalDiff

def fmtI32 (r : Result Std.I32) : String :=
  match r.match with
  | .ok v => toString v.val
  | _ => "TRAP"

def fmtBool (r : Result Bool) : String :=
  match r.match with
  | .ok true => "true"
  | .ok false => "false"
  | _ => "TRAP"

def fmtDateRes (r : Result (Pion.Res Date TimeError)) : String :=
  match r.match with
  | .ok (.Ok d) => s!"Ok({d.year.val},{d.month.val},{d.day.val})"
  | .ok (.Err _) => "Err"
  | _ => "TRAP"

def fmtDurRes (r : Result (Pion.Res SignedDuration TimeError)) : String :=
  match r.match with
  | .ok (.Ok d) => s!"Ok({d.secs.val},{d.nanos.val})"
  | .ok (.Err _) => "Err"
  | _ => "TRAP"

def i64Min : Std.I64 := Pion.I64.sub (-9223372036854775807)#i64 1#i64
def i64Max : Std.I64 := 9223372036854775807#i64
def durMin : SignedDuration := SignedDuration.mk i64Min (-999999999)#i32
def durMax : SignedDuration := SignedDuration.mk i64Max 999999999#i32
def durZero : SignedDuration := SignedDuration.mk 0#i64 0#i32

#eval show IO Unit from do
  IO.println s!"leap_1900={fmtBool (is_leap_year 1900#i32)}"
  IO.println s!"leap_2000={fmtBool (is_leap_year 2000#i32)}"
  IO.println s!"leap_0={fmtBool (is_leap_year 0#i32)}"
  IO.println s!"leap_min={fmtBool (is_leap_year (-2147483648)#i32)}"
  IO.println s!"leap_max={fmtBool (is_leap_year 2147483647#i32)}"
  IO.println s!"dim_2000_2={fmtI32 (days_in_month_of 2000#i32 2#i32)}"
  IO.println s!"dim_1900_2={fmtI32 (days_in_month_of 1900#i32 2#i32)}"
  IO.println s!"dim_2024_12={fmtI32 (days_in_month_of 2024#i32 12#i32)}"
  IO.println s!"ep_min={fmtI32 (Date.to_epoch_days (Date.mk (-9999)#i32 1#i32 1#i32))}"
  IO.println s!"from_ep_min={fmtDateRes (Date.from_epoch_days (-4371587)#i32)}"
  IO.println s!"ep_0000_0229={fmtI32 (Date.to_epoch_days (Date.mk 0#i32 2#i32 29#i32))}"
  IO.println s!"from_ep_0000_0229={fmtDateRes (Date.from_epoch_days (-719469)#i32)}"
  IO.println s!"ep_1970={fmtI32 (Date.to_epoch_days (Date.mk 1970#i32 1#i32 1#i32))}"
  IO.println s!"from_ep_1970={fmtDateRes (Date.from_epoch_days 0#i32)}"
  IO.println s!"ep_max={fmtI32 (Date.to_epoch_days (Date.mk 9999#i32 12#i32 31#i32))}"
  IO.println s!"from_ep_max={fmtDateRes (Date.from_epoch_days 2932896#i32)}"
  IO.println s!"from_ep_oob_lo={fmtDateRes (Date.from_epoch_days (-4371588)#i32)}"
  IO.println s!"from_ep_oob_hi={fmtDateRes (Date.from_epoch_days 2932897#i32)}"
  IO.println s!"from_ep_i32min={fmtDateRes (Date.from_epoch_days (-2147483648)#i32)}"
  IO.println s!"from_ep_i32max={fmtDateRes (Date.from_epoch_days 2147483647#i32)}"
  IO.println s!"dur_new_norm={fmtDurRes (SignedDuration.new 1#i64 (-500000000)#i32)}"
  IO.println s!"dur_new_ovf={fmtDurRes (SignedDuration.new i64Max 1000000000#i32)}"
  IO.println s!"dur_neg_min={fmtDurRes (SignedDuration.checked_neg durMin)}"
  IO.println s!"dur_neg_max={fmtDurRes (SignedDuration.checked_neg durMax)}"
  IO.println s!"dur_add_ovf={fmtDurRes (SignedDuration.checked_add durMax (SignedDuration.mk 0#i64 1#i32))}"
  IO.println s!"dur_add_unf={fmtDurRes (SignedDuration.checked_add durMin (SignedDuration.mk 0#i64 (-1)#i32))}"
  IO.println s!"dur_add_minmax={fmtDurRes (SignedDuration.checked_add durMin durMax)}"
  IO.println s!"dur_sub_edge={fmtDurRes (SignedDuration.checked_sub (SignedDuration.mk 0#i64 (-1)#i32) (SignedDuration.mk i64Min 0#i32))}"
  IO.println s!"dur_sub_ovf={fmtDurRes (SignedDuration.checked_sub durZero durMin)}"
  IO.println s!"dur_sub_self={fmtDurRes (SignedDuration.checked_sub durMin durMin)}"
  IO.println s!"cmp_date={fmtI32 (Date.cmp (Date.mk (-9999)#i32 1#i32 1#i32) (Date.mk 9999#i32 12#i32 31#i32))}"
  IO.println s!"cmp_time={fmtI32 (Time.cmp (Time.mk 23#i32 59#i32 59#i32 999999999#i32) (Time.mk 0#i32 0#i32 0#i32 0#i32))}"
  IO.println s!"cmp_ts={fmtI32 (Timestamp.cmp (Timestamp.mk (-1)#i64 999999999#i32) (Timestamp.mk 0#i64 0#i32))}"
  IO.println s!"cmp_dur={fmtI32 (SignedDuration.cmp durMin durMax)}"

end TimeEvalDiff
