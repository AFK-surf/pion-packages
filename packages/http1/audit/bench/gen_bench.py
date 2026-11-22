#!/usr/bin/env python3
"""Adversarial corpora for the packages/http1 red-team benchmarks (written to argv[1])."""
import os
import sys


def req64(path, count=20000):
    out = []
    for i in range(count):
        hs = "".join(f"X-H{j:02d}: v{j}-{i & 0xff}\r\n" for j in range(61))
        out.append(
            f"GET /api/v1/items/{i}?q=x HTTP/1.1\r\nHost: h{i % 7}.example\r\n"
            f"X-Request-Id: r-{i:08d}\r\n{hs}Accept: */*\r\n\r\n".encode()
        )
    open(path, "wb").write(b"".join(out))


def chunk1m(path, responses=16, chunks=4, size=1 << 20):
    block = bytes((k * 31 + 7) & 0xFF for k in range(size))
    out = []
    for i in range(responses):
        out.append(
            f"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
            f"Transfer-Encoding: chunked\r\nX-I: {i}\r\n\r\n".encode()
        )
        for _ in range(chunks):
            out.append(f"{size:x}\r\n".encode() + block + b"\r\n")
        out.append(b"0\r\n\r\n")
    open(path, "wb").write(b"".join(out))


def sse_multiline(path, events=4000, lines=64):
    out = []
    for i in range(events):
        out.append(f"id: {i}\nevent: chunk\n".encode())
        for j in range(lines):
            out.append(f"data: {{\"i\":{i},\"line\":{j},\"text\":\"lorem ipsum 你好\"}}\n".encode())
        out.append(b"\n")
    open(path, "wb").write(b"".join(out))


def drip(path, value_len=16384):
    # One request whose header block arrives one byte at a time.
    open(path, "wb").write(
        b"GET / HTTP/1.1\r\nHost: a\r\nX-Big: " + b"v" * value_len + b"\r\n\r\n"
    )


if __name__ == "__main__":
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    req64(os.path.join(d, "req64.bin"))
    chunk1m(os.path.join(d, "chunk1m.bin"))
    sse_multiline(os.path.join(d, "sse_multiline.bin"))
    drip(os.path.join(d, "drip.bin"))
