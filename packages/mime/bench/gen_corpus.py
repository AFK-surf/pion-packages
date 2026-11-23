#!/usr/bin/env python3
"""Deterministic corpus generator for packages/mime head-to-head benchmarks."""

import os
import struct
import sys


def gen_multipart_50mb(out_path: str) -> int:
    boundary = b"pion-bench-boundary-2026"
    parts = []
    # 200 small form fields
    for i in range(200):
        name = f"field_{i:03d}".encode("ascii")
        val = f"value-{i}-alpha-beta-gamma-0123456789".encode("ascii")
        parts.append(
            b"--" + boundary + b"\r\n"
            b'Content-Disposition: form-data; name="' + name + b'"\r\n'
            b"\r\n" + val + b"\r\n"
        )
    # 10 large binary attachments (~5 MiB each = ~50 MiB total)
    # Deterministic non-boundary binary pattern
    block_1k = bytes(((j * 37 + 13) & 0xFF) for j in range(1024))
    payload_5m = block_1k * (5 * 1024)
    for i in range(10):
        fname = f"artifact_{i}.bin".encode("ascii")
        parts.append(
            b"--" + boundary + b"\r\n"
            b'Content-Disposition: form-data; name="file_' + str(i).encode("ascii") + b'"; filename="' + fname + b'"\r\n'
            b"Content-Type: application/octet-stream\r\n"
            b"\r\n" + payload_5m + b"\r\n"
        )
    parts.append(b"--" + boundary + b"--\r\n")
    data = b"".join(parts)
    with open(out_path, "wb") as f:
        f.write(data)
    return len(data)


def gen_headers_full(out_path: str) -> int:
    templates = [
        'M\ttext/html; charset=UTF-8',
        'M\tapplication/vnd.api+json; version="1.0"; profile="https://example.com/spec"',
        'M\tmultipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW',
        'M\tapplication/x-stuff; title*=us-ascii\'en-us\'This%20is%20%2A%2A%2Afun%2A%2A%2A',
        'D\tattachment; filename="report-2026.pdf"',
        'D\tattachment; filename="fallback.txt"; filename*=UTF-8\'\'%E4%B8%AD%E6%96%87%E6%96%87%E6%A1%A3.txt',
        'D\tform-data; name="avatar"; filename="profile_pic.png"',
        'W\t=?UTF-8?Q?=C2=A1Hola,_se=C3=B1or!?=',
        'W\t=?UTF-8?B?5Lit5paH5rWL6K+V?= =?UTF-8?Q?Fran=C3=A7ois-J=C3=A9r=C3=B4me?=',
        'W\t=?ISO-8859-1?Q?Rapha=EBl_Dupont?=',
    ]
    lines = [templates[i % len(templates)] for i in range(1000)]
    data = ("\n".join(lines) + "\n").encode("utf-8")
    with open(out_path, "wb") as f:
        f.write(data)
    return len(data)


def gen_headers_mt(out_path: str) -> int:
    templates = [
        'text/html; charset=utf-8',
        'application/json; charset=utf-8',
        'application/vnd.api+json; version="1.0"',
        'multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW',
        'image/svg+xml',
        'text/plain; charset=iso-8859-1; format=flowed',
        'application/octet-stream',
        'application/xml; charset=utf-8',
        'font/woff2',
        'audio/mpeg',
    ]
    lines = [templates[i % len(templates)] for i in range(1000)]
    data = ("\n".join(lines) + "\n").encode("utf-8")
    with open(out_path, "wb") as f:
        f.write(data)
    return len(data)


def gen_qp_16mb(out_path: str) -> int:
    # Realistic 76-col soft-wrapped Quoted-Printable block (~256 bytes) repeated to ~16 MiB
    chunk = (
        b"Quoted-Printable (QP) est un format d'encodage de donn=C3=A9es cod=C3=A9es =\r\n"
        b"sur 8 bits, qui utilise exclusivement les caract=C3=A8res imprimables ASCII=\r\n"
        b" (7 bits). Exemple=3Dtest=20\r\n"
        b"Now's the time for all folk to come to the aid of their country=21=09\r\n"
    )
    reps = (16 * 1024 * 1024) // len(chunk) + 1
    data = chunk * reps
    with open(out_path, "wb") as f:
        f.write(data)
    return len(data)


def gen_sniff_100k(out_path: str) -> int:
    # Samples where magic-byte sniffing returns standard MIME types
    tar_buf = bytearray(265)
    tar_buf[257:262] = b"ustar"
    samples = [
        bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + b"\x00" * 24,  # image/png
        bytes([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) + b"JFIF\x00" + b"\x00" * 21,  # image/jpeg
        b"GIF89a\x01\x00\x01\x00" + b"\x00" * 22,  # image/gif
        b"RIFF\x24\x00\x00\x00WEBPVP8 " + b"\x00" * 16,  # image/webp
        bytes([0x42, 0x4D, 0x36, 0x00, 0x00, 0x00]) + b"\x00" * 26,  # image/bmp
        bytes([0x00, 0x00, 0x01, 0x00, 0x01, 0x00]) + b"\x00" * 26,  # image/x-icon
        b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n" + b"0" * 18,  # application/pdf
        bytes([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00]) + b"\x00" * 26,  # application/zip
        bytes([0x1F, 0x8B, 0x08, 0x00]) + b"\x00" * 28,  # application/gzip
        bytes([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58]) + b"\x00" * 26,  # application/zstd
        bytes(tar_buf),  # application/x-tar
        bytes([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]) + b"\x00" * 24,  # application/wasm
        bytes([0x00, 0x00, 0x00, 0x18]) + b"ftypisom\x00\x00\x02\x00isom" + b"\x00" * 12,  # video/mp4
        b"ID3\x03\x00\x00\x00\x00\x00\x00" + b"\x00" * 22,  # audio/mpeg
        b"OggS\x00\x02\x00\x00" + b"\x00" * 24,  # application/ogg
        b"fLaC\x00\x00\x00\x22" + b"\x00" * 24,  # audio/flac
        b"RIFF\x24\x00\x00\x00WAVEfmt " + b"\x00" * 16,  # audio/wav
        b"wOFF\x00\x01\x00\x00" + b"\x00" * 24,  # font/woff
        b"wOF2\x00\x01\x00\x00" + b"\x00" * 24,  # font/woff2
        b"SQLite format 3\x00\x10\x00" + b"\x00" * 14,  # application/vnd.sqlite3
    ]
    # Pack 100 samples (5x the 20 base types) as [u32_le len][bytes]
    out = bytearray()
    for i in range(100):
        s = samples[i % len(samples)]
        out.extend(struct.pack("<I", len(s)))
        out.extend(s)
    with open(out_path, "wb") as f:
        f.write(out)
    return len(out)


def main() -> None:
    if len(sys.argv) < 2:
        print("usage: gen_corpus.py <out_dir>", file=sys.stderr)
        sys.exit(1)
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    n1 = gen_multipart_50mb(os.path.join(out_dir, "multipart_50mb.bin"))
    n2 = gen_headers_full(os.path.join(out_dir, "headers_full.txt"))
    n3 = gen_headers_mt(os.path.join(out_dir, "headers_mt.txt"))
    n4 = gen_qp_16mb(os.path.join(out_dir, "qp_16mb.bin"))
    n5 = gen_sniff_100k(os.path.join(out_dir, "sniff_100k.bin"))
    print(f"generated: multipart={n1}B headers_full={n2}B headers_mt={n3}B qp={n4}B sniff={n5}B")


if __name__ == "__main__":
    main()
