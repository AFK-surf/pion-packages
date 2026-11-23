"""Independent WOFF 2.0 / WOFF 1.0 building blocks for the `packages/woff2` red-team audit.

Nothing here is shared with `packages/woff2/bench/gen_data.py`: the container writers, the
`glyf` transform encoder (§5.1, all triplet ranges) and the parsers are written from the W3C
WOFF 2.0 / WOFF 1.0 text so that malformed variants can be produced field by field.
Requires the `brotli` Python module (installed in the audit venv by `run_audit.sh`).
"""
import struct
import zlib

import brotli

KNOWN_TAGS = [
    b"cmap", b"head", b"hhea", b"hmtx", b"maxp", b"name", b"OS/2", b"post", b"cvt ", b"fpgm",
    b"glyf", b"loca", b"prep", b"CFF ", b"VORG", b"EBDT", b"EBLC", b"gasp", b"hdmx", b"kern",
    b"LTSH", b"PCLT", b"VDMX", b"vhea", b"vmtx", b"BASE", b"GDEF", b"GPOS", b"GSUB", b"EBSC",
    b"JSTF", b"MATH", b"CBDT", b"CBLC", b"COLR", b"CPAL", b"SVG ", b"sbix", b"acnt", b"avar",
    b"bdat", b"bloc", b"bsln", b"cvar", b"fdsc", b"feat", b"fmtx", b"fvar", b"gvar", b"hsty",
    b"just", b"lcar", b"mort", b"morx", b"opbd", b"prop", b"trak", b"Zapf", b"Silf", b"Glat",
    b"Gloc", b"Feat", b"Sill",
]
TAG_INDEX = {t: i for i, t in enumerate(KNOWN_TAGS)}


# ------------------------------------------------------------------------------------------------
# Primitive encoders
# ------------------------------------------------------------------------------------------------

def b128(v, width=None):
    """UIntBase128. `width` forces a (possibly non-canonical, leading-zero) longer encoding."""
    groups = []
    while True:
        groups.append(v & 0x7F)
        v >>= 7
        if not v:
            break
    groups.reverse()
    if width is not None:
        groups = [0] * (width - len(groups)) + groups
    return bytes([g | 0x80 for g in groups[:-1]] + [groups[-1]])


def u255(v, form=None):
    """255UInt16. `form` forces one of 'byte', 'w253', 'p253', 'p506' (non-canonical allowed)."""
    if form is None:
        form = 'byte' if v < 253 else 'p253' if v < 506 else 'p506' if v < 762 else 'w253'
    if form == 'byte':
        return bytes([v])
    if form == 'p253':
        return bytes([255, v - 253])
    if form == 'p506':
        return bytes([254, v - 506])
    return bytes([253, v >> 8, v & 0xFF])


def triplet(dx, dy, on):
    """WOFF2 §5.2 point triplet encoding (all six ranges). Returns (flag, data)."""
    flag = 0 if on else 128
    ax, ay = abs(dx), abs(dy)
    xs = 1 if dx > 0 else 0
    ys = 1 if dy > 0 else 0
    xy = xs + 2 * ys
    if dx == 0 and ay < 1280:
        return flag + ((ay & 0xF00) >> 7) + ys, bytes([ay & 0xFF])
    if dy == 0 and ax < 1280:
        return flag + 10 + ((ax & 0xF00) >> 7) + xs, bytes([ax & 0xFF])
    if 0 < ax < 65 and 0 < ay < 65:
        return (flag + 20 + ((ax - 1) & 0x30) + (((ay - 1) & 0x30) >> 2) + xy,
                bytes([(((ax - 1) & 0xF) << 4) | ((ay - 1) & 0xF)]))
    if 0 < ax < 769 and 0 < ay < 769:
        return (flag + 84 + 12 * (((ax - 1) & 0x300) >> 8) + (((ay - 1) & 0x300) >> 6) + xy,
                bytes([(ax - 1) & 0xFF, (ay - 1) & 0xFF]))
    if ax < 4096 and ay < 4096:
        return flag + 120 + xy, bytes([ax >> 4, ((ax & 0xF) << 4) | (ay >> 8), ay & 0xFF])
    return flag + 124 + xy, bytes([ax >> 8, ax & 0xFF, ay >> 8, ay & 0xFF])


# ------------------------------------------------------------------------------------------------
# glyf transform encoder (§5.1)
# ------------------------------------------------------------------------------------------------

class Simple:
    def __init__(self, contours, instr=b'', bbox=None, overlap=False, npoints_forms=None):
        self.contours = contours          # [[(x, y, on), ...], ...]
        self.instr = instr
        self.bbox = bbox                  # explicit (xMin, yMin, xMax, yMax) or None (computed)
        self.overlap = overlap
        self.npoints_forms = npoints_forms


class Composite:
    def __init__(self, components, bbox, instr=None):
        self.components = components      # raw component records (flags .. args/scale), already big-endian
        self.bbox = bbox
        self.instr = instr                # bytes or None (WE_HAVE_INSTRUCTIONS must be set in a flag)


def transform_glyf(glyphs, index_format=1, version=0, options=None, sizes_override=None,
                   ncontours_override=None):
    """Encode a list of glyphs (None = empty, Simple, Composite) into a transformed glyf table."""
    n = len(glyphs)
    ncont, npts, flags, gl, comp, bboxes, instrs = (bytearray() for _ in range(7))
    bitmap = bytearray(4 * ((n + 31) // 32))
    overlap = bytearray((n + 7) // 8)
    any_overlap = False
    for gi, g in enumerate(glyphs):
        if g is None:
            ncont += struct.pack('>h', 0)
            continue
        if isinstance(g, Composite):
            ncont += struct.pack('>h', -1)
            comp += b''.join(g.components)
            bitmap[gi >> 3] |= 0x80 >> (gi & 7)
            bboxes += struct.pack('>hhhh', *g.bbox)
            if g.instr is not None:
                gl += u255(len(g.instr))
                instrs += g.instr
            continue
        ncont += struct.pack('>h', len(g.contours))
        px = py = 0
        for ci, c in enumerate(g.contours):
            form = g.npoints_forms[ci] if g.npoints_forms else None
            npts += u255(len(c), form)
            for (x, y, on) in c:
                f, d = triplet(x - px, y - py, on)
                flags.append(f)
                gl += d
                px, py = x, y
        gl += u255(len(g.instr))
        instrs += g.instr
        if g.bbox is not None:
            bitmap[gi >> 3] |= 0x80 >> (gi & 7)
            bboxes += struct.pack('>hhhh', *g.bbox)
        if g.overlap:
            any_overlap = True
            overlap[gi >> 3] |= 0x80 >> (gi & 7)
    if ncontours_override is not None:
        ncont = bytearray(ncontours_override)
    streams = [ncont, npts, flags, gl, comp, bitmap + bboxes, instrs]
    sizes = [len(s) for s in streams]
    if sizes_override:
        for k, v in sizes_override.items():
            sizes[k] = v
    opt = (1 if any_overlap else 0) if options is None else options
    out = struct.pack('>HHHH', version, opt, n if ncontours_override is None else len(ncont) // 2, index_format)
    out += struct.pack('>7I', *sizes)
    out += b''.join(bytes(s) for s in streams)
    if opt & 1:
        out += bytes(overlap)
    return out


def bbox_of(contours):
    pts = [(x, y) for c in contours for (x, y, _) in c]
    if not pts:
        return (0, 0, 0, 0)
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return (min(xs), min(ys), max(xs), max(ys))


# ------------------------------------------------------------------------------------------------
# Minimal SFNT tables for synthetic fonts
# ------------------------------------------------------------------------------------------------

def head_table(index_to_loc=1):
    return struct.pack('>IIIIHHQQhhhhHHhhh', 0x00010000, 0x00010000, 0, 0x5F0F3CF5, 0x000B, 1000,
                       0, 0, 0, 0, 1000, 1000, 0, 3, 2, index_to_loc, 0)


def hhea_table(nmetrics):
    return struct.pack('>IhhhHhhhhhhhhhhhH', 0x00010000, 800, -200, 0, 1000, 0, 0, 1000, 1, 0, 0,
                       0, 0, 0, 0, 0, nmetrics)


def maxp_table(nglyphs):
    return struct.pack('>IH', 0x00010000, nglyphs) + bytes(26)


def hmtx_table(advs, lsbs):
    """advs: advance widths for the first len(advs) glyphs (= numberOfHMetrics)."""
    out = bytearray()
    for i, a in enumerate(advs):
        out += struct.pack('>Hh', a, lsbs[i] if i < len(lsbs) else 0)
    for l in lsbs[len(advs):]:
        out += struct.pack('>h', l)
    return bytes(out)


def hmtx_transformed(advs, lsbs, flags):
    out = bytearray([flags])
    for a in advs:
        out += struct.pack('>H', a)
    if not flags & 1:
        for l in (lsbs + [0] * len(advs))[:len(advs)]:
            out += struct.pack('>h', l)
    if not flags & 2:
        for l in lsbs[len(advs):]:
            out += struct.pack('>h', l)
    return bytes(out)


# ------------------------------------------------------------------------------------------------
# WOFF2 container
# ------------------------------------------------------------------------------------------------

class Entry:
    """One WOFF2 table directory entry plus its bytes in the decompressed stream."""

    def __init__(self, tag, data, version=0, orig_len=None, transform_len=None, flags_byte=None,
                 orig_raw=None, tlen_raw=None, force_custom=False):
        self.tag = tag
        self.data = data
        self.version = version
        self.orig_len = orig_len
        self.transform_len = transform_len
        self.flags_byte = flags_byte
        self.orig_raw = orig_raw
        self.tlen_raw = tlen_raw
        self.force_custom = force_custom

    def transformed(self):
        if self.tag in (b'glyf', b'loca'):
            return self.version == 0
        return self.version != 0

    def directory(self):
        idx = TAG_INDEX.get(self.tag, 63)
        if self.force_custom:
            idx = 63
        f = self.flags_byte if self.flags_byte is not None else (self.version << 6) | idx
        out = bytes([f])
        if (f & 0x3F) == 63:
            out += self.tag
        orig = self.orig_len if self.orig_len is not None else len(self.data)
        out += self.orig_raw if self.orig_raw is not None else b128(orig)
        if self.transformed():
            tl = self.transform_len if self.transform_len is not None else len(self.data)
            out += self.tlen_raw if self.tlen_raw is not None else b128(tl)
        return out


def woff2(entries, flavor=0x00010000, total_sfnt=None, stream=None, compressed=None, length=None,
          reserved=0, num_tables=None, comp_size=None, trailing=b'', quality=11, extra_dir=b'',
          meta=None, priv=None):
    """Assemble a WOFF2 file. Every header field can be overridden to forge malformed files."""
    directory = b''.join(e.directory() for e in entries) + extra_dir
    if stream is None:
        stream = b''.join(e.data for e in entries)
    if compressed is None:
        compressed = brotli.compress(stream, quality=quality)
    body = directory + compressed
    pad = (-(48 + len(body))) % 4
    meta_off = meta_len = meta_orig = priv_off = priv_len = 0
    tail = b'\0' * pad
    if meta is not None:
        meta_off = 48 + len(body) + len(tail)
        mc = zlib.compress(meta)
        meta_len, meta_orig = len(mc), len(meta)
        tail += mc + b'\0' * ((-len(mc)) % 4)
    if priv is not None:
        priv_off = 48 + len(body) + len(tail)
        priv_len = len(priv)
        tail += priv
    total = 48 + len(body) + len(tail) + len(trailing)
    if total_sfnt is None:
        n = len(entries)
        total_sfnt = 12 + 16 * n + sum((((e.orig_len if e.orig_len is not None else len(e.data)) + 3) & ~3)
                                       for e in entries)
    hdr = struct.pack('>4sIIHHIIHHIIIII', b'wOF2', flavor, total if length is None else length,
                      len(entries) if num_tables is None else num_tables, reserved, total_sfnt,
                      len(compressed) if comp_size is None else comp_size, 1, 0, meta_off, meta_len,
                      meta_orig, priv_off, priv_len)
    return hdr + body + tail + trailing


def read_b128(b, p):
    v = 0
    for i in range(5):
        c = b[p]
        p += 1
        v = (v << 7) | (c & 0x7F)
        if not c & 0x80:
            return v, p
    raise ValueError('b128')


def parse_woff2(data):
    """Return (header dict, [Entry], decompressed stream). Only for well-formed seeds."""
    (sig, flavor, length, nt, res, tss, tcs, maj, mnr, mo, ml, mol, po, pl) = struct.unpack(
        '>4sIIHHIIHHIIIII', data[:48])
    p = 48
    entries = []
    for _ in range(nt):
        f = data[p]
        p += 1
        if (f & 0x3F) == 63:
            tag = data[p:p + 4]
            p += 4
        else:
            tag = KNOWN_TAGS[f & 0x3F]
        ver = f >> 6
        orig, p = read_b128(data, p)
        e = Entry(tag, b'', version=ver, orig_len=orig)
        tl = orig
        if e.transformed():
            tl, p = read_b128(data, p)
        e.transform_len = tl
        e.force_custom = (f & 0x3F) == 63 and tag in TAG_INDEX
        entries.append(e)
    if flavor == 0x74746366:
        raise ValueError('collection seed')
    stream = brotli.decompress(data[p:p + tcs])
    q = 0
    for e in entries:
        e.data = stream[q:q + e.transform_len]
        q += e.transform_len
    return dict(flavor=flavor), entries, stream


# ------------------------------------------------------------------------------------------------
# WOFF1 container
# ------------------------------------------------------------------------------------------------

def woff1(tables, flavor=0x00010000, compress=True, length=None, total_sfnt=None, reserved=0,
          offsets=None, comp_lens=None, orig_lens=None, num_tables=None, trailing=b'', align=True,
          raw_blobs=None):
    """tables: [(tag, bytes)]. Overrides let every directory field be forged."""
    n = len(tables)
    blobs = []
    for i, (tag, data) in enumerate(tables):
        if raw_blobs is not None and raw_blobs[i] is not None:
            blobs.append(raw_blobs[i])
            continue
        c = zlib.compress(data, 9) if compress else data
        blobs.append(c if len(c) < len(data) else data)
    p = 44 + 20 * n
    offs = []
    body = b''
    for b in blobs:
        if align:
            pad = (-p) % 4
            body += b'\0' * pad
            p += pad
        offs.append(p)
        body += b
        p += len(b)
    if align:
        body += b'\0' * ((-p) % 4)
    directory = b''
    for i, (tag, data) in enumerate(tables):
        o = offsets[i] if offsets and offsets[i] is not None else offs[i]
        cl = comp_lens[i] if comp_lens and comp_lens[i] is not None else len(blobs[i])
        ol = orig_lens[i] if orig_lens and orig_lens[i] is not None else len(data)
        directory += struct.pack('>4sIIII', tag, o, cl, ol, sfnt_checksum(data))
    total = 44 + len(directory) + len(body) + len(trailing)
    if total_sfnt is None:
        total_sfnt = 12 + 16 * n + sum((len(d) + 3) & ~3 for _, d in tables)
    hdr = struct.pack('>4sIIHHIHHIIIII', b'wOFF', flavor, total if length is None else length,
                      n if num_tables is None else num_tables, reserved, total_sfnt, 1, 0, 0, 0, 0, 0, 0)
    return hdr + directory + body + trailing


def sfnt_checksum(data):
    data = data + b'\0' * ((-len(data)) % 4)
    return sum(struct.unpack('>%dI' % (len(data) // 4), data)) & 0xFFFFFFFF


def sfnt_tables(sfnt):
    nt = struct.unpack('>H', sfnt[4:6])[0]
    out = {}
    for i in range(nt):
        tag, _, off, ln = struct.unpack('>4sIII', sfnt[12 + 16 * i:28 + 16 * i])
        out[tag] = sfnt[off:off + ln]
    return out


def woff2_collection(fonts, quality=11):
    """WOFF2 font collection (flavor 'ttcf', §4.2 CollectionDirectory) from [(flavor, [Entry])]
    (e.g. the entries of single-font WOFF2 files from `parse_woff2`, so glyf/loca keep their transform).
    Identical (tag, version, bytes) tables are shared between fonts."""
    entries, index = [], {}
    font_idx = []
    for _, ents in fonts:
        ids = []
        for e in ents:
            key = (e.tag, e.version, e.orig_len, e.data)
            if key not in index:
                index[key] = len(entries)
                e.orig_raw = e.tlen_raw = None
                entries.append(e)
            ids.append(index[key])
        font_idx.append(ids)
    coll = struct.pack('>I', 0x00020000) + u255(len(fonts))
    for (flavor, _), ids in zip(fonts, font_idx):
        coll += u255(len(ids)) + struct.pack('>I', flavor) + b''.join(u255(i) for i in ids)
    directory = b''.join(e.directory() for e in entries) + coll
    stream = b''.join(e.data for e in entries)
    compressed = brotli.compress(stream, quality=quality)
    body = directory + compressed
    pad = (-(48 + len(body))) % 4
    total = 48 + len(body) + pad
    total_sfnt = 12 + sum(12 + 16 * len(ids) for ids in font_idx) + sum((e.orig_len + 3) & ~3 for e in entries)
    hdr = struct.pack('>4sIIHHIIHHIIIII', b'wOF2', 0x74746366, total, len(entries), 0, total_sfnt,
                      len(compressed), 1, 0, 0, 0, 0, 0, 0)
    return hdr + body + b'\0' * pad
