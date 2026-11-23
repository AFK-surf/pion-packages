#!/usr/bin/env python3
"""Deterministic JSON corpus generator for W1, W2, and W3 benchmarks."""

import json
import sys


def gen_w1(path: str, count: int) -> None:
    """W1: Large realistic nested GitHub-style event stream (~4.5 MB) with escaped strings and >2^53 Int64 IDs."""
    events = []
    base_id = 9007199254740993  # 2^53 + 1
    for i in range(count):
        ev = {
            "id": base_id + i * 17,
            "type": "PushEvent" if i % 3 == 0 else ("PullRequestEvent" if i % 3 == 1 else "IssueCommentEvent"),
            "public": (i % 5) != 0,
            "created_at_ms": 1795451015208 + i * 1000,
            "actor": {
                "id": 100000000 + i,
                "login": f"engineer_{i % 257}",
                "display_name": f"Dev \"#{i % 97}\" — 東京/上海",
                "url": f"https://api.github.com/users/engineer_{i % 257}",
            },
            "repo": {
                "id": base_id + 1000000 + i * 31,
                "name": f"AFK-surf/service-{i % 64}",
                "stars": (i * 73) % 50000,
                "ratio": round(((i % 997) + 1) / 1000.0, 6),
            },
            "payload": {
                "ref": f"refs/heads/feat/wave17-shard-{i % 32}",
                "size": (i % 7) + 1,
                "message": f"feat(json): batch {i}\nline2\t\"quoted\" \\ path/to/file_{i % 128}.pion",
                "tags": [f"v{(i % 5) + 1}.{(i % 10)}.{i % 20}", "rfc8259", "jcs"],
                "metrics": {
                    "latency_ms": round(0.125 * ((i % 200) + 1), 3),
                    "throughput": round(123.45 + (i % 50) * 0.5, 2),
                    "retries": i % 4,
                    "error": None if (i % 11) != 0 else f"timeout at node-{i % 16}",
                },
            },
        }
        events.append(ev)
    doc = {"schema": "github-events-v2", "count": count, "events": events}
    raw = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    with open(path, "wb") as f:
        f.write(raw)


def gen_w2(path: str, count: int) -> None:
    """W2: Realistic event stream for parse + filter/extract/mutate + stringify roundtrip."""
    records = []
    base_id = 9007199254740993
    for i in range(count):
        rec = {
            "id": base_id + i * 13,
            "active": (i % 2) == 0,
            "score": round(10.125 + (i % 100) * 0.25, 3),
            "internal_token": f"secret_tok_{i}_drop_me",
            "actor": {
                "login": f"user_{i % 199}",
                "tier": i % 5,
            },
            "payload": {
                "tags": [f"tag_{i % 37}", f"region_{i % 8}"],
                "note": f"item {i}: \"ok\"\nnext",
            },
        }
        records.append(rec)
    doc = {"version": 1, "records": records}
    raw = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    with open(path, "wb") as f:
        f.write(raw)


def gen_w3(path: str, keys: int) -> None:
    """W3: Wide object with 50,000 keys (ASCII + Unicode/emoji mix) for parse + O(1) lookup + canonical stringify."""
    obj = {}
    for i in range(keys):
        # Deterministic pseudo-shuffled key insertion order
        k_idx = (i * 39989 + 17) % keys
        if k_idx % 500 == 0:
            k = f"k_{k_idx:05d}_😀"
        elif k_idx % 500 == 1:
            k = f"k_{k_idx:05d}_דּ"
        else:
            k = f"field_{k_idx:05d}"
        obj[k] = 9007199254740993 + k_idx
    raw = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    with open(path, "wb") as f:
        f.write(raw)


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: gen_data.py <w1|w2|w3> <output_path> <count>", file=sys.stderr)
        return 1
    mode = sys.argv[1]
    out = sys.argv[2]
    count = int(sys.argv[3])
    if mode == "w1":
        gen_w1(out, count)
    elif mode == "w2":
        gen_w2(out, count)
    elif mode == "w3":
        gen_w3(out, count)
    else:
        print(f"unknown mode: {mode}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
