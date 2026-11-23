import Aeneas
import PionLean
import Git.Types
import Git.Funs

open Aeneas Aeneas.Std Result Pion git

private def checkBool (label : String) (r : Result Bool) (expected : Bool) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkI32 (label : String) (r : Result I32) (expected : I32) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkOptKind (label : String) (r : Result (Option ObjectKind)) (expected : Option ObjectKind) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def runAll : List String := [
  checkI32 "hex_0" (hex_nibble 48#i32) 0#i32,
  checkI32 "hex_9" (hex_nibble 57#i32) 9#i32,
  checkI32 "hex_a" (hex_nibble 97#i32) 10#i32,
  checkI32 "hex_f" (hex_nibble 102#i32) 15#i32,
  checkI32 "hex_A" (hex_nibble 65#i32) 10#i32,
  checkI32 "hex_F" (hex_nibble 70#i32) 15#i32,
  checkI32 "hex_g" (hex_nibble 103#i32) (-1)#i32,
  checkI32 "pkt_len_0000" (pkt_line_decode_len 0#i32 0#i32 0#i32 0#i32) 0#i32,
  checkI32 "pkt_len_0010" (pkt_line_decode_len 0#i32 0#i32 1#i32 0#i32) 16#i32,
  checkI32 "pkt_len_fff0" (pkt_line_decode_len 15#i32 15#i32 15#i32 0#i32) 65520#i32,
  checkI32 "pkt_cls_0" (pkt_line_classify_len 0#i32) 0#i32,
  checkI32 "pkt_cls_1" (pkt_line_classify_len 1#i32) 1#i32,
  checkI32 "pkt_cls_2" (pkt_line_classify_len 2#i32) 2#i32,
  checkI32 "pkt_cls_3" (pkt_line_classify_len 3#i32) (-1)#i32,
  checkI32 "pkt_cls_4" (pkt_line_classify_len 4#i32) 3#i32,
  checkI32 "pkt_cls_65520" (pkt_line_classify_len 65520#i32) 3#i32,
  checkI32 "pkt_cls_65521" (pkt_line_classify_len 65521#i32) (-1)#i32,
  checkBool "ref_ch_sp" (is_ref_forbidden_char 32#i32) true,
  checkBool "ref_ch_tilde" (is_ref_forbidden_char 126#i32) true,
  checkBool "ref_ch_slash" (is_ref_forbidden_char 47#i32) false,
  checkBool "ref_ch_a" (is_ref_forbidden_char 97#i32) false,
  checkBool "ref_pair_dotdot" (is_ref_forbidden_pair 46#i32 46#i32) true,
  checkBool "ref_pair_ss" (is_ref_forbidden_pair 47#i32 47#i32) true,
  checkBool "ref_pair_atb" (is_ref_forbidden_pair 64#i32 123#i32) true,
  checkBool "ref_pair_ok" (is_ref_forbidden_pair 97#i32 98#i32) false,
  checkOptKind "okind_1" (object_kind_from_pack_type_opt 1#i32) (some .Commit),
  checkOptKind "okind_4" (object_kind_from_pack_type_opt 4#i32) (some .Tag),
  checkOptKind "okind_5" (object_kind_from_pack_type_opt 5#i32) none,
  checkI32 "idx_stage_0" (index_flags_stage 0#u32) 0#i32,
  checkI32 "idx_stage_3" (index_flags_stage 12288#u32) 3#i32,
  checkI32 "idx_pad_63" (index_v2_padded_len 63#i32) 64#i32,
  checkI32 "idx_pad_64" (index_v2_padded_len 64#i32) 64#i32,
  checkI32 "idx_padb_63" (index_v2_pad_bytes 63#i32) 1#i32,
  checkI32 "idx_padb_64" (index_v2_pad_bytes 64#i32) 0#i32,
  checkI32 "delta_dec_0" (delta_copy_size_decode 0#i32) 65536#i32,
  checkI32 "delta_dec_42" (delta_copy_size_decode 42#i32) 42#i32,
  checkI32 "delta_enc_65536" (delta_copy_size_encode 65536#i32) 0#i32,
  checkBool "delta_rng_ok" (delta_copy_range_ok 10#i32 20#i32 30#i32 5#i32 25#i32) true,
  checkBool "delta_rng_bad" (delta_copy_range_ok 11#i32 20#i32 30#i32 5#i32 25#i32) false
]

#eval IO.println (String.intercalate "\n" runAll)
