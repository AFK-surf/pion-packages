"""Shared helpers: length-framed batch I/O against the Pion probe and the Rust oracle."""
import os, subprocess, tempfile

TMP = os.environ.get("AUDIT_TMP", "/private/tmp/redteam-bidi")
BIN = os.path.join(TMP, "bin")
UCD = os.path.join(TMP, "ucd")
PION = os.path.join(BIN, "pion_probe")
RUST = os.path.join(BIN, "oracle")
RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
VARIANTS = {
    "native_debug": [os.path.join(BIN, "pion_probe_debug")],
    "native_release": [PION],
    "wasm32_debug": ["node", RT, os.path.join(BIN, "pion_probe_debug.wasm")],
    "wasm32_release": ["node", RT, os.path.join(BIN, "pion_probe_release.wasm")],
}
os.makedirs(BIN, exist_ok=True)

CLASSES = "AL AN B BN CS EN ES ET FSI L LRE LRI LRO NSM ON PDF PDI R RLE RLI RLO S WS".split()
# One representative scalar per Bidi_Class (no bracket / mirrored characters).
REP = dict(L="a", R="א", AL="ا", EN="1", ES="+", ET="$", AN="٠", CS=",", NSM="̀",
           BN="­", B=" ", S="\t", WS=" ", ON="!", LRE="‪", LRO="‭", RLE="‫",
           RLO="‮", PDF="‬", LRI="⁦", RLI="⁧", FSI="⁨", PDI="⁩")


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
        out.append(b[j + 1:j + 1 + n])
        i = j + 1 + n
    return out


def run(cmd, mode, recs, timeout=1800):
    """Run `cmd mode <in> <out>` on `recs`; returns list of output records (bytes)."""
    fd, inp = tempfile.mkstemp(dir=TMP, suffix=".in"); os.close(fd)
    out = inp + ".out"
    write_records(inp, recs)
    if isinstance(cmd, str):
        cmd = {"pion": [PION], "rust": [RUST]}[cmd]
    r = subprocess.run(cmd + [mode, inp, out], capture_output=True, timeout=timeout)
    if r.returncode != 0 or not os.path.exists(out):
        raise RuntimeError(f"{cmd} {mode} failed rc={r.returncode}: {r.stderr[-800:]!r}")
    res = read_records(out)
    os.unlink(inp); os.unlink(out)
    return res
