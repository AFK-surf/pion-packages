#!/usr/bin/env python3
"""Build the differential corpora for the packages/xml red-team audit.

usage: python3 -I gen_corpus.py OUT_DIR [ROXMLTREE_SRC_DIR] [W3C_XMLCONF_DIR]

Writes PACK files (format: repeated `@@CASE <name> <len>\\n<bytes>\\n`) consumed by
tools/pion_dump and tools/rust_ref:

  OUT_DIR/redteam.pack   hand-written + systematically generated adversarial cases
  OUT_DIR/roxmltree.pack roxmltree 0.21.2 tests/files/*.xml (upstream oracle corpus)
  OUT_DIR/w3c.pack       W3C XML Conformance Test Suite 20130923, XML 1.0 5th ed. + NS 1.0,
                         ENTITIES="none" only; OUT_DIR/w3c.expect lists `<name> <valid|not-wf>`
"""
import os
import re
import sys

OUT = sys.argv[1]
ROX = sys.argv[2] if len(sys.argv) > 2 else ""
W3C = sys.argv[3] if len(sys.argv) > 3 else ""
os.makedirs(OUT, exist_ok=True)

cases = []


def add(name, data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    assert " " not in name and "\n" not in name, name
    cases.append((name, data))


def dtd(body, internal):
    return "<!DOCTYPE a [" + internal + "]>" + body


# ---------------------------------------------------------------------------
# 1. Namespaces (XML Namespaces 1.0)
# ---------------------------------------------------------------------------
XMLNS = "http://www.w3.org/2000/xmlns/"
XMLNSURI = "http://www.w3.org/XML/1998/namespace"
ns = {
    "rebind_xml_wrong": '<a xmlns:xml="http://wrong"/>',
    "rebind_xml_ok": '<a xmlns:xml="%s"/>' % XMLNSURI,
    "declare_xmlns_prefix": '<a xmlns:xmlns="urn:x"/>',
    "declare_xmlns_prefix_to_xmlns_uri": '<a xmlns:xmlns="%s"/>' % XMLNS,
    "bind_prefix_to_xmlns_uri": '<a xmlns:p="%s"/>' % XMLNS,
    "bind_prefix_to_xml_uri": '<a xmlns:p="%s"/>' % XMLNSURI,
    "bind_default_to_xml_uri": '<a xmlns="%s"/>' % XMLNSURI,
    "bind_default_to_xmlns_uri": '<a xmlns="%s"/>' % XMLNS,
    "unbind_prefix_empty": '<a xmlns:p="urn:x"><b xmlns:p=""/></a>',
    "unbind_prefix_empty_root": '<a xmlns:p=""/>',
    "default_unbind": '<a xmlns="urn:x"><b xmlns=""><c/></b><d/></a>',
    "dup_expanded_attr": '<a xmlns:a="urn:x" xmlns:b="urn:x" a:k="1" b:k="2"/>',
    "dup_expanded_attr_nested": '<r xmlns:a="urn:x"><e xmlns:b="urn:x" a:k="1" b:k="2"/></r>',
    "dup_expanded_attr_ent_uri": dtd('<a xmlns:a="urn:x" xmlns:b="&u;" a:k="1" b:k="2"/>', '<!ENTITY u "urn:x">'),
    "dup_expanded_attr_charref_uri": '<a xmlns:a="urn:x" xmlns:b="urn:&#120;" a:k="1" b:k="2"/>',
    "dup_attr_xml_lang_twice": '<a xml:lang="en" xml:lang="fr"/>',
    "dup_attr_xml_prefix_explicit": '<a xmlns:xml="%s" xml:lang="en"/>' % XMLNSURI,
    "same_local_diff_ns_ok": '<a xmlns:a="urn:x" xmlns:b="urn:y" a:k="1" b:k="2" k="3"/>',
    "dup_xmlns_decl": '<a xmlns:p="urn:x" xmlns:p="urn:y"/>',
    "dup_default_xmlns": '<a xmlns="urn:x" xmlns="urn:y"/>',
    "unbound_elem_prefix": "<p:a/>",
    "unbound_attr_prefix": '<a p:k="1"/>',
    "attr_unprefixed_no_default_ns": '<a xmlns="urn:x" k="1"/>',
    "elem_prefix_xmlns": '<xmlns:a xmlns:xmlns="urn:x"/>',
    "elem_prefix_xmlns_undeclared": "<xmlns:a/>",
    "elem_prefix_xml": "<xml:a/>",
    "elem_xml_lang_attr": '<a xml:lang="en" xml:space="preserve"/>',
    "attr_named_xmlns_colon_empty_local": '<a xmlns:="urn:x"/>',
    "qname_double_colon": "<a:b:c xmlns:a='urn:x'/>",
    "qname_leading_colon": "<:a/>",
    "qname_trailing_colon": "<a: xmlns:a='urn:x'/>",
    "attr_qname_double_colon": "<a xmlns:p='urn:x' p:b:c='1'/>",
    "shadow_restore": '<a xmlns:p="urn:1"><p:b xmlns:p="urn:2"><p:c/></p:b><p:d/></a>',
    "shadow_restore_empty_elem": '<a xmlns:p="urn:1"><p:b xmlns:p="urn:2"/><p:d/></a>',
    "cache_after_sibling_decl": '<r xmlns:p="urn:1"><p:a/><x xmlns:p="urn:2"><p:a/></x><p:a/></r>',
    "cache_alternating": '<r xmlns:p="urn:1" xmlns:q="urn:2"><p:a/><q:a/><p:a/><q:a/></r>',
    "cache_same_prefix_text_between": '<r xmlns:p="urn:1"><p:a>t</p:a><y xmlns:p="urn:9"/><p:a/></r>',
    "cache_prefix_prefix_of_other": '<r xmlns:p="urn:1" xmlns:pp="urn:2"><pp:a/><p:a/><pp:a/></r>',
    "ns_uri_with_entities": '<a xmlns:p="urn:&lt;&amp;"><p:b/></a>',
    "ns_uri_ws_normalized": '<a xmlns:p="urn:x\ty"><p:b/></a>',
    "ns_uri_relative": '<a xmlns:p="rel"><p:b/></a>',
    "ns_end_tag_prefix_mismatch_same_uri": '<a xmlns:p="urn:x" xmlns:q="urn:x"><p:b></q:b></a>',
    "ns_end_tag_unprefixed_vs_prefixed": '<a xmlns="urn:x" xmlns:p="urn:x"><b></p:b></a>',
    "ns_deep_default_switch": '<a xmlns="urn:1"><b xmlns="urn:2"><c xmlns="urn:1"><d/></c></b></a>',
    "ns_attr_prefix_declared_after": '<a p:k="1" xmlns:p="urn:x"/>',
    "ns_elem_prefix_declared_on_self": '<p:a xmlns:p="urn:x"/>',
    "ns_xmlns_attr_with_entity_value_empty": dtd('<a xmlns:p="&e;"/>', '<!ENTITY e "">'),
    "ns_pi_target_colon": "<?a:b c?><r/>",
    "ns_entity_name_colon": dtd("<a>&b:c;</a>", '<!ENTITY b:c "x">'),
    "ns_doctype_name_colon": "<!DOCTYPE p:a []><p:a xmlns:p='urn:x'/>",
    "ns_xmlns_uppercase": '<a XMLNS:p="urn:x"><p:b/></a>',
    "ns_xml_prefix_upper": '<a XML:lang="en"/>',
    "ns_xmlfoo_prefix": '<a xmlns:xmlfoo="urn:x"><xmlfoo:b/></a>',
}
for k, v in ns.items():
    add("ns_" + k, v)

# 1k namespace declarations, queried at the deepest scope
decls = " ".join('xmlns:p%d="urn:%d"' % (i, i) for i in range(1000))
add("ns_1000_decls", "<r %s>%s</r>" % (decls, "".join("<p%d:e/>" % (i % 1000) for i in range(0, 1000, 7))))

# ---------------------------------------------------------------------------
# 2. Text / attribute normalisation
# ---------------------------------------------------------------------------
norm = {
    "text_cdata_end": "<a>x]]>y</a>",
    "text_cdata_end_split": "<a>x]]]>y</a>",
    "text_cdata_end_after_ref": "<a>&amp;]]></a>",
    "text_lone_brackets": "<a>]] ]>]</a>",
    "text_gt": "<a>></a>",
    "attr_lt": '<a k="<"/>',
    "attr_gt": '<a k=">"/>',
    "attr_charref_tab_lf_cr": '<a k="&#x9;&#xA;&#xD;"/>',
    "attr_literal_tab_lf_cr": '<a k="\t\n\r"/>',
    "attr_literal_crlf": '<a k="x\r\ny"/>',
    "attr_literal_cr_lf_cr": '<a k="\r\n\r"/>',
    "attr_mixed_ref_literal": '<a k="&#x20;\t&#9; "/>',
    "attr_amp_unterminated": '<a k="&amp"/>',
    "attr_amp_bare": '<a k="a & b"/>',
    "attr_single_quote_containing_dq": "<a k='\"'/>",
    "attr_no_space_between": '<a k="1"j="2"/>',
    "attr_no_value": "<a k/>",
    "attr_unquoted": "<a k=1/>",
    "attr_ws_around_eq": '<a k \t=\n "1"/>',
    "text_crlf": "<a>x\r\ny</a>",
    "text_cr": "<a>x\ry</a>",
    "text_cr_cr_lf": "<a>x\r\r\ny</a>",
    "text_charref_cr": "<a>x&#xD;y</a>",
    "text_charref_cr_lf": "<a>&#13;&#10;</a>",
    "cdata_crlf": "<a><![CDATA[x\r\ny\rz]]></a>",
    "comment_crlf": "<a><!--x\r\ny\rz--></a>",
    "pi_crlf": "<a><?t x\r\ny\rz?></a>",
    "attr_cr_end": '<a k="x\r"/>',
    "text_cr_before_tag": "<a>x\r<b/>\r\n</a>",
    "text_cr_before_cdata": "<a>x\r<![CDATA[\ny]]></a>",
    "cdata_text_merge": "<a>x<![CDATA[y]]>z</a>",
    "cdata_comment_between": "<a>x<!--c-->y</a>",
    "cdata_empty_merge": "<a><![CDATA[]]></a>",
    "cdata_empty_between_text": "<a>x<![CDATA[]]>y</a>",
    "pi_between_text": "<a>x<?p?>y</a>",
    "ws_only_text": "<a> \n\t </a>",
    "ws_between_elems": "<a> <b/> </a>",
    "pi_value_leading_ws": "<a><?t   v  ?></a>",
    "pi_value_only_ws": "<a><?t    ?></a>",
    "pi_no_value": "<a><?t?></a>",
    "pi_tab_after_target": "<a><?t\tv?></a>",
    "pi_question_inside": "<a><?t a?b??></a>",
    "comment_empty": "<a><!----></a>",
    "comment_single_dash_end": "<a><!-- x- --></a>",
    "comment_dash_before_end": "<a><!-- x---></a>",
    "comment_double_dash": "<a><!-- a -- b --></a>",
    "comment_open_dash": "<a><!---x--></a>",
    "comment_only_dash": "<a><!---></a>",
    "comment_three_dash_open_close": "<a><!-----></a>",
    "entity_amp_in_text_no_semicolon": "<a>&amp</a>",
    "entity_name_with_space": "<a>&a b;</a>",
    "entity_empty": "<a>&;</a>",
    "entity_unknown": "<a>&foo;</a>",
    "entity_predef_case": "<a>&LT;</a>",
}
for k, v in norm.items():
    add("norm_" + k, v)

# Every C0 control / DEL / C1 / non-character in every content position
ctrl_cps = list(range(0, 0x20)) + [0x7F, 0x80, 0x85, 0x9F, 0xD7FF, 0xE000, 0xFFFD, 0xFFFE, 0xFFFF, 0x10000, 0x10FFFF, 0x1FFFE]
for cp in ctrl_cps:
    ch = chr(cp)
    tag = "%04X" % cp
    add("char_text_" + tag, "<a>x" + ch + "y</a>")
    add("char_attr_" + tag, '<a k="x' + ch + 'y"/>')
    add("char_comment_" + tag, "<a><!--x" + ch + "y--></a>")
    add("char_pi_" + tag, "<a><?t x" + ch + "y?></a>")
    add("char_cdata_" + tag, "<a><![CDATA[x" + ch + "y]]></a>")
    add("char_ref_dec_" + tag, "<a>&#%d;</a>" % cp)
    add("char_ref_hex_" + tag, "<a>&#x%X;</a>" % cp)
    add("char_ref_attr_" + tag, '<a k="&#x%X;"/>' % cp)

# Surrogates written as (invalid) UTF-8 bytes; overlong forms; truncated sequences
bad_utf8 = {
    "surrogate_d800": b"\xed\xa0\x80",
    "surrogate_dfff": b"\xed\xbf\xbf",
    "overlong_slash": b"\xc0\xaf",
    "overlong_lt": b"\xc0\xbc",
    "overlong_3byte_lt": b"\xe0\x80\xbc",
    "overlong_4byte": b"\xf0\x80\x80\xbc",
    "too_big_f4_90": b"\xf4\x90\x80\x80",
    "f5_lead": b"\xf5\x80\x80\x80",
    "lone_cont": b"\x80",
    "ff": b"\xff",
    "truncated_2": b"\xc3",
    "truncated_3": b"\xe2\x82",
    "truncated_4": b"\xf0\x9f\x98",
}
for k, v in bad_utf8.items():
    add("utf8_text_" + k, b"<a>x" + v + b"y</a>")
    add("utf8_attr_" + k, b'<a k="x' + v + b'y"/>')
    add("utf8_name_" + k, b"<a" + v + b"/>")
    add("utf8_comment_" + k, b"<a><!--" + v + b"--></a>")
    add("utf8_eof_" + k, b"<a>" + v)

# Char refs: overflow / bounds / syntax
refs = {
    "dec_overflow_20": "&#99999999999999999999;",
    "dec_overflow_wrap_32_A": "&#%d;" % (2**32 + 65),
    "dec_overflow_wrap_64_A": "&#%d;" % (2**64 + 65),
    "hex_overflow_wrap_32_A": "&#x%X;" % (2**32 + 65),
    "hex_overflow_wrap_64_A": "&#x%X;" % (2**64 + 65),
    "hex_110000": "&#x110000;",
    "hex_10FFFF": "&#x10FFFF;",
    "hex_leading_zeros": "&#x0000000000000000000041;",
    "dec_leading_zeros": "&#0000000000000000000065;",
    "hex_upper_X": "&#X41;",
    "hex_empty": "&#x;",
    "dec_empty": "&#;",
    "hex_neg": "&#x-41;",
    "dec_plus": "&#+65;",
    "dec_space": "&# 65;",
    "hex_no_semicolon": "&#x41",
    "dec_hex_digit": "&#6A;",
    "hex_surrogate": "&#xD800;",
    "hex_fffe": "&#xFFFE;",
    "dec_zero": "&#0;",
    "dec_lt_in_text": "&#60;",
    "hex_amp_in_text": "&#x26;",
}
for k, v in refs.items():
    add("ref_text_" + k, "<a>" + v + "</a>")
    add("ref_attr_" + k, '<a k="' + v + '"/>')

# ---------------------------------------------------------------------------
# 3. Non-well-formed prolog / structure
# ---------------------------------------------------------------------------
wf = {
    "decl_leading_ws": ' <?xml version="1.0"?><a/>',
    "decl_leading_nl": '\n<?xml version="1.0"?><a/>',
    "decl_after_comment": '<!--c--><?xml version="1.0"?><a/>',
    "decl_after_bom": '﻿<?xml version="1.0"?><a/>',
    "decl_twice": '<?xml version="1.0"?><?xml version="1.0"?><a/>',
    "decl_in_body": '<a><?xml version="1.0"?></a>',
    "decl_version_11": '<?xml version="1.1"?><a/>',
    "decl_version_10_sq": "<?xml version='1.0'?><a/>",
    "decl_version_mixed_quotes": "<?xml version='1.0\"?><a/>",
    "decl_version_2": '<?xml version="2.0"?><a/>',
    "decl_version_1_x": '<?xml version="1.5"?><a/>',
    "decl_version_empty": '<?xml version=""?><a/>',
    "decl_no_version": '<?xml encoding="UTF-8"?><a/>',
    "decl_enc_utf16": '<?xml version="1.0" encoding="UTF-16"?><a/>',
    "decl_enc_latin1": '<?xml version="1.0" encoding="ISO-8859-1"?><a/>',
    "decl_enc_bogus": '<?xml version="1.0" encoding="bogus"?><a/>',
    "decl_enc_digit": '<?xml version="1.0" encoding="8bit"?><a/>',
    "decl_enc_empty": '<?xml version="1.0" encoding=""?><a/>',
    "decl_enc_space": '<?xml version="1.0" encoding="UTF 8"?><a/>',
    "decl_standalone_yes": '<?xml version="1.0" standalone="yes"?><a/>',
    "decl_standalone_YES": '<?xml version="1.0" standalone="YES"?><a/>',
    "decl_standalone_maybe": '<?xml version="1.0" standalone="maybe"?><a/>',
    "decl_standalone_before_enc": '<?xml version="1.0" standalone="yes" encoding="UTF-8"?><a/>',
    "decl_no_space_between": '<?xml version="1.0"encoding="UTF-8"?><a/>',
    "decl_trailing_ws": '<?xml version="1.0"   ?><a/>',
    "decl_unknown_attr": '<?xml version="1.0" foo="bar"?><a/>',
    "decl_upper_XML": '<?XML version="1.0"?><a/>',
    "decl_unterminated": '<?xml version="1.0"<a/>',
    "decl_only": '<?xml version="1.0"?>',
    "decl_question_space_gt": '<?xml version="1.0"? ><a/>',
    "pi_target_XML": "<?XML x?><a/>",
    "pi_target_xMl": "<?xMl x?><a/>",
    "pi_target_xml_body": "<a><?xml x?></a>",
    "pi_target_xml_prefix_ok": "<?xml-stylesheet href='x'?><a/>",
    "pi_target_xmlfoo": "<?xmlfoo?><a/>",
    "pi_target_colon": "<?a:b?><a/>",
    "pi_target_digit": "<?1a?><a/>",
    "pi_no_target": "<? x?><a/>",
    "pi_unterminated": "<a><?t x</a>",
    "multi_root": "<a/><b/>",
    "multi_root_text_between": "<a/> <b/>",
    "text_after_root": "<a/>x",
    "text_before_root": "x<a/>",
    "nbsp_before_root": " <a/>",
    "ws_before_root": " \t\r\n<a/>",
    "charref_outside_root": "<a/>&#32;",
    "entity_outside_root": "<a/>&amp;",
    "cdata_outside_root": "<![CDATA[x]]><a/>",
    "no_root": "<!--c-->",
    "empty": "",
    "only_ws": "  ",
    "only_bom": "﻿",
    "double_bom": "﻿﻿<a/>",
    "end_tag_ws": "<a></a  >",
    "end_tag_ws_before_name": "<a></ a>",
    "end_tag_mismatch_case": "<a></A>",
    "end_tag_attrs": '<a></a k="1">',
    "end_tag_slash_extra": "<a></a/>",
    "end_tag_eof": "<a></a",
    "start_tag_eof": "<a",
    "start_tag_eof_attr": '<a k="1"',
    "start_tag_eof_slash": "<a/",
    "start_tag_lt_in_name": "<a<b/>",
    "start_tag_space_before_name": "< a/>",
    "empty_tag_space_before_gt": "<a / >",
    "empty_tag_no_space": "<a/>",
    "unclosed_nested": "<a><b></a>",
    "unclosed_root": "<a>",
    "extra_end": "<a/></a>",
    "lt_in_text": "<a>1 < 2</a>",
    "amp_in_text": "<a>1 & 2</a>",
    "markup_decl_in_body": "<a><!ELEMENT x ANY></a>",
    "doctype_in_body": "<a><!DOCTYPE a></a>",
    "doctype_after_root": "<a/><!DOCTYPE a>",
    "cdata_lowercase": "<a><![cdata[x]]></a>",
    "cdata_unterminated": "<a><![CDATA[x</a>",
    "cdata_nested": "<a><![CDATA[<![CDATA[x]]>]]></a>",
    "name_digit_start": "<1a/>",
    "name_dash_start": "<-a/>",
    "name_dot_start": "<.a/>",
    "name_dot_mid": "<a.b-c_d/>",
    "attr_name_digit_start": '<a 1k="1"/>',
    "attr_dup": '<a k="1" k="2"/>',
    "attr_dup_quotes": "<a k=\"1\" k='2'/>",
    "tab_before_attr": '<a\tk="1"/>',
    "nl_before_attr": '<a\nk="1"/>',
    "cr_before_attr": '<a\rk="1"/>',
    "nbsp_before_attr": '<a k="1"/>',
    "comment_in_prolog_after_doctype": "<!DOCTYPE a><!--c--><a/>",
    "pi_in_epilog": "<a/><?p?>",
    "comment_in_epilog": "<a/><!--c-->",
    "nul_in_prolog": "\x00<a/>",
    "lt_bang_unknown": "<a><!x></a>",
}
for k, v in wf.items():
    add("wf_" + k, v)

# Unicode name characters (NameStartChar / NameChar boundaries, XML 1.0 5th ed. §2.3)
name_cps = [0xB7, 0xC0, 0xD6, 0xD7, 0xD8, 0xF6, 0xF7, 0xF8, 0x2FF, 0x300, 0x36F, 0x370, 0x37D, 0x37E,
            0x37F, 0x1FFF, 0x2000, 0x200B, 0x200C, 0x200D, 0x200E, 0x203F, 0x2040, 0x2041, 0x206F,
            0x2070, 0x218F, 0x2190, 0x2BFF, 0x2C00, 0x2FEF, 0x2FF0, 0x3000, 0x3001, 0xD7FF, 0xE000,
            0xF8FF, 0xF900, 0xFDCF, 0xFDD0, 0xFDEF, 0xFDF0, 0xFFFD, 0x10000, 0xEFFFF, 0xF0000, 0x10FFFF,
            0x0E33, 0x0F75, 0x4E00, 0x1F600]
for cp in name_cps:
    ch = chr(cp)
    tag = "%04X" % cp
    add("name_start_" + tag, "<" + ch + "a/>")
    add("name_char_" + tag, "<a" + ch + "/>")
    add("name_attr_start_" + tag, '<a ' + ch + 'k="1"/>')
    add("name_after_colon_" + tag, "<p:" + ch + " xmlns:p='urn:x'/>")
    add("name_pi_target_" + tag, "<?" + ch + "t?><a/>")

# ---------------------------------------------------------------------------
# 4. DTD & entities (run in *_dtd modes; also parsed in default mode where DTD must be rejected)
# ---------------------------------------------------------------------------
ent = {
    "nested_internal": dtd("<a>&c;</a>", '<!ENTITY a "x"><!ENTITY b "&a;&a;"><!ENTITY c "&b;&b;">'),
    "self_ref": dtd("<a>&e;</a>", '<!ENTITY e "&e;">'),
    "indirect_cycle": dtd("<a>&e1;</a>", '<!ENTITY e1 "&e2;"><!ENTITY e2 "&e1;">'),
    "unused_cycle": dtd("<a/>", '<!ENTITY e1 "&e2;"><!ENTITY e2 "&e1;">'),
    "markup_elem": dtd("<a>&e;</a>", '<!ENTITY e "<b>x</b>">'),
    "markup_elem_attr": dtd("<a>&e;</a>", "<!ENTITY e \"<b k='v'/>\">"),
    "markup_comment": dtd("<a>&e;</a>", '<!ENTITY e "<!--c-->">'),
    "markup_cdata": dtd("<a>&e;</a>", '<!ENTITY e "<![CDATA[x]]>">'),
    "markup_pi": dtd("<a>&e;</a>", '<!ENTITY e "<?p v?>">'),
    "markup_unbalanced_open": dtd("<a>&e;</a>", '<!ENTITY e "<b>">'),
    "markup_unbalanced_close": dtd("<a><b>&e;</a>", '<!ENTITY e "</b>">'),
    "markup_lt_alone": dtd("<a>&e;</a>", '<!ENTITY e "1 &#60; 2">'),
    "markup_lt_double_escaped": dtd("<a>&e;</a>", '<!ENTITY e "1 &#38;#60; 2">'),
    "charref_amp_lt": dtd("<a>&e;</a>", '<!ENTITY e "&#38;lt;">'),
    "charref_amp_amp": dtd("<a>&e;</a>", '<!ENTITY e "&#38;amp;">'),
    "charref_in_value": dtd("<a>&e;</a>", '<!ENTITY e "&#65;&#x42;">'),
    "attr_lt_entity": dtd('<a k="&e;"/>', '<!ENTITY e "a<b">'),
    "attr_lt_via_charref_entity": dtd('<a k="&e;"/>', '<!ENTITY e "&#60;">'),
    "attr_lt_via_double_charref": dtd('<a k="&e;"/>', '<!ENTITY e "&#38;#60;">'),
    "attr_entity_tab": dtd('<a k="&e;"/>', '<!ENTITY e "x\ty">'),
    "attr_entity_charref_tab": dtd('<a k="&e;"/>', '<!ENTITY e "x&#9;y">'),
    "attr_entity_quote": dtd('<a k="&e;"/>', "<!ENTITY e '\"'>"),
    "text_entity_cr": dtd("<a>&e;</a>", '<!ENTITY e "x&#13;y">'),
    "text_entity_literal_crlf": dtd("<a>&e;</a>", '<!ENTITY e "x\r\ny">'),
    "ent_value_ctrl_char": dtd("<a>&e;</a>", '<!ENTITY e "\x01">'),
    "ent_value_unused_ctrl_char": dtd("<a/>", '<!ENTITY e "\x01">'),
    "ent_value_pe_ref": dtd("<a>&e;</a>", '<!ENTITY e "%x;">'),
    "ent_value_bare_amp": dtd("<a/>", '<!ENTITY e "a & b">'),
    "ent_value_bare_amp_used": dtd("<a>&e;</a>", '<!ENTITY e "a & b">'),
    "ent_value_cdata_end": dtd("<a>&e;</a>", '<!ENTITY e "]]>">'),
    "ent_no_ws_before_value": dtd("<a>&e;</a>", '<!ENTITY e"x">'),
    "ent_no_ws_before_name": dtd("<a>&e;</a>", '<!ENTITYe "x">'),
    "ent_redefine_first_wins": dtd("<a>&e;</a>", '<!ENTITY e "1"><!ENTITY e "2">'),
    "ent_redefine_lt": dtd("<a>&lt;</a>", '<!ENTITY lt "&#38;#60;">'),
    "ent_redefine_lt_bad": dtd("<a>&lt;</a>", '<!ENTITY lt "x">'),
    "ent_undefined_with_dtd": dtd("<a>&nope;</a>", '<!ENTITY e "x">'),
    "ent_external_system": dtd("<a>&e;</a>", '<!ENTITY e SYSTEM "file:///etc/passwd">'),
    "ent_external_public": dtd("<a>&e;</a>", '<!ENTITY e PUBLIC "-//X" "http://x">'),
    "ent_external_unused": dtd("<a/>", '<!ENTITY e SYSTEM "file:///etc/passwd">'),
    "ent_unparsed_ndata": dtd("<a/>", '<!ENTITY e SYSTEM "x" NDATA gif>'),
    "ent_parameter": dtd("<a/>", '<!ENTITY % p "x">'),
    "ent_parameter_ref": dtd("<a/>", '<!ENTITY % p "<!ENTITY e \'x\'>">%p;'),
    "doctype_system": '<!DOCTYPE a SYSTEM "http://example.com/x.dtd"><a/>',
    "doctype_public": '<!DOCTYPE a PUBLIC "-//X//EN" "http://example.com/x.dtd"><a/>',
    "doctype_public_bad_pubid": '<!DOCTYPE a PUBLIC "{bad}" "x.dtd"><a/>',
    "doctype_empty_subset": "<!DOCTYPE a []><a/>",
    "doctype_no_subset": "<!DOCTYPE a><a/>",
    "doctype_twice": "<!DOCTYPE a><!DOCTYPE a><a/>",
    "doctype_no_ws": "<!DOCTYPEa><a/>",
    "doctype_bracket_in_comment": dtd("<a/>", "<!-- ] -->"),
    "doctype_bracket_in_quotes": dtd("<a/>", '<!ATTLIST a k CDATA "]>">'),
    "doctype_gt_in_entity_value": dtd("<a>&e;</a>", '<!ENTITY e "]>">'),
    "doctype_attlist_default": dtd("<a/>", '<!ATTLIST a k CDATA "dflt">'),
    "doctype_attlist_fixed": dtd("<a/>", '<!ATTLIST a k CDATA #FIXED "f">'),
    "doctype_element_decl": dtd("<a/>", "<!ELEMENT a (#PCDATA)>"),
    "doctype_notation": dtd("<a/>", '<!NOTATION n SYSTEM "x">'),
    "doctype_pi": dtd("<a/>", "<?p x?>"),
    "doctype_garbage": dtd("<a/>", "garbage"),
    "doctype_unterminated": "<!DOCTYPE a [<!ENTITY e 'x'>",
    "doctype_bad_markup_name": dtd("<a/>", "<!FOO x>"),
    "doctype_element_unterminated_quote": dtd("<a/>", "<!ELEMENT a 'x>"),
    "ent_in_attr_nested": dtd('<a k="&b;"/>', '<!ENTITY a "1"><!ENTITY b "&a;&a;">'),
    "ent_in_attr_cycle": dtd('<a k="&e;"/>', '<!ENTITY e "&e;">'),
    "ent_xmlns_value": dtd('<a xmlns:p="&u;"><p:b/></a>', '<!ENTITY u "urn:x">'),
    "ent_text_with_elem_and_ns": dtd('<a xmlns:p="urn:x">&e;</a>', '<!ENTITY e "<p:b/>">'),
    "ent_lots_of_refs": dtd("<a>" + "&e;" * 300 + "</a>", '<!ENTITY e "x">'),
    "ent_charref_refs": dtd("<a>" + "&#65;" * 300 + "</a>", '<!ENTITY e "x">'),
}
lol = '<!ENTITY lol "lol">' + "".join(
    '<!ENTITY lol%d "%s">' % (i, ("&lol%s;" % ("" if i == 1 else i - 1)) * 10) for i in range(1, 10))
ent["billion_laughs"] = dtd("<a>&lol9;</a>", lol)
ent["billion_laughs_attr"] = dtd('<a k="&lol9;"/>', lol)
ent["quadratic_blowup"] = dtd("<a>" + "&big;" * 200 + "</a>", '<!ENTITY big "' + "x" * 100000 + '">')
for k, v in ent.items():
    add("dtd_" + k, v)

# ---------------------------------------------------------------------------
# 5. Assorted structure / roundtrip shapes
# ---------------------------------------------------------------------------
misc = {
    "deep_200": "<a>" * 200 + "x" + "</a>" * 200,
    "siblings_1000": "<r>" + "<e/>" * 1000 + "</r>",
    "attrs_200": "<a " + " ".join('k%d="%d"' % (i, i) for i in range(200)) + "/>",
    "mixed": '<r xmlns="urn:d" xmlns:x="urn:x"><x:a x:k="1" k="2">t<![CDATA[c]]><!--m--><?p v?>u</x:a><b/></r>',
    "svg": '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><use xlink:href="#a"/></svg>',
    "big_text": "<a>" + "x" * 100000 + "</a>",
    "unicode_text": "<a>中文 \U0001F600 é</a>",
}
for k, v in misc.items():
    add("misc_" + k, v)


def write_pack(path, items):
    with open(path, "wb") as f:
        for name, data in items:
            f.write(b"@@CASE %s %d\n" % (name.encode(), len(data)))
            f.write(data)
            f.write(b"\n")


write_pack(os.path.join(OUT, "redteam.pack"), cases)
print("redteam.pack: %d cases" % len(cases))

# ---------------------------------------------------------------------------
# roxmltree upstream test files
# ---------------------------------------------------------------------------
if ROX:
    d = os.path.join(ROX, "tests", "files")
    items = []
    for fn in sorted(os.listdir(d)):
        if fn.endswith(".xml"):
            with open(os.path.join(d, fn), "rb") as f:
                items.append(("rox_" + fn[:-4], f.read()))
    write_pack(os.path.join(OUT, "roxmltree.pack"), items)
    print("roxmltree.pack: %d cases" % len(items))

# ---------------------------------------------------------------------------
# W3C XML Conformance Test Suite (xmlts20130923)
# ---------------------------------------------------------------------------
if W3C:
    root = W3C
    top = open(os.path.join(root, "xmlconf.xml"), encoding="utf-8", errors="replace").read()
    catalogs = re.findall(r'<!ENTITY\s+(\S+)\s+SYSTEM\s+"([^"]+)"', top)
    items = []
    expect = []
    skipped = {}
    for ent_name, rel in catalogs:
        if "1.1" in rel or "xml11" in ent_name:
            skipped["xml-1.1"] = skipped.get("xml-1.1", 0) + 1
            continue
        cat_path = os.path.join(root, rel)
        base = os.path.dirname(cat_path)
        text = open(cat_path, encoding="utf-8", errors="replace").read()
        for m in re.finditer(r"<TEST\b([^>]*)>", text, re.S):
            attrs = {k: v1 or v2 for k, v1, v2 in re.findall(r"""(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)')""", m.group(1))}
            typ = attrs.get("TYPE")
            if typ not in ("valid", "invalid", "not-wf"):
                skipped[typ] = skipped.get(typ, 0) + 1
                continue
            if attrs.get("ENTITIES", "none") != "none":
                skipped["entities"] = skipped.get("entities", 0) + 1
                continue
            if attrs.get("NAMESPACE", "yes") == "no":
                skipped["namespace=no"] = skipped.get("namespace=no", 0) + 1
                continue
            if attrs.get("VERSION", "1.0") not in ("1.0",) or "1.1" in attrs.get("RECOMMENDATION", ""):
                skipped["version"] = skipped.get("version", 0) + 1
                continue
            ed = attrs.get("EDITION")
            if ed and "5" not in ed.split():
                skipped["edition"] = skipped.get("edition", 0) + 1
                continue
            path = os.path.join(base, attrs["URI"])
            try:
                data = open(path, "rb").read()
            except OSError:
                continue
            # Only UTF-8 documents (no UTF-16 BOM / non-UTF-8 encoding declarations):
            # neither implementation decodes other encodings.
            if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
                skipped["utf16"] = skipped.get("utf16", 0) + 1
                continue
            mdecl = re.match(rb'(\xef\xbb\xbf)?<\?xml[^>]*encoding\s*=\s*["\']([^"\']+)', data)
            if mdecl and mdecl.group(2).lower() not in (b"utf-8", b"utf8", b"us-ascii", b"ascii"):
                skipped["encoding"] = skipped.get("encoding", 0) + 1
                continue
            name = "w3c_" + re.sub(r"[^A-Za-z0-9_.-]", "_", attrs.get("ID", attrs["URI"]))
            items.append((name, data))
            expect.append("%s %s %s" % (name, "not-wf" if typ == "not-wf" else "wf", attrs.get("SECTIONS", "").replace(" ", "")))
    write_pack(os.path.join(OUT, "w3c.pack"), items)
    with open(os.path.join(OUT, "w3c.expect"), "w") as f:
        f.write("\n".join(expect) + "\n")
    print("w3c.pack: %d cases (skipped: %s)" % (len(items), ", ".join("%s=%d" % kv for kv in sorted(skipped.items(), key=lambda kv: str(kv[0])))))
