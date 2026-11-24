#!/usr/bin/env python3
"""Deterministic audit corpus for packages/hls: named edge cases + valid seeds + seeded mutations.

usage: gen.py <out_dir> <fuzz_n>
writes <out_dir>/named.cases, <out_dir>/fuzz.cases (lines `<name>\\t<hex>`) and prints the counts.
"""

import os
import random
import re
import sys

H = "#EXTM3U\n"
MH = H + "#EXT-X-TARGETDURATION:10\n"
SEG = "#EXTINF:4,\na.ts\n"
SI = "#EXT-X-STREAM-INF:BANDWIDTH=1000000\nv.m3u8\n"
KF_FP = "com.apple.streamingkeydelivery"
KF_WV = "urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"
BIG = "9223372036854"


def named():
    c = {}
    # ---- 1. lexical / line structure
    c["lex_minimal_media"] = MH + SEG
    c["lex_minimal_master"] = H + SI
    c["lex_crlf"] = MH.replace("\n", "\r\n") + SEG.replace("\n", "\r\n")
    c["lex_bare_cr_mid"] = MH + "#EXTINF:4,\ra.ts\n"
    c["lex_cr_at_eof"] = MH + "#EXTINF:4,\na.ts\r"
    c["lex_nul"] = MH + "#EXTINF:4,\na\x00.ts\n"
    c["lex_bom"] = "﻿" + MH + SEG
    c["lex_double_bom"] = "﻿﻿" + MH + SEG
    c["lex_no_header"] = "#EXT-X-TARGETDURATION:10\n" + SEG
    c["lex_header_space"] = "#EXTM3U \n#EXT-X-TARGETDURATION:10\n" + SEG
    c["lex_blank_first"] = "\n" + MH + SEG
    c["lex_empty"] = ""
    c["lex_only_header"] = H
    c["lex_comments"] = MH + "# comment\n#EXTX nope\n\n" + SEG
    c["lex_tab_in_title"] = MH + "#EXTINF:4,a\tb\na.ts\n"
    c["lex_esc_in_title"] = MH + "#EXTINF:4,a\x1b[31mred\na.ts\n"
    c["lex_del_in_uri"] = MH + "#EXTINF:4,\na\x7f.ts\n"
    c["lex_c1_in_title"] = MH + "#EXTINF:4,a\u0085b\na.ts\n"
    c["lex_utf8_title"] = MH + "#EXTINF:4,Grüße 日本\na.ts\n"
    c["lex_invalid_utf8"] = (MH + "#EXTINF:4,\na").encode() + b"\xff\xfe.ts\n"
    c["lex_no_final_lf"] = MH + "#EXTINF:4,\na.ts"
    c["lex_lowercase_tag"] = MH + "#extinf:4,\na.ts\n"
    # ---- 2. attribute lists (§4.2)
    for k, v in {
        "dup_attr": 'BANDWIDTH=1,BANDWIDTH=2',
        "unclosed_quote": 'BANDWIDTH=1,CODECS="avc1',
        "quote_in_unquoted": 'BANDWIDTH=1"2',
        "trailing_comma": 'BANDWIDTH=1,',
        "leading_comma": ',BANDWIDTH=1',
        "empty_value": 'BANDWIDTH=',
        "space_after_comma": 'BANDWIDTH=1, CODECS="a"',
        "lowercase_name": 'bandwidth=1',
        "bad_name_char": 'BAND_WIDTH=1,BANDWIDTH=1',
        "no_equals": 'BANDWIDTH',
        "comma_in_quotes": 'BANDWIDTH=1,CODECS="avc1.4d401e,mp4a.40.2"',
        "junk_after_quote": 'BANDWIDTH=1,CODECS="a"b',
        "empty_quoted": 'BANDWIDTH=1,CODECS=""',
        "bw_zero": 'BANDWIDTH=0',
        "bw_negative": 'BANDWIDTH=-1',
        "bw_i64max": 'BANDWIDTH=9223372036854775807',
        "bw_i64max_plus1": 'BANDWIDTH=9223372036854775808',
        "bw_u64max": 'BANDWIDTH=18446744073709551615',
        "bw_quoted": 'BANDWIDTH="1"',
        "bw_plus": 'BANDWIDTH=+1',
        "bw_leading_zero": 'BANDWIDTH=007',
        "res_0x0": 'BANDWIDTH=1,RESOLUTION=0x0',
        "res_huge": 'BANDWIDTH=1,RESOLUTION=999999999x999999999',
        "res_upper_x": 'BANDWIDTH=1,RESOLUTION=1280X720',
        "res_triple": 'BANDWIDTH=1,RESOLUTION=1x2x3',
        "res_missing_h": 'BANDWIDTH=1,RESOLUTION=1280x',
        "fps_ok": 'BANDWIDTH=1,FRAME-RATE=29.97',
        "fps_round": 'BANDWIDTH=1,FRAME-RATE=29.9705',
        "fps_overflow_wrap": 'BANDWIDTH=1,FRAME-RATE=9223372036854775.999',
        "fps_zero": 'BANDWIDTH=1,FRAME-RATE=0',
        "fps_exp": 'BANDWIDTH=1,FRAME-RATE=3e1',
        "fps_nan": 'BANDWIDTH=1,FRAME-RATE=NaN',
        "hdcp_other": 'BANDWIDTH=1,HDCP-LEVEL=TYPE-2',
        "hdcp_space": 'BANDWIDTH=1,HDCP-LEVEL=TYPE 2',
        "hdcp_equals": 'BANDWIDTH=1,HDCP-LEVEL=A=B',
        "hdcp_lower": 'BANDWIDTH=1,HDCP-LEVEL=type-0',
        "cc_none": 'BANDWIDTH=1,CLOSED-CAPTIONS=NONE',
        "cc_bad_enum": 'BANDWIDTH=1,CLOSED-CAPTIONS=CC1',
        "score": 'BANDWIDTH=1,SCORE=1.5',
        "score_negative": 'BANDWIDTH=1,SCORE=-1',
        "avg_zero": 'BANDWIDTH=1,AVERAGE-BANDWIDTH=0',
        "unknown_attr": 'BANDWIDTH=1,X-FOO="bar",REQ-THING=1',
        "max_attrs_256": ",".join(["BANDWIDTH=1"] + ["X-A%d=1" % i for i in range(255)]),
        "max_attrs_257": ",".join(["BANDWIDTH=1"] + ["X-A%d=1" % i for i in range(256)]),
    }.items():
        c["attr_" + k] = H + "#EXT-X-STREAM-INF:" + v + "\nv.m3u8\n"
    # ---- 3. master structure
    c["m_si_eof"] = H + "#EXT-X-STREAM-INF:BANDWIDTH=1\n"
    c["m_si_comment_then_uri"] = H + "#EXT-X-STREAM-INF:BANDWIDTH=1\n# c\nv.m3u8\n"
    c["m_si_tag_then_uri"] = H + "#EXT-X-STREAM-INF:BANDWIDTH=1\n#EXT-X-FOO\nv.m3u8\n"
    c["m_si_si"] = H + "#EXT-X-STREAM-INF:BANDWIDTH=1\n#EXT-X-STREAM-INF:BANDWIDTH=2\nv.m3u8\n"
    c["m_si_noattrs"] = H + "#EXT-X-STREAM-INF\nv.m3u8\n"
    c["m_si_no_bw"] = H + '#EXT-X-STREAM-INF:CODECS="a"\nv.m3u8\n'
    c["m_iframe_no_consume"] = H + '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1,URI="i.m3u8"\nv.m3u8\n'
    c["m_iframe_ok"] = H + '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1,URI="i.m3u8"\n' + SI
    c["m_iframe_no_uri"] = H + '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1\n' + SI
    c["m_iframe_pending_si"] = H + '#EXT-X-STREAM-INF:BANDWIDTH=1\n#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1,URI="i"\nv\n'
    c["m_mixed_targetduration"] = H + SI + "#EXT-X-TARGETDURATION:10\n"
    c["m_mixed_extinf_first"] = MH + SEG + SI
    c["m_mixed_key"] = H + '#EXT-X-KEY:METHOD=NONE\n' + SI
    c["m_mixed_part"] = H + SI + '#EXT-X-PART:DURATION=1,URI="p"\n'
    c["m_uri_without_si"] = H + "v.m3u8\n"
    c["m_media_full"] = H + ('#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="en",LANGUAGE="en",ASSOC-LANGUAGE="en-US",'
                             'DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,CHARACTERISTICS="public.accessibility",CHANNELS="2",'
                             'URI="a.m3u8"\n') + '#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="a"\nv.m3u8\n'
    c["m_media_default_autoselect_no"] = H + '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="n",DEFAULT=YES,AUTOSELECT=NO\n' + SI
    c["m_media_default_quoted"] = H + '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="n",DEFAULT="YES"\n' + SI
    c["m_media_cc_uri"] = H + '#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="c",NAME="n",INSTREAM-ID="CC1",URI="x"\n' + SI
    c["m_media_cc_no_instream"] = H + '#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="c",NAME="n"\n' + SI
    c["m_media_unknown_type"] = H + '#EXT-X-MEDIA:TYPE=TEXT,GROUP-ID="a",NAME="n"\n' + SI
    c["m_media_missing_name"] = H + '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a"\n' + SI
    c["m_media_dup_name"] = H + ('#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="n"\n'
                                 '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="n"\n') + '#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="a"\nv\n'
    c["m_group_ref_missing"] = H + '#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="nope"\nv.m3u8\n'
    c["m_cc_none_mixed"] = H + ('#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="c",NAME="n",INSTREAM-ID="CC1"\n'
                                '#EXT-X-STREAM-INF:BANDWIDTH=1,CLOSED-CAPTIONS=NONE\nv1\n'
                                '#EXT-X-STREAM-INF:BANDWIDTH=2,CLOSED-CAPTIONS="c"\nv2\n')
    c["m_session_data_both"] = H + '#EXT-X-SESSION-DATA:DATA-ID="d",VALUE="v",URI="u"\n' + SI
    c["m_session_data_none"] = H + '#EXT-X-SESSION-DATA:DATA-ID="d"\n' + SI
    c["m_session_data_fmt_json"] = H + '#EXT-X-SESSION-DATA:DATA-ID="d",URI="u.json",FORMAT=JSON\n' + SI
    c["m_session_data_fmt_bad"] = H + '#EXT-X-SESSION-DATA:DATA-ID="d",URI="u",FORMAT=a b\n' + SI
    c["m_session_key_none"] = H + '#EXT-X-SESSION-KEY:METHOD=NONE\n' + SI
    c["m_session_key_ok"] = H + '#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="skd://k",KEYFORMAT="%s"\n' % KF_FP + SI
    c["m_version_dup"] = H + "#EXT-X-VERSION:3\n#EXT-X-VERSION:3\n" + SI
    c["m_version_zero"] = H + "#EXT-X-VERSION:0\n" + SI
    c["m_independent_dup"] = H + "#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-INDEPENDENT-SEGMENTS\n" + SI
    c["m_start_dup"] = H + "#EXT-X-START:TIME-OFFSET=1\n#EXT-X-START:TIME-OFFSET=2\n" + SI
    c["m_start_negative"] = H + "#EXT-X-START:TIME-OFFSET=-6.25,PRECISE=YES\n" + SI
    c["m_start_signflip"] = H + "#EXT-X-START:TIME-OFFSET=-%s.999999\n" % BIG + SI
    c["m_start_precise_quoted"] = H + '#EXT-X-START:TIME-OFFSET=1,PRECISE="YES"\n' + SI
    # ---- 4. EXT-X-DEFINE
    D = '#EXT-X-DEFINE:NAME="%s",VALUE="%s"\n'
    c["def_basic"] = H + D % ("cdn", "https://cdn.example") + "#EXT-X-STREAM-INF:BANDWIDTH=1\n{$cdn}/v.m3u8\n"
    c["def_self_ref"] = H + D % ("a", "{$a}") + "#EXT-X-STREAM-INF:BANDWIDTH=1\n{$a}\n"
    c["def_mutual"] = H + D % ("a", "{$b}") + D % ("b", "{$a}") + "#EXT-X-STREAM-INF:BANDWIDTH=1\n{$a}{$b}\n"
    c["def_nested_reexpand"] = H + D % ("b", "evil") + D % ("a", "{$b}") + "#EXT-X-STREAM-INF:BANDWIDTH=1\n{$a}.m3u8\n"
    c["def_concat_ref"] = H + D % ("d", "$") + D % ("x", "evil") + "#EXT-X-STREAM-INF:BANDWIDTH=1\n{{$d}x}\n"
    laughs = H + D % ("l0", "xxxx") + "".join(D % ("l%d" % i, "{$l%d}{$l%d}" % (i - 1, i - 1)) for i in range(1, 21))
    c["def_laughs_20"] = laughs + "#EXT-X-STREAM-INF:BANDWIDTH=1\n{$l20}\n"
    c["def_undef"] = H + D % ("a", "x") + "#EXT-X-STREAM-INF:BANDWIDTH=1\n{$undef}\n"
    c["def_undef_no_define"] = H + "#EXT-X-STREAM-INF:BANDWIDTH=1\n{$undef}.m3u8\n"
    c["def_dup"] = H + D % ("a", "x") + D % ("a", "y") + SI
    c["def_case_sensitive"] = H + D % ("a", "x") + D % ("A", "y") + "#EXT-X-STREAM-INF:BANDWIDTH=1\n{$a}{$A}\n"
    c["def_bad_name"] = H + D % ("a.b", "x") + SI
    c["def_empty_value"] = H + D % ("e", "") + "#EXT-X-STREAM-INF:BANDWIDTH=1\nv{$e}.m3u8\n"
    c["def_empty_uri"] = H + D % ("e", "") + "#EXT-X-STREAM-INF:BANDWIDTH=1\n{$e}\n"
    c["def_hash_uri"] = H + D % ("h", "#x") + "#EXT-X-STREAM-INF:BANDWIDTH=1\n{$h}\n"
    c["def_name_and_import"] = H + '#EXT-X-DEFINE:NAME="a",VALUE="x",IMPORT="a"\n' + SI
    c["def_value_only"] = H + '#EXT-X-DEFINE:VALUE="x"\n' + SI
    c["def_import_master"] = H + '#EXT-X-DEFINE:IMPORT="token"\n' + SI
    c["def_import_media_ref"] = MH + '#EXT-X-DEFINE:IMPORT="token"\n#EXTINF:4,\na.ts?t={$token}\n'
    c["def_queryparam_ref"] = MH + '#EXT-X-DEFINE:QUERYPARAM="token"\n#EXTINF:4,\na.ts?t={$token}\n'
    c["def_import_unused"] = MH + '#EXT-X-DEFINE:IMPORT="token"\n' + SEG
    c["def_brace_literal"] = H + D % ("a", "x") + "#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8?q={$}\n"
    c["def_brace_literal_nodef"] = H + "#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8?q={$ x}\n"
    c["def_unterminated"] = H + D % ("a", "x") + "#EXT-X-STREAM-INF:BANDWIDTH=1\nv{$a\n"
    c["def_in_language"] = H + D % ("l", "en") + '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="n",LANGUAGE="{$l}"\n#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="a"\nv\n'
    c["def_in_daterange"] = MH + D % ("i", "ad1") + '#EXT-X-DATERANGE:ID="{$i}",START-DATE="2026-01-01T00:00:00Z"\n' + SEG
    c["def_in_iv"] = MH + D % ("iv", "0x00000000000000000000000000000001") + '#EXT-X-KEY:METHOD=AES-128,URI="k",IV={$iv}\n' + SEG
    c["def_in_codecs"] = H + D % ("c", "avc1.64001f") + '#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="{$c}"\nv\n'
    c["def_in_key_uri"] = MH + D % ("k", "https://k.example/1") + '#EXT-X-KEY:METHOD=AES-128,URI="{$k}"\n' + SEG
    c["def_line_limit"] = H + D % ("a", "x" * 40000) + "#EXT-X-STREAM-INF:BANDWIDTH=1\n{$a}{$a}\n"
    # ---- 5. media playlist semantics
    c["med_no_td"] = H + SEG
    c["med_td_zero"] = H + "#EXT-X-TARGETDURATION:0\n" + SEG
    c["med_td_neg"] = H + "#EXT-X-TARGETDURATION:-1\n" + SEG
    c["med_td_float"] = H + "#EXT-X-TARGETDURATION:9.5\n" + SEG
    c["med_td_dup"] = MH + "#EXT-X-TARGETDURATION:10\n" + SEG
    c["med_extinf_over_td"] = MH + "#EXTINF:12.5,\na.ts\n"
    c["med_extinf_round_ok"] = MH + "#EXTINF:10.4,\na.ts\n"
    c["med_extinf_round_up"] = MH + "#EXTINF:10.5,\na.ts\n"
    c["med_extinf_negative"] = MH + "#EXTINF:-1,\na.ts\n"
    c["med_extinf_nan"] = MH + "#EXTINF:NaN,\na.ts\n"
    c["med_extinf_inf"] = MH + "#EXTINF:inf,\na.ts\n"
    c["med_extinf_no_comma"] = MH + "#EXTINF:4\na.ts\n"
    c["med_extinf_precision"] = MH + "#EXTINF:3.99999949999,\na.ts\n#EXTINF:3.0000005,\nb.ts\n"
    c["med_extinf_overflow_wrap"] = MH + "#EXTINF:%s.999999,\na.ts\n" % BIG
    c["med_extinf_overflow_whole"] = MH + "#EXTINF:9223372036855,\na.ts\n"
    c["med_extinf_dangling"] = MH + "#EXTINF:4,\n"
    c["med_extinf_twice"] = MH + "#EXTINF:4,\n#EXTINF:4,\na.ts\n"
    c["med_title_comma"] = MH + "#EXTINF:4,a,b,#EXT-X-KEY:METHOD=AES-128\na.ts\n"
    c["med_title_space"] = MH + "#EXTINF:4, \na.ts\n"
    c["med_sum_overflow"] = H + "#EXT-X-TARGETDURATION:9000000000000\n" + "#EXTINF:9000000000000,\na.ts\n" * 2
    c["med_msn_overflow"] = MH + "#EXT-X-MEDIA-SEQUENCE:9223372036854775807\n" + SEG + SEG
    c["med_dsn_overflow"] = MH + "#EXT-X-DISCONTINUITY-SEQUENCE:9223372036854775807\n" + SEG + "#EXT-X-DISCONTINUITY\n" + SEG
    c["med_msn_after_segment"] = MH + SEG + "#EXT-X-MEDIA-SEQUENCE:5\n" + SEG
    c["med_msn_dup"] = MH + "#EXT-X-MEDIA-SEQUENCE:1\n#EXT-X-MEDIA-SEQUENCE:1\n" + SEG
    c["med_ptype_bad"] = MH + "#EXT-X-PLAYLIST-TYPE:LIVE\n" + SEG
    c["med_endlist_dup"] = MH + SEG + "#EXT-X-ENDLIST\n#EXT-X-ENDLIST\n"
    c["med_iframes_only"] = H + "#EXT-X-VERSION:4\n#EXT-X-TARGETDURATION:10\n#EXT-X-I-FRAMES-ONLY\n" + \
        "#EXTINF:4,\n#EXT-X-BYTERANGE:1000@0\nv.ts\n#EXTINF:4,\n#EXT-X-BYTERANGE:1000@5000\nv.ts\n"
    c["med_disc_seq"] = MH + "#EXT-X-DISCONTINUITY-SEQUENCE:7\n" + SEG + "#EXT-X-DISCONTINUITY\n" + SEG + SEG + \
        "#EXT-X-DISCONTINUITY\n#EXT-X-DISCONTINUITY\n" + SEG
    c["med_gap"] = MH + SEG + "#EXT-X-GAP\n" + SEG
    # byterange §4.4.4.2
    c["br_explicit"] = MH + "#EXTINF:4,\n#EXT-X-BYTERANGE:100@0\nb.mp4\n"
    c["br_implicit_chain"] = MH + "#EXTINF:4,\n#EXT-X-BYTERANGE:100@50\nb.mp4\n#EXTINF:4,\n#EXT-X-BYTERANGE:200\nb.mp4\n" + \
        "#EXTINF:4,\n#EXT-X-BYTERANGE:300\nb.mp4\n"
    c["br_implicit_first"] = MH + "#EXTINF:4,\n#EXT-X-BYTERANGE:100\nb.mp4\n"
    c["br_implicit_interleaved"] = MH + "#EXTINF:4,\n#EXT-X-BYTERANGE:100@0\na.mp4\n#EXTINF:4,\n#EXT-X-BYTERANGE:100@0\nb.mp4\n" + \
        "#EXTINF:4,\n#EXT-X-BYTERANGE:100\na.mp4\n"
    c["br_implicit_after_whole"] = MH + "#EXTINF:4,\nb.mp4\n#EXTINF:4,\n#EXT-X-BYTERANGE:100\nb.mp4\n"
    c["br_implicit_after_disc"] = MH + "#EXTINF:4,\n#EXT-X-BYTERANGE:100@0\nb.mp4\n#EXT-X-DISCONTINUITY\n#EXTINF:4,\n#EXT-X-BYTERANGE:100\nb.mp4\n"
    c["br_zero_len"] = MH + "#EXTINF:4,\n#EXT-X-BYTERANGE:0@0\nb.mp4\n"
    c["br_negative"] = MH + "#EXTINF:4,\n#EXT-X-BYTERANGE:-1@0\nb.mp4\n"
    c["br_overflow"] = MH + "#EXTINF:4,\n#EXT-X-BYTERANGE:2@9223372036854775806\nb.mp4\n"
    c["br_overflow_implicit"] = MH + "#EXTINF:4,\n#EXT-X-BYTERANGE:1@9223372036854775806\nb.mp4\n#EXTINF:4,\n#EXT-X-BYTERANGE:1\nb.mp4\n#EXTINF:4,\n#EXT-X-BYTERANGE:1\nb.mp4\n"
    c["br_double_at"] = MH + "#EXTINF:4,\n#EXT-X-BYTERANGE:1@2@3\nb.mp4\n"
    c["br_map_isolated"] = MH + '#EXT-X-MAP:URI="b.mp4",BYTERANGE="720@0"\n#EXTINF:4,\n#EXT-X-BYTERANGE:100\nb.mp4\n'
    c["br_map_no_offset"] = MH + '#EXT-X-MAP:URI="init.mp4",BYTERANGE="720"\n' + SEG
    c["br_map_unquoted"] = MH + '#EXT-X-MAP:URI="init.mp4",BYTERANGE=720@0\n' + SEG
    c["br_before_tags"] = MH + "#EXT-X-BYTERANGE:100@0\n#EXTINF:4,\n#EXT-X-KEY:METHOD=NONE\nb.mp4\n"
    # keys §4.4.4.4
    c["key_aes"] = MH + '#EXT-X-KEY:METHOD=AES-128,URI="k1",IV=0x0123456789abcdef0123456789ABCDEF\n' + SEG + SEG
    c["key_none_clears"] = MH + '#EXT-X-KEY:METHOD=AES-128,URI="k1"\n' + SEG + '#EXT-X-KEY:METHOD=NONE\n' + SEG
    c["key_none_with_uri"] = MH + '#EXT-X-KEY:METHOD=NONE,URI="k"\n' + SEG
    c["key_none_with_iv"] = MH + '#EXT-X-KEY:METHOD=NONE,IV=0x00000000000000000000000000000001\n' + SEG
    c["key_aes_no_uri"] = MH + '#EXT-X-KEY:METHOD=AES-128\n' + SEG
    c["key_aes_empty_uri"] = MH + '#EXT-X-KEY:METHOD=AES-128,URI=""\n' + SEG
    c["key_no_method"] = MH + '#EXT-X-KEY:URI="k"\n' + SEG
    c["key_method_quoted"] = MH + '#EXT-X-KEY:METHOD="AES-128",URI="k"\n' + SEG
    c["key_method_unknown"] = MH + '#EXT-X-KEY:METHOD=AES-256,URI="k"\n' + SEG
    c["key_ctr"] = MH + '#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI="k",KEYFORMAT="cenc"\n' + SEG
    for n, iv in (("31", "0x" + "0" * 31), ("33", "0x" + "0" * 33), ("nox", "00" + "0" * 32), ("upper0X", "0X" + "a" * 32),
                  ("nonhex", "0x" + "g" * 32), ("quoted", '"0x' + "0" * 32 + '"')):
        c["key_iv_" + n] = MH + '#EXT-X-KEY:METHOD=AES-128,URI="k",IV=%s\n' % iv + SEG
    c["key_multi_keyformat"] = MH + ('#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://fp",KEYFORMAT="%s",KEYFORMATVERSIONS="1"\n'
                                     '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="data:text/plain;base64,AAAA",KEYFORMAT="%s"\n'
                                     % (KF_FP, KF_WV)) + SEG + SEG
    c["key_keyformat_persist"] = MH + '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://fp",KEYFORMAT="%s"\n' % KF_FP + SEG + \
        '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="data:wv",KEYFORMAT="%s"\n' % KF_WV + SEG
    c["key_none_keyformat"] = MH + '#EXT-X-KEY:METHOD=AES-128,URI="k1"\n' + SEG + '#EXT-X-KEY:METHOD=NONE,KEYFORMAT="x"\n' + SEG
    c["key_then_map"] = MH + '#EXT-X-KEY:METHOD=AES-128,URI="k"\n#EXT-X-MAP:URI="init.mp4"\n' + SEG
    c["key_rotation"] = MH + "".join('#EXT-X-KEY:METHOD=AES-128,URI="k%d"\n#EXTINF:4,\ns%d.ts\n' % (i, i) for i in range(5))
    c["map_inherit"] = MH + '#EXT-X-MAP:URI="i1.mp4"\n' + SEG + SEG + '#EXT-X-MAP:URI="i2.mp4",BYTERANGE="10@0"\n' + SEG
    c["map_no_uri"] = MH + '#EXT-X-MAP:BYTERANGE="1@0"\n' + SEG
    # program date time §4.4.4.6
    for n, v in (("z", "2026-11-24T08:00:00.000Z"), ("offset", "2026-11-24T08:00:00+08:00"),
                 ("leap_ok", "2024-02-29T00:00:00Z"), ("leap_bad", "2025-02-29T00:00:00Z"), ("y1900", "1900-02-29T00:00:00Z"),
                 ("y2000", "2000-02-29T00:00:00Z"), ("tz25", "2026-01-01T00:00:00+25:00"), ("min60", "2026-01-01T00:60:00Z"),
                 ("leap_second", "2016-12-31T23:59:60Z"), ("hour24", "2026-01-01T24:00:00Z"), ("month13", "2026-13-01T00:00:00Z"),
                 ("day0", "2026-01-00T00:00:00Z"), ("no_tz", "2010-02-19T14:54:23.031"), ("basic_offset", "2010-02-19T14:54:23.031+0000"),
                 ("hour_offset", "2010-02-19T14:54:23+08"), ("space_sep", "2026-01-01 00:00:00Z"), ("lower", "2026-01-01t00:00:00z"),
                 ("empty_frac", "2026-01-01T00:00:00.Z"), ("trailing", "2026-01-01T00:00:00Zx"), ("date_only", "2026-01-01")):
        c["pdt_" + n] = MH + "#EXT-X-PROGRAM-DATE-TIME:%s\n" % v + SEG
    # date range
    DR = '#EXT-X-DATERANGE:ID="ad",START-DATE="2026-01-01T00:00:00Z"'
    c["dr_basic"] = MH + DR + ',CLASS="c",DURATION=30.5,PLANNED-DURATION=30,X-COM-EXAMPLE-AD-ID="XYZ",X-NUM=12.5,SCTE35-OUT=0xFC30\n' + SEG
    c["dr_eon_no_class"] = MH + DR + ',END-ON-NEXT=YES\n' + SEG
    c["dr_eon_with_duration"] = MH + DR + ',CLASS="c",END-ON-NEXT=YES,DURATION=1\n' + SEG
    c["dr_no_start"] = MH + '#EXT-X-DATERANGE:ID="ad"\n' + SEG
    c["dr_scte_quoted"] = MH + DR + ',SCTE35-CMD="0xFC"\n' + SEG
    c["dr_scte_bad"] = MH + DR + ',SCTE35-IN=FC\n' + SEG
    c["dr_x_unquoted_space"] = MH + DR + ',X-A=a b\n' + SEG
    c["dr_x_unquoted_eq"] = MH + DR + ',X-A=a=b\n' + SEG
    c["dr_neg_duration"] = MH + DR + ',DURATION=-1\n' + SEG
    c["dr_bad_date"] = MH + '#EXT-X-DATERANGE:ID="ad",START-DATE="2026-02-30T00:00:00Z"\n' + SEG
    # LL-HLS
    LL = H + "#EXT-X-VERSION:9\n#EXT-X-TARGETDURATION:4\n#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.0,CAN-SKIP-UNTIL=24\n" \
        "#EXT-X-PART-INF:PART-TARGET=0.5\n"
    c["ll_full"] = LL + "#EXT-X-MEDIA-SEQUENCE:100\n" + \
        '#EXT-X-PART:DURATION=0.5,URI="s0p0.mp4",INDEPENDENT=YES\n#EXT-X-PART:DURATION=0.5,URI="s0p1.mp4"\n#EXTINF:1,\ns0.mp4\n' + \
        '#EXT-X-PART:DURATION=0.5,URI="s1p0.mp4",INDEPENDENT=YES\n' + \
        '#EXT-X-PRELOAD-HINT:TYPE=PART,URI="s1p1.mp4"\n#EXT-X-RENDITION-REPORT:URI="../b/x.m3u8",LAST-MSN=101,LAST-PART=0\n'
    c["ll_part_byterange"] = LL + '#EXT-X-PART:DURATION=0.5,URI="s.mp4",BYTERANGE="100@0"\n#EXT-X-PART:DURATION=0.5,URI="s.mp4",BYTERANGE="100"\n#EXTINF:1,\ns.mp4\n'
    c["ll_part_over_target"] = LL + '#EXT-X-PART:DURATION=0.9,URI="p"\n#EXTINF:1,\ns.mp4\n'
    c["ll_part_no_inf"] = MH + '#EXT-X-PART:DURATION=0.5,URI="p"\n' + SEG
    c["ll_part_no_uri"] = LL + '#EXT-X-PART:DURATION=0.5\n#EXTINF:1,\ns.mp4\n'
    c["ll_part_quoted_dur"] = LL + '#EXT-X-PART:DURATION="0.5",URI="p"\n#EXTINF:1,\ns.mp4\n'
    c["ll_part_empty_uri"] = LL + '#EXT-X-PART:DURATION=0.5,URI=""\n#EXTINF:1,\ns.mp4\n'
    c["ll_partinf_no_phb"] = H + "#EXT-X-TARGETDURATION:4\n#EXT-X-PART-INF:PART-TARGET=0.5\n" + SEG.replace("4,", "1,")
    c["ll_partinf_zero"] = H + "#EXT-X-TARGETDURATION:4\n#EXT-X-PART-INF:PART-TARGET=0\n" + SEG
    c["ll_sc_dup"] = MH + "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES\n#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES\n" + SEG
    c["ll_sc_empty"] = MH + "#EXT-X-SERVER-CONTROL:\n" + SEG
    c["ll_sc_quoted"] = MH + '#EXT-X-SERVER-CONTROL:HOLD-BACK="30"\n' + SEG
    c["ll_sc_skip_too_small"] = MH + "#EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=12\n" + SEG
    c["ll_sc_holdback_small"] = MH + "#EXT-X-SERVER-CONTROL:HOLD-BACK=5\n" + SEG
    c["ll_sc_dateranges_alone"] = MH + "#EXT-X-SERVER-CONTROL:CAN-SKIP-DATERANGES=YES\n" + SEG
    c["ll_skip"] = H + "#EXT-X-VERSION:9\n#EXT-X-TARGETDURATION:4\n#EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=24\n" + \
        "#EXT-X-MEDIA-SEQUENCE:100\n#EXT-X-SKIP:SKIPPED-SEGMENTS=10\n#EXTINF:4,\nx110.ts\n#EXTINF:4,\nx111.ts\n"
    c["ll_skip_dup"] = MH + "#EXT-X-SKIP:SKIPPED-SEGMENTS=1\n#EXT-X-SKIP:SKIPPED-SEGMENTS=2\n" + SEG
    c["ll_skip_quoted"] = MH + '#EXT-X-SKIP:SKIPPED-SEGMENTS="3"\n' + SEG
    c["ll_skip_removed"] = MH + '#EXT-X-SKIP:SKIPPED-SEGMENTS=0,RECENTLY-REMOVED-DATERANGES="a\tb"\n' + SEG
    c["ll_hint_bad_type"] = MH + '#EXT-X-PRELOAD-HINT:TYPE=SEGMENT,URI="x"\n' + SEG
    c["ll_hint_map"] = MH + '#EXT-X-PRELOAD-HINT:TYPE=MAP,URI="init.mp4",BYTERANGE-START=0,BYTERANGE-LENGTH=720\n' + SEG
    c["ll_hint_no_uri"] = MH + '#EXT-X-PRELOAD-HINT:TYPE=PART\n' + SEG
    c["ll_rr_no_uri"] = MH + '#EXT-X-RENDITION-REPORT:LAST-MSN=1\n' + SEG
    c["ll_rr_negative"] = MH + '#EXT-X-RENDITION-REPORT:URI="x",LAST-MSN=-1\n' + SEG
    c["ll_trailing_parts_only"] = LL + '#EXT-X-PART:DURATION=0.5,URI="p0"\n#EXT-X-PART:DURATION=0.5,URI="p1"\n'
    # custom / positional tags
    c["ct_cue"] = MH + SEG + "#EXT-X-CUE-OUT:30\n" + SEG + "#EXT-X-CUE-IN\n" + SEG + "#EXT-X-ENDLIST\n"
    c["ct_unknown_master"] = H + "#EXT-X-CONTENT-STEERING:SERVER-URI=\"s.json\"\n" + SI
    c["ct_bitrate"] = MH + "#EXT-X-BITRATE:800\n" + SEG
    c["ct_extm3u_again"] = MH + "#EXTM3U\n" + SEG
    c["ct_empty_value"] = MH + "#EXT-X-FOO:\n" + SEG
    return c


def seeds(c):
    """Valid inputs that the mutator starts from."""
    names = ["lex_minimal_media", "lex_minimal_master", "m_media_full", "def_basic", "def_in_codecs", "br_implicit_chain",
             "key_aes", "key_rotation", "map_inherit", "pdt_z", "dr_basic", "ll_full", "ll_part_byterange",
             "med_disc_seq", "m_iframe_ok", "m_session_key_ok", "m_start_negative", "med_iframes_only", "ct_cue"]
    out = [c[n] for n in names]
    out.append(H + "#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n" +
               '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="a/en.m3u8"\n'
               '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="s/en.m3u8"\n'
               '#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="CC1",INSTREAM-ID="CC1"\n'
               '#EXT-X-STREAM-INF:BANDWIDTH=1500000,AVERAGE-BANDWIDTH=1200000,CODECS="avc1.64001f,mp4a.40.2",'
               'RESOLUTION=1280x720,FRAME-RATE=29.970,HDCP-LEVEL=NONE,AUDIO="aac",SUBTITLES="subs",CLOSED-CAPTIONS="cc"\n'
               'v720.m3u8\n'
               '#EXT-X-STREAM-INF:BANDWIDTH=4800000,CODECS="hvc1.1.6.L120.90,mp4a.40.2",RESOLUTION=1920x1080,'
               'FRAME-RATE=59.94,HDCP-LEVEL=TYPE-0,AUDIO="aac",SUBTITLES="subs",CLOSED-CAPTIONS="cc",SCORE=2.5,PATHWAY-ID="A"\n'
               'v1080.m3u8\n'
               '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=240000,RESOLUTION=1280x720,CODECS="avc1.64001f",URI="i720.m3u8"\n'
               '#EXT-X-SESSION-DATA:DATA-ID="com.example.title",VALUE="Movie",LANGUAGE="en"\n')
    return out


ATOMS = ["\n", "\r", "\r\n", "\x00", ",", "=", '"', "@", ":", "#", "-", ".", "0", "9", "x", " ", "\t", "{$a}", "{$",
         "YES", "NONE", "#EXT-X-DISCONTINUITY\n", "#EXT-X-ENDLIST\n", "#EXTINF:1,\n", "z.ts\n", "#EXT-X-BYTERANGE:10\n",
         '#EXT-X-DEFINE:NAME="a",VALUE="v"\n', "#EXT-X-STREAM-INF:BANDWIDTH=5\n", '#EXT-X-KEY:METHOD=NONE\n',
         "9223372036854.999999", "99999999999999999999", "\ufeff"]


NUMS = ["0", "1", "4", "10", "10.5", "0.333", "-1", "007", "1.0000005", "9223372036854775807", "9223372036854775808",
        "9223372036854.775807", "9223372036854.999999", "18446744073709551616", "1e3", "0x10"]


def mutate_semantic(rng, s):
    lines = s.split("\n")
    i = rng.randrange(1, len(lines)) if len(lines) > 1 else 0
    l = lines[i]
    op = rng.randrange(5)
    if op == 0:  # replace one number
        spans = [(m.start(), m.end()) for m in re.finditer(r"-?[0-9]+(\.[0-9]+)?", l)]
        if spans:
            a, b = rng.choice(spans)
            l = l[:a] + rng.choice(NUMS) + l[b:]
    elif op == 1 and ":" in l:  # duplicate / drop / swap attributes
        head, attrs = l.split(":", 1)
        parts = re.findall(r'[A-Z0-9-]+=(?:"[^"]*"|[^,]*)', attrs)
        if parts:
            k = rng.randrange(3)
            if k == 0:
                parts.append(rng.choice(parts))
            elif k == 1 and len(parts) > 1:
                parts.pop(rng.randrange(len(parts)))
            else:
                rng.shuffle(parts)
            l = head + ":" + ",".join(parts)
    elif op == 2:  # toggle quoting of one value
        m = list(re.finditer(r'=("?)([^",]*)("?)', l))
        if m:
            x = rng.choice(m)
            v = x.group(2)
            l = l[:x.start()] + ("=" + v if x.group(1) else '="' + v + '"') + l[x.end():]
    elif op == 3:  # duplicate a whole line elsewhere
        lines.insert(rng.randrange(1, len(lines) + 1), l)
    else:  # replace a value with an interesting token
        m = list(re.finditer(r'=("[^"]*"|[^,]*)', l))
        if m:
            x = rng.choice(m)
            tok = rng.choice(['"{$a}"', '""', "YES", "NONE", "0x" + "0" * 32, '"2026-02-29T00:00:00Z"', "1280x720",
                              '"#EXT-X-ENDLIST"', "TYPE-0", '"x,y"'])
            l = l[:x.start()] + "=" + tok + l[x.end():]
    lines[i] = l
    return "\n".join(lines)


def mutate(rng, s):
    if rng.random() < 0.6:
        for _ in range(rng.randint(1, 2)):
            s = mutate_semantic(rng, s)
        return s
    for _ in range(rng.randint(1, 3)):
        op = rng.randrange(7)
        lines = s.split("\n")
        if op == 0 and s:
            i = rng.randrange(len(s))
            s = s[:i] + rng.choice(ATOMS) + s[i:]
        elif op == 1 and s:
            i = rng.randrange(len(s))
            s = s[:i] + s[i + rng.randint(1, 8):]
        elif op == 2 and len(lines) > 2:
            i = rng.randrange(1, len(lines))
            del lines[i]
            s = "\n".join(lines)
        elif op == 3 and len(lines) > 2:
            i = rng.randrange(1, len(lines))
            lines.insert(i, lines[rng.randrange(1, len(lines))])
            s = "\n".join(lines)
        elif op == 4 and len(lines) > 3:
            i, j = rng.randrange(1, len(lines)), rng.randrange(1, len(lines))
            lines[i], lines[j] = lines[j], lines[i]
            s = "\n".join(lines)
        elif op == 5 and s:
            i = rng.randrange(len(s))
            s = s[:i] + chr(rng.randrange(32, 127)) + s[i + 1:]
        elif op == 6:
            i = rng.randrange(len(s) + 1)
            s = s[:i] + rng.choice(ATOMS) * rng.randint(1, 3) + s[i:]
    return s


def enc(v):
    return (v if isinstance(v, bytes) else v.encode("utf-8")).hex()


def main():
    out_dir, n = sys.argv[1], int(sys.argv[2])
    os.makedirs(out_dir, exist_ok=True)
    c = named()
    with open(os.path.join(out_dir, "named.cases"), "w") as f:
        for k in sorted(c):
            f.write("%s\t%s\n" % (k, enc(c[k])))
    rng = random.Random(0x8216)
    base = seeds(c)
    with open(os.path.join(out_dir, "fuzz.cases"), "w") as f:
        for i, s in enumerate(base):
            f.write("seed%02d\t%s\n" % (i, enc(s)))
        for i in range(n):
            f.write("fz%05d\t%s\n" % (i, enc(mutate(rng, rng.choice(base)))))
    print(len(c), len(base) + n)


if __name__ == "__main__":
    main()
