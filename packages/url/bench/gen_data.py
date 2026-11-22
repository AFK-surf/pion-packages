#!/usr/bin/env python3
"""Deterministic corpus generator for packages/url head-to-head benchmarks."""

import os
import sys

def gen_urls(path: str, count: int) -> None:
    templates = [
        "https://api.example.com/v2/users/{i}/profile?fields=id,name,email&active=true#bio",
        "http://cdn-{m}.assets.example.org:80/static/js/app/../bundle.{i}.min.js?v={i}",
        "https://user{m}:s3cr3t@shop.example.net:8443/catalog/items/{i}/details?sort=price&page={p}#reviews",
        "http://192.168.{m}.{p}/api/v1/metrics/node/{i}?window=5m&format=json",
        "http://[2001:0db8:0000:0000:0000:ff00:0042:{h}]:8080/status/health/{i}?verbose=1",
        "https://fa\u00df.ExAmPlE/products/{i}/info?lang=de&ref=nav#top",
        "https://\u4f60\u597d.example.com/\u8def\u5f84/{i}?q=pion+url&n={p}",
        "wss://stream-{m}.realtime.io:443/ws/v1/channel/{i}?token=abc{i}xyz",
        "ftp://files.archive.org/pub/releases/v{m}/pkg-{i}.tar.gz",
        "../v3/items/{i}/summary?ref=rel&idx={p}#sec-{m}",
    ]
    with open(path, "w", encoding="utf-8") as f:
        for i in range(count):
            t = templates[i % len(templates)]
            m = (i * 7 + 3) % 250 + 1
            p = (i * 13 + 5) % 200 + 1
            h = format((i * 17 + 1) % 65535, "04x")
            f.write(t.format(i=i, m=m, p=p, h=h) + "\n")


def gen_queries(path: str, count: int) -> None:
    templates = [
        "z=last+{i}&a=first+value&m=mid%20{p}&a=dup{m}&drop=bye&lang=en-US&q=hello+world%21",
        "page={p}&limit=50&sort=desc&filter=status%3Aactive&drop=1&tag=rust&tag=pion&id={i}",
        "utm_source=web&utm_medium=cpc&q=%E4%BD%A0%E5%A5%BD+url&drop=x&k={i}&a=1&b=2",
        "redirect=https%3A%2F%2Fexample.com%2Fp%2F{i}&state=xyz{m}&drop=tmp&code=200&scope=read+write",
    ]
    with open(path, "w", encoding="utf-8") as f:
        for i in range(count):
            t = templates[i % len(templates)]
            m = (i * 11 + 1) % 997
            p = (i * 5 + 2) % 100
            f.write(t.format(i=i, m=m, p=p) + "\n")


def main() -> None:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-url-bench"
    os.makedirs(out_dir, exist_ok=True)
    gen_urls(os.path.join(out_dir, "urls_100k.txt"), 100000)
    gen_queries(os.path.join(out_dir, "queries_100k.txt"), 100000)


if __name__ == "__main__":
    main()
