#!/usr/bin/env python3
"""Deterministic HTTP/2 + HPACK benchmark corpus generator for packages/http2.

Generates in <out_dir>:
  - headers_plain.bin : 1,000 realistic HTTP/2 request/response header lists
  - hpack_stream.bin  : 1,000 RFC 7541 HPACK-encoded blocks (Huffman + dynamic table)
  - frame_stream.bin  : 2,000 mixed RFC 9113 HTTP/2 frames (SETTINGS/HEADERS/CONTINUATION/DATA/WINDOW_UPDATE/PING/PRIORITY/RST_STREAM)
"""

import os
import struct
import sys

HUFF_CODES = [
    0x1ff8, 0x7fffd8, 0xfffffe2, 0xfffffe3, 0xfffffe4, 0xfffffe5, 0xfffffe6, 0xfffffe7,
    0xfffffe8, 0xffffea, 0x3ffffffc, 0xfffffe9, 0xfffffea, 0x3ffffffd, 0xfffffeb, 0xfffffec,
    0xfffffed, 0xfffffee, 0xfffffef, 0xffffff0, 0xffffff1, 0xffffff2, 0x3ffffffe, 0xffffff3,
    0xffffff4, 0xffffff5, 0xffffff6, 0xffffff7, 0xffffff8, 0xffffff9, 0xffffffa, 0xffffffb,
    0x14, 0x3f8, 0x3f9, 0xffa, 0x1ff9, 0x15, 0xf8, 0x7fa, 0x3fa, 0x3fb, 0xf9, 0x7fb, 0xfa,
    0x16, 0x17, 0x18, 0x0, 0x1, 0x2, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x5c, 0xfb,
    0x7ffc, 0x20, 0xffb, 0x3fc, 0x1ffa, 0x21, 0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63, 0x64,
    0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0xfc,
    0x73, 0xfd, 0x1ffb, 0x7fff0, 0x1ffc, 0x3ffc, 0x22, 0x7ffd, 0x3, 0x23, 0x4, 0x24, 0x5, 0x25,
    0x26, 0x27, 0x6, 0x74, 0x75, 0x28, 0x29, 0x2a, 0x7, 0x2b, 0x76, 0x2c, 0x8, 0x9, 0x2d,
    0x77, 0x78, 0x79, 0x7a, 0x7b, 0x7ffe, 0x7fc, 0x3ffd, 0x1ffd, 0xffffffc,
] + [0] * 128

HUFF_LENS = [
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28,
    28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28,
    6, 10, 10, 12, 13, 6, 8, 11, 10, 10, 8, 11, 8, 6, 6, 6,
    5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 8, 15, 6, 12, 10,
    13, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14, 6,
    15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5,
    6, 7, 6, 5, 5, 6, 7, 7, 7, 7, 7, 15, 11, 14, 13, 28,
] + [28] * 128

STATIC_TABLE = [
    ("", ""),
    (":authority", ""), (":method", "GET"), (":method", "POST"),
    (":path", "/"), (":path", "/index.html"), (":scheme", "http"), (":scheme", "https"),
    (":status", "200"), (":status", "204"), (":status", "206"), (":status", "304"),
    (":status", "400"), (":status", "404"), (":status", "500"),
    ("accept-charset", ""), ("accept-encoding", "gzip, deflate"), ("accept-language", ""),
    ("accept-ranges", ""), ("accept", ""), ("access-control-allow-origin", ""),
    ("age", ""), ("allow", ""), ("authorization", ""), ("cache-control", ""),
    ("content-disposition", ""), ("content-encoding", ""), ("content-language", ""),
    ("content-length", ""), ("content-location", ""), ("content-range", ""),
    ("content-type", ""), ("cookie", ""), ("date", ""), ("etag", ""), ("expect", ""),
    ("expires", ""), ("from", ""), ("host", ""), ("if-match", ""),
    ("if-modified-since", ""), ("if-none-match", ""), ("if-range", ""),
    ("if-unmodified-since", ""), ("last-modified", ""), ("link", ""), ("location", ""),
    ("max-forwards", ""), ("proxy-authenticate", ""), ("proxy-authorization", ""),
    ("range", ""), ("referer", ""), ("refresh", ""), ("retry-after", ""),
    ("server", ""), ("set-cookie", ""), ("strict-transport-security", ""),
    ("transfer-encoding", ""), ("user-agent", ""), ("vary", ""), ("via", ""),
    ("www-authenticate", ""),
]


def huff_encode(raw: bytes) -> bytes:
    acc = 0
    nbits = 0
    out = bytearray()
    for b in raw:
        l = HUFF_LENS[b]
        acc = (acc << l) | HUFF_CODES[b]
        nbits += l
        while nbits >= 8:
            nbits -= 8
            out.append((acc >> nbits) & 0xFF)
    if nbits > 0:
        pad = 8 - nbits
        out.append(((acc << pad) | ((1 << pad) - 1)) & 0xFF)
    return bytes(out)


def enc_int(val: int, prefix_bits: int, mask: int) -> bytes:
    max_p = (1 << prefix_bits) - 1
    if val < max_p:
        return bytes([mask | val])
    out = bytearray([mask | max_p])
    v = val - max_p
    while v >= 128:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return bytes(out)


def enc_str(s: str, use_huff: bool = True) -> bytes:
    raw = s.encode("ascii")
    if use_huff and len(raw) > 0:
        h = huff_encode(raw)
        if len(h) < len(raw):
            return enc_int(len(h), 7, 0x80) + h
    return enc_int(len(raw), 7, 0x00) + raw


class PyHpackEncoder:
    def __init__(self, max_size: int = 4096):
        self.max_size = max_size
        self.dyn = []
        self.cur_size = 0

    def _insert(self, name: str, value: str):
        esize = len(name) + len(value) + 32
        if esize > self.max_size:
            self.dyn.clear()
            self.cur_size = 0
            return
        while self.dyn and self.cur_size + esize > self.max_size:
            on, ov = self.dyn.pop()
            self.cur_size -= len(on) + len(ov) + 32
        self.dyn.insert(0, (name, value))
        self.cur_size += esize

    def encode(self, headers):
        out = bytearray()
        for name, value, sensitive in headers:
            s_idx = 0
            s_exact = False
            for idx in range(1, len(STATIC_TABLE)):
                sn, sv = STATIC_TABLE[idx]
                if sn == name:
                    if sv == value:
                        s_idx = idx
                        s_exact = True
                        break
                    if s_idx == 0:
                        s_idx = idx
            if sensitive:
                n_idx = s_idx
                if n_idx == 0:
                    for di, (dn, _) in enumerate(self.dyn):
                        if dn == name:
                            n_idx = 62 + di
                            break
                if n_idx > 0:
                    out.extend(enc_int(n_idx, 4, 0x10))
                else:
                    out.append(0x10)
                    out.extend(enc_str(name))
                out.extend(enc_str(value))
            elif s_exact:
                out.extend(enc_int(s_idx, 7, 0x80))
            else:
                d_idx = 0
                d_exact = False
                for di, (dn, dv) in enumerate(self.dyn):
                    if dn == name:
                        if dv == value:
                            d_idx = 62 + di
                            d_exact = True
                            break
                        if d_idx == 0:
                            d_idx = 62 + di
                if d_exact:
                    out.extend(enc_int(d_idx, 7, 0x80))
                else:
                    n_idx = s_idx if s_idx > 0 else d_idx
                    if n_idx > 0:
                        out.extend(enc_int(n_idx, 6, 0x40))
                    else:
                        out.append(0x40)
                        out.extend(enc_str(name))
                    out.extend(enc_str(value))
                    self._insert(name, value)
        return bytes(out)


def make_frame(ftype: int, flags: int, sid: int, payload: bytes) -> bytes:
    plen = len(payload)
    hdr = bytes([
        (plen >> 16) & 0xFF, (plen >> 8) & 0xFF, plen & 0xFF,
        ftype & 0xFF, flags & 0xFF,
        (sid >> 24) & 0x7F, (sid >> 16) & 0xFF, (sid >> 8) & 0xFF, sid & 0xFF,
    ])
    return hdr + payload


def build_header_lists(count: int = 1000):
    authorities = [
        "api.example.com", "cdn.example.com", "static.pion.dev", "edge.cloud.internal",
    ]
    paths = [
        "/v1/items?page=1&limit=50",
        "/v1/users/profile",
        "/assets/app.bundle.20261123.js",
        "/index.html",
        "/v2/telemetry/ingest",
        "/api/search?q=http2+hpack+benchmark",
    ]
    uas = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
        "pion-http2-client/0.1.0 (arm64; darwin)",
    ]
    lists = []
    for i in range(count):
        if i % 2 == 0:
            # Request
            method = "GET" if (i % 4 == 0) else "POST"
            hs = [
                (":method", method, False),
                (":scheme", "https", False),
                (":authority", authorities[i % len(authorities)], False),
                (":path", paths[i % len(paths)], False),
                ("user-agent", uas[i % len(uas)], False),
                ("accept", "application/json, text/plain, */*", False),
                ("accept-encoding", "gzip, deflate", False),
                ("cache-control", "no-cache" if (i % 3 == 0) else "max-age=60", False),
                ("x-request-id", f"req-{i:06d}-abcdef", False),
            ]
            if i % 5 == 0:
                hs.append(("authorization", f"Bearer tok-{i:06d}-secret", True))
        else:
            # Response
            status = "200" if (i % 6 != 5) else "304"
            hs = [
                (":status", status, False),
                ("content-type", "application/json; charset=utf-8", False),
                ("cache-control", "public, max-age=3600", False),
                ("date", "Mon, 23 Nov 2026 07:45:00 GMT", False),
                ("etag", f"\"v1-{i // 10:04d}-9f8e7d\"", False),
                ("server", "pion-edge/0.1", False),
                ("content-encoding", "gzip", False),
                ("x-trace-id", f"trc-{i:06d}-xyz", False),
            ]
        lists.append(hs)
    return lists


def main():
    if len(sys.argv) < 2:
        print("usage: gen_corpus.py <out_dir>", file=sys.stderr)
        sys.exit(1)
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    header_lists = build_header_lists(1000)

    # 1. headers_plain.bin
    plain_buf = bytearray()
    plain_buf.extend(struct.pack(">I", len(header_lists)))
    for hs in header_lists:
        plain_buf.extend(struct.pack(">H", len(hs)))
        for name, val, sens in hs:
            nb = name.encode("ascii")
            vb = val.encode("ascii")
            plain_buf.extend(struct.pack(">H", len(nb)))
            plain_buf.extend(nb)
            plain_buf.extend(struct.pack(">H", len(vb)))
            plain_buf.extend(vb)
            plain_buf.append(1 if sens else 0)
    with open(os.path.join(out_dir, "headers_plain.bin"), "wb") as f:
        f.write(plain_buf)

    # 2. hpack_stream.bin (1,000 HPACK blocks with dynamic table + Huffman)
    enc = PyHpackEncoder(4096)
    hpack_buf = bytearray()
    hpack_buf.extend(struct.pack(">I", len(header_lists)))
    encoded_blocks = []
    for hs in header_lists:
        blk = enc.encode(hs)
        encoded_blocks.append(blk)
        hpack_buf.extend(struct.pack(">I", len(blk)))
        hpack_buf.extend(blk)
    with open(os.path.join(out_dir, "hpack_stream.bin"), "wb") as f:
        f.write(hpack_buf)

    # 3. frame_stream.bin (2,000 mixed RFC 9113 frames: request HEADERS(+CONTINUATION), DATA, WINDOW_UPDATE, PING, PRIORITY, SETTINGS)
    f_enc = PyHpackEncoder(4096)
    frame_buf = bytearray()
    frame_count = 0

    # Initial SETTINGS
    settings_payload = struct.pack(">HIHI", 0x1, 4096, 0x3, 256)
    frame_buf.extend(make_frame(0x4, 0x00, 0, settings_payload))
    frame_count += 1

    # Generate 499 request cycles (each 4 frames = 1996 frames, plus 3 extra = 2000 frames total!)
    for i in range(499):
        sid = i * 2 + 1
        req_hs = header_lists[(i * 2) % len(header_lists)]
        blk = f_enc.encode(req_hs)
        if i % 5 == 0 and len(blk) > 16:
            # Split into HEADERS + CONTINUATION
            mid = len(blk) // 2
            frame_buf.extend(make_frame(0x1, 0x00, sid, blk[:mid]))
            frame_buf.extend(make_frame(0x9, 0x04, sid, blk[mid:]))
            body = f"payload-{i:04d}-0123456789abcdef".encode("ascii")
            frame_buf.extend(make_frame(0x0, 0x01, sid, body))
            frame_buf.extend(make_frame(0x8, 0x00, 0, struct.pack(">I", len(body))))
            frame_count += 4
        else:
            # Single HEADERS + DATA + WINDOW_UPDATE + PING/PRIORITY
            frame_buf.extend(make_frame(0x1, 0x04, sid, blk))
            body = f"data-chunk-{i:04d}-abcdefghijklmnopqrstuvwxyz".encode("ascii")
            frame_buf.extend(make_frame(0x0, 0x01, sid, body))
            frame_buf.extend(make_frame(0x8, 0x00, 0, struct.pack(">I", len(body))))
            if i % 2 == 0:
                frame_buf.extend(make_frame(0x6, 0x00, 0, struct.pack(">Q", i + 1)))
            else:
                frame_buf.extend(make_frame(0x2, 0x00, sid, struct.pack(">IB", 0, 16)))
            frame_count += 4

    # Pad to exactly 2,000 frames with 3 PING frames
    while frame_count < 2000:
        frame_buf.extend(make_frame(0x6, 0x00, 0, struct.pack(">Q", 0xCAFE0000 + frame_count)))
        frame_count += 1

    with open(os.path.join(out_dir, "frame_stream.bin"), "wb") as f:
        f.write(frame_buf)

    print(
        f"Generated corpus in {out_dir}: "
        f"headers_plain.bin={len(plain_buf)}B, "
        f"hpack_stream.bin={len(hpack_buf)}B, "
        f"frame_stream.bin={len(frame_buf)}B ({frame_count} frames)"
    )


if __name__ == "__main__":
    main()
