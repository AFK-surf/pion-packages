#!/usr/bin/env python3
"""Generate deterministic real-font WOFF2 and WOFF1 benchmark corpora in /tmp.

Uses real system TrueType fonts (Arial.ttf, Monaco.ttf) when available and
encodes them into spec-compliant WOFF 2.0 (with transformed glyf/loca/hmtx +
Brotli compression) and WOFF 1.0 (with per-table zlib compression).
"""
import os
import struct
import subprocess
import sys
import zlib

KNOWN_TAGS = [
    b"cmap", b"head", b"hhea", b"hmtx", b"maxp", b"name", b"OS/2", b"post",
    b"cvt ", b"fpgm", b"glyf", b"loca", b"prep", b"CFF ", b"VORG", b"EBDT",
    b"EBLC", b"gasp", b"hdmx", b"kern", b"LTSH", b"PCLT", b"VDMX", b"vhea",
    b"vmtx", b"BASE", b"GDEF", b"GPOS", b"GSUB", b"EBSC", b"JSTF", b"MATH",
    b"CBDT", b"CBLC", b"COLR", b"CPAL", b"SVG ", b"sbix", b"acnt", b"avar",
    b"bdat", b"bloc", b"bsln", b"cvar", b"fdsc", b"feat", b"fmtx", b"fvar",
    b"gvar", b"hsty", b"just", b"lcar", b"mort", b"morx", b"opbd", b"prop",
    b"trak", b"Zapf", b"Silf", b"Glat", b"Gloc", b"Feat", b"Sill",
]
KNOWN_TAG_INDEX = {tag: idx for idx, tag in enumerate(KNOWN_TAGS)}


def encode_base128(val: int) -> bytes:
    if val == 0:
        return b"\x00"
    out = bytearray()
    while val > 0:
        out.append(val & 0x7F)
        val >>= 7
    out.reverse()
    for i in range(len(out) - 1):
        out[i] |= 0x80
    return bytes(out)


def encode_255u16(val: int) -> bytes:
    if val < 253:
        return bytes([val])
    if val < 253 + 256:
        return bytes([255, val - 253])
    if val < 506 + 256:
        return bytes([254, val - 506])
    return bytes([253, (val >> 8) & 0xFF, val & 0xFF])


def brotli_compress(raw: bytes, quality: int = 6) -> bytes:
    res = subprocess.run(
        ["/opt/homebrew/bin/brotli", f"-q", str(quality), "-c"],
        input=raw,
        capture_output=True,
        check=True,
    )
    return res.stdout


def parse_sfnt(data: bytes):
    flavor, num_tables = struct.unpack_from(">IH", data, 0)
    tables = {}
    order = []
    for i in range(num_tables):
        tag, csum, off, length = struct.unpack_from(">4sIII", data, 12 + i * 16)
        tables[tag] = data[off : off + length]
        order.append((tag, csum))
    return flavor, tables, order


def sfnt_checksum(data: bytes) -> int:
    pad = (4 - (len(data) % 4)) % 4
    padded = data + b"\x00" * pad
    s = 0
    for (w,) in struct.iter_unpack(">I", padded):
        s = (s + w) & 0xFFFFFFFF
    return s


def encode_woff1(ttf_bytes: bytes) -> bytes:
    flavor, tables, order = parse_sfnt(ttf_bytes)
    num_tables = len(order)
    header_size = 44
    dir_size = num_tables * 20
    data_off = header_size + dir_size

    dir_entries = bytearray()
    table_blobs = bytearray()
    total_sfnt_size = 12 + num_tables * 16

    for tag, orig_csum in order:
        raw = tables[tag]
        orig_len = len(raw)
        total_sfnt_size += (orig_len + 3) & ~3
        comp = zlib.compress(raw, 9)
        if len(comp) < orig_len:
            stored = comp
        else:
            stored = raw
        comp_len = len(stored)
        off = data_off + len(table_blobs)
        dir_entries += struct.pack(">4sIIII", tag, off, comp_len, orig_len, orig_csum)
        table_blobs += stored
        pad = (4 - (comp_len % 4)) % 4
        if pad:
            table_blobs += b"\x00" * pad

    total_len = data_off + len(table_blobs)
    header = struct.pack(
        ">4sIIHHIHHIIIII",
        b"wOFF",
        flavor,
        total_len,
        num_tables,
        0,
        total_sfnt_size,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
    )
    return bytes(header + dir_entries + table_blobs)


def encode_triplet(dx: int, dy: int, on_curve: bool) -> tuple[int, bytes]:
    ax, ay = abs(dx), abs(dy)
    sx = 1 if dx >= 0 else 0
    sy = 1 if dy >= 0 else 0
    off_bit = 0 if on_curve else 0x80

    if dx == 0 and ay < 1280:
        hi = ay >> 8
        lo = ay & 0xFF
        f = (hi << 1) | sy
        return off_bit | f, bytes([lo])
    if dy == 0 and ax < 1280:
        hi = ax >> 8
        lo = ax & 0xFF
        f = 10 + ((hi << 1) | sx)
        return off_bit | f, bytes([lo])
    if 1 <= ax <= 64 and 1 <= ay <= 64:
        vx, vy = ax - 1, ay - 1
        f = 20 + ((vx & 0x30) | ((vy & 0x30) >> 2) | (sy << 1) | sx)
        b1 = ((vx & 0x0F) << 4) | (vy & 0x0F)
        return off_bit | f, bytes([b1])
    if 1 <= ax <= 768 and 1 <= ay <= 768:
        vx, vy = ax - 1, ay - 1
        b0 = (vx >> 8) * 12 + (vy >> 8) * 4 + (sy << 1) + sx
        return off_bit | (84 + b0), bytes([vx & 0xFF, vy & 0xFF])
    if ax < 4096 and ay < 4096:
        f = 120 + (sy << 1) + sx
        b0 = (ax >> 4) & 0xFF
        b1 = ((ax & 0x0F) << 4) | ((ay >> 8) & 0x0F)
        b2 = ay & 0xFF
        return off_bit | f, bytes([b0, b1, b2])
    f = 124 + (sy << 1) + sx
    return off_bit | f, struct.pack(">HH", ax & 0xFFFF, ay & 0xFFFF)


def transform_glyf(glyf: bytes, loca: bytes, head: bytes, maxp: bytes):
    num_glyphs = struct.unpack_from(">H", maxp, 4)[0]
    index_format = struct.unpack_from(">H", head, 50)[0]

    offsets = []
    if index_format == 0:
        for i in range(num_glyphs + 1):
            offsets.append(struct.unpack_from(">H", loca, i * 2)[0] * 2)
    else:
        for i in range(num_glyphs + 1):
            offsets.append(struct.unpack_from(">I", loca, i * 4)[0])

    s_ncont = bytearray()
    s_npts = bytearray()
    s_flags = bytearray()
    s_glyph = bytearray()
    s_comp = bytearray()
    s_bbox_data = bytearray()
    s_instr = bytearray()
    bitmap_len = ((num_glyphs + 31) >> 5) << 2
    bbox_bitmap = bytearray(bitmap_len)
    overlap_bitmap = bytearray((num_glyphs + 7) >> 3)
    has_any_overlap = False
    xmins = [0] * num_glyphs

    for gid in range(num_glyphs):
        g0, g1 = offsets[gid], offsets[gid + 1]
        if g0 == g1:
            s_ncont += struct.pack(">h", 0)
            continue

        ncont, x0, y0, x1, y1 = struct.unpack_from(">hhhhh", glyf, g0)
        xmins[gid] = x0
        s_ncont += struct.pack(">h", ncont)

        if ncont < 0:
            # Composite glyph: always explicit bbox
            bbox_bitmap[gid >> 3] |= 0x80 >> (gid & 7)
            s_bbox_data += struct.pack(">hhhh", x0, y0, x1, y1)
            pos = g0 + 10
            has_instr = False
            while True:
                flags, gidx = struct.unpack_from(">HH", glyf, pos)
                pos += 4
                n_args = 4 if (flags & 1) else 2
                if flags & 0x08:
                    n_scale = 2
                elif flags & 0x40:
                    n_scale = 4
                elif flags & 0x80:
                    n_scale = 8
                else:
                    n_scale = 0
                extra = glyf[pos : pos + n_args + n_scale]
                pos += n_args + n_scale
                s_comp += struct.pack(">HH", flags, gidx) + extra
                if flags & 0x0100:
                    has_instr = True
                if not (flags & 0x0020):
                    break
            if has_instr:
                ilen = struct.unpack_from(">H", glyf, pos)[0]
                pos += 2
                s_glyph += encode_255u16(ilen)
                s_instr += glyf[pos : pos + ilen]
        else:
            # Simple glyph
            pos = g0 + 10
            ends = list(struct.unpack_from(f">{ncont}H", glyf, pos))
            pos += ncont * 2
            prev_end = -1
            for e in ends:
                s_npts += encode_255u16(e - prev_end)
                prev_end = e
            total_pts = ends[-1] + 1 if ncont > 0 else 0

            ilen = struct.unpack_from(">H", glyf, pos)[0]
            pos += 2
            instr_bytes = glyf[pos : pos + ilen]
            pos += ilen

            # Decode TrueType flags (handling REPEAT_FLAG 0x08)
            raw_flags = []
            while len(raw_flags) < total_pts:
                fl = glyf[pos]
                pos += 1
                raw_flags.append(fl)
                if fl & 0x08:
                    rep = glyf[pos]
                    pos += 1
                    raw_flags.extend([fl] * rep)
            if total_pts > 0 and (raw_flags[0] & 0x40):
                overlap_bitmap[gid >> 3] |= 0x80 >> (gid & 7)
                has_any_overlap = True

            xs = []
            cur_x = 0
            for fl in raw_flags:
                if fl & 0x02:
                    dx = glyf[pos]
                    pos += 1
                    if not (fl & 0x10):
                        dx = -dx
                elif fl & 0x10:
                    dx = 0
                else:
                    dx = struct.unpack_from(">h", glyf, pos)[0]
                    pos += 2
                cur_x += dx
                xs.append(cur_x)

            ys = []
            cur_y = 0
            for fl in raw_flags:
                if fl & 0x04:
                    dy = glyf[pos]
                    pos += 1
                    if not (fl & 0x20):
                        dy = -dy
                elif fl & 0x20:
                    dy = 0
                else:
                    dy = struct.unpack_from(">h", glyf, pos)[0]
                    pos += 2
                cur_y += dy
                ys.append(cur_y)

            px, py = 0, 0
            for idx in range(total_pts):
                dx = xs[idx] - px
                dy = ys[idx] - py
                px, py = xs[idx], ys[idx]
                fl_byte, payload = encode_triplet(dx, dy, (raw_flags[idx] & 1) != 0)
                s_flags.append(fl_byte)
                s_glyph += payload

            s_glyph += encode_255u16(ilen)
            s_instr += instr_bytes

            # Emit explicit bbox if original bbox differs from computed point bounds
            if total_pts > 0:
                cx0, cy0, cx1, cy1 = min(xs), min(ys), max(xs), max(ys)
            else:
                cx0, cy0, cx1, cy1 = 0, 0, 0, 0
            if (cx0, cy0, cx1, cy1) != (x0, y0, x1, y1):
                bbox_bitmap[gid >> 3] |= 0x80 >> (gid & 7)
                s_bbox_data += struct.pack(">hhhh", x0, y0, x1, y1)

    s_bbox = bytes(bbox_bitmap) + bytes(s_bbox_data)
    streams = [
        bytes(s_ncont),
        bytes(s_npts),
        bytes(s_flags),
        bytes(s_glyph),
        bytes(s_comp),
        s_bbox,
        bytes(s_instr),
    ]
    option_flags = 1 if has_any_overlap else 0
    header = struct.pack(
        ">HHHH7I",
        0,
        option_flags,
        num_glyphs,
        index_format,
        *(len(s) for s in streams),
    )
    out = header + b"".join(streams)
    if has_any_overlap:
        out += bytes(overlap_bitmap)
    return out, xmins


def try_transform_hmtx(hmtx: bytes, hhea: bytes, maxp: bytes, xmins: list[int]):
    num_h_metrics = struct.unpack_from(">H", hhea, 34)[0]
    num_glyphs = struct.unpack_from(">H", maxp, 4)[0]
    advs = []
    lsbs = []
    pos = 0
    for _ in range(num_h_metrics):
        adv, lsb = struct.unpack_from(">Hh", hmtx, pos)
        pos += 4
        advs.append(adv)
        lsbs.append(lsb)
    for _ in range(num_h_metrics, num_glyphs):
        (lsb,) = struct.unpack_from(">h", hmtx, pos)
        pos += 2
        lsbs.append(lsb)

    prop_match = all(lsbs[i] == xmins[i] for i in range(num_h_metrics))
    mono_match = (num_glyphs > num_h_metrics) and all(
        lsbs[i] == xmins[i] for i in range(num_h_metrics, num_glyphs)
    )
    flags = (1 if prop_match else 0) | (2 if mono_match else 0)
    if flags == 0:
        return None

    out = bytearray([flags])
    for a in advs:
        out += struct.pack(">H", a)
    if not prop_match:
        for i in range(num_h_metrics):
            out += struct.pack(">h", lsbs[i])
    if not mono_match:
        for i in range(num_h_metrics, num_glyphs):
            out += struct.pack(">h", lsbs[i])
    return bytes(out)


def encode_woff2(ttf_bytes: bytes, quality: int = 6) -> bytes:
    flavor, tables, order = parse_sfnt(ttf_bytes)
    # WOFF 2.0 §5 requires `loca` to immediately follow `glyf` in the table directory.
    order = sorted(order, key=lambda item: item[0])
    glyf_pos = next((i for i, (t, _) in enumerate(order) if t == b"glyf"), -1)
    loca_pos = next((i for i, (t, _) in enumerate(order) if t == b"loca"), -1)
    if glyf_pos >= 0 and loca_pos >= 0 and loca_pos != glyf_pos + 1:
        loca_item = order.pop(loca_pos)
        glyf_pos = next(i for i, (t, _) in enumerate(order) if t == b"glyf")
        order.insert(glyf_pos + 1, loca_item)
    has_glyf = b"glyf" in tables and b"loca" in tables and b"head" in tables and b"maxp" in tables
    glyf_trans = None
    xmins = None
    hmtx_trans = None
    if has_glyf:
        glyf_trans, xmins = transform_glyf(
            tables[b"glyf"], tables[b"loca"], tables[b"head"], tables[b"maxp"]
        )
        if b"hmtx" in tables and b"hhea" in tables:
            hmtx_trans = try_transform_hmtx(
                tables[b"hmtx"], tables[b"hhea"], tables[b"maxp"], xmins
            )

    dir_bytes = bytearray()
    stream_bytes = bytearray()
    total_sfnt_size = 12 + len(order) * 16

    for tag, _ in order:
        raw = tables[tag]
        orig_len = len(raw)
        total_sfnt_size += (orig_len + 3) & ~3

        if tag in KNOWN_TAG_INDEX:
            tag_idx = KNOWN_TAG_INDEX[tag]
            custom_tag = b""
        else:
            tag_idx = 0x3F
            custom_tag = tag

        if tag == b"glyf" and glyf_trans is not None:
            ver = 0  # transformed
            dir_bytes.append((ver << 6) | tag_idx)
            dir_bytes += custom_tag
            dir_bytes += encode_base128(orig_len)
            dir_bytes += encode_base128(len(glyf_trans))
            stream_bytes += glyf_trans
        elif tag == b"loca" and glyf_trans is not None:
            ver = 0  # transformed, transformLength = 0
            dir_bytes.append((ver << 6) | tag_idx)
            dir_bytes += custom_tag
            dir_bytes += encode_base128(orig_len)
            dir_bytes += encode_base128(0)
        elif tag == b"hmtx" and hmtx_trans is not None:
            ver = 1  # transformed
            dir_bytes.append((ver << 6) | tag_idx)
            dir_bytes += custom_tag
            dir_bytes += encode_base128(orig_len)
            dir_bytes += encode_base128(len(hmtx_trans))
            stream_bytes += hmtx_trans
        else:
            ver = 3 if tag in (b"glyf", b"loca") else 0
            dir_bytes.append((ver << 6) | tag_idx)
            dir_bytes += custom_tag
            dir_bytes += encode_base128(orig_len)
            stream_bytes += raw

    compressed = brotli_compress(bytes(stream_bytes), quality=quality)
    unpadded_len = 48 + len(dir_bytes) + len(compressed)
    pad = (4 - (unpadded_len % 4)) % 4
    total_len = unpadded_len + pad
    header = struct.pack(
        ">4sIIHHIIHHIIIII",
        b"wOF2",
        flavor,
        total_len,
        len(order),
        0,
        total_sfnt_size,
        len(compressed),
        1,
        0,
        0,
        0,
        0,
        0,
        0,
    )
    return bytes(header + dir_bytes + compressed + b"\x00" * pad)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-woff2-bench"
    os.makedirs(out_dir, exist_ok=True)

    fonts = [
        ("arial", "/System/Library/Fonts/Supplemental/Arial.ttf"),
        ("monaco", "/System/Library/Fonts/Monaco.ttf"),
    ]
    for name, path in fonts:
        if not os.path.exists(path):
            raise FileNotFoundError(f"system font not found: {path}")
        ttf = open(path, "rb").read()
        w2 = encode_woff2(ttf, quality=6)
        w2_path = os.path.join(out_dir, f"{name}.woff2")
        open(w2_path, "wb").write(w2)
        print(f"  {name}.woff2: ttf={len(ttf):7d} B -> woff2={len(w2):7d} B ({len(w2)*100.0/len(ttf):.1f}%)")
        if name == "arial":
            w1 = encode_woff1(ttf)
            w1_path = os.path.join(out_dir, f"{name}.woff")
            open(w1_path, "wb").write(w1)
            print(f"  {name}.woff : ttf={len(ttf):7d} B -> woff1={len(w1):7d} B ({len(w1)*100.0/len(ttf):.1f}%)")


if __name__ == "__main__":
    main()
