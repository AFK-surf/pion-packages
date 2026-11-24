#!/usr/bin/env python3
"""Deterministic red-team corpus generator for packages/exif/audit (no third-party modules).

    gen.py <out_dir> [fuzz_n]

Writes into <out_dir>:
  diff/       well-formed + container/edge inputs that Pion and kamadak-exif must decode identically
  adv/        adversarial inputs with an expected verdict for a correct parser (manifest.json)
  trunc/      every byte prefix of the container seeds
  fuzz/       <fuzz_n> deterministic mutants of the diff/ seeds (seeded LCG, no `random` state)
  dos/        resource bombs (dos.json: budget per file)
  manifest.json, dos.json, lists (diff.lst adv.lst trunc.lst fuzz.lst dos.lst)
"""

import json
import os
import struct
import sys

# --------------------------------------------------------------------------------------------
# TIFF builder
# --------------------------------------------------------------------------------------------

BYTE, ASCII, SHORT, LONG, RATIONAL, SBYTE, UNDEF, SSHORT, SLONG, SRATIONAL, FLOAT, DOUBLE, IFDT = range(1, 14)
UNIT = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4}


def enc_values(e, typ, vals):
    """Encode `vals` for TIFF type `typ`; returns (count, bytes)."""
    if typ in (BYTE, UNDEF, ASCII) and isinstance(vals, (bytes, bytearray)):
        return len(vals), bytes(vals)
    if typ == BYTE:
        return len(vals), bytes(v & 0xFF for v in vals)
    if typ == SBYTE:
        return len(vals), b"".join(struct.pack("b", v) for v in vals)
    if typ == SHORT:
        return len(vals), b"".join(struct.pack(e + "H", v) for v in vals)
    if typ == SSHORT:
        return len(vals), b"".join(struct.pack(e + "h", v) for v in vals)
    if typ in (LONG, IFDT):
        return len(vals), b"".join(struct.pack(e + "I", v) for v in vals)
    if typ == SLONG:
        return len(vals), b"".join(struct.pack(e + "i", v) for v in vals)
    if typ == RATIONAL:
        return len(vals), b"".join(struct.pack(e + "II", n, d) for n, d in vals)
    if typ == SRATIONAL:
        return len(vals), b"".join(struct.pack(e + "ii", n, d) for n, d in vals)
    if typ == FLOAT:  # raw binary32 bit patterns
        return len(vals), b"".join(struct.pack(e + "I", v) for v in vals)
    if typ == DOUBLE:  # raw binary64 bit patterns
        return len(vals), b"".join(struct.pack(e + "Q", v) for v in vals)
    raise ValueError(typ)


class E:
    """IFD entry. `vals` is encoded by type; `raw` = (count, bytes) overrides; `ptr` = name of a child IFD."""

    def __init__(self, tag, typ, vals=None, raw=None, ptr=None, count=None, valfield=None):
        self.tag, self.typ, self.vals, self.raw, self.ptr = tag, typ, vals, raw, ptr
        self.count, self.valfield = count, valfield


def build_tiff(be, ifds, order=None, first="ifd0", align=True, pad_after=b"", start=8):
    """ifds: name -> {"entries": [E...], "next": name|None|int}. Layout: header, IFDs in `order`, data area.
    Pointers (E.ptr / next) are resolved to the named IFD offsets; an int `next` is written verbatim."""
    e = ">" if be else "<"
    order = order or list(ifds.keys())
    # pass 1: IFD positions
    pos = start
    offs = {}
    for name in order:
        offs[name] = pos
        pos += 2 + 12 * len(ifds[name]["entries"]) + 4
    data = bytearray()
    data_base = pos
    out = bytearray(b"MM" if be else b"II")
    out += struct.pack(e + "H", 42)
    out += struct.pack(e + "I", offs[first] if isinstance(first, str) else first)
    out += b"\0" * (start - 8)
    for name in order:
        ents = ifds[name]["entries"]
        out += struct.pack(e + "H", len(ents))
        for en in ents:
            if en.ptr is not None:
                cnt, payload = enc_values(e, en.typ, [offs[en.ptr] if isinstance(en.ptr, str) else en.ptr])
            elif en.raw is not None:
                cnt, payload = en.raw
            else:
                cnt, payload = enc_values(e, en.typ, en.vals)
            if en.count is not None:
                cnt = en.count
            out += struct.pack(e + "HHI", en.tag, en.typ, cnt)
            if en.valfield is not None:
                out += struct.pack(e + "I", en.valfield)
            elif len(payload) <= 4:
                out += payload + b"\0" * (4 - len(payload))
            else:
                if align and len(data) % 2:
                    data += b"\0"
                out += struct.pack(e + "I", data_base + len(data))
                data += payload
        nxt = ifds[name].get("next")
        if nxt is None:
            out += struct.pack(e + "I", 0)
        elif isinstance(nxt, int):
            out += struct.pack(e + "I", nxt)
        else:
            out += struct.pack(e + "I", offs[nxt])
    assert len(out) == data_base, (len(out), data_base)
    return bytes(out + data + pad_after)


def asc(s):
    return s.encode("latin-1") + b"\0"


# --------------------------------------------------------------------------------------------
# containers
# --------------------------------------------------------------------------------------------


def seg(marker, payload):
    return bytes([0xFF, marker]) + struct.pack(">H", len(payload) + 2) + payload


JFIF = seg(0xE0, b"JFIF\0\x01\x02\0\0\x01\0\x01\0\0")
XMP = seg(0xE1, b"http://ns.adobe.com/xap/1.0/\0<x:xmpmeta xmlns:x='adobe:ns:meta/'/>")
SOS_TAIL = b"\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00" + b"\x12\x34\xff\x00\x56" + b"\xff\xd9"


def jpeg(tiff, before=(), after=SOS_TAIL, prefix=b"Exif\0\0"):
    return b"\xff\xd8" + b"".join(before) + seg(0xE1, prefix + tiff) + after


def riff_chunk(fourcc, payload, pad=True):
    c = fourcc + struct.pack("<I", len(payload)) + payload
    if pad and len(payload) % 2:
        c += b"\0"
    return c


VP8X = riff_chunk(b"VP8X", bytes([0x08, 0, 0, 0]) + b"\0\0\0" + b"\0\0\0")
ICCP = riff_chunk(b"ICCP", b"\0" * 7)  # odd -> padded
ALPH = riff_chunk(b"ALPH", b"\0\x11\x22")  # odd -> padded
VP8L = riff_chunk(b"VP8L", b"\x2f\0\0\0\0\x88\x88\x08\0")  # odd -> padded


def webp(chunks, riff_size=None):
    body = b"WEBP" + b"".join(chunks)
    size = len(body) if riff_size is None else riff_size
    return b"RIFF" + struct.pack("<I", size) + body


def png_chunk(ctype, payload, length=None):
    ln = len(payload) if length is None else length
    return struct.pack(">I", ln) + ctype + payload + b"CRC_"


PNG_SIG = b"\x89PNG\r\n\x1a\n"
IHDR = png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
IEND = png_chunk(b"IEND", b"")


def png(chunks):
    return PNG_SIG + b"".join(chunks)


# --------------------------------------------------------------------------------------------
# seeds
# --------------------------------------------------------------------------------------------

F32 = [0x00000000, 0x80000000, 0x00000001, 0x007FFFFF, 0x00800000, 0x3F800000, 0xC0600000, 0x7F7FFFFF,
       0x7F800000, 0xFF800000, 0x7FC00000, 0x7F800001, 0xFFC12345, 0x3DCCCCCD]
F64 = [0x0000000000000000, 0x8000000000000000, 0x0000000000000001, 0x000FFFFFFFFFFFFF, 0x3FF0000000000000,
       0x400921FB54442D18, 0x7FEFFFFFFFFFFFFF, 0x7FF0000000000000, 0xFFF0000000000000, 0x7FF8000000000000,
       0x7FF0000000000001, 0xFFF8DEADBEEF0001]


def all_types_ifds(inline):
    """Every type with extreme values. inline=True keeps each value <= 4 bytes (left-aligned slot)."""
    if inline:
        ents = [
            E(0x1001, BYTE, [0xFF]), E(0x1002, BYTE, [1, 2]), E(0x1003, BYTE, [1, 2, 3]), E(0x1004, BYTE, [0, 0x7F, 0x80, 0xFF]),
            E(0x1011, ASCII, b"A"), E(0x1012, ASCII, b"AB"), E(0x1013, ASCII, b"A\0B"), E(0x1014, ASCII, b"\0\0\0\0"),
            E(0x1021, SHORT, [0xFFFF]), E(0x1022, SHORT, [0x8000, 0x7FFF]),
            E(0x1031, LONG, [0xFFFFFFFF]), E(0x1032, LONG, [0x80000000]),
            E(0x1061, SBYTE, [-128]), E(0x1062, SBYTE, [-1, 127]), E(0x1063, SBYTE, [-128, 0, 127]), E(0x1064, SBYTE, [-1, -2, -3, -4]),
            E(0x1071, UNDEF, b"\xfe"), E(0x1072, UNDEF, b"\x00\xff"), E(0x1073, UNDEF, b"012"), E(0x1074, UNDEF, b"0232"),
            E(0x1081, SSHORT, [-32768]), E(0x1082, SSHORT, [-1, 32767]),
            E(0x1091, SLONG, [-2147483648]), E(0x1092, SLONG, [-1]),
            E(0x10B1, FLOAT, [0xC0600000]), E(0x10B2, FLOAT, [0x7F800001]), E(0x10B3, FLOAT, [0x00000001]),
            E(0x10C1, BYTE, []), E(0x10C2, SHORT, []), E(0x10C3, RATIONAL, []), E(0x10C4, DOUBLE, []), E(0x10C5, ASCII, b""),
        ]
    else:
        ents = [
            E(0x2001, BYTE, list(range(256))),
            E(0x2011, ASCII, b"PionCamera\0"), E(0x2012, ASCII, b"no-nul-terminator"), E(0x2013, ASCII, b"Hi\0Go\0\0x"),
            E(0x2014, ASCII, b"\x80\xff\xc3\x28caf\xe9\0"), E(0x2015, ASCII, b"\0" * 9),
            E(0x2021, SHORT, [0, 1, 0x7FFF, 0x8000, 0xFFFF]),
            E(0x2031, LONG, [0, 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF]),
            E(0x2041, RATIONAL, [(0, 0), (1, 0), (0, 1), (0xFFFFFFFF, 0xFFFFFFFF), (0x80000000, 3), (72, 1)]),
            E(0x2061, SBYTE, list(range(-128, 128))),
            E(0x2071, UNDEF, bytes(range(256))),
            E(0x2081, SSHORT, [-32768, -1, 0, 1, 32767]),
            E(0x2091, SLONG, [-2147483648, -1, 0, 1, 2147483647]),
            E(0x20A1, SRATIONAL, [(-2147483648, -1), (-1, 0), (0, 0), (2147483647, -2147483648), (-5, 2)]),
            E(0x20B1, FLOAT, F32),
            E(0x20C1, DOUBLE, F64),
        ]
    return ents


def camera_tiff(be, lat=("N", (35, 1), (40, 1), (3450, 100)), lon=("E", (139, 1), (45, 1), (0, 1)), alt_ref=0,
                ori=6, thumb_exif=False):
    lat_ref, *lat_r = lat
    lon_ref, *lon_r = lon
    ifds = {
        "ifd0": {"entries": [
            E(0x010F, ASCII, asc("Apple")), E(0x0110, ASCII, asc("iPhone 16 Pro")), E(0x0112, SHORT, [ori]),
            E(0x011A, RATIONAL, [(72, 1)]), E(0x011B, RATIONAL, [(72, 1)]), E(0x0128, SHORT, [2]),
            E(0x0131, ASCII, asc("18.1")), E(0x0132, ASCII, asc("2026:11:24 09:30:00")),
            E(0x8769, LONG, ptr="exif"), E(0x8825, LONG, ptr="gps")], "next": "ifd1"},
        "exif": {"entries": [
            E(0x829A, RATIONAL, [(1, 125)]), E(0x829D, RATIONAL, [(178, 100)]), E(0x8827, SHORT, [64]),
            E(0x9000, UNDEF, b"0232"), E(0x9003, ASCII, asc("2026:11:24 09:30:00")),
            E(0x9204, SRATIONAL, [(-1, 3)]), E(0x920A, RATIONAL, [(6765, 1000)]),
            E(0x927C, UNDEF, b"Apple iOS\0\0\x01MM" + bytes(range(64))),
            E(0x9286, UNDEF, b"ASCII\0\0\0user comment"),
            E(0xA001, SHORT, [1]), E(0xA002, LONG, [4032]), E(0xA003, LONG, [3024]),
            E(0xA005, LONG, ptr="interop"), E(0xA434, ASCII, asc("iPhone 16 Pro back triple camera"))]},
        "gps": {"entries": [
            E(0x0000, BYTE, [2, 3, 0, 0]), E(0x0001, ASCII, asc(lat_ref)), E(0x0002, RATIONAL, lat_r),
            E(0x0003, ASCII, asc(lon_ref)), E(0x0004, RATIONAL, lon_r), E(0x0005, BYTE, [alt_ref]),
            E(0x0006, RATIONAL, [(425, 10)]), E(0x0007, RATIONAL, [(9, 1), (30, 1), (0, 1)]),
            E(0x001D, ASCII, asc("2026:11:24"))]},
        "interop": {"entries": [E(0x0001, ASCII, asc("R98")), E(0x0002, UNDEF, b"0100")]},
        "ifd1": {"entries": [E(0x0103, SHORT, [6]), E(0x011A, RATIONAL, [(72, 1)]),
                             E(0x0201, LONG, [0]), E(0x0202, LONG, [0])]},
    }
    if thumb_exif:
        ifds["ifd1"]["entries"].append(E(0x8769, LONG, ptr="exif1"))
        ifds["exif1"] = {"entries": [E(0xA001, SHORT, [0xFFFF]), E(0xA002, LONG, [160])]}
    return build_tiff(be, ifds)


def simple_tiff(be, entries, nxt=None):
    return build_tiff(be, {"ifd0": {"entries": entries, "next": nxt}})


def chain_tiff(be, n):
    ifds = {}
    for i in range(n):
        ifds["i%d" % i] = {"entries": [E(0x0100, LONG, [i]), E(0x010E, ASCII, asc("ifd%d" % i))],
                           "next": ("i%d" % (i + 1)) if i + 1 < n else None}
    return build_tiff(be, ifds, first="i0")


# --------------------------------------------------------------------------------------------
# corpus
# --------------------------------------------------------------------------------------------


class Corpus:
    def __init__(self, out):
        self.out = out
        self.manifest = []
        self.lists = {}

    def put(self, group, name, data, **meta):
        d = os.path.join(self.out, group)
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, name)
        with open(p, "wb") as f:
            f.write(data)
        self.lists.setdefault(group, []).append(p)
        if meta:
            m = {"file": p, "group": group, "name": name}
            m.update(meta)
            self.manifest.append(m)
        return p


def gen_diff(c):
    """Inputs Pion and kamadak must decode identically (field-by-field)."""
    seeds = {}
    for be in (False, True):
        bo = "be" if be else "le"
        for inline in (True, False):
            t = simple_tiff(be, all_types_ifds(inline))
            seeds["types_%s_%s.tif" % ("inline" if inline else "ext", bo)] = t
        seeds["camera_%s.tif" % bo] = camera_tiff(be)
        seeds["camera_sw_below_%s.tif" % bo] = camera_tiff(
            be, lat=("S", (33, 1), (51, 1), (5432, 100)), lon=("W", (70, 1), (39, 1), (1234, 100)), alt_ref=1, ori=8)
        seeds["chain8_%s.tif" % bo] = chain_tiff(be, 8)
        seeds["big_arrays_%s.tif" % bo] = simple_tiff(be, [
            E(0x0111, LONG, list(range(0, 4000000, 4000))), E(0x0117, SHORT, list(range(1000))),
            E(0x02BC, BYTE, b"<x:xmpmeta/>" * 300), E(0x8773, UNDEF, bytes(i & 0xFF for i in range(3000))),
            E(0x0301, RATIONAL, [(i, i + 1) for i in range(500)])])
        seeds["unaligned_%s.tif" % bo] = build_tiff(be, {"ifd0": {"entries": [
            E(0x010F, ASCII, asc("odd")), E(0x011A, RATIONAL, [(300, 1)]), E(0x0112, SHORT, [3])]}}, align=False)
        # IFD0 placed after its data / at an odd offset
        seeds["ifd_odd_offset_%s.tif" % bo] = build_tiff(be, {"ifd0": {"entries": [
            E(0x0112, SHORT, [5]), E(0x010F, ASCII, asc("late"))]}}, start=9, align=False)
        # sorted out of order, duplicate tags (kamadak keeps both in fields())
        seeds["dup_unsorted_%s.tif" % bo] = simple_tiff(be, [
            E(0x0132, ASCII, asc("2026:01:01 00:00:00")), E(0x0112, SHORT, [6]), E(0x010F, ASCII, asc("A")),
            E(0x0112, SHORT, [3]), E(0x010F, ASCII, asc("B"))])
    cam_le = seeds["camera_le.tif"]
    cam_be = seeds["camera_be.tif"]
    seeds["jpeg_app0_xmp_exif.jpg"] = jpeg(cam_le, before=[JFIF, XMP])
    seeds["jpeg_be.jpg"] = jpeg(cam_be, before=[JFIF])
    seeds["jpeg_fill_ff.jpg"] = b"\xff\xd8" + b"\xff" * 50 + jpeg(cam_le)[2:]
    seeds["jpeg_com_dqt_before.jpg"] = jpeg(cam_be, before=[seg(0xFE, b"comment"), seg(0xDB, b"\0" * 65), JFIF])
    seeds["jpeg_xmp_named_exif_first.jpg"] = jpeg(cam_le, before=[seg(0xE1, b"ExifXX not exif"), XMP])
    seeds["jpeg_two_exif_app1.jpg"] = jpeg(cam_le, before=[seg(0xE1, b"Exif\0\0" + camera_tiff(True, ori=3))])
    seeds["webp_vp8x_iccp_alph_vp8l_exif.webp"] = webp([VP8X, ICCP, ALPH, VP8L, riff_chunk(b"EXIF", cam_le)])
    seeds["webp_be.webp"] = webp([VP8X, riff_chunk(b"EXIF", cam_be)])
    odd = cam_le + b"\x00"  # odd-length EXIF payload (TIFF tolerates trailing bytes)
    seeds["webp_odd_exif_last_nopad.webp"] = webp([VP8X, riff_chunk(b"EXIF", odd, pad=False)])
    seeds["webp_odd_exif_padded.webp"] = webp([VP8X, riff_chunk(b"EXIF", odd), riff_chunk(b"XMP ", b"<x/>")])
    seeds["png_exif.png"] = png([IHDR, png_chunk(b"eXIf", cam_le), png_chunk(b"IDAT", b"\x78\x9c"), IEND])
    seeds["png_be_after_idat.png"] = png([IHDR, png_chunk(b"IDAT", b"\x78\x9c"), png_chunk(b"eXIf", cam_be), IEND])
    seeds["png_types_be.png"] = png([IHDR, png_chunk(b"eXIf", seeds["types_ext_be.tif"]), IEND])
    for name, data in sorted(seeds.items()):
        c.put("diff", name, data)
    return seeds


def gen_adv(c, seeds):
    """Adversarial inputs. `expect` is what a correct parser must do:
       verdict: OK | ERR | ERR:<Variant>     ori: int|None     gps: [lat, lon]|None     alt: float|None
       finding: id of the REPORT.md finding the case pins (if Pion is expected to fail it)."""
    cam_le = seeds["camera_le.tif"]
    cam_be = seeds["camera_be.tif"]
    ori_le = simple_tiff(False, [E(0x0112, SHORT, [6])])

    def put(name, data, **exp):
        c.put("adv", name, data, expect=exp)

    # ---- JPEG -------------------------------------------------------------------------------
    put("jpeg_two_exif_first_wins.jpg", seeds["jpeg_two_exif_app1.jpg"], verdict="OK", ori=3)
    put("jpeg_seglen_0.jpg", b"\xff\xd8\xff\xe0\x00\x00" + seg(0xE1, b"Exif\0\0" + ori_le), verdict="ERR")
    put("jpeg_seglen_1.jpg", b"\xff\xd8\xff\xe0\x00\x01" + seg(0xE1, b"Exif\0\0" + ori_le), verdict="ERR")
    put("jpeg_seglen_2_empty_then_exif.jpg", b"\xff\xd8\xff\xe0\x00\x02" + seg(0xE1, b"Exif\0\0" + ori_le) + SOS_TAIL,
        verdict="OK", ori=6)
    put("jpeg_seglen_past_eof.jpg", b"\xff\xd8\xff\xe1\xff\xf0Exif\0\0" + ori_le, verdict="ERR")
    put("jpeg_app1_exif_header_only.jpg", b"\xff\xd8" + seg(0xE1, b"Exif\0\0") + SOS_TAIL, verdict="ERR")
    put("jpeg_ff_fill_x1000.jpg", b"\xff\xd8" + b"\xff" * 1000 + seg(0xE1, b"Exif\0\0" + ori_le)[1:] + SOS_TAIL,
        verdict="OK", ori=6)
    put("jpeg_standalone_rst_tem_before_app1.jpg",
        b"\xff\xd8" + b"".join(bytes([0xFF, m]) for m in [0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0x01])
        + seg(0xE1, b"Exif\0\0" + ori_le) + SOS_TAIL, verdict="OK", ori=6)
    put("jpeg_fake_exif_after_sos.jpg",
        b"\xff\xd8" + JFIF + b"\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00" + b"\x11\x22"
        + seg(0xE1, b"Exif\0\0" + ori_le) + b"\xff\xd9", verdict="ERR:NotFound")
    put("jpeg_fake_exif_in_entropy_ff00.jpg",
        b"\xff\xd8\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00" + b"\xff\x00\xe1\x00\x10Exif\0\0" + ori_le + b"\xff\xd9",
        verdict="ERR:NotFound")
    put("jpeg_eoi_before_exif.jpg", b"\xff\xd8\xff\xd9" + seg(0xE1, b"Exif\0\0" + ori_le), verdict="ERR:NotFound")
    put("jpeg_garbage_between_segments.jpg", b"\xff\xd8" + JFIF + b"\x00\x00" + seg(0xE1, b"Exif\0\0" + ori_le) + SOS_TAIL,
        verdict="ANY")
    put("jpeg_exif_lowercase_id.jpg", b"\xff\xd8" + seg(0xE1, b"exif\0\0" + ori_le) + SOS_TAIL, verdict="ERR:NotFound")
    put("jpeg_soi_only.jpg", b"\xff\xd8", verdict="ERR")
    put("jpeg_soi_ff.jpg", b"\xff\xd8\xff", verdict="ERR")
    put("jpeg_max_seglen.jpg", b"\xff\xd8\xff\xe1\xff\xff" + b"Exif\0\0" + ori_le + b"\0" * (0xFFFF - 2 - 6 - len(ori_le)),
        verdict="OK", ori=6)
    # ---- WebP -------------------------------------------------------------------------------
    w_ok = webp([VP8X, riff_chunk(b"EXIF", ori_le)])
    put("webp_exif_prefixed.webp", webp([VP8X, riff_chunk(b"EXIF", b"Exif\0\0" + ori_le)]), verdict="OK", ori=6)
    put("webp_riff_size_ffffffff.webp", webp([VP8X, riff_chunk(b"EXIF", ori_le)], riff_size=0xFFFFFFFF), verdict="ANY")
    put("webp_riff_size_3.webp", webp([VP8X, riff_chunk(b"EXIF", ori_le)], riff_size=3), verdict="ERR")
    put("webp_riff_size_4_no_chunks.webp", webp([VP8X, riff_chunk(b"EXIF", ori_le)], riff_size=4), verdict="ERR:NotFound")
    put("webp_exif_outside_riff.webp", webp([VP8X, riff_chunk(b"EXIF", ori_le)], riff_size=4 + len(VP8X)),
        verdict="ERR:NotFound")
    put("webp_chunk_size_ffffffff.webp", webp([b"JUNK\xff\xff\xff\xff" + b"\0" * 16, riff_chunk(b"EXIF", ori_le)]),
        verdict="ERR")
    put("webp_chunk_size_fffffffe.webp", webp([b"JUNK\xfe\xff\xff\xff" + b"\0" * 16, riff_chunk(b"EXIF", ori_le)]),
        verdict="ERR")
    put("webp_chunk_size_7fffffff.webp", webp([b"JUNK\xff\xff\xff\x7f" + b"\0" * 16, riff_chunk(b"EXIF", ori_le)]),
        verdict="ERR")
    put("webp_exif_size_ffffffff.webp", webp([VP8X, b"EXIF\xff\xff\xff\xff" + ori_le]), verdict="ERR")
    put("webp_odd_chunk_missing_pad.webp", webp([riff_chunk(b"JUNK", b"abc", pad=False), riff_chunk(b"EXIF", ori_le)]),
        verdict="ANY")
    put("webp_truncated_header.webp", w_ok[:20], verdict="ERR")
    put("webp_exif_after_vp8l.webp", webp([VP8X, VP8L, riff_chunk(b"EXIF", ori_le)]), verdict="OK", ori=6)
    # ---- PNG --------------------------------------------------------------------------------
    put("png_exif_len_80000000.png", png([IHDR, png_chunk(b"eXIf", ori_le, length=0x80000000), IEND]), verdict="ERR")
    put("png_exif_len_ffffffff.png", png([IHDR, png_chunk(b"eXIf", ori_le, length=0xFFFFFFFF), IEND]), verdict="ERR")
    put("png_junk_len_ffffffff.png", png([IHDR, png_chunk(b"tEXt", b"x", length=0xFFFFFFFF), png_chunk(b"eXIf", ori_le), IEND]),
        verdict="ERR")
    put("png_exif_after_iend.png", png([IHDR, IEND, png_chunk(b"eXIf", ori_le)]), verdict="ERR:NotFound")
    put("png_bad_signature.png", b"\x89PNG\r\n\x1a\x0b" + png([IHDR, png_chunk(b"eXIf", ori_le), IEND])[8:], verdict="ERR")
    put("png_exif_truncated.png", png([IHDR, png_chunk(b"eXIf", ori_le)])[:-10], verdict="ERR")
    put("png_exif_no_crc.png", png([IHDR, png_chunk(b"eXIf", ori_le)])[:-4], verdict="ANY")
    put("png_two_exif_first_wins.png",
        png([IHDR, png_chunk(b"eXIf", simple_tiff(True, [E(0x0112, SHORT, [8])])), png_chunk(b"eXIf", ori_le), IEND]),
        verdict="OK", ori=8)
    # ---- auto-detection -----------------------------------------------------------------------
    put("detect_raw_app1_payload.bin", b"Exif\0\0" + ori_le, verdict="ERR")
    put("detect_tiff_magic_43.tif", b"II\x2b\x00" + ori_le[4:], verdict="ERR")
    put("detect_mixed_bo_IM.tif", b"IM" + ori_le[2:], verdict="ERR")
    put("detect_riff_not_webp.bin", b"RIFF\x10\0\0\0AVI " + b"\0" * 8, verdict="ERR")
    put("detect_png_sig_then_tiff.png", PNG_SIG + ori_le, verdict="ERR")
    # ---- TIFF structure -----------------------------------------------------------------------
    for be in (False, True):
        bo = "be" if be else "le"
        e = ">" if be else "<"
        put("tiff_ifd0_offset_0_%s.tif" % bo, (b"MM\0*" if be else b"II*\0") + struct.pack(e + "I", 0) + b"\0" * 8, verdict="ERR")
        put("tiff_ifd0_offset_4_%s.tif" % bo, (b"MM\0*" if be else b"II*\0") + struct.pack(e + "I", 4) + b"\0" * 8, verdict="ERR")
        put("tiff_ifd0_offset_oob_%s.tif" % bo, (b"MM\0*" if be else b"II*\0") + struct.pack(e + "I", 0xFFFFFFFF) + b"\0" * 8,
            verdict="ERR")
        put("tiff_self_loop_%s.tif" % bo, simple_tiff(be, [E(0x0112, SHORT, [6])], nxt=8), verdict="ERR")
        put("tiff_mutual_loop_%s.tif" % bo, build_tiff(be, {"a": {"entries": [E(0x0112, SHORT, [6])], "next": "b"},
                                                         "b": {"entries": [E(0x0100, LONG, [1])], "next": "a"}}, first="a"),
            verdict="ERR")
        put("tiff_exif_points_to_ifd0_%s.tif" % bo, simple_tiff(be, [E(0x0112, SHORT, [6]), E(0x8769, LONG, ptr=8)]),
            verdict="ERR")
        put("tiff_exif_next_to_ifd0_%s.tif" % bo, build_tiff(be, {
            "ifd0": {"entries": [E(0x0112, SHORT, [6]), E(0x8769, LONG, ptr="exif")]},
            "exif": {"entries": [E(0xA001, SHORT, [1])], "next": 8}}), verdict="ANY")
        put("tiff_diamond_exif_gps_same_%s.tif" % bo, build_tiff(be, {
            "ifd0": {"entries": [E(0x0112, SHORT, [6]), E(0x8769, LONG, ptr="sub"), E(0x8825, LONG, ptr="sub")]},
            "sub": {"entries": [E(0x0001, ASCII, asc("N"))]}}), verdict="ERR")
        put("tiff_gps_ptr_oob_%s.tif" % bo, simple_tiff(be, [E(0x0112, SHORT, [6]), E(0x8825, LONG, [0x7FFFFFF0])]),
            verdict="ANY")
        put("tiff_exif_ptr_into_header_%s.tif" % bo, simple_tiff(be, [E(0x0112, SHORT, [6]), E(0x8769, LONG, [4])]),
            verdict="ANY")
        put("tiff_exif_ptr_zero_%s.tif" % bo, simple_tiff(be, [E(0x0112, SHORT, [6]), E(0x8769, LONG, [0])]),
            verdict="OK", ori=6)
        put("tiff_exif_ptr_short_type_%s.tif" % bo, build_tiff(be, {
            "ifd0": {"entries": [E(0x0112, SHORT, [6]), E(0x8769, SHORT, ptr="exif")]},
            "exif": {"entries": [E(0xA001, SHORT, [1])]}}), verdict="OK", ori=6)
        put("tiff_exif_ptr_count2_%s.tif" % bo, build_tiff(be, {
            "ifd0": {"entries": [E(0x0112, SHORT, [6]), E(0x8769, LONG, raw=(2, struct.pack(e + "II", 26, 26)))]}}),
            verdict="OK", ori=6)
        put("tiff_exif_ptr_ifd_type13_%s.tif" % bo, build_tiff(be, {
            "ifd0": {"entries": [E(0x0112, SHORT, [6]), E(0x8769, IFDT, ptr="exif")]},
            "exif": {"entries": [E(0xA001, SHORT, [1])]}}), verdict="OK", ori=6)
        put("tiff_truncated_dir_%s.tif" % bo, simple_tiff(be, [E(0x0112, SHORT, [6]), E(0x0100, LONG, [1])])[:30], verdict="ERR")
        put("tiff_missing_next_ptr_%s.tif" % bo, simple_tiff(be, [E(0x0112, SHORT, [6])])[:-4], verdict="ANY")
        for ov in (0, 9, 65535):
            put("tiff_orientation_%d_%s.tif" % (ov, bo), simple_tiff(be, [E(0x0112, SHORT, [ov])]), verdict="OK", ori=None)
        put("tiff_orientation_long_%s.tif" % bo, simple_tiff(be, [E(0x0112, LONG, [7])]), verdict="OK", ori=7)
        put("tiff_orientation_long_big_%s.tif" % bo, simple_tiff(be, [E(0x0112, LONG, [0x100000006])] if False else
                                                                  [E(0x0112, LONG, [0x80000006])]), verdict="OK", ori=None)
        put("tiff_orientation_ascii_%s.tif" % bo, simple_tiff(be, [E(0x0112, ASCII, b"6\0")]), verdict="OK", ori=None)
        put("tiff_orientation_dup_%s.tif" % bo, simple_tiff(be, [E(0x0112, SHORT, [6]), E(0x0112, SHORT, [3])]),
            verdict="OK", ori=6)
        put("tiff_orientation_count0_%s.tif" % bo, simple_tiff(be, [E(0x0112, SHORT, [])]), verdict="OK", ori=None)
        put("tiff_orientation_in_ifd1_only_%s.tif" % bo, build_tiff(be, {
            "ifd0": {"entries": [E(0x0100, LONG, [1])], "next": "ifd1"},
            "ifd1": {"entries": [E(0x0112, SHORT, [6])]}}), verdict="OK", ori=None)
        # unknown field types (TIFF 6.0 §2: readers should skip fields with an unexpected type)
        for ut in (0, 14, 16, 0xFFFF):
            put("tiff_unknown_type_%d_ifd0_%s.tif" % (ut, bo),
                simple_tiff(be, [E(0x0112, SHORT, [6]), E(0xC000, ut, raw=(1, b"\x01\x02\x03\x04"))]),
                verdict="OK", ori=6, finding="P1-1")
        put("tiff_unknown_type_in_gps_%s.tif" % bo, build_tiff(be, {
            "ifd0": {"entries": [E(0x0112, SHORT, [8]), E(0x8825, LONG, ptr="gps")]},
            "gps": {"entries": [E(0x0001, ASCII, asc("N")), E(0x001F, 16, raw=(1, b"\0" * 4))]}}),
            verdict="OK", ori=8, finding="P1-1")
        put("tiff_bigtiff_long8_in_exif_%s.tif" % bo, build_tiff(be, {
            "ifd0": {"entries": [E(0x0112, SHORT, [6]), E(0x8769, LONG, ptr="exif")]},
            "exif": {"entries": [E(0xA001, SHORT, [1]), E(0xC001, 16, raw=(2, b"\0" * 16))]}}),
            verdict="OK", ori=6, finding="P1-1")
        # value-offset / count edge cases
        put("tiff_value_oob_in_exif_%s.tif" % bo, build_tiff(be, {
            "ifd0": {"entries": [E(0x0112, SHORT, [6]), E(0x8769, LONG, ptr="exif")]},
            "exif": {"entries": [E(0x927C, UNDEF, raw=(64, b"\0" * 8), valfield=0x10000)]}}), verdict="ANY")
        put("tiff_value_offset_into_header_%s.tif" % bo,
            simple_tiff(be, [E(0x0112, SHORT, [6]), E(0x010F, ASCII, raw=(8, b""), valfield=0)]), verdict="OK", ori=6)
        put("tiff_value_end_exact_%s.tif" % bo, simple_tiff(be, [E(0x0112, SHORT, [6]), E(0x010F, ASCII, asc("exact"))]),
            verdict="OK", ori=6)
        for cnt in (0xFFFFFFFF, 0x80000000, 0x40000000, 0x20000000, 0x1FFFFFFF):
            for typ in (BYTE, SHORT, LONG, RATIONAL, DOUBLE, SRATIONAL):
                put("tiff_count_%08x_type%d_%s.tif" % (cnt, typ, bo),
                    simple_tiff(be, [E(0x0112, SHORT, [6]), E(0xC100, typ, raw=(cnt, b""), valfield=8)]), verdict="ERR")
        # GPS
        def gps(lat_ref, lat, lon_ref, lon, alt_ref=None, alt=None, lat_type=RATIONAL, ref_type=ASCII):
            g = []
            if lat_ref is not None:
                g.append(E(0x0001, ref_type, lat_ref))
            if lat is not None:
                g.append(E(0x0002, lat_type, lat))
            if lon_ref is not None:
                g.append(E(0x0003, ref_type, lon_ref))
            if lon is not None:
                g.append(E(0x0004, RATIONAL, lon))
            if alt_ref is not None:
                g.append(E(0x0005, BYTE, [alt_ref]))
            if alt is not None:
                g.append(E(0x0006, RATIONAL, [alt]))
            return build_tiff(be, {"ifd0": {"entries": [E(0x8825, LONG, ptr="gps")]}, "gps": {"entries": g}})
        L = [(35, 1), (40, 1), (0, 1)]
        G = [(139, 1), (45, 1), (0, 1)]
        put("gps_ok_%s.tif" % bo, gps(b"N\0", L, b"E\0", G, 1, (425, 10)), verdict="OK", gps=[35 + 40 / 60.0, 139 + 45 / 60.0],
            alt=-42.5)
        put("gps_sw_%s.tif" % bo, gps(b"S\0", L, b"W\0", G), verdict="OK", gps=[-(35 + 40 / 60.0), -(139 + 45 / 60.0)])
        put("gps_den_0_0_%s.tif" % bo, gps(b"N\0", [(35, 1), (0, 0), (0, 1)], b"E\0", G), verdict="OK", gps=None)
        put("gps_den_1_0_%s.tif" % bo, gps(b"N\0", L, b"E\0", [(1, 0), (0, 1), (0, 1)]), verdict="OK", gps=None)
        put("gps_lat_gt_90_%s.tif" % bo, gps(b"N\0", [(90, 1), (0, 1), (1, 1)], b"E\0", G), verdict="OK", gps=None)
        put("gps_lat_eq_90_%s.tif" % bo, gps(b"S\0", [(90, 1), (0, 1), (0, 1)], b"E\0", G), verdict="OK", gps=[-90.0, 139 + 45 / 60.0])
        put("gps_lon_gt_180_%s.tif" % bo, gps(b"N\0", L, b"W\0", [(180, 1), (0, 1), (1, 100)]), verdict="OK", gps=None)
        put("gps_lat_u32max_%s.tif" % bo, gps(b"N\0", [(0xFFFFFFFF, 1), (0, 1), (0, 1)], b"E\0", G), verdict="OK", gps=None)
        put("gps_missing_latref_%s.tif" % bo, gps(None, L, b"E\0", G), verdict="OK", gps=None)
        put("gps_missing_lon_%s.tif" % bo, gps(b"N\0", L, b"E\0", None), verdict="OK", gps=None)
        put("gps_bad_ref_X_%s.tif" % bo, gps(b"X\0", L, b"E\0", G), verdict="OK", gps=None)
        put("gps_ref_empty_%s.tif" % bo, gps(b"\0", L, b"E\0", G), verdict="OK", gps=None)
        put("gps_ref_byte_type_%s.tif" % bo, gps([0x4E], L, [0x45], G, ref_type=BYTE), verdict="OK", gps=None)
        put("gps_lat_two_components_%s.tif" % bo, gps(b"N\0", [(35, 1), (40, 1)], b"E\0", G), verdict="OK", gps=None)
        put("gps_lat_srational_%s.tif" % bo, gps(b"N\0", [(-35, 1), (40, 1), (0, 1)], b"E\0", G, lat_type=SRATIONAL),
            verdict="OK", gps=None)
        put("gps_alt_ref_2_%s.tif" % bo, gps(b"N\0", L, b"E\0", G, 2, (425, 10)), verdict="OK", alt=None)
        put("gps_alt_den0_%s.tif" % bo, gps(b"N\0", L, b"E\0", G, 0, (425, 0)), verdict="OK", alt=None)
        put("gps_alt_no_ref_%s.tif" % bo, gps(b"N\0", L, b"E\0", G, None, (425, 10)), verdict="OK", alt=42.5)
        # thumbnail IFD1 carrying its own Exif sub-IFD: primary accessors must not see it
        put("ifd1_exif_subifd_%s.tif" % bo, build_tiff(be, {
            "ifd0": {"entries": [E(0x0112, SHORT, [1])], "next": "ifd1"},
            "ifd1": {"entries": [E(0x0103, SHORT, [6]), E(0x8769, LONG, ptr="exif1")]},
            "exif1": {"entries": [E(0xA001, SHORT, [0xFFFF]), E(0xA002, LONG, [160])]}}),
            verdict="OK", ori=1, colorspace=None, finding="P2-1")
        put("interop_ptr_in_ifd0_%s.tif" % bo, build_tiff(be, {
            "ifd0": {"entries": [E(0x0112, SHORT, [6]), E(0xA005, LONG, ptr="iop")]},
            "iop": {"entries": [E(0x0001, ASCII, asc("R98"))]}}), verdict="OK", ori=6)
    return


def gen_trunc(c, seeds):
    for name in ("jpeg_app0_xmp_exif.jpg", "webp_vp8x_iccp_alph_vp8l_exif.webp", "png_exif.png", "camera_be.tif",
                 "types_ext_le.tif", "jpeg_two_exif_app1.jpg"):
        d = seeds[name]
        for cut in range(len(d)):
            c.put("trunc", "%s.%05d" % (name, cut), d[:cut])


class Lcg:
    """64-bit LCG (Knuth MMIX) so the mutant stream is identical on every Python version."""

    def __init__(self, seed):
        self.s = seed & 0xFFFFFFFFFFFFFFFF

    def next(self):
        self.s = (self.s * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        return self.s >> 33

    def below(self, n):
        return self.next() % n if n > 0 else 0


INTERESTING32 = [0, 1, 2, 4, 7, 8, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000,
                 0xFFFFFFFF, 0xFFFFFFFE, 0x40000000, 0x20000000, 0x3FFFFFFF]


def mutate(rng, d, seeds_list):
    d = bytearray(d)
    for _ in range(1 + rng.below(4)):
        op = rng.below(9)
        if not d:
            d = bytearray(b"\0")
        p = rng.below(len(d))
        if op == 0:  # bit flip
            d[p] ^= 1 << rng.below(8)
        elif op == 1:  # random byte
            d[p] = rng.below(256)
        elif op == 2:  # interesting byte
            d[p] = [0, 1, 0x7F, 0x80, 0xFF, 0x2A, 0x0D][rng.below(7)]
        elif op == 3:  # interesting u16/u32 (either byte order)
            v = INTERESTING32[rng.below(len(INTERESTING32))]
            w = 2 + 2 * rng.below(2)
            b = (v & ((1 << (8 * w)) - 1)).to_bytes(w, "little" if rng.below(2) else "big")
            d[p:p + w] = b
        elif op == 4:  # truncate
            d = d[:p]
        elif op == 5:  # delete a run
            del d[p:p + 1 + rng.below(16)]
        elif op == 6:  # insert a run
            d[p:p] = bytes(rng.below(256) for _ in range(1 + rng.below(16)))
        elif op == 7:  # duplicate a run
            n = 1 + rng.below(32)
            d[p:p] = d[p:p + n]
        else:  # splice from another seed
            o = seeds_list[rng.below(len(seeds_list))]
            q = rng.below(len(o))
            n = 1 + rng.below(64)
            d[p:p + n] = o[q:q + n]
    return bytes(d)


def gen_fuzz(c, seeds, n):
    names = sorted(seeds)
    seeds_list = [seeds[k] for k in names]
    rng = Lcg(0x5EED_E1F0)
    for i in range(n):
        k = rng.below(len(names))
        c.put("fuzz", "m%05d_%s" % (i, names[k]), mutate(rng, seeds[names[k]], seeds_list))


def gen_dos(c):
    """Resource bombs. Budget: verdict, wall-clock per parse and peak RSS (checked by diff/dos.py)."""
    bombs = []

    def put(name, data, verdict, **kw):
        p = c.put("dos", name, data)
        b = {"file": p, "name": name, "verdict": verdict, "size": len(data)}
        b.update(kw)
        bombs.append(b)

    le = False
    # 65535 entries (raw TIFF, ~786 KB): rejected by max_entries_per_ifd
    ents = [E(0x1000 + (i % 0xE000), SHORT, [i & 0xFFFF]) for i in range(65535)]
    put("entries_65535.tif", simple_tiff(le, ents), "ERR")
    # 4096 entries exactly (the default per-IFD and total limit): accepted
    ents = [E(0x1000 + i, SHORT, [i]) for i in range(4096)]
    put("entries_4096.tif", simple_tiff(le, ents), "OK")
    ents = [E(0xFFFF - i, SHORT, [i]) for i in range(4096)]
    put("entries_4096_desc.tif", simple_tiff(le, ents), "OK", note="descending tags: format_canonical insertion sort")
    # 4096 overlapping ASCII fields, each 1 KiB of NULs at the same offset (in a < 64 KiB JPEG APP1):
    # total declared payload = 4 MiB (= max_payload_bytes) -> accepted; every NUL becomes an empty String
    blob = b"\0" * 1024
    n = 4095
    t = bytearray(simple_tiff(le, [E(0x1000 + i, ASCII, raw=(1024, b""), valfield=0) for i in range(n)]))
    off = len(t)
    t += blob
    t = patch_valfields(t, le, off)
    put("overlap_ascii_nul_4mib.jpg", jpeg(bytes(t), after=b"\xff\xd9"), "OK", note="4095 x 1 KiB NUL ASCII")
    t = bytearray(simple_tiff(le, [E(0x1000 + i, BYTE, raw=(1024, b""), valfield=0) for i in range(n)]))
    off = len(t)
    t += b"\x55" * 1024
    t = patch_valfields(t, le, off)
    put("overlap_byte_4mib.jpg", jpeg(bytes(t), after=b"\xff\xd9"), "OK", note="4095 x 1 KiB BYTE")
    t = bytearray(simple_tiff(le, [E(0x1000 + i, RATIONAL, raw=(128, b""), valfield=0) for i in range(n)]))
    off = len(t)
    t += b"\x01" * 1024
    t = patch_valfields(t, le, off)
    put("overlap_rational_4mib.jpg", jpeg(bytes(t), after=b"\xff\xd9"), "OK", note="4095 x 128 RATIONAL")
    t = bytearray(simple_tiff(le, [E(0x1000 + i, SHORT, raw=(512, b""), valfield=0) for i in range(n)]))
    off = len(t)
    t += b"\x01" * 1024
    t = patch_valfields(t, le, off)
    put("overlap_short_4mib.jpg", jpeg(bytes(t), after=b"\xff\xd9"), "OK", note="4095 x 512 SHORT")
    # 500 fields over the same 50 KiB block (25 MB declared) -> must be cut by max_payload_bytes
    t = bytearray(simple_tiff(le, [E(0x1000 + i, UNDEF, raw=(50000, b""), valfield=0) for i in range(500)]))
    off = len(t)
    t += b"\x42" * 50000
    t = patch_valfields(t, le, off)
    put("overlap_undef_500x50k.jpg", jpeg(bytes(t), after=b"\xff\xd9"), "ERR")
    # long IFD chains
    put("chain_33.tif", chain_tiff(le, 33), "ERR")
    put("chain_1000.tif", chain_tiff(le, 1000), "ERR")
    put("chain_32.tif", chain_tiff(le, 32), "OK")
    # 1 MiB ASCII of '\0' in a raw TIFF (1M empty strings)
    put("ascii_nul_1mib.tif", simple_tiff(le, [E(0x010E, ASCII, b"\0" * (1 << 20))]), "OK")
    # count 0xFFFFFFFF of DOUBLE (32 GiB declared)
    put("count_ffffffff_double.tif", simple_tiff(le, [E(0xC100, DOUBLE, raw=(0xFFFFFFFF, b""), valfield=8)]), "ERR")
    # 4 MiB + 1 byte single field (raw TIFF, legitimately sized: e.g. a big ICC profile / XMP)
    put("single_undef_4mib_plus1.tif", simple_tiff(le, [E(0x0112, SHORT, [6]), E(0x8773, UNDEF, b"\0" * (4194304 + 1))]),
        "ANY", note="legit large tag beyond max_payload_bytes")
    with open(os.path.join(c.out, "dos.json"), "w") as f:
        json.dump(bombs, f, indent=1)


def patch_valfields(t, be, off):
    """Point every external value field of the (single) IFD0 at `off`."""
    e = ">" if be else "<"
    ifd = struct.unpack(e + "I", bytes(t[4:8]))[0]
    n = struct.unpack(e + "H", bytes(t[ifd:ifd + 2]))[0]
    for i in range(n):
        p = ifd + 2 + 12 * i
        typ = struct.unpack(e + "H", bytes(t[p + 2:p + 4]))[0]
        cnt = struct.unpack(e + "I", bytes(t[p + 4:p + 8]))[0]
        if UNIT.get(typ, 0) * cnt > 4:
            t[p + 8:p + 12] = struct.pack(e + "I", off)
    return t


def main():
    out = sys.argv[1]
    fuzz_n = int(sys.argv[2]) if len(sys.argv) > 2 else 6000
    os.makedirs(out, exist_ok=True)
    c = Corpus(out)
    seeds = gen_diff(c)
    gen_adv(c, seeds)
    gen_trunc(c, seeds)
    gen_fuzz(c, seeds, fuzz_n)
    gen_dos(c)
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(c.manifest, f, indent=1)
    for g, files in c.lists.items():
        with open(os.path.join(out, g + ".lst"), "w") as f:
            f.write("\n".join(files) + "\n")
    print("corpus: " + " ".join("%s=%d" % (g, len(v)) for g, v in sorted(c.lists.items())))


if __name__ == "__main__":
    main()
