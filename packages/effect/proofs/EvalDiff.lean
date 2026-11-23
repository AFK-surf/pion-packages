import Aeneas
import PionLean
import Effect.Types
import Effect.Funs

open Aeneas Aeneas.Std Result
open effect

def cb (lbl : String) (r : Result Bool) (exp : Bool) : String :=
  if r.reducesTo exp then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def ci (lbl : String) (r : Result Std.I32) (exp : Std.I32) : String :=
  if r.reducesTo exp then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def ci64 (lbl : String) (r : Result Std.I64) (exp : Std.I64) : String :=
  if r.reducesTo exp then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def runAll : List String := [
  ci64 "rng_init0" (rng_init_state 0#i32) 2654435769#i64,
  ci64 "rng_init1" (rng_init_state 1#i32) 8#i64,
  ci64 "rng_step0" (rng_step_u32 0#i64) 0#i64,
  ci64 "rng_step1" (rng_step_u32 1#i64) 270369#i64,
  ci "rng_bel0" (rng_below_val 100#i64 0#i32) 0#i32,
  ci "rng_bel1" (rng_below_val 100#i64 1#i32) 0#i32,
  ci "rng_bel7" (rng_below_val 100#i64 7#i32) 2#i32,
  ci "rcap_0" (ring_next_cap 0#i32) 8#i32,
  ci "rcap_8" (ring_next_cap 8#i32) 16#i32,
  ci "radd_0" (ring_slot_add 0#i32 3#i32 8#i32) 3#i32,
  ci "radd_w" (ring_slot_add 6#i32 5#i32 8#i32) 3#i32,
  ci "rprev_0" (ring_slot_prev 0#i32 8#i32) 7#i32,
  ci "rprev_3" (ring_slot_prev 3#i32 8#i32) 2#i32,
  cb "tm_lt" (timer_before 10#i64 5#i32 20#i64 1#i32) true,
  cb "tm_eq_lt" (timer_before 10#i64 1#i32 10#i64 2#i32) true,
  cb "tm_eq_eq" (timer_before 10#i64 2#i32 10#i64 2#i32) false,
  cb "tm_gt" (timer_before 20#i64 1#i32 10#i64 9#i32) false,
  ci "hp_1" (heap_parent 1#i32) 0#i32,
  ci "hp_2" (heap_parent 2#i32) 0#i32,
  ci "hp_5" (heap_parent 5#i32) 2#i32,
  ci "hl_0" (heap_left 0#i32) 1#i32,
  ci "hl_3" (heap_left 3#i32) 7#i32,
  cb "q_unb" (queue_has_room (-1)#i32 999#i32) true,
  cb "q_ok" (queue_has_room 16#i32 15#i32) true,
  cb "q_full" (queue_has_room 16#i32 16#i32) false,
  cb "qo_shut" (queue_can_offer true (-1)#i32 0#i32) false,
  cb "qo_ok" (queue_can_offer false 4#i32 3#i32) true,
  ci "p_ask" priority_asked 30#i32,
  ci "p_foc" priority_focused 20#i32,
  ci "p_shw" priority_shown 10#i32,
  ci "p_det" priority_detail 5#i32,
  ci "p_bg" priority_background 0#i32,
  ci "p_idl" priority_idle (-10)#i32,
  cb "sl_urg_ok" (sched_lane_admits 20#i32 3#i32 2#i32 2#i32 0#i32 false false false) true,
  cb "sl_urg_no" (sched_lane_admits 20#i32 4#i32 2#i32 2#i32 0#i32 false false false) false,
  cb "sl_shw_ok" (sched_lane_admits 10#i32 1#i32 2#i32 2#i32 0#i32 false false false) true,
  cb "sl_shw_no" (sched_lane_admits 10#i32 2#i32 2#i32 2#i32 0#i32 false false false) false,
  cb "sl_bg_ser" (sched_lane_admits 0#i32 1#i32 2#i32 2#i32 0#i32 false true false) false,
  cb "sl_bg_ok" (sched_lane_admits 0#i32 0#i32 2#i32 2#i32 0#i32 false false false) true,
  cb "sl_idl_no" (sched_lane_admits (-10)#i32 1#i32 2#i32 2#i32 0#i32 false false false) false,
  cb "sl_idl_ok" (sched_lane_admits (-10)#i32 0#i32 2#i32 2#i32 0#i32 false false false) true,
  cb "sp_yes" (sched_is_preempted (-10)#i32 1#i32 false) true,
  cb "sp_no" (sched_is_preempted 0#i32 1#i32 true) false,
  cb "fc_shield" (fiber_should_cut true 1#i32) false
]

#eval IO.println (String.intercalate "\n" runAll)
