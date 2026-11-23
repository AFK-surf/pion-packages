"""Shared pack format for the RT-xpath differential harness (see tools/pion_runner)."""


def rec(tag, body):
    b = body.encode("utf-8")
    return b"@@" + tag.encode() + b" " + str(len(b)).encode() + b"\n" + b + b"\n"


def build(groups):
    """groups: list of (xml, [ns pairs], [queries], [vars]) -> bytes, flat query list."""
    out, flat = [], []
    for g in groups:
        xml, ns, qs = g[0], g[1], g[2]
        vs = g[3] if len(g) > 3 else []
        out.append(rec("DOC", xml))
        for p, u in ns:
            out.append(rec("NS", p + " " + u))
        for kind, name, val in vs:
            out.append(rec("VARS" if kind == "s" else "VARN", name + " " + val))
        for q in qs:
            out.append(rec("Q", q))
            flat.append((xml, q))
    return b"".join(out), flat


def parse_output(text):
    """runner stdout -> list of result strings (one per Q, multi-line for NODES)."""
    res, cur = [], None
    for line in text.split("\n"):
        if line.startswith("=== "):
            if line == "=== DOCERR":
                continue
            if cur is not None:
                res.append("\n".join(cur))
            cur = []
        elif cur is not None and line != "":
            cur.append(line)
    if cur is not None:
        res.append("\n".join(cur))
    return res
