#!/usr/bin/env python3
"""Red-team corpus generator for packages/opentype (stdlib only, run with `python3 -I`).

    python3 -I gen.py <out_dir> [fuzz_n]

Writes, into <out_dir> (never into the repository):
  synth/<case>.ttf + synth/<case>.q   synthesized edge-case fonts and their query files
  cases.tsv                            case<TAB>policy<TAB>font<TAB>face<TAB>queries<TAB>full<TAB>note
  bombs/<name>.ttf, bombs.tsv          < 8 KiB DoS fonts (name<TAB>file<TAB>budget_ms<TAB>note)
  fuzz/<n>.ttf, fuzz.txt               deterministic mutation corpus (seeded, reproducible)
  system.tsv                           read-only system fonts found on this machine (path<TAB>face)
  macroman.tsv                         Python's mac_roman codec, byte -> code point (reference table)

policy is `same` (all oracles must agree with pion on every line) or a comma list of
`<finding|quirk>:<line-prefix>` entries: lines with that prefix may differ (and are attributed).
"""
import os
import random
import struct
import sys

# ----------------------------------------------------------------------------- SFNT writer


def u8(v):
    return struct.pack(">B", v & 0xFF)


def u16(v):
    return struct.pack(">H", v & 0xFFFF)


def i16(v):
    return struct.pack(">h", v)


def u24(v):
    return struct.pack(">I", v & 0xFFFFFF)[1:]


def u32(v):
    return struct.pack(">I", v & 0xFFFFFFFF)


def i32(v):
    return struct.pack(">i", v)


def fixed(v):
    return i32(int(round(v * 65536)))


def f2d14(v):
    return i16(int(round(v * 16384)))


def tag(s):
    return s.encode("latin-1")


def checksum(b):
    b = b + b"\0" * (-len(b) % 4)
    return sum(struct.unpack(">%dI" % (len(b) // 4), b)) & 0xFFFFFFFF


def sfnt(tables, version=0x00010000, order=None, records=None, num_tables=None, pad=True):
    """tables: dict tag -> bytes. order: directory order (default sorted). records: extra raw
    directory entries (tag, offset, length) appended verbatim (offsets absolute)."""
    tags = order if order is not None else sorted(tables)
    n = len(tags) + (len(records) if records else 0)
    nt = n if num_tables is None else num_tables
    es = max(0, n.bit_length() - 1)
    sr = (1 << es) * 16
    hdr = u32(version) + u16(nt) + u16(sr) + u16(es) + u16(n * 16 - sr)
    off = 12 + 16 * n
    body = b""
    dirs = b""
    for t in tags:
        data = tables[t]
        dirs += tag(t) + u32(checksum(data)) + u32(off + len(body)) + u32(len(data))
        body += data
        if pad:
            body += b"\0" * (-len(body) % 4)
    for (t, o, ln) in records or []:
        dirs += tag(t) + u32(0) + u32(o) + u32(ln)
    return hdr + dirs + body


def ttc(fonts, version=0x00010000, num_fonts=None, offsets=None):
    """fonts: list of dict tag->bytes (each face gets its own directory, tables not shared)."""
    n = len(fonts)
    hdr_len = 12 + 4 * n + (12 if version == 0x00020000 else 0)
    blobs = []
    pos = hdr_len
    offs = []
    for f in fonts:
        # build the face with absolute offsets: lay out directory at pos
        tags = sorted(f)
        dir_len = 12 + 16 * len(tags)
        es = max(0, len(tags).bit_length() - 1)
        sr = (1 << es) * 16
        d = u32(0x00010000) + u16(len(tags)) + u16(sr) + u16(es) + u16(len(tags) * 16 - sr)
        body = b""
        tpos = pos + dir_len
        for t in tags:
            data = f[t]
            d += tag(t) + u32(checksum(data)) + u32(tpos + len(body)) + u32(len(data))
            body += data + b"\0" * (-len(data) % 4)
        offs.append(pos)
        blobs.append(d + body)
        pos += len(d) + len(body)
    if offsets is not None:
        offs = offsets
    out = tag("ttcf") + u32(version) + u32(n if num_fonts is None else num_fonts)
    for o in offs:
        out += u32(o)
    if version == 0x00020000:
        out += u32(0) + u32(0) + u32(0)
    return out + b"".join(blobs)


# ----------------------------------------------------------------------------- table builders


def head(upem=1000, bbox=(0, -200, 800, 800), loca=1, magic=0x5F0F3CF5, flags=3, mac_style=0, ppem=8):
    return (u32(0x00010000) + u32(0x00010000) + u32(0) + u32(magic) + u16(flags) + u16(upem) +
            b"\0" * 16 + i16(bbox[0]) + i16(bbox[1]) + i16(bbox[2]) + i16(bbox[3]) + u16(mac_style) +
            u16(ppem) + i16(2) + i16(loca) + i16(0))


def maxp(ng, version=0x00010000):
    if version == 0x00005000:
        return u32(version) + u16(ng)
    return u32(version) + u16(ng) + b"\0" * 26


def hhea(nhm, asc=800, desc=-200, gap=90, adv_max=1000):
    return (u32(0x00010000) + i16(asc) + i16(desc) + i16(gap) + u16(adv_max) + i16(0) + i16(0) +
            i16(900) + i16(1) + i16(0) + i16(0) + b"\0" * 8 + i16(0) + u16(nhm))


def vhea(nvm, asc=500, desc=-500, gap=0):
    return (u32(0x00011000) + i16(asc) + i16(desc) + i16(gap) + u16(1000) + i16(0) + i16(0) +
            i16(1000) + i16(1) + i16(0) + i16(0) + b"\0" * 8 + i16(0) + u16(nvm))


def mtx(metrics, extra=()):
    return b"".join(u16(a) + i16(s) for a, s in metrics) + b"".join(i16(s) for s in extra)


def os2(version=4, weight=400, width=5, typo=(800, -200, 90), win=(1000, 250), xh=500, ch=700, length=None):
    b = (u16(version) + i16(500) + u16(weight) + u16(width) + u16(0) +
         i16(650) + i16(600) + i16(0) + i16(75) + i16(651) + i16(601) + i16(1) + i16(350) +
         i16(50) + i16(259) + i16(0) + bytes(range(1, 11)) + b"\0" * 16 + tag("NONE") +
         u16(0x40) + u16(0x20) + u16(0xFFFF) + i16(typo[0]) + i16(typo[1]) + i16(typo[2]) +
         u16(win[0]) + u16(win[1]))
    if version >= 1:
        b += u32(1) + u32(0)
    if version >= 2:
        b += i16(xh) + i16(ch) + u16(0) + u16(32) + u16(0)
    if version >= 5:
        b += u16(0) + u16(0xFFFF)
    if length is not None:
        b = (b + b"\0" * length)[:length]
    return b


def post(italic=-12.5, upos=-100, uthick=50, mono=0, version=0x00030000):
    return u32(version) + fixed(italic) + i16(upos) + i16(uthick) + u32(mono) + b"\0" * 16


def name_table(records, version=0, langtags=(), storage_extra=b""):
    """records: (pid, eid, lid, nid, bytes) or (pid, eid, lid, nid, bytes, (off, len)) raw override."""
    count = len(records)
    storage = b""
    recs = b""
    for r in records:
        pid, eid, lid, nid, s = r[:5]
        off, ln = len(storage), len(s)
        storage += s
        if len(r) > 5:
            off, ln = r[5]
        recs += u16(pid) + u16(eid) + u16(lid) + u16(nid) + u16(ln) + u16(off)
    lt = b""
    lt_storage = b""
    if version == 1:
        lt = u16(len(langtags))
        for t in langtags:
            lt += u16(len(t)) + u16(len(storage) + len(lt_storage))
            lt_storage += t
    hdr_len = 6 + len(recs) + len(lt)
    return u16(version) + u16(count) + u16(hdr_len) + recs + lt + storage + lt_storage + storage_extra


def utf16(s):
    return s.encode("utf-16-be")


# --- cmap


def cmap(subs, num_tables=None):
    """subs: list of (pid, eid, subtable_bytes) or (pid, eid, raw_offset_int)."""
    n = len(subs)
    hdr = u16(0) + u16(n if num_tables is None else num_tables)
    off = 4 + 8 * n
    body = b""
    seen = {}
    for s in subs:
        pid, eid, data = s
        if isinstance(data, int):
            hdr += u16(pid) + u16(eid) + u32(data)
            continue
        if id(data) in seen:
            hdr += u16(pid) + u16(eid) + u32(seen[id(data)])
            continue
        seen[id(data)] = off + len(body)
        hdr += u16(pid) + u16(eid) + u32(off + len(body))
        body += data
    return hdr + body


def fmt0(m, lang=0):
    arr = bytearray(256)
    for c, g in m.items():
        arr[c] = g
    return u16(0) + u16(262) + u16(lang) + bytes(arr)


def fmt4_segments(segs, glyph_ids=(), seg_count_x2=None, pad=b""):
    """segs: list of (start, end, delta, range_offset). glyph_ids appended after idRangeOffset."""
    n = len(segs)
    sx2 = 2 * n if seg_count_x2 is None else seg_count_x2
    es = max(0, n.bit_length() - 1)
    sr = 2 * (1 << es)
    body = (u16(sx2) + u16(sr) + u16(es) + u16(2 * n - sr) + b"".join(u16(s[1]) for s in segs) + u16(0) +
            b"".join(u16(s[0]) for s in segs) + b"".join(u16(s[2]) for s in segs) +
            b"".join(u16(s[3]) for s in segs) + b"".join(u16(g) for g in glyph_ids) + pad)
    return u16(4) + u16(min(0xFFFF, 6 + len(body))) + u16(0) + body


def fmt4(m):
    """Map code point -> gid with idDelta segments (one per run of consecutive cp with constant delta)."""
    cps = sorted(c for c in m if c < 0xFFFF)
    segs = []
    for c in cps:
        d = (m[c] - c) & 0xFFFF
        if segs and segs[-1][1] == c - 1 and segs[-1][2] == d:
            segs[-1][1] = c
        else:
            segs.append([c, c, d, 0])
    segs.append([0xFFFF, 0xFFFF, 1, 0])
    return fmt4_segments([tuple(s) for s in segs])


def fmt6(first, gids):
    return u16(6) + u16(10 + 2 * len(gids)) + u16(0) + u16(first) + u16(len(gids)) + b"".join(u16(g) for g in gids)


def fmt10(start, gids):
    body = u32(start) + u32(len(gids)) + b"".join(u16(g) for g in gids)
    return u16(10) + u16(0) + u32(12 + len(body)) + u32(0) + body


def fmt12(groups, fmt=12, n_groups=None):
    body = b"".join(u32(a) + u32(b) + u32(g) for a, b, g in groups)
    return u16(fmt) + u16(0) + u32(16 + len(body)) + u32(0) + u32(len(groups) if n_groups is None else n_groups) + body


def fmt14(records):
    """records: list of (vs, default_ranges or None, nondefault list or None); ranges (start, add)."""
    n = len(records)
    hdr_len = 10 + 11 * n
    body = b""
    recs = b""
    for vs, dflt, nd in records:
        doff = 0
        ndoff = 0
        if isinstance(dflt, int):
            doff = dflt
        elif dflt is not None:
            doff = hdr_len + len(body)
            body += u32(len(dflt)) + b"".join(u24(s) + u8(a) for s, a in dflt)
        if isinstance(nd, int):
            ndoff = nd
        elif nd is not None:
            ndoff = hdr_len + len(body)
            body += u32(len(nd)) + b"".join(u24(u) + u16(g) for u, g in nd)
        recs += u24(vs) + u32(doff) + u32(ndoff)
    return u16(14) + u32(hdr_len + len(body)) + u32(n) + recs + body


# --- kern


def kern_sub0(pairs, coverage=0x0001, length=None, version=0, raw_n=None):
    pairs = list(pairs)
    n = len(pairs)
    es = max(0, n.bit_length() - 1) if n else 0
    sr = 6 * (1 << es) if n else 0
    body = (u16(n if raw_n is None else raw_n) + u16(sr) + u16(es) + u16(n * 6 - sr) +
            b"".join(u16(l) + u16(r) + i16(v) for l, r, v in pairs))
    ln = 6 + len(body) if length is None else length
    return u16(version) + u16(ln) + u16(coverage) + body


def kern_v0(subs):
    return u16(0) + u16(len(subs)) + b"".join(subs)


def kern_aat(subs):
    """subs: list of (coverage, pairs)"""
    out = u32(0x00010000) + u32(len(subs))
    for cov, pairs in subs:
        pairs = list(pairs)
        n = len(pairs)
        es = max(0, n.bit_length() - 1) if n else 0
        sr = 6 * (1 << es) if n else 0
        body = u16(n) + u16(sr) + u16(es) + u16(n * 6 - sr) + b"".join(u16(l) + u16(r) + i16(v) for l, r, v in pairs)
        out += u32(8 + len(body)) + u16(cov) + u16(0) + body
    return out


# --- fvar / avar


def fvar(axes, instances=(), ps_names=False, axis_size=20):
    """axes: (tag, min, def, max, flags, nameid) in user units; instances: (subfam, coords[, ps])."""
    ac = len(axes)
    isz = 4 + 4 * ac + (2 if ps_names else 0)
    out = u16(1) + u16(0) + u16(16) + u16(2) + u16(ac) + u16(axis_size) + u16(len(instances)) + u16(isz)
    for t, mn, df, mx, fl, nid in axes:
        a = tag(t) + (mn if isinstance(mn, bytes) else fixed(mn)) + (df if isinstance(df, bytes) else fixed(df)) + \
            (mx if isinstance(mx, bytes) else fixed(mx)) + u16(fl) + u16(nid)
        out += (a + b"\0" * axis_size)[:axis_size]
    for inst in instances:
        out += u16(inst[0]) + u16(0) + b"".join(fixed(c) for c in inst[1])
        if ps_names:
            out += u16(inst[2] if len(inst) > 2 else 0xFFFF)
    return out


def avar(segs, axis_count=None):
    out = u16(1) + u16(0) + u16(0) + u16(len(segs) if axis_count is None else axis_count)
    for seg in segs:
        out += u16(len(seg)) + b"".join(f2d14(a) + f2d14(b) for a, b in seg)
    return out


# --- glyf


def simple_glyph(contours, instructions=b"", bbox=None, compress=True):
    """contours: list of lists of (x, y, on). Absolute coordinates."""
    pts = [p for c in contours for p in c]
    if bbox is None:
        if pts:
            xs = [p[0] for p in pts]
            ys = [p[1] for p in pts]
            bbox = (min(xs), min(ys), max(xs), max(ys))
        else:
            bbox = (0, 0, 0, 0)
    out = i16(len(contours)) + b"".join(i16(v) for v in bbox)
    e = -1
    for c in contours:
        e += len(c)
        out += u16(e)
    out += u16(len(instructions)) + instructions
    flags = []
    xb = b""
    yb = b""
    px = py = 0
    for x, y, on in pts:
        f = 1 if on else 0
        dx, dy = x - px, y - py
        px, py = x, y
        if dx == 0:
            f |= 0x10
        elif -255 <= dx <= 255:
            f |= 0x02 | (0x10 if dx > 0 else 0)
            xb += u8(abs(dx))
        else:
            xb += i16(dx)
        if dy == 0:
            f |= 0x20
        elif -255 <= dy <= 255:
            f |= 0x04 | (0x20 if dy > 0 else 0)
            yb += u8(abs(dy))
        else:
            yb += i16(dy)
        flags.append(f)
    fb = b""
    i = 0
    while i < len(flags):
        j = i
        while compress and j + 1 < len(flags) and flags[j + 1] == flags[i] and j - i < 255:
            j += 1
        if j > i:
            fb += u8(flags[i] | 0x08) + u8(j - i)
        else:
            fb += u8(flags[i])
        i = j + 1
    return out + fb + xb + yb


ARG_WORDS, ARGS_XY, ROUND, HAVE_SCALE, MORE, XY_SCALE, TWO_BY_TWO, INSTR, USE_MY, OVERLAP, SCALED_OFF, UNSCALED_OFF = (
    0x1, 0x2, 0x4, 0x8, 0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800, 0x1000)


def compound_glyph(comps, bbox=(0, 0, 100, 100), contours=-1):
    """comps: list of dict(gid, dx, dy, flags=extra flags, scale=None|s|(sx,sy)|(a,b,c,d), words=None)."""
    out = i16(contours) + b"".join(i16(v) for v in bbox)
    for k, c in enumerate(comps):
        fl = c.get("flags", ARGS_XY)
        dx, dy = c.get("dx", 0), c.get("dy", 0)
        words = c.get("words")
        if words is None:
            words = not (-128 <= dx <= 127 and -128 <= dy <= 127) if fl & ARGS_XY else not (0 <= dx <= 255 and 0 <= dy <= 255)
        if words:
            fl |= ARG_WORDS
        sc = c.get("scale")
        if sc is not None and not (fl & (HAVE_SCALE | XY_SCALE | TWO_BY_TWO)):
            fl |= HAVE_SCALE if not isinstance(sc, tuple) else (XY_SCALE if len(sc) == 2 else TWO_BY_TWO)
        if k + 1 < len(comps):
            fl |= MORE
        out += u16(fl) + u16(c["gid"])
        if fl & ARG_WORDS:
            out += (i16(dx) + i16(dy)) if fl & ARGS_XY else (u16(dx) + u16(dy))
        else:
            out += (struct.pack(">bb", dx, dy)) if fl & ARGS_XY else (u8(dx) + u8(dy))
        if c.get("raw_scale") is not None:
            out += c["raw_scale"]
        elif sc is not None:
            if isinstance(sc, tuple):
                out += b"".join(f2d14(v) for v in sc)
            else:
                out += f2d14(sc)
    return out


def glyf_loca(glyphs, loca_fmt=1, loca_override=None):
    """glyphs: list of bytes (b'' = empty). Returns (glyf, loca)."""
    g = b""
    offs = []
    for gb in glyphs:
        offs.append(len(g))
        g += gb
        g += b"\0" * (-len(g) % (2 if loca_fmt == 0 else 4))
    offs.append(len(g))
    if loca_override is not None:
        offs = loca_override
    if loca_fmt == 0:
        loca = b"".join(u16(o // 2) for o in offs)
    else:
        loca = b"".join(u32(o) for o in offs)
    return g, loca


# ----------------------------------------------------------------------------- base font

SQUARE = [[(100, 0, True), (100, 700, True), (600, 700, True), (600, 0, True)]]
TRI_Q = [[(0, 0, True), (300, 600, False), (600, 0, True)]]


def base_glyphs():
    return [
        simple_glyph([[(50, 0, True), (50, 700, True), (450, 700, True), (450, 0, True)],
                      [(100, 50, True), (400, 50, True), (400, 650, True), (100, 650, True)]]),  # .notdef
        simple_glyph(SQUARE),  # A
        simple_glyph(TRI_Q),  # B
        b"",  # space
        compound_glyph([{"gid": 1, "dx": 10, "dy": -20}, {"gid": 2, "dx": 300, "dy": 400}], bbox=(10, -20, 900, 1000)),
    ]


def base_tables(glyphs=None, ng=None, loca_fmt=1, cmap_t=None, extra=None, nhm=None, metrics=None, drop=()):
    glyphs = base_glyphs() if glyphs is None else glyphs
    ng = len(glyphs) if ng is None else ng
    g, l = glyf_loca(glyphs, loca_fmt)
    metrics = metrics if metrics is not None else [(500 + 10 * i, 10 + i) for i in range(ng)]
    nhm = len(metrics) if nhm is None else nhm
    t = {
        "head": head(loca=loca_fmt),
        "maxp": maxp(ng),
        "hhea": hhea(nhm),
        "hmtx": mtx(metrics[:nhm], [m[1] for m in metrics[nhm:]]),
        "OS/2": os2(),
        "post": post(),
        "name": name_table([(3, 1, 0x409, 1, utf16("Audit Sans")), (3, 1, 0x409, 2, utf16("Regular")),
                            (1, 0, 0, 1, b"Audit Mac"), (0, 3, 0, 4, utf16("Audit Sans Regular"))]),
        "cmap": cmap_t if cmap_t is not None else cmap([(3, 1, fmt4({0x41: 1, 0x42: 2, 0x20: 3, 0xC4: 4}))]),
        "glyf": g,
        "loca": l,
    }
    for k in drop:
        t.pop(k, None)
    if extra:
        t.update(extra)
    return t


def base_font(**kw):
    return sfnt(base_tables(**kw))


# ----------------------------------------------------------------------------- corpus


class Corpus:
    def __init__(self, out):
        self.out = out
        self.rows = []
        os.makedirs(os.path.join(out, "synth"), exist_ok=True)

    def add(self, name, data, policy="same", queries=(), face=0, full=1, note=""):
        p = os.path.join(self.out, "synth", name + ".ttf")
        with open(p, "wb") as f:
            f.write(data)
        q = os.path.join(self.out, "synth", name + ".q")
        with open(q, "w") as f:
            for line in queries:
                f.write(line + "\n")
        self.rows.append((name, policy, p, str(face), q, str(full), note))

    def write(self):
        with open(os.path.join(self.out, "cases.tsv"), "w") as f:
            for r in self.rows:
                f.write("\t".join(r) + "\n")


def kq(pairs):
    return ["kern %d %d" % (l, r) for l, r in pairs]


def build_corpus(c):
    # ------------------------------------------------------------------ controls
    c.add("ctl_base", base_font(), queries=kq([(1, 2), (2, 1)]) + ["norm -"], note="baseline valid TrueType font")
    c.add("ctl_short_loca", base_font(loca_fmt=0), note="index_to_loc_format 0")
    t = base_tables()
    t["vhea"] = vhea(3)
    t["vmtx"] = mtx([(1000, 100), (1100, 110), (1200, 120)], [130, 140])
    c.add("ctl_vmtx_reuse_last", sfnt(t), note="vmtx: gid >= numberOfVMetrics reuses last advance, reads tsb array")
    c.add("ctl_hmtx_reuse_last", base_font(nhm=2), note="hmtx: gid >= numberOfHMetrics reuses last advance")
    c.add("ctl_otto_no_glyf", sfnt(base_tables(drop=("glyf", "loca")), version=0x4F54544F), note="OTTO flavour without glyf")
    c.add("ctl_true_flavour", sfnt(base_tables(), version=0x74727565), note="Apple 'true' flavour")
    c.add("ctl_ttc_v1_face0", ttc([base_tables(), base_tables(loca_fmt=0)]), face=0)
    c.add("ctl_ttc_v1_face1", ttc([base_tables(), base_tables(loca_fmt=0)]), face=1)
    c.add("ctl_ttc_v2_face1", ttc([base_tables(), base_tables(nhm=1)], version=0x00020000), face=1)

    # ------------------------------------------------------------------ D2: SFNT / TTC container
    t = base_tables()
    order = sorted(t, reverse=True)
    c.add("sfnt_unsorted_dir", sfnt(t, order=order), policy="quirk-ttf-unsorted-dir:*",
          note="table directory in reverse tag order (wild fonts); ttf-parser binary-searches it as is")
    t = base_tables()
    probe = sfnt(t, records=[("hmtx", 0, 0)])
    post_off = [struct.unpack(">I", probe[12 + 16 * k + 8:12 + 16 * k + 12])[0] for k in range(len(t))
                if probe[12 + 16 * k:12 + 16 * k + 4] == b"post"][0]
    data = sfnt(t, records=[("hmtx", post_off, 20)])
    c.add("sfnt_dup_tag", data, policy="quirk-dup-tag:hmtx",
          note="two 'hmtx' records; which one wins is unspecified")
    data = sfnt(base_tables(), records=[("DSIG", 0x7FFFFFF0, 0x100)])
    c.add("sfnt_oob_unused_table", data, policy="P2-1:*",
          note="an unused table (DSIG) points past EOF: pion rejects the whole face")
    data = sfnt(base_tables(), records=[("zzzz", 0xFFFFFFF0, 0x20)])
    c.add("sfnt_u32_wrap_record", data, policy="P2-1:*", note="offset+length wraps in u32")
    c.add("sfnt_num_tables_0", sfnt(base_tables(), num_tables=0), note="numTables = 0")
    c.add("sfnt_num_tables_65535", sfnt(base_tables(), num_tables=65535), note="numTables = 65535, directory truncated")
    c.add("sfnt_truncated_dir", base_font()[:12 + 16 * 3], note="directory cut after 3 records")
    c.add("sfnt_bad_version", b"abcd" + base_font()[4:], note="unknown sfnt version")
    c.add("sfnt_ttcf_in_ttcf", ttc([base_tables()], offsets=[0]), note="ttc face offset points back at 'ttcf'")
    c.add("sfnt_tiny_11", base_font()[:11], note="11 bytes")
    c.add("sfnt_empty", b"", note="0 bytes")
    c.add("ttc_numfonts_ffffffff", ttc([base_tables()], num_fonts=0xFFFFFFFF), policy="quirk-ttc-count:ttc", note="numFonts = 0xFFFFFFFF")
    c.add("ttc_numfonts_0", ttc([base_tables()], num_fonts=0), policy="quirk-ttc-count:ttc", note="numFonts = 0")
    c.add("ttc_face_oob", ttc([base_tables(), base_tables()]), face=2, note="face_index >= numFonts")
    c.add("ttc_offset_oob", ttc([base_tables()], offsets=[0xFFFFFFF0]), note="face offset beyond EOF")
    c.add("ttc_bad_version", ttc([base_tables()], version=0x00030000), policy="quirk-ttc-version:*", note="ttcf version 3.0")
    t = base_tables()
    t["head"] = head(magic=0x12345678)
    c.add("head_bad_magic", sfnt(t), policy="quirk-head-magic:*", note="head.magicNumber wrong (ttf-parser ignores it)")
    for upem in (15, 16, 16384, 16385):
        t = base_tables()
        t["head"] = head(upem=upem)
        c.add("head_upem_%d" % upem, sfnt(t), policy="quirk-skrifa-lenient:*", note="unitsPerEm boundary (pion = ttf-parser)")
    t = base_tables()
    t["head"] = head(loca=2)
    c.add("head_loca_fmt_2", sfnt(t), policy="quirk-loca-fmt:*", note="indexToLocFormat = 2")
    t = base_tables()
    t["head"] = head()[:53]
    c.add("head_short_53", sfnt(t), note="head 53 bytes")
    t = base_tables()
    t["maxp"] = maxp(0)
    c.add("maxp_zero_glyphs", sfnt(t), policy="quirk-skrifa-lenient:*", note="numGlyphs 0")
    t = base_tables()
    t["maxp"] = maxp(5, version=0x00005000)
    c.add("maxp_v05_with_glyf", sfnt(t), note="maxp 0.5 + glyf")

    # ------------------------------------------------------------------ D3: glyf / loca
    sq = simple_glyph(SQUARE)

    def gfont(glyphs, **kw):
        return base_font(glyphs=glyphs, cmap_t=cmap([(3, 1, fmt4({0x41: 1}))]), **kw)

    c.add("glyf_self_loop", gfont([sq, compound_glyph([{"gid": 1}]), sq]), policy="quirk-ttf-cycle:glyph",
          note="compound A -> A (ttf-parser recurses to depth 32 and gives up)")
    c.add("glyf_mutual_loop", gfont([sq, compound_glyph([{"gid": 2}]), compound_glyph([{"gid": 1}])]),
          policy="quirk-ttf-cycle:glyph", note="A -> B -> A")
    c.add("glyf_long_cycle", gfont([sq] + [compound_glyph([{"gid": (i % 6) + 1}]) for i in range(1, 7)]),
          policy="quirk-ttf-cycle:glyph", note="1 -> 2 -> ... -> 6 -> 1")
    c.add("glyf_cycle_after_leaf", gfont([sq, compound_glyph([{"gid": 2, "dx": 5}, {"gid": 1}]), sq]),
          policy="quirk-ttf-cycle:glyph", note="compound emits a leaf then cycles (partial output)")
    # diamond: level k glyph references level k+1 twice; level 14 is a leaf
    gl = [sq]
    depth = 14
    for k in range(depth):
        gl.append(compound_glyph([{"gid": k + 2, "dx": 1}, {"gid": k + 2, "dx": -1}]))
    gl.append(simple_glyph([[(0, 0, True), (10, 10, True), (20, 0, True)]]))
    c.add("glyf_diamond_2e14", gfont(gl), policy="guard-max-components:glyph",
          note="14-level diamond DAG: 2^14 = 16384 leaf visits; pion must stop at max_compound_components")
    chain = [sq] + [compound_glyph([{"gid": i + 2}]) for i in range(16)] + [sq]
    c.add("glyf_chain_depth_16", gfont(chain), note="compound chain depth 16 (allowed)")
    chain = [sq] + [compound_glyph([{"gid": i + 2}]) for i in range(17)] + [sq]
    c.add("glyf_chain_depth_17", gfont(chain), policy="quirk-depth-limit:glyph",
          note="depth 17 (pion max 16, ttf-parser 32, FreeType 100)")
    c.add("glyf_all_off_curve", gfont([sq, simple_glyph([[(0, 0, False), (100, 200, False), (300, 100, False), (200, -100, False)]])]),
          note="closed contour with only off-curve points (implied on-curve midpoints)")
    c.add("glyf_first_off_curve", gfont([sq, simple_glyph([[(50, 300, False), (0, 0, True), (300, 0, True), (350, 300, False), (200, 500, True)]])]),
          note="first point off-curve, last on-curve")
    c.add("glyf_first_last_off", gfont([sq, simple_glyph([[(50, 300, False), (0, 0, True), (300, 0, True), (350, 300, False)]])]),
          note="first and last point off-curve")
    c.add("glyf_single_on_point", gfont([sq, simple_glyph([[(10, 20, True)], [(5, 5, True), (9, 9, True)]])]), note="1-point contour")
    c.add("glyf_single_off_point", gfont([sq, simple_glyph([[(10, 20, False)]])]), policy="quirk-ttf-lone-close:outl",
          note="1-point off-curve contour (ttf-parser emits a lone Close)")
    zero = i16(0) + i16(0) * 4 + b"\0" * 8
    c.add("glyf_zero_contours", gfont([sq, zero]), policy="quirk-ttf-name:name,quirk-oracle-crash:*", note="numberOfContours 0 with trailing data")
    nm = bytearray(simple_glyph([[(0, 0, True), (1, 1, True)], [(2, 2, True), (3, 3, True)]]))
    nm[10:12] = u16(3)
    nm[12:14] = u16(1)  # 3, 1: non-monotonic
    c.add("glyf_endpts_non_monotonic", gfont([sq, bytes(nm)]), policy="quirk-endpts:outl", note="endPtsOfContours 3, 1")
    eq = simple_glyph([[(0, 0, True), (1, 1, True)], [], [(2, 2, True)]])
    c.add("glyf_endpts_repeated", gfont([sq, eq]), note="empty contour (repeated end point)")
    rp = bytearray(i16(1) + i16(0) * 4 + u16(2) + u16(0) + u8(0x09) + u8(200))
    c.add("glyf_repeat_overflow", gfont([sq, bytes(rp)]), note="REPEAT_FLAG count 200 for 3 points")
    big = i16(1) + i16(0) * 4 + u16(65535) + u16(0) + (u8(0x39) + u8(255)) * 256
    c.add("glyf_repeat_65536_points", gfont([sq, big]), policy="quirk-65536-points:glyph", note="65536 points from 512 flag bytes, all deltas 0")
    for nc in (-2, -32768):
        g2 = i16(nc) + compound_glyph([{"gid": 1, "dx": 7}])[2:]
        c.add("glyf_ncontours_%d" % (-nc), gfont([sq, g2]), note="numberOfContours %d treated as composite" % nc)
    c.add("glyf_instr_oob", gfont([sq, i16(1) + i16(0) * 4 + u16(0) + u16(0xFFFF) + b"\x01"]), note="instructionLength 65535")
    # coordinates overflow int16 (absolute 40000)
    c.add("glyf_coord_beyond_i16", gfont([sq, simple_glyph([[(0, 0, True), (30000, 0, True), (60000, 0, True), (60000, 100, True)]], bbox=(0, 0, 0, 0))]),
          policy="quirk-ttf-i16-wrap:outl", note="absolute x 60000 (ttf-parser wraps i16)")
    # compound transforms
    leaf = simple_glyph([[(0, 0, True), (100, 0, True), (100, 50, False), (0, 100, True)]])
    comps = {
        "glyf_cmp_scale": [{"gid": 2, "dx": 10, "dy": 20, "scale": 0.5}],
        "glyf_cmp_xy_scale": [{"gid": 2, "dx": -10, "dy": 5, "scale": (1.5, -1.0)}],
        "glyf_cmp_2x2": [{"gid": 2, "dx": 300, "dy": -300, "scale": (0.0, 1.0, -1.0, 0.0)}],
        "glyf_cmp_2x2_shear": [{"gid": 2, "dx": 1, "dy": 2, "scale": (1.0, 0.25, 0.5, 1.0)}],
        "glyf_cmp_words": [{"gid": 2, "dx": -2000, "dy": 3000}],
        "glyf_cmp_bytes_neg": [{"gid": 2, "dx": -128, "dy": 127}],
        "glyf_cmp_round_xy": [{"gid": 2, "dx": 3, "dy": 4, "flags": ARGS_XY | ROUND}],
        "glyf_cmp_use_my_metrics": [{"gid": 2, "dx": 3, "dy": 4, "flags": ARGS_XY | USE_MY}],
        "glyf_cmp_scaled_offset": [{"gid": 2, "dx": 100, "dy": 100, "scale": 0.5, "flags": ARGS_XY | SCALED_OFF}],
        "glyf_cmp_unscaled_offset": [{"gid": 2, "dx": 100, "dy": 100, "scale": 0.5, "flags": ARGS_XY | UNSCALED_OFF}],
        "glyf_cmp_nested": None,
    }
    for nm_, cl in comps.items():
        if cl is None:
            continue
        pol = "same"
        if nm_ == "glyf_cmp_scaled_offset":
            pol = "P2-5:glyph"
        c.add(nm_, gfont([sq, compound_glyph(cl), leaf]), policy=pol, note="compound component transform")
    c.add("glyf_cmp_nested", gfont([sq, compound_glyph([{"gid": 2, "dx": 50, "dy": 0, "scale": (0.5, 1.75)}]),
                                   compound_glyph([{"gid": 3, "dx": 0, "dy": 10, "scale": (0.0, 1.0, -1.0, 0.0)}]), leaf]),
          note="nested transforms combine")
    # point matching (!ARGS_ARE_XY_VALUES): parent point 3 matches child point 0
    c.add("glyf_cmp_point_match", gfont([sq, compound_glyph([{"gid": 3}, {"gid": 2, "dx": 3, "dy": 0, "flags": 0}]), leaf, sq]),
          policy="P2-5:glyph", note="anchor-point matching: component placed so child pt 0 sits on parent pt 3")
    both = compound_glyph([{"gid": 2, "dx": 5, "dy": 5, "flags": ARGS_XY | HAVE_SCALE | TWO_BY_TWO,
                            "raw_scale": f2d14(0.5) + f2d14(0) + f2d14(0) + f2d14(0.5)}])
    c.add("glyf_cmp_scale_and_2x2", gfont([sq, both, leaf]), policy="quirk-ttf-transform-order:outl",
          note="WE_HAVE_A_SCALE | WE_HAVE_A_TWO_BY_TWO both set (FreeType/fontTools read SCALE first)")
    # loca
    g, l = glyf_loca([sq, leaf, sq])
    t = base_tables(glyphs=[sq, leaf, sq])
    t["loca"] = u32(0) + u32(len(sq) + len(leaf)) + u32(len(sq)) + u32(len(g))
    c.add("loca_non_monotonic", sfnt(t), policy="quirk-loca-nonmono:outl,quirk-loca-nonmono:gbox",
          note="loca[2] < loca[1]")
    t = base_tables(glyphs=[sq, leaf, sq])
    t["loca"] = t["loca"][:-4]
    c.add("loca_truncated_last", sfnt(t), note="loca has numGlyphs entries (one short)")
    t = base_tables(glyphs=[sq, leaf, sq], loca_fmt=0)
    t["loca"] = t["loca"] + b"\x00"
    c.add("loca_short_odd_len", sfnt(t), policy="quirk-skrifa-loca-odd:glyph", note="short loca with odd length")
    t = base_tables(glyphs=[sq, leaf, sq])
    t["loca"] = u32(0) + u32(len(sq)) + u32(len(sq)) + u32(len(sq) * 2 + len(leaf) + 4096)
    c.add("loca_end_past_glyf", sfnt(t), policy="quirk-loca-oob:outl,quirk-loca-oob:gbox", note="last glyph end > glyf length")
    # short loca: offset word 0xFFFF -> byte 131070
    pad_glyphs = [sq] + [b""] * 2
    t = base_tables(glyphs=pad_glyphs, loca_fmt=0)
    filler = (sq + b"\0" * 131070)[:131070]
    t["glyf"] = filler + leaf + b"\0" * (-len(leaf) % 2)
    t["loca"] = u16(0) + u16(0) + u16(0xFFFF) + u16((131070 + len(leaf) + 1) // 2)
    c.add("loca_short_x2_max", sfnt(t), full=0, note="short loca word 0xFFFF -> byte offset 131070")
    t = base_tables(glyphs=[sq, b"", leaf])
    c.add("loca_empty_glyph", sfnt(t), note="empty glyph between two glyphs")

    # ------------------------------------------------------------------ D4: cmap
    def cfont(sub_list, ng=40, **kw):
        gl = [sq] * ng
        return base_font(glyphs=gl, cmap_t=cmap(sub_list), **kw)

    m = {0x20: 3, 0x41: 4, 0x42: 5, 0xE9: 6, 0x3B1: 7, 0x4E00: 8, 0xFFFD: 9}
    c.add("cmap_fmt0_unicode", cfont([(0, 3, fmt0({0x41: 4, 0xE9: 6, 0xFF: 7}))]), note="format 0 under Unicode platform")
    c.add("cmap_fmt4_basic", cfont([(3, 1, fmt4(m))]), note="format 4 idDelta segments")
    c.add("cmap_fmt4_delta_wrap", cfont([(3, 1, fmt4_segments([(0xFFF0, 0xFFFE, 0x0020, 0), (0xFFFF, 0xFFFF, 1, 0)]))]),
          note="idDelta wraps modulo 65536 ((cp + delta) & 0xFFFF)")
    c.add("cmap_fmt4_neg_delta", cfont([(3, 1, fmt4_segments([(0x30, 0x39, (-0x2F) & 0xFFFF, 0), (0xFFFF, 0xFFFF, 1, 0)]))]),
          note="negative idDelta")
    # idRangeOffset: segment 0 uses glyphIdArray right after idRangeOffset[]; ro = 2*(segCount - i) + 2*k
    segs = [(0x61, 0x65, 0, 4), (0xFFFF, 0xFFFF, 1, 0)]
    c.add("cmap_fmt4_range_offset", cfont([(3, 1, fmt4_segments(segs, glyph_ids=[10, 0, 12, 13, 14]))]),
          note="idRangeOffset glyphIdArray with a 0 (missing) entry")
    segs = [(0x61, 0x62, 5, 4), (0xFFFF, 0xFFFF, 1, 0)]
    c.add("cmap_fmt4_range_offset_delta", cfont([(3, 1, fmt4_segments(segs, glyph_ids=[30, 0xFFFE]))]),
          note="idRangeOffset + idDelta, (0xFFFE + 5) & 0xFFFF = 3")
    segs = [(0x61, 0x61, 0, 4), (0xFFFF, 0xFFFF, 1, 0)]
    c.add("cmap_fmt4_range_gid_high", cfont([(3, 1, fmt4_segments(segs, glyph_ids=[0x8001]))], ng=40),
          policy="quirk-ttf-fmt4-i16:cmap", note="glyphIdArray value 0x8001 (ttf-parser casts to i16 and drops it)")
    segs = [(0x61, 0x62, 0, 3), (0xFFFF, 0xFFFF, 1, 0)]
    c.add("cmap_fmt4_range_offset_odd", cfont([(3, 1, fmt4_segments(segs, glyph_ids=[0x0102, 0x0304, 0x0506]))]),
          policy="quirk-fmt4-odd-ro:cmap", note="odd idRangeOffset (misaligned)")
    segs = [(0x61, 0x62, 0, 0x7FF0), (0xFFFF, 0xFFFF, 1, 0)]
    c.add("cmap_fmt4_range_offset_oob", cfont([(3, 1, fmt4_segments(segs))]), note="idRangeOffset beyond subtable")
    segs = [(0x61, 0x62, 0, 0), (0xFFFF, 0xFFFF, 1, 0xFFFF)]
    c.add("cmap_fmt4_ffff_range_offset", cfont([(3, 1, fmt4_segments(segs))]), note="last idRangeOffset 0xFFFF")
    c.add("cmap_fmt4_segx2_zero", cfont([(3, 1, fmt4_segments([(0x41, 0x41, 1, 0)], seg_count_x2=0))]), note="segCountX2 0")
    c.add("cmap_fmt4_segx2_odd", cfont([(3, 1, fmt4_segments([(0x41, 0x41, 1, 0), (0xFFFF, 0xFFFF, 1, 0)], seg_count_x2=3))]),
          policy="quirk-fmt4-odd-seg:cmap", note="segCountX2 odd")
    c.add("cmap_fmt4_no_sentinel", cfont([(3, 1, fmt4_segments([(0x41, 0x5A, 0xFFE0 + 4, 0)]))]), note="no 0xFFFF sentinel segment")
    c.add("cmap_fmt4_overlap", cfont([(3, 1, fmt4_segments([(0x41, 0x50, 1, 0), (0x45, 0x60, 2, 0), (0xFFFF, 0xFFFF, 1, 0)]))]),
          policy="quirk-unsorted:cmap", note="overlapping segments")
    c.add("cmap_fmt4_unsorted", cfont([(3, 1, fmt4_segments([(0x61, 0x70, 3, 0), (0x41, 0x50, 1, 0), (0xFFFF, 0xFFFF, 1, 0)]))]),
          policy="quirk-unsorted:cmap", note="segments not sorted by endCode")
    c.add("cmap_fmt10_unicode", cfont([(0, 4, fmt10(0x1F600, [11, 0, 12])), (3, 1, fmt4({0x41: 4}))]), policy="quirk-fmt10:cmap",
          note="format 10 under Unicode 0/4")
    c.add("cmap_fmt6", cfont([(3, 1, fmt6(0x30, [5, 6, 0, 7]))]), note="format 6 trimmed")
    c.add("cmap_fmt6_wrap", cfont([(3, 1, fmt6(0xFFFE, [5, 6, 7, 8]))]), note="firstCode + entryCount > 0x10000")
    c.add("cmap_fmt10", cfont([(3, 10, fmt10(0x1F600, [11, 0, 12]))]), policy="quirk-fmt10:cmap", note="format 10 trimmed array")
    g12 = [(0x20, 0x20, 3), (0x41, 0x43, 4), (0x1F600, 0x1F602, 20)]
    c.add("cmap_fmt12", cfont([(3, 10, fmt12(g12))]), note="format 12 sequential")
    c.add("cmap_fmt12_unsorted", cfont([(3, 10, fmt12([(0x1F600, 0x1F602, 20), (0x41, 0x43, 4), (0x20, 0x20, 3)]))]),
          policy="quirk-unsorted:cmap", note="groups not sorted")
    c.add("cmap_fmt12_start_gt_end", cfont([(3, 10, fmt12([(0x41, 0x43, 4), (0x50, 0x48, 9), (0x60, 0x61, 10)]))]),
          policy="quirk-unsorted:cmap", note="startCharCode > endCharCode")
    c.add("cmap_fmt12_beyond_10ffff", cfont([(3, 10, fmt12([(0x41, 0x41, 4), (0x10FFFE, 0x110005, 10)]))]),
          note="endCharCode > 0x10FFFF")
    c.add("cmap_fmt12_surrogates", cfont([(3, 10, fmt12([(0x41, 0x41, 4), (0xD7FF, 0xE000, 10)]))]),
          policy="quirk-surrogate:cmap", note="group spans the surrogate range (pion must not map U+D800..DFFF; see P2-3)")
    c.add("cmap_fmt12_gid_overflow", cfont([(3, 10, fmt12([(0x41, 0x50, 0xFFF8)]))]), note="startGlyphID + n > 65535")
    c.add("cmap_fmt12_ngroups_huge", cfont([(3, 10, fmt12(g12, n_groups=0xFFFFFFFF))]), note="nGroups = 0xFFFFFFFF")
    c.add("cmap_fmt12_gid0", cfont([(3, 10, fmt12([(0x40, 0x42, 0)]))]), policy="quirk-gid0:cmap",
          note="group maps first char to glyph 0")
    c.add("cmap_fmt13", cfont([(3, 10, fmt12([(0x41, 0x5A, 7), (0x1F000, 0x1F0FF, 8)], fmt=13))]), note="format 13 many-to-one")
    c.add("cmap_fmt13_unsorted", cfont([(3, 10, fmt12([(0x1F000, 0x1F0FF, 8), (0x41, 0x5A, 7)], fmt=13))]),
          policy="quirk-unsorted:cmap", note="format 13 groups unsorted (ttf-parser scans linearly)")
    # format 14
    f14 = fmt14([(0xFE00, [(0x41, 0), (0x4E00, 2)], [(0x42, 30), (0x4E01, 31)]),
                 (0xFE0F, None, [(0x2764, 32)]),
                 (0xE0100, [(0x10FF80, 255)], None)])
    c.add("cmap_fmt14", cfont([(3, 1, fmt4(m)), (0, 5, f14)]),
          queries=["uvs 41 fe00", "uvs 42 fe00", "uvs 4e02 fe00", "uvs 4e03 fe00", "uvs 4e01 fe00", "uvs 2764 fe0f",
                   "uvs 2764 fe00", "uvs 43 fe00", "uvs 41 fe01", "uvs 10ffff e0100", "uvs 10ff7f e0100", "uvs 0 0"],
          note="UVS default ranges (additionalCount, u24 overflow near 0xFFFFFF) and non-default mappings")
    f14b = fmt14([(0xFE00, 0x7FFFFFF0, 0x7FFFFFF0), (0xFE01, [(0x41, 0)], 3)])
    c.add("cmap_fmt14_oob", cfont([(3, 1, fmt4(m)), (0, 5, f14b)]), queries=["uvs 41 fe00", "uvs 41 fe01", "uvs 42 fe01"],
          note="UVS offsets beyond subtable / into header")
    # subtable priority
    conflict_bmp = fmt4({0x41: 4, 0x42: 5})
    conflict_full = fmt12([(0x41, 0x41, 14), (0x1F600, 0x1F600, 15)])
    c.add("cmap_prio_win_bmp_first", cfont([(3, 1, conflict_bmp), (3, 10, conflict_full)]),
          policy="quirk-prio:cmap", note="3/1 fmt4 listed before 3/10 fmt12 with conflicting 'A'")
    c.add("cmap_prio_unicode_vs_win", cfont([(0, 3, conflict_bmp), (3, 1, fmt4({0x41: 24, 0x43: 6}))]),
          policy="quirk-prio:cmap", note="0/3 vs 3/1 disagree on 'A'")
    mac = fmt0({0x41: 4, 0x80: 10, 0x8E: 11, 0xA0: 12, 0xE9: 13, 0xDB: 14})
    c.add("cmap_mac_roman_only", cfont([(1, 0, mac)]), policy="P1-2:cmap",
          note="only a Mac Roman (1,0) byte table: Unicode lookups index it with the raw code point")
    c.add("cmap_mac_roman_fmt6_only", cfont([(1, 0, fmt6(0x80, [10, 11, 12]))]), policy="P1-2:cmap",
          note="Mac Roman format 6 only")
    c.add("cmap_mac_plus_unicode", cfont([(1, 0, mac), (3, 1, fmt4({0x41: 4, 0xC4: 10}))]), note="Mac + Windows Unicode")
    c.add("cmap_symbol_only", cfont([(3, 0, fmt4({0xF041: 4, 0xF042: 5, 0xF020: 3}))]), policy="P2-11:cmap",
          note="Windows Symbol (3,0) only; skrifa/FreeType remap U+0000..00FF to U+F000..F0FF")
    c.add("cmap_win_ucs4_fmt4", cfont([(3, 10, fmt4({0x41: 4}))]), policy="quirk-prio:cmap",
          note="3/10 carrying format 4 (ttf-parser accepts only 12/13 under 3/10)")
    c.add("cmap_num_tables_0", cfont([]), note="cmap with 0 encoding records")
    c.add("cmap_sub_offset_oob", cfont([(3, 1, 0x7FFFFFFF), (0, 3, fmt4(m))]), note="first record points past the table")
    c.add("cmap_sub_offset_into_header", cfont([(3, 1, 0)]), note="subtable offset 0 (cmap header)")
    c.add("cmap_unsupported_fmt8", cfont([(3, 10, u16(8) + b"\0" * 64), (3, 1, fmt4(m))]), note="format 8 ignored, falls back")

    # ------------------------------------------------------------------ D5: metrics, names, kern, variations
    c.add("hmtx_nhm_0", base_font(nhm=0, metrics=[]), note="numberOfHMetrics 0")
    t = base_tables()
    t["hhea"] = hhea(40)
    c.add("hmtx_nhm_gt_ng", sfnt(t), policy="quirk-hmtx-truncated:hmtx", note="numberOfHMetrics 40 > numGlyphs 5")
    t = base_tables(nhm=2)
    t["hmtx"] = t["hmtx"][:-3]
    c.add("hmtx_lsb_truncated", sfnt(t), policy="quirk-hmtx-truncated:hmtx", note="trailing leftSideBearing array truncated")
    t = base_tables()
    t["hmtx"] = t["hmtx"][:7]
    c.add("hmtx_metrics_truncated", sfnt(t), policy="quirk-hmtx-truncated:hmtx", note="longHorMetric array truncated")
    t = base_tables()
    t["vhea"] = vhea(0)
    t["vmtx"] = mtx([(1000, 1)])
    c.add("vmtx_nvm_0", sfnt(t), policy="quirk-vmtx-nvm0:vmtx", note="numberOfVMetrics 0")
    t = base_tables()
    t["vmtx"] = mtx([(1000, 1)] * 5)
    c.add("vmtx_without_vhea", sfnt(t), note="vmtx without vhea")
    # OS/2 versions and lengths
    for v, ln in ((0, 78), (1, 86), (2, 96), (3, 96), (4, 96), (5, 100), (4, 77), (2, 90)):
        t = base_tables()
        t["OS/2"] = os2(version=v, length=ln)
        c.add("os2_v%d_len%d" % (v, ln), sfnt(t), policy="quirk-os2-len:os2" if ln in (77, 90) else "same",
              note="OS/2 version %d, %d bytes" % (v, ln))
    t = base_tables()
    t["post"] = post()[:31]
    c.add("post_short", sfnt(t), note="post 31 bytes")
    # name
    recs = [
        (3, 1, 0x409, 1, utf16("Fam\U0001F600ily")),
        (3, 1, 0x409, 2, b"\xd8\x3d\x00\x41"),  # lone high surrogate followed by 'A'
        (3, 1, 0x409, 3, b"\x00\x41\xdc\x00"),  # lone low surrogate
        (3, 1, 0x409, 4, b"\x00\x41\xd8\x3d"),  # high surrogate at end
        (3, 1, 0x409, 5, b"\x00\x41\x00"),  # odd length
        (3, 1, 0x409, 6, b"", (0xFFF0, 0x20)),  # offset out of storage
        (3, 10, 0x409, 7, utf16("ucs4")),
        (3, 0, 0x409, 8, utf16("sym")),
        (0, 4, 0, 9, utf16("uni4")),
        (1, 0, 0, 10, bytes(range(0x20, 0x7F))),
        (1, 0, 0, 11, bytes(range(0x80, 0x100))),
        (1, 1, 0, 12, b"\x82\xa0"),  # Mac Japanese: undecodable
        (2, 1, 0, 13, b"iso"),
    ]
    t = base_tables()
    t["name"] = name_table(recs)
    c.add("name_edge", sfnt(t), policy="same",
          note="lone/odd surrogates, OOB offset, Mac Roman 0x20..0xFF, unsupported encodings")
    t = base_tables()
    t["name"] = name_table([(3, 1, 0x409, 1, utf16("Format1")), (3, 1, 0x409, 2, utf16("Bold"))], version=1,
                           langtags=[utf16("en-US")])
    c.add("name_format1", sfnt(t), policy="quirk-ttf-name-v1:name", note="name format 1 with a language tag")
    t = base_tables()
    t["name"] = u16(0) + u16(4096) + u16(6) + b"\0" * 64
    c.add("name_count_truncated", sfnt(t), note="count 4096, table 70 bytes")
    t = base_tables()
    nt = bytearray(name_table([(3, 1, 0x409, 1, utf16("abc"))]))
    nt[4:6] = u16(4)  # storageOffset inside the record array
    t["name"] = bytes(nt)
    c.add("name_storage_overlaps_records", sfnt(t), policy="quirk-ttf-name-storage:name",
          note="storageOffset points inside the header/records")
    # kern
    pairs = [(1, 2, -50), (2, 1, 30), (4, 1, 7)]
    c.add("kern_v0_basic", base_font(extra={"kern": kern_v0([kern_sub0(pairs)])}),
          queries=kq([(1, 2), (2, 1), (4, 1), (1, 1), (0, 0)]), note="OpenType kern v0 format 0")
    many = [(l, r, ((l * 7 + r) % 200) - 100 or 1) for l in range(1, 140) for r in range(1, 90)]  # 12371 pairs
    sub = kern_sub0(many)
    n_len = (6 + 8 + 6 * len(many)) & 0xFFFF
    sub_wrapped = sub[:2] + u16(n_len) + sub[4:]
    probe = [(1, 1), (1, 2), (50, 50), (139, 89), (100, 3), (139, 1), (77, 77), (2, 88)]
    c.add("kern_v0_u16_length_overflow", base_font(glyphs=[sq] * 150, extra={"kern": kern_v0([sub_wrapped])}),
          queries=kq(probe), full=0, policy="P1-1:kern",
          note="single subtable with 12371 pairs: the u16 length field wraps (fonts abuse this; ttf-parser ignores it)")
    c.add("kern_v0_multi_sum", base_font(extra={"kern": kern_v0([kern_sub0(pairs), kern_sub0([(1, 2, -5), (3, 3, 9)])])}),
          queries=kq([(1, 2), (3, 3), (2, 1)]), note="two horizontal subtables accumulate")
    c.add("kern_v0_override", base_font(extra={"kern": kern_v0([kern_sub0(pairs), kern_sub0([(1, 2, -5)], coverage=0x0009)])}),
          queries=kq([(1, 2), (2, 1)]), policy="quirk-kern-override:kern", note="override bit replaces accumulated value")
    c.add("kern_v0_minimum", base_font(extra={"kern": kern_v0([kern_sub0(pairs), kern_sub0([(1, 2, -5)], coverage=0x0003)])}),
          queries=kq([(1, 2)]), policy="quirk-kern-minimum:kern", note="minimum-values subtable")
    c.add("kern_v0_cross_vertical", base_font(extra={"kern": kern_v0([kern_sub0(pairs, coverage=0x0005), kern_sub0(pairs, coverage=0x0000)])}),
          queries=kq([(1, 2), (2, 1)]), note="cross-stream and vertical subtables ignored")
    c.add("kern_v0_unsorted", base_font(extra={"kern": kern_v0([kern_sub0([(4, 1, 7), (1, 2, -50), (2, 1, 30)])])}),
          queries=kq([(1, 2), (2, 1), (4, 1)]), policy="quirk-unsorted:kern", note="pairs not sorted")
    c.add("kern_v0_npairs_huge", base_font(extra={"kern": kern_v0([kern_sub0(pairs, raw_n=0xFFFF)])}),
          queries=kq([(1, 2), (2, 1), (4, 1)]), policy="quirk-kern-npairs:kern", note="nPairs 65535 with 3 pairs present")
    fmt2 = u16(0) + u16(6 + 8) + u16(0x0201) + b"\0" * 8
    c.add("kern_v0_fmt2_then_fmt0", base_font(extra={"kern": kern_v0([fmt2, kern_sub0(pairs)])}),
          queries=kq([(1, 2)]), policy="quirk-kern-fmt2:kern", note="class-based format 2 subtable before format 0")
    c.add("kern_aat", base_font(extra={"kern": kern_aat([(0x0000, pairs), (0x8000, [(1, 2, 99)]), (0x4000, [(1, 2, 98)]),
                                                         (0x2000, [(1, 2, 97)]), (0x0000, [(1, 2, 1)])])}),
          queries=kq([(1, 2), (2, 1)]), note="AAT kern v1.0: vertical / cross-stream / variation subtables skipped")
    # fvar / avar
    axes = [("wght", 100, 400, 900, 0, 256), ("wdth", 50, 100, 200, 1, 257), ("opsz", 8, 8, 72, 0, 258),
            ("slnt", -15, 0, 0, 0, 259), ("BIGV", -30000.5, 1000.25, 32767.99998, 0, 260)]
    inst = [(261, [400, 100, 12, 0, 1000.25], 300), (262, [900, 200, 72, -15, 32767])]
    norms = ["norm 400,100,8,0,1000.25", "norm 100,50,8,-15,-30000.5", "norm 900,200,72,0,32767.99998",
             "norm 1000,10,100,5,40000", "norm 650,75,40,-7.5,0", "norm 399.99,100.01,8.01,-0.01,1000.26",
             "norm 400.0061,100,8,0,1000", "norm 399.9939,100,8,0,1000"]
    av = [[(-1, -1), (0, 0), (0.5, 0.8), (1, 1)], [(-1, -1), (0, 0), (1, 1)], [], [(-1, -1), (-0.5, -0.25), (0, 0), (1, 1)],
          [(-1, -1), (0, 0), (1, 1)]]
    t = base_tables(extra={"fvar": fvar(axes, inst, ps_names=True), "avar": avar(av)})
    c.add("var_fvar_avar", sfnt(t), queries=norms, policy="quirk-ttf-axis:axis,P2-2:norm,P2-8:inst",
          note="5 axes incl. default==min, default==max, large Fixed values; avar with a 0.5 -> 0.8 knee")
    # rounding of negative half units: axis -1..0..1, coordinate -1/32768 -> -0.5 F2Dot14 units
    t = base_tables(extra={"fvar": fvar([("TEST", -1, 0, 1, 0, 256)])})
    c.add("var_round_neg_half", sfnt(t), queries=["norm -0.000030517578125", "norm 0.000030517578125", "norm -0.0000915527",
                                                   "norm -0.5", "norm -2"],
          policy="P2-2:norm", note="F2Dot14 rounding of exact negative half units (spec: +2 >> 2, i.e. round half up)")
    t = base_tables(extra={"fvar": fvar([("TEST", -1, 0, 1, 0, 256), ("TST2", 0, 0.5, 1, 0, 257)]),
                           "avar": avar([[(-1, -1), (0.2, 0.0), (0, 0.5), (1, 1)], [(-1, -1), (0, 0), (0, 0.3), (1, 1)]])})
    c.add("var_avar_non_monotonic", sfnt(t), queries=["norm 0.1,0.75", "norm -0.5,0.25", "norm 0.5,1", "norm 0,0.5"],
          policy="quirk-avar-malformed:norm", note="avar fromCoordinate not monotonic / duplicated")
    t = base_tables(extra={"fvar": fvar([("TEST", -1, 0, 1, 0, 256), ("TST2", 0, 0.5, 1, 0, 257)]),
                           "avar": avar([[(-1, -0.5), (1, 0.5)]], axis_count=2)})
    c.add("var_avar_axis_mismatch", sfnt(t), queries=["norm 0.5,0.75", "norm -1,1"],
          policy="quirk-avar-malformed:norm", note="avar axisCount 2 but only one segment map present")
    t = base_tables(extra={"fvar": fvar([("TEST", -1, 0, 1, 0, 256)]), "avar": avar([[(0.5, 0.25)]])})
    c.add("var_avar_single_map", sfnt(t), queries=["norm 0.5", "norm -1", "norm 1"], policy="quirk-avar-malformed:norm",
          note="avar segment with a single map (no -1/0/1 anchors)")
    t = base_tables(extra={"fvar": fvar([("TEST", 0, 10, 5, 0, 256)])})
    c.add("var_min_gt_max", sfnt(t), queries=["norm 7", "norm 0", "norm 11"], policy="quirk-axis-malformed:norm",
          note="axis min 0, default 10, max 5")
    t = base_tables(extra={"fvar": fvar([("TEST", 0, 10, 5, 0, 256)], axis_size=24)})
    c.add("var_axis_size_24", sfnt(t), policy="quirk-ttf-axis:axis,P2-2:norm", queries=["norm 1"], note="axisSize 24")
    return c


# ----------------------------------------------------------------------------- DoS bombs (< 8 KiB)


def bombs(out):
    os.makedirs(os.path.join(out, "bombs"), exist_ok=True)
    rows = []
    sq = simple_glyph(SQUARE)

    def add(name, data, budget, note):
        assert len(data) < 8192, (name, len(data))
        p = os.path.join(out, "bombs", name + ".ttf")
        with open(p, "wb") as f:
            f.write(data)
        rows.append((name, p, str(budget), note))

    # 1. diamond DAG 2^20 visits (20 levels, 2 refs each)
    gl = [sq]
    for k in range(20):
        gl.append(compound_glyph([{"gid": k + 2, "dx": 1}, {"gid": k + 2, "dx": -1}]))
    gl.append(simple_glyph([[(0, 0, True), (10, 10, True), (20, 0, True)]]))
    add("diamond_2e20", base_font(glyphs=gl, cmap_t=cmap([(3, 1, fmt4({0x41: 1}))])), 1000, "20-level diamond, 2^20 leaf visits")
    # 2. wide diamond: 8 levels x 16 references = 16^8 visits
    gl = [sq]
    for k in range(8):
        gl.append(compound_glyph([{"gid": k + 2, "dx": j} for j in range(16)]))
    gl.append(sq)
    add("diamond_16e8", base_font(glyphs=gl, cmap_t=cmap([(3, 1, fmt4({0x41: 1}))])), 1000, "8 levels x 16 refs")
    # 3. numTables 65535 declared
    add("num_tables_65535", sfnt(base_tables(), num_tables=65535), 200, "numTables 65535 (truncated)")
    # 4. ttc numFonts 0xFFFFFFFF
    add("ttc_numfonts_max", ttc([base_tables()], num_fonts=0xFFFFFFFF), 200, "numFonts 0xFFFFFFFF")
    # 5. cmap fmt12 nGroups max
    add("cmap_ngroups_max", base_font(cmap_t=cmap([(3, 10, fmt12([(0x41, 0x41, 1)], n_groups=0xFFFFFFFF))])), 3000,
        "nGroups 0xFFFFFFFF")
    # 6. numGlyphs 65535, all empty, loca short of entries
    t = base_tables()
    t["maxp"] = maxp(65535)
    add("num_glyphs_65535", sfnt(t), 3000, "numGlyphs 65535 with 5 glyphs of data")
    # 7. REPEAT_FLAG bomb: 12 glyphs x 65536 points
    big = i16(1) + i16(0) * 4 + u16(65535) + u16(0) + (u8(0x39) + u8(255)) * 256
    add("repeat_flag_points", base_font(glyphs=[sq] + [big] * 12, cmap_t=cmap([(3, 1, fmt4({0x41: 1}))])), 3000,
        "12 glyphs x 65536 points")
    # 8. compound referencing the 65536-point glyph 1024 times
    gl = [sq, big, compound_glyph([{"gid": 1, "dx": j % 100} for j in range(1024)])]
    data = base_font(glyphs=gl, cmap_t=cmap([(3, 1, fmt4({0x41: 1}))]))
    if len(data) < 8192:
        add("compound_x_points", data, 3000, "1024 refs to a 65536-point glyph")
    # 9. name count 65535 (truncated) + 600 overlapping 7 KiB records
    t = base_tables()
    t["name"] = u16(0) + u16(0xFFFF) + u16(6) + b"\0" * 128
    add("name_count_max", sfnt(t), 200, "name count 65535")
    t = base_tables()
    st = utf16("x" * 3000)
    nrec = 400
    recs = b"".join(u16(3) + u16(1) + u16(0x409) + u16(1 + (k % 30)) + u16(len(st)) + u16(0) for k in range(nrec))
    t["name"] = u16(0) + u16(nrec) + u16(6 + len(recs)) + recs + st
    t["cmap"] = cmap([(3, 1, fmt4({0x41: 1}))])
    data = sfnt(t)
    while len(data) >= 8192:
        nrec -= 20
        recs = b"".join(u16(3) + u16(1) + u16(0x409) + u16(1 + (k % 30)) + u16(len(st)) + u16(0) for k in range(nrec))
        t["name"] = u16(0) + u16(nrec) + u16(6 + len(recs)) + recs + st
        data = sfnt(t)
    add("name_overlapping_records", data, 3000, "%d records all aliasing one 6000-byte string" % nrec)
    # 10. kern v0 with ~1300 tiny subtables (per-lookup linear scan)
    subs = [kern_sub0([(1, 2, 1)])] * 280
    add("kern_many_subtables", base_font(extra={"kern": kern_v0(subs)}), 3000, "280 kern subtables")
    # 11. cmap with ~900 encoding records to distinct broken subtables (each lookup walks all of them)
    best = fmt12([(0x41, 0x41, 1)])
    other = fmt4({0x42: 2})
    recs = [(3, 10, best)] + [(3, 1, other)] * 900
    add("cmap_many_records", base_font(cmap_t=cmap(recs)), 3000,
        "901 encoding records, 900 aliasing one format 4 subtable: every miss re-walks all of them")
    # 12. fmt4 segCountX2 65534 (truncated)
    add("cmap_fmt4_segcount_max", base_font(cmap_t=cmap([(3, 1, fmt4_segments([(0x41, 0x41, 1, 0)], seg_count_x2=0xFFFE))])), 3000,
        "segCountX2 0xFFFE")
    # 13. truncated-at-every-byte stream is the fuzz corpus; here: avar / fvar maximal counts
    t = base_tables(extra={"fvar": u16(1) + u16(0) + u16(16) + u16(2) + u16(256) + u16(20) + u16(4096) + u16(1028) + b"\0" * 64,
                           "avar": u16(1) + u16(0) + u16(0) + u16(256) + (u16(4096) + b"\0" * 16) * 4})
    add("fvar_avar_counts_max", sfnt(t), 200, "fvar 256 axes x 4096 instances declared, avar 4096 pairs declared")
    # 14. UVS nRecords max
    add("uvs_records_max", base_font(cmap_t=cmap([(3, 1, fmt4({0x41: 1})), (0, 5, u16(14) + u32(0xFFFFFFFF) + u32(0xFFFFFFFF) + b"\0" * 64)])),
        3000, "Format 14 numVarSelectorRecords 0xFFFFFFFF")
    # 15. directory of 400 unsorted records (insertion sort)
    t = base_tables()
    recs = [("z%03d" % k, 0, 0) for k in range(400, 0, -1)]
    add("dir_unsorted_400", sfnt(t, order=sorted(t, reverse=True), records=recs), 500, "405 unsorted directory records")
    with open(os.path.join(out, "bombs.tsv"), "w") as f:
        for r in rows:
            f.write("\t".join(r) + "\n")
    return rows


# ----------------------------------------------------------------------------- fuzz corpus


def fuzz(out, n, seed=20261124):
    os.makedirs(os.path.join(out, "fuzz"), exist_ok=True)
    rng = random.Random(seed)
    sq = simple_glyph(SQUARE)
    seeds = [
        base_font(),
        base_font(loca_fmt=0),
        sfnt(base_tables(extra={"kern": kern_v0([kern_sub0([(1, 2, -50), (2, 1, 30)])]),
                                "fvar": fvar([("wght", 100, 400, 900, 0, 256)], [(257, [700])]),
                                "avar": avar([[(-1, -1), (0, 0), (0.5, 0.7), (1, 1)]])})),
        base_font(cmap_t=cmap([(3, 10, fmt12([(0x41, 0x43, 1), (0x1F600, 0x1F602, 2)])),
                               (0, 5, fmt14([(0xFE00, [(0x41, 2)], [(0x42, 3)])])),
                               (3, 1, fmt4({0x41: 1, 0x42: 2})), (1, 0, fmt0({0x41: 1}))])),
        base_font(glyphs=[sq, compound_glyph([{"gid": 2, "dx": 3, "scale": (0.5, 0.0, 0.0, 0.5)}]),
                          compound_glyph([{"gid": 3, "dx": 1}, {"gid": 3, "dx": 2, "scale": 0.5}]), simple_glyph(TRI_Q)]),
        ttc([base_tables(), base_tables(loca_fmt=0)], version=0x00020000),
    ]
    files = []
    for k in range(n):
        d = bytearray(seeds[k % len(seeds)])
        op = rng.randrange(6)
        if op == 0:  # truncate
            d = d[:rng.randrange(len(d))]
        elif op == 1:  # flip bytes
            for _ in range(rng.randint(1, 8)):
                d[rng.randrange(len(d))] ^= 1 << rng.randrange(8)
        elif op == 2:  # interesting u16 into random aligned offset
            pos = rng.randrange(len(d) - 2) & ~1
            d[pos:pos + 2] = u16(rng.choice([0, 1, 0x7FFF, 0x8000, 0xFFFF, 0xFFFE, 0x100]))
        elif op == 3:  # interesting u32
            pos = rng.randrange(len(d) - 4) & ~1
            d[pos:pos + 4] = u32(rng.choice([0, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, len(d), len(d) - 1, 0x10000]))
        elif op == 4:  # random bytes run
            pos = rng.randrange(len(d))
            ln = rng.randint(1, 32)
            d[pos:pos + ln] = bytes(rng.randrange(256) for _ in range(ln))
        else:  # directory field mutation
            if len(d) > 28:
                rec = 12 + 16 * rng.randrange(max(1, (min(len(d), 200) - 12) // 16))
                fld = rng.choice([4, 8, 12])
                if rec + fld + 4 <= len(d):
                    d[rec + fld:rec + fld + 4] = u32(rng.choice([0, 0xFFFFFFFF, len(d), rng.randrange(len(d) + 64)]))
        p = os.path.join(out, "fuzz", "%05d.ttf" % k)
        with open(p, "wb") as f:
            f.write(bytes(d))
        files.append(p)
    with open(os.path.join(out, "fuzz.txt"), "w") as f:
        f.write("\n".join(files) + "\n")
    return files


# ----------------------------------------------------------------------------- system fonts


def face_tables(data, face):
    off = 0
    if data[:4] == b"ttcf":
        off = struct.unpack(">I", data[12 + 4 * face:16 + 4 * face])[0]
    n = struct.unpack(">H", data[off + 4:off + 6])[0]
    t = {}
    for i in range(n):
        tg, _, o, ln = struct.unpack(">4sIII", data[off + 12 + 16 * i:off + 28 + 16 * i])
        if o + ln <= len(data):
            t[tg.decode("latin-1")] = data[o:o + ln]
    return t


def system_queries(path, face, qpath):
    """kern pairs, UVS sequences and variation coordinates taken from the font itself."""
    q = []
    try:
        data = open(path, "rb").read()
        t = face_tables(data, face)
        k = t.get("kern", b"")
        pairs = []
        if len(k) >= 4 and struct.unpack(">H", k[:2])[0] == 0:
            n, pos = struct.unpack(">H", k[2:4])[0], 4
            for _ in range(n):
                if pos + 6 > len(k):
                    break
                ln, cov = struct.unpack(">HH", k[pos + 2:pos + 6])
                if cov >> 8 == 0 and pos + 14 <= len(k):
                    np_ = struct.unpack(">H", k[pos + 6:pos + 8])[0]
                    for j in range(np_):
                        e = pos + 14 + 6 * j
                        if e + 6 > len(k):
                            break
                        pairs.append(struct.unpack(">HH", k[e:e + 4]))
                pos += ln if ln >= 6 else len(k)
        elif len(k) >= 8 and struct.unpack(">I", k[:4])[0] == 0x00010000:
            n, pos = struct.unpack(">I", k[4:8])[0], 8
            for _ in range(min(n, 64)):
                if pos + 8 > len(k):
                    break
                ln, cov = struct.unpack(">IH", k[pos:pos + 6])
                if cov & 0xFF == 0 and pos + 16 <= len(k):
                    np_ = struct.unpack(">H", k[pos + 8:pos + 10])[0]
                    for j in range(np_):
                        e = pos + 16 + 6 * j
                        if e + 6 > len(k):
                            break
                        pairs.append(struct.unpack(">HH", k[e:e + 4]))
                if ln < 8:
                    break
                pos += ln
        # a pair listed twice (Hoefler Text has (454, 484) = -60 and -76) has no defined value: binary
        # searches legitimately differ, so duplicated keys are not queried
        seen = {}
        for pr in pairs:
            seen[pr] = seen.get(pr, 0) + 1
        pairs = [pr for pr in pairs if seen[pr] == 1]
        step = max(1, len(pairs) // 400)
        sel = pairs[::step][:400] + pairs[-20:]
        q += ["kern %d %d" % (l, r) for l, r in sel] + ["kern %d %d" % (r, l) for l, r in sel[:40]]
        cm = t.get("cmap", b"")
        if len(cm) >= 4:
            for i in range(struct.unpack(">H", cm[2:4])[0]):
                if 12 + 8 * i > len(cm):
                    break
                pid, eid, so = struct.unpack(">HHI", cm[4 + 8 * i:12 + 8 * i])
                if so + 10 > len(cm) or struct.unpack(">H", cm[so:so + 2])[0] != 14:
                    continue
                nr = struct.unpack(">I", cm[so + 6:so + 10])[0]
                seqs = []
                for r in range(min(nr, 64)):
                    e = so + 10 + 11 * r
                    if e + 11 > len(cm):
                        break
                    vs = int.from_bytes(cm[e:e + 3], "big")
                    d_off, nd_off = struct.unpack(">II", cm[e + 3:e + 11])
                    for base, size, add in ((d_off, 4, True), (nd_off, 5, False)):
                        if not base or so + base + 4 > len(cm):
                            continue
                        cnt = struct.unpack(">I", cm[so + base:so + base + 4])[0]
                        for z in range(min(cnt, 20)):
                            e2 = so + base + 4 + size * z
                            if e2 + size > len(cm):
                                break
                            u = int.from_bytes(cm[e2:e2 + 3], "big")
                            seqs.append((u, vs))
                            if add:
                                seqs.append((u + cm[e2 + 3], vs))
                    seqs.append((0x41, vs))
                q += ["uvs %x %x" % (u, vs) for u, vs in seqs[:600] if u <= 0x10FFFF]
                break
        fv = t.get("fvar", b"")
        if len(fv) >= 16:
            ao, _, ac, asz = struct.unpack(">HHHH", fv[4:12])
            axes = []
            for i in range(ac):
                e = ao + i * asz
                if e + 16 > len(fv):
                    break
                mn, df, mx = (struct.unpack(">i", fv[e + 4 * j:e + 4 * j + 4])[0] / 65536 for j in (1, 2, 3))
                axes.append((mn, df, mx))
            pts = []
            for f in (0.0, 1.0, 0.5, 0.25, 0.8125, 0.3330078125):
                pts.append([round((a[0] + (a[2] - a[0]) * f) * 64) / 64 for a in axes])
            pts.append([a[1] for a in axes])
            q += ["norm " + ",".join(repr(v) for v in p) for p in pts if p]
    except Exception as e:  # a broken system font is not a corpus error
        q.append("# query generation failed: %s" % e)
    with open(qpath, "w") as f:
        f.write("\n".join(x for x in q if not x.startswith("#")) + "\n")


def system_fonts(out):
    rows = []
    roots = ["/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts",
             "/usr/share/fonts/truetype", "/usr/share/fonts/TTF"]
    for r in roots:
        if not os.path.isdir(r):
            continue
        for fn in sorted(os.listdir(r)):
            p = os.path.join(r, fn)
            low = fn.lower()
            if not os.path.isfile(p) or not low.endswith((".ttf", ".ttc", ".otf")):
                continue
            if os.path.getsize(p) > 40 * 1024 * 1024:
                continue
            with open(p, "rb") as f:
                hdr = f.read(12)
            faces = 1
            if hdr[:4] == b"ttcf":
                faces = min(struct.unpack(">I", hdr[8:12])[0], 3)
            for i in range(faces):
                rows.append((p, str(i)))
    os.makedirs(os.path.join(out, "sysq"), exist_ok=True)
    with open(os.path.join(out, "system.tsv"), "w") as f:
        for i, (p, face) in enumerate(rows):
            qp = os.path.join(out, "sysq", "%d.q" % i)
            system_queries(p, int(face), qp)
            f.write("%s\t%s\t%s\n" % (p, face, qp))
    return rows


def macroman(out):
    with open(os.path.join(out, "macroman.tsv"), "w") as f:
        for b in range(256):
            f.write("%02x\t%x\n" % (b, ord(bytes([b]).decode("mac_roman"))))


def main():
    out = sys.argv[1]
    fuzz_n = int(sys.argv[2]) if len(sys.argv) > 2 else 3000
    os.makedirs(out, exist_ok=True)
    c = build_corpus(Corpus(out))
    c.write()
    b = bombs(out)
    fz = fuzz(out, fuzz_n)
    s = system_fonts(out)
    macroman(out)
    print("%d synthesized cases, %d bombs (< 8 KiB), %d fuzz fonts, %d system font faces" % (len(c.rows), len(b), len(fz), len(s)))


if __name__ == "__main__":
    main()
