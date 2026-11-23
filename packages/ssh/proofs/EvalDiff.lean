import Aeneas
import PionLean
import Ssh.Types
import Ssh.Funs

open Aeneas Aeneas.Std Result Pion ssh

private def fmtI32 (r : Result I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtU32 (r : Result U32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtOptCT (r : Result (Option CertType)) : String :=
  match r.match with
  | .ok none => "None"
  | .ok (some .User) => "Some(User)"
  | .ok (some .Host) => "Some(Host)"
  | _ => "TRAP"

private def runAll : List String :=
  [ s!"pad_0_8={fmtI32 (ssh_packet_padding_len 0#i32 8#i32 4#i32)}"
  , s!"pad_3_8={fmtI32 (ssh_packet_padding_len 3#i32 8#i32 4#i32)}"
  , s!"pad_7_16={fmtI32 (ssh_packet_padding_len 7#i32 16#i32 4#i32)}"
  , s!"pad_8_16={fmtI32 (ssh_packet_padding_len 8#i32 16#i32 4#i32)}"
  , s!"hdr_ok={fmtI32 (ssh_packet_header_err_code 16#i32 12#u32 4#i32 35000#i32)}"
  , s!"hdr_over={fmtI32 (ssh_packet_header_err_code 40000#i32 35001#u32 4#i32 35000#i32)}"
  , s!"hdr_small={fmtI32 (ssh_packet_header_err_code 16#i32 4#u32 4#i32 35000#i32)}"
  , s!"hdr_eof={fmtI32 (ssh_packet_header_err_code 15#i32 12#u32 4#i32 35000#i32)}"
  , s!"hdr_align={fmtI32 (ssh_packet_header_err_code 20#i32 13#u32 4#i32 35000#i32)}"
  , s!"hdr_pad3={fmtI32 (ssh_packet_header_err_code 16#i32 12#u32 3#i32 35000#i32)}"
  , s!"hdr_padge={fmtI32 (ssh_packet_header_err_code 16#i32 12#u32 12#i32 35000#i32)}"
  , s!"ct_u={fmtU32 (cert_type_code .User)}"
  , s!"ct_h={fmtU32 (cert_type_code .Host)}"
  , s!"ctf_1={fmtOptCT (cert_type_from_code 1#u32)}"
  , s!"ctf_2={fmtOptCT (cert_type_from_code 2#u32)}"
  , s!"ctf_0={fmtOptCT (cert_type_from_code 0#u32)}"
  , s!"tv_ok={fmtI32 (cert_time_valid_code 100#u64 50#u64 200#u64)}"
  , s!"tv_early={fmtI32 (cert_time_valid_code 49#u64 50#u64 200#u64)}"
  , s!"tv_exp={fmtI32 (cert_time_valid_code 200#u64 50#u64 200#u64)}"
  , s!"tv_forever={fmtI32 (cert_time_valid_code 18446744073709551615#u64 50#u64 18446744073709551615#u64)}"
  , s!"mask_1={fmtI32 (cidr_rem_mask 1#i32)}"
  , s!"mask_4={fmtI32 (cidr_rem_mask 4#i32)}"
  , s!"mask_7={fmtI32 (cidr_rem_mask 7#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
