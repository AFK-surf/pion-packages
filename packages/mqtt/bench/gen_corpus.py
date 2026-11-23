#!/usr/bin/env python3
"""Deterministic MQTT 5.0 (all 15 packet types) and MQTT 3.1.1 (all 14 packet types)
corpus generator for packages/mqtt head-to-head benchmarks."""

import os
import struct
import sys


def encode_vbi(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n > 0:
            b |= 0x80
        out.append(b)
        if n == 0:
            break
    return bytes(out)


def mqtt_str(s: str) -> bytes:
    b = s.encode("utf-8")
    return struct.pack("!H", len(b)) + b


def mqtt_bin(b: bytes) -> bytes:
    return struct.pack("!H", len(b)) + b


def wrap(hdr: int, body: bytes) -> bytes:
    return bytes([hdr]) + encode_vbi(len(body)) + body


def build_v5(count: int, include_auth: bool = True) -> bytes:
    out = bytearray()
    mod = 15 if include_auth else 14
    for i in range(count):
        kind = i % mod
        pid = (i % 65000) + 1
        if kind == 0:
            # CONNECT v5
            props = b"\x11" + struct.pack("!I", 3600) + b"\x21" + struct.pack("!H", 32)
            body = (
                mqtt_str("MQTT")
                + bytes([5, 0x02])
                + struct.pack("!H", 60)
                + encode_vbi(len(props))
                + props
                + mqtt_str(f"cli-v5-{i}")
            )
            out.extend(wrap(0x10, body))
        elif kind == 1:
            # CONNACK v5
            props = b"\x21" + struct.pack("!H", 64) + b"\x22" + struct.pack("!H", 16)
            body = bytes([0x01, 0x00]) + encode_vbi(len(props)) + props
            out.extend(wrap(0x20, body))
        elif kind == 2:
            # PUBLISH v5 QoS 1 with properties
            props = (
                b"\x02"
                + struct.pack("!I", 120)
                + b"\x03"
                + mqtt_str("application/json")
                + b"\x26"
                + mqtt_str("region")
                + mqtt_str("ap-northeast-1")
            )
            topic = f"factory/zone{i % 4}/dev{i % 16}/telemetry"
            payload = f'{{"seq":{i},"temp":23.5,"ok":true}}'.encode("utf-8")
            body = (
                mqtt_str(topic)
                + struct.pack("!H", pid)
                + encode_vbi(len(props))
                + props
                + payload
            )
            out.extend(wrap(0x32, body))
        elif kind == 3:
            # PUBACK v5
            out.extend(wrap(0x40, struct.pack("!H", pid) + bytes([0x00, 0x00])))
        elif kind == 4:
            # PUBREC v5
            out.extend(wrap(0x50, struct.pack("!H", pid) + bytes([0x00, 0x00])))
        elif kind == 5:
            # PUBREL v5
            out.extend(wrap(0x62, struct.pack("!H", pid) + bytes([0x00, 0x00])))
        elif kind == 6:
            # PUBCOMP v5
            out.extend(wrap(0x70, struct.pack("!H", pid) + bytes([0x00, 0x00])))
        elif kind == 7:
            # SUBSCRIBE v5
            body = (
                struct.pack("!H", pid)
                + bytes([0x00])
                + mqtt_str(f"factory/zone{i % 4}/+/telemetry")
                + bytes([0x01])
            )
            out.extend(wrap(0x82, body))
        elif kind == 8:
            # SUBACK v5
            body = struct.pack("!H", pid) + bytes([0x00, 0x01])
            out.extend(wrap(0x90, body))
        elif kind == 9:
            # UNSUBSCRIBE v5
            body = (
                struct.pack("!H", pid)
                + bytes([0x00])
                + mqtt_str(f"factory/zone{i % 4}/+/telemetry")
            )
            out.extend(wrap(0xA2, body))
        elif kind == 10:
            # UNSUBACK v5
            body = struct.pack("!H", pid) + bytes([0x00, 0x00])
            out.extend(wrap(0xB0, body))
        elif kind == 11:
            # PINGREQ
            out.extend(b"\xC0\x00")
        elif kind == 12:
            # PINGRESP
            out.extend(b"\xD0\x00")
        elif kind == 13:
            # DISCONNECT v5
            props = b"\x11" + struct.pack("!I", 0)
            body = bytes([0x00]) + encode_vbi(len(props)) + props
            out.extend(wrap(0xE0, body))
        else:
            # AUTH v5
            props = b"\x15" + mqtt_str("SCRAM-SHA-256") + b"\x16" + mqtt_bin(b"nonce-1")
            body = bytes([0x18]) + encode_vbi(len(props)) + props
            out.extend(wrap(0xF0, body))
    return bytes(out)


def build_v311_all14(count: int) -> bytes:
    out = bytearray()
    for i in range(count):
        kind = i % 14
        pid = (i % 65000) + 1
        if kind == 0:
            # CONNECT v3.1.1
            body = (
                mqtt_str("MQTT")
                + bytes([4, 0x02])
                + struct.pack("!H", 60)
                + mqtt_str(f"cli-v4-{i}")
            )
            out.extend(wrap(0x10, body))
        elif kind == 1:
            # CONNACK v3.1.1
            out.extend(wrap(0x20, bytes([0x01, 0x00])))
        elif kind == 2:
            # PUBLISH v3.1.1 QoS 1
            topic = f"iot/v4/zone{i % 4}/dev{i % 16}"
            payload = f'{{"seq":{i},"v":4}}'.encode("utf-8")
            body = mqtt_str(topic) + struct.pack("!H", pid) + payload
            out.extend(wrap(0x32, body))
        elif kind == 3:
            out.extend(wrap(0x40, struct.pack("!H", pid)))
        elif kind == 4:
            out.extend(wrap(0x50, struct.pack("!H", pid)))
        elif kind == 5:
            out.extend(wrap(0x62, struct.pack("!H", pid)))
        elif kind == 6:
            out.extend(wrap(0x70, struct.pack("!H", pid)))
        elif kind == 7:
            body = (
                struct.pack("!H", pid)
                + mqtt_str(f"iot/v4/zone{i % 4}/+")
                + bytes([0x01])
            )
            out.extend(wrap(0x82, body))
        elif kind == 8:
            out.extend(wrap(0x90, struct.pack("!H", pid) + bytes([0x01])))
        elif kind == 9:
            body = struct.pack("!H", pid) + mqtt_str(f"iot/v4/zone{i % 4}/+")
            out.extend(wrap(0xA2, body))
        elif kind == 10:
            out.extend(wrap(0xB0, struct.pack("!H", pid)))
        elif kind == 11:
            out.extend(b"\xC0\x00")
        elif kind == 12:
            out.extend(b"\xD0\x00")
        else:
            out.extend(b"\xE0\x00")
    return bytes(out)


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: gen_corpus.py <out_dir>", file=sys.stderr)
        sys.exit(1)
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    v5_all15 = build_v5(500, include_auth=True)
    v5_14 = build_v5(500, include_auth=False)
    v311_bytes = build_v311_all14(500)
    with open(os.path.join(out_dir, "v5_all15.bin"), "wb") as f:
        f.write(v5_all15)
    with open(os.path.join(out_dir, "v5_14.bin"), "wb") as f:
        f.write(v5_14)
    with open(os.path.join(out_dir, "v311_all14.bin"), "wb") as f:
        f.write(v311_bytes)
    print(f"generated v5_all15.bin ({len(v5_all15)}B), v5_14.bin ({len(v5_14)}B), v311_all14.bin ({len(v311_bytes)}B)")


if __name__ == "__main__":
    main()
