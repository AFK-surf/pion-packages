"""Deterministic corpora for the RT-unicode-linebreak audit (stdlib only). `<name>\\t<hex bytes>` per line.

  gen.py <ucd_dir> <outdir> [fuzz_n]

  lbtest.cases  every LineBreakTest-16.0.0.txt vector (16,672), in file order, named L<line>
  named.cases   hand-written adversarial inputs: ASCII fast-path seams, LB9/LB10 after SP/BK/ZW/CR/LF/NL,
                LB15a-d, LB19/19a, LB20a, LB21a, LB25 chains, LB28a syllables, LB30a parity, LB30b, CR/LF/NL/BK,
                ill-formed / truncated / overlong / surrogate UTF-8
  pairs.cases   every ordered pair of representatives of all (Line_Break, LB1 class, EA, Pi, Pf, ExtPict&Cn,
                U+2010, U+25CC) property combinations occurring in Unicode 16.0.0 (2 code points each), plus the
                same pair with SP, CM, ZWJ, SP SP in between
  fastpath.cases  the inlined ASCII AL x AL path against everything: "ab" + c + "cd" and "ab" + c + d + "cd"
                for every ASCII c, d, and "ab" + r + "cd", "ab" + r + "\u0301cd", r + "ab" for every representative r
  long.cases    longer random strings (40-200 code points, a quarter with an ill-formed byte) so that
                next_break_opportunity's backward anchor search walks over real distances
  icuprobe.cases  short probes that isolate the contexts in which Rust icu_segmenter 2.4.0 departs from
                16.0.0 (dotted-circle / Brahmic prefixes, NU (SY | IS) PO / PR chains) followed by every
                representative: they give compare.py ICU's own behaviour per context (never used for Pion verdicts)
  fuzz.cases    random strings over those representatives, weighted towards the classes the tricky rules use,
                10 % with raw ill-formed bytes spliced in
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model  # noqa: E402
import ucd  # noqa: E402


def enc(s):
    return s.encode("utf-8", "surrogatepass") if isinstance(s, str) else s


NAMED = [
    # ASCII fast path (AL x AL inlined) against every neighbour it could swallow
    ("fast_cm", "áb"), ("fast_cm2", "ab́́cd"), ("fast_zwj", "a‍b"), ("fast_zwj2", "ab‍cd"),
    ("fast_qu", 'ab"cd'), ("fast_qu_sp", 'ab "cd" ef'), ("fast_op", "ab(cd"), ("fast_cl", "ab)cd"),
    ("fast_hy", "ab-cd"), ("fast_is", "ab.cd"), ("fast_sy", "ab/cd"), ("fast_ex", "ab!cd"), ("fast_nu", "ab12cd"),
    ("fast_pr", "ab$cd"), ("fast_po", "ab%cd"), ("fast_hl", "abאcd"), ("fast_id", "ab一cd"),
    ("fast_gl", "ab cd"), ("fast_wj", "ab⁠cd"), ("fast_zw", "ab​cd"), ("fast_ba", "ab\tcd"),
    ("fast_bb", "ab´cd"), ("fast_cb", "ab￼cd"), ("fast_in", "ab…cd"), ("fast_ri", "ab\U0001F1E6cd"),
    ("fast_eb", "ab\U0001F466\U0001F3FBcd"), ("fast_25cc", "ab◌᭄cd"), ("fast_hy_al", "x -ab"),
    ("fast_hy_al2", "-ab-cd"), ("fast_after_cr", "ab\rcd\nef\r\ngh"), ("fast_nul", "ab\x00cd"),
    ("fast_ctrl", "ab\x01\x7fcd"), ("fast_ai", "ab§cd"), ("fast_sa", "abกัcd"),
    # LB9 / LB10: CM and ZWJ after SP / BK / ZW / CR / LF / NL, at sot, runs
    ("lb9_sp_cm", "a ́b"), ("lb9_bk_cm", "a\x0b́b"), ("lb9_zw_cm", "a​́b"),
    ("lb9_cr_cm", "a\ŕb"), ("lb9_lf_cm", "a\ńb"), ("lb9_nl_cm", "a\u0085́b"),
    ("lb9_sp_zwj", "a ‍b"), ("lb9_sot_cm", "́a"), ("lb9_sot_zwj", "‍一"),
    ("lb9_cm_run", "一" + "́" * 8 + "一"), ("lb9_zwj_cm_mix", "a‍́‍一"),
    ("lb10_sp_cm_qu", " ́“一"), ("lb10_sp_eacm_qu", " ゙“一"),
    ("lb10_sot_eacm_qu", "゙“一"), ("lb10_sp_eacm_qu2", " 〪”一"),
    ("lb10_sp_eacm_op", " ゙（一"), ("lb10_sp_cm_op", " ́(a"),
    ("lb10_sp_eacm_qu_after", "一“ ゙"), ("lb10_vs_ea", " \U00016FF0“一"),
    # LB15a / LB15b
    ("lb15a_sot", "« x"), ("lb15a_sp", "a «  x"), ("lb15a_op", "(« x"), ("lb15a_mid", "a« x"),
    ("lb15a_cm", "«́ x"), ("lb15b_eot", "x »"), ("lb15b_sp", "x » y"),
    ("lb15b_al", "x »y"), ("lb15b_cm", "x »́ y"), ("lb15b_cl", "x ») y"),
    ("lb15_both", "“ ”"), ("lb15_nested", "‘“ x ”’"),
    # LB15c / LB15d
    ("lb15c", "subtract .5"), ("lb15c_cm", "a .́5"), ("lb15c_not_nu", "a .b"), ("lb15d", "a .b"),
    ("lb15c_sp2", "a  ,5"),
    # LB19 / LB19a
    ("lb19_ascii", '一"一'), ("lb19a_cjk_pi", "一“一"), ("lb19a_cjk_pf", "一”一"),
    ("lb19a_mixed", "a“一"), ("lb19a_mixed2", "一“a"), ("lb19a_eot", "一“"),
    ("lb19a_sot", "”一"), ("lb19a_cm", "一“́一"), ("lb19a_halfwidth", "ｱ“ｱ"),
    ("lb19a_after_sot_non_ea", "“一“一"),
    # LB20 / LB20a
    ("lb20a_sot", "-a"), ("lb20a_sp", "x -a"), ("lb20a_2010", "x ‐a"), ("lb20a_gl", " -a"),
    ("lb20a_cb", "￼-a"), ("lb20a_zw", "​-a"), ("lb20a_nl", "\u0085-a"), ("lb20a_not", "x-a"),
    ("lb20a_cm", "x -́a"), ("lb20a_hl", "x -א"), ("lb20a_nu", "x -5"), ("lb20_cb", "a￼b"),
    # LB21 / LB21a / LB21b
    ("lb21a_hy", "א-a"), ("lb21a_ba", "א‐a"), ("lb21a_hl", "א-ב"),
    ("lb21a_ideo_space", "א　a"), ("lb21a_ideo_space_cm", "א́　a"),
    ("lb21a_ideo_space_id", "א　一"), ("lb21b", "/א"), ("lb21_bb", "´a"),
    # LB25 chains
    ("lb25_money", "$(12.35)"), ("lb25_pct", "(12.5)%"), ("lb25_pr_op_is_nu", "$(.5)"), ("lb25_po_op_nu", "%(5)"),
    ("lb25_sy", "1/2"), ("lb25_sy_al", "a/b"), ("lb25_chain", "12,345.678.9/10%"), ("lb25_hy_nu", "-5"),
    ("lb25_is_nu", ".5"), ("lb25_cl_po", "5)%"), ("lb25_cl_pr", "5]$"), ("lb25_pr_op_al", "$(a"),
    ("lb25_pr_op_cm_nu", "$(́5"), ("lb25_pr_op_is_cm_nu", "$(.́5"), ("lb25_nu_sp_po", "5 %"),
    ("lb25_dollar_paren", ")$"), ("lb25_nu_cl_cl_po", "5))%"), ("lb25_fullwidth", "￥（１）"),
    # LB28a Brahmic
    ("lb28a_ap", "\U00011F02\U00011F05"), ("lb28a_vf", "ᬅ᭄"), ("lb28a_vi", "ᬅ᯲ᬅ"),
    ("lb28a_dotted", "◌᭄◌"), ("lb28a_ak_ak_vf", "ᬅᬅ᭄"),
    ("lb28a_ak_ak", "ᬅᬅ"), ("lb28a_as", "\U00011F04\U00011F41"), ("lb28a_cm", "ᬅ᬴᭄"),
    ("lb28a_vi_cm_ak", "ᬅ᬴᯲ᬅ"), ("lb28a_long", "ᬅ᭄" * 6),
    # LB30 / LB30a / LB30b
    ("lb30_op", "a(b"), ("lb30_ea_op", "a（b"), ("lb30_cp", "(a)b"), ("lb30_ea_cp", "（a）b"),
    ("lb30a_1", "\U0001F1FA"), ("lb30a_2", "\U0001F1FA\U0001F1F8"), ("lb30a_3", "\U0001F1FA\U0001F1F8\U0001F1EF"),
    ("lb30a_5", "\U0001F1E6" * 5), ("lb30a_cm", "\U0001F1FÁ\U0001F1F8\U0001F1EF"),
    ("lb30a_zwj", "\U0001F1FA‍\U0001F1F8\U0001F1EF"), ("lb30a_after_al", "a\U0001F1E6\U0001F1E6\U0001F1E6"),
    ("lb30b_eb", "\U0001F466\U0001F3FB"), ("lb30b_cn", "\U0001F777\U0001F3FB"), ("lb30b_cn2", "\U0001FFFD\U0001F3FB"),
    ("lb30b_assigned_ep", "☁\U0001F3FB"), ("lb30b_zwj_seq", "\U0001F469‍\U0001F4BB"),
    ("lb30b_arrows_cn", "\U0001F80C\U0001F3FB"), ("lb_arrows_cn_al", "a\U0001F80Cb"),
    # hard breaks
    ("crlf", "a\r\nb"), ("cr", "a\rb"), ("lf", "a\nb"), ("nl", "a\u0085b"), ("bk_vt", "a\x0bb"), ("bk_ff", "a\x0cb"),
    ("bk_ls", "a b"), ("ps", "a b"), ("crcr", "\r\r"), ("lflf", "\n\n"), ("crlfcrlf", "\r\n\r\n"),
    ("lfcr", "\n\r"), ("sp_cr_lf", "a \r\n b"), ("zw_lf", "a​\nb"), ("cr_eot", "a\r"), ("lf_eot", "a\n"),
    ("only_lf", "\n"), ("only_cr", "\r"), ("only_sp", "   "), ("zw", "a​b"), ("zw_sp", "a​  b"),
    ("sp", "a b"), ("sp_eot", "a "), ("gl", "a b"), ("wj", "a⁠ b"), ("cr_cm", "\ŕ"),
    # ill-formed UTF-8 (raw bytes)
    ("bad_lone_cont", b"a\x80b"), ("bad_lead_eot", b"ab\xe4"), ("bad_trunc3", b"a\xe4\xb8b"),
    ("bad_trunc4", b"a\xf0\x9f\x98"), ("bad_overlong2", b"\xc0\xafa"), ("bad_overlong3", b"\xe0\x80\xafa"),
    ("bad_surrogate", b"a\xed\xa0\x80b"), ("bad_f5", b"a\xf5\x80\x80\x80b"), ("bad_ff", b"\xff\xfe a"),
    ("bad_above_max", b"\xf4\x90\x80\x80a"), ("bad_cont_run", b"\x80\x80\x80\x80"), ("bad_mixed", b"\xe4\xb8\xad\x80\xe6"),
    ("bad_cm_after", b"\x80\xcc\x81 a"), ("bad_crlf", b"\r\x80\n"), ("bad_nul", b"\x00\x00"),
    # next_break_opportunity backward anchors (AL / ID / NU / BK / CR / LF / NL reset the state machine)
    ("anc_zwj", "a\u200db c d"), ("anc_zwj2", "\u4e00\u200d\u4e00 \u4e00"), ("anc_trunc", b"\xe4\xb8a b c"),
    ("anc_trunc4", b"\xf0\x9f\x98 1 2 3"), ("anc_crlf", "a\r\nb c\r\nd"), ("anc_cr_only", "a\rb\rc d"),
    ("anc_cm", "a\u0301 b\u0301 c"), ("anc_nu_cm", "1\u0301 2\u0301,3 4"), ("anc_id_cm", "\u4e00\u0301 \u4e00\u0301 x"),
    ("anc_fw_digit", "\uff11 \uff12\u0301 \uff13%"), ("anc_fw_digit_qu", "\uff11\u201c\uff12\u201d\uff13"),
    ("anc_25cc", "\u25cc\u25cc \u1b05\u25cc\u1b44 a"), ("anc_ep_cn", "\U0001F777\U0001F3FB \U0001F777 a"),
    ("anc_fffd", "\ufffd a \ufffd b"), ("anc_ef_bad", b"\xef\xbf a \xef b"), ("anc_cont_run", b"a\x80\x80\x80\x80 b c"),
    ("anc_op_sp", "a( \u4e00  b"), ("anc_qu_pi_sp", "a \u00ab  b \u00bb c"), ("anc_ri", "a\U0001F1E6\U0001F1E6\U0001F1E6 b"),
    ("anc_nu_chain", "a 1,234.56%) b 7/8$"), ("anc_pr_op", "x $(12) y %(.5) z"), ("anc_hl_hy", "\u05d0-a \u05d0\u3000b"),
    ("anc_hy_al", " -a -b \u2010c"), ("anc_b2", "a\u2014 \u2014b"), ("anc_cl_ns", "a) \u3005b"), ("anc_eb_em", "a\U0001F466\U0001F3FB b"),
    ("anc_ak_vi", "a\u1b05\u1bf2\u1b05 b"), ("anc_korean", "\uac00\uac01 \uac00 a \uac01"), ("anc_bk", "a\x0bb\x0c c\u2028d"),
    ("anc_nl", "a\u0085b c"), ("anc_lf_cm", "a\n\u0301b"), ("anc_lb10_ea", "a \u3099\u201c\u4e00 b"),
    ("big_mixed", "Hello, world! 中文排版「引号」 $(1,234.56) 🇺🇸🇯🇵 👩‍💻 א-ב ᬅ᭄ á\r\n"),
    ("empty", ""),
]


def reps(P, rnd):
    """{(raw class, LB1 class, flags): [cp, cp]} over all of Unicode 16.0.0, surrogates excluded."""
    seen = {}
    for cp in range(ucd.N):
        if 0xD800 <= cp <= 0xDFFF:
            continue
        key = (P.lb[cp], P.resolved(cp), P.flags(cp))
        seen.setdefault(key, []).append(cp)
    out = {}
    for k, cps in sorted(seen.items()):
        pick = [cps[0]]
        if len(cps) > 1:
            pick.append(rnd.choice(cps[1:]))
        out[k] = pick
    return out


def write(path, rows):
    with open(path, "w") as f:
        for name, data in rows:
            f.write("%s\t%s\n" % (name, enc(data).hex()))
    return len(rows)


def main(argv):
    ucd_dir, outdir = argv[0], argv[1]
    fuzz_n = int(argv[2]) if len(argv) > 2 else 5000
    os.makedirs(outdir, exist_ok=True)
    rnd = random.Random(0x14)
    vec = model.parse_lbtest(ucd.read(ucd_dir, "LineBreakTest.txt").decode("utf-8"))
    n1 = write(os.path.join(outdir, "lbtest.cases"), [("L%d" % no, data) for no, data, _ in vec])
    n2 = write(os.path.join(outdir, "named.cases"), NAMED)
    P = ucd.Props(ucd_dir)
    R = reps(P, rnd)
    flat = sorted(set(cp for v in R.values() for cp in v))
    rows = []
    for a in flat:
        for b in flat:
            rows.append(("P%X_%X" % (a, b), chr(a) + chr(b)))
    mids = [" ", "́", "‍", "  "]
    for i in range(len(flat) * 20):
        a, b = rnd.choice(flat), rnd.choice(flat)
        m = mids[i % 4]
        rows.append(("Q%X_%d_%X" % (a, i % 4, b), chr(a) + m + chr(b)))
    n3 = write(os.path.join(outdir, "pairs.cases"), rows)
    # weighted fuzz: the classes the stateful / lookahead rules depend on
    hot = [cp for k, v in R.items() for cp in v if k[1] in (
        "QU", "SP", "CM", "ZWJ", "NU", "IS", "SY", "PR", "PO", "OP", "CL", "CP", "HY", "BA", "HL", "AL", "AK", "AP",
        "AS", "VF", "VI", "RI", "EB", "EM", "ID", "ZW", "GL", "CB", "B2", "NS", "WJ", "BK", "CR", "LF", "NL") or k[2]]
    hot += [0x20, 0x20, 0x301, 0x200D, 0x22, 0x28, 0x29, 0x2D, 0x2E, 0x2F, 0x24, 0x25, 0x30, 0x31, 0x61, 0x62,
            0x201C, 0x201D, 0xAB, 0xBB, 0x2010, 0x25CC, 0x3000, 0x3099, 0x4E00, 0x1F1E6, 0x1F3FB, 0x1B05, 0x1B44,
            0x1BF2, 0x11F02, 0x05D0, 0x0D, 0x0A]
    rows = []
    for i in range(fuzz_n):
        ln = rnd.choice([1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 24])
        cps = [rnd.choice(hot) if rnd.random() < 0.8 else rnd.choice(flat) for _ in range(ln)]
        data = "".join(chr(c) for c in cps).encode("utf-8")
        if i % 10 == 9:
            pos = rnd.randrange(len(data) + 1)
            junk = bytes(rnd.choice([0x80, 0xBF, 0xC0, 0xC2, 0xE0, 0xE4, 0xED, 0xF0, 0xF4, 0xF5, 0xFF])
                         for _ in range(rnd.randrange(1, 4)))
            data = data[:pos] + junk + data[pos:]
        rows.append(("F%d" % i, data))
    n4 = write(os.path.join(outdir, "fuzz.cases"), rows)
    rows = []
    for c in range(128):
        rows.append(("A%02X" % c, "ab" + chr(c) + "cd"))
        for d in range(128):
            rows.append(("A%02X%02X" % (c, d), "ab" + chr(c) + chr(d) + "cd"))
    for r in flat:
        rows.append(("R%X" % r, "ab" + chr(r) + "cd"))
        rows.append(("RC%X" % r, "ab" + chr(r) + "\u0301cd"))
        rows.append(("RS%X" % r, chr(r) + "ab"))
        rows.append(("RZ%X" % r, "a\u200d" + chr(r) + "b"))
    n5 = write(os.path.join(outdir, "fastpath.cases"), rows)
    rows = []
    pre = {"dd": "\u25cc\u25cc", "d": "\u25cc", "ddd": "\u25cc\u25cc\u25cc", "ad": "a\u25cc", "kk": "\u1b05\u1b05",
           "kd": "\u1b05\u25cc", "dk": "\u25cc\u1b05", "ss": "\U00011f04\U00011f04", "pd": "\U00011f02\u25cc", "aa": "ab"}
    for pn, p in sorted(pre.items()):
        for x in flat:
            rows.append(("%s_%X" % (pn, x), p + chr(x)))
            rows.append(("%sb_%X" % (pn, x), p + chr(x) + "b"))
    for m in ["/", ".", ",", ";", "\u037e", ":"]:
        for x in flat:
            for po in ["", "%", "\ufe6a"]:
                rows.append(("n%s%s_%X" % (m.encode().hex(), po.encode().hex(), x), "0" + m + po + chr(x)))
    for y in ["%", "$", "\ufe6a", "\uffe0", "\u20a9"]:
        for x in flat:
            rows.append(("p%s_%X" % (y.encode().hex(), x), "0" + y + chr(x)))
            rows.append(("q%s_%X" % (y.encode().hex(), x), y + chr(x) + "0"))
    n6 = write(os.path.join(outdir, "icuprobe.cases"), rows)
    rows = []
    for i in range(max(200, fuzz_n // 20)):
        ln = rnd.choice([40, 60, 90, 140, 200])
        cps = [rnd.choice(hot) if rnd.random() < 0.85 else rnd.choice(flat) for _ in range(ln)]
        data = "".join(chr(c) for c in cps).encode("utf-8")
        if i % 4 == 3:
            pos = rnd.randrange(len(data) + 1)
            data = data[:pos] + bytes([rnd.choice([0x80, 0xBF, 0xE4, 0xEF, 0xF0, 0xFF])]) + data[pos:]
        rows.append(("G%d" % i, data))
    n7 = write(os.path.join(outdir, "long.cases"), rows)
    print(n1, n2, n3, n4, n5, len(R), n6, n7)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
