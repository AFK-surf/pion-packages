#!/usr/bin/env python3
"""Deterministic corpus generator for packages/zstd parity & head-to-head benchmarks."""
import os
import struct
import sys


def gen_web_corpus(target_bytes: int) -> bytes:
    chunks = []
    state = 0x9E3779B97F4A7C15
    tags = ["div", "section", "article", "header", "main", "footer", "nav", "aside"]
    classes = [
        "container mx-auto px-4",
        "card shadow-sm rounded-lg p-6",
        "btn btn-primary font-medium",
        "grid grid-cols-3 gap-4",
        "text-slate-700 leading-relaxed",
    ]
    scripts = [
        "const fetchData = async (url) => { const r = await fetch(url); return r.json(); };",
        "document.querySelectorAll('.card').forEach((el, i) => el.dataset.idx = i);",
        "function formatBytes(n) { return (n / 1024).toFixed(2) + ' KiB'; }",
    ]
    total = 0
    idx = 0
    while total < target_bytes:
        state = (state * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        tag = tags[(state >> 16) % len(tags)]
        cls = classes[(state >> 24) % len(classes)]
        js = scripts[(state >> 32) % len(scripts)]
        frag = (
            f'<{tag} id="node-{idx}" class="{cls}" data-ts="2026-11-24T{(idx//60)%24:02d}:{idx%60:02d}Z">\n'
            f'  <h2>Section {idx % 64}: Zstandard RFC 8878 Web Asset Payload</h2>\n'
            f'  <p style="color:#334155;margin:8px 0">Item {idx} value={(state >> 8) % 99991} '
            f'json={{"ok":true,"id":{idx},"ratio":{(state >> 40) % 100}}}</p>\n'
            f'  <script>{js}</script>\n'
            f'</{tag}>\n'
        ).encode("utf-8")
        chunks.append(frag)
        total += len(frag)
        idx += 1
    return b"".join(chunks)[:target_bytes]


def gen_binary_log_corpus(target_bytes: int) -> bytes:
    chunks = []
    state = 0xD1B54A32D192ED03
    regions = [b"us-east-1", b"eu-west-1", b"ap-east-1", b"ap-south-1"]
    total = 0
    seq = 0
    while total < target_bytes:
        state = (state * 2862933555777941757 + 3037000493) & ((1 << 64) - 1)
        reg = regions[(state >> 20) % len(regions)]
        ts = 1795500000 + seq
        code = 200 if (seq % 7) else 503
        lat_us = (state >> 12) % 8192
        flags = (seq & 0x0F) | 0x80
        # 24-byte structured binary header + repeated telemetry tag
        rec = struct.pack("<IQHHII", seq, ts, code, flags, lat_us, len(reg)) + reg + b"\x00\x00\x01\xff"
        if seq % 11 == 0:
            rec += b"\x00" * 32
        chunks.append(rec)
        total += len(rec)
        seq += 1
    return b"".join(chunks)[:target_bytes]


def gen_parity_cases(out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    cases = {
        "empty.bin": b"",
        "one_byte.bin": b"X",
        "rle_64k.bin": b"A" * 65536,
        "rle_200k.bin": b"\x5A" * 204800,
        "high_entropy_32k.bin": bytes(
            ((i * 1103515245 + 12345) >> 16) & 0xFF for i in range(32768)
        ),
        "cjk_utf8.bin": (
            "纯 Pion 零外部依赖 RFC 8878 Zstandard 压缩与解压器测试语料！日本語テスト・한국어 테스트。\n" * 400
        ).encode("utf-8"),
        "web_1m.bin": gen_web_corpus(1024 * 1024),
        "binlog_1m.bin": gen_binary_log_corpus(1024 * 1024),
    }
    for name, data in cases.items():
        with open(os.path.join(out_dir, name), "wb") as f:
            f.write(data)
    print(f"Generated {len(cases)} deterministic corpora in {out_dir}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: gen_corpus.py <out_dir>", file=sys.stderr)
        sys.exit(1)
    gen_parity_cases(sys.argv[1])
