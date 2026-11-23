import Aeneas
import PionLean
import Ssh.Types
import Ssh.Funs

open Aeneas Aeneas.Std Result Pion ssh

private def checkBool (label : String) (r : Result Bool) (expected : Bool) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkI32 (label : String) (r : Result I32) (expected : I32) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkU32 (label : String) (r : Result U32) (expected : U32) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def checkOptCT (label : String) (r : Result (Option CertType)) (expected : Option CertType) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

private def runAll : List String := [
  checkBool "vc_sp" (is_ssh_version_char 32#i32) true,
  checkBool "vc_tilde" (is_ssh_version_char 126#i32) true,
  checkBool "vc_lf" (is_ssh_version_char 10#i32) false,
  checkBool "vc_del" (is_ssh_version_char 127#i32) false,
  checkI32 "pad_0_8" (ssh_packet_padding_len 0#i32 8#i32 4#i32) 11#i32,
  checkI32 "pad_3_8" (ssh_packet_padding_len 3#i32 8#i32 4#i32) 8#i32,
  checkI32 "pad_7_16" (ssh_packet_padding_len 7#i32 16#i32 4#i32) 4#i32,
  checkI32 "pad_8_16" (ssh_packet_padding_len 8#i32 16#i32 4#i32) 19#i32,
  checkI32 "hdr_ok" (ssh_packet_header_err_code 16#i32 12#u32 4#i32 35000#i32) 0#i32,
  checkI32 "hdr_over" (ssh_packet_header_err_code 40000#i32 35001#u32 4#i32 35000#i32) 1#i32,
  checkI32 "hdr_small" (ssh_packet_header_err_code 16#i32 4#u32 4#i32 35000#i32) 2#i32,
  checkI32 "hdr_eof" (ssh_packet_header_err_code 15#i32 12#u32 4#i32 35000#i32) 3#i32,
  checkI32 "hdr_align" (ssh_packet_header_err_code 20#i32 13#u32 4#i32 35000#i32) 4#i32,
  checkI32 "hdr_pad3" (ssh_packet_header_err_code 16#i32 12#u32 3#i32 35000#i32) 5#i32,
  checkI32 "hdr_padge" (ssh_packet_header_err_code 16#i32 12#u32 12#i32 35000#i32) 6#i32,
  checkU32 "ct_u" (cert_type_code .User) 1#u32,
  checkU32 "ct_h" (cert_type_code .Host) 2#u32,
  checkOptCT "ctf_1" (cert_type_from_code 1#u32) (some .User),
  checkOptCT "ctf_2" (cert_type_from_code 2#u32) (some .Host),
  checkOptCT "ctf_0" (cert_type_from_code 0#u32) none,
  checkI32 "tv_ok" (cert_time_valid_code 100#u64 50#u64 200#u64) 0#i32,
  checkI32 "tv_early" (cert_time_valid_code 49#u64 50#u64 200#u64) 1#i32,
  checkI32 "tv_exp" (cert_time_valid_code 200#u64 50#u64 200#u64) 2#i32,
  checkI32 "tv_forever" (cert_time_valid_code 18446744073709551615#u64 50#u64 18446744073709551615#u64) 0#i32,
  checkI32 "mask_1" (cidr_rem_mask 1#i32) 128#i32,
  checkI32 "mask_4" (cidr_rem_mask 4#i32) 240#i32,
  checkI32 "mask_7" (cidr_rem_mask 7#i32) 254#i32,
  checkBool "cm_hit" (cidr_byte_match 0xAB#i32 0xA0#i32 4#i32) true,
  checkBool "cm_miss" (cidr_byte_match 0xAB#i32 0xB0#i32 4#i32) false
]

#eval IO.println (String.intercalate "\n" runAll)
