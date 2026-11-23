"""Spec-graded differential vectors for packages/feed (Pion) vs feed-rs =2.4.0.

Each vector: (id, finding, input, [(key, expected), ...]).
  * finding: REPORT.md id (P1-1 ...) or "ctl" (control, currently passes) or "info" (not graded).
  * key: a key of the canonical dump (audit/probe == audit/oracle/rust), e.g. "e0.title", "feed.logo".
  * expected: the value the cited spec requires, as the dump prints it ("-" = absent, "err" key = error
    kind), a callable(value) -> bool, or None (not graded: print both implementations only).
Grading is Pion vs the spec expectation; feed-rs is printed as the reference implementation.
"""
import calendar
import xml.parsers.expat

ATOM = "http://www.w3.org/2005/Atom"


def wellformed_fragment(v):
    v = v.replace("\\n", "\n").replace("\\t", "\t").replace("\\\\", "\\")
    p = xml.parsers.expat.ParserCreate()
    try:
        p.Parse("<r>" + v + "</r>", True)
        return True
    except xml.parsers.expat.ExpatError:
        return False


wellformed_fragment.__name__ = "<well-formed XML fragment>"


def xhtml_kept(v):
    # wrapper div unwrapped, markup / entities / attributes kept, still a well-formed fragment
    # (namespace declarations may legitimately be re-emitted by a fix for P2-6, so no exact match)
    return (wellformed_fragment(v) and not v.startswith("<div") and "<em" in v and ">x</em> &amp; <a " in v
            and 'href="h?a=1&amp;b=2"' in v and "<br" in v)


xhtml_kept.__name__ = "<xhtml body kept, well-formed>"


def rss_item(inner, ns="", chan=""):
    return '<rss version="2.0"%s><channel><title>t</title>%s<item><guid>g</guid>%s</item></channel></rss>' % (ns, chan, inner)


def atom(inner, base=""):
    b = ' xml:base="%s"' % base if base else ""
    return '<feed xmlns="%s"%s><id>f</id>%s</feed>' % (ATOM, b, inner)


V = []

# ---- P1-1 namespace-blind dispatch -----------------------------------------------------------------
V += [
    ("ns_slash_comments", "P1-1",
     rss_item("<comments>https://ex.com/p/1#comments</comments><slash:comments>12</slash:comments>",
              ' xmlns:slash="http://purl.org/rss/1.0/modules/slash/"'),
     [("e0.comments", "https://ex.com/p/1#comments")]),
    ("ns_googleplay_image", "P1-1",
     '<rss version="2.0" xmlns:googleplay="http://www.google.com/schemas/play-podcasts/1.0"><channel><title>t</title>'
     '<image><url>https://ex.com/logo.png</url><title>t</title><link>https://ex.com/</link></image>'
     '<googleplay:image href="https://ex.com/gp.png"/></channel></rss>',
     [("feed.logo", "https://ex.com/logo.png")]),
    ("ns_podcast_image_channel", "P1-1",
     '<rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>t</title>'
     '<image><url>https://ex.com/logo.png</url><title>t</title><link>https://ex.com/</link></image>'
     '<podcast:image href="https://ex.com/p.png" width="1400"/></channel></rss>',
     [("feed.logo", "https://ex.com/logo.png")]),
    ("ns_media_title_channel", "P1-1",
     '<rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"><channel><title>Real</title>'
     '<media:title>Fake</media:title><description>D</description><media:description>FakeD</media:description></channel></rss>',
     [("feed.title", "Real"), ("feed.desc", "D")]),
    ("ns_googleplay_description_item", "P1-1",
     rss_item("<description>D</description><googleplay:description>G</googleplay:description>",
              ' xmlns:googleplay="http://www.google.com/schemas/play-podcasts/1.0"'),
     [("e0.summary", "D")]),
    ("ns_atom_foreign_id_title", "P1-1",
     '<feed xmlns="%s" xmlns:x="urn:x" xmlns:dc="http://purl.org/dc/elements/1.1/"><id>urn:feed</id><x:id>evil-feed</x:id>'
     '<title>T</title><dc:title>DC</dc:title><entry><id>urn:e</id><x:id>evil</x:id><title>E</title><dc:title>DC</dc:title>'
     '<author><name>Alice</name><x:name>Mallory</x:name></author></entry></feed>' % ATOM,
     [("feed.id", "urn:feed"), ("feed.title", "T"), ("e0.id", "urn:e"), ("e0.title", "E"), ("e0.author.0", "Alice|-|-")]),
    ("ns_atom_dc_rights", "P1-1",
     atom('<entry><id>e</id><title>E</title><dc:rights xmlns:dc="http://purl.org/dc/elements/1.1/">R</dc:rights></entry>'),
     [("e0.rights", "-")]),
]

# ---- P1-2 DOCTYPE -----------------------------------------------------------------------------------
V += [
    ("doctype_netscape_091", "P1-2",
     '<?xml version="1.0"?>\n<!DOCTYPE rss PUBLIC "-//Netscape Communications//DTD RSS 0.91//EN" '
     '"http://my.netscape.com/publish/formats/rss-0.91.dtd">\n<rss version="0.91"><channel><title>T</title>'
     '<item><title>I</title><link>http://x/1</link></item></channel></rss>',
     [("err", "-"), ("feed.title", "T"), ("n", "1")]),
    ("doctype_simple", "P1-2", '<!DOCTYPE rss><rss version="2.0"><channel><title>T</title></channel></rss>',
     [("err", "-"), ("feed.title", "T")]),
]

# ---- P1-3 RSS description is HTML ---------------------------------------------------------------------
V += [
    ("rss_description_html", "P1-3",
     '<rss version="2.0"><channel><title>t</title><description>&lt;b&gt;D&lt;/b&gt;</description>'
     '<item><guid>g</guid><description>&lt;p&gt;hi&lt;/p&gt;</description></item></channel></rss>',
     [("e0.summary", "<p>hi</p>"), ("e0.summary.t", "html"), ("feed.desc.t", None)]),
]

# ---- P1-4 JSON numeric id ----------------------------------------------------------------------------
V += [
    ("json_numeric_id", "P1-4",
     '{"version":"https://jsonfeed.org/version/1.1","title":"t","items":[{"id":123,"content_text":"a"}]}',
     [("e0.id", "123")]),
]

# ---- P2-1 Atom link rel default ----------------------------------------------------------------------
V += [
    ("atom_link_rel_default", "P2-1", atom('<link href="http://x/"/><entry><id>e</id><link href="http://x/1"/></entry>'),
     [("feed.link.0", "http://x/|alternate|-|-"), ("e0.link.0", "http://x/1|alternate|-|-")]),
    ("rss_atom_link_rel_default", "P2-1",
     rss_item('<atom:link href="http://x/2"/>', ' xmlns:atom="%s"' % ATOM),
     [("e0.link.0", "http://x/2|alternate|-|-")]),
]

# ---- P2-2 RFC 3986 (all §5.4 examples, graded; three extra empty-segment / net-path rows) -------------
RFC3986 = [
    ("g:h", "g:h"), ("g", "http://a/b/c/g"), ("./g", "http://a/b/c/g"), ("g/", "http://a/b/c/g/"), ("/g", "http://a/g"),
    ("//g", "http://g"), ("?y", "http://a/b/c/d;p?y"), ("g?y", "http://a/b/c/g?y"), ("#s", "http://a/b/c/d;p?q#s"),
    ("g#s", "http://a/b/c/g#s"), ("g?y#s", "http://a/b/c/g?y#s"), (";x", "http://a/b/c/;x"), ("g;x", "http://a/b/c/g;x"),
    ("g;x?y#s", "http://a/b/c/g;x?y#s"), ("", "http://a/b/c/d;p?q"), (".", "http://a/b/c/"), ("./", "http://a/b/c/"),
    ("..", "http://a/b/"), ("../", "http://a/b/"), ("../g", "http://a/b/g"), ("../..", "http://a/"), ("../../", "http://a/"),
    ("../../g", "http://a/g"), ("../../../g", "http://a/g"), ("../../../../g", "http://a/g"), ("/./g", "http://a/g"),
    ("/../g", "http://a/g"), ("g.", "http://a/b/c/g."), (".g", "http://a/b/c/.g"), ("g..", "http://a/b/c/g.."),
    ("..g", "http://a/b/c/..g"), ("./../g", "http://a/b/g"), ("./g/.", "http://a/b/c/g/"), ("g/./h", "http://a/b/c/g/h"),
    ("g/../h", "http://a/b/c/h"), ("g;x=1/./y", "http://a/b/c/g;x=1/y"), ("g;x=1/../y", "http://a/b/c/y"),
    ("g?y/./x", "http://a/b/c/g?y/./x"), ("g?y/../x", "http://a/b/c/g?y/../x"), ("g#s/./x", "http://a/b/c/g#s/./x"),
    ("g#s/../x", "http://a/b/c/g#s/../x"), ("http:g", "http:g"),
]
for i, (r, want) in enumerate(RFC3986):
    V.append(("rfc3986_%02d" % i, "ctl", atom('<link rel="related" href="%s"/>' % r, "http://a/b/c/d;p?q"),
              [("feed.link.0", want + "|related|-|-")]))
for i, (r, want) in enumerate([("g//h", "http://a/b/c/g//h"), ("/a//b/../c", "http://a/a//c"), ("//h/p/../q", "http://h/q")]):
    V.append(("rfc3986_x%d" % i, "P2-2", atom('<link rel="related" href="%s"/>' % r, "http://a/b/c/d;p?q"),
              [("feed.link.0", want + "|related|-|-")]))
V.append(("xml_base_nested", "ctl",
          atom('<entry xml:base="b/"><id>e</id><link rel="related" xml:base="c/" href="d.html"/>'
               '<author xml:base="/root/"><name>n</name><uri>me</uri></author></entry>', "http://ex.com/a/"),
          [("e0.link.0", "http://ex.com/a/b/c/d.html|related|-|-"), ("e0.author.0", "n|-|http://ex.com/root/me")]))

# ---- P2-3 element-level xml:base on icon/logo ---------------------------------------------------------
V.append(("atom_icon_own_base", "P2-3",
          atom('<icon xml:base="http://cdn.com/i/">fav.ico</icon><logo xml:base="/img/">l.png</logo>', "http://ex.com/a/"),
          [("feed.icon", "http://cdn.com/i/fav.ico"), ("feed.logo", "http://ex.com/img/l.png")]))

# ---- P2-4 integer parsing ----------------------------------------------------------------------------
V.append(("enclosure_lengths", "P2-4",
          rss_item('<enclosure url="http://x/a.mp3" length="9999999999999999999" type="audio/mpeg"/>'
                   '<enclosure url="http://x/b.mp3" length="-5" type="audio/mpeg"/>'
                   '<enclosure url="http://x/c.mp3" length="12345" type="audio/mpeg"/>'),
          [("e0.link.0", "http://x/a.mp3|enclosure|audio/mpeg|-"), ("e0.link.1", "http://x/b.mp3|enclosure|audio/mpeg|-"),
           ("e0.link.2", "http://x/c.mp3|enclosure|audio/mpeg|12345")]))
ITUNES = ' xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"'
for i, (d, want, tag) in enumerate([("3600", "3600", "ctl"), ("1:00:00", "3600", "ctl"), ("59:00", "3540", "ctl"),
                                    (" 10:05 ", "605", "ctl"), ("1:2:3:4", "-", "ctl"), ("abc", "-", "ctl"),
                                    ("-5", "-", "P2-4"), ("00:-30", "-", "P2-4"),
                                    ("9223372036854775807:00:00", "-", "P2-4")]):
    V.append(("itunes_duration_%d" % i, tag, rss_item("<itunes:duration>%s</itunes:duration>" % d, ITUNES),
              [("e0.itunes.duration", want)]))

# ---- dates (RFC 2822 §3.3/§4.3, RFC 3339 §5.6) ----------------------------------------------------------
T = calendar.timegm((2026, 11, 23, 12, 0, 0))
DATES = [
    ("Mon, 23 Nov 2026 12:00:00 GMT", T, "ctl"), ("Mon, 23 Nov 26 12:00:00 GMT", T, "ctl"),
    ("Wed, 23 Nov 49 12:00:00 GMT", calendar.timegm((2049, 11, 23, 12, 0, 0)), "ctl"),
    ("Tue, 23 Nov 50 12:00:00 GMT", calendar.timegm((1950, 11, 23, 12, 0, 0)), "ctl"),
    ("23 Nov 099 12:00:00 GMT", calendar.timegm((1999, 11, 23, 12, 0, 0)), "ctl"),
    ("Tue, 29 Feb 2000 00:00:00 GMT", calendar.timegm((2000, 2, 29, 0, 0, 0)), "ctl"),
    ("Thu, 29 Feb 1900 00:00:00 GMT", None, "ctl"), ("31 Feb 2026 00:00:00 GMT", None, "ctl"),
    ("32 Jan 2026 00:00:00 GMT", None, "ctl"), ("23 Nov 2026 25:00:00 GMT", None, "ctl"),
    ("23 Nov 2026 12:00:00 +0530", T - 19800, "ctl"), ("23 Nov 2026 12:00:00 -0000", T, "ctl"),
    ("23 Nov 2026 12:00:00 +2400", None, "P2-5"), ("23 Nov 2026 12:00:00 +2359", T - 86340, "ctl"),
    ("23 Nov 2026 12:00:00 EST", T + 5 * 3600, "ctl"), ("23 Nov 2026 12:00:00 EDT", T + 4 * 3600, "ctl"),
    ("23 Nov 2026 12:00:00 CST", T + 6 * 3600, "ctl"), ("23 Nov 2026 12:00:00 CDT", T + 5 * 3600, "ctl"),
    ("23 Nov 2026 12:00:00 MST", T + 7 * 3600, "ctl"), ("23 Nov 2026 12:00:00 MDT", T + 6 * 3600, "ctl"),
    ("23 Nov 2026 12:00:00 PST", T + 8 * 3600, "ctl"), ("23 Nov 2026 12:00:00 PDT", T + 7 * 3600, "ctl"),
    ("23 Nov 2026 12:00:00 UT", T, "ctl"), ("23 Nov 2026 12:00:00 Z", T, "ctl"),
    ("23 Nov 2026 12:00:00 A", T, "ctl"),        # RFC 2822 §4.3: military zones SHOULD be read as -0000
    ("23 Nov 2026 12:00:00 XYZ", T, "ctl"),      # RFC 2822 §4.3: unknown alphabetic zones -> -0000
    ("Mon, 23 Nov 2026 12:00:00 -0800 (PST)", T + 8 * 3600, "ctl"),
    ("Mon, 23 Nov 2026 12:00 GMT", T, "ctl"), ("  Mon,   23   Nov   2026   12:00:00   GMT  ", T, "ctl"),
    ("Monday, 23 November 2026 12:00:00 GMT", T, "ctl"), ("23 Nov 2026 12:00:60 GMT", T + 59, "ctl"),
    ("Mon, 23 Nov 2026 12:00:00 GMT garbage", "?", "info"), ("Mon, 23 Nov 2026", "?", "info"),
    ("2026-11-23T12:00:00Z", T, "ctl"), ("2026-11-23t12:00:00z", T, "ctl"), ("2026-11-23 12:00:00Z", T, "ctl"),
    ("2026-11-23T12:00:00.123456789123Z", T, "ctl"), ("2026-11-23T12:00:60Z", T + 59, "ctl"),
    ("2026-11-23", T - 12 * 3600, "ctl"), ("2026-11-23T12:00:00+0800", T - 8 * 3600, "ctl"),
    ("2026-11-23T12:00:00+08", "?", "info"), ("2026-11-23T12:00Z", "?", "info"), ("2026-11-23T12:00:00", "?", "info"),
    ("2026-11-23T24:00:00Z", None, "ctl"), ("2026-02-30T00:00:00Z", None, "ctl"),
    ("2026-11-23T12:00:00+24:00", None, "P2-5"), ("2026-11-23T12:00:00+2400", None, "P2-5"),
    ("10000-01-01T00:00:00Z", None, "ctl"), ("2026-11-23T12:00:00Zjunk", None, "ctl"),
]
for i, (d, want, tag) in enumerate(DATES):
    exp = None if want == "?" else ("-" if want is None else str(want))
    V.append(("date_%02d" % i, tag, rss_item("<pubDate>%s</pubDate>" % d), [("e0.published", exp)]))

# ---- detection / encoding / strictness controls --------------------------------------------------------
V += [
    ("bom_utf8_rss", "ctl", b"\xef\xbb\xbf" + b'<?xml version="1.0"?><rss version="2.0"><channel><title>T</title></channel></rss>',
     [("fmt", "rss2"), ("feed.title", "T")]),
    ("bom_utf8_json", "ctl", b'\xef\xbb\xbf{"version":"https://jsonfeed.org/version/1","title":"T","items":[]}',
     [("fmt", "json_feed"), ("feed.title", "T")]),
    ("comment_pi_prolog", "ctl",
     '<?xml version="1.0"?><!-- c --><?xml-stylesheet href="s.xsl" type="text/xsl"?><rss version="2.0"><channel><title>T</title></channel></rss>',
     [("feed.title", "T")]),
    ("prefixed_atom", "ctl", '<a:feed xmlns:a="%s"><a:id>f</a:id><a:title>T</a:title><a:entry><a:id>e</a:id></a:entry></a:feed>' % ATOM,
     [("fmt", "atom"), ("feed.title", "T"), ("e0.id", "e")]),
    ("prefixed_rdf", "ctl",
     '<r:RDF xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/"><channel r:about="http://x/">'
     '<title>T</title><link>http://x/</link></channel><item r:about="http://x/1"><title>I</title><link>http://x/1</link></item></r:RDF>',
     [("fmt", "rss1"), ("e0.title", "I")]),
    ("rss091", "ctl", '<rss version="0.91"><channel><title>T</title><item><title>I</title><link>http://x/</link></item></channel></rss>',
     [("fmt", "rss2"), ("n", "1")]),
    ("guid_permalink", "ctl", rss_item("", chan='<item><guid isPermaLink="false">tag:x,2026:2</guid></item>'),
     [("e0.permalink", "false"), ("e0.id", "tag:x,2026:2"), ("e1.permalink", "true")]),
    ("multi_category_domain", "ctl", rss_item('<category domain="http://d/">a</category><category>b</category>'),
     [("e0.cat.n", "2"), ("e0.cat.0", "a|http://d/|-"), ("e0.cat.1", "b|-|-")]),
    ("content_encoded_cdata", "ctl",
     rss_item("<description>S</description><content:encoded><![CDATA[<p>B &amp; ]]]]><![CDATA[>]]></content:encoded>",
              ' xmlns:content="http://purl.org/rss/1.0/modules/content/"'),
     [("e0.content", "<p>B &amp; ]]>"), ("e0.content.t", "html"), ("e0.summary", "S")]),
    ("atom_html_once", "ctl", atom('<entry><id>e</id><title type="html">AT&amp;amp;T &amp;lt;b&amp;gt;</title>'
                                   '<summary type="text">&lt;b&gt;</summary></entry>'),
     [("e0.title", "AT&amp;T &lt;b&gt;"), ("e0.title.t", "html"), ("e0.summary", "<b>"), ("e0.summary.t", "text")]),
    ("xhtml_default_ns", "ctl", atom('<entry><id>e</id><content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">'
                                     '<p>Hi <em>x</em> &amp; <a href="h?a=1&amp;b=2">l</a><br/></p></div></content></entry>'),
     [("e0.content", xhtml_kept), ("e0.content.t", "xhtml")]),
    ("xhtml_prefixed", "P2-6", atom('<entry><id>e</id><content type="xhtml"><xh:div xmlns:xh="http://www.w3.org/1999/xhtml">'
                                    '<xh:p>Hi <xh:b>B</xh:b></xh:p></xh:div></content></entry>'),
     [("e0.content", wellformed_fragment)]),
    ("json_strict_comment", "ctl", '{"version":"https://jsonfeed.org/version/1.1",/*c*/"title":"T","items":[]}', [("err", "JsonError")]),
    ("json_strict_trailing_comma", "ctl", '{"version":"https://jsonfeed.org/version/1.1","title":"T","items":[],}', [("err", "JsonError")]),
    ("json_strict_single_quote", "ctl", "{'version':'https://jsonfeed.org/version/1.1','title':'T','items':[]}", [("err", "JsonError")]),
    ("json_trailing_garbage", "ctl", '{"version":"https://jsonfeed.org/version/1.1","title":"T","items":[]} x', [("err", "JsonError")]),
    ("json_10_author", "ctl", '{"version":"https://jsonfeed.org/version/1","title":"T","author":{"name":"Old"},"items":[{"id":"1"}]}',
     [("feed.author.0", "Old|-|-")]),
    ("json_11_authors_win", "ctl",
     '{"version":"https://jsonfeed.org/version/1.1","title":"T","author":{"name":"Old"},"authors":[{"name":"New"}],"items":[]}',
     [("feed.author.0", "New|-|-")]),
    ("json_tags_mixed_types", "ctl", '{"version":"https://jsonfeed.org/version/1.1","title":"T","items":[{"id":"1","tags":[null,1,"ok",true]}]}',
     [("e0.cat.n", "1")]),
    ("bad_utf8", "ctl", b'<rss version="2.0"><channel><title>a\xffb</title></channel></rss>', [("err", "XmlError")]),
    ("undeclared_html_entity", "ctl", '<rss version="2.0"><channel><title>a&nbsp;b</title></channel></rss>', [("err", "XmlError")]),
    # informational (behaviour differs from feed-rs, no spec MUST either way)
    ("info_latin1_declared", "info", '<?xml version="1.0" encoding="ISO-8859-1"?><rss version="2.0"><channel><title>caf\xe9</title></channel></rss>'.encode("latin-1"),
     [("err", None), ("feed.title", None)]),
    ("info_utf16", "info", '<?xml version="1.0" encoding="UTF-16"?><rss version="2.0"><channel><title>T</title></channel></rss>'.encode("utf-16"),
     [("err", None)]),
    ("info_ws_before_xmldecl", "info", '  <?xml version="1.0"?><rss version="2.0"><channel><title>T</title></channel></rss>', [("err", None)]),
    ("info_atom_entry_document", "info", '<entry xmlns="%s"><id>e</id><title>T</title></entry>' % ATOM, [("err", None), ("n", None)]),
    ("info_foreign_root_feed", "info", '<feed xmlns="urn:not-atom"><id>x</id><title>T</title></feed>', [("err", None), ("feed.title", None)]),
    ("info_json_content_text_and_html", "info",
     '{"version":"https://jsonfeed.org/version/1.1","title":"t","items":[{"id":"s","content_html":"<b>h</b>","content_text":"plain"}]}',
     [("e0.content", None), ("e0.summary", None)]),
    ("info_json_version_2", "info", '{"version":"https://jsonfeed.org/version/2.0","title":"T","items":[]}', [("err", None)]),
]
