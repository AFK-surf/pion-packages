import Base64.Types
import Base64.Funs

open Aeneas Aeneas.Std Result Pion base64

private def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

private def report (label : String) (ok_cond : Bool) : IO Unit :=
  IO.println s!"{label}: {if ok_cond then "PASS" else "FAIL"}"

def main : IO Unit := do
  report "b64_enc_pad_0" (okIs (encoded_len 0#i32 true) 0#i32)
  report "b64_enc_pad_1" (okIs (encoded_len 1#i32 true) 4#i32)
  report "b64_enc_pad_2" (okIs (encoded_len 2#i32 true) 4#i32)
  report "b64_enc_pad_3" (okIs (encoded_len 3#i32 true) 4#i32)
  report "b64_enc_nopad_1" (okIs (encoded_len 1#i32 false) 2#i32)
  report "b64_enc_nopad_2" (okIs (encoded_len 2#i32 false) 3#i32)
  report "b64_enc_nopad_10" (okIs (encoded_len 10#i32 false) 14#i32)
  report "b64_dec_len_0" (okIs (b64_decoded_len 0#i32) 0#i32)
  report "b64_dec_len_1_bad" (okIs (b64_decoded_len 1#i32) (-1)#i32)
  report "b64_dec_len_2" (okIs (b64_decoded_len 2#i32) 1#i32)
  report "b64_dec_len_3" (okIs (b64_decoded_len 3#i32) 2#i32)
  report "b64_dec_len_14" (okIs (b64_decoded_len 14#i32) 10#i32)
  report "b64_pack3_abc" (okIs (b64_pack3 97#i32 98#i32 99#i32) 6382179#i32)
  report "b64_pack4_ok" (okIs (b64_pack4_sextets 24#i32 22#i32 9#i32 35#i32) 6382179#i32)
  report "b64_pack4_bad" (okIs (do let v ← b64_pack4_sextets 0#i32 (-1)#i32 0#i32 0#i32; ok (decide (v < 0#i32))) true)
  report "b64_mask_2" (okIs (b64_tail_canonical_mask 2#i32) 15#i32)
  report "b64_mask_3" (okIs (b64_tail_canonical_mask 3#i32) 3#i32)
  report "b64_pad_0" (okIs (b64_expected_pad 0#i32) 0#i32)
  report "b64_pad_2" (okIs (b64_expected_pad 2#i32) 2#i32)
  report "b64_pad_3" (okIs (b64_expected_pad 3#i32) 1#i32)

  report "b32_tsym_0" (okIs (b32_tail_symbols 0#i32) 0#i32)
  report "b32_tsym_1" (okIs (b32_tail_symbols 1#i32) 2#i32)
  report "b32_tsym_2" (okIs (b32_tail_symbols 2#i32) 4#i32)
  report "b32_tsym_3" (okIs (b32_tail_symbols 3#i32) 5#i32)
  report "b32_tsym_4" (okIs (b32_tail_symbols 4#i32) 7#i32)
  report "b32_tbyt_1_bad" (okIs (b32_tail_bytes 1#i32) (-1)#i32)
  report "b32_tbyt_3_bad" (okIs (b32_tail_bytes 3#i32) (-1)#i32)
  report "b32_tbyt_6_bad" (okIs (b32_tail_bytes 6#i32) (-1)#i32)
  report "b32_tbyt_7" (okIs (b32_tail_bytes 7#i32) 4#i32)
  report "b32_enc_pad_6" (okIs (b32_encoded_len 6#i32 true) 16#i32)
  report "b32_enc_nopad_6" (okIs (b32_encoded_len 6#i32 false) 10#i32)
  report "b32_spare_2" (okIs (b32_spare_mask 2#i32) 3#i32)
  report "b32_spare_4" (okIs (b32_spare_mask 4#i32) 15#i32)
  report "b32_spare_5" (okIs (b32_spare_mask 5#i32) 1#i32)
  report "b32_spare_7" (okIs (b32_spare_mask 7#i32) 7#i32)

  report "hex_enc_7" (okIs (hex_encoded_len 7#i32) 14#i32)
  report "hex_dec_14" (okIs (hex_decoded_len 14#i32) 7#i32)
  report "hex_dec_odd" (okIs (hex_decoded_len 15#i32) (-1)#i32)
  report "hex_pack_ab" (okIs (hex_pack_byte 10#i32 11#i32) 171#i32)
  report "hex_pack_bad" (okIs (do let v ← hex_pack_byte 10#i32 (-1)#i32; ok (decide (v < 0#i32))) true)
