#!/usr/bin/env python3
"""Generate deterministic realistic SSE benchmark corpora for packages/sse."""

import sys


def gen_stream(path: str, count: int) -> None:
    lines = []
    lines.append(": monoid multi-station sync & LLM SSE stream\n")
    for i in range(count):
        kind = i % 5
        if kind == 0:
            lines.append("event: token.delta\n")
            lines.append(f"id: seq-{i:06d}\n")
            if i % 50 == 0:
                lines.append("retry: 2500\n")
            lines.append(
                f'data: {{"seq":{i},"station":"tokyo-0","delta":"chunk_{i}_hello_world"}}\n\n'
            )
        elif kind == 1:
            lines.append("event: sync.patch\r\n")
            lines.append(f"id: seq-{i:06d}\r\n")
            lines.append(f"data: header line {i}\r\n")
            lines.append(f"data:  indented payload {i} 你好世界\r\n")
            lines.append(f"data: footer={i % 97}\r\n\r\n")
        elif kind == 2:
            lines.append(": heartbeat keepalive\n")
            lines.append(f"data: msg-{i}-alpha-beta-gamma-delta\n\n")
        elif kind == 3:
            lines.append("event: state.update\n")
            lines.append(f"id: cur/{i}\n")
            lines.append(
                f'data: {{"id":"cur/{i}","ok":true,"tags":["a","b","c"],"n":{i}}}\n\n'
            )
        else:
            lines.append(f"data: lineA-{i}\n")
            lines.append(f"data: lineB-{i}\n\n")
    with open(path, "wb") as f:
        f.write("".join(lines).encode("utf-8"))


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: gen_data.py <w1|w2|w3> <out_path> <count>", file=sys.stderr)
        return 1
    mode = sys.argv[1]
    out_path = sys.argv[2]
    count = int(sys.argv[3])
    if mode in ("w1", "w2", "w3"):
        gen_stream(out_path, count)
        return 0
    print(f"unknown mode: {mode}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
