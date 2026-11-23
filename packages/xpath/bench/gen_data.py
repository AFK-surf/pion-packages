#!/usr/bin/env python3
"""Deterministic XML corpus generator for packages/xpath benchmarks (W1, W2, W3)."""
import os
import sys


def gen_w1(path: str) -> None:
    """~1.2 MB realistic book catalog with 3,000 books across 10 categories."""
    categories = [
        "systems", "compilers", "databases", "networking", "security",
        "graphics", "ml", "distributed", "crypto", "algorithms",
    ]
    langs = ["en", "de", "fr", "ja", "zh"]
    tags_pool = ["core", "fast", "pure", "wasm", "native", "formal", "async", "zero-copy"]
    out = ['<?xml version="1.0" encoding="UTF-8"?>\n<catalog version="2.0">\n']
    for c_idx, cat in enumerate(categories):
        out.append(f'  <section id="sec-{c_idx}" name="{cat}">\n')
        for j in range(300):
            bid = c_idx * 300 + j + 1
            lang = langs[bid % len(langs)]
            avail = "true" if (bid % 4 != 0) else "false"
            price = 10 + (bid * 7) % 90
            year = 2000 + (bid % 27)
            t1 = tags_pool[bid % len(tags_pool)]
            t2 = tags_pool[(bid + 3) % len(tags_pool)]
            out.append(
                f'    <book id="b{bid}" lang="{lang}" available="{avail}">'
                f'<title>  Book   Title  #{bid}  ({cat}) </title>'
                f'<author>Author_{bid % 97}</author>'
                f'<price>{price}</price>'
                f'<year>{year}</year>'
                f'<tags><tag>{t1}</tag><tag>{t2}</tag></tags>'
                f'<summary>  Comprehensive guide to {cat} engineering volume {bid}.  </summary>'
                f'</book>\n'
            )
        out.append('  </section>\n')
    out.append('</catalog>\n')
    with open(path, "w", encoding="utf-8") as f:
        f.write("".join(out))


def gen_w2(path: str) -> None:
    """Medium realistic XML catalog (50 books) for 20,000x compile+eval."""
    langs = ["en", "de", "fr", "ja"]
    out = ['<?xml version="1.0" encoding="UTF-8"?>\n<store region="global">\n']
    for i in range(1, 51):
        lang = langs[i % len(langs)]
        price = 15 + (i * 3) % 50
        out.append(
            f'  <item id="i{i}" lang="{lang}" stock="{i % 5}">'
            f'<name>Item {i}</name>'
            f'<cost>{price}</cost>'
            f'<meta><sku>SKU-{i:04d}</sku><tier>{(i % 3) + 1}</tier></meta>'
            f'</item>\n'
        )
    out.append('</store>\n')
    with open(path, "w", encoding="utf-8") as f:
        f.write("".join(out))


def gen_w3(path: str) -> None:
    """Deep hierarchical org/project tree for recursive axes & aggregation."""
    out = ['<?xml version="1.0" encoding="UTF-8"?>\n<org name="monoid">\n']
    tid = 0
    for d in range(25):
        out.append(f'  <dept id="d{d}" region="r{d % 4}">\n')
        for g in range(6):
            out.append(f'    <team id="t{d}_{g}" tier="{(g % 3) + 1}">\n')
            for p in range(5):
                tid += 1
                cost = 100 + (tid * 13) % 500
                out.append(
                    f'      <project id="p{tid}" active="{"yes" if tid % 3 != 0 else "no"}">'
                    f'<label>  Proj   {tid}  </label>'
                    f'<budget>{cost}</budget>'
                    f'<milestone id="m{tid}_1"><hours>{(tid % 12) + 1}</hours></milestone>'
                    f'<milestone id="m{tid}_2"><hours>{(tid % 7) + 2}</hours></milestone>'
                    f'</project>\n'
                )
            out.append('    </team>\n')
        out.append('  </dept>\n')
    out.append('</org>\n')
    with open(path, "w", encoding="utf-8") as f:
        f.write("".join(out))


def gen_w4(path: str) -> None:
    """Node-set comparison workload: 8,000 <a> and 8,000 <b> disjoint numeric elements."""
    out = ['<?xml version="1.0" encoding="UTF-8"?>\n<r>\n']
    for i in range(8000):
        out.append(f'<a>{i}</a>')
    for i in range(8000):
        out.append(f'<b>{i + 10000}</b>')
    out.append('\n</r>\n')
    with open(path, "w", encoding="utf-8") as f:
        f.write("".join(out))


def gen_w5(path: str) -> None:
    """> 1 MB document (~1.4 MB, 50,000 elements + attributes + text) under default limits."""
    out = ['<?xml version="1.0" encoding="UTF-8"?>\n<r>\n']
    for i in range(50000):
        out.append(f'<e k="{i}">v{i:06d}</e>')
    out.append('\n</r>\n')
    with open(path, "w", encoding="utf-8") as f:
        f.write("".join(out))


def main() -> None:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/w15-xpath-bench/data"
    os.makedirs(out_dir, exist_ok=True)
    w1_path = os.path.join(out_dir, "w1.xml")
    w2_path = os.path.join(out_dir, "w2.xml")
    w3_path = os.path.join(out_dir, "w3.xml")
    w4_path = os.path.join(out_dir, "w4.xml")
    w5_path = os.path.join(out_dir, "w5.xml")
    gen_w1(w1_path)
    gen_w2(w2_path)
    gen_w3(w3_path)
    gen_w4(w4_path)
    gen_w5(w5_path)
    print(
        f"generated w1={os.path.getsize(w1_path)}B "
        f"w2={os.path.getsize(w2_path)}B "
        f"w3={os.path.getsize(w3_path)}B "
        f"w4={os.path.getsize(w4_path)}B "
        f"w5={os.path.getsize(w5_path)}B"
    )


if __name__ == "__main__":
    main()
