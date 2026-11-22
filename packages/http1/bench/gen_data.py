#!/usr/bin/env python3
"""Generate deterministic HTTP/1.1 Request, Chunked Response, and LLM SSE corpora."""

import os
import sys


def gen_requests(out_path: str, count: int = 50000) -> int:
    methods = ["GET", "POST", "PUT", "DELETE", "PATCH"]
    paths = [
        "/api/v1/chat/completions?stream=true&model=neon-4",
        "/api/v1/users/42918/profile?include=roles,teams",
        "/static/assets/app.8f91c2d4.bundle.js",
        "/v2/webhooks/stripe/events?attempt=1",
        "/healthz",
    ]
    hosts = ["api.still.fail", "cdn.example.com", "edge-tokyo-01.internal"]
    uas = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/537.36",
        "pion-http/0.1.0 (arm64_apple)",
        "curl/8.7.1",
    ]
    chunks = []
    for i in range(count):
        m = methods[i % len(methods)]
        p = paths[i % len(paths)]
        h = hosts[i % len(hosts)]
        ua = uas[i % len(uas)]
        req = (
            f"{m} {p} HTTP/1.1\r\n"
            f"Host: {h}\r\n"
            f"User-Agent: {ua}\r\n"
            f"Accept: application/json, text/event-stream;q=0.9, */*;q=0.8\r\n"
            f"Accept-Encoding: gzip, deflate, br\r\n"
            f"Connection: keep-alive\r\n"
            f"X-Request-Id: req-{i:08d}-abcdef\r\n"
            f"X-Forwarded-For: 10.24.{(i >> 8) & 255}.{i & 255}\r\n"
            f"Cache-Control: no-cache\r\n"
            f"\r\n"
        )
        chunks.append(req.encode("ascii"))
    data = b"".join(chunks)
    with open(out_path, "wb") as f:
        f.write(data)
    return len(data)


def gen_responses_chunked(out_path: str, count: int = 25000) -> int:
    statuses = [(200, "OK"), (201, "Created"), (202, "Accepted")]
    ctypes = ["application/json; charset=utf-8", "text/plain; charset=utf-8"]
    c1_tmpl = '{"id":"resp_%07d","status":"ok","items":['
    c2_body = '{"k":"alpha","v":12345},{"k":"beta","v":67890},{"k":"gamma","v":24680}'
    c3_body = '],"meta":{"region":"ap-northeast-1","cached":false,"latency_ms":12}}\n'

    chunks = []
    for i in range(count):
        code, reason = statuses[i % len(statuses)]
        ct = ctypes[i % len(ctypes)]
        p1 = (c1_tmpl % i).encode("ascii")
        p2 = c2_body.encode("ascii")
        p3 = c3_body.encode("ascii")
        resp = (
            f"HTTP/1.1 {code} {reason}\r\n"
            f"Content-Type: {ct}\r\n"
            f"Transfer-Encoding: chunked\r\n"
            f"Server: pion-edge/0.1\r\n"
            f"X-Trace-Id: tr-{i:08x}\r\n"
            f"Cache-Control: private, max-age=60\r\n"
            f"Vary: Accept-Encoding\r\n"
            f"\r\n"
        ).encode("ascii")
        body = (
            f"{len(p1):x}\r\n".encode("ascii") + p1 + b"\r\n"
            + f"{len(p2):x}\r\n".encode("ascii") + p2 + b"\r\n"
            + f"{len(p3):x}\r\n".encode("ascii") + p3 + b"\r\n"
            + b"0\r\n\r\n"
        )
        chunks.append(resp + body)
    data = b"".join(chunks)
    with open(out_path, "wb") as f:
        f.write(data)
    return len(data)


def gen_sse_llm(out_path: str, events: int = 200000) -> int:
    tokens = [
        "The ", "quick ", "brown ", "fox ", "jumps ", "over ", "the ", "lazy ",
        "dog. ", "Pure ", "Pion ", "Sans-IO ", "HTTP/1.1 ", "and ", "SSE ", "streaming!",
    ]
    chunks = [b"\xef\xbb\xbf"]  # UTF-8 BOM at stream start
    for i in range(events):
        tok = tokens[i % len(tokens)]
        if i % 50 == 0:
            chunks.append(b": keep-alive ping\n")
        if i % 10 == 0:
            evt = (
                f"event: content_block_delta\r\n"
                f"id: evt_{i:07d}\r\n"
                f"data: {{\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{tok}\"}}}}\r\n"
                f"data: {{\"seq\":{i}}}\r\n"
                f"\r\n"
            )
        else:
            evt = (
                f"event: content_block_delta\n"
                f"id: evt_{i:07d}\n"
                f"data: {{\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{tok}\"}}}}\n"
                f"\n"
            )
        chunks.append(evt.encode("utf-8"))
    data = b"".join(chunks)
    with open(out_path, "wb") as f:
        f.write(data)
    return len(data)


def main() -> int:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-http1-bench"
    os.makedirs(out_dir, exist_ok=True)
    n1 = gen_requests(os.path.join(out_dir, "requests.bin"))
    n2 = gen_responses_chunked(os.path.join(out_dir, "responses_chunked.bin"))
    n3 = gen_sse_llm(os.path.join(out_dir, "sse_llm.bin"))
    print(f"generated: requests={n1}B responses_chunked={n2}B sse_llm={n3}B")
    return 0


if __name__ == "__main__":
    sys.exit(main())
