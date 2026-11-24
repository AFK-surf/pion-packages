#!/usr/bin/env python3
"""Generate `packages/cookie/src/psl_index.pion` from `packages/cookie/src/psl_data.pion`.

Usage:
    python3 packages/cookie/scripts/gen_psl_index.py          # regenerate src/psl_index.pion
    python3 packages/cookie/scripts/gen_psl_index.py --check  # verify byte-for-byte match
"""

import os
import re
import sys


def enc6(v: int) -> str:
    """Encode a 6-bit integer (0..63) as a single printable ASCII byte avoiding '"' and '\\'."""
    return chr(49 + v) if v >= 44 else chr(48 + v)


def build_index_source(psl_data_path: str) -> str:
    src = open(psl_data_path, encoding="utf-8").read()
    m = re.search(r'"(.*)"', src, re.S)
    if not m:
        raise RuntimeError(f"failed to find string literal in {psl_data_path}")
    lit = m.group(1).encode("utf-8").decode("unicode_escape")
    rows = [line.rsplit("\t", 1) for line in lit.split("\n") if line]

    # 6-bit per-node flags:
    #   0x01: EXACT_ICANN
    #   0x02: EXACT_PRIVATE
    #   0x04: WILD_ICANN
    #   0x08: WILD_PRIVATE
    #   0x10: HAS_CHILDREN
    #   0x20: HAS_EXCEPTION_CHILD
    nodes: dict[str, int] = {}

    def ensure_ancestors(labels: list[str]) -> None:
        for i in range(1, len(labels)):
            anc = ".".join(labels[i:])
            nodes[anc] = nodes.get(anc, 0) | 0x10

    for rule, sec in rows:
        is_icann = sec == "I"
        if rule.startswith("!"):
            labs = rule[1:].split(".")
            parent = ".".join(labs[1:])
            nodes[parent] = nodes.get(parent, 0) | 0x20 | 0x10
            ensure_ancestors(labs[1:])
        elif rule.startswith("*."):
            base = rule[2:]
            labs = base.split(".")
            nodes[base] = nodes.get(base, 0) | (0x04 if is_icann else 0x08)
            ensure_ancestors(labs)
        else:
            labs = rule.split(".")
            nodes[rule] = nodes.get(rule, 0) | (0x01 if is_icann else 0x02)
            ensure_ancestors(labs)

    sorted_keys = sorted(nodes.keys(), key=lambda s: s.encode("ascii"))

    data_parts: list[str] = []
    offsets: list[int] = []
    pos = 0
    for k in sorted_keys:
        offsets.append(pos)
        fc = enc6(nodes[k])
        data_parts.append(k + fc)
        pos += len(k) + 1
    offsets.append(pos)

    data_str = "".join(data_parts)
    if len(data_str) >= (1 << 18):
        raise RuntimeError(f"packed node data ({len(data_str)} B) exceeds 18-bit offset space")

    off_str = "".join(enc6((o >> 12) & 63) + enc6((o >> 6) & 63) + enc6(o & 63) for o in offsets)

    buckets = [0] * 129
    idx = 0
    for b in range(128):
        while idx < len(sorted_keys) and ord(sorted_keys[idx][0]) < b:
            idx += 1
        buckets[b] = idx
    buckets[128] = len(sorted_keys)
    bkt_str = "".join(enc6((o >> 12) & 63) + enc6((o >> 6) & 63) + enc6(o & 63) for o in buckets)

    return (
        "///| Compact read-only PSL node-flag index generated from `src/psl_data.pion`.\n"
        "///| Zero startup allocation, zero mutable globals, O(log N) in-place lookup.\n"
        "\n"
        "fn psl_node_count() -> Int {\n"
        f"  {len(sorted_keys)}\n"
        "}\n"
        "\n"
        "fn psl_node_data() -> String {\n"
        f'  "{data_str}"\n'
        "}\n"
        "\n"
        "fn psl_node_offsets() -> String {\n"
        f'  "{off_str}"\n'
        "}\n"
        "\n"
        "fn psl_node_buckets() -> String {\n"
        f'  "{bkt_str}"\n'
        "}\n"
    )


def main() -> int:
    pkg_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    data_path = os.path.join(pkg_dir, "src", "psl_data.pion")
    index_path = os.path.join(pkg_dir, "src", "psl_index.pion")
    generated = build_index_source(data_path)

    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        existing = open(index_path, encoding="utf-8").read()
        if existing != generated:
            sys.stderr.write(f"FAIL: {index_path} is out of date; re-run gen_psl_index.py\n")
            return 1
        print(f"OK: {index_path} matches generator output byte-for-byte ({len(generated)} bytes)")
        return 0

    with open(index_path, "w", encoding="utf-8") as f:
        f.write(generated)
    print(f"Wrote {index_path} ({len(generated)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
