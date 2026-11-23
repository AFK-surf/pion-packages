#!/usr/bin/env python3
"""Generate deterministic composite BSON 1.1 corpus (concatenated length-prefixed docs)."""
import struct
import sys


def enc_cstr(s: str) -> bytes:
    return s.encode("utf-8") + b"\x00"


def enc_str(s: str) -> bytes:
    b = s.encode("utf-8") + b"\x00"
    return struct.pack("<i", len(b)) + b


def enc_doc(elems: bytes) -> bytes:
    return struct.pack("<i", len(elems) + 5) + elems + b"\x00"


def enc_decimal128_cents(cents: int, neg: bool) -> bytes:
    # Value = (-1)^neg * cents * 10^-2  (exp = -2, biased = 6174 = 0x181E)
    biased = 6174
    hi = (biased << 49) | (0x8000000000000000 if neg else 0)
    lo = cents & 0xFFFFFFFFFFFFFFFF
    hi |= (cents >> 64) & 0x0001FFFFFFFFFFFF
    return struct.pack("<QQ", lo, hi)


def make_doc(i: int) -> bytes:
    oid = struct.pack(">III", 0x65A4F8B0 + (i % 10000), 0xE1C9D04A, 0x7B000000 + i)
    account_id = 1000000000000 + i * 7919
    amount_bid = enc_decimal128_cents(10000 + i * 37, (i % 7) == 0)
    created_at = 1705322096000 + (i // 10) * 10000 if (i % 10 == 0) else 1705322096001 + i * 1338
    regions = ["ap-northeast-1", "us-east-1", "eu-central-1", "ap-southeast-1"]
    region = regions[i % 4]
    score = float((i % 100) + 0.5)
    active = (i % 2) == 0
    retries = i % 5

    # Nested subdocument (alphabetical keys)
    meta_elems = (
        b"\x08" + enc_cstr("active") + (b"\x01" if active else b"\x00")
        + b"\x02" + enc_cstr("region") + enc_str(region)
        + b"\x10" + enc_cstr("retries") + struct.pack("<i", retries)
        + b"\x01" + enc_cstr("score") + struct.pack("<d", score)
    )
    meta_doc = enc_doc(meta_elems)

    # Binary payload (UUID 0x04 or Generic 0x00)
    if i % 2 == 0:
        sub = b"\x04"
        payload = bytes(((i * 13 + j * 17) & 0xFF) for j in range(16))
    else:
        sub = b"\x00"
        payload = bytes(((i * 7 + j * 29) & 0xFF) for j in range(24))

    # Array: ["bson", "wave13", retries, null]
    arr_elems = (
        b"\x02" + enc_cstr("0") + enc_str("bson")
        + b"\x02" + enc_cstr("1") + enc_str("wave13")
        + b"\x10" + enc_cstr("2") + struct.pack("<i", retries)
        + b"\x0a" + enc_cstr("3")
    )
    arr_doc = enc_doc(arr_elems)

    # Root document (alphabetical keys for deterministic ExtJSON key order)
    elems = (
        b"\x07" + enc_cstr("_id") + oid
        + b"\x12" + enc_cstr("account_id") + struct.pack("<q", account_id)
        + b"\x13" + enc_cstr("amount") + amount_bid
        + b"\x09" + enc_cstr("created_at") + struct.pack("<q", created_at)
        + b"\x03" + enc_cstr("meta") + meta_doc
        + b"\x05" + enc_cstr("payload") + struct.pack("<i", len(payload)) + sub + payload
        + b"\x04" + enc_cstr("tags") + arr_doc
    )
    return enc_doc(elems)


def main() -> None:
    if len(sys.argv) < 3:
        print("usage: gen_corpus.py <out.bson> <count>", file=sys.stderr)
        sys.exit(1)
    out_path = sys.argv[1]
    count = int(sys.argv[2])
    with open(out_path, "wb") as f:
        for i in range(count):
            f.write(make_doc(i))


if __name__ == "__main__":
    main()
