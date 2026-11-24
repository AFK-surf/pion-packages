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
    ("linebreak.pion", "after_zw_sp = cur == cls_ZW", "after_zw_sp = false", "LB8: ZW SP* no longer forces a break", 1),
    ("linebreak.pion", "after_hl_hy_ba = prev == cls_HL &&", "after_hl_hy_ba = false && prev == cls_HL &&",
     "LB21a: HL (HY | BA) x dropped"),
    ("tables.pion", "let flag_qu_pi : Int = 2", "let flag_qu_pi : Int = 64", "tables: QU_Pi flag never set"),
    ("utf8.pion", "b1 >= 0xA0 && b1 <= 0xBF", "(b1 & 0xC0) == 0x80", "UTF-8: E0 overlong forms accepted"),
    # regressions of the 585254a fixes
    ("linebreak.pion", "(cur == cls_HY || (cur == cls_BA && !cur_ea))", "(cur == cls_HY || cur == cls_BA)",
     "P2-2 regression: LB21a [BA - $EastAsian] exclusion dropped (line_breaks)", 1),
    ("linebreak.pion", "let cur_ea = if is_lb10 { false } else { (cur_flags & flag_ea) != 0 }",
     "let cur_ea = (cur_flags & flag_ea) != 0", "P2-3 regression: LB10 keeps the mark's East_Asian_Width (line_breaks)", 1),
    ("linebreak.pion", "    res_cls == cls_SP ||\n", "",
     "P1-1 anchor: SP accepted as a state-reset anchor (loses OP SP* / ZW SP* / B2 SP* state)"),
    ("linebreak.pion", "    res_cls == cls_RI)", "    false)", "P1-1 anchor: RI accepted as an anchor (loses LB30a parity)"),
    ("linebreak.pion", "let anchor = find_backward_anchor(s, target, n)", "let anchor = find_backward_anchor(s, target + 1, n)",
     "P1-1 anchor: search starts one byte past the target"),
    ("linebreak.pion", "    res_cls == cls_QU ||\n", "", "P1-1 anchor: QU accepted as an anchor (loses LB19a / LB15a context)"),
    ("linebreak.pion", "if cont == 4 ||", "if cont == 3 ||", "P1-1 anchor: a 4-byte sequence's last continuation byte taken as standalone"),
    ("linebreak.pion", "if np <= saved {", "if np < saved {", "P1-1 anchor: continuation byte at the end of its sequence taken as standalone"),
    # LineBreakIter (second copy of the engine)
    ("linebreak.pion", "(cur == cls_HY || (cur == cls_BA && !cur_ea))", "(cur == cls_HY || cur == cls_BA)",
     "LineBreakIter: LB21a [BA - $EastAsian] exclusion dropped", 2),
    ("linebreak.pion", "let cur_ea = if is_lb10 { false } else { (cur_flags & flag_ea) != 0 }",
     "let cur_ea = (cur_flags & flag_ea) != 0", "LineBreakIter: LB10 keeps the mark's East_Asian_Width", 2),
    ("linebreak.pion", "self.ri_odd = !self.ri_odd", "self.ri_odd = true", "LineBreakIter: LB30a parity lost"),
    ("linebreak.pion", "  self.done = true\n  Some(BreakOpportunity::new(n, BreakKind::Mandatory))",
     "  self.done = true\n  Some(BreakOpportunity::new(n, BreakKind::Allowed))", "LineBreakIter: eot reported Allowed"),
    ("linebreak.pion", "    self.after_qu_pi_sp = self.prev_qu_pi\n", "    self.after_qu_pi_sp = false\n",
     "LineBreakIter: sot Pi quote not glued (LB15a at sot)"),
]


def main(argv):
    pkg, out = argv[0], argv[1]
    for n, m in enumerate(M, 1):
        f, old, new, desc = m[:4]
        occ = m[4] if len(m) > 4 else 1  # which occurrence (the engine exists twice: run_linebreak, LineBreakIter)
        multi = len(m) > 4
        dst = os.path.join(out, "m%d" % n, "unicode_linebreak")
        shutil.copytree(os.path.join(pkg, "src"), os.path.join(dst, "src"))
        shutil.copy(os.path.join(pkg, "pion.toml"), os.path.join(dst, "pion.toml"))
        shutil.copytree(os.path.join(pkg, "audit"), os.path.join(dst, "audit"),
                        ignore=shutil.ignore_patterns("ucd", "rust", "*.md"))
        p = os.path.join(dst, "src", f)
        s = open(p, encoding="utf-8").read()
        k = s.count(old)
        if k < occ or (occ == 1 and k != 1 and not multi):
            print("%d SKIP %s" % (n, desc))
            continue
        i = -1
        for _ in range(occ):
            i = s.index(old, i + 1)
        open(p, "w", encoding="utf-8").write(s[:i] + new + s[i + len(old):])
        print("%d %s %s" % (n, os.path.join(dst, "audit"), desc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
