#!/usr/bin/env python3
"""Generate `packages/cookie/src/psl_index.pion` from `packages/cookie/src/psl_data.pion`.

Builds a zero-allocation, read-only reversed-label hash trie:
  - `psl_node_data`: deduplicated single-label string pool (~43 KiB)
  - `psl_node_meta`: 8-byte fixed-stride node metadata (flags, label_len, label_off, parent_id)
  - `psl_cc_table`: 26x26 direct-indexed O(1) table for 2-letter ASCII ccTLDs
  - `psl_tld_hash`: 4096-slot open-addressing hash table for all other TLDs
  - `psl_edge_hash`: 32768-slot open-addressing hash table for (parent_id, label) -> child_id

Usage:
    python3 packages/cookie/scripts/gen_psl_index.py          # regenerate src/psl_index.pion
    python3 packages/cookie/scripts/gen_psl_index.py --check  # verify byte-for-byte match
"""

import os
import re
import sys


def escape_pion_bytes(bs: list[int]) -> str:
    """Encode a list of 7-bit bytes (0..127) as a valid Pion string literal body."""
    out: list[str] = []
    for b in bs:
        if b == 34:  # "
            out.append('\\"')
        elif b == 92:  # \
            out.append("\\\\")
        elif 32 <= b <= 126:
            out.append(chr(b))
        else:
            out.append(f"\\x{b:02x}")
    return "".join(out)


def h_tld(label: str) -> int:
    h = 5381
    for b in reversed(label.encode("ascii")):
        h = ((h * 33) ^ b) & 0xFFFFFFFF
    h &= 0x7FFFFFFF
    return (h ^ (h >> 12)) & 4095


def h_edge(pid: int, label: str) -> int:
    h = (pid * 40503 + 5381) & 0xFFFFFFFF
    for b in reversed(label.encode("ascii")):
        h = ((h * 33) ^ b) & 0xFFFFFFFF
    h &= 0x7FFFFFFF
    return (h ^ (h >> 15)) & 32767


def build_index_source(psl_data_path: str) -> str:
    src = open(psl_data_path, encoding="utf-8").read()
    m = re.search(r'"(.*)"', src, re.S)
    if not m:
        raise RuntimeError(f"failed to find string literal in {psl_data_path}")
    lit = m.group(1).encode("utf-8").decode("unicode_escape")
    rows = [line.rsplit("\t", 1) for line in lit.split("\n") if line]

    # 7-bit per-node flags (0..127):
    #   0x01: EXACT_ICANN
    #   0x02: EXACT_PRIVATE
    #   0x04: WILD_ICANN
    #   0x08: WILD_PRIVATE
    #   0x10: EX_ICANN      (!this_node)
    #   0x20: EX_PRIVATE    (!this_node)
    #   0x40: HAS_CHILDREN
    nodes: dict[tuple[str, ...], int] = {}
    flags: dict[int, int] = {}
    parent: dict[int, int] = {}
    label_of: dict[int, str] = {}

    def get_or_add(path: tuple[str, ...]) -> int:
        if path in nodes:
            return nodes[path]
        pid = 0 if len(path) == 1 else get_or_add(path[:-1])
        nid = len(nodes) + 1
        nodes[path] = nid
        flags[nid] = 0
        parent[nid] = pid
        label_of[nid] = path[-1]
        if pid != 0:
            flags[pid] |= 0x40
        return nid

    for rule, sec in rows:
        is_icann = sec == "I"
        if rule.startswith("!"):
            labs = tuple(reversed(rule[1:].split(".")))
            nid = get_or_add(labs)
            flags[nid] |= 0x10 if is_icann else 0x20
        elif rule.startswith("*."):
            labs = tuple(reversed(rule[2:].split(".")))
            nid = get_or_add(labs)
            flags[nid] |= 0x04 if is_icann else 0x08
        else:
            labs = tuple(reversed(rule.split(".")))
            nid = get_or_add(labs)
            flags[nid] |= 0x01 if is_icann else 0x02

    total_nodes = len(nodes)
    if total_nodes >= (1 << 14):
        raise RuntimeError(f"total trie nodes ({total_nodes}) exceeds 14-bit node id space")

    # Build deterministic deduplicated substring pool for all unique labels
    unique_labels = sorted(set(label_of.values()), key=lambda s: (-len(s), s))
    pool_parts: list[str] = []
    pool_str = ""
    label_pos: dict[str, int] = {}
    for lab in unique_labels:
        idx = pool_str.find(lab)
        if idx >= 0:
            label_pos[lab] = idx
        else:
            label_pos[lab] = len(pool_str)
            pool_parts.append(lab)
            pool_str += lab

    # Layout of single flat `psl_node_data()` blob (all 7-bit bytes 0..127):
    #   [0 .. 1352):           26x26 ccTLD direct table (676 * 2 B)
    #   [1352 .. 9544):        4096-slot TLD hash table (4096 * 2 B)
    #   [9544 .. 75080):       32768-slot edge hash table (32768 * 2 B)
    #   [75080 .. pool_off):   8-byte node metadata for ids 0..total_nodes
    #   [pool_off .. end):     deduplicated single-label string pool
    meta_off = 1352 + 8192 + 65536
    pool_off = meta_off + (total_nodes + 1) * 8
    if pool_off + len(pool_str) >= (1 << 21):
        raise RuntimeError(f"blob size ({pool_off + len(pool_str)} B) exceeds 21-bit offset space")

    # 8-byte fixed-stride node metadata (id 0 is unused sentinel, ids 1..total_nodes)
    # label_off is stored directly as absolute byte offset inside `psl_node_data()`.
    meta_bytes: list[int] = [0] * ((total_nodes + 1) * 8)
    for nid in range(1, total_nodes + 1):
        lab = label_of[nid]
        off = pool_off + label_pos[lab]
        pid = parent[nid]
        base = nid * 8
        meta_bytes[base + 0] = flags[nid] & 0x7F
        meta_bytes[base + 1] = len(lab) & 0x7F
        meta_bytes[base + 2] = (off >> 14) & 0x7F
        meta_bytes[base + 3] = (off >> 7) & 0x7F
        meta_bytes[base + 4] = off & 0x7F
        meta_bytes[base + 5] = (pid >> 7) & 0x7F
        meta_bytes[base + 6] = pid & 0x7F
        meta_bytes[base + 7] = 0

    # 26x26 direct table for 2-letter ASCII ccTLDs + 4096-slot hash table for other TLDs
    cc_tbl = [0] * 676
    tld_tbl = [0] * 4096
    edge_tbl = [0] * 32768

    for path, nid in nodes.items():
        if len(path) == 1:
            lab = path[0]
            if len(lab) == 2 and "a" <= lab[0] <= "z" and "a" <= lab[1] <= "z":
                cc_tbl[(ord(lab[0]) - 97) * 26 + (ord(lab[1]) - 97)] = nid
            else:
                slot = h_tld(lab)
                while tld_tbl[slot] != 0:
                    slot = (slot + 1) & 4095
                tld_tbl[slot] = nid
        else:
            slot = h_edge(parent[nid], path[-1])
            while edge_tbl[slot] != 0:
                slot = (slot + 1) & 32767
            edge_tbl[slot] = nid

    blob: list[int] = []
    for arr in (cc_tbl, tld_tbl, edge_tbl):
        for v in arr:
            blob.append((v >> 7) & 0x7F)
            blob.append(v & 0x7F)
    blob.extend(meta_bytes)
    blob.extend(ord(c) for c in pool_str)
    blob_lit = escape_pion_bytes(blob)

    return (
        "///| Compact read-only PSL reversed-label hash-trie index generated from `src/psl_data.pion`.\n"
        "///| Single flat blob: zero startup allocation, zero mutable globals, O(1) expected lookup.\n"
        "\n"
        "fn psl_node_data() -> String {\n"
        f'  "{blob_lit}"\n'
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
