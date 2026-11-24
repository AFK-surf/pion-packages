"""Mutation proof for the RT-unicode-segment audit (stdlib only).

    python3 -I -B inject.py <pkg_dir> <out_dir>

Copies packages/unicode_segment (src without its unit tests, pion.toml) once per mutant into
<out_dir>/m<N>/pkg, applies ONE realistic defect and prints `<N> <dir> <description>` (`<N> SKIP ...` when the
target text is no longer present exactly once, e.g. on a fix branch). run_audit.sh `inject` rebuilds the audit
binary and the table probe against each mutant and requires that the gate fails on it.
"""

import os
import shutil
import sys

MUTANTS = [
    ("grapheme.pion", "if incb_state == 2 && curr_incb == incb_consonant {",
     "if incb_state == 3 && curr_incb == incb_consonant {", "GB9c Indic conjunct rule disabled"),
    ("grapheme.pion", "if ep_state == 2 && curr_ep == 1 {", "if ep_state == 1 && curr_ep == 1 {",
     "GB11 keyed on EP Extend* instead of EP Extend* ZWJ"),
    ("grapheme.pion", "curr_gcb == gcb_regional_indicator && ri_odd {", "curr_gcb == gcb_regional_indicator {",
     "GB12/GB13 regional-indicator parity ignored (odd RI runs)"),
    ("word.pion", "      brk = false\n      is_wb4_ignored = true", "      brk = false\n      is_wb4_ignored = false",
     "WB4 Extend/Format/ZWJ no longer transparent"),
    ("sentence.pion", "if curr_sb == sb_lower {\n          matched_sb8 = true",
     "if curr_sb == sb_lower {\n          matched_sb8 = false", "SB8 ATerm ... x Lower disabled"),
    ("types.pion", "if limits.max_input_bytes < 0 || limits.max_segments < 0 {",
     "if limits.max_input_bytes < -1 && limits.max_segments < -1 {", "negative SegmentLimits accepted"),
    ("utf8.pion", "      if (b1 & 0xC0) == 0x80 {\n        return ((((b0 & 0x1F) << 6)",
     "      if b1 >= 0 {\n        return ((((b0 & 0x1F) << 6)",
     "2-byte UTF-8 decode no longer checks the continuation byte (C3 '(' swallows the next byte)"),
    # Tried and dropped as an EQUIVALENT mutant (REPORT.md INFO-7): removing the mid-UTF-8 lead-byte alignment
    # loop of find_safe_grapheme_anchor changes nothing, because the backward walk re-synchronises through its
    # `start + clen != cur` path; every cursor result at every byte offset of the 9,727 inputs stays identical.
    ("grapheme.pion", "    if pos > byte_offset {\n      return false", "    if pos > byte_offset {\n      return true",
     "is_grapheme_boundary reports mid-cluster / mid-UTF-8 offsets as boundaries"),
    ("tables.pion", "      if target <= r_hi {", "      if target < r_hi {",
     "SMP range binary search drops the last code point of every range"),
    ("tables.pion", "data_s.code_unit_at((page << 8) | (cp & 255)) - 65", "data_s.code_unit_at((page << 8) | (cp & 254)) - 65",
     "BMP two-level page lookup reads the wrong slot for odd code points"),
    ("sentence.pion", "out.length() + 1 >= limits.max_segments", "out.length() + 1 > limits.max_segments",
     "sentence max_segments off by one (accepts k + 1 segments)"),
    ("utf8.pion", "(b0 != 0xED || b1 < 0xA0)", "(b0 != 0xED || b1 < 0xC0)",
     "UTF-8 decoder accepts encoded surrogates (ED A0..BF)"),
    ("word.pion", "wb_is_ahletter(wb_peek_next_non_ignored(s, pos + clen, n)) {",
     "wb_is_ahletter(wb_peek_next_non_ignored(s, pos, n)) {", "WB6 lookahead starts at the MidLetter itself"),
    ("grapheme.pion", "  // GB9b: Prepend x\n  if prev_gcb == gcb_prepend {",
     "  // GB9b: Prepend x\n  if prev_gcb == gcb_spacingmark {", "GB9b Prepend rule keyed on SpacingMark"),
]


def main():
    pkg, out = sys.argv[1], sys.argv[2]
    for i, (fname, old, new, desc) in enumerate(MUTANTS, 1):
        d = os.path.join(out, "m%d" % i, "pkg")
        src = open(os.path.join(pkg, "src", fname), encoding="utf-8").read()
        if src.count(old) != 1:
            print("%d SKIP %s" % (i, desc))
            continue
        shutil.rmtree(os.path.dirname(d), ignore_errors=True)
        os.makedirs(os.path.join(d, "src"))
        shutil.copy(os.path.join(pkg, "pion.toml"), d)
        for f in os.listdir(os.path.join(pkg, "src")):
            if f.endswith(".pion") and not f.endswith("_test.pion"):
                shutil.copy(os.path.join(pkg, "src", f), os.path.join(d, "src", f))
        with open(os.path.join(d, "src", fname), "w", encoding="utf-8") as f:
            f.write(src.replace(old, new))
        print("%d %s %s: %s" % (i, d, fname, desc))


if __name__ == "__main__":
    main()
