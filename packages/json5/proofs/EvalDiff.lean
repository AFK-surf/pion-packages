import Json5.Types
import Json5.Funs

open Aeneas Aeneas.Std Result Pion json5

namespace Json5EvalDiff

private def i32 (x : Int) : Std.I32 := ⟨BitVec.ofInt 32 x⟩

private def showI32 (label : String) (r : Result Std.I32) : String :=
  match r.match with
  | .ok v => s!"{label}={v.val}"
  | _ => s!"{label}=TRAP"

private def showBool (label : String) (r : Result Bool) : String :=
  match r.match with
  | .ok b => s!"{label}={if b then "true" else "false"}"
  | _ => s!"{label}=TRAP"

def runAll : List String :=
  [ showI32 "sur_min" (decode_surrogate_pair 55296#i32 56320#i32)
  , showI32 "sur_max" (decode_surrogate_pair 56319#i32 57343#i32)
  , showI32 "sur_oob" (decode_surrogate_pair (i32 (-1)) 0#i32)
  , showI32 "hex2_00" (pack_hex2 0#i32 0#i32)
  , showI32 "hex2_ff" (pack_hex2 15#i32 15#i32)
  , showI32 "hex2_oob" (pack_hex2 (i32 (-1)) 0#i32)
  , showBool "ws_sp" (is_unicode_j5_ws 32#i32)
  , showBool "ws_ls" (is_unicode_j5_ws 8232#i32)
  , showBool "ws_min" (is_unicode_j5_ws (i32 (-2147483648)))
  , showBool "ws_max" (is_unicode_j5_ws (i32 2147483647))
  , showBool "grow_no" (hash_needs_grow 4#i32 8#i32)
  , showBool "grow_yes" (hash_needs_grow 5#i32 8#i32)
  , showBool "grow_0" (hash_needs_grow 0#i32 0#i32)
  , showI32 "nslot_wrap" (hash_next_slot 7#i32 7#i32)
  , showI32 "nslot_max" (hash_next_slot (i32 2147483647) 15#i32)
  , showI32 "pe_til" (pointer_escape_suffix 126#i32)
  , showI32 "pe_sl" (pointer_escape_suffix 47#i32)
  , showI32 "pe_other" (pointer_escape_suffix 65#i32)
  , showI32 "pu_0" (pointer_unescape_byte 48#i32)
  , showI32 "pu_1" (pointer_unescape_byte 49#i32)
  , showI32 "pu_bad" (pointer_unescape_byte 50#i32)
  , showI32 "lut_sp" (ascii_lut_flags 32#i32)
  , showI32 "lut_A" (ascii_lut_flags 65#i32)
  , showI32 "lut_min" (ascii_lut_flags (i32 (-2147483648)))
  , showI32 "lut_max" (ascii_lut_flags (i32 2147483647))
  ]

#eval IO.println (String.intercalate "\n" runAll)

end Json5EvalDiff
