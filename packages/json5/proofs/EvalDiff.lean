import Aeneas
import PionLean
import Json5.Types
import Json5.Funs

open Aeneas Aeneas.Std Result
open json5

def cb (lbl : String) (r : Result Bool) (exp : Bool) : String :=
  if r.reducesTo exp then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def ci (lbl : String) (r : Result Std.I32) (exp : Std.I32) : String :=
  if r.reducesTo exp then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def cu64 (lbl : String) (r : Result Std.U64) (exp : Std.U64) : String :=
  if r.reducesTo exp then s!"{lbl}: PASS" else s!"{lbl}: FAIL"

def runAll : List String := [
  cb "hs_ok" (is_high_surrogate 55357#i32) true,
  cb "hs_lo" (is_high_surrogate 56320#i32) false,
  cb "ls_ok" (is_low_surrogate 56832#i32) true,
  cb "ls_hi" (is_low_surrogate 55296#i32) false,
  ci "sp_min" (decode_surrogate_pair 55296#i32 56320#i32) 65536#i32,
  ci "sp_max" (decode_surrogate_pair 56319#i32 57343#i32) 1114111#i32,
  ci "sp_emo" (decode_surrogate_pair 55357#i32 56832#i32) 128512#i32,
  ci "hx4_0" (pack_hex4 0#i32 0#i32 4#i32 1#i32) 65#i32,
  ci "hx4_f" (pack_hex4 15#i32 15#i32 15#i32 15#i32) 65535#i32,
  ci "hx2_a" (pack_hex2 10#i32 5#i32) 165#i32,
  ci "hx2_f" (pack_hex2 15#i32 15#i32) 255#i32,
  cb "uws_ls" (is_unicode_j5_ws 8232#i32) true,
  cb "uws_ps" (is_unicode_j5_ws 8233#i32) true,
  cb "uws_bom" (is_unicode_j5_ws 65279#i32) true,
  cb "uws_sp" (is_unicode_j5_ws 32#i32) false,
  cb "u8c_ok" (is_utf8_cont 128#i32) true,
  cb "u8c_no" (is_utf8_cont 192#i32) false,
  cb "u8_3_ok" (utf8_valid_3byte 228#i32 184#i32 173#i32) true,
  cb "u8_3_ov" (utf8_valid_3byte 224#i32 159#i32 128#i32) false,
  cb "u8_3_sr" (utf8_valid_3byte 237#i32 160#i32 128#i32) false,
  cb "u8_4_ok" (utf8_valid_4byte 240#i32 159#i32 152#i32 128#i32) true,
  cb "u8_4_ov" (utf8_valid_4byte 240#i32 143#i32 128#i32 128#i32) false,
  cb "u8_4_hi" (utf8_valid_4byte 244#i32 144#i32 128#i32 128#i32) false,
  cu64 "hnz_0" (hash_ensure_nonzero 0#u64) 1#u64,
  cu64 "hnz_7" (hash_ensure_nonzero 7#u64) 7#u64,
  cu64 "sm64_0" (splitmix64 0#u64) 16294208416658607535#u64,
  cb "hgr_no" (hash_needs_grow 19#i32 32#i32) false,
  cb "hgr_yes" (hash_needs_grow 20#i32 32#i32) true,
  cb "hgr_ful" (hash_needs_grow 32#i32 32#i32) true,
  ci "hns_0" (hash_next_slot 0#i32 31#i32) 1#i32,
  ci "hns_w" (hash_next_slot 31#i32 31#i32) 0#i32,
  ci "pe_til" (pointer_escape_suffix 126#i32) 48#i32,
  ci "pe_sl" (pointer_escape_suffix 47#i32) 49#i32,
  ci "pe_a" (pointer_escape_suffix 97#i32) (-1)#i32,
  ci "pu_0" (pointer_unescape_byte 48#i32) 126#i32,
  ci "pu_1" (pointer_unescape_byte 49#i32) 47#i32,
  ci "pu_2" (pointer_unescape_byte 50#i32) (-1)#i32,
  cb "je_q" (json_needs_escape_ascii 34#i32) true,
  cb "je_bs" (json_needs_escape_ascii 92#i32) true,
  cb "je_nl" (json_needs_escape_ascii 10#i32) true,
  cb "je_a" (json_needs_escape_ascii 97#i32) false,
  ci "lut_sp" (ascii_lut_flags 32#i32) 3#i32,
  ci "lut_A" (ascii_lut_flags 65#i32) 12#i32,
  ci "lut_0" (ascii_lut_flags 48#i32) 24#i32
]

#eval IO.println (String.intercalate "\n" runAll)
