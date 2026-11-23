import Aeneas
import PionLean
import HttpCache.Types
import HttpCache.Funs

open Aeneas Aeneas.Std Result Pion http_cache

private def mkI32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
private def mkI64 (n : Int) : Std.I64 := ⟨BitVec.ofInt 64 n⟩

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtI64 (r : Result Std.I64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def runAll : List String :=
  [ s!"add_0_0={fmtI64 (clamped_add_i64 (mkI64 0) (mkI64 0))}"
  , s!"add_10_20={fmtI64 (clamped_add_i64 (mkI64 10) (mkI64 20))}"
  , s!"add_clamp={fmtI64 (clamped_add_i64 (mkI64 2147483640) (mkI64 100))}"
  , s!"add_ovf={fmtI64 (clamped_add_i64 (mkI64 9223372036854775807) (mkI64 1))}"
  , s!"sub_le={fmtI64 (clamped_sub_i64 (mkI64 100) (mkI64 200))}"
  , s!"sub_eq={fmtI64 (clamped_sub_i64 (mkI64 500) (mkI64 500))}"
  , s!"sub_mid={fmtI64 (clamped_sub_i64 (mkI64 1000) (mkI64 250))}"
  , s!"sub_clamp={fmtI64 (clamped_sub_i64 (mkI64 5000000000) (mkI64 0))}"
  , s!"sub_extreme={fmtI64 (clamped_sub_i64 (mkI64 9223372036854775807) (mkI64 (-100)))}"
  , s!"iage_app={fmtI64 (compute_initial_age_core (mkI64 50) (mkI64 10) (mkI64 100) (mkI64 105))}"
  , s!"iage_corr={fmtI64 (compute_initial_age_core (mkI64 5) (mkI64 10) (mkI64 100) (mkI64 125))}"
  , s!"cage_0={fmtI64 (compute_current_age_core (mkI64 30) (mkI64 1000) (mkI64 900))}"
  , s!"cage_60={fmtI64 (compute_current_age_core (mkI64 30) (mkI64 1000) (mkI64 1060))}"
  , s!"cage_cap={fmtI64 (compute_current_age_core (mkI64 2147483640) (mkI64 1000) (mkI64 2000))}"
  , s!"hc_200={fmtBool (is_heuristically_cacheable_status (mkI32 200))}"
  , s!"hc_206={fmtBool (is_heuristically_cacheable_status (mkI32 206))}"
  , s!"hc_308={fmtBool (is_heuristically_cacheable_status (mkI32 308))}"
  , s!"hc_410={fmtBool (is_heuristically_cacheable_status (mkI32 410))}"
  , s!"hc_501={fmtBool (is_heuristically_cacheable_status (mkI32 501))}"
  , s!"hc_500={fmtBool (is_heuristically_cacheable_status (mkI32 500))}"
  , s!"us_302={fmtBool (is_understood_status (mkI32 302))}"
  , s!"us_206={fmtBool (is_understood_status (mkI32 206))}"
  , s!"us_418={fmtBool (is_understood_status (mkI32 418))}"
  , s!"leap_2000={fmtBool (is_leap_year (mkI32 2000))}"
  , s!"leap_1900={fmtBool (is_leap_year (mkI32 1900))}"
  , s!"leap_2024={fmtBool (is_leap_year (mkI32 2024))}"
  , s!"leap_2025={fmtBool (is_leap_year (mkI32 2025))}"
  , s!"dim_feb24={fmtI32 (days_in_month (mkI32 2024) (mkI32 2))}"
  , s!"dim_feb25={fmtI32 (days_in_month (mkI32 2025) (mkI32 2))}"
  , s!"dim_apr={fmtI32 (days_in_month (mkI32 2025) (mkI32 4))}"
  , s!"dim_dec={fmtI32 (days_in_month (mkI32 2025) (mkI32 12))}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
