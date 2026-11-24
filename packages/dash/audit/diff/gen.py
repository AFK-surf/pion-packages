#!/usr/bin/env python3
"""Deterministic corpora for the packages/dash red-team differential (no third-party media, no network).

gen.py <out_dir> <n>   writes
  named.cases  hand-written ISO/IEC 23009-1 / XML 1.0 edge cases (one per line: <name> TAB <hex>)
  fuzz.cases   <n> generated MPDs: structured random documents (seeds) + byte / token mutations of them
  api.vec      public-API vectors for src/api.pion (durations, date-times, rationals, templates, URLs)
and prints '<named> <fuzz> <api>'.
"""
import os
import random
import sys

NS = 'xmlns="urn:mpeg:dash:schema:mpd:2011"'
CENC = 'xmlns:cenc="urn:mpeg:cenc:2013"'


def mpd(attrs, body):
    return '<MPD %s %s %s>%s</MPD>' % (NS, CENC, attrs, body)


def st(pattrs, body, mattrs='type="static" mediaPresentationDuration="PT10S"'):
    return mpd(mattrs, '<Period%s>%s</Period>' % (pattrs, body))


def as1(inner, rattrs='id="v" bandwidth="1000"', aattrs=''):
    return '<AdaptationSet%s><Representation %s>%s</Representation></AdaptationSet>' % (aattrs, rattrs, inner)


def named():
    c = []
    a = c.append
    # --- structure / XML
    a(("minimal", '<MPD/>'))
    a(("bom_decl_prolog", '﻿<?xml version="1.0" encoding="UTF-8"?>\n<!-- c -->\n<?pi x?>\n<MPD type="static"/>\n<!-- e -->\n'))
    a(("decl_standalone", '<?xml version="1.0" encoding="utf-8" standalone="yes"?><MPD/>'))
    a(("decl_version_9", '<?xml version="9.0"?><MPD/>'))
    a(("decl_not_first", ' <?xml version="1.0"?><MPD/>'))
    a(("decl_inside_root", '<MPD><?xml version="1.0"?></MPD>'))
    a(("pi_reserved_XML", '<MPD><?XML x?></MPD>'))
    a(("pi_no_target", '<MPD><? ?></MPD>'))
    a(("doctype_xxe", '<!DOCTYPE MPD [<!ENTITY x SYSTEM "file:///etc/passwd">]><MPD>&x;</MPD>'))
    a(("doctype_lower", '<!doctype MPD><MPD/>'))
    a(("entity_in_content", '<MPD><!ENTITY a "b"></MPD>'))
    a(("billion_laughs", '<!DOCTYPE l [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]><MPD>&b;</MPD>'))
    a(("cdata_baseurl", mpd('', '<BaseURL><![CDATA[http://h/<a>&amp;/]]></BaseURL>')))
    a(("cdata_cr", mpd('', '<Location><![CDATA[a\rb]]></Location>')))
    a(("cdata_end_in_text", mpd('', '<Location>a]]>b</Location>')))
    a(("comment_dashes", mpd('', '<!-- a -- b -->')))
    a(("comment_ctl", mpd('', '<!-- \x01 -->')))
    a(("text_ctl", mpd('', '<Location>a\x02b</Location>')))
    a(("attr_ctl", '<MPD id="a\x1fb"/>'))
    a(("charrefs", mpd('id="&#x41;&#66;&#x1F600;&amp;&lt;&gt;&quot;&apos;"', '')))
    a(("charref_upper_X", mpd('id="&#X41;"', '')))
    a(("charref_long", mpd('id="&#x0000000000000000000000041;"', '')))
    a(("charref_surrogate", mpd('id="&#xD800;"', '')))
    a(("charref_too_big", mpd('id="&#x110000;"', '')))
    a(("charref_nul", mpd('id="&#0;"', '')))
    a(("charref_fffe", mpd('id="&#xFFFE;"', '')))
    a(("raw_fffe", mpd('id="a￾b"', '')))
    a(("raw_nonchar_text", mpd('', '<Location>￿</Location>')))
    a(("unknown_entity", mpd('', '<Location>&nbsp;</Location>')))
    a(("attr_tab_lf_cr", st('', as1('', 'id="a\tb\nc\r\nd\re" bandwidth="1"'))))
    a(("attr_charref_ws", st('', as1('', 'id="a&#9;b&#10;c&#13;d" bandwidth="1"'))))
    a(("dup_attr", '<MPD id="a" id="b"/>'))
    a(("dup_attr_prefixed", '<MPD a:id="a" b:id="b"/>'))
    a(("attr_no_ws", '<MPD a="1"b="2"/>'))
    a(("attr_unquoted", '<MPD a=1/>'))
    a(("attr_lt", '<MPD a="<"/>'))
    a(("attr_single_quotes", "<MPD id='x\"y' type='static'/>"))
    a(("mismatch", '<MPD></mpd>'))
    a(("unclosed", '<MPD>'))
    a(("two_roots", '<MPD/><MPD/>'))
    a(("text_before_root", 'x<MPD/>'))
    a(("text_after_root", '<MPD/>x'))
    a(("empty", ''))
    a(("name_nonascii_ok", '<MPD été="1" type="static"/>'))
    a(("name_times_sign", '<MPD ×="1"/>'))
    a(("name_cjk", '<MPD 中="1"/>'))
    a(("invalid_utf8", b'<MPD><Location>a\xffb</Location></MPD>'))
    a(("overlong_utf8", b'<MPD><Location>\xc0\xafb</Location></MPD>'))
    a(("utf8_surrogate_bytes", b'<MPD><Location>\xed\xa0\x80</Location></MPD>'))
    a(("deep_64", '<MPD>' + '<a>' * 63 + '</a>' * 63 + '</MPD>'))
    a(("deep_65", '<MPD>' + '<a>' * 64 + '</a>' * 64 + '</MPD>'))
    a(("attrs_256", '<MPD ' + ' '.join('a%d="1"' % i for i in range(256)) + '/>'))
    a(("attrs_257", '<MPD ' + ' '.join('a%d="1"' % i for i in range(257)) + '/>'))
    a(("prefixed_root", '<d:MPD xmlns:d="urn:mpeg:dash:schema:mpd:2011" d:type="dynamic"><d:Period id="p"/></d:MPD>'))
    a(("not_mpd_root", '<Foo/>'))
    a(("bad_type", '<MPD type="Static"/>'))
    # --- durations / date-times
    for i, d in enumerate(["PT0S", "PT1H2M3.5S", "P1Y2M3DT4H5M6.123456S", "P1W", "PT0.0000019S", "PT1,5S", "-PT1S", "P",
                           "PT", "P1DT", "PT1.5M", "P1M", "PT36H", "P2W3D", "PT9223372036854.775807S", "PT9223372036855S",
                           " PT1S ", "pt1s", "PT1S2M", "P1Y1Y"]):
        a(("dur_%d" % i, mpd('type="static" mediaPresentationDuration="%s"' % d, '')))
    for i, d in enumerate(["2024-02-29T12:00:00Z", "2023-02-29T00:00:00Z", "1900-02-29T00:00:00Z", "2000-02-29T00:00:00Z",
                           "2024-01-01T00:00:00", "2024-01-01T24:00:00Z", "2024-01-01T24:00:01Z", "2024-01-01T00:00:60Z",
                           "2024-01-01T00:00:00+14:00", "2024-01-01T00:00:00+14:01", "2024-01-01T00:00:00+23:59",
                           "2024-01-01T00:00:00-05:30", "2024-01-01T00:00:00+0530", "2024-01-01T00:00:00+05",
                           "2024-01-01t00:00:00z", "2024-01-01T00:00:00.123456789Z", "1969-12-31T23:59:59Z",
                           "2024-01-01T00:00:00.Z", "2024-13-01T00:00:00Z", "2024-01-01T00:00:00Zx"]):
        a(("dt_%d" % i, mpd('type="dynamic" availabilityStartTime="%s" publishTime="2024-01-01T00:00:00Z"' % d, '<Period start="PT0S"/>')))
    # --- numbers
    for i, v in enumerate(["+5", "05", " 5 ", "-1", "0", "9223372036854775807", "9223372036854775808", "5x", "", "1e3"]):
        a(("startnum_%d" % i, st('', as1('<SegmentTemplate duration="5" startNumber="%s" media="s$Number$"/>' % v))))
    for i, v in enumerate(["0", "1", "+1", "4294967296", "9223372036854775807", "-1"]):
        a(("bandwidth_%d" % i, st('', as1('', 'id="v" bandwidth="%s"' % v))))
    a(("width_zero", st('', as1('', 'id="v" bandwidth="1" width="0" height="0"'))))
    for i, v in enumerate(["30", "30000/1001", "0", "30/0", "29.97", "+30", "1/2/3", "60/1"]):
        a(("framerate_%d" % i, st('', as1('', 'id="v" bandwidth="1" frameRate="%s"' % v))))
    for i, v in enumerate(["true", "false", "1", "0", "TRUE", "yes", " true "]):
        a(("bool_%d" % i, st('', '<AdaptationSet segmentAlignment="%s"/>' % v)))
    # --- timelines
    T = '<SegmentTemplate timescale="%s" %s media="$RepresentationID$/$Number%%05d$_$Time$.m4s"><SegmentTimeline>%s</SegmentTimeline></SegmentTemplate>'
    a(("tl_basic", st('', as1(T % ("10", 'startNumber="5"', '<S t="100" d="20" r="1"/><S d="10"/><S t="200" d="5" r="-1"/><S t="210" d="30"/>')))))
    a(("tl_r_neg_end", st('', as1(T % ("1", '', '<S d="3" r="-1"/>')))))
    a(("tl_r_neg_pto", st('', as1(T % ("1", 'presentationTimeOffset="1000"', '<S t="1000" d="2" r="-1"/>')))))
    a(("tl_r_neg_pto_90k", st('', as1(T % ("90000", 'presentationTimeOffset="900000"', '<S t="900000" d="180000" r="-1"/>')))))
    a(("tl_r_neg_frac", st('', as1(T % ("3", '', '<S d="3" r="-1"/>')), 'type="static" mediaPresentationDuration="PT1.5S"')))
    a(("tl_r_minus5", st('', as1(T % ("1", '', '<S t="0" d="2" r="-5"/>')))))
    a(("tl_r_plus", st('', as1(T % ("1", '', '<S d="2" r="+2"/>')))))
    a(("tl_r_huge", st('', as1(T % ("1", '', '<S d="1" r="999999999"/>')))))
    a(("tl_r_neg_huge", st('', as1(T % ("1", '', '<S d="1" r="-9223372036854775808"/>')))))
    a(("tl_t_overflow", st('', as1(T % ("1", '', '<S t="9223372036854775800" d="5" r="3"/>')))))
    a(("tl_number_max", st('', as1(T % ("1", 'startNumber="9223372036854775807"', '<S d="2"/>')))))
    a(("tl_number_max2", st('', as1(T % ("1", 'startNumber="9223372036854775806"', '<S d="2" r="3"/>')))))
    a(("tl_dynamic_r_neg", mpd('type="dynamic" availabilityStartTime="2024-01-01T00:00:00Z"',
                               '<Period start="PT0S">' + as1(T % ("1", '', '<S t="0" d="2" r="-1"/>')) + '</Period>')))
    a(("tl_no_d", st('', as1(T % ("1", '', '<S t="0"/>')))))
    a(("tl_d0", st('', as1(T % ("1", '', '<S d="0"/>')))))
    a(("tl_two_timelines", st('', as1('<SegmentTemplate media="$Time$"><SegmentTimeline><S d="1"/></SegmentTimeline><SegmentTimeline><S d="2"/></SegmentTimeline></SegmentTemplate>'))))
    # --- duration-based / numbers
    D = '<SegmentTemplate %s media="s$Number$_$Time$.m4s" initialization="i_$RepresentationID$.mp4"/>'
    a(("dur_tpl", st('', as1(D % 'timescale="1000" duration="2000"'))))
    a(("dur_tpl_frac", st('', as1(D % 'timescale="1" duration="1"'), 'type="static" mediaPresentationDuration="PT2.000001S"')))
    a(("dur_tpl_wrap", st('', as1(D % 'duration="5" startNumber="9223372036854775807"'))))
    a(("dur_tpl_dynamic", mpd('type="dynamic"', '<Period>' + as1(D % 'duration="5"') + '</Period>')))
    a(("list_wrap", st('', as1('<SegmentList duration="5" startNumber="9223372036854775807"><SegmentURL media="a"/><SegmentURL media="b"/></SegmentList>'))))
    # --- periods
    P2 = as1(D % 'duration="2"')
    a(("periods_first_nostart", mpd('type="static" mediaPresentationDuration="PT10S"', '<Period>%s</Period><Period start="PT4S">%s</Period>' % (P2, P2))))
    a(("periods_prev_dur", mpd('type="static" mediaPresentationDuration="PT10S"', '<Period start="PT0S" duration="PT4S">%s</Period><Period>%s</Period>' % (P2, P2))))
    a(("periods_chain_dur", mpd('type="static" mediaPresentationDuration="PT10S"', '<Period duration="PT4S">%s</Period><Period duration="PT2S">%s</Period><Period>%s</Period>' % (P2, P2, P2))))
    a(("periods_explicit", mpd('type="static" mediaPresentationDuration="PT10S"', '<Period start="PT0S">%s</Period><Period start="PT6S">%s</Period>' % (P2, P2))))
    a(("periods_mpd_short", mpd('type="static" mediaPresentationDuration="PT1S"', '<Period start="PT5S">%s</Period>' % P2)))
    # --- templates
    for i, m in enumerate(["$$Number$$", "$Number%032d$", "$Number%033d$", "$Number%999999999d$", "$Time%x$",
                           "$Bandwidth%010d$", "$SubNumber$", "$RepresentationID%05d$", "$Number", "$Number%d$",
                           "$Number%5d$", "$Number%00005d$", "$Foo$", "a$$b", ""]):
        a(("tpl_%d" % i, st('', as1('<SegmentTemplate duration="5" media="%s"/>' % m))))
    a(("tpl_no_media", st('', as1('<SegmentTemplate duration="5" initialization="init.mp4"/>'))))
    # --- inheritance
    a(("inherit_period_as_rep", mpd('type="static" mediaPresentationDuration="PT10S"',
                                     '<BaseURL>http://h/root/</BaseURL><Period><SegmentTemplate timescale="1000" startNumber="3" initialization="$RepresentationID$/init.mp4" media="p/$Number$.m4s"/>'
                                     '<AdaptationSet><BaseURL>as/</BaseURL><SegmentTemplate duration="4000" media="a/$RepresentationID$/$Number%03d$.m4s"/>'
                                     '<Representation id="r1" bandwidth="1"><SegmentTemplate startNumber="10"/></Representation>'
                                     '<Representation id="r2" bandwidth="2"><BaseURL>http://other/x/</BaseURL></Representation></AdaptationSet></Period>')))
    a(("inherit_timeline_override", st('<SegmentTemplate media="$Time$"><SegmentTimeline><S d="1" r="2"/></SegmentTimeline></SegmentTemplate>',
                                        '<AdaptationSet><Representation id="v" bandwidth="1"><SegmentTemplate timescale="2"><SegmentTimeline><S d="4"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>')))
    a(("list_base", st('', '<AdaptationSet><SegmentList timescale="10" duration="20"><Initialization sourceURL="init.mp4"/></SegmentList>'
                           '<Representation id="v" bandwidth="1"><BaseURL>http://h/v/</BaseURL><SegmentList startNumber="0"><SegmentURL media="a.m4s" mediaRange="0-99"/><SegmentURL/></SegmentList></Representation></AdaptationSet>')))
    a(("segbase", st(' duration="PT8S"', '<AdaptationSet><SegmentBase timescale="1000" indexRange="100-200"/><Representation id="v" bandwidth="1"><BaseURL>v.mp4</BaseURL><SegmentBase indexRangeExact="true"><Initialization range="0-99"/></SegmentBase></Representation></AdaptationSet>')))
    a(("bare_baseurl", st('', as1('<BaseURL>http://h/file.mp4</BaseURL>'))))
    a(("mixed_tpl_list", st('<SegmentTemplate duration="5" media="t$Number$"/>', as1('<SegmentList><SegmentURL media="l.m4s"/></SegmentList>'))))
    # --- URLs
    for i, (b, r) in enumerate([("http://h/a/b/c", ".."), ("http://h/a/b/", "."), ("http://h/a/b", "x//y"), ("http://h/a?q=1", "#f"),
                                ("http://h/a/b", "http://g/x/../y"), ("../media/", "seg/"), ("video/../../x/", "s/"),
                                ("https://cdn/p/?token=abc", "seg/"), ("http://h", "x/"), ("//cdn.example/p/", "q/"),
                                ("http://h/a/", "../../../x/"), ("http://h/a/", "/r/./s/../t/"), ("./", "a/"), ("", "")]):
        a(("url_%d" % i, mpd('type="static" mediaPresentationDuration="PT4S"',
                             ('<BaseURL>%s</BaseURL>' % b if b else '') + '<Period>' + as1('<BaseURL>%s</BaseURL><SegmentTemplate duration="2" media="s$Number$.m4s"/>' % r) + '</Period>')))
    # --- segment references against parsed bases (P1-6 fast path must equal RFC 3986 resolution)
    bases = ["http://h/a/b/c/", "http://h", "http://h/a//b/", "../../x/y/", "file.mp4", "urn:a/b", "urn:x", "v/", "https://c/p/?t=1"]
    refs = ["../s$Number$", "../../../../s$Number$", "..//s$Number$", "./s$Number$/.", "s$Number$/..", "a//..",
            "..", "x/../../y$Number$", "?q=$Number$", "#f$Number$", "//other/z$Number$", "/abs/$Number$"]
    for bi, b0 in enumerate(bases):
        a(("refbase_%d" % bi, mpd('type="static" mediaPresentationDuration="PT6S"', '<BaseURL>%s</BaseURL><Period>' % b0 +
                                   "".join(as1('<SegmentTemplate duration="2" media="%s"/>' % r, 'id="r%d" bandwidth="1"' % k)
                                           for k, r in enumerate(refs)) +
                                   as1('<SegmentList><SegmentURL media="../l"/><SegmentURL media="..//l"/><SegmentURL/></SegmentList>', 'id="l" bandwidth="1"') +
                                   '</Period>')))
    # --- DRM / descriptors
    a(("drm_multi", mpd('type="static"', '<Period><AdaptationSet>'
                        '<ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" value="cenc" cenc:default_KID="34e5db32-8625-47cd-ba06-68fca0655a72"/>'
                        '<ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"><cenc:pssh>AAAA</cenc:pssh><cenc:pssh>\n BBBB \n</cenc:pssh></ContentProtection>'
                        '<ContentProtection schemeIdUri="urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95" value="MSPR 2.0"><mspr:pro xmlns:mspr="urn:microsoft:playready">UFJP</mspr:pro></ContentProtection>'
                        '<ContentProtection schemeIdUri="urn:uuid:94ce86fb-07ff-4f43-adb8-93d2fa968ca2"/>'
                        '<Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/><Accessibility schemeIdUri="urn:tva:metadata:cs:AudioPurposeCS:2007" value="1"/>'
                        '<AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="2"/>'
                        '<SupplementalProperty schemeIdUri="urn:x" value="y" id="1"/><EssentialProperty schemeIdUri="urn:e"/>'
                        '<Representation id="v" bandwidth="1"><ContentProtection schemeIdUri="urn:uuid:x"/></Representation></AdaptationSet></Period>')))
    a(("cp_no_scheme", st('', '<AdaptationSet><ContentProtection value="cenc"/></AdaptationSet>')))
    a(("role_no_scheme", st('', '<AdaptationSet><Role value="main"/></AdaptationSet>')))
    a(("utc_timing", mpd('type="dynamic"', '<UTCTiming schemeIdUri="urn:mpeg:dash:utc:http-iso:2014" value="https://time.akamai.com/?iso"/><Location> http://h/m.mpd </Location><Period/>')))
    # --- ABR
    a(("abr_set", st('', '<AdaptationSet codecs="avc1.4d401f"><Representation id="lo" bandwidth="500000"/>'
                         '<Representation id="av1" bandwidth="2000000" codecs="av01.0.08M.08"/><Representation id="mid" bandwidth="1000000"/>'
                         '<Representation id="mid2" bandwidth="1000000"/><Representation id="x10" bandwidth="1500000" codecs="avc10"/>'
                         '<Representation id="hi" bandwidth="3000000" codecs="AVC1.640028"/>'
                         '<Representation id="mux" bandwidth="2500000" codecs="mp4a.40.2, avc1.640028"/>'
                         '<Representation id="hev" bandwidth="4000000" codecs="hev1.1.6.L93.B0,mp4a.40.2"/></AdaptationSet><AdaptationSet/>')))
    a(("rep_no_id", st('', '<AdaptationSet><Representation bandwidth="1"/></AdaptationSet>')))
    a(("rep_empty_id", st('', '<AdaptationSet><Representation id="" bandwidth="1"/></AdaptationSet>')))
    a(("rep_no_bw", st('', '<AdaptationSet><Representation id="v"/></AdaptationSet>')))
    a(("ns_foreign_period", '<MPD %s xmlns:x="urn:x" type="static"><x:Period><AdaptationSet/></x:Period></MPD>' % NS))
    # --- namespaces (Namespaces in XML 1.0) and PlayReady PRO
    R1 = '<Representation id="v" bandwidth="1"/>'
    a(("ns_foreign_attr", '<MPD %s xmlns:x="urn:x" type="static"><Period><AdaptationSet><Representation x:id="evil" id="v" bandwidth="1"/></AdaptationSet></Period></MPD>' % NS))
    a(("ns_custom_prefix", '<m:MPD xmlns:m="urn:mpeg:dash:schema:mpd:2011" type="static"><m:Period id="p"><m:AdaptationSet><m:Representation id="v" bandwidth="1"/></m:AdaptationSet></m:Period></m:MPD>'))
    a(("ns_mixed_default", '<MPD %s type="static"><Period xmlns="urn:other"><AdaptationSet/></Period><Period id="real"/></MPD>' % NS))
    a(("ns_undeclare_default", '<MPD %s type="static"><Period><AdaptationSet xmlns="">%s</AdaptationSet></Period></MPD>' % (NS, R1)))
    a(("ns_unbound_prefix_elem", '<MPD %s type="static"><y:Period/><Period id="ok"/></MPD>' % NS))
    a(("ns_no_default_ns", '<MPD type="static"><Period id="p"><x:AdaptationSet xmlns:x="urn:x"/><AdaptationSet>%s</AdaptationSet></Period></MPD>' % R1))
    a(("ns_dup_expanded_attr", '<MPD %s xmlns:a="urn:q" xmlns:b="urn:q" a:k="1" b:k="2"/>' % NS))
    a(("ns_dup_unbound_attr", '<MPD %s a:k="1" b:k="2"/>' % NS))
    a(("ns_dash_qualified_attr", '<MPD %s xmlns:d="urn:mpeg:dash:schema:mpd:2011" type="static"><Period d:id="qualified"/></MPD>' % NS))
    a(("ns_xml_lang", st('', '<AdaptationSet xml:lang="fr" lang="en"/>')))
    a(("ns_cenc_wrong_uri", '<MPD %s xmlns:cenc="urn:not-cenc" type="static"><Period><AdaptationSet><ContentProtection schemeIdUri="urn:x" cenc:default_KID="k"><cenc:pssh>P</cenc:pssh></ContentProtection></AdaptationSet></Period></MPD>' % NS))
    a(("ns_cenc_other_prefix", '<MPD %s xmlns:c="urn:mpeg:cenc:2013" type="static"><Period><AdaptationSet><ContentProtection schemeIdUri="urn:x" c:default_KID="k"><c:pssh>P</c:pssh></ContentProtection></AdaptationSet></Period></MPD>' % NS))
    a(("ns_cenc_undeclared", '<MPD %s type="static"><Period><AdaptationSet><ContentProtection schemeIdUri="urn:x" cenc:default_KID="k"><cenc:pssh>P</cenc:pssh><pssh>Q</pssh></ContentProtection></AdaptationSet></Period></MPD>' % NS))
    a(("mspr_pro_declared", '<MPD %s xmlns:mspr="urn:microsoft:playready" type="static"><Period><AdaptationSet><ContentProtection schemeIdUri="urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95"><mspr:pro> UFJP </mspr:pro><mspr:pro>Q</mspr:pro><cenc:pssh>S</cenc:pssh></ContentProtection>%s</AdaptationSet></Period></MPD>' % (NS, R1)))
    a(("mspr_pro_other_prefix", '<MPD %s xmlns:pr="urn:microsoft:playready" type="static"><Period><AdaptationSet><ContentProtection schemeIdUri="urn:x"><pr:pro>A</pr:pro></ContentProtection></AdaptationSet></Period></MPD>' % NS))
    a(("dt_24_year_end", mpd('type="dynamic" availabilityStartTime="2024-12-31T24:00:00Z"', '<Period start="PT0S"/>')))
    a(("unknown_elements", mpd('type="static"', '<ProgramInformation><Title>t</Title></ProgramInformation><EventStream schemeIdUri="x"><Event/></EventStream>'
                                '<Period><Foo><AdaptationSet/></Foo><AdaptationSet><Label>l</Label><Representation id="v" bandwidth="1"><SubRepresentation level="0"/></Representation></AdaptationSet></Period>')))
    return c


# ------------------------------------------------------------------ structured random documents

def rand_doc(R):
    def ch(*xs):
        return R.choice(xs)

    def dur():
        if R.random() < 0.04:
            return ch("PT%d,%dS" % (R.randint(1, 9), R.randint(0, 9)), "P1W", "-PT1S", "PT1.5M")
        return ch("PT%dS" % R.randint(1, 60), "PT%d.%dS" % (R.randint(0, 30), R.randint(0, 999999)), "PT1M%dS" % R.randint(0, 59),
                  "PT%dH" % R.randint(0, 2), "P0DT%dS" % R.randint(1, 30), "PT%dM" % R.randint(1, 3),
                  "P1DT%dH" % R.randint(0, 5))

    def dt():
        y = R.randint(1999, 2030)
        mo = R.randint(1, 12)
        d = R.randint(1, 31 if R.random() < 0.05 else 28)
        odd = R.random() < 0.08
        return "%04d-%02d-%02dT%02d:%02d:%02d%s%s" % (
            y, mo, d, R.randint(0, 24 if odd else 23), R.randint(0, 59), R.randint(0, 59),
            ch("", ".5", ".123456", ".1234567"),
            ch("", "+15:00", "z", "+14:00") if odd else ch("Z", "Z", "+01:00", "-05:30", "+14:00"))

    def num(lo, hi):
        v = str(R.randint(lo, hi))
        return "+" + v if R.random() < 0.03 else ch(v, v, v, " %s " % v)

    def url_part():
        return ch("", "seg/", "v%d/" % R.randint(1, 9), "../", "./", ".", "..", "../up/", "a//b/", "?tok=%d" % R.randint(1, 99),
                  "x/?q=1", "#frag", "/abs/", "http://cdn%d.example/p/" % R.randint(1, 3), "//edge.example/z/",
                  "https://cdn.example/a/b/c?x=1&amp;y=2", "media/../m/", "a/./b/")

    def tmpl():
        return ch("$RepresentationID$/$Number$.m4s", "seg_$Number%05d$.m4s", "$Time$.m4s", "t_$Time%010d$_$Bandwidth$.mp4",
                  "c$$$Number$", "chunk-$RepresentationID$-$Number%03d$.m4s?k=1", "$Number%d$", "$Bandwidth$/$Time$")

    def seginfo(level):
        k = R.random()
        if k < 0.35:
            ts = ch(1, 10, 1000, 90000, 48000, 3)
            dd = max(1, int(ts * ch(1, 2, 4, 6, 0.5)))
            return '<SegmentTemplate timescale="%d" duration="%d"%s%s%s/>' % (
                ts, dd, ' startNumber="%s"' % (num(0, 5) if R.random() < 0.85 else ch("9223372036854775806", "9223372036854775807")) if R.random() < 0.6 else "",
                ' media="%s"' % tmpl() if (level == "R" or R.random() < 0.7) else "",
                ' initialization="init_$RepresentationID$.mp4"' if R.random() < 0.6 else "")
        if k < 0.65:
            ts = ch(1, 10, 1000, 90000)
            pto = ch(0, 0, ts * 100, ts * R.randint(1, 5))
            t0 = pto if R.random() < 0.7 else 0
            ss = []
            for i in range(R.randint(1, 4)):
                d = ts * R.randint(1, 4) // ch(1, 2)
                d = max(d, 1)
                r = ch(0, 0, 1, 2, -1, R.randint(0, 5), -2)
                t = ' t="%d"' % t0 if (i == 0 and R.random() < 0.7) or R.random() < 0.2 else ""
                ss.append('<S%s d="%d"%s/>' % (t, d, ' r="%d"' % r if r else ""))
                t0 += d * (max(r, 0) + 1)
            return '<SegmentTemplate timescale="%d"%s media="%s"%s><SegmentTimeline>%s</SegmentTimeline></SegmentTemplate>' % (
                ts, ' presentationTimeOffset="%d"' % pto if pto else "", tmpl(),
                ' startNumber="%s"' % num(0, 9) if R.random() < 0.4 else "", "".join(ss))
        if k < 0.85:
            urls = "".join('<SegmentURL media="s%d.m4s"%s/>' % (i, ' mediaRange="%d-%d"' % (i * 100, i * 100 + 99) if R.random() < 0.4 else "")
                           for i in range(R.randint(0, 5)))
            return '<SegmentList timescale="%d" duration="%d"%s>%s%s</SegmentList>' % (
                ch(1, 1000), R.randint(1, 5000), ' startNumber="%s"' % num(0, 3) if R.random() < 0.5 else "",
                '<Initialization sourceURL="init.mp4"/>' if R.random() < 0.5 else ('<Initialization range="0-99"/>' if R.random() < 0.3 else ""), urls)
        return '<SegmentBase timescale="%d" indexRange="%d-%d"%s>%s</SegmentBase>' % (
            ch(1, 1000, 48000), 100, R.randint(200, 999), ' indexRangeExact="%s"' % ch("true", "false", "1", "0") if R.random() < 0.5 else "",
            '<Initialization range="0-99"/>' if R.random() < 0.6 else "")

    def baseurl():
        return '<BaseURL>%s</BaseURL>' % url_part() if R.random() < 0.6 else ""

    def cp():
        return ch('<ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" value="cenc" cenc:default_KID="%08x-0000-4000-8000-000000000000"/>' % R.randint(0, 1 << 31),
                  '<ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"><cenc:pssh>AAAA%dBB==</cenc:pssh></ContentProtection>' % R.randint(0, 99),
                  '<ContentProtection schemeIdUri="urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95" value="MSPR 2.0"><cenc:pssh> P%d </cenc:pssh><cenc:pssh>Q</cenc:pssh></ContentProtection>' % R.randint(0, 9),
                  '<ContentProtection schemeIdUri="urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95" value="MSPR 2.0"><mspr:pro xmlns:mspr="urn:microsoft:playready">PRO%d=</mspr:pro></ContentProtection>' % R.randint(0, 9))

    codecs = ["avc1.4d401f", "avc1.640028", "av01.0.08M.08", "hvc1.1.6.L93.B0", "hev1.2.4.L120", "mp4a.40.2", "ec-3", "vp09.00.10.08",
              "mp4a.40.2,avc1.64001f", "avc1.4d401e, mp4a.40.5", "AVC1.42E01E", "avc10", "opus"]

    def rep(i):
        attrs = ['id="%s"' % ch("v%d" % i, "r%d" % i, "a&amp;%d" % i, "id %d" % i, "x\t%d" % i, "&#x41;%d" % i), 'bandwidth="%s"' % ch(
            str(R.randint(1, 9) * 10 ** R.randint(4, 7)), str(R.randint(100000, 9000000)),
            "+%d" % R.randint(1, 99999) if R.random() < 0.02 else "%d" % R.randint(1, 99999))]
        if R.random() < 0.5:
            attrs.append('width="%s" height="%s"' % (ch("1920", "1280", "640", "0" if R.random() < 0.1 else "854"), ch("1080", "720", "360")))
        if R.random() < 0.4:
            attrs.append('frameRate="%s"' % ch("30", "25", "30000/1001", "60", "24000/1001"))
        if R.random() < 0.6:
            attrs.append('codecs="%s"' % ch(*codecs))
        if R.random() < 0.2:
            attrs.append('mimeType="video/mp4" sar="1:1" startWithSAP="%s" audioSamplingRate="48000"' % ch("1", "2"))
        inner = baseurl() + (cp() if R.random() < 0.15 else "") + (seginfo("R") if R.random() < 0.7 else "")
        return '<Representation %s>%s</Representation>' % (" ".join(attrs), inner)

    def aset(i):
        attrs = []
        if R.random() < 0.7:
            attrs.append('id="%d"' % i)
        if R.random() < 0.5:
            attrs.append('contentType="%s"' % ch("video", "audio", "text", "image", "Video", "foo"))
        if R.random() < 0.4:
            attrs.append('mimeType="%s" codecs="%s"' % (ch("video/mp4", "audio/mp4"), ch(*codecs)))
        if R.random() < 0.3:
            attrs.append('segmentAlignment="%s" lang="%s"' % (ch("true", "1", "false"), ch("en", "fr-CA", "und")))
        if R.random() < 0.2:
            attrs.append('minBandwidth="1" maxBandwidth="%s" maxWidth="1920" maxHeight="1080" par="16:9" frameRate="%s"' % (num(1000, 9000000), ch("30", "60/2")))
        inner = baseurl()
        if R.random() < 0.3:
            inner += '<Role schemeIdUri="urn:mpeg:dash:role:2011" value="%s"/>' % ch("main", "alternate")
        for _ in range(R.choice((0, 0, 1, 2, 3))):
            inner += cp()
        if R.random() < 0.15:
            inner += '<AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="2"/>'
        if R.random() < 0.3:
            inner += seginfo("A")
        inner += "".join(rep(k) for k in range(R.randint(0, 4)))
        return '<AdaptationSet%s>%s</AdaptationSet>' % ("".join(" " + x for x in attrs), inner)

    dyn = R.random() < 0.25
    mattrs = ['type="%s"' % ("dynamic" if dyn else "static")]
    if not dyn or R.random() < 0.3:
        mattrs.append('mediaPresentationDuration="%s"' % dur())
    if dyn or R.random() < 0.2:
        mattrs.append('availabilityStartTime="%s"' % dt())
    if R.random() < 0.3:
        mattrs.append('minBufferTime="%s" profiles="urn:mpeg:dash:profile:isoff-live:2011"' % dur())
    if R.random() < 0.1:
        mattrs.append('publishTime="%s"' % dt())
    body = baseurl()
    nper = R.choice((1, 1, 1, 2, 3))
    for pi in range(nper):
        pa = []
        if R.random() < 0.5:
            pa.append('start="%s"' % ch("PT0S", "PT%dS" % R.randint(1, 20), dur()))
        if R.random() < 0.3:
            pa.append('duration="%s"' % dur())
        if R.random() < 0.5:
            pa.append('id="p%d"' % pi)
        pin = baseurl() + (seginfo("P") if R.random() < 0.2 else "") + "".join(aset(k) for k in range(R.randint(0, 3)))
        body += '<Period%s>%s</Period>' % ("".join(" " + x for x in pa), pin)
    doc = mpd(" ".join(mattrs), body)
    if R.random() < 0.2:
        doc = '<?xml version="1.0" encoding="UTF-8"?>\n' + doc
    if R.random() < 0.15:
        doc = doc.replace("><", ">\n  <")
    return doc


TOKENS = [b"<", b">", b"&", b"&amp;", b"]]>", b"<!--x-->", b"<![CDATA[y]]>", b"<?xml version=\"1.0\"?>", b"<?p q?>", b"\x01",
          b"\xff", b"\xef\xbf\xbe", "é".encode(), "×".encode(), "中".encode(), b"&#0;", b"&#x10FFFF;", b"&#X41;",
          b"<!DOCTYPE x>", b'"', b"'", b"=", b"/>", b"</X>", b' a="1"', b"\t", b"\r", b"\r\n", b"-1", b"99999999999999999999",
          b"P", b"T", b"+", b"0", b"$", b"$$", b"%05d", b"..", b"/", b"<S d=\"1\" r=\"-1\"/>", b"<Period/>", b"&lt;", b"&#10;"]


def mutate(R, b):
    b = bytearray(b)
    for _ in range(R.choice((1, 1, 1, 2, 3))):
        if not b:
            break
        k = R.random()
        i = R.randrange(len(b))
        if k < 0.25:
            j = min(len(b), i + R.randint(1, 8))
            del b[i:j]
        elif k < 0.4:
            j = min(len(b), i + R.randint(1, 40))
            b[i:i] = b[i:j]
        elif k < 0.85:
            b[i:i] = R.choice(TOKENS)
        else:
            # replace an attribute value
            q = b.find(b'"', i)
            if q >= 0:
                e = b.find(b'"', q + 1)
                if e > q:
                    b[q + 1:e] = R.choice(TOKENS + [b"", b"PT1S", b"5", b"true", b"x/y", b"2024-01-01T00:00:00Z"])
    return bytes(b)


def api_vectors(R):
    v = []
    for s in ["PT0S", "PT1H2M3.5S", "P1Y2M3DT4H5M6.123456S", "P1W", "PT0.0000019S", "PT1,5S", "-PT1S", "P", "PT", "P1DT", "PT1.5M",
              "PT1.5H", "P1.5D", "P1M", "PT1M", "PT36H", "P2W3D", "PT9223372036854.775807S", "PT9223372036854.775808S", "PT9223372036855S",
              " PT1S ", "pt1s", "PT1S2M", "P1Y1Y", "P292471Y", "P292472Y", "PT.5S", "PT1.S", "P1H", "PTS", "P1DT1H1M1.999999999S",
              "P0Y0M0W0DT0H0M0S", "PT0001S", "Pé", "PT1S\x00", "P1W1D", "P1D1W"]:
        v.append("DUR\t" + s.encode().hex())
    for s in ["1970-01-01T00:00:00Z", "2024-02-29T12:00:00Z", "2023-02-29T00:00:00Z", "1900-02-29T00:00:00Z", "2000-02-29T00:00:00Z",
              "2024-01-01T00:00:00", "2024-01-01T24:00:00Z", "2024-01-01T24:00:00.000Z", "2024-01-01T24:00:01Z", "2024-01-01T00:00:60Z",
              "2024-01-01T00:00:00+14:00", "2024-01-01T00:00:00+14:01", "2024-01-01T00:00:00+23:59", "2024-01-01T00:00:00-05:30",
              "2024-01-01T00:00:00+0530", "2024-01-01T00:00:00+05", "2024-01-01t00:00:00z", "2024-01-01T00:00:00.123456789Z",
              "1969-12-31T23:59:59Z", "0000-01-01T00:00:00Z", "9999-12-31T23:59:59.999999Z", "2024-01-01T00:00:00.Z",
              "2024-13-01T00:00:00Z", "2024-01-01T00:00:00Zx", "2024-1-01T00:00:00Z", "2024-04-31T00:00:00Z", "2024-01-01 00:00:00Z",
              "+2024-01-01T00:00:00Z", "12024-01-01T00:00:00Z", "2024-01-01T00:00Z"]:
        v.append("DT\t" + s.encode().hex())
    for s in ["30", "30000/1001", "0", "30/0", "29.97", "+30", "1/2/3", "/2", "2/", "", "-30", "9223372036854775807",
              "9223372036854775808", " 25 ", "60/1", "1/9223372036854775807"]:
        v.append("RAT\t" + s.encode().hex())
    for x in [0, 1, -1, 999999, 1000000, 3723500000, 86400000000, 31536000000000, 9223372036854775807, -9223372036854775808, 60000000, 3599999999]:
        v.append("FDUR\t%d" % x)
    urls = [("http://a/b/c/d;p?q", r) for r in ["g", "./g", "g/", "/g", "//g", "?y", "g?y", "#s", "g#s", "g?y#s", ";x", "g;x", "", ".", "./",
                                              "..", "../", "../g", "../..", "../../", "../../g", "../../../g", "/./g", "/../g", "g.", ".g",
                                              "g..", "..g", "./../g", "./g/.", "g/./h", "g/../h", "g;x=1/./y", "g;x=1/../y", "g?y/./x",
                                              "g#s/../x", "http:g", "x//y", "x//../y"]]
    urls += [("http://h/a?q=1", "#f"), ("http://h/a/b", "http://g/x/../y"), ("../media/", "seg.m4s"), ("video/../../x/", "s.m4s"),
             ("a/b", "../../../c"), ("a/./b/", "./c/."), ("", "x"), ("x", ""), ("http://h", "y"), ("http://h", "?q"), ("//cdn/p/", "q"),
             ("https://cdn/p/?token=abc", "seg.m4s"), ("urn:x:y", "z"), ("file:///a/b", "../c")]
    for _ in range(150):
        segs = ["a", "b", ".", "..", "", "c.m4s", "?q", "#f", "x=1"]
        b = R.choice(["http://h", "https://c.example", "", "//e"]) + "/" + "/".join(R.choice(segs) for _ in range(R.randint(0, 4)))
        if R.random() < 0.3:
            b = "/".join(R.choice(segs) for _ in range(R.randint(1, 3)))
        r = "/".join(R.choice(segs) for _ in range(R.randint(1, 4)))
        urls.append((b, r))
    for b, r in urls:
        v.append("URL\t%s\t%s" % (b.encode().hex(), r.encode().hex()))
    tps = ["$RepresentationID$/$Number$-$Bandwidth$-$Time$.m4s", "$Number%05d$_$Time%012d$_$Bandwidth%2d$", "a$$b$$$Number$", "$Number%032d$",
           "$Number%033d$", "$Number%999999999d$", "$Time%x$", "$Number%05x$", "$Foo$", "$Number", "a$", "$RepresentationID%05d$",
           "$Number%-5d$", "$SubNumber$", "$Number%d$", "$Number%00005d$", "$$", "", "$$$$", "$Number%0d$", "$Time$$Time$", "$number$"]
    for t in tps:
        for (n, bw, tm) in ((7, 500, 90000), (-5, 1, 0), (9223372036854775807, 9223372036854775807, 9223372036854775807), (0, 0, 0)):
            v.append("TPL\t%s\t%s\t%d\t%d\t%d" % (t.encode().hex(), "v1".encode().hex(), n, bw, tm))
    v.append("TPL\t%s\t%s\t1\t1\t1" % ("$RepresentationID$".encode().hex(), "a$b".encode().hex()))
    return v


def main():
    out = sys.argv[1]
    n = int(sys.argv[2])
    os.makedirs(out, exist_ok=True)
    R = random.Random(23009)
    nm = named()
    with open(os.path.join(out, "named.cases"), "w") as f:
        for name, d in nm:
            b = d if isinstance(d, bytes) else d.encode("utf-8")
            f.write("%s\t%s\n" % (name, b.hex()))
    seeds = []
    with open(os.path.join(out, "fuzz.cases"), "w") as f:
        k = 0
        while k < n:
            if k % 3 == 0 or not seeds:
                d = rand_doc(R).encode("utf-8")
                seeds.append(d)
                name = "seed_%d" % k
            else:
                d = mutate(R, R.choice(seeds + [x if isinstance(x, bytes) else x.encode() for _, x in nm]))
                name = "mut_%d" % k
            f.write("%s\t%s\n" % (name, d.hex()))
            k += 1
    av = api_vectors(R)
    with open(os.path.join(out, "api.vec"), "w") as f:
        f.write("\n".join(av) + "\n")
    print(len(nm), n, len(av))


if __name__ == "__main__":
    main()
