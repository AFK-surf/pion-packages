import Aeneas
import PionLean
import Qrcode.Types
import Qrcode.Funs

open Aeneas Aeneas.Std Result Pion qrcode

private def checkBool (label : String) (r : Result Bool) (expected : Bool) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkI32 (label : String) (r : Result I32) (expected : I32) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def runAll : List String := [
  checkI32 "ec_L_fb" (EcLevel.format_bits .L) 1#i32,
  checkI32 "ec_M_fb" (EcLevel.format_bits .M) 0#i32,
  checkI32 "ec_Q_fb" (EcLevel.format_bits .Q) 3#i32,
  checkI32 "ec_H_fb" (EcLevel.format_bits .H) 2#i32,
  checkI32 "mode_num" (Mode.indicator .Numeric) 1#i32,
  checkI32 "mode_alnum" (Mode.indicator .Alphanumeric) 2#i32,
  checkI32 "mode_byte" (Mode.indicator .Byte) 4#i32,
  checkI32 "mode_kanji" (Mode.indicator .Kanji) 8#i32,
  checkI32 "mode_eci" (Mode.indicator .Eci) 7#i32,
  checkI32 "vsize_1" (version_size 1#i32) 21#i32,
  checkI32 "vsize_7" (version_size 7#i32) 45#i32,
  checkI32 "vsize_40" (version_size 40#i32) 177#i32,
  checkI32 "raw_v1" (raw_data_modules 1#i32) 208#i32,
  checkI32 "raw_v7" (raw_data_modules 7#i32) 1568#i32,
  checkI32 "raw_v40" (raw_data_modules 40#i32) 29648#i32,
  checkI32 "cw_v1" (total_codewords 1#i32) 26#i32,
  checkI32 "cw_v40" (total_codewords 40#i32) 3706#i32,
  checkI32 "ccb_v1_num" (char_count_bits 1#i32 .Numeric) 10#i32,
  checkI32 "ccb_v10_byte" (char_count_bits 10#i32 .Byte) 16#i32,
  checkI32 "ccb_v27_kanji" (char_count_bits 27#i32 .Kanji) 12#i32,
  checkI32 "ceil6_0" (ceil_sixths 0#i32) 0#i32,
  checkI32 "ceil6_1" (ceil_sixths 1#i32) 6#i32,
  checkI32 "ceil6_6" (ceil_sixths 6#i32) 6#i32,
  checkI32 "ceil6_7" (ceil_sixths 7#i32) 12#i32,
  checkBool "mask0_3_5" (apply_mask_condition 0#i32 3#i32 5#i32) true,
  checkBool "mask1_3_5" (apply_mask_condition 1#i32 3#i32 5#i32) false,
  checkBool "mask2_6_5" (apply_mask_condition 2#i32 6#i32 5#i32) true,
  checkBool "mask3_4_5" (apply_mask_condition 3#i32 4#i32 5#i32) true,
  checkBool "mask4_3_2" (apply_mask_condition 4#i32 3#i32 2#i32) true,
  checkBool "mask5_2_3" (apply_mask_condition 5#i32 2#i32 3#i32) true,
  checkBool "mask6_2_3" (apply_mask_condition 6#i32 2#i32 3#i32) true,
  checkBool "mask7_2_3" (apply_mask_condition 7#i32 2#i32 3#i32) false,
  checkI32 "kanji_min" (kanji_value 0x81#i32 0x40#i32) 0#i32,
  checkI32 "kanji_mid" (kanji_value 0x93#i32 0x5F#i32) 3487#i32,
  checkI32 "kanji_hi" (kanji_value 0xEB#i32 0xBF#i32) 8191#i32,
  checkI32 "kanji_7f" (kanji_value 0x81#i32 0x7F#i32) (-1)#i32,
  checkI32 "kfrom_0" (kanji_from_value 0#i32) 33088#i32,
  checkI32 "kfrom_3487" (kanji_from_value 3487#i32) 37727#i32,
  checkI32 "kfrom_8191" (kanji_from_value 8191#i32) 60351#i32,
  checkI32 "kfrom_bad" (kanji_from_value 63#i32) (-1)#i32
]

#eval IO.println (String.intercalate "\n" runAll)
