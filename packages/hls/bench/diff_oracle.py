#!/usr/bin/env python3
"""Field-by-field differential oracle comparing Pion `packages/hls` against Rust `m3u8-rs`."""

import sys


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("usage: diff_oracle.py <pion_out.txt> <rust_out.txt>")
    pion_path, rust_path = sys.argv[1], sys.argv[2]
    with open(pion_path, "r", encoding="utf-8") as f:
        pion_lines = f.read().splitlines()
    with open(rust_path, "r", encoding="utf-8") as f:
        rust_lines = f.read().splitlines()

    if len(pion_lines) != len(rust_lines):
        print(f"FAIL: line count mismatch: pion={len(pion_lines)} rust={len(rust_lines)}")
        sys.exit(1)

    mismatches = 0
    playlists = 0
    for idx, (p, r) in enumerate(zip(pion_lines, rust_lines)):
        if p.startswith("MASTER|") or p.startswith("MEDIA|"):
            playlists += 1
        if p != r:
            mismatches += 1
            if mismatches <= 10:
                print(f"MISMATCH at line {idx + 1}:")
                print(f"  pion: {p}")
                print(f"  rust: {r}")

    if mismatches > 0:
        print(f"FAIL: {mismatches} mismatches across {playlists} playlists ({len(pion_lines)} field records)")
        sys.exit(1)

    print(
        f"PASS: 0 deviations across {playlists} playlists ({len(pion_lines)} field records) vs Rust m3u8-rs"
    )


if __name__ == "__main__":
    main()
