#!/usr/bin/env python3
"""Synthesize a deterministic 512-glyph TrueType variable font (zero external files)
for differential testing and benchmarking on environments without system fonts."""
import struct
import sys
import os


def pack_fixed(v: float) -> int:
    return int(round(v * 65536.0))


def build_sfnt(tables: dict[str, bytes]) -> bytes:
    tags = sorted(tables.keys())
    n = len(tags)
    header = struct.pack(">IHHHH", 0x00010000, n, 0, 0, 0)
    offset = 12 + n * 16
    records = []
    blobs = []
    for tag in tags:
        payload = tables[tag]
        records.append(struct.pack(">4sIII", tag.encode("ascii"), 0, offset, len(payload)))
        pad = (4 - (len(payload) % 4)) % 4
        blobs.append(payload + b"\x00" * pad)
        offset += len(payload) + pad
    return header + b"".join(records) + b"".join(blobs)


def build_synthetic_font(num_glyphs: int = 512) -> bytes:
    head = struct.pack(
        ">IIIIHHQQhhhhHHhhh",
        0x00010000, 0x00010000, 0, 0x5F0F3CF5,
        0x000B, 1000, 0, 0,
        -50, -200, 1050, 900,
        0, 8, 2, 1, 0,
    )
    maxp = struct.pack(">IH", 0x00010000, num_glyphs) + b"\x00" * 26
    num_h = num_glyphs - 16
    hhea = struct.pack(
        ">IhhhHhhhhhh8sH",
        0x00010000, 800, -200, 90, 1000, -20, 0, 980, 1, 0, 0, b"\x00" * 8, 0,
    )[:-2] + struct.pack(">hH", 0, num_h)
    hmtx_parts = [struct.pack(">Hh", 450 + (i % 15) * 30, (i % 7) * 5 - 10) for i in range(num_h)]
    hmtx_parts += [struct.pack(">h", (i % 5) * 4) for i in range(num_glyphs - num_h)]
    hmtx = b"".join(hmtx_parts)

    os2 = (
        struct.pack(">HhHHHhhhhhhhhhh", 4, 520, 400, 5, 0, 650, 600, 0, 75, 650, 600, 0, 350, 50, 260)
        + struct.pack(">h10s16s4sHHHhhhHH8shhHHH", 0, bytes(range(1, 11)), b"\x00" * 16, b"PION", 0x0040, 0x20, 0x220, 800, -200, 90, 900, 250, b"\x00" * 8, 520, 710, 0, 0x20, 2)
    )
    post = struct.pack(">IihhI16s", 0x00030000, 0, -100, 50, 0, b"\x00" * 16)

    # cmap fmt 12 mapping U+0020..U+0020+num_glyphs-2 -> gid 1..num_glyphs-1
    fmt12 = struct.pack(">HHIIIIII", 12, 0, 28, 0, 1, 0x20, 0x20 + num_glyphs - 2, 1)
    cmap = struct.pack(">HHHH I", 0, 1, 3, 10, 12) + fmt12

    # kern fmt 0 with 128 sorted pairs
    pairs = []
    for i in range(1, 129):
        pairs.append(struct.pack(">HHh", i, i + 1, -10 - (i % 30)))
    sub_len = 6 + 8 + len(pairs) * 6
    kern = struct.pack(">HHHHHHH HHH", 0, 1, 0, sub_len, 0x0001, len(pairs), 0, 0, 0, 0)[:18]
    kern = (
        struct.pack(">HH", 0, 1)
        + struct.pack(">HHH", 0, sub_len, 0x0001)
        + struct.pack(">HHHH", len(pairs), 0, 0, 0)
        + b"".join(pairs)
    )

    # fvar with 2 axes (wght, wdth)
    fvar = (
        struct.pack(">HHHHHHHH", 1, 0, 16, 2, 2, 20, 0, 12)
        + struct.pack(">4siiiHH", b"wght", pack_fixed(100), pack_fixed(400), pack_fixed(900), 0, 256)
        + struct.pack(">4siiiHH", b"wdth", pack_fixed(75), pack_fixed(100), pack_fixed(125), 0, 257)
    )

    # loca + glyf: gid 0 empty, gid 1..449 simple curves, gid 450..511 compound glyphs
    loca_entries = []
    glyf_blobs = []
    off = 0
    for g in range(num_glyphs):
        loca_entries.append(struct.pack(">I", off))
        if g == 0:
            blob = b""
        elif g < 450:
            w = 100 + (g % 20) * 20
            h = 150 + (g % 15) * 30
            blob = struct.pack(
                ">hhhhhHH4B4h4h",
                1, 0, 0, w, h,
                3, 0,
                0x01, 0x00, 0x00, 0x01,
                0, w // 3, w // 3, w - 2 * (w // 3),
                0, h, 0, -h,
            )
            pad = (4 - (len(blob) % 4)) % 4
            blob += b"\x00" * pad
        else:
            ref = (g % 100) + 1
            blob = struct.pack(
                ">hhhhhHHhh",
                -1, 10, 10, 600, 600,
                0x0003, ref, 10, 10,
            )
            pad = (4 - (len(blob) % 4)) % 4
            blob += b"\x00" * pad
        glyf_blobs.append(blob)
        off += len(blob)
    loca_entries.append(struct.pack(">I", off))

    return build_sfnt({
        "head": head,
        "maxp": maxp,
        "hhea": hhea,
        "hmtx": hmtx,
        "OS/2": os2,
        "post": post,
        "cmap": cmap,
        "kern": kern,
        "fvar": fvar,
        "loca": b"".join(loca_entries),
        "glyf": b"".join(glyf_blobs),
    })


def main() -> None:
    out_path = sys.argv[1]
    data = build_synthetic_font(512)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(data)
    print(len(data))


if __name__ == "__main__":
    main()
