"""Bug-injection (mutation) gate for the RT-unicode-linebreak audit.

  inject.py <pkg_dir> <outdir>   copy packages/unicode_linebreak (src + audit) once per mutant into
                                 <outdir>/m<N>/unicode_linebreak, apply one realistic defect to src/, print
                                 `<N> <audit dir of the copy> <description>` (`<N> SKIP <description>` when the
                                 target text is not present exactly once any more)

run_audit.sh builds each mutant's audit binary and requires that the gate (control cases, official
LineBreakTest-16.0.0 positions + kinds, next_break_opportunity / limits API sweep) fails for every one.
The repository is never touched.
"""
import os
import shutil
import sys

M = [
    ("linebreak.pion", "decision = 0 // LB9", "decision = 1 // LB9", "LB9: CM / ZWJ no longer absorbed into the base"),
    ("linebreak.pion", "after_qu_pi_sp = cur_qu_pi && is_lb15a_before(prev)", "after_qu_pi_sp = false",
     "LB15a: opening Pi quote + SP* no longer glued"),
    ("linebreak.pion", "if !la_found || is_lb15b_after(la_eff) {", "if !la_found {",
     "LB15b: closing Pf quote only protected at eot"),
    ("linebreak.pion", "decision = 0 // LB20a (Unicode 16.0.0)", "decision = 1 // LB20a",
     "LB20a: word-initial hyphen breaks before the letter"),
    ("linebreak.pion", "((prev == cls_PR || prev == cls_PO) && cur == cls_NU) ||", "false ||",
     "LB25: (PR | PO) x NU dropped"),
    ("linebreak.pion", "(after_ak_vi && (cur == cls_AK || cur_25cc))", "false",
     "LB28a: (AK | dotted circle | AS) VI x (AK | dotted circle) dropped"),
    ("linebreak.pion", "ri_odd = !ri_odd", "ri_odd = true", "LB30a: RI pairing parity lost (RI RI RI glued)"),
    ("linebreak.pion", "decision = 2 // LB4", "decision = 1 // LB4", "LB4: break after BK reported Allowed, not Mandatory"),
    ("linebreak.pion", "decision = 2 // LB5: CR!, LF!, NL!", "decision = 1 // LB5",
     "LB5: break after CR / LF / NL reported Allowed"),
    ("linebreak.pion", "decision = 0 // LB5: CR x LF", "decision = 2 // LB5", "LB5: break between CR and LF"),
    ("linebreak.pion", "if limits.max_input_bytes < 0 || limits.max_opportunities < 0 {",
     "if limits.max_input_bytes < -1 {", "LineBreakLimits: negative limits no longer rejected"),
    ("linebreak.pion", "if s.length() > limits.max_input_bytes {", "if s.length() > limits.max_input_bytes + 1 {",
     "LineBreakLimits: max_input_bytes off by one"),
    ("linebreak.pion", "if cur_raw == cls_AL && prev == cls_AL && !raw_prev_zwj {", "if cur_raw == cls_AL && !raw_prev_zwj {",
     "ASCII fast path taken after any class (skips LB18 / LB31 before letters)"),
    ("linebreak.pion", "if !la_found || (la_flags & flag_ea) == 0 {", "if !la_found {",
     "LB19a: x QU [^EastAsian] lookahead ignored"),
    ("linebreak.pion", "if cur_byte_offset > find_after {", "if cur_byte_offset >= find_after {",
     "next_break_opportunity returns the opportunity *at* the offset"),
    ("linebreak.pion", "(prev == cls_EB || prev_ep_cn) && cur == cls_EM", "prev == cls_EB && cur == cls_EM",
     "LB30b: [ExtPict & Cn] x EM dropped"),
    ("linebreak.pion", "after_zw_sp = cur == cls_ZW", "after_zw_sp = false", "LB8: ZW SP* no longer forces a break"),
    ("linebreak.pion", "after_hl_hy_ba = prev == cls_HL &&", "after_hl_hy_ba = false && prev == cls_HL &&",
     "LB21a: HL (HY | BA) x dropped"),
    ("tables.pion", "let flag_qu_pi : Int = 2", "let flag_qu_pi : Int = 64", "tables: QU_Pi flag never set"),
    ("utf8.pion", "b1 >= 0xA0 && b1 <= 0xBF", "(b1 & 0xC0) == 0x80", "UTF-8: E0 overlong forms accepted"),
    # regressions of the 585254a fixes
    ("linebreak.pion", "(cur == cls_HY || (cur == cls_BA && !cur_ea))", "(cur == cls_HY || cur == cls_BA)",
     "P2-2 regression: LB21a [BA - $EastAsian] exclusion dropped"),
    ("linebreak.pion", "let cur_ea = if is_lb10 { false } else { (cur_flags & flag_ea) != 0 }",
     "let cur_ea = (cur_flags & flag_ea) != 0", "P2-3 regression: LB10 keeps the mark's East_Asian_Width"),
    ("linebreak.pion", "  if res_cls == cls_NU {\n    return true\n  }", "  if res_cls == cls_NU || res_cls == cls_SP {\n    return true\n  }",
     "P1-1 anchor: SP accepted as a state-reset anchor (loses OP SP* / ZW SP* / B2 SP* state)"),
    ("linebreak.pion", "  if res_cls == cls_NU {\n    return true\n  }", "  if res_cls == cls_NU || res_cls == cls_RI {\n    return true\n  }",
     "P1-1 anchor: RI accepted as an anchor (loses LB30a parity)"),
    ("linebreak.pion", "let anchor = find_backward_anchor(s, target, n)", "let anchor = find_backward_anchor(s, target + 1, n)",
     "P1-1 anchor: search starts one byte past the target"),
]


def main(argv):
    pkg, out = argv[0], argv[1]
    for n, (f, old, new, desc) in enumerate(M, 1):
        dst = os.path.join(out, "m%d" % n, "unicode_linebreak")
        shutil.copytree(os.path.join(pkg, "src"), os.path.join(dst, "src"))
        shutil.copy(os.path.join(pkg, "pion.toml"), os.path.join(dst, "pion.toml"))
        shutil.copytree(os.path.join(pkg, "audit"), os.path.join(dst, "audit"),
                        ignore=shutil.ignore_patterns("ucd", "rust", "*.md"))
        p = os.path.join(dst, "src", f)
        s = open(p, encoding="utf-8").read()
        if s.count(old) != 1:
            print("%d SKIP %s" % (n, desc))
            continue
        open(p, "w", encoding="utf-8").write(s.replace(old, new))
        print("%d %s %s" % (n, os.path.join(dst, "audit"), desc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
