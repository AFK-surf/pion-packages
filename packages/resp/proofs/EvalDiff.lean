import Aeneas
import PionLean
import Resp.Types
import Resp.Funs

open Aeneas Aeneas.Std Result Pion resp

private def mkI32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
private def mkI64 (n : Int) : Std.I64 := ⟨BitVec.ofInt 64 n⟩

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def mkLim (mb mbb : Int) : RespLimits :=
  RespLimits.mk (mkI32 64) (mkI32 mb) (mkI32 100) (mkI32 mbb) (mkI32 500) (mkI32 65536)

private def runAll : List String :=
  [ s!"eff_slack={fmtI32 (effective_max_buffer_bytes (mkLim 1000 1000))}"
  , s!"eff_keep={fmtI32 (effective_max_buffer_bytes (mkLim 1000 2000))}"
  , s!"eff_small={fmtI32 (effective_max_buffer_bytes (mkLim 1000 500))}"
  , s!"pfx_plus={fmtBool (is_resp_prefix (mkI32 43))}"
  , s!"pfx_dollar={fmtBool (is_resp_prefix (mkI32 36))}"
  , s!"pfx_star={fmtBool (is_resp_prefix (mkI32 42))}"
  , s!"pfx_tilde={fmtBool (is_resp_prefix (mkI32 126))}"
  , s!"pfx_P={fmtBool (is_resp_prefix (mkI32 80))}"
  , s!"sp_sp={fmtBool (is_inline_space (mkI32 32))}"
  , s!"sp_vt={fmtBool (is_inline_space (mkI32 11))}"
  , s!"sp_a={fmtBool (is_inline_space (mkI32 97))}"
  , s!"hex_0={fmtI32 (hex_nibble (mkI32 48))}"
  , s!"hex_A={fmtI32 (hex_nibble (mkI32 65))}"
  , s!"hex_f={fmtI32 (hex_nibble (mkI32 102))}"
  , s!"hex_bad={fmtI32 (hex_nibble (mkI32 122))}"
  , s!"ovf_pos_ok={fmtBool (i64_parse_will_overflow (mkI64 922337203685477580) (mkI64 7) false)}"
  , s!"ovf_pos_hi={fmtBool (i64_parse_will_overflow (mkI64 922337203685477580) (mkI64 8) false)}"
  , s!"ovf_neg_ok={fmtBool (i64_parse_will_overflow (mkI64 (-922337203685477580)) (mkI64 8) true)}"
  , s!"ovf_neg_lo={fmtBool (i64_parse_will_overflow (mkI64 (-922337203685477580)) (mkI64 9) true)}"
  , s!"crc_0={fmtI32 (crc16_bit_step (mkI32 0))}"
  , s!"crc_msb={fmtI32 (crc16_bit_step (mkI32 32768))}"
  , s!"crc_ffff={fmtI32 (crc16_bit_step (mkI32 65535))}"
  , s!"slot_0={fmtI32 (crc16_to_slot (mkI32 0))}"
  , s!"slot_wrap={fmtI32 (crc16_to_slot (mkI32 16384))}"
  , s!"slot_ffff={fmtI32 (crc16_to_slot (mkI32 65535))}"
  , s!"vslot_0={fmtBool (is_valid_cluster_slot (mkI32 0))}"
  , s!"vslot_max={fmtBool (is_valid_cluster_slot (mkI32 16383))}"
  , s!"vslot_neg={fmtBool (is_valid_cluster_slot (mkI32 (-1)))}"
  , s!"vslot_hi={fmtBool (is_valid_cluster_slot (mkI32 16384))}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
