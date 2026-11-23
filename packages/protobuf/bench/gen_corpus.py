#!/usr/bin/env python3
"""Generate deterministic OTel/RPC Span binary corpus (length-prefixed protobuf messages)."""

import struct
import sys


def encode_varint(val: int) -> bytes:
    val &= 0xFFFFFFFFFFFFFFFF
    out = bytearray()
    while val >= 0x80:
        out.append((val & 0x7F) | 0x80)
        val >>= 7
    out.append(val)
    return bytes(out)


def encode_tag(field_num: int, wire_type: int) -> bytes:
    return encode_varint((field_num << 3) | wire_type)


def encode_bytes_field(field_num: int, data: bytes) -> bytes:
    if not data:
        return b""
    return encode_tag(field_num, 2) + encode_varint(len(data)) + data


def encode_string_field(field_num: int, s: str) -> bytes:
    if not s:
        return b""
    b = s.encode("utf-8")
    return encode_tag(field_num, 2) + encode_varint(len(b)) + b


def encode_varint_field(field_num: int, v: int) -> bytes:
    if v == 0:
        return b""
    return encode_tag(field_num, 0) + encode_varint(v)


def encode_kv(key: str, str_val: str, int_val: int) -> bytes:
    return (
        encode_string_field(1, key)
        + encode_string_field(2, str_val)
        + encode_varint_field(3, int_val)
    )


def encode_event(ts: int, name: str, dropped: int) -> bytes:
    return (
        encode_varint_field(1, ts)
        + encode_string_field(2, name)
        + encode_varint_field(3, dropped)
    )


SPAN_NAMES = [
    "grpc.order.CreateOrder",
    "grpc.payment.Authorize",
    "http.GET /api/v1/inventory",
    "db.postgres.SELECT orders",
    "redis.HGET session:meta",
    "kafka.produce order-events",
    "auth.VerifyJwtToken",
    "cache.LookupUserProfile",
]

SERVICES = ["checkout-svc", "payment-svc", "inventory-svc", "gateway-edge"]
REGIONS = ["ap-northeast-1", "us-west-2", "eu-central-1", "ap-southeast-1"]


def build_span(idx: int) -> bytes:
    trace_id = bytes(((idx * 31 + j * 17) & 0xFF) for j in range(16))
    span_id = bytes(((idx * 13 + j * 29 + 7) & 0xFF) for j in range(8))
    name = SPAN_NAMES[idx % len(SPAN_NAMES)]
    kind = (idx % 5) + 1
    start_ns = 1700000000000000000 + idx * 125000
    end_ns = start_ns + 45000 + (idx % 997) * 100

    attrs = [
        encode_kv("service.name", SERVICES[idx % len(SERVICES)], 0),
        encode_kv("cloud.region", REGIONS[idx % len(REGIONS)], 0),
        encode_kv("http.status_code", "", 200 if (idx % 17) != 0 else 503),
        encode_kv("rpc.retry_count", "", idx % 4),
    ]
    events = [
        encode_event(start_ns + 5000, "request.received", 0),
        encode_event(end_ns - 2000, "response.flushed", idx % 3),
    ]
    status_code = 1 if (idx % 17) != 0 else 2
    status_msg = "" if status_code == 1 else "upstream deadline exceeded"

    buf = bytearray()
    buf += encode_bytes_field(1, trace_id)
    buf += encode_bytes_field(2, span_id)
    buf += encode_string_field(3, name)
    buf += encode_varint_field(4, kind)
    buf += encode_varint_field(5, start_ns)
    buf += encode_varint_field(6, end_ns)
    for a in attrs:
        buf += encode_bytes_field(7, a)
    for ev in events:
        buf += encode_bytes_field(8, ev)
    buf += encode_varint_field(9, status_code)
    buf += encode_string_field(10, status_msg)
    return bytes(buf)


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write("usage: gen_corpus.py <out.pb> <count>\n")
        return 1
    out_path = sys.argv[1]
    count = int(sys.argv[2])
    with open(out_path, "wb") as f:
        for i in range(count):
            msg = build_span(i)
            f.write(struct.pack("<I", len(msg)))
            f.write(msg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
