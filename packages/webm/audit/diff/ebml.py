"""Minimal EBML reader/writer used by the packages/webm red-team corpus and fuzz generators."""

EBML, SEGMENT, CLUSTER, CUES, SEEKHEAD, INFO, TRACKS = 0x1A45DFA3, 0x18538067, 0x1F43B675, 0x1C53BB6B, 0x114D9B74, 0x1549A966, 0x1654AE6B
TIMESTAMP, SIMPLEBLOCK, BLOCKGROUP, BLOCK, BLOCKDURATION, REFBLOCK, DISCARDPAD = 0xE7, 0xA3, 0xA0, 0xA1, 0x9B, 0xFB, 0x75A2
VOID = 0xEC
UNKNOWN8 = b"\x01\xff\xff\xff\xff\xff\xff\xff"


def read_id(d, p):
    b0 = d[p]
    if b0 == 0:
        raise ValueError("zero VINT")
    n = 1
    m = 0x80
    while not b0 & m:
        m >>= 1
        n += 1
    v = 0
    for i in range(n):
        v = (v << 8) | d[p + i]
    return v, p + n


def read_size(d, p):
    b0 = d[p]
    if b0 == 0:
        raise ValueError("zero VINT")
    n = 1
    m = 0x80
    while not b0 & m:
        m >>= 1
        n += 1
    v = b0 & (m - 1)
    for i in range(1, n):
        v = (v << 8) | d[p + i]
    if v == (1 << (7 * n)) - 1:
        return None, p + n
    return v, p + n


def enc_id(i):
    n = (i.bit_length() + 7) // 8
    return i.to_bytes(n, "big")


def enc_size(n, width=None):
    if width is None:
        width = 1
        while n >= (1 << (7 * width)) - 1:
            width += 1
    return ((1 << (7 * width)) | n).to_bytes(width, "big")


def enc_svint(v, width=None):
    if width is None:
        width = 1
        while not (-(1 << (7 * width - 1)) + 1 <= v <= (1 << (7 * width - 1)) - 1):
            width += 1
    return enc_size(v + (1 << (7 * width - 1)) - 1, width)


def elem(i, payload, size_width=None):
    return enc_id(i) + enc_size(len(payload), size_width) + payload


def uint(i, v, w=None):
    if w is None:
        w = max(1, (v.bit_length() + 7) // 8)
    return elem(i, v.to_bytes(w, "big"))


def children(d, start, end):
    """Yield (id, elem_start, payload_start, payload_end_or_None)."""
    p = start
    while p < end:
        s = p
        i, p = read_id(d, p)
        sz, p = read_size(d, p)
        if sz is None:
            yield i, s, p, None
            return
        yield i, s, p, p + sz
        p += sz


def split_file(d):
    """Return (header_bytes, [(child_id, raw_bytes)], cluster list [(ts, [(id, payload)])])."""
    out = []
    hdr = b""
    for i, s, ps, pe in children(d, 0, len(d)):
        if i == EBML:
            hdr = d[s:pe]
        elif i == SEGMENT:
            end = len(d) if pe is None else pe
            for ci, cs, cps, cpe in children(d, ps, end):
                if cpe is None:
                    raise ValueError("unknown-size segment child")
                out.append((ci, d[cs:cpe], d[cps:cpe]))
            break
    return hdr, out


def block_header(payload):
    tr, p = read_size(payload, 0)
    rel = int.from_bytes(payload[p:p + 2], "big", signed=True)
    flags = payload[p + 2]
    return tr, rel, flags, p + 3
