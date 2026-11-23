#!/usr/bin/env python3
"""Deterministic RFC 9113 single-frame corpus (Pion decode_frame vs Go x/net/http2 Framer.ReadFrame).

Each line: `<name>\t<hex of one wire frame>` (max_frame_size = 16384 on both sides).
Families: valid frames of every type with every flag combination that matters, then boundary
attacks (PADDED with pad_len = len-1/len/len+1, PADDED with empty payload, PADDED+PRIORITY sizes,
stream id 0 / reserved bit, fixed-length frames +-1, SETTINGS values on both sides of each limit,
WINDOW_UPDATE 0 / 2^31-1 / reserved bit, oversize frames), then 3,000 random mutations.
"""
import random
import struct
import sys


def fr(t, flags, sid, payload, length=None):
    L = len(payload) if length is None else length
    return struct.pack(">I", L)[1:] + bytes([t, flags]) + struct.pack(">I", sid) + payload


def main():
    r = random.Random(0x46524D53)
    cases = []
    add = lambda n, b: cases.append((n, b))
    blk = bytes.fromhex("828684418aa0e41d139d09b8f01e07")  # C.4.1 request
    # DATA
    for flags in [0, 1, 8, 9]:
        for pad in [0, 1, 5, 255]:
            body = b"hello"
            p = (bytes([pad]) + body + b"\0" * pad) if flags & 8 else body
            add(f"data_f{flags}_p{pad}", fr(0, flags, 1, p))
    add("data_sid0", fr(0, 0, 0, b"x"))
    add("data_padded_empty", fr(0, 8, 1, b""))
    for L in [1, 2, 6]:
        add(f"data_pad_eq_len_{L}", fr(0, 8, 1, bytes([L]) + b"\0" * (L - 1)))
        add(f"data_pad_lenm1_{L}", fr(0, 8, 1, bytes([L - 1]) + b"\0" * (L - 1)))
    add("data_reserved_bit_sid", fr(0, 0, 0x80000001, b"x"))
    add("data_unknown_flags", fr(0, 0xF6, 1, b"x"))
    # HEADERS
    for flags in [0x4, 0x5, 0x0, 0x1, 0x24, 0x2C, 0x0C, 0x08, 0x20]:
        p = blk
        if flags & 0x20:
            p = struct.pack(">I", 0x80000003) + b"\x0f" + p
        if flags & 0x08:
            p = b"\x03" + p + b"\0\0\0"
        add(f"headers_f{flags:x}", fr(1, flags, 1, p))
    add("headers_sid0", fr(1, 4, 0, blk))
    add("headers_prio_short", fr(1, 0x24, 1, b"\0\0\0"))
    add("headers_prio_exact5", fr(1, 0x24, 1, b"\0\0\0\0\x10"))
    add("headers_padded_prio_overflow", fr(1, 0x2C, 1, b"\x03" + b"\0\0\0\0\x10" + b"\x82"))
    add("headers_padded_prio_exact", fr(1, 0x2C, 1, b"\x01" + b"\0\0\0\0\x10" + b"\0"))
    add("headers_padded_empty", fr(1, 0x0C, 1, b""))
    add("headers_pad_eq_rest", fr(1, 0x0C, 1, b"\x02\0\0"))
    add("headers_pad_gt_rest", fr(1, 0x0C, 1, b"\x03\0\0"))
    add("headers_self_dep", fr(1, 0x24, 3, struct.pack(">I", 3) + b"\x10" + blk))
    # PRIORITY
    for L in [4, 5, 6]:
        add(f"priority_len{L}", fr(2, 0, 1, (struct.pack(">I", 3) + b"\x20\x00")[:L]))
    add("priority_sid0", fr(2, 0, 0, struct.pack(">I", 3) + b"\x20"))
    add("priority_self", fr(2, 0, 5, struct.pack(">I", 5) + b"\x20"))
    add("priority_excl", fr(2, 0, 5, struct.pack(">I", 0x80000001) + b"\xff"))
    # RST_STREAM
    for L in [3, 4, 5]:
        add(f"rst_len{L}", fr(3, 0, 1, (b"\0\0\0\x08\0")[:L]))
    add("rst_sid0", fr(3, 0, 0, b"\0\0\0\x08"))
    add("rst_code_max", fr(3, 0, 1, b"\xff\xff\xff\xff"))
    # SETTINGS
    S = lambda i, v: struct.pack(">HI", i, v)
    add("settings_empty", fr(4, 0, 0, b""))
    add("settings_ack", fr(4, 1, 0, b""))
    add("settings_ack_payload", fr(4, 1, 0, S(1, 0)))
    add("settings_sid1", fr(4, 0, 1, S(1, 0)))
    add("settings_len5", fr(4, 0, 0, S(1, 0)[:5]))
    add("settings_len7", fr(4, 0, 0, S(1, 0) + b"\0"))
    for v in [0, 1, 2, 0xFFFFFFFF]:
        add(f"settings_enable_push_{v}", fr(4, 0, 0, S(2, v)))
    for v in [0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0]:
        add(f"settings_iws_{v}", fr(4, 0, 0, S(4, v)))
    for v in [16383, 16384, 16777215, 16777216, 0]:
        add(f"settings_mfs_{v}", fr(4, 0, 0, S(5, v)))
    add("settings_unknown_id", fr(4, 0, 0, S(0xFFFF, 7) + S(0, 1) + S(7, 9)))
    add("settings_dup", fr(4, 0, 0, S(4, 1) + S(4, 2) + S(1, 0) + S(1, 4096)))
    add("settings_header_table_huge", fr(4, 0, 0, S(1, 0xFFFFFFFF)))
    add("settings_mcs_0", fr(4, 0, 0, S(3, 0)))
    add("settings_ecp_2", fr(4, 0, 0, S(8, 2)))
    # PUSH_PROMISE
    add("push_ok", fr(5, 4, 1, struct.pack(">I", 2) + blk))
    add("push_padded", fr(5, 0xC, 1, b"\x02" + struct.pack(">I", 2) + blk + b"\0\0"))
    add("push_sid0", fr(5, 4, 0, struct.pack(">I", 2) + blk))
    add("push_prom0", fr(5, 4, 1, struct.pack(">I", 0) + blk))
    add("push_short", fr(5, 4, 1, b"\0\0\0"))
    add("push_padded_overflow", fr(5, 0xC, 1, b"\x09" + struct.pack(">I", 2) + b"\x82"))
    add("push_padded_empty", fr(5, 0xC, 1, b""))
    # PING
    for L in [7, 8, 9]:
        add(f"ping_len{L}", fr(6, 0, 0, b"\x01" * L))
    add("ping_ack", fr(6, 1, 0, b"\x02" * 8))
    add("ping_sid1", fr(6, 0, 1, b"\x01" * 8))
    # GOAWAY
    for L in [7, 8, 20]:
        add(f"goaway_len{L}", fr(7, 0, 0, (struct.pack(">II", 5, 2) + b"debug-data-xx")[:L]))
    add("goaway_sid1", fr(7, 0, 1, struct.pack(">II", 5, 0)))
    add("goaway_reserved_last", fr(7, 0, 0, struct.pack(">II", 0xFFFFFFFF, 0)))
    # WINDOW_UPDATE
    for inc in [0, 1, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF]:
        add(f"wu_conn_{inc:x}", fr(8, 0, 0, struct.pack(">I", inc)))
        add(f"wu_stream_{inc:x}", fr(8, 0, 1, struct.pack(">I", inc)))
    for L in [3, 5]:
        add(f"wu_len{L}", fr(8, 0, 0, (struct.pack(">I", 1) + b"\0")[:L]))
    # CONTINUATION (frame-level only; ordering is a connection concern)
    add("cont_sid0", fr(9, 4, 0, blk))
    add("cont_ok", fr(9, 4, 1, blk))
    # unknown / extension
    add("unknown_type_0a", fr(0x0A, 0xFF, 5, b"abc"))
    add("unknown_type_ff_sid0", fr(0xFF, 0, 0, b""))
    # sizes
    add("oversize_16385", fr(0, 0, 1, b"\0" * 16385))
    add("exact_16384", fr(0, 0, 1, b"\0" * 16384))
    add("oversize_header_only", fr(0, 0, 1, b"", length=0xFFFFFF))
    add("truncated_header", fr(0, 0, 1, b"abc")[:7])
    add("truncated_payload", fr(0, 0, 1, b"abcdef")[:12])

    seeds = [b for _, b in cases if len(b) < 2000]
    for i in range(3000):
        b = bytearray(r.choice(seeds))
        for _ in range(r.randint(1, 3)):
            op = r.randrange(6)
            if op == 0:  # flags
                b[4] = r.choice([0, 1, 4, 5, 8, 9, 0x20, 0x24, 0x28, 0x2C, 0x0C, r.randrange(256)])
            elif op == 1:  # type
                b[3] = r.randrange(11)
            elif op == 2:  # stream id
                sid = r.choice([0, 1, 2, 3, 0x7FFFFFFF, 0x80000000, r.randrange(1 << 32)])
                b[5:9] = struct.pack(">I", sid)
            elif op == 3 and len(b) > 9:  # payload byte
                j = r.randrange(9, len(b))
                b[j] = r.randrange(256)
            elif op == 4:  # length field vs actual payload
                n = len(b) - 9 + r.choice([-2, -1, 0, 0, 1])
                n = max(0, n)
                b[0:3] = struct.pack(">I", n)[1:]
                b = b[: 9 + n] if 9 + n <= len(b) else b + b"\0" * (9 + n - len(b))
            else:  # truncate/extend payload consistently
                n = r.randrange(0, max(1, len(b) - 9 + 3))
                b = b[:9] + (bytes(b[9:]) + b"\0" * 3)[:n]
                b[0:3] = struct.pack(">I", n)[1:]
        cases.append((f"mut_{i}", bytes(b)))

    with open(sys.argv[1], "w") as f:
        for n, b in cases:
            f.write(n + "\t" + b.hex() + "\n")
    print(f"{len(cases)} cases -> {sys.argv[1]}")


if __name__ == "__main__":
    main()
