import Base64.Types
import Base64.Funs

open Aeneas Aeneas.Std Result Pion base64

namespace Base64EvalDiff

def fmtI32 (r : Result Std.I32) : String :=
  match r.match with
  | .ok v => toString v.val
  | _ => "TRAP"

#eval show IO Unit from do
  -- Base64 full-domain boundaries (including 512 MiB, 1.5 GiB saturation, INT32_MIN/MAX)
  IO.println s!"b64_enc_0_t={fmtI32 (encoded_len 0#i32 true)}"
  IO.println s!"b64_enc_neg1_f={fmtI32 (encoded_len (-1)#i32 false)}"
  IO.println s!"b64_enc_min_t={fmtI32 (encoded_len (-2147483648)#i32 true)}"
  IO.println s!"b64_enc_512m_f={fmtI32 (encoded_len 536870912#i32 false)}"
  IO.println s!"b64_enc_512m_t={fmtI32 (encoded_len 536870912#i32 true)}"
  IO.println s!"b64_enc_fit_f={fmtI32 (encoded_len 1610612734#i32 false)}"
  IO.println s!"b64_enc_sat_f={fmtI32 (encoded_len 1610612735#i32 false)}"
  IO.println s!"b64_enc_max_t={fmtI32 (encoded_len 2147483647#i32 true)}"
  IO.println s!"b64_dec_512m={fmtI32 (b64_decoded_len 715827883#i32)}"
  IO.println s!"b64_dec_mod1={fmtI32 (b64_decoded_len 5#i32)}"
  IO.println s!"b64_dec_neg1={fmtI32 (b64_decoded_len (-1)#i32)}"
  IO.println s!"b64_dec_min={fmtI32 (b64_decoded_len (-2147483648)#i32)}"
  -- Base64 bit-packing
  IO.println s!"b64_pack3_abc={fmtI32 (b64_pack3 0x4D#i32 0x61#i32 0x6E#i32)}"
  IO.println s!"b64_pack4_ok={fmtI32 (b64_pack4_sextets 19#i32 22#i32 5#i32 46#i32)}"
  IO.println s!"b64_pack4_err={fmtI32 (b64_pack4_sextets 0#i32 (-1)#i32 0#i32 0#i32)}"
  -- Hex full-domain boundaries (including 1 GiB saturation, INT32_MIN/MAX)
  IO.println s!"hex_enc_0={fmtI32 (hex_encoded_len 0#i32)}"
  IO.println s!"hex_enc_min={fmtI32 (hex_encoded_len (-2147483648)#i32)}"
  IO.println s!"hex_enc_fit={fmtI32 (hex_encoded_len 1073741823#i32)}"
  IO.println s!"hex_enc_1g={fmtI32 (hex_encoded_len 1073741824#i32)}"
  IO.println s!"hex_enc_max={fmtI32 (hex_encoded_len 2147483647#i32)}"
  IO.println s!"hex_dec_fit={fmtI32 (hex_decoded_len 2147483646#i32)}"
  IO.println s!"hex_dec_odd={fmtI32 (hex_decoded_len 2147483647#i32)}"
  IO.println s!"hex_dec_neg={fmtI32 (hex_decoded_len (-2)#i32)}"
  IO.println s!"hex_pack_ab={fmtI32 (hex_pack_byte 10#i32 11#i32)}"
  IO.println s!"hex_pack_err={fmtI32 (hex_pack_byte (-1)#i32 0#i32)}"
  -- Base32 full-domain boundaries (including 1 GiB, 1.25 GiB saturation, INT32_MIN/MAX)
  IO.println s!"b32_enc_0_t={fmtI32 (b32_encoded_len 0#i32 true)}"
  IO.println s!"b32_enc_min_f={fmtI32 (b32_encoded_len (-2147483648)#i32 false)}"
  IO.println s!"b32_enc_1g_f={fmtI32 (b32_encoded_len 1073741824#i32 false)}"
  IO.println s!"b32_enc_1g_t={fmtI32 (b32_encoded_len 1073741824#i32 true)}"
  IO.println s!"b32_enc_fit_f={fmtI32 (b32_encoded_len 1342177279#i32 false)}"
  IO.println s!"b32_enc_sat_f={fmtI32 (b32_encoded_len 1342177280#i32 false)}"
  IO.println s!"b32_enc_max_t={fmtI32 (b32_encoded_len 2147483647#i32 true)}"

end Base64EvalDiff
