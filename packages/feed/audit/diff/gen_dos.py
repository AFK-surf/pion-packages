#!/usr/bin/env python3
"""Generate the DoS / limit corpus. usage: gen_dos.py <out_dir>
Writes <name>.in files and prints `<name>\t<expected regex under default limits>` to <out_dir>/expect.tsv."""
import os
import sys

A = '<feed xmlns="http://www.w3.org/2005/Atom">'
RSS = '<rss version="2.0"><channel><title>t</title>'
J = '{"version":"https://jsonfeed.org/version/1.1","title":"t",'
MIB = 1 << 20


def cases():
    yield "xhtml_deep_100k", A + '<entry><id>x</id><content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">' + "<div>" * 100000 + "x" + "</div>" * 100000 + "</div></content></entry></feed>", r"^err LimitExceeded$"
    yield "xml_deep_1m", A + "<x>" * 1000000 + "</x>" * 1000000 + "</feed>", r"^err LimitExceeded$"
    yield "json_deep_1m", J + '"x":' + "[" * 1000000 + "]" * 1000000 + "}", r"^err LimitExceeded$"
    yield "json_nodes_1m", J + '"x":[' + "0," * 1000001 + '0],"items":[]}', r"^err LimitExceeded$"
    yield "atom_entries_10000", A + "<entry><id>i</id><title>t</title></entry>" * 10000 + "</feed>", r"^ok entries=10000 "
    yield "atom_entries_10001", A + "<entry><id>i</id><title>t</title></entry>" * 10001 + "</feed>", r"^err LimitExceeded$"
    yield "rss_items_10001", RSS + "<item><guid>g</guid></item>" * 10001 + "</channel></rss>", r"^err LimitExceeded$"
    yield "json_items_10001", J + '"items":[' + ",".join(['{"id":"i"}'] * 10001) + "]}", r"^err LimitExceeded$"
    yield "links_64", A + "<entry><id>i</id>" + '<link href="a"/>' * 64 + "</entry></feed>", r"^ok entries=1 feed_links=0 links=64 "
    yield "links_65", A + "<entry><id>i</id>" + '<link href="a"/>' * 65 + "</entry></feed>", r"^err LimitExceeded$"
    yield "rss_enclosures_65", RSS + "<item><guid>g</guid>" + '<enclosure url="a" length="1" type="a/b"/>' * 65 + "</item></channel></rss>", r"^err LimitExceeded$"
    yield "json_attachments_65", J + '"items":[{"id":"i","attachments":[' + ",".join(['{"url":"a","mime_type":"a/b"}'] * 65) + "]}]}", r"^err LimitExceeded$"
    yield "text_4mib", RSS + "<item><guid>g</guid><content:encoded xmlns:content=\"http://purl.org/rss/1.0/modules/content/\">" + "x" * (4 * MIB) + "</content:encoded></item></channel></rss>", r"^ok entries=1 .* content_bytes=4194304 "
    yield "text_4mib_plus1", RSS + "<item><guid>g</guid><content:encoded xmlns:content=\"http://purl.org/rss/1.0/modules/content/\">" + "x" * (4 * MIB + 1) + "</content:encoded></item></channel></rss>", r"^err LimitExceeded$"
    yield "cdata_4mib_plus1_split", RSS + "<item><guid>g</guid><content:encoded xmlns:content=\"http://purl.org/rss/1.0/modules/content/\">" + ("<![CDATA[" + "x" * 65536 + "]]>") * 64 + "y</content:encoded></item></channel></rss>", r"^err LimitExceeded$"
    yield "input_16mib_plus1", RSS + "<!--" + "x" * (16 * MIB) + "-->" + "</channel></rss>", r"^err LimitExceeded$"
    yield "text_chunks_160k", RSS[:-len("<title>t</title>")] + "<title>" + "a<![CDATA[b]]>" * 160000 + "</title></channel></rss>", r"^ok "
    yield "feed_links_100k", A + '<link href="a"/>' * 100000 + "</feed>", r"^(ok|err LimitExceeded)"
    yield "categories_100k", A + "<entry><id>i</id>" + '<category term="c"/>' * 100000 + "</entry></feed>", r"^(ok|err LimitExceeded)"
    yield "json_tags_100k", J + '"items":[{"id":"i","tags":[' + ",".join(['"a"'] * 100000) + "]}]}", r"^(ok|err LimitExceeded)"
    yield "dot_segments_200k", A + '<entry><id>i</id><link xml:base="http://h/b/" href="' + "a/../" * 200000 + 'z"/></entry></feed>', r"^ok "
    yield "xml_base_up_200k", A + '<entry xml:base="' + "../" * 200000 + '"><id>i</id><link href="x"/></entry></feed>', r"^ok "
    yield "date_tokens_200k", RSS + "<item><guid>g</guid><pubDate>" + "Mon " * 200000 + "</pubDate></item></channel></rss>", r"^ok "
    yield "date_parens_200k", RSS + "<item><guid>g</guid><pubDate>" + "(" * 200000 + "</pubDate></item></channel></rss>", r"^ok "
    yield "author_parens_200k", RSS + "<item><guid>g</guid><author>" + "a@b (" * 100000 + "</author></item></channel></rss>", r"^ok "
    yield "huge_attr_8mib", A + '<entry><id>i</id><link href="' + "a" * (8 * MIB) + '"/></entry></feed>', r"^ok "
    yield "many_attrs_100k", A + "<entry><id>i</id><x " + " ".join('a%d="1"' % i for i in range(100000)) + "/></entry></feed>", r"^(ok|err LimitExceeded)"
    lol = '<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY a "aaaaaaaaaa">' + "".join(
        '<!ENTITY %s "%s">' % (chr(98 + i), ("&%s;" % chr(97 + i)) * 10) for i in range(9)) + ']><rss version="2.0"><channel><title>&j;</title></channel></rss>'
    yield "billion_laughs", lol, r"^err (XmlError|LimitExceeded)$"
    quad = '<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY q "' + "x" * 100000 + '">]><rss version="2.0"><channel><title>' + "&q;" * 100000 + "</title></channel></rss>"
    yield "quadratic_blowup", quad, r"^err (XmlError|LimitExceeded)$"
    yield "external_entity", '<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY x SYSTEM "file:///etc/passwd">]><rss version="2.0"><channel><title>&x;</title></channel></rss>', r"^err "


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "expect.tsv"), "w") as f:
        for name, data, exp in cases():
            with open(os.path.join(out, name + ".in"), "w") as g:
                g.write(data)
            f.write("%s\t%s\n" % (name, exp))


if __name__ == "__main__":
    main()
