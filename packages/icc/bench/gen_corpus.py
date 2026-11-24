#!/usr/bin/env python3
"""Generate deterministic synthetic ICC profiles (Display-P3 v4, sRGB v2 curv[1024],
AdobeRGB v2 gamma, Rec.2020 para3) and a 1920x1080 RGBA8 frame for fair head-to-head benchmarks."""
import os
import struct
import sys


def s15f16(v: float) -> bytes:
    scaled = int(round(v * 65536.0))
    return struct.pack(">i", scaled)


def make_xyz(x: float, y: float, z: float) -> bytes:
    return b"XYZ \x00\x00\x00\x00" + s15f16(x) + s15f16(y) + s15f16(z)


def make_para3(g: float, a: float, b: float, c: float, d: float) -> bytes:
    return (
        b"para\x00\x00\x00\x00"
        + struct.pack(">HH", 3, 0)
        + s15f16(g)
        + s15f16(a)
        + s15f16(b)
        + s15f16(c)
        + s15f16(d)
    )


def make_curv_gamma(g: float) -> bytes:
    return b"curv\x00\x00\x00\x00" + struct.pack(">IH", 1, int(round(g * 256.0)))


def make_curv_table(entries) -> bytes:
    return b"curv\x00\x00\x00\x00" + struct.pack(">I", len(entries)) + b"".join(struct.pack(">H", e) for e in entries)


def make_desc_v2(text: bytes) -> bytes:
    return b"desc\x00\x00\x00\x00" + struct.pack(">I", len(text) + 1) + text + b"\x00" + b"\x00" * 78


def make_mluc(text: str) -> bytes:
    u16 = text.encode("utf-16-be")
    return (
        b"mluc\x00\x00\x00\x00"
        + struct.pack(">II", 1, 12)
        + b"enUS"
        + struct.pack(">II", len(u16), 28)
        + u16
    )


def make_sf32(vals) -> bytes:
    return b"sf32\x00\x00\x00\x00" + b"".join(s15f16(v) for v in vals)


def build_rgb_profile(ver_major: int, ver_minor_byte: int, desc_tag: bytes, r, g, b, trc: bytes, chad=None) -> bytes:
    tags = [
        (b"desc", desc_tag),
        (b"wtpt", make_xyz(0.96420288, 1.0, 0.82490540)),
        (b"rXYZ", make_xyz(*r)),
        (b"gXYZ", make_xyz(*g)),
        (b"bXYZ", make_xyz(*b)),
        (b"rTRC", trc),
    ]
    if chad is not None:
        tags.append((b"chad", make_sf32(chad)))
    aliases = [(b"gTRC", b"rTRC"), (b"bTRC", b"rTRC")]
    total_tags = len(tags) + len(aliases)
    cur = (128 + 4 + total_tags * 12 + 3) & ~3
    offsets = {}
    sizes = {}
    body = bytearray()
    for sig, payload in tags:
        offsets[sig] = cur
        sizes[sig] = len(payload)
        pad = (4 - (len(payload) % 4)) % 4
        body.extend(payload)
        body.extend(b"\x00" * pad)
        cur += len(payload) + pad
    profile_size = cur

    hdr = bytearray(128)
    struct.pack_into(">I", hdr, 0, profile_size)
    hdr[4:8] = b"pion"
    hdr[8:12] = bytes([ver_major, ver_minor_byte, 0, 0])
    hdr[12:16] = b"mntr"
    hdr[16:20] = b"RGB "
    hdr[20:24] = b"XYZ "
    struct.pack_into(">HHHHHH", hdr, 24, 2026, 11, 24, 0, 0, 0)
    hdr[36:40] = b"acsp"
    hdr[40:44] = b"APPL"
    hdr[68:80] = s15f16(0.96420288) + s15f16(1.0) + s15f16(0.82490540)

    table = bytearray(struct.pack(">I", total_tags))
    for sig, _ in tags:
        table.extend(struct.pack(">4sII", sig, offsets[sig], sizes[sig]))
    for new_sig, target_sig in aliases:
        table.extend(struct.pack(">4sII", new_sig, offsets[target_sig], sizes[target_sig]))
    while (128 + len(table)) % 4 != 0:
        table.append(0)
    return bytes(hdr + table + body)


def srgb_eotf(x: float) -> float:
    return x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4


CHAD_D65 = [
    1.047882, 0.022919, -0.050201,
    0.029587, 0.990479, -0.017059,
    -0.009232, 0.015076, 0.751678,
]


def main() -> None:
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    p3 = build_rgb_profile(
        4, 0x00, make_mluc("Display P3"),
        (0.515121, 0.241196, -0.001053),
        (0.291977, 0.692245, 0.041885),
        (0.157104, 0.066574, 0.784073),
        make_para3(2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045),
        CHAD_D65,
    )
    srgb_curv = make_curv_table([int(round(srgb_eotf(i / 1023.0) * 65535.0)) for i in range(1024)])
    srgb_v2 = build_rgb_profile(
        2, 0x10, make_desc_v2(b"sRGB IEC61966-2.1"),
        (0.436066, 0.222488, 0.013916),
        (0.385147, 0.716873, 0.097076),
        (0.143066, 0.060608, 0.714096),
        srgb_curv,
    )
    adobe_v2 = build_rgb_profile(
        2, 0x10, make_desc_v2(b"Adobe RGB (1998)"),
        (0.609741, 0.311111, 0.019470),
        (0.205276, 0.625671, 0.060867),
        (0.149185, 0.063217, 0.744568),
        make_curv_gamma(563.0 / 256.0),
    )
    rec2020 = build_rgb_profile(
        4, 0x30, make_mluc("Rec.2020"),
        (0.673459, 0.279033, -0.001931),
        (0.165661, 0.675338, 0.029979),
        (0.125100, 0.045629, 0.797162),
        make_para3(1.0 / 0.45, 1.0 / 1.099, 0.099 / 1.099, 1.0 / 4.5, 0.081),
        CHAD_D65,
    )

    for fname, blob in (
        ("display_p3_v4.icc", p3),
        ("srgb_v2_curv1024.icc", srgb_v2),
        ("adobe_v2_gamma.icc", adobe_v2),
        ("rec2020_para3_709.icc", rec2020),
    ):
        with open(os.path.join(out_dir, fname), "wb") as f:
            f.write(blob)

    # 1920x1080 RGBA8 deterministic smooth + colorful test image (8,294,400 bytes)
    w, h = 1920, 1080
    buf = bytearray(w * h * 4)
    idx = 0
    for y in range(h):
        g_base = (y * 255) // (h - 1)
        b_base = ((y * 7) ^ 0x5A) & 0xFF
        a_base = (128 + (y & 127)) & 0xFF
        row = bytearray(w * 4)
        for x in range(w):
            o = x * 4
            row[o] = (x * 255) // (w - 1)
            row[o + 1] = (g_base + (x & 31)) & 0xFF
            row[o + 2] = (b_base + ((x >> 2) & 63)) & 0xFF
            row[o + 3] = a_base
        buf[idx : idx + w * 4] = row
        idx += w * 4
    rgba_path = os.path.join(out_dir, "frame_1080p.rgba")
    with open(rgba_path, "wb") as f:
        f.write(buf)
    print(f"{len(p3)} {len(buf)} {len(srgb_v2)} {len(adobe_v2)} {len(rec2020)}")


if __name__ == "__main__":
    main()
