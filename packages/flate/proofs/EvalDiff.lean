import Flate.Types
import Flate.Funs

open Aeneas Aeneas.Std Result Pion flate

namespace FlateEvalDiff

private def i32 (x : Int) : Std.I32 := ⟨BitVec.ofInt 32 x⟩
private def u32 (x : Nat) : Std.U32 := ⟨BitVec.ofNat 32 x⟩

private def showI32 (label : String) (r : Result Std.I32) : String :=
  match r.match with
  | .ok v => s!"{label}={v.val}"
  | _ => s!"{label}=TRAP"

private def showU32 (label : String) (r : Result Std.U32) : String :=
  match r.match with
  | .ok v => s!"{label}={v.val}"
  | _ => s!"{label}=TRAP"

def runAll : List String :=
  [ showI32 "huff_dir_0" (huff_direct_entry 0#i32 1#i32)
  , showI32 "huff_dir_285" (huff_direct_entry 285#i32 15#i32)
  , showI32 "huff_dir_max" (huff_direct_entry (i32 33554431) 15#i32)
  , showI32 "huff_dir_oob" (huff_direct_entry (i32 (-1)) 15#i32)
  , showI32 "huff_sub_0" (huff_subtable_entry 0#i32 1#i32)
  , showI32 "huff_sub_max" (huff_subtable_entry (i32 33554431) 15#i32)
  , showU32 "adler_init" (adler32_pack 1#u32 0#u32)
  , showU32 "adler_max" (adler32_pack (u32 65520) (u32 65520))
  , showU32 "adler_u32max" (adler32_pack (u32 0xFFFFFFFF) (u32 0xFFFFFFFF))
  , showI32 "zfl_0" (zlib_flevel 0#i32)
  , showI32 "zfl_6" (zlib_flevel 6#i32)
  , showI32 "zfl_9" (zlib_flevel 9#i32)
  , showI32 "zfl_min" (zlib_flevel (i32 (-2147483648)))
  , showI32 "zfl_max" (zlib_flevel (i32 2147483647))
  , showI32 "zflg_78_2" (zlib_compute_flg 120#i32 2#i32)
  , showI32 "zflg_0_0" (zlib_compute_flg 0#i32 0#i32)
  , showI32 "zflg_255_3" (zlib_compute_flg 255#i32 3#i32)
  , showI32 "zchk_789c" (zlib_check_header 120#i32 156#i32)
  , showI32 "zchk_badf" (zlib_check_header 120#i32 157#i32)
  , showI32 "zchk_badcm" (zlib_check_header 121#i32 24#i32)
  , showI32 "zchk_badci" (zlib_check_header 136#i32 28#i32)
  ]

#eval IO.println (String.intercalate "\n" runAll)

end FlateEvalDiff
