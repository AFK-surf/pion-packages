#!/usr/bin/env python3
"""Generate deterministic synthetic Display-P3 v4 ICC profile and 1920x1080 RGBA8 frame."""
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


def build_display_p3_v4() -> bytes:
    trc = make_para3(2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045)
    chad = make_sf32(
        [
            1.047882, 0.022919, -0.050201,
            0.029587, 0.990479, -0.017059,
            -0.009232, 0.015076, 0.751678,
        ]
    )
    tags = [
        (b"desc", make_mluc("Display P3")),
        (b"wtpt", make_xyz(0.950455, 1.0, 1.089050)),
        (b"rXYZ", make_xyz(0.515121, 0.241196, -0.001053)),
        (b"gXYZ", make_xyz(0.291977, 0.692245, 0.041885)),
        (b"bXYZ", make_xyz(0.157104, 0.066574, 0.784073)),
        (b"rTRC", trc),
        (b"chad", chad),
    ]
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
    hdr[8:12] = bytes([4, 0, 0, 0])
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


def main() -> None:
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    icc = build_display_p3_v4()
    icc_path = os.path.join(out_dir, "display_p3_v4.icc")
    with open(icc_path, "wb") as f:
        f.write(icc)

    # 1920x1080 RGBA8 deterministic smooth + colorful test image (8,294,400 bytes)
    w, h = 1920, 1080
    buf = bytearray(w * h * 4)
    # Build one row pattern and vary across rows for fast generation in Python
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
    print(f"{len(icc)} {len(buf)}")


if __name__ == "__main__":
    main()
