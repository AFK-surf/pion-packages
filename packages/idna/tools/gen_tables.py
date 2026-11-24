#!/usr/bin/env python3
"""Deterministic generator for Unicode 16.0.0 UTS #46 / NFC / Bidi / ContextJ / ContextO / UTS #39 tables.

Reads official Unicode 16.0.0 data files (Unicode-3.0 license) from a directory and writes:
  - src/tables_uts46.pion
  - src/tables_uts39.pion

Usage:
  python3 packages/idna/tools/gen_tables.py /path/to/unicode-16.0.0 packages/idna/src
"""

import os
import sys

# Base-32 VLQ alphabet (5 bits per char, continuation flag in char choice):
#   0..25  -> 'A'..'Z' (final)
#   26..31 -> 'a'..'f' (final)
#   0..19  -> 'g'..'z' (more)
#   20..29 -> '0'..'9' (more)
#   30     -> '-'      (more)
#   31     -> '_'      (more)
FINAL_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"
MORE_CHARS = "ghijklmnopqrstuvwxyz0123456789-_"


def encode_vlq_u(v: int) -> str:
    assert v >= 0, f"negative vlq_u: {v}"
    out = []
    while True:
        d = v & 31
        v >>= 5
        if v:
            out.append(MORE_CHARS[d])
        else:
            out.append(FINAL_CHARS[d])
            break
    return "".join(out)


def encode_vlq_i(v: int) -> str:
    u = (v << 1) if v >= 0 else ((-v << 1) - 1)
    return encode_vlq_u(u)


def encode_vlq_u_array(arr) -> str:
    return "".join(encode_vlq_u(x) for x in arr)


def encode_vlq_i_array(arr) -> str:
    return "".join(encode_vlq_i(x) for x in arr)


def encode_vlq_delta_array(arr) -> str:
    out = []
    prev = 0
    for x in arr:
        assert x >= prev, f"non-monotonic delta array: {x} < {prev}"
        out.append(encode_vlq_u(x - prev))
        prev = x
    return "".join(out)


def encode_vlq_end_array(starts, ends) -> str:
    return "".join(encode_vlq_u(e - s) for s, e in zip(starts, ends))


def format_pion_string(name: str, s: str) -> str:
    return f'let {name} : String = "{s}"\n'


def parse_range(field: str):
    if ".." in field:
        a, b = field.split("..")
        return int(a, 16), int(b, 16)
    v = int(field, 16)
    return v, v


def parse_idna_mapping(path: str):
    # Returns list of (start, end, val) ranges (merged) and pool list.
    # val encoding:
    #   0 = disallowed
    #   1 = valid
    #   2 = ignored
    #   5 = deviation (00DF, 03C2, 200C, 200D)
    #   (v & 7) == 3 => single-cp mapping with signed delta = (v >> 3)
    #   (v & 7) == 4 => multi-cp mapping: off = (v >> 3) & 0xFFFF, len = v >> 19
    pool = []
    pool_index = {}

    def intern_pool(seq):
        key = tuple(seq)
        if key in pool_index:
            return pool_index[key]
        off = len(pool)
        pool.extend(seq)
        pool_index[key] = off
        return off

    raw = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            parts = [p.strip() for p in s.split(";")]
            lo, hi = parse_range(parts[0])
            status = parts[1]
            if status == "disallowed":
                val = 0
            elif status == "valid":
                val = 1
            elif status == "ignored":
                val = 2
            elif status == "deviation":
                val = 5
            elif status == "mapped":
                cps = [int(x, 16) for x in parts[2].split()] if len(parts) > 2 and parts[2] else []
                if len(cps) == 0:
                    val = 2
                elif len(cps) == 1 and lo == hi:
                    delta = cps[0] - lo
                    val = (delta << 3) | 3
                elif len(cps) == 1:
                    # Range mapped to a single fixed cp: emit individual or multi-pool
                    off = intern_pool(cps)
                    val = (1 << 19) | (off << 3) | 4
                else:
                    off = intern_pool(cps)
                    val = (len(cps) << 19) | (off << 3) | 4
            else:
                raise ValueError(f"Unknown IdnaMappingTable status: {status}")
            if val != 0:
                raw.append((lo, hi, val))

    # Merge adjacent identical-val ranges (only safe when val is not delta-mapped, or wait:
    # delta-mapped is safe to merge too! If cp1->cp1+d and cp2->cp2+d with same d, same val works!)
    raw.sort()
    merged = []
    for lo, hi, val in raw:
        if merged and merged[-1][2] == val and merged[-1][1] + 1 == lo:
            merged[-1] = (merged[-1][0], hi, val)
        else:
            merged.append((lo, hi, val))
    return merged, pool


def parse_unicode_data(ud_path: str, excl_path: str):
    exclusions = set()
    with open(excl_path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            lo, hi = parse_range(s)
            for cp in range(lo, hi + 1):
                exclusions.add(cp)

    ccc_map = {}
    raw_decomp = {}
    marks = []
    nd_cps = []

    with open(ud_path, "r", encoding="utf-8") as f:
        range_start = None
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split(";")
            cp = int(parts[0], 16)
            name = parts[1]
            gc = parts[2]
            ccc = int(parts[3])
            decomp = parts[5].strip()

            if name.endswith(", First>"):
                range_start = (cp, gc, ccc)
                continue
            elif name.endswith(", Last>"):
                assert range_start is not None
                lo, rgc, rccc = range_start
                range_start = None
                if rccc != 0:
                    for c in range(lo, cp + 1):
                        ccc_map[c] = rccc
                if rgc in ("Mn", "Mc", "Me"):
                    marks.append((lo, cp))
                continue

            if ccc != 0:
                ccc_map[cp] = ccc
            if gc in ("Mn", "Mc", "Me"):
                marks.append((cp, cp))
            if gc == "Nd":
                digit_val = int(parts[6])
                nd_cps.append((cp, cp - digit_val))
            if decomp and not decomp.startswith("<"):
                raw_decomp[cp] = [int(x, 16) for x in decomp.split()]

    # Recursive canonical decomposition
    def expand(cp):
        if cp not in raw_decomp:
            return [cp]
        res = []
        for c in raw_decomp[cp]:
            res.extend(expand(c))
        return res

    full_decomp = {}
    for cp in sorted(raw_decomp.keys()):
        full_decomp[cp] = expand(cp)

    # Canonical composition pairs (exclude exclusions, singletons, non-starter first)
    comp_pairs = []
    for cp, seq in raw_decomp.items():
        if cp in exclusions:
            continue
        if len(seq) != 2:
            continue
        c1, c2 = seq
        if ccc_map.get(c1, 0) != 0:
            continue
        key = (c1 << 21) | c2
        comp_pairs.append((key, cp))
    comp_pairs.sort()

    # Merge ccc ranges
    ccc_ranges = []
    for cp in sorted(ccc_map.keys()):
        v = ccc_map[cp]
        if ccc_ranges and ccc_ranges[-1][2] == v and ccc_ranges[-1][1] + 1 == cp:
            ccc_ranges[-1] = (ccc_ranges[-1][0], cp, v)
        else:
            ccc_ranges.append((cp, cp, v))

    # Merge mark ranges
    marks.sort()
    mark_ranges = []
    for lo, hi in marks:
        if mark_ranges and mark_ranges[-1][1] + 1 >= lo:
            mark_ranges[-1] = (mark_ranges[-1][0], max(mark_ranges[-1][1], hi))
        else:
            mark_ranges.append((lo, hi))

    # Merge Nd ranges by numbering-system zero (cp - digit_value) so adjacent systems
    # such as U+116D0..U+116D9 and U+116DA..U+116E3 stay distinct.
    nd_cps.sort()
    nd_ranges = []
    for cp, zero_cp in nd_cps:
        if nd_ranges and nd_ranges[-1][1] + 1 == cp and nd_ranges[-1][2] == zero_cp:
            nd_ranges[-1] = (nd_ranges[-1][0], cp, zero_cp)
        else:
            nd_ranges.append((cp, cp, zero_cp))
    nd_ranges = [(lo, hi) for lo, hi, _ in nd_ranges]

    return ccc_ranges, full_decomp, comp_pairs, mark_ranges, nd_ranges


def parse_nfc_qc(path: str):
    """Parse all NFC_Quick_Check != Yes (No or Maybe) ranges from DerivedNormalizationProps.txt."""
    raw = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            parts = [p.strip() for p in s.split(";")]
            if len(parts) >= 3 and parts[1] == "NFC_QC":
                lo, hi = parse_range(parts[0])
                raw.append((lo, hi))
    raw.sort()
    merged = []
    for lo, hi in raw:
        if merged and merged[-1][1] + 1 >= lo:
            merged[-1] = (merged[-1][0], max(merged[-1][1], hi))
        else:
            merged.append((lo, hi))
    return merged


def parse_bidi(path: str):
    # Bidi class codes:
    #   0=L, 1=R, 2=AL, 3=EN, 4=ES, 5=ET, 6=AN, 7=CS, 8=NSM, 9=BN, 10=ON,
    #   11=WS, 12=S, 13=B, 14=LRE, 15=RLE, 16=LRO, 17=RLO, 18=PDF,
    #   19=LRI, 20=RLI, 21=FSI, 22=PDI
    cls_map = {
        "L": 0, "Left_To_Right": 0,
        "R": 1, "Right_To_Left": 1,
        "AL": 2, "Arabic_Letter": 2,
        "EN": 3, "European_Number": 3,
        "ES": 4, "European_Separator": 4,
        "ET": 5, "European_Terminator": 5,
        "AN": 6, "Arabic_Number": 6,
        "CS": 7, "Common_Separator": 7,
        "NSM": 8, "Nonspacing_Mark": 8,
        "BN": 9, "Boundary_Neutral": 9,
        "ON": 10, "Other_Neutral": 10,
        "WS": 11, "White_Space": 11,
        "S": 12, "Segment_Separator": 12,
        "B": 13, "Paragraph_Separator": 13,
        "LRE": 14, "Left_To_Right_Embedding": 14,
        "RLE": 15, "Right_To_Left_Embedding": 15,
        "LRO": 16, "Left_To_Right_Override": 16,
        "RLO": 17, "Right_To_Left_Override": 17,
        "PDF": 18, "Pop_Directional_Format": 18,
        "LRI": 19, "Left_To_Right_Isolate": 19,
        "RLI": 20, "Right_To_Left_Isolate": 20,
        "FSI": 21, "First_Strong_Isolate": 21,
        "PDI": 22, "Pop_Directional_Isolate": 22,
    }
    arr = [0] * 0x110000
    # First apply @missing defaults in order
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            if line.startswith("# @missing:"):
                body = line[len("# @missing:"):].strip()
                parts = [p.strip() for p in body.split(";")]
                lo, hi = parse_range(parts[0])
                code = cls_map.get(parts[1], 11)
                for cp in range(lo, hi + 1):
                    arr[cp] = code
    # Then apply explicit entries
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            parts = [p.strip() for p in s.split(";")]
            lo, hi = parse_range(parts[0])
            code = cls_map.get(parts[1], 11)
            for cp in range(lo, hi + 1):
                arr[cp] = code
    # Compress non-zero ranges (0=L is default)
    ranges = []
    cp = 0
    while cp < 0x110000:
        v = arr[cp]
        if v != 0:
            start = cp
            while cp < 0x110000 and arr[cp] == v:
                cp += 1
            ranges.append((start, cp - 1, v))
        else:
            cp += 1
    return ranges


def parse_joining_type(path: str):
    # 0=other, 1=L, 2=R, 3=D, 4=T
    jt_map = {"L": 1, "R": 2, "D": 3, "T": 4}
    raw = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            parts = [p.strip() for p in s.split(";")]
            v = jt_map.get(parts[1], 0)
            if v != 0:
                lo, hi = parse_range(parts[0])
                raw.append((lo, hi, v))
    raw.sort()
    merged = []
    for lo, hi, v in raw:
        if merged and merged[-1][2] == v and merged[-1][1] + 1 == lo:
            merged[-1] = (merged[-1][0], hi, v)
        else:
            merged.append((lo, hi, v))
    return merged


NAMED_SCRIPTS = [
    "Common",      # 0
    "Inherited",   # 1
    "Latin",       # 2
    "Greek",       # 3
    "Cyrillic",    # 4
    "Han",         # 5
    "Hiragana",    # 6
    "Katakana",    # 7
    "Hangul",      # 8
    "Arabic",      # 9
    "Hebrew",      # 10
    "Thai",        # 11
    "Devanagari",  # 12
    "Bengali",     # 13
    "Gurmukhi",    # 14
    "Gujarati",    # 15
    "Oriya",       # 16
    "Tamil",       # 17
    "Telugu",      # 18
    "Kannada",     # 19
    "Malayalam",   # 20
    "Sinhala",     # 21
    "Myanmar",     # 22
    "Georgian",    # 23
    "Armenian",    # 24
    "Ethiopic",    # 25
    "Cherokee",    # 26
    "Khmer",       # 27
    "Lao",         # 28
    "Tibetan",     # 29
    "Bopomofo",    # 30
]


def parse_scripts(path: str):
    script_ids = {name: idx for idx, name in enumerate(NAMED_SCRIPTS)}
    next_id = len(NAMED_SCRIPTS)
    raw = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            parts = [p.strip() for p in s.split(";")]
            lo, hi = parse_range(parts[0])
            sc = parts[1]
            if sc not in script_ids:
                script_ids[sc] = next_id
                next_id += 1
            sid = script_ids[sc]
            if sid != 0:  # 0=Common is default for unassigned/Common
                raw.append((lo, hi, sid))
    raw.sort()
    merged = []
    for lo, hi, v in raw:
        if merged and merged[-1][2] == v and merged[-1][1] + 1 == lo:
            merged[-1] = (merged[-1][0], hi, v)
        else:
            merged.append((lo, hi, v))
    return merged


def parse_default_ignorable(path: str):
    raw = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            parts = [p.strip() for p in s.split(";")]
            if len(parts) >= 2 and parts[1] == "Default_Ignorable_Code_Point":
                lo, hi = parse_range(parts[0])
                raw.append((lo, hi))
    raw.sort()
    merged = []
    for lo, hi in raw:
        if merged and merged[-1][1] + 1 >= lo:
            merged[-1] = (merged[-1][0], max(merged[-1][1], hi))
        else:
            merged.append((lo, hi))
    return merged


def parse_confusables(path: str):
    entries = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            parts = [p.strip() for p in s.split(";")]
            src = int(parts[0], 16)
            tgt = [int(x, 16) for x in parts[1].split()]
            entries[src] = tgt
    cps = sorted(entries.keys())
    pool = []
    pool_idx = {}
    infos = []
    for cp in cps:
        tgt = entries[cp]
        if len(tgt) == 1:
            infos.append((tgt[0] << 1) | 0)
        else:
            key = tuple(tgt)
            if key in pool_idx:
                off = pool_idx[key]
            else:
                off = len(pool)
                pool.extend(tgt)
                pool_idx[key] = off
            assert off < 65536 and len(tgt) < 256
            infos.append((((len(tgt) << 16) | off) << 1) | 1)
    return cps, infos, pool


def parse_bidi_brackets(path: str):
    """Parse BidiBrackets.txt -> sorted (cps, packed_vals) where val = (paired_cp << 1) | (1 if 'o' else 0)."""
    entries = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            parts = [p.strip() for p in s.split(";")]
            if len(parts) >= 3 and parts[2] in ("o", "c"):
                cp = int(parts[0], 16)
                other = int(parts[1], 16)
                is_open = 1 if parts[2] == "o" else 0
                entries.append((cp, (other << 1) | is_open))
    entries.sort()
    return [e[0] for e in entries], [e[1] for e in entries]


def parse_bidi_mirroring(path: str):
    """Parse BidiMirroring.txt -> sorted (cps, mirror_cps)."""
    entries = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            parts = [p.strip() for p in s.split(";")]
            if len(parts) >= 2 and parts[1]:
                entries.append((int(parts[0], 16), int(parts[1], 16)))
    entries.sort()
    return [e[0] for e in entries], [e[1] for e in entries]


def parse_identifier_status(path: str):
    """Parse IdentifierStatus.txt -> merged ranges of Identifier_Status = Allowed."""
    raw = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            parts = [p.strip() for p in s.split(";")]
            if len(parts) >= 2 and parts[1] == "Allowed":
                lo, hi = parse_range(parts[0])
                raw.append((lo, hi))
    raw.sort()
    merged = []
    for lo, hi in raw:
        if merged and merged[-1][1] + 1 >= lo:
            merged[-1] = (merged[-1][0], max(merged[-1][1], hi))
        else:
            merged.append((lo, hi))
    return merged


def write_uts46_tables(out_path: str, idna_ranges, idna_pool, ccc_ranges, full_decomp, comp_pairs, mark_ranges, bidi_ranges, jt_ranges, nfcqc_ranges):
    decomp_cps = sorted(full_decomp.keys())
    decomp_pool = []
    decomp_infos = []
    for cp in decomp_cps:
        seq = full_decomp[cp]
        off = len(decomp_pool)
        decomp_pool.extend(seq)
        decomp_infos.append((len(seq) << 16) | off)

    idna_s = [r[0] for r in idna_ranges]
    idna_e = [r[1] for r in idna_ranges]
    idna_v = [r[2] for r in idna_ranges]

    ccc_s = [r[0] for r in ccc_ranges]
    ccc_e = [r[1] for r in ccc_ranges]
    ccc_v = [r[2] for r in ccc_ranges]

    comp_k = [p[0] for p in comp_pairs]
    comp_v = [p[1] for p in comp_pairs]

    mark_s = [r[0] for r in mark_ranges]
    mark_e = [r[1] for r in mark_ranges]

    bidi_s = [r[0] for r in bidi_ranges]
    bidi_e = [r[1] for r in bidi_ranges]
    bidi_v = [r[2] for r in bidi_ranges]

    jt_s = [r[0] for r in jt_ranges]
    jt_e = [r[1] for r in jt_ranges]
    jt_v = [r[2] for r in jt_ranges]

    nfcqc_s = [r[0] for r in nfcqc_ranges]
    nfcqc_e = [r[1] for r in nfcqc_ranges]

    lines = []
    lines.append("///| Auto-generated by `tools/gen_tables.py` from Unicode 16.0.0 data (Unicode-3.0 license).\n")
    lines.append("///| Sources: IdnaMappingTable.txt, UnicodeData.txt, CompositionExclusions.txt,\n")
    lines.append("///| DerivedNormalizationProps.txt, DerivedBidiClass.txt, DerivedJoiningType.txt.\n\n")

    lines.append("""fn vlq_digit(b : Int) -> (Int, Bool) {
  if b >= 65 && b <= 90 {
    (b - 65, false)
  } else if b >= 97 && b <= 102 {
    (b - 97 + 26, false)
  } else if b >= 103 && b <= 122 {
    (b - 103, true)
  } else if b >= 48 && b <= 57 {
    (b - 48 + 20, true)
  } else if b == 45 {
    (30, true)
  } else {
    (31, true)
  }
}

fn decode_vlq_u_array(s : String, count : Int) -> FixedArray[Int] {
  let arr : FixedArray[Int] = FixedArray::make(count, 0)
  let mut idx = 0
  let mut pos = 0
  while idx < count {
    let mut v = 0
    let mut shift = 0
    while true {
      let (d, more) = vlq_digit(s.code_unit_at(pos))
      pos = pos + 1
      v = v | (d << shift)
      if !more {
        break
      }
      shift = shift + 5
    }
    arr[idx] = v
    idx = idx + 1
  }
  arr
}

fn decode_vlq_delta_array(s : String, count : Int) -> FixedArray[Int] {
  let arr : FixedArray[Int] = FixedArray::make(count, 0)
  let mut idx = 0
  let mut pos = 0
  let mut acc = 0
  while idx < count {
    let mut v = 0
    let mut shift = 0
    while true {
      let (d, more) = vlq_digit(s.code_unit_at(pos))
      pos = pos + 1
      v = v | (d << shift)
      if !more {
        break
      }
      shift = shift + 5
    }
    acc = acc + v
    arr[idx] = acc
    idx = idx + 1
  }
  arr
}

fn decode_vlq_end_array(
  starts : FixedArray[Int],
  s : String,
  count : Int,
) -> FixedArray[Int] {
  let arr : FixedArray[Int] = FixedArray::make(count, 0)
  let mut idx = 0
  let mut pos = 0
  while idx < count {
    let mut v = 0
    let mut shift = 0
    while true {
      let (d, more) = vlq_digit(s.code_unit_at(pos))
      pos = pos + 1
      v = v | (d << shift)
      if !more {
        break
      }
      shift = shift + 5
    }
    arr[idx] = starts[idx] + v
    idx = idx + 1
  }
  arr
}

fn decode_vlq_i_array(s : String, count : Int) -> FixedArray[Int] {
  let arr : FixedArray[Int] = FixedArray::make(count, 0)
  let mut idx = 0
  let mut pos = 0
  while idx < count {
    let mut u : Int64 = 0L
    let mut shift : Int64 = 0L
    while true {
      let (d, more) = vlq_digit(s.code_unit_at(pos))
      pos = pos + 1
      u = u | (d.to_int64() << shift)
      if !more {
        break
      }
      shift = shift + 5L
    }
    let signed = (u >> 1L) ^ -(u & 1L)
    arr[idx] = signed.to_int()
    idx = idx + 1
  }
  arr
}

fn decode_vlq_delta_i64_array(s : String, count : Int) -> FixedArray[Int64] {
  let arr : FixedArray[Int64] = FixedArray::make(count, 0L)
  let mut idx = 0
  let mut pos = 0
  let mut acc : Int64 = 0L
  while idx < count {
    let mut v : Int64 = 0L
    let mut shift : Int64 = 0L
    while true {
      let (d, more) = vlq_digit(s.code_unit_at(pos))
      pos = pos + 1
      v = v | (d.to_int64() << shift)
      if !more {
        break
      }
      shift = shift + 5L
    }
    acc = acc + v
    arr[idx] = acc
    idx = idx + 1
  }
  arr
}

""")

    lines.append(format_pion_string("idna_s_data", encode_vlq_delta_array(idna_s)))
    lines.append(format_pion_string("idna_e_data", encode_vlq_end_array(idna_s, idna_e)))
    lines.append(format_pion_string("idna_v_data", encode_vlq_i_array(idna_v)))
    lines.append(format_pion_string("idna_pool_data", encode_vlq_u_array(idna_pool)))

    lines.append(format_pion_string("ccc_s_data", encode_vlq_delta_array(ccc_s)))
    lines.append(format_pion_string("ccc_e_data", encode_vlq_end_array(ccc_s, ccc_e)))
    lines.append(format_pion_string("ccc_v_data", encode_vlq_u_array(ccc_v)))

    lines.append(format_pion_string("decomp_cp_data", encode_vlq_delta_array(decomp_cps)))
    lines.append(format_pion_string("decomp_info_data", encode_vlq_u_array(decomp_infos)))
    lines.append(format_pion_string("decomp_pool_data", encode_vlq_u_array(decomp_pool)))

    lines.append(format_pion_string("comp_k_data", encode_vlq_delta_array(comp_k)))
    lines.append(format_pion_string("comp_v_data", encode_vlq_u_array(comp_v)))

    lines.append(format_pion_string("mark_s_data", encode_vlq_delta_array(mark_s)))
    lines.append(format_pion_string("mark_e_data", encode_vlq_end_array(mark_s, mark_e)))

    lines.append(format_pion_string("bidi_s_data", encode_vlq_delta_array(bidi_s)))
    lines.append(format_pion_string("bidi_e_data", encode_vlq_end_array(bidi_s, bidi_e)))
    lines.append(format_pion_string("bidi_v_data", encode_vlq_u_array(bidi_v)))

    lines.append(format_pion_string("jt_s_data", encode_vlq_delta_array(jt_s)))
    lines.append(format_pion_string("jt_e_data", encode_vlq_end_array(jt_s, jt_e)))
    lines.append(format_pion_string("jt_v_data", encode_vlq_u_array(jt_v)))

    lines.append(format_pion_string("nfcqc_s_data", encode_vlq_delta_array(nfcqc_s)))
    lines.append(format_pion_string("nfcqc_e_data", encode_vlq_end_array(nfcqc_s, nfcqc_e)))

    lines.append(f"""
let idna_count : Int = {len(idna_s)}
let idna_start : FixedArray[Int] = decode_vlq_delta_array(idna_s_data, {len(idna_s)})
let idna_end : FixedArray[Int] = decode_vlq_end_array(idna_start, idna_e_data, {len(idna_s)})
let idna_val : FixedArray[Int] = decode_vlq_i_array(idna_v_data, {len(idna_s)})
let idna_pool : FixedArray[Int] = decode_vlq_u_array(idna_pool_data, {len(idna_pool)})

let ccc_count : Int = {len(ccc_s)}
let ccc_start : FixedArray[Int] = decode_vlq_delta_array(ccc_s_data, {len(ccc_s)})
let ccc_end : FixedArray[Int] = decode_vlq_end_array(ccc_start, ccc_e_data, {len(ccc_s)})
let ccc_val : FixedArray[Int] = decode_vlq_u_array(ccc_v_data, {len(ccc_s)})

let decomp_count : Int = {len(decomp_cps)}
let decomp_cp : FixedArray[Int] = decode_vlq_delta_array(decomp_cp_data, {len(decomp_cps)})
let decomp_info : FixedArray[Int] = decode_vlq_u_array(decomp_info_data, {len(decomp_cps)})
let decomp_pool : FixedArray[Int] = decode_vlq_u_array(decomp_pool_data, {len(decomp_pool)})

let comp_count : Int = {len(comp_k)}
let comp_key : FixedArray[Int64] = decode_vlq_delta_i64_array(comp_k_data, {len(comp_k)})
let comp_val : FixedArray[Int] = decode_vlq_u_array(comp_v_data, {len(comp_k)})

let mark_count : Int = {len(mark_s)}
let mark_start : FixedArray[Int] = decode_vlq_delta_array(mark_s_data, {len(mark_s)})
let mark_end : FixedArray[Int] = decode_vlq_end_array(mark_start, mark_e_data, {len(mark_s)})

let bidi_count : Int = {len(bidi_s)}
let bidi_start : FixedArray[Int] = decode_vlq_delta_array(bidi_s_data, {len(bidi_s)})
let bidi_end : FixedArray[Int] = decode_vlq_end_array(bidi_start, bidi_e_data, {len(bidi_s)})
let bidi_val : FixedArray[Int] = decode_vlq_u_array(bidi_v_data, {len(bidi_s)})

let jt_count : Int = {len(jt_s)}
let jt_start : FixedArray[Int] = decode_vlq_delta_array(jt_s_data, {len(jt_s)})
let jt_end : FixedArray[Int] = decode_vlq_end_array(jt_start, jt_e_data, {len(jt_s)})
let jt_val : FixedArray[Int] = decode_vlq_u_array(jt_v_data, {len(jt_s)})

let nfcqc_count : Int = {len(nfcqc_s)}
let nfcqc_start : FixedArray[Int] = decode_vlq_delta_array(nfcqc_s_data, {len(nfcqc_s)})
let nfcqc_end : FixedArray[Int] = decode_vlq_end_array(nfcqc_start, nfcqc_e_data, {len(nfcqc_s)})

///| Lookup UTS #46 mapping entry for `cp`.
///| Returns: 0=disallowed, 1=valid, 2=ignored, 5=deviation,
///| (v&7)==3 => single-cp delta=(v>>3), (v&7)==4 => multi-cp off=(v>>3)&0xFFFF, len=v>>19.
fn uts46_lookup(cp : Int) -> Int {{
  let starts = idna_start
  let mut lo = 0
  let mut hi = idna_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    if starts[mid] <= cp {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  if hi >= 0 && cp <= idna_end[hi] {{
    idna_val[hi]
  }} else {{
    0
  }}
}}

fn build_latin1_uts46_lut() -> FixedArray[Int] {{
  let lut : FixedArray[Int] = FixedArray::make(256, 0)
  let mut cp = 0
  while cp < 256 {{
    lut[cp] = uts46_lookup(cp)
    cp = cp + 1
  }}
  lut
}}

let latin1_uts46_lut : FixedArray[Int] = build_latin1_uts46_lut()

fn uts46_lookup_fast(cp : Int) -> Int {{
  if cp < 256 {{
    latin1_uts46_lut[cp]
  }} else if cp >= 0x4E00 && cp <= 0x9FFF {{
    1
  }} else {{
    uts46_lookup(cp)
  }}
}}

fn unicode_ccc(cp : Int) -> Int {{
  if cp < 0x0300 {{
    return 0
  }}
  let starts = ccc_start
  let mut lo = 0
  let mut hi = ccc_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    if starts[mid] <= cp {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  if hi >= 0 && cp <= ccc_end[hi] {{
    ccc_val[hi]
  }} else {{
    0
  }}
}}

fn unicode_decomp_info(cp : Int) -> Int {{
  if cp < 0x00C0 {{
    return -1
  }}
  let cps = decomp_cp
  let mut lo = 0
  let mut hi = decomp_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    let v = cps[mid]
    if v == cp {{
      return decomp_info[mid]
    }} else if v < cp {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  -1
}}

fn unicode_compose_pair(c1 : Int, c2 : Int) -> Int {{
  let key = (c1.to_int64() << 21L) | c2.to_int64()
  let keys = comp_key
  let mut lo = 0
  let mut hi = comp_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    let v = keys[mid]
    if v == key {{
      return comp_val[mid]
    }} else if v < key {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  -1
}}

fn unicode_is_mark(cp : Int) -> Bool {{
  if cp < 0x0300 {{
    return false
  }}
  let starts = mark_start
  let mut lo = 0
  let mut hi = mark_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    if starts[mid] <= cp {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  hi >= 0 && cp <= mark_end[hi]
}}

///| Lookup Bidi_Class: 0=L, 1=R, 2=AL, 3=EN, 4=ES, 5=ET, 6=AN, 7=CS, 8=NSM, 9=BN, 10=ON, 11=OTHER.
fn unicode_bidi_class(cp : Int) -> Int {{
  if cp >= 97 && cp <= 122 {{
    return 0
  }}
  let starts = bidi_start
  let mut lo = 0
  let mut hi = bidi_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    if starts[mid] <= cp {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  if hi >= 0 && cp <= bidi_end[hi] {{
    bidi_val[hi]
  }} else {{
    0
  }}
}}

///| Lookup Joining_Type: 0=other, 1=L, 2=R, 3=D, 4=T.
fn unicode_joining_type(cp : Int) -> Int {{
  if cp < 0x0300 {{
    return 0
  }}
  let starts = jt_start
  let mut lo = 0
  let mut hi = jt_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    if starts[mid] <= cp {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  if hi >= 0 && cp <= jt_end[hi] {{
    jt_val[hi]
  }} else {{
    0
  }}
}}

///| Return true if `cp` has NFC_Quick_Check != Yes (No or Maybe) in Unicode 16.0.0.
fn unicode_nfc_qc_not_yes(cp : Int) -> Bool {{
  if cp < 0x0300 {{
    return false
  }}
  let starts = nfcqc_start
  let mut lo = 0
  let mut hi = nfcqc_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    if starts[mid] <= cp {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  hi >= 0 && cp <= nfcqc_end[hi]
}}
""")

    with open(out_path, "w", encoding="utf-8") as f:
        f.writelines(lines)


def write_uts39_tables(
    out_path: str,
    script_ranges,
    ign_ranges,
    nd_ranges,
    conf_cps,
    conf_infos,
    conf_pool,
    bracket_cps,
    bracket_vals,
    mirror_cps,
    mirror_vals,
    id_allowed_ranges,
):
    sc_s = [r[0] for r in script_ranges]
    sc_e = [r[1] for r in script_ranges]
    sc_v = [r[2] for r in script_ranges]

    ig_s = [r[0] for r in ign_ranges]
    ig_e = [r[1] for r in ign_ranges]

    nd_s = [r[0] for r in nd_ranges]
    nd_e = [r[1] for r in nd_ranges]

    ida_s = [r[0] for r in id_allowed_ranges]
    ida_e = [r[1] for r in id_allowed_ranges]

    lines = []
    lines.append("///| Auto-generated by `tools/gen_tables.py` from Unicode 16.0.0 data (Unicode-3.0 license).\n")
    lines.append("///| Sources: Scripts.txt, DerivedCoreProperties.txt, UnicodeData.txt, confusables.txt,\n")
    lines.append("///| BidiBrackets.txt, BidiMirroring.txt, IdentifierStatus.txt.\n\n")

    lines.append(format_pion_string("script_s_data", encode_vlq_delta_array(sc_s)))
    lines.append(format_pion_string("script_e_data", encode_vlq_end_array(sc_s, sc_e)))
    lines.append(format_pion_string("script_v_data", encode_vlq_u_array(sc_v)))

    lines.append(format_pion_string("ign_s_data", encode_vlq_delta_array(ig_s)))
    lines.append(format_pion_string("ign_e_data", encode_vlq_end_array(ig_s, ig_e)))

    lines.append(format_pion_string("nd_s_data", encode_vlq_delta_array(nd_s)))
    lines.append(format_pion_string("nd_e_data", encode_vlq_end_array(nd_s, nd_e)))

    lines.append(format_pion_string("conf_cp_data", encode_vlq_delta_array(conf_cps)))
    lines.append(format_pion_string("conf_info_data", encode_vlq_u_array(conf_infos)))
    lines.append(format_pion_string("conf_pool_data", encode_vlq_u_array(conf_pool)))

    lines.append(format_pion_string("bracket_cp_data", encode_vlq_delta_array(bracket_cps)))
    lines.append(format_pion_string("bracket_val_data", encode_vlq_u_array(bracket_vals)))

    lines.append(format_pion_string("mirror_cp_data", encode_vlq_delta_array(mirror_cps)))
    lines.append(format_pion_string("mirror_val_data", encode_vlq_u_array(mirror_vals)))

    lines.append(format_pion_string("ida_s_data", encode_vlq_delta_array(ida_s)))
    lines.append(format_pion_string("ida_e_data", encode_vlq_end_array(ida_s, ida_e)))

    lines.append(f"""
let script_count : Int = {len(sc_s)}
let script_start : FixedArray[Int] = decode_vlq_delta_array(script_s_data, {len(sc_s)})
let script_end : FixedArray[Int] = decode_vlq_end_array(script_start, script_e_data, {len(sc_s)})
let script_val : FixedArray[Int] = decode_vlq_u_array(script_v_data, {len(sc_s)})

let ign_count : Int = {len(ig_s)}
let ign_start : FixedArray[Int] = decode_vlq_delta_array(ign_s_data, {len(ig_s)})
let ign_end : FixedArray[Int] = decode_vlq_end_array(ign_start, ign_e_data, {len(ig_s)})

let nd_count : Int = {len(nd_s)}
let nd_start : FixedArray[Int] = decode_vlq_delta_array(nd_s_data, {len(nd_s)})
let nd_end : FixedArray[Int] = decode_vlq_end_array(nd_start, nd_e_data, {len(nd_s)})

let conf_count : Int = {len(conf_cps)}
let conf_cp : FixedArray[Int] = decode_vlq_delta_array(conf_cp_data, {len(conf_cps)})
let conf_info : FixedArray[Int] = decode_vlq_u_array(conf_info_data, {len(conf_cps)})
let conf_pool : FixedArray[Int] = decode_vlq_u_array(conf_pool_data, {len(conf_pool)})

let bracket_count : Int = {len(bracket_cps)}
let bracket_cp : FixedArray[Int] = decode_vlq_delta_array(bracket_cp_data, {len(bracket_cps)})
let bracket_val : FixedArray[Int] = decode_vlq_u_array(bracket_val_data, {len(bracket_cps)})

let mirror_count : Int = {len(mirror_cps)}
let mirror_cp : FixedArray[Int] = decode_vlq_delta_array(mirror_cp_data, {len(mirror_cps)})
let mirror_val : FixedArray[Int] = decode_vlq_u_array(mirror_val_data, {len(mirror_cps)})

let ida_count : Int = {len(ida_s)}
let ida_start : FixedArray[Int] = decode_vlq_delta_array(ida_s_data, {len(ida_s)})
let ida_end : FixedArray[Int] = decode_vlq_end_array(ida_start, ida_e_data, {len(ida_s)})

///| Lookup Unicode Script ID (0=Common, 1=Inherited, 2=Latin, 3=Greek, 4=Cyrillic, 5=Han, ...).
fn unicode_script_id(cp : Int) -> Int {{
  if (cp >= 65 && cp <= 90) || (cp >= 97 && cp <= 122) {{
    return 2
  }}
  if cp < 0x00AA {{
    return 0
  }}
  let starts = script_start
  let mut lo = 0
  let mut hi = script_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    if starts[mid] <= cp {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  if hi >= 0 && cp <= script_end[hi] {{
    script_val[hi]
  }} else {{
    0
  }}
}}

///| Return true if `cp` has Default_Ignorable_Code_Point property.
fn unicode_is_default_ignorable(cp : Int) -> Bool {{
  if cp < 0x00AD {{
    return false
  }}
  let starts = ign_start
  let mut lo = 0
  let mut hi = ign_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    if starts[mid] <= cp {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  hi >= 0 && cp <= ign_end[hi]
}}

///| Return decimal digit numbering-system block index (>= 0) if `cp` has General_Category Nd, else -1.
fn unicode_decimal_digit_system(cp : Int) -> Int {{
  if cp >= 48 && cp <= 57 {{
    return 0
  }}
  if cp < 0x0660 {{
    return -1
  }}
  let starts = nd_start
  let mut lo = 0
  let mut hi = nd_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    if starts[mid] <= cp {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  if hi >= 0 && cp <= nd_end[hi] {{
    hi
  }} else {{
    -1
  }}
}}

///| Lookup UTS #39 confusable prototype info for `cp`, or -1 if unmapped.
///| Encoding: (info & 1) == 0 => single target cp = info >> 1;
///|           (info & 1) == 1 => packed = info >> 1, off = packed & 0xFFFF, len = packed >> 16.
fn unicode_confusable_info(cp : Int) -> Int {{
  let cps = conf_cp
  let mut lo = 0
  let mut hi = conf_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    let v = cps[mid]
    if v == cp {{
      return conf_info[mid]
    }} else if v < cp {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  -1
}}

///| Lookup UAX #9 BidiBrackets entry for `cp`, or -1 if not a bracket.
///| Encoding: (val & 1) == 1 => opening bracket, 0 => closing; paired_cp = val >> 1.
fn unicode_bidi_bracket(cp : Int) -> Int {{
  let cps = bracket_cp
  let mut lo = 0
  let mut hi = bracket_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    let v = cps[mid]
    if v == cp {{
      return bracket_val[mid]
    }} else if v < cp {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  -1
}}

///| Lookup UAX #9 Bidi_Mirroring_Glyph for `cp` (returns `cp` itself if unmirrored).
fn unicode_bidi_mirror(cp : Int) -> Int {{
  let cps = mirror_cp
  let mut lo = 0
  let mut hi = mirror_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    let v = cps[mid]
    if v == cp {{
      return mirror_val[mid]
    }} else if v < cp {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  cp
}}

///| Return true if `cp` has UTS #39 Identifier_Status = Allowed in Unicode 16.0.0.
fn unicode_is_identifier_allowed(cp : Int) -> Bool {{
  let starts = ida_start
  let mut lo = 0
  let mut hi = ida_count - 1
  while lo <= hi {{
    let mid = (lo + hi) >> 1
    if starts[mid] <= cp {{
      lo = mid + 1
    }} else {{
      hi = mid - 1
    }}
  }}
  hi >= 0 && cp <= ida_end[hi]
}}
""")

    with open(out_path, "w", encoding="utf-8") as f:
        f.writelines(lines)


def main():
    if len(sys.argv) != 3:
        print("usage: gen_tables.py <unicode_16_dir> <out_src_dir>", file=sys.stderr)
        sys.exit(1)
    ucd_dir = sys.argv[1]
    out_dir = sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    idna_ranges, idna_pool = parse_idna_mapping(os.path.join(ucd_dir, "IdnaMappingTable.txt"))
    ccc_ranges, full_decomp, comp_pairs, mark_ranges, nd_ranges = parse_unicode_data(
        os.path.join(ucd_dir, "UnicodeData.txt"),
        os.path.join(ucd_dir, "CompositionExclusions.txt"),
    )
    bidi_ranges = parse_bidi(os.path.join(ucd_dir, "DerivedBidiClass.txt"))
    jt_ranges = parse_joining_type(os.path.join(ucd_dir, "DerivedJoiningType.txt"))
    nfcqc_ranges = parse_nfc_qc(os.path.join(ucd_dir, "DerivedNormalizationProps.txt"))
    script_ranges = parse_scripts(os.path.join(ucd_dir, "Scripts.txt"))
    ign_ranges = parse_default_ignorable(os.path.join(ucd_dir, "DerivedCoreProperties.txt"))
    conf_cps, conf_infos, conf_pool = parse_confusables(os.path.join(ucd_dir, "confusables.txt"))
    bracket_cps, bracket_vals = parse_bidi_brackets(os.path.join(ucd_dir, "BidiBrackets.txt"))
    mirror_cps, mirror_vals = parse_bidi_mirroring(os.path.join(ucd_dir, "BidiMirroring.txt"))
    id_allowed_ranges = parse_identifier_status(os.path.join(ucd_dir, "IdentifierStatus.txt"))

    write_uts46_tables(
        os.path.join(out_dir, "tables_uts46.pion"),
        idna_ranges, idna_pool, ccc_ranges, full_decomp, comp_pairs, mark_ranges, bidi_ranges, jt_ranges, nfcqc_ranges,
    )
    write_uts39_tables(
        os.path.join(out_dir, "tables_uts39.pion"),
        script_ranges, ign_ranges, nd_ranges, conf_cps, conf_infos, conf_pool,
        bracket_cps, bracket_vals, mirror_cps, mirror_vals, id_allowed_ranges,
    )
    print(
        f"Generated tables_uts46.pion & tables_uts39.pion: "
        f"idna={len(idna_ranges)} pool={len(idna_pool)} ccc={len(ccc_ranges)} "
        f"decomp={len(full_decomp)} comp={len(comp_pairs)} marks={len(mark_ranges)} "
        f"bidi={len(bidi_ranges)} jt={len(jt_ranges)} nfcqc={len(nfcqc_ranges)} "
        f"scripts={len(script_ranges)} ign={len(ign_ranges)} nd={len(nd_ranges)} "
        f"conf={len(conf_cps)} conf_pool={len(conf_pool)} brackets={len(bracket_cps)} "
        f"mirrors={len(mirror_cps)} id_allowed={len(id_allowed_ranges)}"
    )


if __name__ == "__main__":
    main()
