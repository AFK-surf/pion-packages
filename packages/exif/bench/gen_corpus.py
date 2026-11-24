#!/usr/bin/env python3
"""Deterministic EXIF benchmark corpus generator (JPEG, Big-Endian TIFF, WebP, PNG)."""

import os
import struct
import sys


def build_camera_tiff(be: bool, orientation: int, lat_ref: str, lon_ref: str) -> bytes:
    e = ">" if be else "<"
    hdr = b"MM" if be else b"II"
    hdr += struct.pack(e + "HI", 42, 8)

    # Layout:
    # IFD0 at 8: 9 entries -> 2 + 108 + 4 = 114 -> ends 122
    # ExifIFD at 122: 10 entries -> 2 + 120 + 4 = 126 -> ends 248
    # GPSIFD at 248: 6 entries -> 2 + 72 + 4 = 78 -> ends 326
    # InteropIFD at 326: 2 entries -> 2 + 24 + 4 = 30 -> ends 356
    # IFD1 at 356: 1 entry -> 2 + 12 + 4 = 18 -> ends 374
    off_exif = 122
    off_gps = 248
    off_interop = 326
    off_ifd1 = 356
    data_base = 374
    ext = bytearray()

    def add_ext(b: bytes) -> int:
        off = data_base + len(ext)
        ext.extend(b)
        return off

    def entry_ext(tag: int, ftype: int, count: int, off: int) -> bytes:
        return struct.pack(e + "HHII", tag, ftype, count, off)

    def entry_inline(tag: int, ftype: int, count: int, raw4: bytes) -> bytes:
        assert len(raw4) == 4
        return struct.pack(e + "HHI", tag, ftype, count) + raw4

    def u16_inline(v: int) -> bytes:
        return struct.pack(e + "H", v) + b"\x00\x00"

    def u8_inline(v: int) -> bytes:
        return bytes([v, 0, 0, 0])

    off_make = add_ext(b"Apple\x00")
    off_model = add_ext(b"iPhone 16 Pro\x00")
    off_sw = add_ext(b"18.1\x00")
    off_dt = add_ext(b"2026:11:24 09:30:00\x00")
    off_xres = add_ext(struct.pack(e + "II", 72, 1))
    off_yres = add_ext(struct.pack(e + "II", 72, 1))
    off_exp = add_ext(struct.pack(e + "II", 1, 125))
    off_fnum = add_ext(struct.pack(e + "II", 178, 100))
    off_focal = add_ext(struct.pack(e + "II", 6765, 1000))
    off_lens = add_ext(b"iPhone 16 Pro back triple camera\x00")
    off_lat = add_ext(struct.pack(e + "IIIIII", 35, 1, 40, 1, 3450, 100))
    off_lon = add_ext(struct.pack(e + "IIIIII", 139, 1, 45, 1, 0, 1))
    off_alt = add_ext(struct.pack(e + "II", 425, 10))

    # IFD0 (9 entries)
    ifd0 = bytearray(struct.pack(e + "H", 9))
    ifd0 += entry_ext(0x010F, 2, 6, off_make)
    ifd0 += entry_ext(0x0110, 2, 14, off_model)
    ifd0 += entry_inline(0x0112, 3, 1, u16_inline(orientation))
    ifd0 += entry_ext(0x011A, 5, 1, off_xres)
    ifd0 += entry_ext(0x011B, 5, 1, off_yres)
    ifd0 += entry_ext(0x0131, 2, 5, off_sw)
    ifd0 += entry_ext(0x0132, 2, 20, off_dt)
    ifd0 += entry_ext(0x8769, 4, 1, off_exif)
    ifd0 += entry_ext(0x8825, 4, 1, off_gps)
    ifd0 += struct.pack(e + "I", off_ifd1)

    # ExifIFD (10 entries)
    exif_ifd = bytearray(struct.pack(e + "H", 10))
    exif_ifd += entry_ext(0x829A, 5, 1, off_exp)
    exif_ifd += entry_ext(0x829D, 5, 1, off_fnum)
    exif_ifd += entry_inline(0x8827, 3, 1, u16_inline(64))
    exif_ifd += entry_ext(0x9003, 2, 20, off_dt)
    exif_ifd += entry_ext(0x920A, 5, 1, off_focal)
    exif_ifd += entry_inline(0xA001, 3, 1, u16_inline(1))
    exif_ifd += entry_ext(0xA002, 4, 1, 4032)
    exif_ifd += entry_ext(0xA003, 4, 1, 3024)
    exif_ifd += entry_ext(0xA005, 4, 1, off_interop)
    exif_ifd += entry_ext(0xA434, 2, 33, off_lens)
    exif_ifd += struct.pack(e + "I", 0)

    # GPSIFD (6 entries)
    gps_ifd = bytearray(struct.pack(e + "H", 6))
    gps_ifd += entry_inline(0x0001, 2, 2, lat_ref.encode("ascii") + b"\x00\x00\x00")
    gps_ifd += entry_ext(0x0002, 5, 3, off_lat)
    gps_ifd += entry_inline(0x0003, 2, 2, lon_ref.encode("ascii") + b"\x00\x00\x00")
    gps_ifd += entry_ext(0x0004, 5, 3, off_lon)
    gps_ifd += entry_inline(0x0005, 1, 1, u8_inline(0))
    gps_ifd += entry_ext(0x0006, 5, 1, off_alt)
    gps_ifd += struct.pack(e + "I", 0)

    # InteropIFD (2 entries)
    interop_ifd = bytearray(struct.pack(e + "H", 2))
    interop_ifd += entry_inline(0x0001, 2, 4, b"R98\x00")
    interop_ifd += entry_inline(0x0002, 7, 4, b"0100")
    interop_ifd += struct.pack(e + "I", 0)

    # IFD1 (1 entry)
    ifd1 = bytearray(struct.pack(e + "H", 1))
    ifd1 += entry_inline(0x0103, 3, 1, u16_inline(6))
    ifd1 += struct.pack(e + "I", 0)

    out = bytes(hdr + ifd0 + exif_ifd + gps_ifd + interop_ifd + ifd1 + ext)
    assert len(hdr + ifd0) == off_exif
    assert len(hdr + ifd0 + exif_ifd) == off_gps
    assert len(hdr + ifd0 + exif_ifd + gps_ifd) == off_interop
    assert len(hdr + ifd0 + exif_ifd + gps_ifd + interop_ifd) == off_ifd1
    assert len(hdr + ifd0 + exif_ifd + gps_ifd + interop_ifd + ifd1) == data_base
    return out


def wrap_jpeg(tiff: bytes) -> bytes:
    buf = bytearray(b"\xFF\xD8")
    # APP0 JFIF
    app0 = b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    buf += b"\xFF\xE0" + struct.pack(">H", len(app0) + 2) + app0
    # XMP APP1 (to exercise skipping non-EXIF APP1)
    xmp = b"http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta/>"
    buf += b"\xFF\xFF\xE1" + struct.pack(">H", len(xmp) + 2) + xmp
    # EXIF APP1
    exif_seg = b"Exif\x00\x00" + tiff
    buf += b"\xFF\xE1" + struct.pack(">H", len(exif_seg) + 2) + exif_seg
    # Dummy SOS + scan data + EOI
    buf += b"\xFF\xDA\x00\x02" + (b"\x00" * 256) + b"\xFF\xD9"
    return bytes(buf)


def wrap_webp(tiff: bytes) -> bytes:
    junk = b"JUNK" + struct.pack("<I", 3) + b"\x01\x02\x03\x00"
    pad = b"\x00" if (len(tiff) & 1) else b""
    exif_chunk = b"EXIF" + struct.pack("<I", len(tiff)) + tiff + pad
    riff_size = 4 + len(junk) + len(exif_chunk)
    return b"RIFF" + struct.pack("<I", riff_size) + b"WEBP" + junk + exif_chunk


def wrap_png(tiff: bytes) -> bytes:
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr_data = struct.pack(">IIBBBBB", 4032, 3024, 8, 2, 0, 0, 0)
    ihdr = struct.pack(">I", len(ihdr_data)) + b"IHDR" + ihdr_data + b"\x00\x00\x00\x00"
    exif_chunk = struct.pack(">I", len(tiff)) + b"eXIf" + tiff + b"\x00\x00\x00\x00"
    iend = struct.pack(">I", 0) + b"IEND" + b"\x00\x00\x00\x00"
    return sig + ihdr + exif_chunk + iend


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: gen_corpus.py <out_dir>", file=sys.stderr)
        return 1
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    tiff_le = build_camera_tiff(be=False, orientation=6, lat_ref="N", lon_ref="E")
    tiff_be = build_camera_tiff(be=True, orientation=8, lat_ref="S", lon_ref="W")

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
