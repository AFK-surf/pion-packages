#!/usr/bin/env python3
"""Deterministic corpus generator for packages/zip head-to-head benchmarks."""

import json
import os
import struct
import sys
import zipfile


def make_mixed_files():
    """Generate 200 mixed JSON/log/source files totaling ~28 MiB uncompressed."""
    files = []
    # 80 JSON API response files (~140 KiB each -> ~11.2 MiB)
    for i in range(80):
        records = []
        for j in range(600):
            records.append(
                {
                    "id": i * 1000 + j,
                    "user": f"user_{(i + j) % 97:03d}",
                    "region": ["us-east", "eu-west", "ap-northeast", "ap-south"][
                        (i + j) % 4
                    ],
                    "latency_ms": ((i * 31 + j * 17) % 450) + 1,
                    "ok": (i + j) % 13 != 0,
                    "tags": ["zip", "bench", f"shard-{j % 16}", f"wave-{i % 9}"],
                    "message": f"Processed request {i}:{j} for tenant_{(i * 7 + j) % 23}",
                }
            )
        payload = json.dumps({"batch": i, "items": records}, separators=(",", ":")).encode(
            "utf-8"
        )
        files.append((f"json/batch_{i:03d}.json", payload))

    # 60 structured log files (~150 KiB each -> ~9.0 MiB)
    levels = ["INFO", "WARN", "DEBUG", "ERROR"]
    services = ["gateway", "auth", "billing", "indexer", "worker"]
    for i in range(60):
        lines = []
        for j in range(1500):
            lvl = levels[(i + j) % 4]
            svc = services[(i * 3 + j) % 5]
            lines.append(
                f"2026-11-23T{(i % 24):02d}:{(j % 60):02d}:{(j * 7 % 60):02d}.{(j * 13 % 1000):03d}Z "
                f"[{lvl}] svc={svc} req_id={i:03d}-{j:05d} status={200 + ((i + j) % 5) * 100} "
                f"bytes={(i * 97 + j * 53) % 65536} path=/v1/items/{(i + j) % 500}\n"
            )
        files.append((f"logs/service_{i:03d}.log", "".join(lines).encode("utf-8")))

    # 60 synthetic source-code files (~130 KiB each -> ~7.8 MiB)
    for i in range(60):
        chunks = [f"// Synthetic module {i}\n\n"]
        for j in range(650):
            chunks.append(
                f"pub fn compute_step_{i}_{j}(x : Int, y : Int) -> Int {{\n"
                f"  let a = (x * {(j % 17) + 3}) + (y ^ {(i % 31) + 7})\n"
                f"  let b = if a > 1024 {{ a - 512 }} else {{ a + 256 }}\n"
                f"  (b & 0xFFFF) + {j}\n"
                f"}}\n\n"
            )
        files.append((f"src/mod_{i:03d}.pion", "".join(chunks).encode("utf-8")))

    return files


def main():
    if len(sys.argv) < 2:
        print("usage: gen_corpus.py <out_dir>", file=sys.stderr)
        sys.exit(1)
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    mixed_zip = os.path.join(out_dir, "mixed_28mb.zip")
    mixed_bundle = os.path.join(out_dir, "mixed_28mb.bundle")
    index_zip = os.path.join(out_dir, "index_20k.zip")

    files = make_mixed_files()
    total_uncomp = sum(len(d) for _, d in files)

    with zipfile.ZipFile(
        mixed_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6
    ) as zf:
        for name, data in files:
            zi = zipfile.ZipInfo(name, (2026, 11, 23, 12, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(zi, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)

    with open(mixed_bundle, "wb") as bf:
        bf.write(struct.pack("<I", len(files)))
        for name, data in files:
            nb = name.encode("utf-8")
            bf.write(struct.pack("<H", len(nb)))
            bf.write(nb)
            bf.write(struct.pack("<I", len(data)))
            bf.write(data)

    # 20,000-entry Stored archive for CD index scan + random lookup
    with zipfile.ZipFile(index_zip, "w", compression=zipfile.ZIP_STORED) as zf:
        for idx in range(20000):
            name = f"dir_{idx % 100:02d}/file_{idx:05d}.txt"
            payload = f"entry={idx:05d} shard={idx % 100:02d} payload=pion-zip-benchmark-20k-lookup-item!\n".encode(
                "utf-8"
            )
            zi = zipfile.ZipInfo(name, (2026, 11, 23, 12, 0, 0))
            zi.compress_type = zipfile.ZIP_STORED
            zf.writestr(zi, payload)

    print(
        f"mixed_files={len(files)} mixed_uncomp={total_uncomp} "
        f"mixed_zip={os.path.getsize(mixed_zip)} index_20k_zip={os.path.getsize(index_zip)}"
    )


if __name__ == "__main__":
    main()
