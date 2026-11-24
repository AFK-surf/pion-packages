#!/usr/bin/env python3
"""Deterministic camera-sized EXIF benchmark corpus generator (JPEG, Big-Endian TIFF, WebP, PNG).

Generates realistic smartphone/DSLR-scale metadata matching `audit/diff/gen_bench_real.py`:
  - IFD0 (12 tags), ExifIFD (38 tags incl. 30 KB MakerNote), GPSIFD (14 tags),
    InteropIFD (2 tags), IFD1 (6 tags + 11 KB JPEG thumbnail)
  - `camera_iphone.jpg`: APP0 + EXIF APP1 (LE) + XMP APP1 + ICC APP2 + DQT/SOF/DHT/SOS + 256 KB scan
  - `camera_be.tiff`: same camera TIFF block in Big-Endian
  - `photo_webp.webp`: VP8X + ICCP (odd-padded) + VP8L + EXIF (LE)
  - `photo_png.png`: IHDR + eXIf (BE) + IDAT (4 KB) + IEND
"""

import os
import struct
import sys

BYTE, ASCII, SHORT, LONG, RATIONAL, SBYTE, UNDEF, SSHORT, SLONG, SRATIONAL = (
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
)

DEFAULT_MAKERNOTE_BYTES = 30000


def enc_values(e: str, typ: int, vals):
    if typ in (BYTE, UNDEF, ASCII) and isinstance(vals, (bytes, bytearray)):
        return len(vals), bytes(vals)
    if typ == BYTE:
        return len(vals), bytes(v & 0xFF for v in vals)
    if typ == SHORT:
        return len(vals), b"".join(struct.pack(e + "H", v) for v in vals)
    if typ == LONG:
        return len(vals), b"".join(struct.pack(e + "I", v) for v in vals)
    if typ == RATIONAL:
        return len(vals), b"".join(struct.pack(e + "II", n, d) for n, d in vals)
    if typ == SRATIONAL:
        return len(vals), b"".join(struct.pack(e + "ii", n, d) for n, d in vals)
    raise ValueError(typ)


def asc(s: str) -> bytes:
    return s.encode("ascii") + b"\x00"


def build_tiff(be: bool, ifds: dict) -> bytes:
    e = ">" if be else "<"
    order = list(ifds.keys())
    pos = 8
    offs = {}
    for name in order:
        offs[name] = pos
        pos += 2 + 12 * len(ifds[name]["entries"]) + 4
    data = bytearray()
    data_base = pos
    out = bytearray(b"MM" if be else b"II")
    out += struct.pack(e + "HI", 42, offs[order[0]])
    for name in order:
        ents = ifds[name]["entries"]
        out += struct.pack(e + "H", len(ents))
        for tag, typ, val, ptr in ents:
            if ptr is not None:
                cnt, payload = enc_values(e, typ, [offs[ptr]])
            else:
                cnt, payload = enc_values(e, typ, val)
            out += struct.pack(e + "HHI", tag, typ, cnt)
            if len(payload) <= 4:
                out += payload + b"\x00" * (4 - len(payload))
            else:
                if len(data) % 2:
                    data += b"\x00"
                out += struct.pack(e + "I", data_base + len(data))
                data += payload
        nxt = ifds[name].get("next")
        out += struct.pack(e + "I", offs[nxt] if nxt is not None else 0)
    assert len(out) == data_base
    return bytes(out + data)


def build_camera_tiff(be: bool, mn_bytes: int = DEFAULT_MAKERNOTE_BYTES) -> bytes:
    thumb = b"\xff\xd8" + bytes((i * 7) & 0xFF for i in range(11000)) + b"\xff\xd9"
    ifds = {
        "ifd0": {
            "entries": [
                (0x010F, ASCII, asc("Apple"), None),
                (0x0110, ASCII, asc("iPhone 16 Pro"), None),
                (0x0112, SHORT, [6], None),
                (0x011A, RATIONAL, [(72, 1)], None),
                (0x011B, RATIONAL, [(72, 1)], None),
                (0x0128, SHORT, [2], None),
                (0x0131, ASCII, asc("18.1"), None),
                (0x0132, ASCII, asc("2026:11:24 09:30:00"), None),
                (0x013C, ASCII, asc("iPhone 16 Pro"), None),
                (0x0213, SHORT, [1], None),
                (0x8769, LONG, None, "exif"),
                (0x8825, LONG, None, "gps"),
            ],
            "next": "ifd1",
        },
        "exif": {
            "entries": [
                (0x829A, RATIONAL, [(1, 121)], None),
                (0x829D, RATIONAL, [(178, 100)], None),
                (0x8822, SHORT, [2], None),
                (0x8827, SHORT, [64], None),
                (0x9000, UNDEF, b"0232", None),
                (0x9003, ASCII, asc("2026:11:24 09:30:00"), None),
                (0x9004, ASCII, asc("2026:11:24 09:30:00"), None),
                (0x9010, ASCII, asc("+09:00"), None),
                (0x9011, ASCII, asc("+09:00"), None),
                (0x9012, ASCII, asc("+09:00"), None),
                (0x9101, UNDEF, b"\x01\x02\x03\x00", None),
                (0x9201, SRATIONAL, [(691947, 99950)], None),
                (0x9202, RATIONAL, [(14447, 8530)], None),
                (0x9203, SRATIONAL, [(44357, 6981)], None),
                (0x9204, SRATIONAL, [(0, 1)], None),
                (0x9207, SHORT, [5], None),
                (0x9209, SHORT, [16], None),
                (0x920A, RATIONAL, [(6765, 1000)], None),
                (0x9214, SHORT, [2009, 1502, 2208, 1387], None),
                (0x927C, UNDEF, b"Apple iOS\x00\x00\x01MM" + bytes((i * 31) & 0xFF for i in range(mn_bytes)), None),
                (0x9290, ASCII, asc("123"), None),
                (0x9291, ASCII, asc("123"), None),
                (0x9292, ASCII, asc("123"), None),
                (0xA000, UNDEF, b"0100", None),
                (0xA001, SHORT, [1], None),
                (0xA002, LONG, [4032], None),
                (0xA003, LONG, [3024], None),
                (0xA217, SHORT, [2], None),
                (0xA301, UNDEF, b"\x01", None),
                (0xA402, SHORT, [0], None),
                (0xA403, SHORT, [0], None),
                (0xA405, SHORT, [24], None),
                (0xA406, SHORT, [0], None),
                (0xA432, RATIONAL, [(1559, 1000), (9, 1), (178, 100), (28, 10)], None),
                (0xA433, ASCII, asc("Apple"), None),
                (0xA434, ASCII, asc("iPhone 16 Pro back triple camera 6.765mm f/1.78"), None),
                (0xA460, SHORT, [2], None),
                (0xA005, LONG, None, "interop"),
            ]
        },
        "gps": {
            "entries": [
                (0x0001, ASCII, asc("N"), None),
                (0x0002, RATIONAL, [(35, 1), (40, 1), (3450, 100)], None),
                (0x0003, ASCII, asc("E"), None),
                (0x0004, RATIONAL, [(139, 1), (45, 1), (1234, 100)], None),
                (0x0005, BYTE, [0], None),
                (0x0006, RATIONAL, [(42500, 1000)], None),
                (0x0007, RATIONAL, [(0, 1), (30, 1), (0, 1)], None),
                (0x000C, ASCII, asc("K"), None),
                (0x000D, RATIONAL, [(0, 1)], None),
                (0x0010, ASCII, asc("T"), None),
                (0x0011, RATIONAL, [(1832, 10)], None),
                (0x0017, ASCII, asc("T"), None),
                (0x0018, RATIONAL, [(1832, 10)], None),
                (0x001D, ASCII, asc("2026:11:24"), None),
            ]
        },
        "interop": {
            "entries": [
                (0x0001, ASCII, asc("R98"), None),
                (0x0002, UNDEF, b"0100", None),
            ]
        },
        "ifd1": {
            "entries": [
                (0x0103, SHORT, [6], None),
                (0x011A, RATIONAL, [(72, 1)], None),
                (0x011B, RATIONAL, [(72, 1)], None),
                (0x0128, SHORT, [2], None),
                (0x0201, LONG, [0], None),
                (0x0202, LONG, [len(thumb)], None),
            ]
        },
    }
    t = bytearray(build_tiff(be, ifds))
    e = ">" if be else "<"
    off = len(t)
    t += thumb
    i = t.find(struct.pack(e + "HHI", 0x0201, LONG, 1))
    t[i + 8 : i + 12] = struct.pack(e + "I", off)
    return bytes(t)


def seg(marker: int, payload: bytes) -> bytes:
    return bytes([0xFF, marker]) + struct.pack(">H", len(payload) + 2) + payload


def riff_chunk(fourcc: bytes, payload: bytes) -> bytes:
    pad = b"\x00" if (len(payload) & 1) else b""
    return fourcc + struct.pack("<I", len(payload)) + payload + pad


def png_chunk(ctype: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + ctype + payload + b"CRC_"


def wrap_jpeg(tiff: bytes) -> bytes:
    jfif = seg(0xE0, b"JFIF\x00\x01\x02\x00\x00\x01\x00\x01\x00\x00")
    xmp = seg(0xE1, b"http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta xmlns:x='adobe:ns:meta/'/>")
    icc = seg(0xE2, b"ICC_PROFILE\x00\x01\x01" + bytes(560))
    scan = bytes((i * 13 + 1) & 0x7F for i in range(256 * 1024))
    tail = (
        seg(0xDB, bytes(130))
        + seg(0xC0, b"\x08\x0b\xd0\x0f\xc0\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01")
        + seg(0xC4, bytes(418))
        + b"\xff\xda\x00\x0c\x03\x01\x00\x02\x11\x03\x11\x00\x3f\x00"
        + scan
        + b"\xff\xd9"
    )
    return b"\xff\xd8" + jfif + seg(0xE1, b"Exif\x00\x00" + tiff) + xmp + icc + tail


def wrap_webp(tiff: bytes) -> bytes:
    vp8x = riff_chunk(b"VP8X", bytes([0x08, 0, 0, 0]) + b"\x00\x00\x00\x00\x00\x00")
    iccp = riff_chunk(b"ICCP", b"\x00" * 7)
    vp8l = riff_chunk(b"VP8L", b"\x2f\x00\x00\x00\x00\x88\x88\x08\x00")
    body = b"WEBP" + vp8x + iccp + vp8l + riff_chunk(b"EXIF", tiff)
    return b"RIFF" + struct.pack("<I", len(body)) + body


def wrap_png(tiff: bytes) -> bytes:
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
    exif = png_chunk(b"eXIf", tiff)
    idat = png_chunk(b"IDAT", b"\x78\x9c" + bytes(4000))
    iend = png_chunk(b"IEND", b"")
    return sig + ihdr + exif + idat + iend


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: gen_corpus.py <out_dir> [makernote_bytes]", file=sys.stderr)
        return 1
    out_dir = sys.argv[1]
    mn_bytes = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_MAKERNOTE_BYTES
    os.makedirs(out_dir, exist_ok=True)

    tiff_le = build_camera_tiff(be=False, mn_bytes=mn_bytes)
    tiff_be = build_camera_tiff(be=True, mn_bytes=mn_bytes)

    files = {
        "camera_iphone.jpg": wrap_jpeg(tiff_le),
        "camera_be.tiff": tiff_be,
        "photo_webp.webp": wrap_webp(tiff_le),
        "photo_png.png": wrap_png(tiff_be),
    }
    total = 0
    for name, data in files.items():
        with open(os.path.join(out_dir, name), "wb") as f:
            f.write(data)
        total += len(data)
    print(total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
