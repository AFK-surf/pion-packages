"""Shared helpers: length-framed batch I/O against the Pion probe, Rust oracle and Go oracle."""
import os, subprocess, tempfile

TMP = os.environ.get("AUDIT_TMP", "/private/tmp/redteam-html")
BIN = os.path.join(TMP, "bin")
PION = os.path.join(BIN, "pion_probe")
RUST = os.path.join(BIN, "oracle")
GO = os.path.join(BIN, "go_oracle")


def write_records(path, recs):
    with open(path, "wb") as f:
        for r in recs:
            b = r.encode("utf-8", "surrogatepass") if isinstance(r, str) else r
            f.write(str(len(b)).encode() + b"\n" + b)


def read_records(path):
    b = open(path, "rb").read()
    out, i = [], 0
    while i < len(b):
        j = b.index(b"\n", i)
        n = int(b[i:j])
        out.append(b[j + 1:j + 1 + n].decode("utf-8", "replace"))
        i = j + 1 + n
    return out


def run(binary, mode, recs, *extra, timeout=600):
    fd, inp = tempfile.mkstemp(dir=TMP, suffix=".in"); os.close(fd)
    out = inp + ".out"
    write_records(inp, recs)
    r = subprocess.run([binary, mode, inp, out, *extra], capture_output=True, timeout=timeout)
    if r.returncode != 0 or not os.path.exists(out):
        raise RuntimeError(f"{binary} {mode} failed rc={r.returncode}: {r.stderr[-500:]!r}")
    res = read_records(out)
    os.unlink(inp); os.unlink(out)
    return res
