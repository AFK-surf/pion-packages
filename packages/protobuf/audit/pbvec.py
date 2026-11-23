"""Tiny protobuf wire builder + shared helpers for the packages/protobuf red-team scripts (stdlib only)."""
import json
import os
import struct
import subprocess


def varint(n):
    n &= (1 << 64) - 1
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def tag(f, wt):
    return varint((f << 3) | wt)


def vi(f, n):  # varint field
    return tag(f, 0) + varint(n)


def ld(f, b):  # length-delimited field
    if isinstance(b, str):
        b = b.encode()
    return tag(f, 2) + varint(len(b)) + b


def f32(f, x):
    return tag(f, 5) + struct.pack("<f", x)


def f32bits(f, bits):
    return tag(f, 5) + struct.pack("<I", bits)


def f64(f, x):
    return tag(f, 1) + struct.pack("<d", x)


def f64bits(f, bits):
    return tag(f, 1) + struct.pack("<Q", bits)


def zz(n):
    return (n << 1) ^ (n >> 63)


def run_lines(cmd, lines, workdir, name, timeout=300):
    """Write hex lines to a file, run `cmd + [file]`, return (list of output lines, returncode)."""
    path = os.path.join(workdir, name + ".hex")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    p = subprocess.run(cmd + [path], capture_output=True, text=True, timeout=timeout)
    out = [l for l in p.stdout.split("\n") if l != ""]
    return out, p.returncode


def write(path, text):
    with open(path, "w") as f:
        f.write(text)
    return path


def json_norm(s):
    """Parse JSON keeping duplicate keys; return (canonical, has_dupes, key_orders)."""
    dupes = [False]

    def hook(pairs):
        keys = [k for k, _ in pairs]
        if len(set(keys)) != len(keys):
            dupes[0] = True
        return {"__pairs__": pairs}

    try:
        v = json.loads(s, object_pairs_hook=hook, parse_float=float, parse_int=float)
    except Exception:
        return None, False, None

    def canon(x):
        if isinstance(x, dict):
            d = {}
            for k, vv in x["__pairs__"]:
                d[k] = canon(vv)  # last wins, like every JSON consumer
            return {"__obj__": sorted(d.items())}
        if isinstance(x, list):
            return [canon(i) for i in x]
        return x

    def order(x):
        if isinstance(x, dict):
            return [(k, order(vv)) for k, vv in x["__pairs__"]]
        if isinstance(x, list):
            return [order(i) for i in x]
        return None

    return repr(canon(v)), dupes[0], repr(order(v))
