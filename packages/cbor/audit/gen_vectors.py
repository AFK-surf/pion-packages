#!/usr/bin/env python3
"""Targeted RFC 8949 / CTAP2 adversarial vectors for the differential (label<TAB>hex)."""
import sys

V = []


def add(label, hexstr):
    V.append((label, hexstr.replace(" ", "").lower()))


# --- 1. integer extremes (u64 > i64::MAX, -2^64) ---
add("int_u64_max", "1bffffffffffffffff")
add("int_2pow63", "1b8000000000000000")
add("neg_i64_min", "3b7fffffffffffffff")
add("neg_below_i64_min", "3b8000000000000000")
add("neg_minus_2pow64", "3bffffffffffffffff")
add("int_nonminimal_1b", "1817")
add("int_nonminimal_8b", "1b0000000000000001")
add("map_key_u64_max", "a11bffffffffffffffff01")
add("map_key_neg_2pow64", "a13bffffffffffffffff01")
# --- 2. indefinite-length strings ---
add("indef_bytes_ok", "5f4201024103ff")
add("indef_bytes_empty", "5fff")
add("indef_bytes_empty_chunk", "5f40ff")
add("indef_bytes_nested_indef_chunk", "5f5f4101ffff")
add("indef_bytes_text_chunk", "5f6161ff")
add("indef_bytes_int_chunk", "5f00ff")
add("indef_bytes_unterminated", "5f4101")
add("indef_text_ok", "7f657374726561646d696e67ff")
add("indef_text_split_utf8", "7f61c361a9ff")
add("indef_text_nested", "7f7f6161ffff")
add("indef_text_bytes_chunk", "7f4161ff")
add("indef_text_empty_chunk", "7f60ff")
add("indef_array_ok", "9f0102ff")
add("indef_array_unterminated", "9f0102")
add("indef_map_ok", "bf0102ff")
add("indef_map_odd", "bf01ff")
add("indef_map_dup", "bf01020103ff")
add("break_in_definite_array", "8101ff")
add("break_top_level", "ff")
add("break_as_map_value", "a101ff")
add("break_in_tag", "c1ff")
add("indef_bytes_chunk_nonminimal_len", "5f580101ff")
# --- 3. floats ---
add("f16_subnormal_min", "f90001")
add("f16_subnormal_max", "f903ff")
add("f16_neg_zero", "f98000")
add("f16_inf", "f97c00")
add("f16_nan_canonical", "f97e00")
add("f16_nan_payload", "f97e01")
add("f16_snan", "f97c01")
add("f32_nan_payload", "fa7fc00001")
add("f64_nan_payload", "fb7ff8000000000001")
add("f32_shrinkable_1_5", "fa3fc00000")
add("f64_shrinkable_1_5", "fb3ff8000000000000")
add("f64_shrinkable_f32", "fb3ff0000020000000")
add("f64_neg_zero", "fb8000000000000000")
add("f32_subnormal", "fa00000001")
add("f64_f16_subnormal_exact", "fb3e70000000000000")
# --- 4. simple values / reserved additional info ---
for b in ["f800", "f813", "f81f", "f820", "f8ff", "e0", "f3", "fc", "fd", "fe",
          "1c", "1d", "1e", "1f", "3c", "3f", "5c", "7c", "9c", "bc", "dc", "df"]:
    add("simple_or_reserved_" + b, b)
# --- 5. UTF-8 ---
add("utf8_overlong_2", "62c0af")
add("utf8_overlong_3", "63e080af")
add("utf8_surrogate", "63eda080")
add("utf8_above_10ffff", "64f4908080")
add("utf8_f5", "64f5808080")
add("utf8_lone_cont", "6180")
add("utf8_trunc", "62e282")
add("utf8_ok_4byte", "64f09f9880")
add("utf8_nul", "6100")
# --- 6. duplicate map keys ---
add("dup_int", "a201010102")
add("dup_text", "a2616101616102")
add("dup_float", "a2f93c0001f93c0002")
add("dup_nan_keys", "a2f97e0001f97e0002")
add("dup_nan_diff_payload", "a2f97e0001f97e0102")
add("dup_pos_neg_zero", "a2f9000001f9800002")
add("dup_int_vs_float", "a201f6f93c00f6")
add("dup_f16_vs_f64_same_value", "a2f93c0001fb3ff000000000000002")
add("dup_indef_vs_def_text", "a27f6161ff0161610f")
add("dup_array_keys", "a2820102f6820102f6")
add("dup_nonminimal_int", "a201f61801f6")
# --- 7. tags ---
add("tag0_text_ok", "c074323031332d30332d32315432303a30343a30305a")
add("tag0_int", "c000")
add("tag0_bad_date", "c06161")
add("tag1_int", "c11a514b67b0")
add("tag1_float", "c1fb41d452d9ec200000")
add("tag1_text", "c16161")
add("tag1_nan", "c1f97e00")
add("tag2_bignum", "c249010000000000000000")
add("tag2_int", "c201")
add("tag2_text", "c26161")
add("tag3_bignum", "c349010000000000000000")
add("tag3_array", "c380")
add("tag2_empty", "c240")
add("tag2_fits_u64", "c24101")
add("tag_selfdescribe", "d9d9f701")
add("tag_u64_max", "dbffffffffffffffff00")
add("tag_nested_6", "c6c6c6c6c6c600")
add("tag24_embedded_ok", "d81842a100")
# --- 8. trailing / truncated ---
add("trailing_after_int", "0000")
add("trailing_after_map", "a0ff")
add("trunc_map", "a201")
add("empty_top", "")
# --- 9. length bombs ---
add("bomb_bytes_u32", "5affffffff00")
add("bomb_bytes_u64", "5bffffffffffffffff00")
add("bomb_text_i32max", "7a7fffffff61")
add("bomb_array_u64", "9bffffffffffffffff00")
add("bomb_map_u64", "bbffffffffffffffff0000")
add("bomb_array_131073", "9a00020001" + "00" * 16)
add("bomb_indef_chunk_u64", "5f5bffffffffffffffff00ff")
# --- 10. nesting depth (fxamacker default MaxNestedLevels=32) ---
for d in (31, 32, 33):
    add("nest_array_%d" % d, "81" * d + "00")
    add("nest_map_%d" % d, "a100" * d + "00")
    add("nest_tag_%d" % d, "c1" * d + "00")
add("nest_tag_in_array_32", "81" * 16 + "c1" * 16 + "00")

if __name__ == "__main__":
    out = open(sys.argv[1], "w") if len(sys.argv) > 1 else sys.stdout
    for lab, h in V:
        if h:
            out.write(lab + "\t" + h + "\n")
