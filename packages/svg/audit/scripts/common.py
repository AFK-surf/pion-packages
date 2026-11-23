"""Shared helpers for the packages/svg red-team audit: length-framed batch I/O against the Pion probe
(4 build modes) and the Rust oracle, IEEE-754 bit decoding, and the PASS/FAIL ledger."""
import json, os, struct, subprocess, sys, tempfile

TMP = os.environ.get("AUDIT_TMP", "/private/tmp/rt-svg-audit")
BIN = os.path.join(TMP, "bin")
RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
os.makedirs(BIN, exist_ok=True)
SEP = "\x1f"

IMPLS = {
    "pion": [os.path.join(BIN, "probe_native_rel")],
    "pion_dbg": [os.path.join(BIN, "probe_native_dbg")],
    "wasm_rel": ["node", RT, os.path.join(BIN, "probe_wasm_rel.wasm")],
    "wasm_dbg": ["node", RT, os.path.join(BIN, "probe_wasm_dbg.wasm")],
    "rust": [os.path.join(BIN, "oracle")],
}


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


def run(impl, mode, recs, timeout=600):
    fd, inp = tempfile.mkstemp(dir=TMP, suffix=".in")
    os.close(fd)
    out = inp + ".out"
    write_records(inp, recs)
    r = subprocess.run(IMPLS[impl] + [mode, inp, out], capture_output=True, timeout=timeout)
    if r.returncode != 0 or not os.path.exists(out):
        raise RuntimeError(f"{impl} {mode} failed rc={r.returncode}: {r.stderr[-600:]!r}")
    res = read_records(out)
    os.unlink(inp)
    os.unlink(out)
    if len(res) != len(recs):
        raise RuntimeError(f"{impl} {mode}: {len(res)} outputs for {len(recs)} inputs")
    return res


def f64(bits):
    return struct.unpack("<d", struct.pack("<q", int(bits)))[0]


def bits(x):
    return struct.unpack("<q", struct.pack("<d", float(x)))[0]


def ulps(a, b):
    if a == b:
        return 0
    if a != a or b != b:
        return 1 << 62
    ia, ib = bits(a), bits(b)
    if ia < 0:
        ia = -(1 << 63) - ia
    if ib < 0:
        ib = -(1 << 63) - ib
    return abs(ia - ib)


class Ledger:
    """Collects PASS/FAIL checks. `sev` is P0/P1/P2 for a defect check, `ctl` for a control."""

    def __init__(self, section):
        self.section = section
        self.rows = []

    def check(self, name, ok, sev="ctl", detail=""):
        self.rows.append((name, bool(ok), sev, detail))
        tag = "PASS" if ok else "FAIL"
        print(f"  {tag} [{sev}] {name}" + ("" if ok or not detail else f"\n        {detail}"))
        return ok

    def save(self):
        path = os.path.join(TMP, f"ledger_{self.section}.json")
        json.dump([dict(name=n, ok=o, sev=s, detail=d) for n, o, s, d in self.rows], open(path, "w"), indent=1)
        fails = [r for r in self.rows if not r[1]]
        print(f"  -- {self.section}: {len(self.rows) - len(fails)} pass / {len(fails)} fail")
        return 0 if not fails else 1
