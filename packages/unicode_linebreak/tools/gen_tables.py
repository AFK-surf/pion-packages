#!/usr/bin/env python3
"""Deterministic Unicode 16.0.0 UAX #14 table generator for packages/unicode_linebreak.

Reads official Unicode 16.0.0 UCD data files:
  - LineBreak.txt
  - EastAsianWidth.txt
  - UnicodeData.txt
  - emoji-data.txt

Generates a compact, zero-FixedArray, zero-mutable-global, pure-ASCII String
3-level lookup table in `src/tables.pion` with O(1) lookup for all 1,114,112
Unicode code points (U+0000..U+10FFFF).

Usage:
  python3 packages/unicode_linebreak/tools/gen_tables.py <ucd_dir> <out_file>
  python3 packages/unicode_linebreak/tools/gen_tables.py --check <ucd_dir> <out_file>
"""

import os
import sys

RAW_CLASSES = [
    "AI", "AK", "AL", "AP", "AS", "B2", "BA", "BB", "BK", "CB",
    "CJ", "CL", "CM", "CP", "CR", "EB", "EM", "EX", "GL", "H2",
    "H3", "HL", "HY", "ID", "IN", "IS", "JL", "JT", "JV", "LF",
    "NL", "NS", "NU", "OP", "PO", "PR", "QU", "RI", "SA", "SG",
    "SP", "SY", "VF", "VI", "WJ", "XX", "ZW", "ZWJ",
]
RAW_CLASS_TO_ID = {name: i for i, name in enumerate(RAW_CLASSES)}

# Resolved classes after LB1 (42 values; AI/SG/XX -> AL, CJ -> NS, SA -> CM or AL)
RES_CLASSES = [
    "AK", "AL", "AP", "AS", "B2", "BA", "BB", "BK", "CB", "CL",
    "CM", "CP", "CR", "EB", "EM", "EX", "GL", "H2", "H3", "HL",
    "HY", "ID", "IN", "IS", "JL", "JT", "JV", "LF", "NL", "NS",
    "NU", "OP", "PO", "PR", "QU", "RI", "SP", "SY", "VF", "VI",
    "WJ", "ZW", "ZWJ",
]
RES_CLASS_TO_ID = {name: i for i, name in enumerate(RES_CLASSES)}

# Printable ASCII alphabet of length 90 excluding '"' (34) and '\' (92) and control chars.
# Uses characters from 0x23 ('#') to 0x7E ('~'), skipping '\\' (0x5C):
# 0x23..0x5B = 57 chars (indices 0..56)
# 0x5D..0x7E = 34 chars (indices 57..90) => 91 safe printable ASCII chars!
ALPHABET = "".join(chr(c) for c in range(0x23, 0x7F) if c != 0x5C)
assert len(ALPHABET) == 91
assert '"' not in ALPHABET and "\\" not in ALPHABET


def encode_1(v: int) -> str:
    if not (0 <= v < 91):
        raise ValueError(f"value {v} out of 1-char alphabet range 0..90")
    return ALPHABET[v]


def encode_2(v: int) -> str:
    if not (0 <= v < 91 * 91):
        raise ValueError(f"value {v} out of 2-char alphabet range")
    return ALPHABET[v // 91] + ALPHABET[v % 91]


def load_ucd(ucd_dir: str):
    # 1. LineBreak.txt with @missing and unassigned block defaults per
    # Unicode 16.0.0 DerivedLineBreak.txt (Note: U+1F800..U+1F8FF defaults to XX, not ID).
    lb = ["XX"] * 0x110000
    for lo, hi in [
        (0x3400, 0x4DBF),
        (0x4E00, 0x9FFF),
        (0xF900, 0xFAFF),
        (0x1F000, 0x1F7FF),
        (0x1F900, 0x1FAFF),
        (0x1FC00, 0x1FFFD),
        (0x20000, 0x2FFFD),
        (0x30000, 0x3FFFD),
    ]:
        for cp in range(lo, hi + 1):
            lb[cp] = "ID"
    for cp in range(0x20A0, 0x20D0):
        lb[cp] = "PR"

    with open(os.path.join(ucd_dir, "LineBreak.txt"), "r", encoding="utf-8") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            rng, val = [x.strip() for x in s.split(";")]
            if ".." in rng:
                lo, hi = [int(x, 16) for x in rng.split("..")]
                for cp in range(lo, hi + 1):
                    lb[cp] = val
            else:
                lb[int(rng, 16)] = val

    # 2. EastAsianWidth.txt with @missing and unassigned block defaults per EastAsianWidth-16.0.0.txt
    ea = [False] * 0x110000
    for lo, hi in [
        (0x3400, 0x4DBF),
        (0x4E00, 0x9FFF),
        (0xF900, 0xFAFF),
        (0x20000, 0x2FFFD),
        (0x30000, 0x3FFFD),
    ]:
        for cp in range(lo, hi + 1):
            ea[cp] = True

    with open(os.path.join(ucd_dir, "EastAsianWidth.txt"), "r", encoding="utf-8") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            rng, val = [x.strip() for x in s.split(";")]
            is_ea = val in ("F", "W", "H")
            if ".." in rng:
                lo, hi = [int(x, 16) for x in rng.split("..")]
                for cp in range(lo, hi + 1):
                    ea[cp] = is_ea
            else:
                ea[int(rng, 16)] = is_ea

    # 3. UnicodeData.txt -> General_Category
    gc = ["Cn"] * 0x110000
    with open(os.path.join(ucd_dir, "UnicodeData.txt"), "r", encoding="utf-8") as f:
        range_start = None
        for line in f:
            parts = line.rstrip("\r\n").split(";")
            if len(parts) < 3:
                continue
            cp = int(parts[0], 16)
            name, cat = parts[1], parts[2]
            if name.endswith(", First>"):
                range_start = (cp, cat)
            elif name.endswith(", Last>"):
                lo, lcat = range_start
                for c in range(lo, cp + 1):
                    gc[c] = lcat
                range_start = None
            else:
                gc[cp] = cat

    # 4. emoji-data.txt -> Extended_Pictographic
    extpict = [False] * 0x110000
    with open(os.path.join(ucd_dir, "emoji-data.txt"), "r", encoding="utf-8") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            rng, prop = [x.strip() for x in s.split(";")]
            if prop != "Extended_Pictographic":
                continue
            if ".." in rng:
                lo, hi = [int(x, 16) for x in rng.split("..")]
                for cp in range(lo, hi + 1):
                    extpict[cp] = True
            else:
                extpict[int(rng, 16)] = True

    return lb, ea, gc, extpict


def resolve_lb1(raw_cls: str, cat: str) -> str:
    if raw_cls in ("AI", "SG", "XX"):
        return "AL"
    if raw_cls == "SA":
        return "CM" if cat in ("Mn", "Mc") else "AL"
    if raw_cls == "CJ":
        return "NS"
    return raw_cls


def chunk_string(name: str, data: str, width: int = 100) -> str:
    lines = [f"let {name} : String ="]
    parts = [data[i : i + width] for i in range(0, len(data), width)]
    for idx, part in enumerate(parts):
        suffix = " +" if idx + 1 < len(parts) else ""
        lines.append(f'"{part}"{suffix}')
    return "\n".join(lines)


def generate(ucd_dir: str) -> str:
    lb, ea, gc, extpict = load_ucd(ucd_dir)

    # Bit flags packed into combo_flags (6 bits, 0..63):
    #   bit 0 (1):  is_ea (EastAsianWidth in {F, W, H})
    #   bit 1 (2):  is_qu_pi (LB == QU && GC == Pi)
    #   bit 2 (4):  is_qu_pf (LB == QU && GC == Pf)
    #   bit 3 (8):  is_ep_cn (Extended_Pictographic && GC == Cn)
    #   bit 4 (16): is_u2010 (cp == U+2010 HYPHEN)
    #   bit 5 (32): is_u25cc (cp == U+25CC DOTTED CIRCLE)
    combos_map = {}
    combos_list = []
    cp_combo = [0] * 0x110000

    for cp in range(0x110000):
        raw = lb[cp]
        cat = gc[cp]
        res = resolve_lb1(raw, cat)
        flags = 0
        if ea[cp]:
            flags |= 1
        if raw == "QU" and cat == "Pi":
            flags |= 2
        if raw == "QU" and cat == "Pf":
            flags |= 4
        if extpict[cp] and cat == "Cn":
            flags |= 8
        if cp == 0x2010:
            flags |= 16
        if cp == 0x25CC:
            flags |= 32
        key = (RAW_CLASS_TO_ID[raw], RES_CLASS_TO_ID[res], flags)
        cid = combos_map.get(key)
        if cid is None:
            cid = len(combos_list)
            combos_map[key] = cid
            combos_list.append(key)
        cp_combo[cp] = cid

    assert len(combos_list) <= 91, f"Too many combos ({len(combos_list)}) for 1-char encoding"

    # Build 3-level table:
    #   Level 3: blocks of 128 codepoints -> 1-char combo IDs
    #   Level 2: pages of 64 level-3 block IDs (covering 8192 codepoints) -> 2-char base-91 block IDs
    #   Level 1: 136 entries (0x110000 / 8192 = 136) -> 1-char level-2 page IDs
    l3_map = {}
    l3_blocks = []
    l3_idx = []
    for base in range(0, 0x110000, 128):
        blk = tuple(cp_combo[base : base + 128])
        bid = l3_map.get(blk)
        if bid is None:
            bid = len(l3_blocks)
            l3_map[blk] = bid
            l3_blocks.append(blk)
        l3_idx.append(bid)

    l2_map = {}
    l2_pages = []
    l1_idx = []
    for base in range(0, len(l3_idx), 64):
        page = tuple(l3_idx[base : base + 64])
        pid = l2_map.get(page)
        if pid is None:
            pid = len(l2_pages)
            l2_map[page] = pid
            l2_pages.append(page)
        l1_idx.append(pid)

    assert len(l2_pages) <= 91, f"Too many stage2 pages ({len(l2_pages)})"
    assert len(l3_blocks) < 91 * 91

    ascii_str = "".join(encode_1(cp_combo[cp]) for cp in range(128))
    ascii_res_str = "".join(encode_1(combos_list[cp_combo[cp]][1]) for cp in range(128))
    combo_raw_str = "".join(encode_1(raw_id) for raw_id, _, _ in combos_list)
    combo_res_str = "".join(encode_1(res_id) for _, res_id, _ in combos_list)
    combo_flags_str = "".join(encode_1(flags) for _, _, flags in combos_list)
    stage1_str = "".join(encode_1(pid) for pid in l1_idx)
    stage2_str = "".join(encode_2(bid) for page in l2_pages for bid in page)
    stage3_str = "".join(encode_1(cid) for blk in l3_blocks for cid in blk)

    out = []
    out.append("///| Auto-generated by `tools/gen_tables.py` from Unicode 16.0.0 UCD (Unicode-3.0 license).")
    out.append("///| Sources: LineBreak.txt, EastAsianWidth.txt, UnicodeData.txt, emoji-data.txt.")
    out.append(f"///| Combos: {len(combos_list)}, Stage1: {len(l1_idx)}, Stage2 pages: {len(l2_pages)}, Stage3 blocks: {len(l3_blocks)}.")
    out.append("")
    # Resolved class ID constants
    for idx, name in enumerate(RES_CLASSES):
        out.append(f"let cls_{name} : Int = {idx}")
    out.append("")
    out.append("let flag_ea : Int = 1")
    out.append("let flag_qu_pi : Int = 2")
    out.append("let flag_qu_pf : Int = 4")
    out.append("let flag_ep_cn : Int = 8")
    out.append("let flag_u2010 : Int = 16")
    out.append("let flag_u25cc : Int = 32")
    out.append("")
    out.append("fn dec91(b : Int) -> Int {")
    out.append("  if b > 92 {")
    out.append("    b - 36")
    out.append("  } else {")
    out.append("    b - 35")
    out.append("  }")
    out.append("}")
    out.append("")
    out.append(chunk_string("ascii_combos", ascii_str))
    out.append("")
    out.append(chunk_string("ascii_res_table", ascii_res_str))
    out.append("")
    out.append(chunk_string("combo_raw_table", combo_raw_str))
    out.append("")
    out.append(chunk_string("combo_res_table", combo_res_str))
    out.append("")
    out.append(chunk_string("combo_flags_table", combo_flags_str))
    out.append("")
    out.append(chunk_string("stage1_table", stage1_str))
    out.append("")
    out.append(chunk_string("stage2_table", stage2_str))
    out.append("")
    out.append(chunk_string("stage3_table", stage3_str))
    out.append("")
    out.append("fn lookup_combo(cp : Int) -> Int {")
    out.append("  if cp < 0 || cp > 0x10FFFF {")
    out.append(f"    return {cp_combo[0x10FFFF]}")
    out.append("  }")
    out.append("  if cp < 128 {")
    out.append("    return dec91(ascii_combos.code_unit_at(cp))")
    out.append("  }")
    out.append("  let s1 = dec91(stage1_table.code_unit_at(cp >> 13))")
    out.append("  let s2_off = (s1 * 64 + ((cp >> 7) & 63)) * 2")
    out.append("  let b0 = dec91(stage2_table.code_unit_at(s2_off))")
    out.append("  let b1 = dec91(stage2_table.code_unit_at(s2_off + 1))")
    out.append("  let s3 = b0 * 91 + b1")
    out.append("  dec91(stage3_table.code_unit_at(s3 * 128 + (cp & 127)))")
    out.append("}")
    out.append("")
    out.append("fn combo_raw_id(cid : Int) -> Int {")
    out.append("  dec91(combo_raw_table.code_unit_at(cid))")
    out.append("}")
    out.append("")
    out.append("fn combo_res_cls(cid : Int) -> Int {")
    out.append("  dec91(combo_res_table.code_unit_at(cid))")
    out.append("}")
    out.append("")
    out.append("fn combo_flags(cid : Int) -> Int {")
    out.append("  dec91(combo_flags_table.code_unit_at(cid))")
    out.append("}")
    out.append("")
    out.append("fn raw_id_to_class(id : Int) -> LineBreakClass {")
    out.append("  match id {")
    for idx, name in enumerate(RAW_CLASSES):
        out.append(f"    {idx} => LineBreakClass::{name}")
    out.append("    _ => LineBreakClass::XX")
    out.append("  }")
    out.append("}")
    out.append("")
    return "\n".join(out)


def main() -> int:
    args = sys.argv[1:]
    check = False
    if args and args[0] == "--check":
        check = True
        args = args[1:]
    if len(args) != 2:
        print(
            "usage: gen_tables.py [--check] <unicode_16_0_0_ucd_dir> <out_tables_pion>",
            file=sys.stderr,
        )
        return 2
    ucd_dir, out_file = args
    content = generate(ucd_dir)
    if check:
        if not os.path.exists(out_file):
            print(f"FAIL: {out_file} does not exist", file=sys.stderr)
            return 1
        with open(out_file, "r", encoding="utf-8") as f:
            existing = f.read()
        if existing != content:
            print(f"FAIL: {out_file} is out of date with Unicode 16.0.0 UCD", file=sys.stderr)
            return 1
        print(f"OK: {out_file} matches deterministic Unicode 16.0.0 UCD output ({len(content)} bytes)")
        return 0
    os.makedirs(os.path.dirname(os.path.abspath(out_file)), exist_ok=True)
    with open(out_file, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"Generated {out_file} ({len(content)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
