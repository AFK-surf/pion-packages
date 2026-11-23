import Aeneas
import PionLean
import Qrcode.Types
import Qrcode.Funs

open Aeneas Aeneas.Std Result Pion qrcode

private def fmtI32 (r : Result I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def runAll : List String :=
  [ s!"raw_v1={fmtI32 (raw_data_modules 1#i32)}"
  , s!"raw_v7={fmtI32 (raw_data_modules 7#i32)}"
  , s!"raw_v40={fmtI32 (raw_data_modules 40#i32)}"
  , s!"cw_v1={fmtI32 (total_codewords 1#i32)}"
  , s!"cw_v40={fmtI32 (total_codewords 40#i32)}"
  , s!"ccb_v1_num={fmtI32 (char_count_bits 1#i32 .Numeric)}"
  , s!"ccb_v10_byte={fmtI32 (char_count_bits 10#i32 .Byte)}"
  , s!"ccb_v27_kanji={fmtI32 (char_count_bits 27#i32 .Kanji)}"
  , s!"ceil6_0={fmtI32 (ceil_sixths 0#i32)}"
  , s!"ceil6_1={fmtI32 (ceil_sixths 1#i32)}"
  , s!"ceil6_6={fmtI32 (ceil_sixths 6#i32)}"
  , s!"ceil6_7={fmtI32 (ceil_sixths 7#i32)}"
  , s!"kanji_min={fmtI32 (kanji_value 0x81#i32 0x40#i32)}"
  , s!"kanji_mid={fmtI32 (kanji_value 0x93#i32 0x5F#i32)}"
  , s!"kanji_hi={fmtI32 (kanji_value 0xEB#i32 0xBF#i32)}"
  , s!"kanji_7f={fmtI32 (kanji_value 0x81#i32 0x7F#i32)}"
  , s!"kfrom_0={fmtI32 (kanji_from_value 0#i32)}"
  , s!"kfrom_3487={fmtI32 (kanji_from_value 3487#i32)}"
  , s!"kfrom_8191={fmtI32 (kanji_from_value 8191#i32)}"
  , s!"kfrom_bad={fmtI32 (kanji_from_value 63#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
