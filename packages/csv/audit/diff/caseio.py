"""Shared case-file encoding / tool runner for the csv red-team differential.

Case line (space separated):
  <id> <op> <delim> <quote> <dq> <esc> <cmt> <quoting> <trim> <term> <hdr> <flex> <style> <payload>
    op       r (read) | w (write)
    esc/cmt  byte value or -1 (None)
    trim     0 None, 1 Headers, 2 Fields, 3 All
    term     -1 CRLF, -2 Pion LF / Rust Any(b'\\n'), else Terminator::Any(byte)
    style    0 Necessary, 1 Always, 2 NonNumeric, 3 Never (writer only)
    payload  read : hex of the input bytes, '-' when empty
             write: records joined by '/', fields joined by '.', each field 'x'+hex, '~' = zero fields
"""
import os
import subprocess
import tempfile

BIN = os.environ.get("AUDIT_BIN", "/tmp/pion-csv-audit/bin")
DEFAULT = dict(delim=44, quote=34, dq=1, esc=-1, cmt=-1, quoting=1, trim=0, term=-1, hdr=0, flex=1, style=0)
KEYS = ["delim", "quote", "dq", "esc", "cmt", "quoting", "trim", "term", "hdr", "flex", "style"]
TRIM = ["None", "Headers", "Fields", "All"]
STYLE = ["Necessary", "Always", "NonNumeric", "Never"]


def cfg(**kw):
    c = dict(DEFAULT)
    c.update(kw)
    return c


def describe(c):
    out = []
    for k in KEYS:
        if c[k] != DEFAULT[k]:
            v = c[k]
            if k == "trim":
                v = TRIM[v]
            elif k == "style":
                v = STYLE[v]
            elif k == "term":
                v = {-1: "CRLF", -2: "LF"}[v] if v < 0 else "Any(%r)" % chr(v)
            elif k in ("delim", "quote", "esc", "cmt") and v >= 0:
                v = repr(chr(v))
            out.append("%s=%s" % (k, v))
    return " ".join(out) or "default"


def read_line(i, c, data):
    return "%s r %s %s" % (i, " ".join(str(c[k]) for k in KEYS), data.hex() or "-")


def write_line(i, c, records):
    recs = []
    for r in records:
        recs.append("~" if not r else ".".join("x" + f.hex() for f in r))
    return "%s w %s %s" % (i, " ".join(str(c[k]) for k in KEYS), "/".join(recs))


def parse_output(text):
    res = {}
    cur = None
    for ln in text.splitlines():
        if ln.startswith("#"):
            cur = ln[1:]
            res[cur] = []
        elif ln == "Z":
            cur = None
        elif cur is not None:
            res[cur].append(ln)
    return res


def run(tool_args, lines):
    with tempfile.NamedTemporaryFile("w", suffix=".cases", delete=False) as f:
        f.write("\n".join(lines) + "\n")
        path = f.name
    try:
        p = subprocess.run(tool_args + [path], capture_output=True, timeout=600)
        if p.returncode != 0:
            raise RuntimeError("%s failed: rc=%d %s" % (tool_args, p.returncode, p.stderr[-2000:]))
        return parse_output(p.stdout.decode("latin-1"))
    finally:
        os.unlink(path)


def rust(lines):
    return run([os.path.join(BIN, "rust_ref")], lines)


def pion(variant, lines):
    return run([os.path.join(BIN, "pion_cli"), variant], lines)


def decode_fields(tok):
    if tok == "~":
        return []
    return [bytes.fromhex(f[1:]) for f in tok.split(".")]


def pretty(lines):
    """Human readable rendering of one case output."""
    out = []
    for ln in lines:
        tag, _, rest = ln.partition(" ")
        if tag in ("H", "R"):
            out.append("%s %r" % (tag, decode_fields(rest)))
        elif tag == "W":
            out.append("W %r" % bytes.fromhex(rest))
        else:
            out.append(ln)
    return out
