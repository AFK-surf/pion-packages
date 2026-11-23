import Flate.Types
import Flate.Funs

open Aeneas Aeneas.Std Result Pion flate

def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool :=
  r.reducesTo expected

def check (label : String) (b : Bool) : IO Unit :=
  IO.println s!"{label}: {if b then "PASS" else "FAIL"}"

def main : IO Unit := do
  -- Limits & level & btype & stored nlen
  check "level_neg1_false" (okIs (is_valid_level (-1)#i32) false)
  check "level_0_true" (okIs (is_valid_level 0#i32) true)
  check "level_9_true" (okIs (is_valid_level 9#i32) true)
  check "level_10_false" (okIs (is_valid_level 10#i32) false)
  check "limits_default" (okIs (do let l ← DecompressLimits.default; ok l.max_output_bytes) 268435456#i32)
  check "limits_new_1024" (okIs (do let l ← DecompressLimits.new 1024#i32; ok l.max_output_bytes) 1024#i32)
  check "btype_0_true" (okIs (is_valid_btype 0#i32) true)
  check "btype_2_true" (okIs (is_valid_btype 2#i32) true)
  check "btype_3_false" (okIs (is_valid_btype 3#i32) false)
  check "nlen_0_ffff" (okIs (is_valid_stored_nlen 0#i32 65535#i32) true)
  check "nlen_1234_ok" (okIs (is_valid_stored_nlen 1234#i32 64301#i32) true)
  check "nlen_1234_bad" (okIs (is_valid_stored_nlen 1234#i32 64300#i32) false)

  -- Zlib RFC 1950
  check "zlib_flevel_0" (okIs (zlib_flevel 0#i32) 0#i32)
  check "zlib_flevel_1" (okIs (zlib_flevel 1#i32) 0#i32)
  check "zlib_flevel_5" (okIs (zlib_flevel 5#i32) 1#i32)
  check "zlib_flevel_6" (okIs (zlib_flevel 6#i32) 2#i32)
  check "zlib_flevel_9" (okIs (zlib_flevel 9#i32) 3#i32)
  check "zlib_flg_0" (okIs (zlib_compute_flg 120#i32 0#i32) 1#i32)
  check "zlib_flg_1" (okIs (zlib_compute_flg 120#i32 1#i32) 94#i32)
  check "zlib_flg_2" (okIs (zlib_compute_flg 120#i32 2#i32) 156#i32)
  check "zlib_flg_3" (okIs (zlib_compute_flg 120#i32 3#i32) 218#i32)
  check "zlib_chk_78_9c_ok" (okIs (zlib_check_header 120#i32 156#i32) 0#i32)
  check "zlib_chk_fcheck_err" (okIs (zlib_check_header 120#i32 155#i32) 1#i32)
  check "zlib_chk_cm_err" (okIs (zlib_check_header 121#i32 24#i32) 2#i32)
  check "zlib_chk_cinfo_err" (okIs (zlib_check_header 136#i32 28#i32) 3#i32)

  -- Huffman LUT & bit_reverse
  check "huff_direct_65_8" (okIs (huff_direct_entry 65#i32 8#i32) 2088#i32)
  check "huff_subtable_1024_5" (okIs (huff_subtable_entry 1024#i32 5#i32) 32789#i32)
  check "bit_rev_0_0" (okIs (bit_reverse 0#i32 0#i32) 0#i32)
  check "bit_rev_1_3" (okIs (bit_reverse 1#i32 3#i32) 4#i32)
  check "bit_rev_5_4" (okIs (bit_reverse 5#i32 4#i32) 10#i32)
  check "bit_rev_13_8" (okIs (bit_reverse 13#i32 8#i32) 176#i32)

  -- Checksums (Adler-32 & IEEE CRC-32)
  check "adler_pack_1_0" (okIs (adler32_pack 1#u32 0#u32) 1#u32)
  check "adler_pack_sample" (okIs (adler32_pack 500#u32 1000#u32) 65536500#u32)
  check "crc32_poly_0" (okIs (crc32_byte_poly 0#u32) 0#u32)
  check "crc32_poly_1" (okIs (crc32_byte_poly 1#u32) 1996959894#u32)
  check "crc32_poly_128" (okIs (crc32_byte_poly 128#u32) 3988292384#u32)
  check "crc32_poly_255" (okIs (crc32_byte_poly 255#u32) 755167117#u32)
