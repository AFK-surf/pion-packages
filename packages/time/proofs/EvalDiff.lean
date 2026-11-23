/-
Executable sanity & differential check on the extracted `Time.Funs`:
runs `#guard` and `#eval` directly on the Aeneas-extracted Lean functions and prints
labeled `PASS`/`FAIL` lines that `run_proofs.sh` diffs against native Pion execution.
-/
import Time.Funs

open Aeneas Aeneas.Std Result Pion
open time

def okBool (r : Result Bool) (expected : Bool) : Bool :=
  r.reducesTo expected

def okI32 (r : Result Std.I32) (expected : Std.I32) : Bool :=
  r.reducesTo expected

def okDateRes (r : Result (Pion.Res Date TimeError)) (y m d : Std.I32) : Bool :=
  (do
    let res ← r
    ok (match res with
      | .Ok dt => dt.year == y && dt.month == m && dt.day == d
      | .Err _ => false)).reducesTo true

def errDateRes (r : Result (Pion.Res Date TimeError)) : Bool :=
  (do
    let res ← r
    ok (match res with
      | .Ok _ => false
      | .Err _ => true)).reducesTo true

def okDurRes (r : Result (Pion.Res SignedDuration TimeError)) (s : Std.I64) (n : Std.I32) : Bool :=
  (do
    let res ← r
    ok (match res with
      | .Ok dur => dur.secs == s && dur.nanos == n
      | .Err _ => false)).reducesTo true

def errDurRes (r : Result (Pion.Res SignedDuration TimeError)) : Bool :=
  (do
    let res ← r
    ok (match res with
      | .Ok _ => false
      | .Err _ => true)).reducesTo true

def i64Min : Std.I64 := Pion.I64.sub (-9223372036854775807)#i64 1#i64
def i64Max : Std.I64 := 9223372036854775807#i64
def durMin : SignedDuration := SignedDuration.mk i64Min (-999999999)#i32
def durMax : SignedDuration := SignedDuration.mk i64Max 999999999#i32
def durZero : SignedDuration := SignedDuration.mk 0#i64 0#i32

-- Leap year & days in month
#guard okBool (is_leap_year 1900#i32) false
#guard okBool (is_leap_year 2000#i32) true
#guard okBool (is_leap_year 2100#i32) false
#guard okBool (is_leap_year 2400#i32) true
#guard okBool (is_leap_year 0#i32) true
#guard okBool (is_leap_year (-100)#i32) false
#guard okBool (is_leap_year (-400)#i32) true
#guard okI32 (days_in_month_of 2000#i32 2#i32) 29#i32
#guard okI32 (days_in_month_of 1900#i32 2#i32) 28#i32
#guard okI32 (days_in_month_of 0#i32 2#i32) 29#i32

-- Epoch days roundtrip boundaries
#guard okI32 (Date.to_epoch_days (Date.mk (-9999)#i32 1#i32 1#i32)) (-4371587)#i32
#guard okDateRes (Date.from_epoch_days (-4371587)#i32) (-9999)#i32 1#i32 1#i32
#guard okI32 (Date.to_epoch_days (Date.mk 0#i32 2#i32 29#i32)) (-719469)#i32
#guard okDateRes (Date.from_epoch_days (-719469)#i32) 0#i32 2#i32 29#i32
#guard okI32 (Date.to_epoch_days (Date.mk 1970#i32 1#i32 1#i32)) 0#i32
#guard okDateRes (Date.from_epoch_days 0#i32) 1970#i32 1#i32 1#i32
#guard okI32 (Date.to_epoch_days (Date.mk 2000#i32 2#i32 29#i32)) 11016#i32
#guard okDateRes (Date.from_epoch_days 11016#i32) 2000#i32 2#i32 29#i32
#guard okI32 (Date.to_epoch_days (Date.mk 9999#i32 12#i32 31#i32)) 2932896#i32
#guard okDateRes (Date.from_epoch_days 2932896#i32) 9999#i32 12#i32 31#i32
#guard errDateRes (Date.from_epoch_days (-4371588)#i32)
#guard errDateRes (Date.from_epoch_days 2932897#i32)

-- SignedDuration boundaries & checked arithmetic
#guard errDurRes (SignedDuration.checked_neg durMin)
#guard okDurRes (SignedDuration.checked_neg durMax) (-9223372036854775807)#i64 (-999999999)#i32
#guard errDurRes (SignedDuration.checked_add durMax (SignedDuration.mk 0#i64 1#i32))
#guard errDurRes (SignedDuration.checked_add durMin (SignedDuration.mk 0#i64 (-1)#i32))
#guard okDurRes (SignedDuration.checked_add durMin durMax) (-1)#i64 0#i32
#guard okDurRes (SignedDuration.checked_sub (SignedDuration.mk 0#i64 (-1)#i32) (SignedDuration.mk i64Min 0#i32)) i64Max 999999999#i32
#guard errDurRes (SignedDuration.checked_sub durZero durMin)
#guard okDurRes (SignedDuration.checked_sub durMin durMin) 0#i64 0#i32

-- Comparisons
#guard okI32 (Date.cmp (Date.mk (-9999)#i32 1#i32 1#i32) (Date.mk 9999#i32 12#i32 31#i32)) (-1)#i32
#guard okI32 (Time.cmp (Time.mk 23#i32 59#i32 59#i32 999999999#i32) (Time.mk 0#i32 0#i32 0#i32 0#i32)) 1#i32
#guard okI32 (Timestamp.cmp (Timestamp.mk (-1)#i64 999999999#i32) (Timestamp.mk 0#i64 0#i32)) (-1)#i32
#guard okI32 (SignedDuration.cmp durMin durMax) (-1)#i32

def fmtResult (label : String) (b : Bool) : String :=
  s!"{label}: {if b then "PASS" else "FAIL"}"

#eval do
  let lines : List String := [
    fmtResult "leap_1900_false" (okBool (is_leap_year 1900#i32) false),
    fmtResult "leap_2000_true" (okBool (is_leap_year 2000#i32) true),
    fmtResult "leap_0000_true" (okBool (is_leap_year 0#i32) true),
    fmtResult "leap_neg100_false" (okBool (is_leap_year (-100)#i32) false),
    fmtResult "leap_neg400_true" (okBool (is_leap_year (-400)#i32) true),
    fmtResult "dim_2000_02" (okI32 (days_in_month_of 2000#i32 2#i32) 29#i32),
    fmtResult "dim_1900_02" (okI32 (days_in_month_of 1900#i32 2#i32) 28#i32),
    fmtResult "epoch_min_date" (okI32 (Date.to_epoch_days (Date.mk (-9999)#i32 1#i32 1#i32)) (-4371587)#i32),
    fmtResult "from_epoch_min_date" (okDateRes (Date.from_epoch_days (-4371587)#i32) (-9999)#i32 1#i32 1#i32),
    fmtResult "epoch_0000_02_29" (okI32 (Date.to_epoch_days (Date.mk 0#i32 2#i32 29#i32)) (-719469)#i32),
    fmtResult "from_epoch_0000_02_29" (okDateRes (Date.from_epoch_days (-719469)#i32) 0#i32 2#i32 29#i32),
    fmtResult "epoch_1970_01_01" (okI32 (Date.to_epoch_days (Date.mk 1970#i32 1#i32 1#i32)) 0#i32),
    fmtResult "from_epoch_1970_01_01" (okDateRes (Date.from_epoch_days 0#i32) 1970#i32 1#i32 1#i32),
    fmtResult "epoch_2000_02_29" (okI32 (Date.to_epoch_days (Date.mk 2000#i32 2#i32 29#i32)) 11016#i32),
    fmtResult "from_epoch_2000_02_29" (okDateRes (Date.from_epoch_days 11016#i32) 2000#i32 2#i32 29#i32),
    fmtResult "epoch_max_date" (okI32 (Date.to_epoch_days (Date.mk 9999#i32 12#i32 31#i32)) 2932896#i32),
    fmtResult "from_epoch_max_date" (okDateRes (Date.from_epoch_days 2932896#i32) 9999#i32 12#i32 31#i32),
    fmtResult "from_epoch_underflow_err" (errDateRes (Date.from_epoch_days (-4371588)#i32)),
    fmtResult "from_epoch_overflow_err" (errDateRes (Date.from_epoch_days 2932897#i32)),
    fmtResult "dur_neg_min_err" (errDurRes (SignedDuration.checked_neg durMin)),
    fmtResult "dur_neg_max_ok" (okDurRes (SignedDuration.checked_neg durMax) (-9223372036854775807)#i64 (-999999999)#i32),
    fmtResult "dur_add_max_overflow" (errDurRes (SignedDuration.checked_add durMax (SignedDuration.mk 0#i64 1#i32))),
    fmtResult "dur_add_min_underflow" (errDurRes (SignedDuration.checked_add durMin (SignedDuration.mk 0#i64 (-1)#i32))),
    fmtResult "dur_add_min_max" (okDurRes (SignedDuration.checked_add durMin durMax) (-1)#i64 0#i32),
    fmtResult "dur_sub_zero_neg1_i64min" (okDurRes (SignedDuration.checked_sub (SignedDuration.mk 0#i64 (-1)#i32) (SignedDuration.mk i64Min 0#i32)) i64Max 999999999#i32),
    fmtResult "dur_sub_zero_min_err" (errDurRes (SignedDuration.checked_sub durZero durMin)),
    fmtResult "dur_sub_min_min_zero" (okDurRes (SignedDuration.checked_sub durMin durMin) 0#i64 0#i32),
    fmtResult "cmp_date_min_max" (okI32 (Date.cmp (Date.mk (-9999)#i32 1#i32 1#i32) (Date.mk 9999#i32 12#i32 31#i32)) (-1)#i32),
    fmtResult "cmp_time_max_min" (okI32 (Time.cmp (Time.mk 23#i32 59#i32 59#i32 999999999#i32) (Time.mk 0#i32 0#i32 0#i32 0#i32)) 1#i32),
    fmtResult "cmp_ts_neg1_zero" (okI32 (Timestamp.cmp (Timestamp.mk (-1)#i64 999999999#i32) (Timestamp.mk 0#i64 0#i32)) (-1)#i32),
    fmtResult "cmp_dur_min_max" (okI32 (SignedDuration.cmp durMin durMax) (-1)#i32)
  ]
  for l in lines do
    IO.println l
