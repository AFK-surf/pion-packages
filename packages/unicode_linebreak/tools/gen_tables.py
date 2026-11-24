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
    if not (0 <= v < 57 * 32):
        raise ValueError(f"value {v} out of 2-char base-32 range")
    return chr(35 + (v >> 5)) + chr(35 + (v & 31))


def build_pair_table() -> str:
    """Build compact 47x64 DFA fast-path action table for UAX #14 when !ctx_dirty.
    Rows 0..42: resolved classes (OP implies after_op_sp=true; CL implies after_cl_cp_sp=true, nu_state=0).
    Row 43: SP_AFTER_OP    (prev=SP, after_op_sp=true, nu_state=0)
    Row 44: SP_AFTER_CL_CP (prev=SP, after_cl_cp_sp=true, nu_state=0)
    Row 45: CP_NA          (prev=CP, !prev_is_ea, after_cl_cp_sp=true, nu_state=0)
    Row 46: QU_PLAIN       (prev=QU, !prev_qu_pi, !prev_qu_pf, nu_state=0)
    Action codes (encoded as chr(35 + act), all < 92):
      0: NO_BREAK,        nu_state = 0, prev = cur_raw
      1: ALLOW_BREAK,     nu_state = 0, prev = cur_raw
      2: NO_BREAK,        nu_state = 1, prev = cur_raw
      3: ALLOW_BREAK,     nu_state = 1, prev = cur_raw
      4: NO_BREAK,        keep nu_state, prev = cur_raw
      5: NO_BREAK,        nu_state = 0, prev = 43 (SP_AFTER_OP)
      6: NO_BREAK,        nu_state = 0, prev = 44 (SP_AFTER_CL_CP)
      7: NO_BREAK,        nu_state = 0, prev = 45 (CP_NA; caller ensures cur_flags == 0)
      8: NO_BREAK,        nu_state = 0, prev = 46 (QU_PLAIN; caller ensures cur_flags == 0)
      9: ALLOW_BREAK,     nu_state = 0, prev = 46 (QU_PLAIN; caller ensures cur_flags == 0)
      10: MANDATORY_BREAK, nu_state = 0, prev = cur_raw (LB5 LF!)
      11: MANDATORY_BREAK, nu_state = 1, prev = cur_raw (LB5 LF! -> NU)
      12: SLOW            (needs full slow_step)
    """
    SLOW = chr(35 + 12)
    fast_classes = {
        "AL", "SP", "ID", "NU", "IS", "SY", "EX", "NS", "PR", "PO",
        "IN", "GL", "WJ", "BB", "CB", "BA", "HY", "H2", "H3", "JL", "JV", "JT",
    }
    lb20a_before = {"BK", "CR", "LF", "NL", "SP", "ZW", "CB", "GL"}
    hangul = {"JL", "JV", "JT", "H2", "H3"}
    rows = list(RES_CLASSES) + ["SP_AFTER_OP", "SP_AFTER_CL_CP", "CP_NA", "QU_PLAIN"]
    out = []
    for p in rows:
        for c in RES_CLASSES:
            # --- LB5: LF! Mandatory break (CR/NL/BK remain SLOW to keep LB4/LB5 mutants live) ---
            if p == "LF":
                if c == "NU":
                    out.append(chr(35 + 11))
                elif c == "HY":
                    out.append(SLOW)  # LB20a: LF HY sets after_word_init_hy
                elif c in fast_classes or c in ("BK", "CR", "LF", "NL", "OP", "CL"):
                    out.append(chr(35 + 10))
                else:
                    out.append(SLOW)
                continue

            # --- Virtual / contextual fast state: QU_PLAIN (LB19: QU x ALL) ---
            if p == "QU_PLAIN":
                if c in ("BK", "CR", "LF", "NL", "OP", "CL"):
                    out.append(chr(35 + 0))  # LB6 / LB13 / LB19
                elif c == "CP":
                    out.append(chr(35 + 7))  # LB13 -> CP_NA
                elif c == "QU":
                    out.append(chr(35 + 8))  # LB19 -> QU_PLAIN
                elif c == "NU":
                    out.append(chr(35 + 2))  # LB19 -> NU
                elif c in fast_classes:
                    out.append(chr(35 + 0))  # LB7 / LB19 -> cur
                else:
                    out.append(SLOW)
                continue

            # --- Virtual / contextual fast states: OP, SP_AFTER_OP ---
            if p in ("OP", "SP_AFTER_OP"):
                if c == "SP":
                    out.append(chr(35 + 5))  # SP_AFTER_OP
                elif c == "HY" and p == "SP_AFTER_OP":
                    out.append(SLOW)  # LB20a: SP HY sets after_word_init_hy
                elif c in ("BK", "CR", "LF", "NL"):
                    out.append(chr(35 + 0))  # LB6
                elif c == "OP":
                    out.append(chr(35 + 0))  # LB14 -> OP (caller ensures cur_flags==0)
                elif c == "CL":
                    out.append(chr(35 + 0))  # LB13 -> CL
                elif c == "CP":
                    out.append(chr(35 + 7))  # LB13 -> CP_NA (caller ensures cur_flags==0)
                elif c == "QU":
                    out.append(chr(35 + 8))  # LB14 -> QU_PLAIN (caller ensures cur_flags==0)
                elif c == "NU":
                    out.append(chr(35 + 2))  # LB14 -> NU, nu_state=1
                elif c in fast_classes:
                    out.append(chr(35 + 0))  # LB14 -> cur, nu_state=0
                else:
                    out.append(SLOW)
                continue

            # --- Virtual / contextual fast states: CL, CP_NA, SP_AFTER_CL_CP ---
            if p in ("CL", "CP_NA", "SP_AFTER_CL_CP"):
                if c == "SP":
                    out.append(chr(35 + 6))  # SP_AFTER_CL_CP
                elif c == "HY" and p == "SP_AFTER_CL_CP":
                    out.append(SLOW)  # LB20a: SP HY sets after_word_init_hy
                elif c in ("BK", "CR", "LF", "NL"):
                    out.append(chr(35 + 0))  # LB6
                elif c == "CL":
                    out.append(chr(35 + 0))  # LB13 -> CL
                elif c == "CP":
                    out.append(chr(35 + 7))  # LB13 -> CP_NA
                elif c == "QU":
                    if p == "SP_AFTER_CL_CP":
                        out.append(chr(35 + 9))  # LB18 -> QU_PLAIN
                    else:
                        out.append(chr(35 + 8))  # LB19 -> QU_PLAIN
                elif c == "NS":
                    out.append(chr(35 + 0))  # LB16: (CL|CP) SP* x NS
                elif c in ("EX", "SY", "WJ"):
                    out.append(chr(35 + 0))  # LB11 / LB13
                elif c == "IS":
                    if p == "SP_AFTER_CL_CP":
                        out.append(SLOW)  # LB15c lookahead
                    else:
                        out.append(chr(35 + 0))  # LB15d
                elif c == "GL":
                    if p == "SP_AFTER_CL_CP":
                        out.append(chr(35 + 1))  # LB18 (LB12a excludes SP)
                    else:
                        out.append(chr(35 + 0))  # LB12a
                elif c == "OP":
                    out.append(chr(35 + 1))  # LB18 / LB31 -> OP (caller ensures cur_flags==0)
                elif c in fast_classes:
                    if p == "CP_NA" and c == "AL":
                        out.append(chr(35 + 0))  # LB30: CP_NA x AL
                    elif p == "CP_NA" and c == "NU":
                        out.append(chr(35 + 2))  # LB30: CP_NA x NU
                    elif p != "SP_AFTER_CL_CP" and c in ("BA", "HY", "IN"):
                        out.append(chr(35 + 0))  # LB21 / LB22
                    elif c == "NU":
                        out.append(chr(35 + 3))  # LB18 / LB31 -> NU, nu_state=1
                    else:
                        out.append(chr(35 + 1))  # LB18 / LB20 / LB31
                else:
                    out.append(SLOW)
                continue

            # --- Normal fast_classes rows ---
            if p not in fast_classes:
                out.append(SLOW)
                continue
            if c in ("BK", "CR", "LF", "NL"):
                out.append(chr(35 + 0))
                continue
            if c == "QU":
                if p == "SP":
                    out.append(chr(35 + 9))  # LB18 -> QU_PLAIN (caller ensures cur_flags==0)
                else:
                    out.append(chr(35 + 8))  # LB19 -> QU_PLAIN (caller ensures cur_flags==0)
                continue
            if c == "CL":
                if p in ("NU", "IS", "SY"):
                    out.append(SLOW)  # nu_state may transition 1 -> 2
                else:
                    out.append(chr(35 + 0))  # LB13 -> CL (nu_state=0)
                continue
            if c == "CP":
                if p in ("NU", "IS", "SY"):
                    out.append(SLOW)  # nu_state may transition 1 -> 2
                else:
                    out.append(chr(35 + 7))  # LB13 -> CP_NA (caller ensures cur_flags==0)
                continue
            if c == "OP":
                if p in ("PR", "PO"):
                    out.append(SLOW)  # LB25 lookahead: (PR|PO) x OP IS? NU
                elif p in ("WJ", "GL", "BB", "AL", "NU"):
                    out.append(chr(35 + 0))  # LB11/12/21/30 (caller ensures cur_flags==0)
                else:
                    out.append(chr(35 + 1))  # LB18/20/31 -> OP
                continue
            if c == "HY" and p in lb20a_before:
                out.append(SLOW)  # LB20a: word-initial HY sets after_word_init_hy
                continue
            if c not in fast_classes:
                out.append(SLOW)
                continue
            # Context-dependent or lookahead pairs -> SLOW
            if p == "SP" and c == "IS":
                out.append(SLOW)
                continue
            if p == "SY" and c == "NU":
                out.append(SLOW)
                continue
            if p in ("IS", "SY") and c in ("PR", "PO"):
                out.append(SLOW)
                continue
            if p in ("PR", "PO") and c == "NU":
                out.append(SLOW)
                continue

            # Exact UAX #14 LB7..LB31 decision for (p, c) under !ctx_dirty && cur_flags <= 1
            if c == "SP":
                brk = False  # LB7
            elif p == "WJ" or c == "WJ":
                brk = False  # LB11
            elif p == "GL":
                brk = False  # LB12
            elif c == "GL" and p not in ("SP", "BA", "HY"):
                brk = False  # LB12a
            elif c in ("EX", "SY"):
                brk = False  # LB13
            elif c == "IS":
                brk = False  # LB15d
            elif p == "SP":
                brk = True  # LB18
            elif p == "CB" or c == "CB":
                brk = True  # LB20
            elif c in ("BA", "HY", "NS") or p == "BB":
                brk = False  # LB21
            elif c == "IN":
                brk = False  # LB22
            elif (p == "AL" and c == "NU") or (p == "NU" and c == "AL"):
                brk = False  # LB23
            elif (p == "PR" and c == "ID") or (p == "ID" and c == "PO"):
                brk = False  # LB23a
            elif (p in ("PR", "PO") and c == "AL") or (p == "AL" and c in ("PR", "PO")):
                brk = False  # LB24
            elif p == "NU" and c in ("PO", "PR", "NU"):
                brk = False  # LB25 (p == NU => nu_state == 1)
            elif p in ("HY", "IS") and c == "NU":
                brk = False  # LB25
            elif (
                (p == "JL" and c in ("JL", "JV", "H2", "H3"))
                or (p in ("JV", "H2") and c in ("JV", "JT"))
                or (p in ("JT", "H3") and c == "JT")
            ):
                brk = False  # LB26
            elif (p in hangul and c == "PO") or (p == "PR" and c in hangul):
                brk = False  # LB27
            elif p == "AL" and c == "AL":
                brk = False  # LB28
            elif p == "IS" and c == "AL":
                brk = False  # LB29
            else:
                brk = True  # LB31

            if c == "NU":
                act = 3 if brk else 2
            elif c in ("SY", "IS"):
                assert not brk
                if p == "NU":
                    act = 2
                elif p in ("SY", "IS"):
                    act = 4
                else:
                    act = 0
            else:
                act = 1 if brk else 0
            out.append(chr(35 + act))
        # Pad row to 64 entries so index is `(prev << 6) | cur` (no multiply)
        out.append(SLOW * (64 - len(RES_CLASSES)))
    return "".join(out)


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

    assert len(l2_pages) <= 57, f"Too many stage2 pages ({len(l2_pages)})"
    assert len(l3_blocks) < 57 * 32

    ascii_str = "".join(encode_1(cp_combo[cp]) for cp in range(128))
    ascii_res_str = "".join(encode_1(combos_list[cp_combo[cp]][1]) for cp in range(128))
    combo_raw_str = "".join(encode_1(raw_id) for raw_id, _, _ in combos_list)
    combo_res_str = "".join(encode_1(res_id) for _, res_id, _ in combos_list)
    combo_flags_str = "".join(encode_1(flags) for _, _, flags in combos_list)
    stage1_str = "".join(encode_1(pid) for pid in l1_idx)
    stage2_str = "".join(encode_2(bid) for page in l2_pages for bid in page)
    stage3_str = "".join(encode_1(cid) for blk in l3_blocks for cid in blk)
    pair_str = build_pair_table()

    # Pack all hot lookup tables into a single immutable String (`table_blob`) so
    # hot loops hoist just ONE String (1 ptr + 1 len) instead of 7 separate Strings:
    #   [0 .. 128):       ascii_res_table (128 B)
    #   [128 .. 2880):    pair_table (43 * 64 = 2752 B)
    #   [2880 .. 3016):   stage1_table (136 B)
    #   [3016 .. 5320):   stage2_table (len(l2_pages) * 64 * 2 B)
    #   [5320 .. s3_end): stage3_table (len(l3_blocks) * 128 B)
    #   [s3_end .. +nc):  combo_res_table (nc B)
    #   [+nc .. +2*nc):   combo_flags_table (nc B)
    off_pair = len(ascii_res_str)
    off_s1 = off_pair + len(pair_str)
    off_s2 = off_s1 + len(stage1_str)
    off_s3 = off_s2 + len(stage2_str)
    off_cres = off_s3 + len(stage3_str)
    off_cflg = off_cres + len(combo_res_str)
    blob_str = (
        ascii_res_str
        + pair_str
        + stage1_str
        + stage2_str
        + stage3_str
        + combo_res_str
        + combo_flags_str
    )

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
    out.append(f"let blob_off_pair : Int = {off_pair}")
    out.append(f"let blob_off_s1 : Int = {off_s1}")
    out.append(f"let blob_off_s2 : Int = {off_s2}")
    out.append(f"let blob_off_s3 : Int = {off_s3}")
    out.append(f"let blob_off_cres : Int = {off_cres}")
    out.append(f"let blob_off_cflg : Int = {off_cflg}")
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
    out.append(chunk_string("combo_raw_table", combo_raw_str))
    out.append("")
    out.append(chunk_string("table_blob", blob_str))
    out.append("")
    out.append("fn lookup_combo(cp : Int) -> Int {")
    out.append("  if cp < 0 || cp > 0x10FFFF {")
    out.append(f"    return {cp_combo[0x10FFFF]}")
    out.append("  }")
    out.append("  if cp < 128 {")
    out.append("    return dec91(ascii_combos.code_unit_at(cp))")
    out.append("  }")
    out.append("  let tbl = table_blob")
    out.append("  let s1 = tbl.code_unit_at(blob_off_s1 + (cp >> 13)) - 35")
    out.append("  let s2_off = blob_off_s2 + (((s1 << 6) | ((cp >> 7) & 63)) << 1)")
    out.append("  let b0 = tbl.code_unit_at(s2_off) - 35")
    out.append("  let b1 = tbl.code_unit_at(s2_off + 1) - 35")
    out.append("  let s3 = (b0 << 5) | b1")
    out.append("  dec91(tbl.code_unit_at(blob_off_s3 + ((s3 << 7) | (cp & 127))))")
    out.append("}")
    out.append("")
    out.append("fn combo_raw_id(cid : Int) -> Int {")
    out.append("  combo_raw_table.code_unit_at(cid) - 35")
    out.append("}")
    out.append("")
    out.append("fn combo_res_cls(cid : Int) -> Int {")
    out.append("  table_blob.code_unit_at(blob_off_cres + cid) - 35")
    out.append("}")
    out.append("")
    out.append("fn combo_flags(cid : Int) -> Int {")
    out.append("  table_blob.code_unit_at(blob_off_cflg + cid) - 35")
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
