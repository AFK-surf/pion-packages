#!/usr/bin/env python3
"""Blind-spot benchmark corpora (shapes the official W1/W2/W3 corpora do not exercise).
usage: gen_bench.py <out_dir>
  B1 Atom, 500 entries, XHTML content with 60 nested/sibling inline elements each (XHTML re-serialization path)
  B2 RSS, 3000 items, dirty / non-canonical dates in 12 styles (lenient date fallback paths)
  B3 RSS, 150 items, 64 KiB content:encoded CDATA each (long text, ~9.6 MiB)
  B4 RSS podcast, 1500 items, media:group + itunes + googleplay + podcast + slash extensions
"""
import os
import sys


def b1():
    out = ['<feed xmlns="http://www.w3.org/2005/Atom"><id>urn:b1</id><title>B1</title><updated>2026-11-23T12:00:00Z</updated>']
    for i in range(500):
        body = "".join('<p class="c%d">Para <em>%d</em> <a href="https://x/%d?a=1&amp;b=2">l</a> &amp; <code>x&lt;y</code><br/></p>' % (j, j, j) for j in range(12))
        body = "<section>" + "<div><ul><li>" * 5 + body + "</li></ul></div>" * 5 + "</section>"
        out.append('<entry><id>urn:b1:%d</id><title>Entry %d</title><updated>2026-11-23T12:00:00Z</updated>'
                   '<content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">%s</div></content></entry>' % (i, i, body))
    out.append("</feed>")
    return "\n".join(out)


DATES = ["Mon, 23 Nov 2026 12:00:00 GMT", "Monday, 23 November 2026 12:00:00 GMT", "Mon, 23 Nov 26 12:00:00 +0530",
         "23 Nov 2026 12:00 EST", "Mon, 23 Nov 2026 12:00:00 -0800 (PST)", "2026-11-23T12:00:00Z",
         "2026-11-23 12:00:00+0800", "2026-11-23T12:00:00.123456Z", "Mon,  23  Nov  2026  12:00:00  UTC",
         "Mon, 23 Nov 2026 9:05:00 GMT", "2026-11-23", "Mon, 23 Nov 2026 12:00:00 Z"]


def b2():
    out = ['<rss version="2.0"><channel><title>B2</title><link>https://x/</link><description>d</description>']
    for i in range(3000):
        out.append("<item><title>Item %d</title><guid>urn:b2:%d</guid><pubDate>%s</pubDate></item>" % (i, i, DATES[i % len(DATES)]))
    out.append("</channel></rss>")
    return "\n".join(out)


def b3():
    blob = ("<p>Lorem ipsum dolor sit amet &amp; consectetur &lt;adipiscing&gt; elit.</p>\n" * 900)[:65536]
    out = ['<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>B3</title>']
    for i in range(150):
        out.append("<item><title>Long %d</title><guid>urn:b3:%d</guid><description>short</description>"
                   "<content:encoded><![CDATA[%s]]></content:encoded></item>" % (i, i, blob))
    out.append("</channel></rss>")
    return "\n".join(out)


def b4():
    out = ['<rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" '
           'xmlns:googleplay="http://www.google.com/schemas/play-podcasts/1.0" xmlns:podcast="https://podcastindex.org/namespace/1.0" '
           'xmlns:slash="http://purl.org/rss/1.0/modules/slash/" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>B4</title>'
           '<link>https://x/</link><description>d</description><itunes:author>A</itunes:author><itunes:explicit>no</itunes:explicit>'
           '<image><url>https://x/l.png</url><title>B4</title><link>https://x/</link></image><googleplay:image href="https://x/g.png"/>']
    for i in range(1500):
        out.append(
            "<item><title>Ep %d</title><link>https://x/%d</link><guid isPermaLink=\"false\">urn:b4:%d</guid>"
            "<pubDate>Mon, 23 Nov 2026 12:00:00 GMT</pubDate><dc:creator>Host %d</dc:creator><description>Notes %d</description>"
            "<enclosure url=\"https://cdn/x%d.mp3\" length=\"%d\" type=\"audio/mpeg\"/>"
            "<media:group><media:title>T</media:title><media:description>D</media:description>"
            "<media:content url=\"https://cdn/%d.mp4\" type=\"video/mp4\" width=\"1280\" height=\"720\" fileSize=\"123\"/>"
            "<media:content url=\"https://cdn/%d.webm\" type=\"video/webm\"/><media:thumbnail url=\"https://cdn/%d.jpg\" width=\"320\" height=\"180\"/></media:group>"
            "<itunes:duration>01:%02d:%02d</itunes:duration><itunes:episode>%d</itunes:episode><itunes:season>2</itunes:season>"
            "<itunes:summary>S</itunes:summary><googleplay:description>G</googleplay:description>"
            "<podcast:transcript url=\"https://x/%d.vtt\" type=\"text/vtt\"/><slash:comments>%d</slash:comments><comments>https://x/%d#c</comments></item>"
            % (i, i, i, i % 7, i, i, 1000 + i, i, i, i, i % 60, (i * 7) % 60, i + 1, i, i % 50, i))
    out.append("</channel></rss>")
    return "\n".join(out)


def main():
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    for name, fn in (("b1_atom_xhtml_heavy.xml", b1), ("b2_rss_dirty_dates.xml", b2), ("b3_rss_long_cdata.xml", b3), ("b4_rss_podcast_ext.xml", b4)):
        with open(os.path.join(d, name), "w") as f:
            f.write(fn())


if __name__ == "__main__":
    main()
