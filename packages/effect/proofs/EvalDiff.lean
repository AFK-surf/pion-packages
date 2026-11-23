import Effect.Types
import Effect.Funs

open Aeneas Aeneas.Std Result Pion effect

namespace EffectEvalDiff

private def i32 (x : Int) : Std.I32 := ⟨BitVec.ofInt 32 x⟩
private def i64 (x : Int) : Std.I64 := ⟨BitVec.ofInt 64 x⟩

private def showI32 (label : String) (r : Result Std.I32) : String :=
  match r.match with
  | .ok v => s!"{label}={v.val}"
  | _ => s!"{label}=TRAP"

private def showI64 (label : String) (r : Result Std.I64) : String :=
  match r.match with
  | .ok v => s!"{label}={v.val}"
  | _ => s!"{label}=TRAP"

private def showBool (label : String) (r : Result Bool) : String :=
  match r.match with
  | .ok b => s!"{label}={if b then "true" else "false"}"
  | _ => s!"{label}=TRAP"

def runAll : List String :=
  [ showI64 "rng_init_0" (rng_init_state 0#i32)
  , showI64 "rng_init_neg1" (rng_init_state (i32 (-1)))
  , showI64 "rng_init_min" (rng_init_state (i32 (-2147483648)))
  , showI64 "rng_init_max" (rng_init_state (i32 2147483647))
  , showI32 "rng_below_le1" (rng_below_val 12345#i64 1#i32)
  , showI32 "rng_below_0" (rng_below_val 12345#i64 0#i32)
  , showI32 "rng_below_10" (rng_below_val 4294967295#i64 10#i32)
  , showI32 "rng_below_max" (rng_below_val (i64 9223372036854775807) (i32 2147483647))
  , showI32 "ring_cap_0" (ring_next_cap 0#i32)
  , showI32 "ring_cap_8" (ring_next_cap 8#i32)
  , showI32 "ring_cap_oob" (ring_next_cap (i32 1073741824))
  , showI32 "ring_add_wrap" (ring_slot_add 6#i32 5#i32 8#i32)
  , showI32 "ring_add_trap0" (ring_slot_add 0#i32 1#i32 0#i32)
  , showI32 "ring_prev_0" (ring_slot_prev 0#i32 8#i32)
  , showI32 "ring_prev_3" (ring_slot_prev 3#i32 8#i32)
  , showI32 "ring_prev_trap0" (ring_slot_prev 0#i32 0#i32)
  , showBool "timer_eq" (timer_before 100#i64 1#i32 100#i64 1#i32)
  , showBool "timer_lt_at" (timer_before (i64 (-9223372036854775808)) 0#i32 (i64 9223372036854775807) 0#i32)
  , showBool "timer_tie_seq" (timer_before 100#i64 1#i32 100#i64 2#i32)
  , showI32 "heap_parent_1" (heap_parent 1#i32)
  , showI32 "heap_parent_max" (heap_parent (i32 2147483647))
  , showI32 "heap_left_0" (heap_left 0#i32)
  , showI32 "heap_left_10" (heap_left 10#i32)
  ]

#eval IO.println (String.intercalate "\n" runAll)

end EffectEvalDiff
