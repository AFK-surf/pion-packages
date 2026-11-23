"""Shared helpers: length-framed batch I/O against the Pion probe, graphql-js and apollo-parser oracles."""
import os, subprocess, tempfile

TMP = os.environ.get("AUDIT_TMP", "/private/tmp/rt-graphql")
BIN = os.path.join(TMP, "bin")
PION = os.path.join(BIN, "pion_probe")
RUST = os.path.join(BIN, "oracle")
HERE = os.path.dirname(os.path.abspath(__file__))
NODE_ORACLE = os.path.join(HERE, "..", "node", "oracle.js")
NODE_MODULES = os.path.join(TMP, "node_pkg", "node_modules")
os.makedirs(BIN, exist_ok=True)


def enc(r):
    return r.encode("utf-8", "surrogatepass") if isinstance(r, str) else r


def write_records(path, recs):
    with open(path, "wb") as f:
        for r in recs:
            b = enc(r)
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


def cmd_for(impl):
    if impl == "pion":
        return [PION]
    if impl == "rust":
        return [RUST]
    if impl == "node":
        return ["node", "--stack-size=984", NODE_ORACLE]
    return impl  # explicit argv list


def run(impl, mode, recs, timeout=900):
    fd, inp = tempfile.mkstemp(dir=TMP, suffix=".in"); os.close(fd)
    out = inp + ".out"
    write_records(inp, recs)
    env = dict(os.environ, NODE_PATH=NODE_MODULES)
    r = subprocess.run(cmd_for(impl) + [mode, inp, out], capture_output=True, timeout=timeout, env=env)
    if r.returncode != 0 or not os.path.exists(out):
        raise RuntimeError(f"{impl} {mode} failed rc={r.returncode}: {r.stderr[-800:]!r}")
    res = [x.decode("utf-8", "replace") for x in read_records_bytes(out)]
    os.unlink(inp); os.unlink(out)
    return res


def is_err(s):
    return s.startswith("ERR")


def short(s, n=110):
    s = repr(s)
    return s if len(s) <= n else s[:n] + "..."
