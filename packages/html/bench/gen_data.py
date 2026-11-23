#!/usr/bin/env python3
"""Deterministic HTML5 benchmark corpus generator for packages/html."""

import os
import sys


def gen_mixed_pages(path: str, sections: int = 120) -> int:
    parts = [
        "<!DOCTYPE html><html lang=\"en\"><head>"
        "<meta charset=\"utf-8\">"
        "<title>Pion HTML5 Benchmark Corpus &amp; Reference</title>"
        "<style>.post > .title { font-weight: 700; } .archived { opacity: 0.5; }</style>"
        "<script>if (window.a < 10 && window.b > 2) { console.log(\"<div>noop</div>\"); }</script>"
        "</head><body>"
        "<header id=\"top\" class=\"site-header\"><h1>Engineering Feed</h1>"
        "<nav><ul class=\"nav-list\">"
        "<li class=\"item active\"><a href=\"https://example.com/home\" rel=\"noopener\">Home</a></li>"
        "<li class=\"item\"><a href=\"https://example.com/docs\" rel=\"noopener\">Docs</a></li>"
        "<li class=\"item\"><a href=\"https://example.com/blog\" rel=\"noopener\">Blog</a></li>"
        "<li class=\"item\"><a href=\"http://legacy.example.org/archive\">Archive</a></li>"
        "</ul></nav></header>"
        "<main id=\"content\" class=\"container\">"
        "<section class=\"articles\">"
    ]

    for i in range(sections):
        archived = " archived" if (i % 5 == 0) else ""
        status = "OK" if (i % 3 != 0) else "WARN"
        parts.append(
            f"<!-- article {i} -->"
            f"<article class=\"post{archived}\" data-idx=\"{i}\">"
            f"<h2 class=\"title\"><a href=\"https://example.com/posts/{i}\">Post #{i}: HTML5 &amp; CSS &mdash; Fast Parsing</a></h2>"
            f"<div class=\"card{archived}\">"
            f"<p class=\"summary\">Summary for item {i} with <b>bold</b>, <i>italic</i>, &ldquo;quotes&rdquo;, and <code>&lt;tag&gt;</code>.<br>"
            f"Read more at <a href=\"https://example.com/docs/{i}.html\">doc-{i}</a>.</p>"
            f"<table class=\"metrics\"><tbody>"
            f"<tr><td data-status=\"{status}\">latency</td><td>{10 + (i % 40)}ms</td></tr>"
            f"<tr><td data-status=\"ok\">throughput</td><td>{200 + i}MB/s</td></tr>"
            f"</tbody></table>"
            f"</div></article>"
        )

    parts.append(
        "</section></main>"
        "<footer class=\"site-footer\">"
        "<p>&copy; 2026 Pion Benchmark &bull; <a href=\"https://example.com/about\" rel=\"noopener noreferrer\">About</a></p>"
        "</footer></body></html>"
    )
    data = "".join(parts)
    with open(path, "w", encoding="utf-8") as f:
        f.write(data)
    return len(data.encode("utf-8"))


def gen_ugc_xss(path: str, comments: int = 200) -> int:
    parts = []
    for i in range(comments):
        parts.append(
            f"<div title=\"comment-{i}\">"
            f"<p>User <b>#{i}</b> wrote: <em>Hello &amp; welcome</em> to "
            f"<a href=\"https://example.com/u/{i}\" title=\"profile\">Profile {i}</a> "
            f"and <a href=\"javascript:alert({i})\">bad-js</a> "
            f"and <a href=\"java&#x09;script:alert({i})\">obf-js</a>.</p>"
            f"<blockquote cite=\"https://example.com/q/{i}\"><p>Quoted &lt;safe&gt; text #{i}.</p></blockquote>"
            f"<script>alert('xss-{i}')</script>"
            f"<style>body {{ display: none; }}</style>"
            f"<iframe src=\"https://evil.example/{i}\">frame</iframe>"
            f"<!-- hidden comment {i} -->"
            f"<p onclick=\"evil({i})\"><font color=\"red\">Legacy font {i}</font><br><code>x &lt; y &amp;&amp; y &gt; 0</code></p>"
            f"</div>"
        )
    data = "".join(parts)
    with open(path, "w", encoding="utf-8") as f:
        f.write(data)
    return len(data.encode("utf-8"))


def main() -> int:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/pion-html-bench"
    os.makedirs(out_dir, exist_ok=True)
    p1 = os.path.join(out_dir, "mixed_pages.html")
    p2 = os.path.join(out_dir, "ugc_xss.html")
    n1 = gen_mixed_pages(p1)
    n2 = gen_ugc_xss(p2)
    print(f"generated mixed_pages.html={n1}B ugc_xss.html={n2}B")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
