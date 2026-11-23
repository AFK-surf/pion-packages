import Aeneas
import PionLean
import Protobuf.Types
import Protobuf.Funs

open Aeneas Aeneas.Std Result Pion protobuf

private def mkI32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
private def mkI64 (n : Int) : Std.I64 := ⟨BitVec.ofInt 64 n⟩

private def checkCase {α : Type} [BEq α] (label : String) (r : Result α) (expected : α) : String :=
  if r.reducesTo expected then s!"{label}: PASS" else s!"{label}: FAIL"

def runAll : List String := [
  -- ZigZag i32
  checkCase "zz32_enc_0" (zigzag_encode_i32 (mkI32 0)) (mkI64 0),
  checkCase "zz32_enc_m1" (zigzag_encode_i32 (mkI32 (-1))) (mkI64 1),
  checkCase "zz32_enc_1" (zigzag_encode_i32 (mkI32 1)) (mkI64 2),
  checkCase "zz32_enc_m2" (zigzag_encode_i32 (mkI32 (-2))) (mkI64 3),
  checkCase "zz32_enc_max" (zigzag_encode_i32 (mkI32 2147483647)) (mkI64 4294967294),
  checkCase "zz32_enc_min" (zigzag_encode_i32 (mkI32 (-2147483648))) (mkI64 4294967295),
  checkCase "zz32_dec_0" (zigzag_decode_i32 (mkI64 0)) (mkI32 0),
  checkCase "zz32_dec_1" (zigzag_decode_i32 (mkI64 1)) (mkI32 (-1)),
  checkCase "zz32_dec_max" (zigzag_decode_i32 (mkI64 4294967294)) (mkI32 2147483647),
  checkCase "zz32_dec_min" (zigzag_decode_i32 (mkI64 4294967295)) (mkI32 (-2147483648)),
  -- ZigZag i64
  checkCase "zz64_enc_0" (zigzag_encode_i64 (mkI64 0)) 0#u64,
  checkCase "zz64_enc_m1" (zigzag_encode_i64 (mkI64 (-1))) 1#u64,
  checkCase "zz64_enc_1" (zigzag_encode_i64 (mkI64 1)) 2#u64,
  checkCase "zz64_enc_max" (zigzag_encode_i64 (mkI64 9223372036854775807)) 18446744073709551614#u64,
  checkCase "zz64_enc_min" (zigzag_encode_i64 (mkI64 (-9223372036854775808))) 18446744073709551615#u64,
  checkCase "zz64_dec_0" (zigzag_decode_i64 0#u64) (mkI64 0),
  checkCase "zz64_dec_1" (zigzag_decode_i64 1#u64) (mkI64 (-1)),
  checkCase "zz64_dec_min" (zigzag_decode_i64 18446744073709551615#u64) (mkI64 (-9223372036854775808)),
  -- varint_len_u64
  checkCase "vlen_0" (varint_len_u64 0#u64) 1#i32,
  checkCase "vlen_127" (varint_len_u64 127#u64) 1#i32,
  checkCase "vlen_128" (varint_len_u64 128#u64) 2#i32,
  checkCase "vlen_16383" (varint_len_u64 16383#u64) 2#i32,
  checkCase "vlen_16384" (varint_len_u64 16384#u64) 3#i32,
  checkCase "vlen_268435456" (varint_len_u64 268435456#u64) 5#i32,
  checkCase "vlen_max9" (varint_len_u64 9223372036854775807#u64) 9#i32,
  checkCase "vlen_min10" (varint_len_u64 9223372036854775808#u64) 10#i32,
  checkCase "vlen_max" (varint_len_u64 18446744073709551615#u64) 10#i32,
  -- WireType & tags
  checkCase "wt_varint" (wire_type_code .Varint) 0#i32,
  checkCase "wt_fixed32" (wire_type_code .Fixed32) 5#i32,
  checkCase "wtf_2" (wire_type_from_code 2#i32) (some .LengthDelimited),
  checkCase "wtf_6" (wire_type_from_code 6#i32) none,
  checkCase "tag_enc_1" (encode_tag_raw 1#i32 .Varint) 8#u64,
  checkCase "tag_enc_max" (encode_tag_raw 536870911#i32 .Fixed32) 4294967293#u64,
  checkCase "tag_dec_fn" (decode_tag_field_num 4294967293#u64) 536870911#i32,
  checkCase "tag_dec_wt" (decode_tag_wire_type 4294967293#u64) 5#i32,
  checkCase "taglen_15" (tag_len 15#i32) 1#i32,
  checkCase "taglen_16" (tag_len 16#i32) 2#i32,
  checkCase "taglen_max" (tag_len 536870911#i32) 5#i32,
  -- field_number_err_code
  checkCase "fn_0" (field_number_err_code 0#i32 false) 1#i32,
  checkCase "fn_1" (field_number_err_code 1#i32 true) 0#i32,
  checkCase "fn_19000_t" (field_number_err_code 19000#i32 true) 2#i32,
  checkCase "fn_19000_f" (field_number_err_code 19000#i32 false) 0#i32,
  checkCase "fn_max" (field_number_err_code 536870911#i32 true) 0#i32,
  checkCase "fn_over" (field_number_err_code 536870912#i32 false) 1#i32
]

#eval IO.println (String.intercalate "\n" runAll)
