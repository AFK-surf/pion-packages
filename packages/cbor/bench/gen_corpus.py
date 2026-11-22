#!/usr/bin/env python3
"""Generate a deterministic RFC 8949 CBOR corpus of WebAuthn/COSE + Telemetry RPC records."""

import struct
import sys


def encode_head(major: int, n: int) -> bytes:
    maj = major << 5
    if n < 24:
        return bytes([maj | n])
    if n <= 0xFF:
        return bytes([maj | 24, n])
    if n <= 0xFFFF:
        return bytes([maj | 25]) + struct.pack(">H", n)
    if n <= 0xFFFFFFFF:
        return bytes([maj | 26]) + struct.pack(">I", n)
    return bytes([maj | 27]) + struct.pack(">Q", n)


def enc_uint(n: int) -> bytes:
    return encode_head(0, n)


def enc_neg(n: int) -> bytes:
    # encodes -1 - n (pass positive n >= 0)
    return encode_head(1, n)


def enc_bytes(b: bytes) -> bytes:
    return encode_head(2, len(b)) + b


def enc_text(s: str) -> bytes:
    b = s.encode("utf-8")
    return encode_head(3, len(b)) + b


def enc_array(items) -> bytes:
    return encode_head(4, len(items)) + b"".join(items)


def enc_map_sorted(pairs) -> bytes:
    # pairs is list of (encoded_key_bytes, encoded_val_bytes)
    pairs = sorted(pairs, key=lambda kv: kv[0])
    return encode_head(5, len(pairs)) + b"".join(k + v for k, v in pairs)


def enc_bool(v: bool) -> bytes:
    return b"\xf5" if v else b"\xf4"


def enc_f64(v: float) -> bytes:
    return b"\xfb" + struct.pack(">d", v)


def make_bytes(length: int, seed: int) -> bytes:
    return bytes(((seed * 31 + i * 17 + 7) & 0xFF) for i in range(length))


def make_record(i: int) -> bytes:
    auth_data = make_bytes(37, i)
    sig = make_bytes(64, i + 1)
    x_coord = make_bytes(32, i + 2)
    y_coord = make_bytes(32, i + 3)

    cose_key = enc_map_sorted(
        [
            (enc_uint(1), enc_uint(2)),
            (enc_uint(3), enc_neg(6)),
            (enc_neg(0), enc_uint(1)),
            (enc_neg(1), enc_bytes(x_coord)),
            (enc_neg(2), enc_bytes(y_coord)),
        ]
    )

    att_stmt = enc_map_sorted(
        [
            (enc_text("alg"), enc_neg(6)),
            (enc_text("sig"), enc_bytes(sig)),
        ]
    )

    telemetry = enc_map_sorted(
        [
            (enc_text("ok"), enc_bool(i % 2 == 0)),
            (enc_text("seq"), enc_uint(i)),
            (
                enc_text("tags"),
                enc_array([enc_text("tokyo"), enc_text("arm64"), enc_text("cbor")]),
            ),
            (enc_text("latency_ms"), enc_f64(12.3)),
        ]
    )

    return enc_map_sorted(
        [
            (enc_text("fmt"), enc_text("packed")),
            (enc_text("coseKey"), cose_key),
            (enc_text("attStmt"), att_stmt),
            (enc_text("authData"), enc_bytes(auth_data)),
            (enc_text("telemetry"), telemetry),
        ]
    )


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: gen_corpus.py <out.cbor> <count>", file=sys.stderr)
        return 1
    out_path = sys.argv[1]
    count = int(sys.argv[2])
    records = [make_record(i) for i in range(count)]
    payload = enc_array(records)
    with open(out_path, "wb") as f:
        f.write(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
