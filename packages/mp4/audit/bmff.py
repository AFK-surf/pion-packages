"""Minimal ISO BMFF tree reader/writer used by the RT-mp4 audit (corpus rewrites + fuzz mutations).

A box is `[type(bytes4), payload(bytes) | children(list), extra]`; containers listed in CONTAINERS
are parsed recursively.  `serialize` recomputes every size (32-bit, or 64-bit largesize when
`extra.get('large')`).  Chunk offsets (`stco`/`co64`) are absolute file offsets, so after a rewrite
that changes the size of anything placed before `mdat`, call `fix_chunk_offsets(tree, delta)`.
"""
import struct

CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"mvex", b"moof", b"traf", b"edts", b"dinf", b"udta"}
SAMPLE_ENTRY_SKIP = {}


class Box:
    __slots__ = ("type", "payload", "children", "large", "uuid", "zero")

    def __init__(self, typ, payload=b"", children=None, large=False, uuid=None, zero=False):
        self.type = typ
        self.payload = payload
        self.children = children
        self.large = large
        self.uuid = uuid
        self.zero = zero

    def find(self, typ):
        return [c for c in (self.children or []) if c.type == typ]

    def walk(self):
        yield self
        for c in self.children or []:
            yield from c.walk()


def parse(data, start=0, end=None):
    end = len(data) if end is None else end
    out = []
    pos = start
    while pos + 8 <= end:
        size, typ = struct.unpack_from(">I4s", data, pos)
        hdr = 8
        large = zero = False
        if size == 1:
            size = struct.unpack_from(">Q", data, pos + 8)[0]
            hdr = 16
            large = True
        elif size == 0:
            size = end - pos
            zero = True
        if size < hdr or pos + size > end:
            raise ValueError("bad box %r at %d" % (typ, pos))
        uuid = None
        if typ == b"uuid":
            uuid = data[pos + hdr:pos + hdr + 16]
            hdr += 16
        body_s, body_e = pos + hdr, pos + size
        if typ in CONTAINERS:
            b = Box(typ, children=parse(data, body_s, body_e), large=large, uuid=uuid, zero=zero)
        else:
            b = Box(typ, payload=data[body_s:body_e], large=large, uuid=uuid, zero=zero)
        out.append(b)
        pos += size
    return out


def serialize_box(b):
    body = b"".join(serialize_box(c) for c in b.children) if b.children is not None else b.payload
    if b.uuid is not None:
        body = b.uuid + body
    if b.zero:
        return struct.pack(">I4s", 0, b.type) + body
    if b.large:
        return struct.pack(">I4sQ", 1, b.type, 16 + len(body)) + body
    return struct.pack(">I4s", 8 + len(body), b.type) + body


def serialize(tree):
    return b"".join(serialize_box(b) for b in tree)


def all_boxes(tree):
    for b in tree:
        yield from b.walk()


def fix_chunk_offsets(tree, delta):
    for b in all_boxes(tree):
        if b.type == b"stco":
            n = struct.unpack_from(">I", b.payload, 4)[0]
            vals = struct.unpack_from(">%dI" % n, b.payload, 8)
            b.payload = b.payload[:8] + struct.pack(">%dI" % n, *[v + delta for v in vals])
        elif b.type == b"co64":
            n = struct.unpack_from(">I", b.payload, 4)[0]
            vals = struct.unpack_from(">%dQ" % n, b.payload, 8)
            b.payload = b.payload[:8] + struct.pack(">%dQ" % n, *[v + delta for v in vals])


def moov_before_mdat(tree):
    types = [b.type for b in tree]
    return b"moov" in types and b"mdat" in types and types.index(b"moov") < types.index(b"mdat")


def mdat_payload_start(tree):
    pos = 0
    for b in tree:
        if b.type == b"mdat":
            return pos + (16 if b.large else 8)
        pos += len(serialize_box(b))
    return None


def rewrite(data, fn):
    """Apply `fn(tree)` and keep chunk offsets valid (single-mdat files). Returns new bytes."""
    tree = parse(data)
    before = mdat_payload_start(tree)
    fn(tree)
    after = mdat_payload_start(tree)
    if before is not None and after is not None and after != before:
        fix_chunk_offsets(tree, after - before)
    return serialize(tree)


# ---- individual rewrites ------------------------------------------------------------------

def stco_to_co64(tree):
    for b in all_boxes(tree):
        if b.type == b"stco":
            n = struct.unpack_from(">I", b.payload, 4)[0]
            vals = struct.unpack_from(">%dI" % n, b.payload, 8)
            b.type = b"co64"
            b.payload = b.payload[:8] + struct.pack(">%dQ" % n, *vals)


def stsz_to_stz2(tree, field):
    for b in all_boxes(tree):
        if b.type == b"stsz":
            const, n = struct.unpack_from(">II", b.payload, 4)
            if const != 0:
                continue
            sizes = struct.unpack_from(">%dI" % n, b.payload, 12)
            if max(sizes) >= (1 << field):
                continue
            hdr = b.payload[:4] + b"\0\0\0" + bytes([field]) + struct.pack(">I", n)
            if field == 16:
                tab = struct.pack(">%dH" % n, *sizes)
            elif field == 8:
                tab = bytes(sizes)
            else:
                tab = bytearray((n + 1) // 2)
                for i, s in enumerate(sizes):
                    tab[i >> 1] |= (s << 4) if i % 2 == 0 else s
                tab = bytes(tab)
            b.type = b"stz2"
            b.payload = hdr + tab


def to_v1_headers(tree):
    """mvhd/tkhd/mdhd v0 -> v1 (64-bit times/durations)."""
    for b in all_boxes(tree):
        p = b.payload
        if b.type in (b"mvhd", b"mdhd") and p[0] == 0:
            ct, mt, ts, du = struct.unpack_from(">IIII", p, 4)
            b.payload = b"\x01" + p[1:4] + struct.pack(">QQIQ", ct, mt, ts, du) + p[20:]
        elif b.type == b"tkhd" and p[0] == 0:
            ct, mt, tid, res, du = struct.unpack_from(">IIIII", p, 4)
            b.payload = b"\x01" + p[1:4] + struct.pack(">QQIIQ", ct, mt, tid, res, du) + p[24:]


def add_uuid_boxes(tree):
    u = Box(b"uuid", payload=b"redteam-uuid-box", uuid=bytes(range(16)))
    tree.insert(1, u)
    for b in tree:
        if b.type == b"moov":
            b.children.append(Box(b"uuid", payload=b"inside-moov", uuid=bytes(range(16, 32))))


def trailing_mdat_size0(tree):
    if tree[-1].type == b"mdat":
        tree[-1].zero = True


def mdat_largesize(tree):
    for b in tree:
        if b.type == b"mdat":
            b.large = True


def sidx_to_v0(tree):
    for b in tree:
        if b.type == b"sidx" and b.payload[0] == 1:
            p = b.payload
            ept, fo = struct.unpack_from(">QQ", p, 12)
            b.payload = b"\0" + p[1:12] + struct.pack(">II", ept, fo) + p[28:]


def ctts_to_v1_signed(tree):
    """Rewrite ctts v0 to v1 and subtract the first offset (negative-CTO style, no edit-list shift)."""
    for b in all_boxes(tree):
        if b.type == b"ctts" and b.payload[0] == 0:
            n = struct.unpack_from(">I", b.payload, 4)[0]
            ent = list(struct.unpack_from(">%dI" % (2 * n), b.payload, 8))
            base = ent[1]
            for i in range(n):
                ent[2 * i + 1] = (ent[2 * i + 1] - base) & 0xFFFFFFFF
            b.payload = b"\x01" + b.payload[1:8] + struct.pack(">%dI" % (2 * n), *ent)
