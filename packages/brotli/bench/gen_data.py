#!/usr/bin/env python3
"""Generate deterministic realistic corpora for packages/brotli benchmarks:
1. web.br        : ~2 MiB mixed HTML/CSS/JS/JSON payload (brotli -q 6)
2. woff2.br      : ~1 MiB WOFF2-like binary font table payload (brotli -q 11)
3. small_batch.bin : 512 small HTTP/API/JSON/HTML payloads (~512B-2KB each, brotli -q 5)
"""
import hashlib
import json
import os
import struct
import subprocess
import sys


def compress_brotli(raw: bytes, quality: int) -> bytes:
    proc = subprocess.run(
        ["brotli", f"-q", str(quality), "-c"],
        input=raw,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return proc.stdout


def gen_web_corpus(target_bytes: int = 2 * 1024 * 1024) -> bytes:
    html_tpl = (
        "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\">"
        "<title>Article {i} - Web Performance &amp; Compression</title>"
        "<link rel=\"stylesheet\" href=\"/static/app.{v}.css\"></head>"
        "<body><header class=\"site-header\"><nav><a href=\"/\">Home</a>"
        "<a href=\"/docs/{i}\">Documentation</a><a href=\"/blog/{i}\">Blog</a></nav></header>"
        "<main class=\"container\"><article data-id=\"{i}\">"
        "<h1>Understanding Brotli Static Dictionary &amp; Context Modeling</h1>"
        "<p>Brotli is a generic-purpose lossless compression algorithm (RFC 7932) "
        "that compresses data using a combination of a modern variant of the LZ77 algorithm, "
        "Huffman coding and 2nd order context modeling, with a compression ratio comparable "
        "to the best currently available general-purpose compression methods.</p>"
        "</article></main></body></html>\n"
    )
    css_tpl = (
        ".card-{i} {{ display: flex; flex-direction: column; padding: 16px 24px; "
        "margin: 0 auto 12px; border-radius: 8px; background-color: #ffffff; "
        "border: 1px solid rgba(15, 23, 42, 0.08); font-family: -apple-system, "
        "BlinkMacSystemFont, \"Segoe UI\", Roboto, sans-serif; color: #1e293b; }}\n"
    )
    js_tpl = (
        "export function renderWidget_{i}(state, props) {{\n"
        "  const items = state.items.filter((x) => x.active && x.score >= {s});\n"
        "  return items.map((item) => ({{ id: item.id, title: item.title, url: `/api/v1/items/${{item.id}}` }}));\n"
        "}}\n"
    )
    parts = []
    total = 0
    idx = 0
    while total < target_bytes:
        m = idx % 4
        if m == 0:
            chunk = html_tpl.format(i=idx, v=idx % 17).encode("utf-8")
        elif m == 1:
            chunk = css_tpl.format(i=idx % 64).encode("utf-8")
        elif m == 2:
            chunk = js_tpl.format(i=idx % 32, s=(idx * 7) % 100).encode("utf-8")
        else:
            rec = json.dumps(
                {
                    "id": idx,
                    "type": ["article", "comment", "asset", "metric"][idx % 4],
                    "host": "cdn.example.com",
                    "path": f"/api/v2/content/{idx % 251}/bundle.json",
                    "status": 200 if idx % 19 != 0 else 304,
                    "bytes": 1024 + ((idx * 131) % 8192),
                    "tags": ["html", "css", "javascript", f"region-{idx % 8}"],
                },
                separators=(",", ":"),
            ) + "\n"
            chunk = rec.encode("utf-8")
        parts.append(chunk)
        total += len(chunk)
        idx += 1
    return b"".join(parts)[:target_bytes]


def gen_woff2_payload(target_bytes: int = 1024 * 1024) -> bytes:
    """Deterministic WOFF2-like binary font payload (SFNT tables + glyph contours + kerning)."""
    out = bytearray()
    # Header-like directory
    out.extend(b"wOF2\x00\x01\x00\x00")
    out.extend(struct.pack(">IIII", target_bytes, 16, 0, 1024))
    # Table directory entries (cmap, glyf, head, hhea, hmtx, loca, maxp, name, post, GPOS, GSUB)
    tags = [b"cmap", b"glyf", b"head", b"hhea", b"hmtx", b"loca", b"maxp", b"name", b"post", b"GPOS", b"GSUB", b"OS/2"]
    for ti, tag in enumerate(tags):
        out.extend(tag)
        out.extend(struct.pack(">III", (0x12345678 ^ (ti * 0x9E3779B1)) & 0xFFFFFFFF, ti * 4096, 4096))

    # Glyph contour stream + delta-encoded coordinates + kerning pairs (binary structured, high LZ77 locality)
    glyph = 0
    while len(out) < target_bytes:
        n_contours = (glyph % 4) + 1
        xmin = -50 + (glyph % 40)
        ymin = -200 + ((glyph * 3) % 60)
        xmax = 500 + ((glyph * 7) % 300)
        ymax = 700 + ((glyph * 5) % 200)
        out.extend(struct.pack(">hhhhh", n_contours, xmin, ymin, xmax, ymax))
        # End points of contours
        pts = 0
        for c in range(n_contours):
            pts += 6 + ((glyph + c) % 5)
            out.extend(struct.pack(">H", pts - 1))
        # Hinting instructions (short repeating bytecode patterns)
        instr = bytes([0xB0, glyph & 0xFF, 0x2C, 0x20, 0x20, 0x00, 0x58, 0x1B])
        out.extend(struct.pack(">H", len(instr)))
        out.extend(instr)
        # Flags + delta coordinates
        for p in range(pts):
            flag = 0x31 if (p % 2 == 0) else 0x13
            dx = ((glyph * 17 + p * 31) % 127) - 63
            dy = ((glyph * 13 + p * 29) % 127) - 63
            out.append(flag)
            out.append(dx & 0xFF)
            out.append(dy & 0xFF)
        # Every 16 glyphs emit a repeating kerning / GSUB lookup subtable block
        if glyph % 16 == 15:
            for k in range(32):
                out.extend(struct.pack(">HHh", (glyph + k) & 0x3FF, (glyph + k + 1) & 0x3FF, -20 + (k % 9) * 5))
        glyph += 1
    return bytes(out[:target_bytes])


def gen_small_batch(count: int = 512) -> tuple[bytes, bytes]:
    """Generate `count` small HTTP/JSON/HTML payloads compressed with brotli -q 5."""
    batch = bytearray()
    batch.extend(struct.pack("<I", count))
    raw_concat = bytearray()
    for i in range(count):
        if i % 3 == 0:
            payload = json.dumps(
                {
                    "req_id": f"req-{i:06d}",
                    "user": {"id": 10000 + i, "name": f"user_{i % 64}", "roles": ["reader", "editor"]},
                    "items": [
                        {"sku": f"SKU-{(i + j) % 999:03d}", "qty": (j % 5) + 1, "price": 9.95 + j}
                        for j in range(4 + (i % 8))
                    ],
                    "meta": {"trace": f"00-{(i * 2654435761) & 0xFFFFFFFF:08x}-01", "ok": True},
                },
                separators=(",", ":"),
            ).encode("utf-8")
        elif i % 3 == 1:
            rows = "".join(
                f"<li data-idx=\"{j}\"><span>Item {i}-{j}</span><em>{(i + j) % 100}%</em></li>"
                for j in range(6 + (i % 10))
            )
            payload = f"<section class=\"panel\" id=\"p-{i}\"><h2>Panel {i}</h2><ul>{rows}</ul></section>".encode("utf-8")
        else:
            payload = (
                f"HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n"
                f"Cache-Control: public, max-age=3600\r\nETag: \"v1-{i:04x}\"\r\n\r\n"
                + ("{" + ",".join(f"\"k{j}\":\"value_{(i + j) % 37}\"" for j in range(16 + (i % 12))) + "}")
            ).encode("utf-8")
        br = compress_brotli(payload, 5)
        batch.extend(struct.pack("<I", len(br)))
        batch.extend(br)
        raw_concat.extend(payload)
    return bytes(batch), bytes(raw_concat)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: gen_data.py <out_dir>", file=sys.stderr)
        return 1
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    web_raw = gen_web_corpus(2 * 1024 * 1024)
    web_br = compress_brotli(web_raw, 6)
    with open(os.path.join(out_dir, "web.bin"), "wb") as f:
        f.write(web_raw)
    with open(os.path.join(out_dir, "web.br"), "wb") as f:
        f.write(web_br)

    woff2_raw = gen_woff2_payload(1024 * 1024)
    woff2_br = compress_brotli(woff2_raw, 11)
    with open(os.path.join(out_dir, "woff2.bin"), "wb") as f:
        f.write(woff2_raw)
    with open(os.path.join(out_dir, "woff2.br"), "wb") as f:
        f.write(woff2_br)

    small_batch, small_raw = gen_small_batch(512)
    with open(os.path.join(out_dir, "small_batch.bin"), "wb") as f:
        f.write(small_batch)
    with open(os.path.join(out_dir, "small_raw.bin"), "wb") as f:
        f.write(small_raw)

    print(f"web.bin         : {len(web_raw):8d} B -> web.br         : {len(web_br):7d} B ({len(web_br)*100.0/len(web_raw):5.2f}%) sha256:{hashlib.sha256(web_raw).hexdigest()[:16]}")
    print(f"woff2.bin       : {len(woff2_raw):8d} B -> woff2.br       : {len(woff2_br):7d} B ({len(woff2_br)*100.0/len(woff2_raw):5.2f}%) sha256:{hashlib.sha256(woff2_raw).hexdigest()[:16]}")
    print(f"small_raw.bin   : {len(small_raw):8d} B -> small_batch.bin: {len(small_batch):7d} B (512 pkts) sha256:{hashlib.sha256(small_raw).hexdigest()[:16]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
