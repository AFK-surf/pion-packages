"""Shared helpers: length-framed batch I/O against the Pion probe, Rust oracle and Node oracle."""
import os, subprocess, tempfile

TMP = os.environ.get("AUDIT_TMP", "/private/tmp/redteam-css")
BIN = os.path.join(TMP, "bin")
PION = os.path.join(BIN, "pion_probe")
RUST = os.path.join(BIN, "oracle")
NODE_ORACLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "node", "oracle.js")
NODE_MODULES = os.path.join(TMP, "node_pkg", "node_modules")
os.makedirs(BIN, exist_ok=True)


def write_records(path, recs):
    with open(path, "wb") as f:
        for r in recs:
            b = r.encode("utf-8", "surrogatepass") if isinstance(r, str) else r
            f.write(str(len(b)).encode() + b"\n" + b)


def read_records_bytes(path):
    b = open(path, "rb").read()
    out, i = [], 0
    while i < len(b):
        j = b.index(b"\n", i)
        n = int(b[i:j])
        out.append(b[j + 1:j + 1 + n])
        i = j + 1 + n
    return out


def read_records(path):
    return [x.decode("utf-8", "replace") for x in read_records_bytes(path)]


def cmd_for(impl):
    if impl == "pion":
        return [PION]
    if impl == "rust":
        return [RUST]
    if impl == "node":
        return ["node", NODE_ORACLE]
    return impl  # explicit argv list


def run(impl, mode, recs, *extra, timeout=900, raw=False):
    fd, inp = tempfile.mkstemp(dir=TMP, suffix=".in"); os.close(fd)
    out = inp + ".out"
    write_records(inp, recs)
    env = dict(os.environ, NODE_PATH=NODE_MODULES)
    r = subprocess.run(cmd_for(impl) + [mode, inp, out, *extra], capture_output=True, timeout=timeout, env=env)
    if r.returncode != 0 or not os.path.exists(out):
        raise RuntimeError(f"{impl} {mode} failed rc={r.returncode}: {r.stderr[-800:]!r}")
    res = read_records_bytes(out) if raw else read_records(out)
    os.unlink(inp); os.unlink(out)
    return res


def parse_items(s):
    """Parse `KIND len:value` items (the canonical dump format shared by all three implementations)."""
    out, i = [], 0
    if isinstance(s, str):
        s = s.encode("utf-8", "surrogatepass")
    if s.startswith(b"ERR"):
        return None
    while i < len(s):
        sp = s.index(b" ", i)
        kind = s[i:sp].decode()
        col = s.index(b":", sp)
        n = int(s[sp + 1:col])
        out.append((kind, s[col + 1:col + 1 + n]))
        i = col + 1 + n
    return out
