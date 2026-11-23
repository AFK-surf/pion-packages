#!/usr/bin/env python3
"""Line-by-line port of WHATWG HTML "parse a srcset attribute" (§4.8.4.3.10, fetched
2026-11-23) incl. the "rules for parsing floating-point number values" (§2.3.4.3).
Usage: srcset_ref.py < hex lines > out   (protocol: see ../pion/src/main.pion)
       import srcset_ref; srcset_ref.parse_srcset(str) -> [(url, ('w', int)|('x', float))]
A candidate without width/density is reported as x1 (the implied 1x density)."""
import re, sys

WS = " \t\n\x0c\r"
VALID_INT = re.compile(r"[0-9]+\Z")
VALID_FLOAT = re.compile(r"-?(?:[0-9]+|[0-9]+\.[0-9]+|\.[0-9]+)(?:[eE][-+]?[0-9]+)?\Z")


def parse_float_rule(s):
    """Rules for parsing floating-point number values, on an already *valid* string.
    Values rounding to +-2^1024 are errors (None); -0 is not in S, so it becomes 0."""
    try:
        v = float(s)
    except OverflowError:
        return None
    if v in (float("inf"), float("-inf")):
        return None
    return 0.0 if v == 0 else v


def parse_srcset(inp):
    pos, n, out = 0, len(inp), []
    while True:
        while pos < n and (inp[pos] in WS or inp[pos] == ","):  # splitting loop
            pos += 1
        if pos >= n:
            return out
        start = pos
        while pos < n and inp[pos] not in WS:
            pos += 1
        url = inp[start:pos]
        descriptors = []
        if url.endswith(","):
            url = url.rstrip(",")
        else:
            while pos < n and inp[pos] in WS:
                pos += 1
            cur, state = "", "in"
            while True:
                c = inp[pos] if pos < n else None
                if state == "in":
                    if c is not None and c in WS:
                        if cur:
                            descriptors.append(cur)
                            cur, state = "", "after"
                    elif c == ",":
                        pos += 1
                        if cur:
                            descriptors.append(cur)
                        break
                    elif c == "(":
                        cur += c
                        state = "paren"
                    elif c is None:
                        if cur:
                            descriptors.append(cur)
                        break
                    else:
                        cur += c
                elif state == "paren":
                    if c == ")":
                        cur += c
                        state = "in"
                    elif c is None:
                        descriptors.append(cur)
                        break
                    else:
                        cur += c
                else:  # after descriptor
                    if c is not None and c in WS:
                        pass
                    elif c is None:
                        break
                    else:
                        state = "in"
                        continue  # reconsume
                pos += 1
        # descriptor parser
        error, width, density, h = False, None, None, None
        for d in descriptors:
            body, last = d[:-1], d[-1:]
            if last == "w" and VALID_INT.match(body):
                if width is not None or density is not None:
                    error = True
                v = int(body)
                if v == 0:
                    error = True
                else:
                    width = v
            elif last == "x" and VALID_FLOAT.match(body):
                if width is not None or density is not None or h is not None:
                    error = True
                v = parse_float_rule(body)
                if v is None or v < 0:
                    error = True
                else:
                    density = v
            elif last == "h" and VALID_INT.match(body):
                if h is not None or density is not None:
                    error = True
                v = int(body)
                if v == 0:
                    error = True
                else:
                    h = v
            else:
                error = True
        if h is not None and width is None:
            error = True
        if not error and url:
            if width is not None:
                out.append((url, ("w", width)))
            else:
                out.append((url, ("x", 1.0 if density is None else density)))


if __name__ == "__main__":
    lines = []
    for line in sys.stdin.read().split("\n")[:-1]:
        s = bytes.fromhex(line).decode("latin1")
        cs = parse_srcset(s)
        lines.append("\t".join(u.encode("latin1").hex() + " " + k + repr(v) for u, (k, v) in cs))
    sys.stdout.write("\n".join(lines) + ("\n" if lines else ""))
