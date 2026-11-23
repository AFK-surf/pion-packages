"""Shared helpers: length-framed batch I/O against the Pion probe and the Rust oracle."""
import glob, os, subprocess

TMP = os.environ.get("AUDIT_TMP", "/private/tmp/redteam-hyph")
BIN = os.path.join(TMP, "bin")
PION = os.path.join(BIN, "pion_probe")
RUST = os.path.join(BIN, "oracle")
os.makedirs(BIN, exist_ok=True)
_pat = glob.glob(os.path.expanduser(
    "~/.cargo/registry/src/*/hyphenation-0.8.4/patterns/hyph-en-us.pat.txt"))
CRATE_PAT = _pat[0] if _pat else None
CRATE_HYP = CRATE_PAT.replace(".pat.txt", ".hyp.txt") if CRATE_PAT else None


def write_records(path, recs):
    with open(path, "wb") as f:
        for r in recs:
            b = r.encode("utf-8") if isinstance(r, str) else r
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
    return [x.decode("utf-8") for x in read_records_bytes(path)]


def run_batch(binary, mode, dictspec, recs, tag, extra=(), timeout=900):
    """dictspec = (pats, hyp, lmin, rmin). Returns list of decoded output records."""
    inp = os.path.join(TMP, f"{tag}.in")
    out = os.path.join(TMP, f"{tag}.{os.path.basename(binary)}.{mode}.out")
    write_records(inp, recs)
    if os.path.exists(out):
        os.unlink(out)
    cmd = [binary, mode, *map(str, dictspec), inp, out, *extra]
    r = subprocess.run(cmd, capture_output=True, timeout=timeout)
    if r.returncode != 0 or not os.path.exists(out):
        raise RuntimeError(f"{cmd} rc={r.returncode} stdout={r.stdout[-300:]!r} stderr={r.stderr[-600:]!r}")
    return read_records(out)


def write_tok_file(path, toks):
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(toks) + "\n")
    return path
