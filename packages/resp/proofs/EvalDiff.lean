import Aeneas
import PionLean
import Resp.Types
import Resp.Funs

open Aeneas Aeneas.Std Result Pion resp

namespace RespEvalDiff

private def mkI32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
private def mkI64 (n : Int) : Std.I64 := ⟨BitVec.ofInt 64 n⟩

private def checkCase [BEq α] (label : String) (r : Result α) (expected : α) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

def runAll : List String :=
  [ checkCase "lim_def_d" (do let l ← RespLimits.default; ok l.max_depth) (mkI32 128)
  , checkCase "lim_def_b" (do let l ← RespLimits.default; ok l.max_bulk_len) (mkI32 67108864)
  , checkCase "lim_def_il" (do let l ← RespLimits.default; ok l.max_inline_len) (mkI32 65536)
  , checkCase "lim_wil" (do let l ← RespLimits.new (mkI32 64) (mkI32 1024) (mkI32 100) (mkI32 1024) (mkI32 500); let l2 ← RespLimits.with_max_inline_len l (mkI32 4096); ok l2.max_inline_len) (mkI32 4096)
  , checkCase "eff_slack" (do let l ← RespLimits.new (mkI32 64) (mkI32 1000) (mkI32 100) (mkI32 1000) (mkI32 500); effective_max_buffer_bytes l) (mkI32 1016)
  , checkCase "eff_keep" (do let l ← RespLimits.new (mkI32 64) (mkI32 1000) (mkI32 100) (mkI32 2000) (mkI32 500); effective_max_buffer_bytes l) (mkI32 2000)
  , checkCase "eff_small" (do let l ← RespLimits.new (mkI32 64) (mkI32 1000) (mkI32 100) (mkI32 500) (mkI32 500); effective_max_buffer_bytes l) (mkI32 500)
  , checkCase "pfx_plus" (is_resp_prefix (mkI32 43)) true
  , checkCase "pfx_dollar" (is_resp_prefix (mkI32 36)) true
  , checkCase "pfx_star" (is_resp_prefix (mkI32 42)) true
  , checkCase "pfx_tilde" (is_resp_prefix (mkI32 126)) true
  , checkCase "pfx_pipe" (is_resp_prefix (mkI32 124)) true
  , checkCase "pfx_gt" (is_resp_prefix (mkI32 62)) true
  , checkCase "pfx_P" (is_resp_prefix (mkI32 80)) false
  , checkCase "pfx_sp" (is_resp_prefix (mkI32 32)) false
  , checkCase "sp_sp" (is_inline_space (mkI32 32)) true
  , checkCase "sp_vt" (is_inline_space (mkI32 11)) true
  , checkCase "sp_cr" (is_inline_space (mkI32 13)) true
  , checkCase "sp_a" (is_inline_space (mkI32 97)) false
  , checkCase "hex_0" (hex_nibble (mkI32 48)) (mkI32 0)
  , checkCase "hex_9" (hex_nibble (mkI32 57)) (mkI32 9)
  , checkCase "hex_A" (hex_nibble (mkI32 65)) (mkI32 10)
  , checkCase "hex_f" (hex_nibble (mkI32 102)) (mkI32 15)
  , checkCase "hex_bad" (hex_nibble (mkI32 122)) (mkI32 (-1))
  , checkCase "ovf_pos_ok" (i64_parse_will_overflow (mkI64 922337203685477580) (mkI64 7) false) false
  , checkCase "ovf_pos_hi" (i64_parse_will_overflow (mkI64 922337203685477580) (mkI64 8) false) true
  , checkCase "ovf_neg_ok" (i64_parse_will_overflow (mkI64 (-922337203685477580)) (mkI64 8) true) false
  , checkCase "ovf_neg_lo" (i64_parse_will_overflow (mkI64 (-922337203685477580)) (mkI64 9) true) true
  , checkCase "crc_0" (crc16_bit_step (mkI32 0)) (mkI32 0)
  , checkCase "crc_msb" (crc16_bit_step (mkI32 32768)) (mkI32 4129)
  , checkCase "crc_low" (crc16_bit_step (mkI32 1234)) (mkI32 2468)
  , checkCase "crc_ffff" (crc16_bit_step (mkI32 65535)) (mkI32 61407)
  , checkCase "slot_0" (crc16_to_slot (mkI32 0)) (mkI32 0)
  , checkCase "slot_wrap" (crc16_to_slot (mkI32 16384)) (mkI32 0)
  , checkCase "slot_ffff" (crc16_to_slot (mkI32 65535)) (mkI32 16383)
  , checkCase "vslot_0" (is_valid_cluster_slot (mkI32 0)) true
  , checkCase "vslot_max" (is_valid_cluster_slot (mkI32 16383)) true
  , checkCase "vslot_neg" (is_valid_cluster_slot (mkI32 (-1))) false
  , checkCase "vslot_hi" (is_valid_cluster_slot (mkI32 16384)) false
  , checkCase "vran_ok" (is_valid_slot_range (mkI32 0) (mkI32 16383)) true
  , checkCase "vran_eq" (is_valid_slot_range (mkI32 5461) (mkI32 5461)) true
  , checkCase "vran_rev" (is_valid_slot_range (mkI32 100) (mkI32 99)) false
  , checkCase "vran_neg" (is_valid_slot_range (mkI32 (-1)) (mkI32 10)) false
  , checkCase "vran_hi" (is_valid_slot_range (mkI32 0) (mkI32 16384)) false
  ]

#eval IO.println (String.intercalate "\n" runAll)

end RespEvalDiff
