#!/usr/bin/env python3
"""Deterministic realistic mixed XML corpus generator (SVG + Maven/Plist + RSS/Atom)."""
import os
import sys

def generate(out_dir: str) -> str:
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "mixed_corpus.xml")
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<bundle xmlns="urn:pion:bundle" xmlns:svg="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:atom="http://www.w3.org/2005/Atom" version="1.0">',
    ]
    # 600 rich mixed sections (~1.5 MB total)
    for i in range(600):
        # 1. SVG vector group with namespaces and paths
        parts.append(
            f'<svg:g id="layer-{i}" transform="translate({i % 64}, {(i * 3) % 128})" opacity="0.95">'
            f'<svg:rect x="{i}" y="{i + 2}" width="120" height="80" rx="4" fill="#336699" stroke="#112233"/>'
            f'<svg:path d="M10 10 L{20 + (i % 50)} 40 C30 50 60 50 90 10 Z" fill="none" stroke-width="1.5"/>'
            f'<svg:text x="12" y="24" xml:lang="en">Node &amp; Layer #{i} &lt;v1&gt;</svg:text>'
            f'<svg:use xlink:href="#icon-{i % 16}"/>'
            f'</svg:g>'
        )
        # 2. Maven POM / Plist-like dependency & config block
        parts.append(
            f'<artifact groupId="org.pion.pkg" artifactId="mod-{i}" version="0.{(i % 9) + 1}.{i % 20}" scope="compile">'
            f'<description>Pure Pion module &quot;mod-{i}&quot; with zero C deps &amp; fast UTF-8</description>'
            f'<properties><key>max.depth</key><integer>{256 + i}</integer><key>enabled</key><true/></properties>'
            f'<!-- artifact metadata #{i} -->'
            f'</artifact>'
        )
        # 3. Atom/RSS feed entry with CDATA & PI
        parts.append(
            f'<atom:entry xml:id="entry-{i}">'
            f'<atom:title type="text">Release {i}: XML 1.0 &amp; Namespaces</atom:title>'
            f'<atom:link rel="alternate" type="text/html" href="https://example.org/releases/{i}?a=1&amp;b=2"/>'
            f'<atom:updated>2026-11-23T06:00:{i % 60:02d}Z</atom:updated>'
            f'<atom:summary><![CDATA[Summary for item {i}: <tag attr="val"> & raw text 100% preserved.]]></atom:summary>'
            f'<?render mode="fast" id="{i}"?>'
            f'</atom:entry>'
        )
    parts.append('</bundle>')
    data = "".join(parts)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(data)
    return path

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-xml-bench"
    p = generate(out)
    print(f"Generated {p} ({os.path.getsize(p)} bytes)")
