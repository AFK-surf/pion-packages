#!/usr/bin/env python3
"""Deterministic corpus generator for packages/feed head-to-head benchmarks."""

import json
import os
import sys


def gen_rss2(path: str, count: int = 1500) -> None:
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<rss version="2.0"',
        '  xmlns:content="http://purl.org/rss/1.0/modules/content/"',
        '  xmlns:dc="http://purl.org/dc/elements/1.1/"',
        '  xmlns:media="http://search.yahoo.com/mrss/"',
        '  xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"',
        '  xmlns:atom="http://www.w3.org/2005/Atom">',
        '  <channel>',
        '    <title>Pion Systems Engineering Podcast &amp; Feed</title>',
        '    <link>https://pion.dev/podcast</link>',
        '    <atom:link href="https://pion.dev/podcast/rss.xml" rel="self" type="application/rss+xml"/>',
        '    <description>Deep dives into compilers, runtimes, and protocols.</description>',
        '    <language>en-us</language>',
        '    <pubDate>Mon, 23 Nov 2026 08:00:00 GMT</pubDate>',
        '    <lastBuildDate>Mon, 23 Nov 2026 12:00:00 +0000</lastBuildDate>',
        '    <generator>PionBenchGen 1.0</generator>',
        '    <itunes:author>Pion Team</itunes:author>',
        '    <itunes:explicit>false</itunes:explicit>',
    ]
    days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    for i in range(count):
        day_num = (i % 28) + 1
        hour = i % 24
        minute = (i * 7) % 60
        sec = (i * 13) % 60
        dow = days[i % 7]
        dur_m = 10 + (i % 50)
        dur_s = i % 60
        lines.append("    <item>")
        lines.append(f"      <title>Episode {i}: High-Throughput Syndication &amp; Parsing #{i}</title>")
        lines.append(f"      <link>https://pion.dev/podcast/ep-{i}</link>")
        lines.append(f'      <guid isPermaLink="false">urn:pion:rss:item:{i}</guid>')
        lines.append(
            f"      <pubDate>{dow}, {day_num:02d} Nov 2026 {hour:02d}:{minute:02d}:{sec:02d} +0000</pubDate>"
        )
        lines.append(f"      <dc:creator>Author {i % 17}</dc:creator>")
        lines.append(f"      <category>systems</category>")
        lines.append(f"      <category>compilers-{i % 5}</category>")
        lines.append(
            f"      <description>Summary for episode {i} discussing zero-copy parsing and memory layout.</description>"
        )
        lines.append(
            f"      <content:encoded><![CDATA[<p>Show notes for <strong>Episode {i}</strong>. "
            f"We benchmark XML &amp; JSON feed parsing at scale with iteration {i * 3}.</p>]]></content:encoded>"
        )
        lines.append(
            f'      <enclosure url="https://cdn.pion.dev/ep-{i}.mp3" length="{1048576 + i * 512}" type="audio/mpeg"/>'
        )
        lines.append(
            f'      <media:content url="https://cdn.pion.dev/ep-{i}.mp4" type="video/mp4" fileSize="{2097152 + i * 1024}" width="1280" height="720"/>'
        )
        lines.append(
            f'      <media:thumbnail url="https://cdn.pion.dev/ep-{i}.jpg" width="320" height="180"/>'
        )
        lines.append(f"      <itunes:author>Host {i % 7}</itunes:author>")
        lines.append(f"      <itunes:duration>{dur_m:02d}:{dur_s:02d}</itunes:duration>")
        lines.append(f"      <itunes:episode>{i + 1}</itunes:episode>")
        lines.append("    </item>")
    lines.append("  </channel>")
    lines.append("</rss>")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def gen_atom(path: str, count: int = 1500) -> None:
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en">',
        "  <id>urn:pion:bench:atom:feed</id>",
        "  <title>Pion Atom 1.0 Engineering Feed</title>",
        "  <subtitle>RFC 4287 compliant syndication corpus</subtitle>",
        "  <updated>2026-11-23T12:00:00Z</updated>",
        '  <link rel="self" type="application/atom+xml" href="https://pion.dev/atom.xml"/>',
        '  <link rel="alternate" type="text/html" href="https://pion.dev/"/>',
        "  <author><name>Pion Core</name><email>core@pion.dev</email></author>",
    ]
    for i in range(count):
        day_num = (i % 28) + 1
        hour = i % 24
        minute = (i * 5) % 60
        sec = (i * 11) % 60
        ts = f"2026-11-{day_num:02d}T{hour:02d}:{minute:02d}:{sec:02d}Z"
        lines.append("  <entry>")
        lines.append(f"    <id>urn:pion:atom:entry:{i}</id>")
        lines.append(f"    <title>Atom Entry #{i}: Deterministic Parsing &amp; Verification</title>")
        lines.append(f'    <link rel="alternate" type="text/html" href="https://pion.dev/posts/{i}"/>')
        lines.append(f'    <link rel="enclosure" type="application/pdf" href="https://pion.dev/papers/{i}.pdf" length="{4096 + i * 64}"/>')
        lines.append(f"    <published>{ts}</published>")
        lines.append(f"    <updated>{ts}</updated>")
        lines.append(f"    <author><name>Writer {i % 13}</name><email>w{i % 13}@pion.dev</email></author>")
        lines.append(f"    <author><name>CoAuthor {i % 5}</name></author>")
        lines.append(f'    <category term="atom-{i % 9}" label="Atom {i % 9}"/>')
        lines.append(f"    <summary>Abstract for entry {i} covering RFC 4287 compliance.</summary>")
        lines.append('    <content type="xhtml">')
        lines.append('      <div xmlns="http://www.w3.org/1999/xhtml">')
        lines.append(
            f'        <p>Article <em>#{i}</em> body with <a href="https://pion.dev/posts/{i}">link</a> &amp; code.</p>'
        )
        lines.append("      </div>")
        lines.append("    </content>")
        lines.append("  </entry>")
    lines.append("</feed>")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def gen_json_feed(path: str, count: int = 2000) -> None:
    items = []
    for i in range(count):
        day_num = (i % 28) + 1
        hour = i % 24
        minute = (i * 3) % 60
        sec = (i * 17) % 60
        ts = f"2026-11-{day_num:02d}T{hour:02d}:{minute:02d}:{sec:02d}Z"
        items.append(
            {
                "id": f"urn:pion:jf:item:{i}",
                "url": f"https://pion.dev/jf/{i}",
                "title": f"JSON Feed Item #{i}: Fast Normalization",
                "summary": f"Concise summary for JSON Feed item {i}.",
                "content_html": f"<p>Full HTML content for item <b>{i}</b> with payload {i * 7}.</p>",
                "date_published": ts,
                "date_modified": ts,
                "authors": [{"name": f"JF Author {i % 11}", "url": f"https://pion.dev/u/{i % 11}"}],
                "tags": ["jsonfeed", f"topic-{i % 8}"],
                "attachments": [
                    {
                        "url": f"https://cdn.pion.dev/jf-{i}.bin",
                        "mime_type": "application/octet-stream",
                        "size_in_bytes": 8192 + i * 32,
                    }
                ],
            }
        )
    doc = {
        "version": "https://jsonfeed.org/version/1.1",
        "title": "Pion JSON Feed 1.1 Corpus",
        "home_page_url": "https://pion.dev/",
        "feed_url": "https://pion.dev/feed.json",
        "description": "High-volume JSON Feed 1.1 benchmark corpus",
        "language": "en-US",
        "authors": [{"name": "Pion Team", "url": "https://pion.dev/"}],
        "items": items,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, separators=(",", ":"))
        f.write("\n")


def main() -> None:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/w16-feed-bench"
    os.makedirs(out_dir, exist_ok=True)
    gen_rss2(os.path.join(out_dir, "w1_rss2_1500.xml"), 1500)
    gen_atom(os.path.join(out_dir, "w2_atom_1500.xml"), 1500)
    gen_json_feed(os.path.join(out_dir, "w3_jsonfeed_2000.json"), 2000)


if __name__ == "__main__":
    main()
