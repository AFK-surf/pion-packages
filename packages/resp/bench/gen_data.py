#!/usr/bin/env python3
"""Deterministic RESP3 corpus generator for packages/resp benchmarks."""
import os
import sys


def gen_w1(out_path: str, count: int = 200000) -> None:
    chunks = []
    for i in range(count):
        kind = i & 7
        if kind == 0:
            # BulkString
            val = f"user-payload-{i:06d}-abcdef0123456789"
            chunks.append(f"${len(val)}\r\n{val}\r\n".encode("ascii"))
        elif kind == 1:
            # Integer
            chunks.append(f":{i * 17 - 50000}\r\n".encode("ascii"))
        elif kind == 2:
            # Double (exact binary representable fractions to guarantee identical formatting)
            val = (i % 1024) * 0.25
            chunks.append(f",{val}\r\n".encode("ascii"))
        elif kind == 3:
            # Array of 3 BulkStrings
            a = f"k:{i}"
            b = f"v:{i:06d}"
            c = "ok"
            chunks.append(
                f"*3\r\n${len(a)}\r\n{a}\r\n${len(b)}\r\n{b}\r\n${len(c)}\r\n{c}\r\n".encode("ascii")
            )
        elif kind == 4:
            # Map of 2 pairs
            v1 = f"n{i}"
            chunks.append(
                f"%2\r\n$2\r\nid\r\n:{i}\r\n$4\r\nname\r\n${len(v1)}\r\n{v1}\r\n".encode("ascii")
            )
        elif kind == 5:
            # Set of 3 items
            s1 = f"t{i & 31}"
            chunks.append(
                f"~3\r\n${len(s1)}\r\n{s1}\r\n$4\r\nresp\r\n$5\r\nredis\r\n".encode("ascii")
            )
        elif kind == 6:
            # Push (pub/sub)
            ch = f"chan:{i & 15}"
            msg = f"event-{i}"
            chunks.append(
                f">3\r\n$7\r\nmessage\r\n${len(ch)}\r\n{ch}\r\n${len(msg)}\r\n{msg}\r\n".encode("ascii")
            )
        else:
            # SimpleString
            chunks.append(b"+OK\r\n")

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(b"".join(chunks))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: gen_data.py <out_w1.bin> [count]", file=sys.stderr)
        sys.exit(1)
    out = sys.argv[1]
    cnt = int(sys.argv[2]) if len(sys.argv) >= 3 else 200000
    gen_w1(out, cnt)
