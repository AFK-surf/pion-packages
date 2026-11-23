#!/usr/bin/env python3
"""RT-git DoS / complexity probes: peak RSS + wall time of Pion vs `git index-pack` vs gix.

Usage: python3 dos.py --pion <oracle> --gix <gix_oracle> --work <dir>
Every input is generated under --work; nothing is written inside the repository.
"""
import argparse
import os
import re
import struct
import subprocess
import sys
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import difftest as d  # noqa: E402


def measure(cmd, cwd=None, timeout=900):
    """Run under /usr/bin/time -l (macOS) or -v (GNU); return (rc, secs, peak_rss_mib, tail)."""
    if sys.platform == "darwin":
        tcmd = ["/usr/bin/time", "-l"] + cmd
    else:
        tcmd = ["/usr/bin/time", "-v"] + cmd
    t0 = time.time()
    try:
        p = subprocess.run(tcmd, capture_output=True, timeout=timeout, cwd=cwd)
    except subprocess.TimeoutExpired:
        return ("TIMEOUT", timeout, -1, "")
    dt = time.time() - t0
    err = p.stderr.decode("utf-8", "replace")
    rss = -1
    m = re.search(r"(\d+)\s+maximum resident set size", err)
    if m:
        rss = int(m.group(1)) / (1 << 20)
    m = re.search(r"Maximum resident set size \(kbytes\): (\d+)", err)
    if m:
        rss = int(m.group(1)) / 1024
    out = p.stdout.decode("utf-8", "replace").strip().splitlines()
    tail = out[-1][:110] if out else ""
    if p.returncode != 0:
        lines = [l for l in err.splitlines() if "panic" in l or "fatal" in l or "error" in l]
        tail = (lines[-1] if lines else tail)[:110]
    return (p.returncode, dt, rss, tail)


def batch(path, recs):
    with open(path, "wb") as f:
        for r in recs:
            f.write(struct.pack(">I", len(r)) + r)


def bomb_pack(k, mib=64):
    """k entries; each a zlib bomb blob of `mib` MiB (distinct content so no dedupe)."""
    ents = []
    for i in range(k):
        data = bytes([65 + (i % 26)]) * (mib << 20 if mib else 1)
        ents.append({"t": 3, "data": data, "z": zlib.compress(data, 9)})
    return d.build_pack(ents)


def delta_amp_pack(k):
    """One 64 KiB base + k OFS_DELTAs each expanding to 63 MiB (1 KiB-ish delta each)."""
    base = bytes(range(256)) * 256
    ents = [{"t": 3, "data": base}]
    for i in range(k):
        n_ops = 1008  # 1008 * 64 KiB = 63 MiB
        delta = d.delta_varint(len(base)) + d.delta_varint(n_ops * 0x10000 + 1) + bytes([0x80]) * n_ops + bytes([1, i & 0xFF])
        ents.append({"t": 6, "data": delta, "base": 0})
    return d.build_pack(ents)


def chain_pack(depth, reverse_ref=False):
    objs = [b"x"]
    for i in range(depth):
        objs.append(objs[-1][-64:] + b"y%d" % i)
    ents = []
    if reverse_ref:
        for i in range(depth, 0, -1):
            cur, prev = objs[i], objs[i - 1]
            dd = d.delta_varint(len(prev)) + d.delta_varint(len(cur)) + bytes([len(cur)]) + cur
            ents.append({"t": 7, "data": dd, "base": bytes.fromhex(d.obj_oid("blob", prev))})
        ents.append({"t": 3, "data": objs[0]})
    else:
        ents.append({"t": 3, "data": objs[0]})
        for i in range(1, depth + 1):
            cur, prev = objs[i], objs[i - 1]
            dd = d.delta_varint(len(prev)) + d.delta_varint(len(cur)) + bytes([len(cur)]) + cur
            ents.append({"t": 6, "data": dd, "base": i - 1})
    return d.build_pack(ents)


def big_tree(n):
    ents = sorted([b"f%07d" % i for i in range(n)])
    return b"".join(b"100644 " + e + b"\0" + d.BLOB_OID for e in ents)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pion", required=True)
    ap.add_argument("--gix", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--fourmode-batch", default="", help="also write DoS vectors as a `packx` batch for fourmode.py")
    args = ap.parse_args()
    os.makedirs(args.work, exist_ok=True)
    if args.fourmode_batch:
        batch(args.fourmode_batch, [chain_pack(5000), chain_pack(5000, True), bomb_pack(4), delta_amp_pack(4)])
    gitrepo = os.path.join(args.work, "dosrepo")
    if not os.path.exists(gitrepo):
        subprocess.run(["git", "init", "-q", gitrepo], check=True)

    cases = []
    ks = [1, 4, 8] if args.quick else [1, 4, 8, 16]
    for k in ks:
        cases.append((f"zlib-bomb pack: {k} x 64 MiB blobs", bomb_pack(k), "pack", True))
    for k in ([1, 4, 8] if args.quick else [1, 4, 8, 16]):
        cases.append((f"delta-amp pack: 64KiB base + {k} x 63MiB OFS_DELTA", delta_amp_pack(k), "pack", True))
    for depth in ([1000, 5000] if args.quick else [1000, 5000, 10000]):
        cases.append((f"OFS chain depth {depth} (permissive limits)", chain_pack(depth), "packx", True))
        cases.append((f"reversed REF chain depth {depth} (permissive limits)", chain_pack(depth, True), "packx", True))
    cases.append(("tree 100000 entries parse+encode", big_tree(100000), "tree", False))
    cases.append(("tree 100001 entries (default max_tree_entries)", big_tree(100001), "tree", False))

    print("| Case | Input | Impl | rc | Wall s | Peak RSS MiB | Result |")
    print("| --- | ---: | --- | ---: | ---: | ---: | --- |")
    for label, data, mode, is_pack in cases:
        bp = os.path.join(args.work, "dos.bin")
        batch(bp, [data])
        size = f"{len(data) / 1024:.1f} KiB"
        rows = [("pion", [args.pion, mode, bp]), ("gix", [args.gix, mode.rstrip("x"), bp])]
        if is_pack:
            pp = os.path.join(args.work, "dos.pack")
            for f in (pp, pp[:-5] + ".idx"):
                if os.path.exists(f):
                    os.chmod(f, 0o644)
                    os.remove(f)
            with open(pp, "wb") as f:
                f.write(data)
            rows.append(("git index-pack", ["git", "index-pack", "-o", pp[:-5] + ".idx", pp]))
        else:
            tp = os.path.join(args.work, "dos.obj")
            with open(tp, "wb") as f:
                f.write(data)
            rows.append(("git hash-object", ["git", "-C", gitrepo, "hash-object", "-t", "tree", tp]))
        for name, cmd in rows:
            rc, dt, rss, tail = measure(cmd)
            dts = f"{dt:.2f}" if isinstance(dt, float) else str(dt)
            print(f"| {label} | {size} | {name} | {rc} | {dts} | {rss:.1f} | `{tail}` |", flush=True)


if __name__ == "__main__":
    main()
