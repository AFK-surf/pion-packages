import Aeneas
import PionLean
import Git.Types
import Git.Funs

open Aeneas Aeneas.Std Result Pion git

private def fmtBool (r : Result Bool) : String :=
  match r.match with | .ok v => if v then "true" else "false" | _ => "TRAP"

private def fmtI32 (r : Result I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def runAll : List String :=
  [ s!"hex_0={fmtI32 (hex_nibble 48#i32)}"
  , s!"hex_9={fmtI32 (hex_nibble 57#i32)}"
  , s!"hex_a={fmtI32 (hex_nibble 97#i32)}"
  , s!"hex_f={fmtI32 (hex_nibble 102#i32)}"
  , s!"hex_A={fmtI32 (hex_nibble 65#i32)}"
  , s!"hex_F={fmtI32 (hex_nibble 70#i32)}"
  , s!"hex_g={fmtI32 (hex_nibble 103#i32)}"
  , s!"hex_min={fmtI32 (hex_nibble (-2147483648)#i32)}"
  , s!"pkt_len_0000={fmtI32 (pkt_line_decode_len 0#i32 0#i32 0#i32 0#i32)}"
  , s!"pkt_len_0010={fmtI32 (pkt_line_decode_len 0#i32 0#i32 1#i32 0#i32)}"
  , s!"pkt_len_fff0={fmtI32 (pkt_line_decode_len 15#i32 15#i32 15#i32 0#i32)}"
  , s!"pkt_len_ffff={fmtI32 (pkt_line_decode_len 15#i32 15#i32 15#i32 15#i32)}"
  , s!"idx_pad_63={fmtI32 (index_v2_padded_len 63#i32)}"
  , s!"idx_pad_64={fmtI32 (index_v2_padded_len 64#i32)}"
  , s!"idx_pad_70={fmtI32 (index_v2_padded_len 70#i32)}"
  , s!"idx_padb_63={fmtI32 (index_v2_pad_bytes 63#i32)}"
  , s!"idx_padb_64={fmtI32 (index_v2_pad_bytes 64#i32)}"
  , s!"idx_padb_70={fmtI32 (index_v2_pad_bytes 70#i32)}"
  , s!"delta_dec_0={fmtI32 (delta_copy_size_decode 0#i32)}"
  , s!"delta_dec_42={fmtI32 (delta_copy_size_decode 42#i32)}"
  , s!"delta_enc_65536={fmtI32 (delta_copy_size_encode 65536#i32)}"
  , s!"delta_enc_42={fmtI32 (delta_copy_size_encode 42#i32)}"
  , s!"delta_rng_ok={fmtBool (delta_copy_range_ok 10#i32 20#i32 30#i32 5#i32 25#i32)}"
  , s!"delta_rng_bad={fmtBool (delta_copy_range_ok 11#i32 20#i32 30#i32 5#i32 25#i32)}"
  , s!"delta_rng_neg={fmtBool (delta_copy_range_ok (-1)#i32 10#i32 30#i32 0#i32 25#i32)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
