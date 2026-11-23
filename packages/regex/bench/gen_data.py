#!/usr/bin/env python3
"""Deterministic synthetic server log corpus generator for packages/regex benchmarks."""

import sys

SERVICES = [
    "auth-api", "edge-proxy", "billing-worker", "search-idx",
    "ingest-gw", "cache-node", "scheduler", "metrics-sink",
]
LEVELS = ["INFO", "INFO", "INFO", "INFO", "WARN", "ERROR", "INFO", "INFO"]
PATHS = [
    "/v1/users/profile", "/v1/orders/checkout", "/v2/search?q=pion",
    "/healthz", "/v1/tokens/refresh", "/api/../../etc/passwd",
    "/v1/items/42", "/v1/metrics/export",
]
MESSAGES = [
    "request completed ok",
    "upstream timeout waiting for response",
    "connection refused by backend 10.0.1.42:8080",
    "rate_limit exceeded for tenant=acme",
    "tls: handshake failure from 198.51.100.17",
    "query=SELECT id FROM users WHERE active=1",
    "container OOMKilled after 2048Mi",
    "panic: runtime error in worker pool",
    "see https://docs.example.com/runbooks/latency-spike for details",
    "FATAL unrecoverable storage corruption detected",
]


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: gen_data.py <out_file> <num_lines>", file=sys.stderr)
        return 1
    out_file = sys.argv[1]
    num_lines = int(sys.argv[2])

    state = 0x12345678
    def next_u32() -> int:
        nonlocal state
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
        return state

    lines = []
    for i in range(num_lines):
        r1 = next_u32()
        r2 = next_u32()
        r3 = next_u32()
        hh = (i // 3600) % 24
        mm = (i // 60) % 60
        ss = i % 60
        lvl = LEVELS[r1 % len(LEVELS)]
        svc = SERVICES[(r1 >> 4) % len(SERVICES)]
        status = 200
        if lvl == "ERROR":
            status = 500 + (r2 % 4)
        elif lvl == "WARN":
            status = 429 if (r2 % 3 == 0) else 404
        latency = 4 + (r2 % 90)
        if r3 % 19 == 0:
            latency = 500 + (r2 % 1800)
        path = PATHS[(r3 >> 3) % len(PATHS)]
        msg = MESSAGES[(r3 >> 7) % len(MESSAGES)] if (r3 % 5 == 0) else "request completed ok"
        req_id = "{:08x}{:04x}".format(r1, r2 & 0xFFFF)
        line = (
            "2026-11-23T{:02d}:{:02d}:{:02d}Z {} [{}] "
            "req_id={} path={} status={} latency={}ms msg={}"
        ).format(hh, mm, ss, lvl, svc, req_id, path, status, latency, msg)
        lines.append(line)

    with open(out_file, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
