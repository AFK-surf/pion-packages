#!/usr/bin/env python3
"""Generate ../tests/redteam_test.pion.  Every `expect=None` case takes its expected HTML from the
real Rust pulldown-cmark 0.13.1 oracle (rust_ref) at generation time, so the asserted bytes are
exactly what upstream produces; spec-derived cases carry the expected HTML inline.

usage: gen_tests.py <rust_ref_bin> <out.pion>
"""
import subprocess, sys, tempfile, os

RUST, OUT = sys.argv[1:3]
CM, GFM, SMART = 0, 7, 23
AUTO = 15  # GFM + autolinks (pion-only option)
FULL_RUST = 1 | 2 | 4 | 64 | 128 | 1024 | 2048 | 4096 | 8192 | 16384 | 32768 | 256 | 512

# (test name, level, render api, pion mask, rust mask, markdown, expected-or-None, comment)
# api: "pulldown" -> to_html_pulldown, "cm" -> to_html, "paths" -> 3-way equality, "events" -> render_html_pulldown(parse())
C = []


def case(name, level, api, mask, src, expect=None, why="", rmask=None):
    C.append((name, level, api, mask, mask if rmask is None else rmask, src, expect, why))


# ---------------- P0: two render paths disagree / spec-breaking structure
case("p0_paths_loose_tasklist_direct_vs_parse", "P0", "paths", GFM, "- [ ] a\n\n- [x] b\n",
     why="to_html_pulldown drops the newline after <li> that render_html_pulldown(parse()) and Rust emit")
case("p0_paths_loose_tasklist_direct_vs_rust", "P0", "pulldown", GFM, "* [ ] foo\n\n* [ ] bar\n\nbaz\n",
     why="pulldown-cmark regression #70")
case("p0_paths_loose_tasklist_cm_direct_vs_parse", "P0", "cm_paths", GFM, "- [ ] a\n\n- [x] b\n",
     why="to_html vs render_html(parse()) disagree the same way")
case("p0_list_indented_code_then_para_is_loose", "P0", "cm", CM, "-     test\n\n  test2\n",
     "<ul>\n<li>\n<pre><code>test\n</code></pre>\n<p>test2</p>\n</li>\n</ul>\n",
     why="CommonMark: blank line between two children makes the list loose (cmark/commonmark.js agree); pion renders tight")
case("p0_list_indented_code_then_item_is_loose", "P0", "cm", CM, "-     test\n\n- test2\n",
     "<ul>\n<li>\n<pre><code>test\n</code></pre>\n</li>\n<li>\n<p>test2</p>\n</li>\n</ul>\n",
     why="blank line between items -> loose list")
case("p0_list_indented_code_then_para_pulldown", "P0", "pulldown", CM, "-     test\n\n  test2\n", why="pulldown-cmark regression #183")

# ---------------- P1: GFM strikethrough flanking (spec-breaking)
case("p1_strike_opener_followed_by_space", "P1", "pulldown", GFM, "~~ ~~\n",
     why="`~~` followed by whitespace is not left-flanking (GFM/emphasis rules) -> must stay literal")
case("p1_strike_not_flanking_both_sides", "P1", "pulldown", GFM, "a~~ b ~~c\n")
case("p1_strike_newline_content", "P1", "pulldown", GFM, "~~\n~~\n")
case("p1_strike_closer_punct_then_alnum", "P1", "pulldown", GFM, "~~$~~b\n",
     why="closer preceded by punctuation and followed by alnum is not right-flanking")
case("p1_strike_closer_quote_then_alnum", "P1", "pulldown", GFM, "~~'~~x\n")
case("p1_strike_mixed_lengths", "P1", "pulldown", GFM, "~~a~ b~ ~a~~\n")
case("p1_strike_intraword_single", "P1", "pulldown", GFM, "This~is~nothing\n", why="pulldown-cmark strikethrough test 8")
case("p1_strike_intraword_single_wrap", "P1", "pulldown", GFM, "~This~is~nothing~\n", why="pulldown-cmark strikethrough test 9")

# ---------------- P1: smart punctuation
case("p1_smart_quote_left_straight_inside_emphasis", "P1", "pulldown", SMART, "*- '*\n",
     why="smart punctuation enabled but a straight ' leaks through unconverted")
case("p1_smart_quote_left_straight_underscore", "P1", "pulldown", SMART, "_> '_\n")
case("p1_smart_quote_left_straight_cjk", "P1", "pulldown", SMART, "*'é*\n")
case("p1_smart_link_title_spec508", "P1", "pulldown", SMART, "[link](/url \"title \"and\" title\")\n")
case("p1_smart_html_attr_spec632", "P1", "pulldown", SMART, "<a href=\"\\\"\">\n")
case("p1_smart_bracket_quote_regression147", "P1", "pulldown", SMART, "[foo]: https://example.com\n'[foo]'bar\n")
case("p1_smart_triple_quote_regression179", "P1", "pulldown", SMART, "[link]: test \"\"\"\n\n[link]\n")

# ---------------- P1: tables
case("p1_table_terminated_by_list_item", "P1", "pulldown", GFM, "moo | moo\n----|----\nmoo | moo\n*\n",
     why="a list item starts a new block (GFM: table ends at another block-level structure); pion swallows `*` as a cell")
case("p1_table_terminated_by_ordered_item", "P1", "pulldown", GFM, "moo | moo\n----|----\nmoo | moo\n2.\n")
case("p1_table_lone_pipe_row", "P1", "pulldown", GFM, "| Table | Header |\n|-------|--------|\n|\n")
case("p1_table_lone_pipe_then_rows", "P1", "pulldown", GFM,
     "| Table | Header |\n|-------|--------|\n| Table | Body   |\n|\n| Not   | Enough |\n")
case("p1_table_not_interrupting_paragraph", "P1", "pulldown", GFM, "lorem ipsum\nA | B\n---|---\nfoo | bar\n",
     why="pulldown-cmark regression #23")
case("p1_table_empty_header", "P1", "pulldown", GFM, "|\n|-\n")
case("p1_table_double_backslash_pipe", "P1", "pulldown", GFM, "| Double | `\\\\|` |\n|--|--|\n| Double | `\\\\|` |\n",
     why="pulldown-cmark table test 18")
case("p1_table_double_backslash_pipe_link", "P1", "pulldown", GFM, "| Double | [test](first\\\\|second) |\n|--|--|\n")
case("p1_table_trailing_escaped_backslash", "P1", "pulldown", GFM, "|a\\|\n|-|\n|b\\\\|\n")
case("p1_table_image_alt_pipe", "P1", "pulldown", GFM, "| ![Moo\\\\|Moo](image.png) |\n|-------------|\n| ![Moo\\\\\\|Moo](image.png) |\n")
case("p1_table_indented_header_cell", "P1", "pulldown", GFM, "table c\n a  |  b\n--- | ---\n c  |  d\n")

# ---------------- P1: task lists
case("p1_tasklist_marker_only", "P1", "pulldown", GFM, "- [x]\n")
case("p1_tasklist_marker_then_continuation", "P1", "pulldown", GFM, "- [x]\n  b\n")
case("p1_tasklist_marker_then_nested_list", "P1", "pulldown", GFM, "- [x]\n  * some text\n- [ ]\n  > some text\n",
     why="pulldown-cmark regression #210")
case("p1_tasklist_trailing_tabs", "P1", "pulldown", GFM, "- [x]\t\t\n\\\n-\n", why="pulldown-cmark regression #198")

# ---------------- P1: pulldown HTML formatting ("byte-for-byte push_html" claim)
case("p1_pulldown_fmt_li_html_block", "P1", "pulldown", CM, "- <div>\n- foo\n")
case("p1_pulldown_fmt_li_html_block_tab", "P1", "pulldown", CM, "* <foo>\n\t<bar>\n")
case("p1_pulldown_fmt_li_empty_first_line_html", "P1", "pulldown", CM, "*\n\t<div>\n\t<div>\n")
case("p1_pulldown_fmt_li_table", "P1", "pulldown", GFM, "- |a|b|\n  |-|-|\n  |1|2|\n")
case("p1_softbreak_trailing_tab_kept", "P1", "pulldown", CM, "b\t\nc\n",
     why="trailing tab before a soft break leaks into the HTML")
case("p1_softbreak_trailing_tab_blockquote", "P1", "pulldown", CM, "> [!CAUTION]\t\n> Line 1.\n")

# ---------------- P1: GFM autolink literals (pion-only option, GFM 0.29 spec expectations)
case("p1_gfm_autolink_entity_suffix_excluded", "P1", "pulldown_auto", AUTO, "www.google.com/search?q=commonmark&hl;\n",
     "<p><a href=\"http://www.google.com/search?q=commonmark\">www.google.com/search?q=commonmark</a>&amp;hl;</p>\n",
     why="GFM spec: trailing entity reference is excluded from the autolink")
case("p1_gfm_autolink_ftp", "P1", "pulldown_auto", AUTO, "Anonymous FTP is available at ftp://foo.bar.baz.\n",
     "<p>Anonymous FTP is available at <a href=\"ftp://foo.bar.baz\">ftp://foo.bar.baz</a>.</p>\n",
     why="GFM spec extended url autolink accepts ftp://")
case("p1_gfm_autolink_email_trailing_underscore", "P1", "pulldown_auto", AUTO, "a.b-c_d@a.b_\n",
     "<p>a.b-c_d@a.b_</p>\n", why="GFM spec: only `.` may end an email address; `_`/`-` at the end -> no autolink")
case("ok_gfm_autolink_email_trailing_dash", "OK", "pulldown_auto", AUTO, "a.b-c_d@a.b-\n", "<p>a.b-c_d@a.b-</p>\n")
case("p1_gfm_autolink_mailto_protocol", "P1", "pulldown_auto", AUTO, "mailto:foo@bar.baz\n",
     "<p><a href=\"mailto:foo@bar.baz\">mailto:foo@bar.baz</a></p>\n", why="GFM 0.29 extended protocol autolink")
case("p1_gfm_autolink_xmpp_protocol", "P1", "pulldown_auto", AUTO, "xmpp:foo@bar.baz\n",
     "<p><a href=\"xmpp:foo@bar.baz\">xmpp:foo@bar.baz</a></p>\n")

# ---------------- P1: capability gaps (pulldown-cmark 0.13.1 features with no pion option)
case("gap_footnotes", "P1", "pulldown", GFM, "Lorem ipsum.[^a]\n\n[^a]: Cool.\n", rmask=GFM | 64,
     why="ENABLE_FOOTNOTES: pion silently turns the footnote into a link to href=\"Cool.\"")
case("gap_footnote_image_bang", "P1", "pulldown", GFM, "![^1]\n\n[^1]: foo\n", rmask=GFM | 64)
case("gap_heading_attributes", "P1", "pulldown", GFM, "# Heading {#id .class key=val}\n", rmask=GFM | 128)
case("gap_math_inline_display", "P1", "pulldown", GFM, "$a*b*c$ and $$x_1_2$$\n", rmask=GFM | 1024,
     why="ENABLE_MATH: pion parses emphasis inside math")
case("gap_yaml_metadata_block", "P1", "pulldown", GFM, "---\ntitle: x\nlist:\n    - a\n---\nThings\n", rmask=GFM | 256,
     why="ENABLE_YAML_STYLE_METADATA_BLOCKS: front matter rendered as <hr>+<h2>")
case("gap_pluses_metadata_block", "P1", "pulldown", GFM, "+++\ntitle = 'x'\n+++\nThings\n", rmask=GFM | 512)
case("gap_definition_list", "P1", "pulldown", GFM, "term\n: definition\n", rmask=GFM | 4096)
case("gap_wikilinks", "P1", "pulldown", GFM, "[[Main Page|the page]]\n", rmask=GFM | 32768)
case("gap_superscript_subscript", "P1", "pulldown", CM, "^sup^ and ~sub~\n", rmask=8192 | 16384)
case("gap_gfm_alert_blockquote", "P1", "pulldown", GFM, "> [!NOTE]\n> Useful.\n", rmask=GFM | 2048)

# ---------------- P2: parity divergences where pion matches cmark / the spec (documented for honesty)
case("p2_parity_eof_no_newline_code", "P2", "pulldown", CM, "\tcode", why="pion==cmark (adds \\n); pulldown omits it")
case("p2_parity_eof_no_newline_fence", "P2", "pulldown", CM, "```\nabc")
case("p2_parity_eof_no_newline_html", "P2", "pulldown", CM, "<div>")
case("p2_parity_title_apostrophe_escape", "P2", "pulldown", CM, "[link]: test '\\''\n\n[link]\n",
     why="pulldown escapes ' as &#39; in attributes")
case("p2_parity_href_apostrophe_escape", "P2", "pulldown", CM, "[](')\n")
case("p2_parity_info_apostrophe_escape", "P2", "pulldown", CM, "```'\n```\n")
case("p2_parity_href_caret", "P2", "pulldown", CM, "<tp:^>\n")
case("p2_parity_image_alt_softbreak", "P2", "pulldown", CM, "![a\nb](c)\n")
case("p2_parity_crlf_inline_html", "P2", "pulldown", CM, "<a\r\nhref='x'>y</a>\r\n")
case("p2_parity_crlf_code_span", "P2", "pulldown", CM, "`a\r\nb`\r\n")
case("p2_parity_heading_trailing_tab", "P2", "pulldown", CM, "## tabs\t\t\n")
case("p2_parity_fence_info_tab", "P2", "pulldown", CM, "~~~b\t;\n~~~\n")
case("p2_parity_smart_unmatched_double_quote", "P2", "pulldown", SMART, "a\"\n",
     why="pion (like commonmark.js) closes; pulldown opens an unmatched double quote")
case("p2_parity_lazy_empty_item", "P2", "pulldown", CM, ">x\n+\n", why="pion==cmark (empty item cannot interrupt a paragraph)")
case("p2_parity_label_1000_chars", "P2", "pulldown", CM, "[" + "x" * 1000 + "]: /u\n\n[" + "x" * 1000 + "]\n",
     why="CommonMark caps labels at 999 chars; pion is right, pulldown links it")
case("p2_gfm_tagfilter_missing", "P2", "pulldown_auto", AUTO, "<title> <style> <xmp>\n",
     "<p>&lt;title> &lt;style> &lt;xmp></p>\n", why="GFM disallowed raw HTML (tagfilter): neither pion nor pulldown implement it")

# ---------------- regressions that currently PASS (guard rails; keep them green)
case("ok_nul_replacement_direct", "OK", "pulldown", CM, "a\x00b *x*\n", "<p>a\ufffdb <em>x</em></p>\n",
     why="CommonMark 2.3: U+0000 must become U+FFFD. pion is right here; pulldown-cmark 0.13.1 emits a raw NUL")
case("ok_nul_replacement_events", "OK", "events", CM, "a\x00b *x*\n", "<p>a\ufffdb <em>x</em></p>\n")
case("ok_crlf_paragraph", "OK", "pulldown", GFM, "a\r\nb\r\n\r\n|a|b|\r\n|-|-|\r\n|1|2|\r\n")
case("ok_tabs_list_code", "OK", "pulldown", CM, "-\tfoo\n\n\tbar\n")
case("ok_cjk_strong", "OK", "pulldown", CM, "中文**强调**中文\n")
case("ok_xss_attr_quote", "OK", "pulldown", CM, "[a](/u \"x\\\" onmouseover=\\\"y\")\n")
case("ok_xss_img_alt", "OK", "pulldown", CM, "![\"><script>](/u)\n")


def oracle(src, mask):
    with tempfile.NamedTemporaryFile("wb", delete=False) as f:
        f.write(src.encode())
    try:
        return subprocess.run([RUST, "html", f.name, str(mask)], capture_output=True, check=True).stdout.decode()
    finally:
        os.unlink(f.name)


def lit(s):
    out = []
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif o < 0x20 or o == 0x7F:
            out.append("\\u{%X}" % o)
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def opts(mask):
    b = lambda bit: "true" if mask & bit else "false"
    return (f"markdown::Options::{{ tables: {b(1)}, strikethrough: {b(2)}, tasklists: {b(4)}, "
            f"autolinks: {b(8)}, smart_punctuation: {b(16)}, cjk_friendly: {b(32)} }}")


hdr = """///| RED-TEAM evidence for `packages/markdown` (d082835) vs Rust pulldown-cmark 0.13.1.
///| GENERATED by audit/scripts/gen_tests.py -- do not edit by hand.
///| Expected bytes come from the real pulldown-cmark 0.13.1 oracle (audit/rust_ref) unless the
///| case is a GFM-spec example.  A FAILING test is evidence.  Prefixes: p0_/p1_/gap_/p2_ = severity
///| (p2_ = pion matches cmark/the spec but not pulldown), ok_ = guard rails that currently pass.
///| Run: pionc test -p markdown_redteam packages/markdown/audit

import "markdown"
"""
parts = [hdr]
for name, level, api, mask, rmask, src, expect, why in C:
    exp = expect if expect is not None else oracle(src, rmask)
    o = opts(mask)
    body = [f"\n///| [{level}] {why}" if why else f"\n///| [{level}]", f'test "{name}" {{', f"  let src = {lit(src)}",
            f"  let expected = {lit(exp)}"]
    if api in ("pulldown", "pulldown_auto"):
        body.append(f"  let got = markdown::to_html_pulldown(src, {o})")
        body.append(f'  debug_assert(got == expected, "{name}: to_html_pulldown=" + got)')
    elif api == "events":
        body.append(f"  let got = markdown::render_html_pulldown(markdown::parse(src, {o}))")
        body.append(f'  debug_assert(got == expected, "{name}: render_html_pulldown(parse)=" + got)')
    elif api == "cm":
        body.append(f"  let got = markdown::to_html(src, {o})")
        body.append(f'  debug_assert(got == expected, "{name}: to_html=" + got)')
        body.append(f"  let ev = markdown::render_html(markdown::parse(src, {o}))")
        body.append(f'  debug_assert(ev == expected, "{name}: render_html(parse)=" + ev)')
    elif api == "paths":
        body.append(f"  let direct = markdown::to_html_pulldown(src, {o})")
        body.append(f"  let events = markdown::render_html_pulldown(markdown::parse(src, {o}))")
        body.append(f'  debug_assert(events == expected, "{name}: events path=" + events)')
        body.append(f'  debug_assert(direct == events, "{name}: direct path diverges from parse() path: " + direct)')
    elif api == "cm_paths":
        body.append(f"  let direct = markdown::to_html(src, {o})")
        body.append(f"  let events = markdown::render_html(markdown::parse(src, {o}))")
        body.append(f"  let _ = expected")
        body.append(f'  debug_assert(direct == events, "{name}: to_html=" + direct + " render_html(parse)=" + events)')
    body.append("}")
    parts.append("\n".join(body) + "\n")
open(OUT, "w", encoding="utf-8").write("".join(parts))
print(f"wrote {len(C)} tests -> {OUT}")
