import Aeneas
import PionLean
import HttpCache.Types
import HttpCache.Funs

open Aeneas Aeneas.Std Result Pion http_cache

private def mkI32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
private def mkI64 (n : Int) : Std.I64 := ⟨BitVec.ofInt 64 n⟩

private def checkCase {α : Type} [BEq α] (label : String) (r : Result α) (expected : α) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

def runAll : List String := [
  -- clamped_add_i64
  checkCase "add_0_0" (clamped_add_i64 (mkI64 0) (mkI64 0)) (mkI64 0),
  checkCase "add_10_20" (clamped_add_i64 (mkI64 10) (mkI64 20)) (mkI64 30),
  checkCase "add_clamp" (clamped_add_i64 (mkI64 2147483640) (mkI64 100)) (mkI64 2147483648),
  checkCase "add_ovf" (clamped_add_i64 (mkI64 9223372036854775807) (mkI64 1)) (mkI64 2147483648),
  -- clamped_sub_i64
  checkCase "sub_le" (clamped_sub_i64 (mkI64 100) (mkI64 200)) (mkI64 0),
  checkCase "sub_eq" (clamped_sub_i64 (mkI64 500) (mkI64 500)) (mkI64 0),
  checkCase "sub_mid" (clamped_sub_i64 (mkI64 1000) (mkI64 250)) (mkI64 750),
  checkCase "sub_clamp" (clamped_sub_i64 (mkI64 5000000000) (mkI64 0)) (mkI64 2147483648),
  checkCase "sub_extreme" (clamped_sub_i64 (mkI64 9223372036854775807) (mkI64 (-100))) (mkI64 2147483648),
  -- initial & current age
  checkCase "iage_app" (compute_initial_age_core (mkI64 50) (mkI64 10) (mkI64 100) (mkI64 105)) (mkI64 50),
  checkCase "iage_corr" (compute_initial_age_core (mkI64 5) (mkI64 10) (mkI64 100) (mkI64 125)) (mkI64 35),
  checkCase "cage_0" (compute_current_age_core (mkI64 30) (mkI64 1000) (mkI64 900)) (mkI64 30),
  checkCase "cage_60" (compute_current_age_core (mkI64 30) (mkI64 1000) (mkI64 1060)) (mkI64 90),
  checkCase "cage_cap" (compute_current_age_core (mkI64 2147483640) (mkI64 1000) (mkI64 2000)) (mkI64 2147483648),
  -- status codes
  checkCase "hc_200" (is_heuristically_cacheable_status (mkI32 200)) true,
  checkCase "hc_206" (is_heuristically_cacheable_status (mkI32 206)) false,
  checkCase "hc_308" (is_heuristically_cacheable_status (mkI32 308)) true,
  checkCase "hc_410" (is_heuristically_cacheable_status (mkI32 410)) true,
  checkCase "hc_501" (is_heuristically_cacheable_status (mkI32 501)) true,
  checkCase "hc_500" (is_heuristically_cacheable_status (mkI32 500)) false,
  checkCase "us_302" (is_understood_status (mkI32 302)) true,
  checkCase "us_206" (is_understood_status (mkI32 206)) false,
  checkCase "us_418" (is_understood_status (mkI32 418)) false,
  -- limits
  checkCase "lim_def" (do let l ← CacheLimits.default; limits_all_nonneg l) true,
  checkCase "lim_neg" (do let l ← CacheLimits.new (mkI32 (-1)) (mkI32 1) (mkI32 1) (mkI32 1) (mkI64 1) (mkI32 1) (mkI64 1); limits_all_nonneg l) false,
  -- date helpers
  checkCase "dig_0" (is_ascii_digit (mkI32 48)) true,
  checkCase "dig_9" (is_ascii_digit (mkI32 57)) true,
  checkCase "dig_a" (is_ascii_digit (mkI32 97)) false,
  checkCase "leap_2000" (is_leap_year (mkI32 2000)) true,
  checkCase "leap_1900" (is_leap_year (mkI32 1900)) false,
  checkCase "leap_2024" (is_leap_year (mkI32 2024)) true,
  checkCase "leap_2025" (is_leap_year (mkI32 2025)) false,
  checkCase "dim_feb24" (days_in_month (mkI32 2024) (mkI32 2)) (mkI32 29),
  checkCase "dim_feb25" (days_in_month (mkI32 2025) (mkI32 2)) (mkI32 28),
  checkCase "dim_apr" (days_in_month (mkI32 2025) (mkI32 4)) (mkI32 30),
  checkCase "dim_dec" (days_in_month (mkI32 2025) (mkI32 12)) (mkI32 31)
]

#eval IO.println (String.intercalate "\n" runAll)
