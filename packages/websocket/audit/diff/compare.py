#!/usr/bin/env python3
"""Compare canonical outputs of the Pion / tungstenite / coder/websocket runners.

usage: compare.py <pion.out> <rust.out> <go.out> [--md out.md]
Prints every case whose canonical result differs between implementations, plus any
implementation whose result depends on the feed chunk size (1-byte drip vs whole)."""
import sys
from collections import OrderedDict

def load(p):
    d = OrderedDict()
    for line in open(p):
        line = line.rstrip("\n")
        if line:
            name, _, rest = line.partition(" ")
            d[name] = rest
    return d

# RFC 6455 verdict for every case where implementations may legitimately disagree.
RFC = {
    "utf8_6_4_1_failfast_no_final": "MUST fail fast (Autobahn 6.4.1 strict): ERR1007 before the FIN fragment",
    "utf8_6_4_2_failfast_no_final": "MUST fail fast (Autobahn 6.4.2 strict): ERR1007",
    "utf8_firstfrag_ff_no_final": "0xFF can never start UTF-8: fail fast ERR1007",
    "utf8_firstfrag_overlong_no_final": "C0 80 is overlong: fail fast ERR1007",
    "utf8_firstfrag_surrogate_no_final": "ED A0 80 is a surrogate: fail fast ERR1007",
    "utf8_firstfrag_bad_prefix_no_final": "F4 90 can never complete: fail fast ERR1007",
    "utf8_6_4_1_full": "ERR1007 (§8.1)",
    "utf8_valid_prefix_incomplete_at_fin": "ERR1007 (§8.1)",
    "close_reason_bad_utf8": "ERR1007 (§5.5.1/§8.1)",
    "close_1005": "1005 must not be sent on the wire: fail (1002)",
    "close_1006": "1006 must not be sent on the wire: fail (1002)",
    "close_2999": "2999 unassigned: fail (1002)",
    "data_after_close": "§5.5.1/§7.1.1: after Close no data frame may be processed",
    "close_after_close": "§7.1.1: only the first Close is processed",
    "len64_msb_set": "§5.2: MSB MUST be 0 -> fail",
    "len64_max_positive": "exceeds max_message_size -> fail fast (no wait for 8 EiB)",
    "len64_4gb": "exceeds max_message_size -> fail fast",
    "limit_header_only_huge": "exceeds max_message_size -> fail fast",
    "len16_nonminimal_5": "§5.2 'minimal number of bytes MUST be used'; Autobahn does not test, peers accept",
    "len64_nonminimal_5": "same as len16_nonminimal_5",
    "masked_from_server": "§5.1: client MUST fail on a masked server frame",
    "unmasked_from_client": "§5.1: server MUST fail (1002)",
}

def main():
    p, r, g = (load(x) for x in sys.argv[1:4])
    md = sys.argv[5] if len(sys.argv) > 5 and sys.argv[4] == "--md" else None
    rows, drift = [], []
    bases = OrderedDict()
    for name in p:
        bases.setdefault(name.split("@")[0], []).append(name)
    for base, names in bases.items():
        for impl, d in (("pion", p), ("rust", r), ("go", g)):
            vals = {d.get(n) for n in names}
            if len(vals) > 1:
                drift.append(f"{impl}:{base} -> " + " | ".join(f"{n}={d.get(n)}" for n in names))
        n0 = names[0]
        a, b, c = p.get(n0), r.get(n0), g.get(n0)
        if not (a == b == c):
            rows.append((base, a, b, c, RFC.get(base, "")))
    out = ["| case | pion | tungstenite | coder/websocket | RFC 6455 expectation |",
           "| --- | --- | --- | --- | --- |"]
    for base, a, b, c in [x[:4] for x in rows]:
        out.append(f"| `{base}` | `{a}` | `{b}` | `{c}` | {RFC.get(base, '')} |")
    text = "\n".join(out)
    print(f"cases={len(p)} distinct={len(bases)} divergent={len(rows)} chunk-dependent={len(drift)}")
    print(text)
    for d in drift:
        print("CHUNK-DEPENDENT", d)
    if md:
        open(md, "w").write(text + "\n")

main()
