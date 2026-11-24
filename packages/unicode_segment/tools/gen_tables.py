#!/usr/bin/env python3
"""Deterministic Unicode 16.0.0 UAX #29 lookup table generator for packages/unicode_segment.

Reads official Unicode 16.0.0 UCD data files:
  - GraphemeBreakProperty.txt
  - WordBreakProperty.txt
  - SentenceBreakProperty.txt
  - emoji-data.txt (Extended_Pictographic)
  - DerivedCoreProperties.txt (InCB=Linker/Consonant/Extend, Alphabetic)
  - UnicodeData.txt (General_Category Nd/Nl/No for unicode_words)

Generates a pure-Pion `src/tables.pion` using ONLY immutable `String` and `Int` constants:
  - 0 `FixedArray`
  - 0 module-level `let mut` or mutable containers (`Array`, `Map`, etc.)
  - O(1) two-level paged lookup for BMP (U+0000..U+FFFF)
  - O(log K) fixed-width base-64 binary search for SMP (U+10000..U+10FFFF)

License of generated Unicode data: Unicode-3.0 (Unicode, Inc.).
"""

import os
import sys

B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

GCB_NAMES = [
    "Other",
    "CR",
    "LF",
    "Control",
    "Extend",
    "ZWJ",
    "Regional_Indicator",
    "Prepend",
    "SpacingMark",
    "L",
    "V",
    "T",
    "LV",
    "LVT",
]
GCB_ID = {name: i for i, name in enumerate(GCB_NAMES)}

INCB_NAMES = ["None", "Linker", "Consonant", "Extend"]
INCB_ID = {name: i for i, name in enumerate(INCB_NAMES)}

WB_NAMES = [
    "Other",
    "CR",
    "LF",
    "Newline",
    "Extend",
    "ZWJ",
    "Regional_Indicator",
    "Format",
    "Katakana",
    "Hebrew_Letter",
    "ALetter",
    "Single_Quote",
    "Double_Quote",
    "MidNumLet",
    "MidLetter",
    "MidNum",
    "Numeric",
    "ExtendNumLet",
    "WSegSpace",
]
WB_ID = {name: i for i, name in enumerate(WB_NAMES)}

SB_NAMES = [
    "Other",
    "CR",
    "LF",
    "Extend",
    "Sep",
    "Format",
    "Sp",
    "Lower",
    "Upper",
    "OLetter",
    "Numeric",
    "ATerm",
    "SContinue",
    "STerm",
    "Close",
]
SB_ID = {name: i for i, name in enumerate(SB_NAMES)}


def parse_ucd_ranges(path, prop_filter=None):
    res = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = [p.strip() for p in line.split(";")]
            if len(parts) < 2:
                continue
            if prop_filter is not None:
                if parts[1] != prop_filter:
                    continue
                val = parts[2] if len(parts) > 2 else True
            else:
                val = parts[1]
            r = parts[0]
            if ".." in r:
                lo_s, hi_s = r.split("..")
                lo, hi = int(lo_s, 16), int(hi_s, 16)
            else:
                lo = hi = int(r, 16)
            for cp in range(lo, hi + 1):
                res[cp] = val
    return res


def parse_numeric_gc(path):
    num = set()
    with open(path, "r", encoding="utf-8") as f:
        first = None
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split(";")
            cp = int(parts[0], 16)
            name = parts[1]
            cat = parts[2]
            if name.endswith(", First>"):
                first = (cp, cat)
                continue
            if name.endswith(", Last>"):
                lo, lcat = first
                if lcat in ("Nd", "Nl", "No"):
                    for c in range(lo, cp + 1):
                        num.add(c)
                first = None
                continue
            if cat in ("Nd", "Nl", "No"):
                num.add(cp)
    return num


def enc_b64_4(v):
    assert 0 <= v < (1 << 24)
    return (
        B64[(v >> 18) & 63]
        + B64[(v >> 12) & 63]
        + B64[(v >> 6) & 63]
        + B64[v & 63]
    )


def build_table(fn, default_val):
    pages = {}
    page_list = []
    page_idx = []
    for p in range(256):
        chunk = bytes(fn(p * 256 + i) for i in range(256))
        idx = pages.get(chunk)
        if idx is None:
            idx = len(page_list)
            pages[chunk] = idx
            page_list.append(chunk)
        page_idx.append(idx)
    assert len(page_list) <= 64, f"too many BMP pages: {len(page_list)}"
    idx_str = "".join(B64[i] for i in page_idx)
    data_str = "".join(chr(65 + b) for chunk in page_list for b in chunk)

    ranges = []
    cur_lo = cur_hi = cur_v = None
    for cp in range(0x10000, 0x110000):
        v = fn(cp)
        if v != default_val:
            if cur_v == v and cp == cur_hi + 1:
                cur_hi = cp
            else:
                if cur_v is not None:
                    ranges.append((cur_lo, cur_hi, cur_v))
                cur_lo = cur_hi = cp
                cur_v = v
        else:
            if cur_v is not None:
                ranges.append((cur_lo, cur_hi, cur_v))
                cur_v = None
    if cur_v is not None:
        ranges.append((cur_lo, cur_hi, cur_v))

    smp_str = "".join(
        enc_b64_4(lo - 0x10000) + enc_b64_4(hi - 0x10000) + chr(65 + v)
        for lo, hi, v in ranges
    )
    return idx_str, data_str, smp_str, len(ranges)


def generate(ucd_dir):
    gcb = parse_ucd_ranges(os.path.join(ucd_dir, "GraphemeBreakProperty.txt"))
    wb = parse_ucd_ranges(os.path.join(ucd_dir, "WordBreakProperty.txt"))
    sb = parse_ucd_ranges(os.path.join(ucd_dir, "SentenceBreakProperty.txt"))
    extpict = parse_ucd_ranges(
        os.path.join(ucd_dir, "emoji-data.txt"), "Extended_Pictographic"
    )
    incb = parse_ucd_ranges(
        os.path.join(ucd_dir, "DerivedCoreProperties.txt"), "InCB"
    )
    alpha = parse_ucd_ranges(
        os.path.join(ucd_dir, "DerivedCoreProperties.txt"), "Alphabetic"
    )
    num = parse_numeric_gc(os.path.join(ucd_dir, "UnicodeData.txt"))

    # Collect unique combos
    g_combos = sorted(
        {
            (
                GCB_ID[gcb.get(cp, "Other")],
                1 if cp in extpict else 0,
                INCB_ID[incb.get(cp, "None")],
            )
            for cp in range(0x110000)
        }
    )
    assert len(g_combos) <= 26, f"too many GCB combos: {len(g_combos)}"
    g_default_tuple = (0, 0, 0)
    g_combos.remove(g_default_tuple)
    g_combos.insert(0, g_default_tuple)
    g_id = {t: i for i, t in enumerate(g_combos)}

    w_combos = sorted(
        {
            (
                WB_ID[wb.get(cp, "Other")],
                1 if cp in extpict else 0,
                1 if (cp in alpha or cp in num) else 0,
            )
            for cp in range(0x110000)
        }
    )
    assert len(w_combos) <= 26, f"too many WB combos: {len(w_combos)}"
    w_default_tuple = (0, 0, 0)
    w_combos.remove(w_default_tuple)
    w_combos.insert(0, w_default_tuple)
    w_id = {t: i for i, t in enumerate(w_combos)}

    g_idx, g_data, g_smp, g_smp_n = build_table(
        lambda cp: g_id[
            (
                GCB_ID[gcb.get(cp, "Other")],
                1 if cp in extpict else 0,
                INCB_ID[incb.get(cp, "None")],
            )
        ],
        0,
    )
    w_idx, w_data, w_smp, w_smp_n = build_table(
        lambda cp: w_id[
            (
                WB_ID[wb.get(cp, "Other")],
                1 if cp in extpict else 0,
                1 if (cp in alpha or cp in num) else 0,
            )
        ],
        0,
    )
    s_idx, s_data, s_smp, s_smp_n = build_table(
        lambda cp: SB_ID[sb.get(cp, "Other")],
        0,
    )

    lines = []
    lines.append(
        "///| Auto-generated by `tools/gen_tables.py` from official Unicode 16.0.0 UCD data."
    )
    lines.append(
        "///| Sources: GraphemeBreakProperty.txt, WordBreakProperty.txt, SentenceBreakProperty.txt,"
    )
    lines.append(
        "///| emoji-data.txt (Extended_Pictographic), DerivedCoreProperties.txt (InCB, Alphabetic),"
    )
    lines.append("///| UnicodeData.txt (General_Category Nd/Nl/No). License: Unicode-3.0.")
    lines.append("///| Zero FixedArray, zero mutable globals: immutable String literals only.")
    lines.append("")

    # Constants
    for i, name in enumerate(GCB_NAMES):
        lines.append(f"let gcb_{name.lower()} : Int = {i}")
    lines.append("")
    for i, name in enumerate(INCB_NAMES):
        lines.append(f"let incb_{name.lower()} : Int = {i}")
    lines.append("")
    for i, name in enumerate(WB_NAMES):
        lines.append(f"let wb_{name.lower()} : Int = {i}")
    lines.append("")
    for i, name in enumerate(SB_NAMES):
        lines.append(f"let sb_{name.lower()} : Int = {i}")
    lines.append("")

    # Base64 decoder
    lines.append("fn b64_val(b : Int) -> Int {")
    lines.append("  if b >= 65 && b <= 90 {")
    lines.append("    b - 65")
    lines.append("  } else if b >= 97 && b <= 122 {")
    lines.append("    b - 97 + 26")
    lines.append("  } else if b >= 48 && b <= 57 {")
    lines.append("    b - 48 + 52")
    lines.append("  } else if b == 45 {")
    lines.append("    62")
    lines.append("  } else {")
    lines.append("    63")
    lines.append("  }")
    lines.append("}")
    lines.append("")
    lines.append("fn b64_u24(s : String, off : Int) -> Int {")
    lines.append("  (b64_val(s.code_unit_at(off)) << 18) |")
    lines.append("  (b64_val(s.code_unit_at(off + 1)) << 12) |")
    lines.append("  (b64_val(s.code_unit_at(off + 2)) << 6) |")
    lines.append("  b64_val(s.code_unit_at(off + 3))")
    lines.append("}")
    lines.append("")
    lines.append(
        "fn lookup_table(cp : Int, idx_s : String, data_s : String, smp_s : String, smp_n : Int) -> Int {"
    )
    lines.append("  if cp < 0 || cp > 0x10FFFF {")
    lines.append("    return 0")
    lines.append("  }")
    lines.append("  if cp < 0x10000 {")
    lines.append("    let page = b64_val(idx_s.code_unit_at(cp >> 8))")
    lines.append("    return data_s.code_unit_at((page << 8) | (cp & 255)) - 65")
    lines.append("  }")
    lines.append("  let target = cp - 0x10000")
    lines.append("  let mut lo = 0")
    lines.append("  let mut hi = smp_n - 1")
    lines.append("  while lo <= hi {")
    lines.append("    let mid = (lo + hi) >> 1")
    lines.append("    let off = mid * 9")
    lines.append("    let r_lo = b64_u24(smp_s, off)")
    lines.append("    if target < r_lo {")
    lines.append("      hi = mid - 1")
    lines.append("    } else {")
    lines.append("      let r_hi = b64_u24(smp_s, off + 4)")
    lines.append("      if target <= r_hi {")
    lines.append("        return smp_s.code_unit_at(off + 8) - 65")
    lines.append("      }")
    lines.append("      lo = mid + 1")
    lines.append("    }")
    lines.append("  }")
    lines.append("  0")
    lines.append("}")
    lines.append("")

    # Packed lookup helpers for Grapheme: returns (gcb | (extpict << 4) | (incb << 5))
    lines.append("///| Decode grapheme combo ID into packed `gcb | (extpict << 4) | (incb << 5)`.")
    lines.append("fn decode_g_combo(id : Int) -> Int {")
    lines.append("  match id {")
    for idx, (g, ep, ic) in enumerate(g_combos):
        packed = g | (ep << 4) | (ic << 5)
        lines.append(f"    {idx} => {packed}")
    lines.append("    _ => 0")
    lines.append("  }")
    lines.append("}")
    lines.append("")

    # Packed lookup helpers for Word: returns (wb | (extpict << 5) | (alnum << 6))
    lines.append("///| Decode word combo ID into packed `wb | (extpict << 5) | (alnum << 6)`.")
    lines.append("fn decode_w_combo(id : Int) -> Int {")
    lines.append("  match id {")
    for idx, (w, ep, al) in enumerate(w_combos):
        packed = w | (ep << 5) | (al << 6)
        lines.append(f"    {idx} => {packed}")
    lines.append("    _ => 0")
    lines.append("  }")
    lines.append("}")
    lines.append("")

    # Tables as immutable String literals
    lines.append(f'let g_bmp_idx : String = "{g_idx}"')
    lines.append(f'let g_bmp_data : String = "{g_data}"')
    lines.append(f'let g_smp_ranges : String = "{g_smp}"')
    lines.append(f"let g_smp_count : Int = {g_smp_n}")
    lines.append("")
    lines.append(f'let w_bmp_idx : String = "{w_idx}"')
    lines.append(f'let w_bmp_data : String = "{w_data}"')
    lines.append(f'let w_smp_ranges : String = "{w_smp}"')
    lines.append(f"let w_smp_count : Int = {w_smp_n}")
    lines.append("")
    lines.append(f'let s_bmp_idx : String = "{s_idx}"')
    lines.append(f'let s_bmp_data : String = "{s_data}"')
    lines.append(f'let s_smp_ranges : String = "{s_smp}"')
    lines.append(f"let s_smp_count : Int = {s_smp_n}")
    lines.append("")

    lines.append("fn lookup_grapheme_packed(cp : Int) -> Int {")
    lines.append("  decode_g_combo(lookup_table(cp, g_bmp_idx, g_bmp_data, g_smp_ranges, g_smp_count))")
    lines.append("}")
    lines.append("")
    lines.append("fn lookup_word_packed(cp : Int) -> Int {")
    lines.append("  decode_w_combo(lookup_table(cp, w_bmp_idx, w_bmp_data, w_smp_ranges, w_smp_count))")
    lines.append("}")
    lines.append("")
    lines.append("fn lookup_sentence_prop(cp : Int) -> Int {")
    lines.append("  lookup_table(cp, s_bmp_idx, s_bmp_data, s_smp_ranges, s_smp_count)")
    lines.append("}")
    lines.append("")

    return "\n".join(lines)


def main():
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} <ucd-16.0.0-dir> <out-tables.pion> [--check]", file=sys.stderr)
        sys.exit(2)
    ucd_dir = sys.argv[1]
    out_path = sys.argv[2]
    check_only = "--check" in sys.argv[3:]
    content = generate(ucd_dir)
    if check_only:
        with open(out_path, "r", encoding="utf-8") as f:
            existing = f.read()
        if existing != content:
            print(f"FAIL: {out_path} differs from generated output", file=sys.stderr)
            sys.exit(1)
        print(f"OK: {out_path} matches deterministic Unicode 16.0.0 generation ({len(content)} bytes)")
    else:
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"Wrote {out_path} ({len(content)} bytes)")


if __name__ == "__main__":
    main()
