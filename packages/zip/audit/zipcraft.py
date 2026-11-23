"""Low-level ZIP crafting helpers for the packages/zip red-team audit (no third-party deps).

Every field of the Local File Header, Central Directory header, EOCD, ZIP64 EOCD and locator
can be overridden independently, so LFH/CD disagreements, forged sizes and offset tricks are
expressed declaratively in difftest.py.
"""

import struct
import zlib


def deflate(data, level=6):
    c = zlib.compressobj(level, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()


class Entry:
    def __init__(self, name, data, method=8, **kw):
        self.name = name if isinstance(name, bytes) else name.encode()
        self.data = data
        self.method = method
        self.payload = deflate(data) if method == 8 else data
        self.crc = zlib.crc32(data)
        self.flags = 0
        self.dd = None  # None | 'sig' | 'nosig' | 'sig64' | raw bytes
        self.lfh = {}  # overrides for LFH fields
        self.cd = {}  # overrides for CD fields
        self.lfh_extra = b""
        self.cd_extra = b""
        self.comment = b""
        self.offset_override = None
        for k, v in kw.items():
            setattr(self, k, v)


def u16(v):
    return struct.pack("<H", v & 0xFFFF)


def u32(v):
    return struct.pack("<I", v & 0xFFFFFFFF)


def u64(v):
    return struct.pack("<Q", v & 0xFFFFFFFFFFFFFFFF)


def build(entries, comment=b"", prefix=b"", adjust_prefix=False, eocd=None, zip64=None,
          cd_extra_tail=b"", gap_after_cd=b"", trailing=b""):
    """Assemble an archive.

    prefix/adjust_prefix: bytes prepended; if adjust_prefix the recorded offsets include the prefix (zip -A).
    eocd: dict overriding EOCD fields (disk, cd_disk, n_disk, n, cd_size, cd_off, comment_len).
    zip64: None or dict for ZIP64 EOCD (+locator) with optional overrides (n, cd_size, cd_off, loc_off, rec_size).
    """
    out = bytearray()
    base = len(prefix) if adjust_prefix else 0
    offsets = []
    for e in entries:
        off = len(out) + base
        offsets.append(off)
        lf = dict(
            sig=0x04034B50, ver=20, flags=e.flags, method=e.method, time=0, date=0x21,
            crc=e.crc, csize=len(e.payload), usize=len(e.data), name=e.name, extra=e.lfh_extra,
        )
        if e.flags & 8:
            lf.update(crc=0, csize=0, usize=0)
        lf.update(e.lfh)
        name = lf["name"]
        out += u32(lf["sig"]) + u16(lf["ver"]) + u16(lf["flags"]) + u16(lf["method"])
        out += u16(lf["time"]) + u16(lf["date"]) + u32(lf["crc"]) + u32(lf["csize"]) + u32(lf["usize"])
        out += u16(lf.get("name_len", len(name))) + u16(lf.get("extra_len", len(lf["extra"])))
        out += name + lf["extra"]
        out += e.payload
        if e.dd is not None:
            if e.dd == "sig":
                out += u32(0x08074B50) + u32(e.crc) + u32(len(e.payload)) + u32(len(e.data))
            elif e.dd == "nosig":
                out += u32(e.crc) + u32(len(e.payload)) + u32(len(e.data))
            elif e.dd == "sig64":
                out += u32(0x08074B50) + u32(e.crc) + u64(len(e.payload)) + u64(len(e.data))
            else:
                out += e.dd
    cd_start = len(out) + base
    cd = bytearray()
    for e, off in zip(entries, offsets):
        c = dict(
            sig=0x02014B50, made=0x0314, ver=20, flags=e.flags, method=e.method, time=0, date=0x21,
            crc=e.crc, csize=len(e.payload), usize=len(e.data), name=e.name, extra=e.cd_extra,
            comment=e.comment, disk=0, iattr=0, eattr=0o100644 << 16,
            off=off if e.offset_override is None else e.offset_override,
        )
        c.update(e.cd)
        cd += u32(c["sig"]) + u16(c["made"]) + u16(c["ver"]) + u16(c["flags"]) + u16(c["method"])
        cd += u16(c["time"]) + u16(c["date"]) + u32(c["crc"]) + u32(c["csize"]) + u32(c["usize"])
        cd += u16(len(c["name"])) + u16(len(c["extra"])) + u16(len(c["comment"]))
        cd += u16(c["disk"]) + u16(c["iattr"]) + u32(c["eattr"]) + u32(c["off"])
        cd += c["name"] + c["extra"] + c["comment"]
    cd += cd_extra_tail
    out += cd
    out += gap_after_cd
    cd_size = len(cd)
    if zip64 is not None:
        z = dict(n=len(entries), cd_size=cd_size, cd_off=cd_start, rec_size=44, loc_disk=0, total_disks=1)
        z.update(zip64)
        z64_off = len(out) + base
        if "body" in z:
            out += z["body"]
        else:
            out += u32(0x06064B50) + u64(z["rec_size"]) + u16(0x032D) + u16(45) + u32(0) + u32(0)
            out += u64(z["n"]) + u64(z["n"]) + u64(z["cd_size"]) + u64(z["cd_off"])
        out += u32(0x07064B50) + u32(z["loc_disk"]) + u64(z.get("loc_off", z64_off)) + u32(z["total_disks"])
    ed = dict(disk=0, cd_disk=0, n_disk=len(entries), n=len(entries), cd_size=cd_size, cd_off=cd_start,
              comment_len=len(comment))
    if eocd:
        ed.update(eocd)
    out += u32(0x06054B50) + u16(ed["disk"]) + u16(ed["cd_disk"]) + u16(ed["n_disk"]) + u16(ed["n"])
    out += u32(ed["cd_size"]) + u32(ed["cd_off"]) + u16(ed["comment_len"]) + comment
    out += trailing
    return bytes(prefix) + bytes(out)


def z64extra(*vals, header_id=1, raw=None):
    body = raw if raw is not None else b"".join(u64(v) for v in vals)
    return u16(header_id) + u16(len(body)) + body
