#!/usr/bin/env python3
"""Zero-dependency MessagePack corpus generator for packages/msgpack benchmarks.

Generates:
  1. rpc_2000.msgpack   -- 2,000 nested RPC/Telemetry records (for 40x = 80k ops decode)
  2. large_16m.msgpack  -- ~16 MiB large bin + str + array payload (for 4x = ~64 MiB decode)
"""

import struct
import sys


def pack_nil() -> bytes:
    return b"\xc0"


def pack_bool(v: bool) -> bytes:
    return b"\xc3" if v else b"\xc2"


def pack_int(v: int) -> bytes:
    if v >= 0:
        if v <= 0x7F:
            return bytes([v])
        if v <= 0xFF:
            return b"\xcc" + struct.pack(">B", v)
        if v <= 0xFFFF:
            return b"\xcd" + struct.pack(">H", v)
        if v <= 0xFFFFFFFF:
            return b"\xce" + struct.pack(">I", v)
        return b"\xcf" + struct.pack(">Q", v)
    else:
        if v >= -32:
            return struct.pack(">b", v)
        if v >= -128:
            return b"\xd0" + struct.pack(">b", v)
        if v >= -32768:
            return b"\xd1" + struct.pack(">h", v)
        if v >= -2147483648:
            return b"\xd2" + struct.pack(">i", v)
        return b"\xd3" + struct.pack(">q", v)


def pack_f64(v: float) -> bytes:
    return b"\xcb" + struct.pack(">d", v)


def pack_str(s: str) -> bytes:
    b = s.encode("utf-8")
    n = len(b)
    if n <= 31:
        return bytes([0xA0 | n]) + b
    if n <= 0xFF:
        return b"\xd9" + struct.pack(">B", n) + b
    if n <= 0xFFFF:
        return b"\xda" + struct.pack(">H", n) + b
    return b"\xdb" + struct.pack(">I", n) + b


def pack_bin(b: bytes) -> bytes:
    n = len(b)
    if n <= 0xFF:
        return b"\xc4" + struct.pack(">B", n) + b
    if n <= 0xFFFF:
        return b"\xc5" + struct.pack(">H", n) + b
    return b"\xc6" + struct.pack(">I", n) + b


def pack_array_head(n: int) -> bytes:
    if n <= 15:
        return bytes([0x90 | n])
    if n <= 0xFFFF:
        return b"\xdc" + struct.pack(">H", n)
    return b"\xdd" + struct.pack(">I", n)


def pack_map_head(n: int) -> bytes:
    if n <= 15:
        return bytes([0x80 | n])
    if n <= 0xFFFF:
        return b"\xde" + struct.pack(">H", n)
    return b"\xdf" + struct.pack(">I", n)


def pack_timestamp(sec: int, nsec: int) -> bytes:
    if sec >= 0 and (sec >> 34) == 0:
        if nsec == 0 and (sec >> 32) == 0:
            return b"\xd6\xff" + struct.pack(">I", sec)
        data64 = (nsec << 34) | sec
        return b"\xd7\xff" + struct.pack(">Q", data64)
    return b"\xc7\x0c\xff" + struct.pack(">Iq", nsec, sec)


def build_rpc_corpus(count: int) -> bytes:
    parts = [pack_array_head(count)]
    regions = ["ap-northeast-1", "us-east-1", "eu-west-1", "us-west-2"]
    for i in range(count):
        payload = bytes([(i + j * 13) & 0xFF for j in range(24)])
        # Sorted keys for deterministic canonical representation
        rec = b"".join([
            pack_map_head(9),
            pack_str("delta"), pack_int(-(i * 17 + 1)),
            pack_str("id"), pack_int(1000000 + i),
            pack_str("latency_ms"), pack_f64(1.25 + (i % 97) * 0.25),
            pack_str("meta"), b"".join([
                pack_map_head(3),
                pack_str("err"), pack_nil(),
                pack_str("region"), pack_str(regions[i % 4]),
                pack_str("retries"), pack_int(i % 4),
            ]),
            pack_str("ok"), pack_bool((i % 5) != 0),
            pack_str("payload"), pack_bin(payload),
            pack_str("svc"), pack_str(f"edge-gw-{i % 16}"),
            pack_str("tags"), b"".join([
                pack_array_head(4),
                pack_str("prod"),
                pack_str("telemetry"),
                pack_str("v2"),
                pack_str("grpc"),
            ]),
            pack_str("ts"), pack_timestamp(1700000000 + i, (i * 123457) % 1000000000),
        ])
        parts.append(rec)
    return b"".join(parts)


def build_large_corpus(chunks: int = 64) -> bytes:
    # 64 chunks * (~200 KiB bin + ~50 KiB UTF-8 str + 1024-elem array) ~= 16 MiB
    parts = [pack_array_head(chunks)]
    str_unit = "telemetry-log-entry-αβγ-汉字-ok|" # 34 bytes UTF-8
    base_str = (str_unit * 1500)[:49152] # ~48 KiB valid UTF-8
    # Make sure we don't slice mid-UTF-8 char: repeat ASCII-terminated unit 1445 times = 49130 bytes
    base_str = str_unit * 1445
    base_bin = bytes([(k * 31 + 7) & 0xFF for k in range(196608)]) # 192 KiB
    for i in range(chunks):
        # Slightly vary first byte of bin so each chunk is distinct
        b = bytes([i & 0xFF]) + base_bin[1:]
        arr = [pack_array_head(1024)]
        for j in range(1024):
            arr.append(pack_int(i * 1024 + j))
        rec = b"".join([
            pack_map_head(4),
            pack_str("bin"), pack_bin(b),
            pack_str("id"), pack_int(i),
            pack_str("nums"), b"".join(arr),
            pack_str("text"), pack_str(base_str),
        ])
        parts.append(rec)
    return b"".join(parts)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: gen_corpus.py <rpc|large> <output_path> [count]", file=sys.stderr)
        return 1
    kind = sys.argv[1]
    out_path = sys.argv[2]
    if kind == "rpc":
        count = int(sys.argv[3]) if len(sys.argv) > 3 else 2000
        data = build_rpc_corpus(count)
    elif kind == "large":
        count = int(sys.argv[3]) if len(sys.argv) > 3 else 64
        data = build_large_corpus(count)
    else:
        print(f"unknown kind: {kind}", file=sys.stderr)
        return 1
    with open(out_path, "wb") as f:
        f.write(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
