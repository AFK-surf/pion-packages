#!/usr/bin/env python3
"""RFC 8785 differential: jcs_compare.py <jcs.hex> <pion canon out> <node canon out> [--show N]

Node (JSON.parse + RFC 8785 Appendix canonicalizer) is the reference. A Pion line is CORRECT when it
equals Node's bytes, or when Pion returns an error for a document whose numbers are not all exactly
representable as finite IEEE-754 doubles (rejecting rather than rounding a big integer is a legitimate
JCS policy; emitting non-ES digits is not). Divergences are classified:
  non-finite   Node rejects (a number overflows binary64, RFC 8785 §3.2.2.2), Pion emits something
  number-form  Pion bytes == Node bytes once every Pion number is re-read as a double and printed with
               ECMAScript Number::toString - i.e. only number serialization differs
  other        anything else (key order, string escaping, structure)
Exits 1 on any divergence.
"""
import json
import math
import sys
from collections import defaultdict

show = 6
a = sys.argv[1:]
if "--show" in a:
    i = a.index("--show"); show = int(a[i + 1]); del a[i:i + 2]
cases, pf, nf = a
C = open(cases).read().split("\n")
P = open(pf).read().split("\n")
N = open(nf).read().split("\n")
if C[-1] == "":
    C.pop()


def es_num(x):
    """ECMAScript Number::toString(x) for finite x (Python repr has the same shortest/closest digits)."""
    if x == 0:
        return "0"
    s = repr(abs(x))
    mant, _, e = s.partition("e")
    e = int(e) if e else 0
    ip, _, fp = mant.partition(".")
    digits = (ip + fp).lstrip("0")
    point = len(ip) + e if ip != "0" else e - (len(fp) - len(fp.lstrip("0")))
    digits = digits.rstrip("0") or "0"
    k, n = len(digits), point
    if k <= n <= 21:
        r = digits + "0" * (n - k)
    elif 0 < n <= 21:
        r = digits[:n] + "." + digits[n:]
    elif -6 < n <= 0:
        r = "0." + "0" * (-n) + digits
    else:
        r = digits[0] + ("." + digits[1:] if k > 1 else "") + "e" + ("+" if n - 1 >= 0 else "-") + str(abs(n - 1))
    return ("-" if x < 0 else "") + r


def jcs(v):
    if isinstance(v, bool) or v is None:
        return json.dumps(v)
    if isinstance(v, float):
        if not math.isfinite(v):
            raise ValueError("non-finite")
        return es_num(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "[" + ",".join(jcs(x) for x in v) + "]"
    ks = sorted(v, key=lambda k: k.encode("utf-16-be"))
    return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + jcs(v[k]) for k in ks) + "}"


def exact(text):
    ok = [True]

    def pi(s):
        if float(s) != int(s):
            ok[0] = False
        return float(s)

    def pf(s):
        try:
            if not math.isfinite(float(s)):
                ok[0] = False
        except OverflowError:
            ok[0] = False
        return float(s)
    try:
        json.loads(text, parse_int=pi, parse_float=pf)
    except Exception:
        return False
    return ok[0]


def dec(h):
    return bytes.fromhex(h).decode("utf-8", "surrogatepass")


bad = defaultdict(list)
good = 0
for i, c in enumerate(C):
    p, n = P[i], N[i]
    src = dec(c.split("\t")[0])
    if p == n or (p.startswith("ERR") and not exact(src)):
        good += 1
        continue
    if n == "ERR":
        k = "non-finite (Node/RFC 8785 rejects, Pion emits)"
    elif p.startswith("OK "):
        try:
            again = jcs(json.loads(dec(p[3:]), parse_int=float, parse_float=float))
            k = "number-form (only number serialization differs)" if again.encode().hex() == n[3:] else "other"
        except Exception:
            k = "other"
    else:
        k = "other"
    bad[k].append((src, p, n))
print(f"  jcs: {good}/{len(C)} RFC 8785-correct (pion vs node JSON.parse + RFC 8785 canonicalize)")
for k, v in bad.items():
    print(f"    {len(v)} x {k}")
    for src, p, n in v[:show]:
        s = src if len(src) < 100 else src[:70] + f"...<{len(src)} chars>"
        po = dec(p[3:]) if p.startswith("OK ") else p
        no = dec(n[3:]) if n.startswith("OK ") else n
        print(f"      in={s!r}")
        print(f"         pion={po[:110]!r}")
        print(f"         node={no[:110]!r}")
sys.exit(1 if bad else 0)
