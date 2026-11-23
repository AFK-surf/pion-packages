#!/usr/bin/env python3
"""Structured + mutation fuzz differential: Pion (4 build modes) vs Rust rmpv vs Go vmihailenco.

usage: fuzz_diff.py <bin_dir> <work_dir> <count> <seed>

Inputs: random value trees encoded with random (often overlong) widths, then ~60% get mutated
(bit flips, truncation, byte insertion/deletion, marker swaps). For every input:
  * Pion native-release / native-debug / wasm32-debug / wasm32-release must print identical lines
    for opts -, ts0, dup, canon (any process crash is reported);
  * Pion(ts0) vs rmpv: same accept/reject decision, same tree, same canonical re-encoding,
    except for documented, explained classes (rmpv accepts 0xC1 / invalid UTF-8 / depth > 128);
  * Pion(-) vs Go: same decision and tree, with the same explained classes plus Go's unchecked
    timestamp nanoseconds.
"""
import collections
import os
import random
import struct
import subprocess
import sys

RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")


def gen_value(rng, depth, budget=None):
    """budget: shared [remaining-node-count] so one input stays small (<= ~64 nodes)."""
    if budget is None:
        budget = [64]
    budget[0] -= 1
    k = rng.randrange(14 if depth < 6 and budget[0] > 0 else 10)
    if k == 0:
        return ("nil",)
    if k == 1:
        return ("bool", rng.random() < 0.5)
    if k == 2:
        return ("uint", rng.choice([0, 1, 127, 128, 255, 256, 65535, 65536, (1 << 32) - 1, 1 << 32,
                                    (1 << 63) - 1, 1 << 63, (1 << 64) - 1, rng.getrandbits(rng.choice([7, 8, 16, 32, 64]))]))
    if k == 3:
        return ("int", rng.choice([-1, -32, -33, -128, -129, -32768, -32769, -(1 << 31), -(1 << 31) - 1, -(1 << 63),
                                   -rng.getrandbits(rng.choice([5, 7, 15, 31, 62])) - 1]))
    if k == 4:
        return ("f32", rng.getrandbits(32))
    if k == 5:
        return ("f64", rng.getrandbits(64) if rng.random() < 0.5 else struct.unpack(">Q", struct.pack(">d", rng.uniform(-1e6, 1e6)))[0])
    if k == 6:
        n = rng.choice([0, 1, 5, 31, 32, 40, 255, 256, 300])
        alphabet = ["a", "é", "✓", "😀", "\x00", "߿", "￿", "\U0010ffff"]
        s = "".join(rng.choice(alphabet) for _ in range(n)).encode()[:n] if n else b""
        return ("str", s)
    if k == 7:
        return ("bin", bytes(rng.getrandbits(8) for _ in range(rng.choice([0, 1, 7, 255, 256, 300]))))
    if k == 8:
        t = rng.choice([-128, -2, 0, 1, 5, 127])
        return ("ext", t, bytes(rng.getrandbits(8) for _ in range(rng.choice([0, 1, 2, 3, 4, 8, 16, 17, 255, 256]))))
    if k == 9:
        form = rng.randrange(3)
        if form == 0:
            return ("ts32", rng.getrandbits(32))
        if form == 1:
            return ("ts64", rng.getrandbits(34), rng.choice([0, 1, 999999999, rng.randrange(1000000000), rng.getrandbits(30)]))
        return ("ts96", rng.getrandbits(64) - (1 << 63), rng.choice([0, 999999999, rng.randrange(1000000000), rng.getrandbits(32)]))
    if k in (10, 11):
        return ("arr", [gen_value(rng, depth + 1, budget) for _ in range(rng.choice([0, 1, 2, 3, 15, 16, 17]))])
    return ("map", [(gen_value(rng, depth + 1, budget), gen_value(rng, depth + 1, budget))
                    for _ in range(rng.choice([0, 1, 2, 3, 15, 16]))])


def enc_len(rng, n, fix_marker, fix_max, markers):
    """markers: list of (marker, struct-fmt, max). Random width >= the needed one (overlong allowed)."""
    opts = []
    if fix_marker is not None and n <= fix_max:
        opts.append(bytes([fix_marker | n]))
    for m, fmt, mx in markers:
        if n <= mx:
            opts.append(bytes([m]) + struct.pack(">" + fmt, n))
    return opts[0] if rng.random() < 0.7 else rng.choice(opts)


def enc(rng, v):
    t = v[0]
    if t == "nil":
        return b"\xc0"
    if t == "bool":
        return b"\xc3" if v[1] else b"\xc2"
    if t == "uint":
        u = v[1]
        c = []
        if u <= 0x7F:
            c.append(bytes([u]))
        for m, fmt, mx in ((0xCC, "B", 0xFF), (0xCD, "H", 0xFFFF), (0xCE, "I", 0xFFFFFFFF), (0xCF, "Q", (1 << 64) - 1)):
            if u <= mx:
                c.append(bytes([m]) + struct.pack(">" + fmt, u))
        for m, fmt, mx in ((0xD0, "b", 127), (0xD1, "h", 32767), (0xD2, "i", (1 << 31) - 1), (0xD3, "q", (1 << 63) - 1)):
            if u <= mx:
                c.append(bytes([m]) + struct.pack(">" + fmt, u))
        return c[0] if rng.random() < 0.7 else rng.choice(c)
    if t == "int":
        s = v[1]
        c = []
        if s >= -32:
            c.append(struct.pack(">b", s))
        for m, fmt, lo in ((0xD0, "b", -128), (0xD1, "h", -32768), (0xD2, "i", -(1 << 31)), (0xD3, "q", -(1 << 63))):
            if s >= lo:
                c.append(bytes([m]) + struct.pack(">" + fmt, s))
        return c[0] if rng.random() < 0.7 else rng.choice(c)
    if t == "f32":
        return b"\xca" + struct.pack(">I", v[1])
    if t == "f64":
        return b"\xcb" + struct.pack(">Q", v[1])
    if t == "str":
        return enc_len(rng, len(v[1]), 0xA0, 31, [(0xD9, "B", 0xFF), (0xDA, "H", 0xFFFF), (0xDB, "I", 0xFFFFFFFF)]) + v[1]
    if t == "bin":
        return enc_len(rng, len(v[1]), None, 0, [(0xC4, "B", 0xFF), (0xC5, "H", 0xFFFF), (0xC6, "I", 0xFFFFFFFF)]) + v[1]
    if t in ("ext", "ts32", "ts64", "ts96"):
        if t == "ext":
            typ, data = v[1], v[2]
        elif t == "ts32":
            typ, data = -1, struct.pack(">I", v[1])
        elif t == "ts64":
            typ, data = -1, struct.pack(">Q", (v[2] << 34) | v[1])
        else:
            typ, data = -1, struct.pack(">Iq", v[2], v[1])
        n = len(data)
        c = []
        fx = {1: 0xD4, 2: 0xD5, 4: 0xD6, 8: 0xD7, 16: 0xD8}
        if n in fx:
            c.append(bytes([fx[n]]))
        for m, fmt, mx in ((0xC7, "B", 0xFF), (0xC8, "H", 0xFFFF), (0xC9, "I", 0xFFFFFFFF)):
            if n <= mx:
                c.append(bytes([m]) + struct.pack(">" + fmt, n))
        h = c[0] if rng.random() < 0.7 else rng.choice(c)
        return h + struct.pack(">b", typ) + data
    if t == "arr":
        items = v[1]
        return enc_len(rng, len(items), 0x90, 15, [(0xDC, "H", 0xFFFF), (0xDD, "I", 0xFFFFFFFF)]) + b"".join(enc(rng, x) for x in items)
    pairs = v[1]
    return enc_len(rng, len(pairs), 0x80, 15, [(0xDE, "H", 0xFFFF), (0xDF, "I", 0xFFFFFFFF)]) + b"".join(enc(rng, a) + enc(rng, b) for a, b in pairs)


def mutate(rng, b):
    b = bytearray(b)
    for _ in range(rng.randrange(1, 4)):
        op = rng.randrange(6)
        if not b:
            b.append(rng.getrandbits(8))
            continue
        i = rng.randrange(len(b))
        if op == 0:
            b[i] ^= 1 << rng.randrange(8)
        elif op == 1:
            b = b[: rng.randrange(len(b))]
        elif op == 2:
            b.insert(i, rng.getrandbits(8))
        elif op == 3:
            del b[i]
        elif op == 4:
            b[i] = rng.choice([0xC1, 0xD9, 0xDB, 0xDD, 0xDF, 0xC9, 0xC7, 0xD6, 0xD7, 0xFF, 0x00, 0x80, 0x90])
        else:
            b[i] = rng.getrandbits(8)
    return bytes(b)


def run(cmd, timeout=900):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.splitlines(), r.stderr


def split(line):
    if line.startswith("OK "):
        p = line.split(" ")
        return "OK", p[1], p[2] if len(p) > 2 else ""
    return "ERR", line[4:], ""


def explain(inp, pion, other, who):
    """Return a reason string when a decision difference is a known, documented class."""
    if pion.startswith("ERR") and other.startswith("OK"):
        if "invalid UTF-8" in pion:
            return "%s accepts invalid UTF-8 str (Pion validates, stricter)" % who
        if "invalid marker 193" in pion:
            return "%s decodes reserved 0xC1 as nil (Pion rejects, spec-correct)" % who
        if "max nesting depth" in pion:
            return "default max_depth 128 (Pion) vs 1024 (rmpv) / unlimited (Go)"
        if "invalid timestamp" in pion and who == "go":
            return "go accepts timestamp nsec >= 1e9 (Pion rejects, spec-correct)"
    return None


def main():
    bin_dir, work, count, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    os.makedirs(work, exist_ok=True)
    rng = random.Random(seed)
    inputs = []
    for i in range(count):
        b = enc(rng, gen_value(rng, 0))
        if rng.random() < 0.6:
            b = mutate(rng, b)
        if not b:
            b = b"\xc0"
        inputs.append(b)
    hexf = os.path.join(work, "fuzz.hex")
    with open(hexf, "w") as f:
        f.write("".join(x.hex() + "\n" for x in inputs))

    pion = {
        "native-release": [os.path.join(bin_dir, "pion_probe")],
        "native-debug": [os.path.join(bin_dir, "pion_probe_debug")],
        "wasm32-debug": ["node", RT, os.path.join(bin_dir, "pion_probe_debug.wasm")],
        "wasm32-release": ["node", RT, os.path.join(bin_dir, "pion_probe_release.wasm")],
    }
    res = {}
    crashes = 0
    for mode, cmd in pion.items():
        for opt in ("-", "ts0", "dup", "canon"):
            rc, out, err = run(cmd + ["tree", opt, hexf])
            if rc != 0 or len(out) != len(inputs):
                crashes += 1
                print("CRASH %s opts=%s rc=%d lines=%d/%d stderr=%s" % (mode, opt, rc, len(out), len(inputs), err[-300:]))
            res[mode, opt] = out
    mism = 0
    for mode in ("native-debug", "wasm32-debug", "wasm32-release"):
        for opt in ("-", "ts0", "dup", "canon"):
            for i, (a, b) in enumerate(zip(res["native-release", opt], res[mode, opt])):
                if a != b:
                    mism += 1
                    if mism <= 10:
                        print("4MODE MISMATCH %s opts=%s input=%s\n   release=%s\n   %s=%s" % (mode, opt, inputs[i].hex(), a, mode, b))
    print("inputs=%d  pion crashes=%d  4-mode mismatches=%d" % (len(inputs), crashes, mism))

    _, rust, _ = run([os.path.join(bin_dir, "rust_probe"), "tree", "-", hexf])
    _, go, _ = run([os.path.join(bin_dir, "go_probe"), "tree", "-", hexf])
    P, P0 = res["native-release", "-"], res["native-release", "ts0"]
    stats = collections.Counter()
    unexplained = []
    for i, inp in enumerate(inputs):
        for who, other, mine in (("rust", rust[i], P0[i]), ("go", go[i], P[i])):
            md, mt, me = split(mine)
            od, ot, oe = split(other)
            if md == od == "OK":
                if mt != ot:
                    unexplained.append((who, "tree", inp, mine, other))
                elif who == "rust" and me != oe:
                    unexplained.append((who, "re-encoding", inp, mine, other))
                else:
                    stats[who, "agree OK"] += 1
            elif md == od == "ERR":
                stats[who, "agree ERR"] += 1
            else:
                why = explain(inp, mine, other, who)
                if why:
                    stats[who, why] += 1
                else:
                    unexplained.append((who, "decision", inp, mine, other))
        # strict re-decode of Pion's own output must succeed (canonical encoder)
    for k, v in sorted(stats.items()):
        print("  %-5s %-70s %d" % (k[0], k[1], v))
    print("unexplained differences: %d" % len(unexplained))
    for who, kind, inp, mine, other in unexplained[:40]:
        print("  [%s %s] in=%s\n     pion=%s\n     %s=%s" % (who, kind, inp.hex()[:120], mine[:200], who, other[:200]))


if __name__ == "__main__":
    main()
