import Aeneas
import PionLean
import Protobuf.Types
import Protobuf.Funs

open Aeneas Aeneas.Std Result Pion protobuf

private def mkI32 (n : Int) : Std.I32 := ⟨BitVec.ofInt 32 n⟩
private def mkI64 (n : Int) : Std.I64 := ⟨BitVec.ofInt 64 n⟩

private def fmtI32 (r : Result Std.I32) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtI64 (r : Result Std.I64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtU64 (r : Result Std.U64) : String :=
  match r.match with | .ok v => toString v.val | _ => "TRAP"

private def fmtOptWT (r : Result (Option WireType)) : String :=
  match r.match with
  | .ok none => "None"
  | .ok (some .Varint) => "Some(Varint)"
  | .ok (some .Fixed64) => "Some(Fixed64)"
  | .ok (some .LengthDelimited) => "Some(LengthDelimited)"
  | .ok (some .StartGroup) => "Some(StartGroup)"
  | .ok (some .EndGroup) => "Some(EndGroup)"
  | .ok (some .Fixed32) => "Some(Fixed32)"
  | _ => "TRAP"

private def runAll : List String :=
  [ s!"zz32_enc_0={fmtI64 (zigzag_encode_i32 (mkI32 0))}"
  , s!"zz32_enc_m1={fmtI64 (zigzag_encode_i32 (mkI32 (-1)))}"
  , s!"zz32_enc_max={fmtI64 (zigzag_encode_i32 (mkI32 2147483647))}"
  , s!"zz32_enc_min={fmtI64 (zigzag_encode_i32 (mkI32 (-2147483648)))}"
  , s!"zz32_dec_1={fmtI32 (zigzag_decode_i32 (mkI64 1))}"
  , s!"zz32_dec_min={fmtI32 (zigzag_decode_i32 (mkI64 4294967295))}"
  , s!"zz64_enc_0={fmtU64 (zigzag_encode_i64 (mkI64 0))}"
  , s!"zz64_enc_m1={fmtU64 (zigzag_encode_i64 (mkI64 (-1)))}"
  , s!"zz64_enc_max={fmtU64 (zigzag_encode_i64 (mkI64 9223372036854775807))}"
  , s!"zz64_enc_min={fmtU64 (zigzag_encode_i64 (mkI64 (-9223372036854775808)))}"
  , s!"zz64_dec_min={fmtI64 (zigzag_decode_i64 18446744073709551615#u64)}"
  , s!"vlen_0={fmtI32 (varint_len_u64 0#u64)}"
  , s!"vlen_127={fmtI32 (varint_len_u64 127#u64)}"
  , s!"vlen_128={fmtI32 (varint_len_u64 128#u64)}"
  , s!"vlen_16384={fmtI32 (varint_len_u64 16384#u64)}"
  , s!"vlen_max9={fmtI32 (varint_len_u64 9223372036854775807#u64)}"
  , s!"vlen_min10={fmtI32 (varint_len_u64 9223372036854775808#u64)}"
  , s!"vlen_max={fmtI32 (varint_len_u64 18446744073709551615#u64)}"
  , s!"wt_varint={fmtI32 (wire_type_code .Varint)}"
  , s!"wt_fixed32={fmtI32 (wire_type_code .Fixed32)}"
  , s!"wtf_2={fmtOptWT (wire_type_from_code 2#i32)}"
  , s!"wtf_6={fmtOptWT (wire_type_from_code 6#i32)}"
  , s!"tag_enc_1={fmtU64 (encode_tag_raw 1#i32 .Varint)}"
  , s!"tag_enc_max={fmtU64 (encode_tag_raw 536870911#i32 .Fixed32)}"
  , s!"tag_dec_fn={fmtI32 (decode_tag_field_num 4294967293#u64)}"
  , s!"tag_dec_wt={fmtI32 (decode_tag_wire_type 4294967293#u64)}"
  ]

#eval IO.println (String.intercalate "\n" runAll)
