#!/usr/bin/env python3
"""Fairness probe for packages/exif/bench: same 4 file names as bench/gen_corpus.py, but camera-sized EXIF.

    gen_bench_real.py <out_dir> <makernote_bytes>

  camera_iphone.jpg  APP0 + EXIF APP1 (IFD0 12, ExifIFD 38 incl. MakerNote, GPS 14, Interop 2, IFD1 6 tags +
                     an 11 KB thumbnail) + XMP APP1 + ICC APP2 + DQT/SOF/DHT/SOS + 256 KB scan data
  camera_be.tiff     the same TIFF block, big-endian, no strip data (kamadak reads a raw TIFF whole)
  photo_webp.webp    VP8X + ICCP + VP8L + EXIF (LE)
  photo_png.png      IHDR + eXIf (BE) + IDAT + IEND
Prints the total corpus size in bytes (like gen_corpus.py).
"""

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen import (ASCII, BYTE, E, LONG, RATIONAL, SHORT, SRATIONAL, UNDEF, asc, build_tiff, jpeg, png, png_chunk, IHDR,  # noqa: E402
                 IEND, riff_chunk, seg, webp, VP8X, ICCP, VP8L, JFIF, XMP)


def camera(be, mn):
    thumb = b"\xff\xd8" + bytes((i * 7) & 0xFF for i in range(11000)) + b"\xff\xd9"
    ifds = {
        "ifd0": {"entries": [
            E(0x010F, ASCII, asc("Apple")), E(0x0110, ASCII, asc("iPhone 16 Pro")), E(0x0112, SHORT, [6]),
            E(0x011A, RATIONAL, [(72, 1)]), E(0x011B, RATIONAL, [(72, 1)]), E(0x0128, SHORT, [2]),
            E(0x0131, ASCII, asc("18.1")), E(0x0132, ASCII, asc("2026:11:24 09:30:00")),
            E(0x013C, ASCII, asc("iPhone 16 Pro")), E(0x0213, SHORT, [1]),
            E(0x8769, LONG, ptr="exif"), E(0x8825, LONG, ptr="gps")], "next": "ifd1"},
        "exif": {"entries": [
            E(0x829A, RATIONAL, [(1, 121)]), E(0x829D, RATIONAL, [(178, 100)]), E(0x8822, SHORT, [2]),
            E(0x8827, SHORT, [64]), E(0x9000, UNDEF, b"0232"), E(0x9003, ASCII, asc("2026:11:24 09:30:00")),
            E(0x9004, ASCII, asc("2026:11:24 09:30:00")), E(0x9010, ASCII, asc("+09:00")),
            E(0x9011, ASCII, asc("+09:00")), E(0x9012, ASCII, asc("+09:00")), E(0x9101, UNDEF, b"\x01\x02\x03\x00"),
            E(0x9201, SRATIONAL, [(691947, 99950)]), E(0x9202, RATIONAL, [(14447, 8530)]),
            E(0x9203, SRATIONAL, [(44357, 6981)]), E(0x9204, SRATIONAL, [(0, 1)]), E(0x9207, SHORT, [5]),
            E(0x9209, SHORT, [16]), E(0x920A, RATIONAL, [(6765, 1000)]), E(0x9214, SHORT, [2009, 1502, 2208, 1387]),
            E(0x927C, UNDEF, b"Apple iOS\0\0\x01MM" + bytes((i * 31) & 0xFF for i in range(mn))),
            E(0x9290, ASCII, asc("123")), E(0x9291, ASCII, asc("123")), E(0x9292, ASCII, asc("123")),
            E(0xA000, UNDEF, b"0100"), E(0xA001, SHORT, [1]), E(0xA002, LONG, [4032]), E(0xA003, LONG, [3024]),
            E(0xA217, SHORT, [2]), E(0xA301, UNDEF, b"\x01"), E(0xA402, SHORT, [0]), E(0xA403, SHORT, [0]),
            E(0xA405, SHORT, [24]), E(0xA406, SHORT, [0]),
            E(0xA432, RATIONAL, [(1559, 1000), (9, 1), (178, 100), (28, 10)]), E(0xA433, ASCII, asc("Apple")),
            E(0xA434, ASCII, asc("iPhone 16 Pro back triple camera 6.765mm f/1.78")),
            E(0xA460, SHORT, [2]), E(0xA005, LONG, ptr="interop")]},
        "gps": {"entries": [
            E(0x0001, ASCII, asc("N")), E(0x0002, RATIONAL, [(35, 1), (40, 1), (3450, 100)]),
            E(0x0003, ASCII, asc("E")), E(0x0004, RATIONAL, [(139, 1), (45, 1), (1234, 100)]),
            E(0x0005, BYTE, [0]), E(0x0006, RATIONAL, [(42500, 1000)]),
            E(0x0007, RATIONAL, [(0, 1), (30, 1), (0, 1)]), E(0x000C, ASCII, asc("K")),
            E(0x000D, RATIONAL, [(0, 1)]), E(0x0010, ASCII, asc("T")), E(0x0011, RATIONAL, [(1832, 10)]),
            E(0x0017, ASCII, asc("T")), E(0x0018, RATIONAL, [(1832, 10)]), E(0x001D, ASCII, asc("2026:11:24"))]},
        "interop": {"entries": [E(0x0001, ASCII, asc("R98")), E(0x0002, UNDEF, b"0100")]},
        "ifd1": {"entries": [E(0x0103, SHORT, [6]), E(0x011A, RATIONAL, [(72, 1)]), E(0x011B, RATIONAL, [(72, 1)]),
                             E(0x0128, SHORT, [2]), E(0x0201, LONG, [0]), E(0x0202, LONG, [len(thumb)])]},
    }
    t = bytearray(build_tiff(be, ifds))
    # append the thumbnail and point JPEGInterchangeFormat at it (a real APP1 carries it, nobody decodes it)
    e = ">" if be else "<"
    off = len(t)
    t += thumb
    i = t.find(struct.pack(e + "HHI", 0x0201, LONG, 1))
    t[i + 8:i + 12] = struct.pack(e + "I", off)
    return bytes(t)


def main():
    out, mn = sys.argv[1], int(sys.argv[2])
    os.makedirs(out, exist_ok=True)
    le, be = camera(False, mn), camera(True, mn)
    icc = seg(0xE2, b"ICC_PROFILE\0\x01\x01" + bytes(560))
    scan = bytes((i * 13 + 1) & 0x7F for i in range(256 * 1024))
    tail = (seg(0xDB, bytes(130)) + seg(0xC0, b"\x08\x0b\xd0\x0f\xc0\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01")
            + seg(0xC4, bytes(418)) + b"\xff\xda\x00\x0c\x03\x01\x00\x02\x11\x03\x11\x00\x3f\x00" + scan + b"\xff\xd9")
    files = {
        "camera_iphone.jpg": jpeg(le, before=[JFIF], after=XMP + icc + tail),
        "camera_be.tiff": be,
        "photo_webp.webp": webp([VP8X, ICCP, VP8L, riff_chunk(b"EXIF", le)]),
        "photo_png.png": png([IHDR, png_chunk(b"eXIf", be), png_chunk(b"IDAT", b"\x78\x9c" + bytes(4000)), IEND]),
    }
    total = 0
    for k, v in files.items():
        with open(os.path.join(out, k), "wb") as f:
            f.write(v)
        total += len(v)
    print(total)


if __name__ == "__main__":
    main()
