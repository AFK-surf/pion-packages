"""Shared helpers: run every implementation's decoder on raw TOML bytes and compare semantically."""
import json, math, os, subprocess, tempfile

BIN = os.environ.get("AUDIT_BIN", "/tmp/pion-toml-audit/bin")
IMPLS = {
    "pion": [f"{BIN}/pion_cli", "decode"],
    "rust_toml_1.2": [f"{BIN}/rust_ref", "decode"],
    "rust_toml_0.8": [f"{BIN}/rust_ref", "v08-decode"],
    "go_burntsushi": [f"{BIN}/go_ref", "decode"],
}


def run(impl, data, timeout=10):
    with tempfile.NamedTemporaryFile(delete=False, suffix=".toml") as f:
        f.write(data)
        path = f.name
    try:
        r = subprocess.run(IMPLS[impl] + [path], capture_output=True, timeout=timeout)
        if r.returncode == 0:
            return ("ok", json.loads(r.stdout))
        if r.returncode == 1:
            return ("err", r.stderr.decode(errors="replace").strip()[:200])
        return ("crash", f"rc={r.returncode} {r.stderr.decode(errors='replace').strip()[-200:]}")
    except subprocess.TimeoutExpired:
        return ("timeout", f">{timeout}s")
    finally:
        os.unlink(path)


def norm_dt(kind, s):
    s = s.upper().replace(" ", "T")
    # strip trailing fractional zeros / truncate to ns (spec: truncate extra precision)
    def fix_frac(t):
        if "." not in t:
            return t
        head, rest = t.split(".", 1)
        i = 0
        while i < len(rest) and rest[i].isdigit():
            i += 1
        frac, tail = rest[:i][:9].rstrip("0"), rest[i:]
        return head + ("." + frac if frac else "") + tail
    s = fix_frac(s)
    if s.endswith("+00:00") and kind == "datetime":
        s = s[:-6] + "Z"
    return s


def fval(s):
    s = s.lower()
    if s in ("nan", "+nan", "-nan"):
        return float("nan")
    return float(s.replace("_", ""))


def same(a, b, path="$"):
    """Return None if semantically equal, else a description of the first difference."""
    if isinstance(a, dict) and isinstance(b, dict):
        ta, tb = a.get("type") if len(a) == 2 and "value" in a else None, b.get("type") if len(b) == 2 and "value" in b else None
        if ta or tb:
            if ta != tb:
                return f"{path}: type {ta} vs {tb}"
            va, vb = a["value"], b["value"]
            if ta == "float":
                x, y = fval(va), fval(vb)
                if math.isnan(x) and math.isnan(y):
                    return None
                if x != y or math.copysign(1, x) != math.copysign(1, y):
                    return f"{path}: float {va} vs {vb}"
                return None
            if ta in ("datetime", "datetime-local", "date-local", "time-local"):
                if norm_dt(ta, va) != norm_dt(ta, vb):
                    return f"{path}: {ta} {va!r} vs {vb!r}"
                return None
            if ta == "integer":
                return None if int(va) == int(vb) else f"{path}: int {va} vs {vb}"
            return None if va == vb else f"{path}: {ta} {va!r} vs {vb!r}"
        if set(a) != set(b):
            return f"{path}: keys {sorted(set(a) ^ set(b))}"
        for k in a:
            d = same(a[k], b[k], f"{path}.{k}")
            if d:
                return d
        return None
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return f"{path}: len {len(a)} vs {len(b)}"
        for i, (x, y) in enumerate(zip(a, b)):
            d = same(x, y, f"{path}[{i}]")
            if d:
                return d
        return None
    return f"{path}: shape {type(a).__name__} vs {type(b).__name__}"


def compare(res_a, res_b):
    """'agree' | description of disagreement."""
    (sa, va), (sb, vb) = res_a, res_b
    if sa != sb:
        return f"{sa} vs {sb}"
    if sa == "ok":
        d = same(va, vb)
        return d or "agree"
    return "agree"
