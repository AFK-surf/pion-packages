#!/usr/bin/env python3
"""Generate deterministic mixed text/source/JSON corpus and pre-compressed .gz for flate benchmarks."""
import gzip
import hashlib
import json
import os
import sys

def generate_corpus(target_bytes: int = 2 * 1024 * 1024) -> bytes:
    prose = (
        "In computer science and information theory, DEFLATE is a lossless data compression "
        "file format that uses a combination of LZSS and Huffman coding (RFC 1951). "
        "It was designed by Phil Katz for version 2 of PKZIP and later standardized for "
        "zlib (RFC 1950), gzip (RFC 1952), PNG, HTTP content encoding, and WebSocket permessage-deflate.\n"
    )
    code = (
        "pub fn inflate_block(src: Bytes, pos: Int, limit: Int) -> Result[Bytes, FlateError] {\n"
        "  let mut bitbuf: UInt64 = 0UL\n"
        "  let mut bitcnt = 0\n"
        "  while pos < src.length() {\n"
        "    let sym = lut[(bitbuf & 511UL).to_int()]\n"
        "    if sym == 256 { break }\n"
        "  }\n"
        "  Ok(Bytes::new(0))\n"
        "}\n"
    )
    parts = []
    total = 0
    idx = 0
    while total < target_bytes:
        rec = json.dumps({
            "id": idx,
            "service": "pion-flate-bench",
            "level": ["INFO", "WARN", "DEBUG"][idx % 3],
            "latency_ms": round(((idx * 73) % 1000) / 10.0, 2),
            "path": f"/api/v1/packages/flate/item/{idx % 97}",
            "tags": ["deflate", "zlib", "gzip", f"shard-{idx % 16}"],
            "ok": (idx % 11) != 0,
        }, separators=(",", ":")) + "\n"
        chunk = (prose if idx % 5 == 0 else (code if idx % 5 == 1 else rec)).encode("utf-8")
        parts.append(chunk)
        total += len(chunk)
        idx += 1
    data = b"".join(parts)[:target_bytes]
    return data

def main() -> int:
    if len(sys.argv) < 2:
        print("usage: gen_data.py <out_dir>", file=sys.stderr)
        return 1
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    raw = generate_corpus(2 * 1024 * 1024)
    raw_path = os.path.join(out_dir, "corpus.bin")
    gz_path = os.path.join(out_dir, "corpus.gz")
    with open(raw_path, "wb") as f:
        f.write(raw)
    gz = gzip.compress(raw, compresslevel=6, mtime=0)
    with open(gz_path, "wb") as f:
        f.write(gz)
    sha = hashlib.sha256(raw).hexdigest()
    print(f"corpus.bin: {len(raw)} B (sha256:{sha[:16]}...)")
    print(f"corpus.gz : {len(gz)} B (ratio {len(gz)*100.0/len(raw):.2f}%)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
