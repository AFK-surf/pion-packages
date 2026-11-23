"""Shared helpers: run a line-protocol oracle over a request file, survive Pion aborts."""
import json
import math
import os
import struct
import subprocess


def run_impl(cmd, req_path, n_req, crash_restart=False, timeout=600):
    """Return list of n_req result lines. For Pion (crash_restart=True) an abort on request k
    is recorded as 'CRASH\t<stderr>' and the probe is restarted at k+1 (probe's skip argument)."""
    out = []
    skip = 0
    while skip < n_req:
        args = list(cmd) + [req_path] + ([str(skip)] if crash_restart else [])
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        lines = p.stdout.decode("utf-8", "replace").split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        out.extend(lines)
        if p.returncode == 0 or not crash_restart:
            break
        err = p.stderr.decode("utf-8", "replace").strip().replace("\n", " ")[:200]
        out.append("CRASH\texit=%d %s" % (p.returncode, err))
        skip = len(out)
    out += ["MISSING"] * (n_req - len(out))
    return out[:n_req]


def write_requests(path, reqs):
    with open(path, "w") as f:
        for op, payload in reqs:
            if isinstance(payload, str):
                payload = payload.encode("utf-8", "surrogatepass")
            f.write("%s\t%s\n" % (op, payload.hex()))


def status(line):
    return line.split("\t", 1)[0]


# ---- JSON semantic comparison (order-preserving, duplicate-preserving) ----

def jparse(s):
    return json.loads(s, object_pairs_hook=lambda kv: ("__obj__", kv))


def _dbl(s):
    if s in ("NaN", "-NaN"):
        return "NaN"
    try:
        v = float(s)
    except ValueError:
        return ("bad", s)
    return struct.pack("<d", v)


def norm(v):
    """Normalise a parsed ExtJSON tree so that equal values compare equal:
    $numberDouble strings -> IEEE bits (format-insensitive), bare JSON floats -> bits."""
    if isinstance(v, tuple) and v and v[0] == "__obj__":
        kv = v[1]
        if len(kv) == 1 and kv[0][0] == "$numberDouble" and isinstance(kv[0][1], str):
            return ("dbl", _dbl(kv[0][1]))
        return ("obj", tuple((k, norm(x)) for k, x in kv))
    if isinstance(v, list):
        return ("arr", tuple(norm(x) for x in v))
    if isinstance(v, bool) or v is None:
        return v
    if isinstance(v, float):
        return ("num", struct.pack("<d", v))
    if isinstance(v, int):
        return ("int", v)
    return v


def json_equal(a, b):
    try:
        return norm(jparse(a)) == norm(jparse(b))
    except Exception:
        return False
