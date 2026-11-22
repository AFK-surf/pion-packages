#!/usr/bin/env python3
"""Score WHATWG `domainToASCII` of Pion and Rust `url v2.5.9` against the Unicode
IdnaTestV2.txt expectations (the normative UTS #46 conformance file).

IdnaTestV2 is written for UseSTD3ASCIIRules=true, CheckHyphens=true,
VerifyDnsLength=true. The WHATWG URL Standard runs UTS #46 with
UseSTD3ASCIIRules=false, CheckHyphens=false, CheckBidi=true, CheckJoiners=true,
Transitional_Processing=false, VerifyDnsLength=false, then rejects forbidden
domain code points. We therefore ignore the status codes those flags turn off
(V2, V3, U1, A4_1, A4_2, X4_2) and re-apply the forbidden-domain check; cases
whose result would go through the IPv4 parser (last label numeric) are skipped.

Usage: idna_conformance.py <IdnaTestV2.txt> <pion_bin> <rust_bin> <out.txt>
"""

import re
import subprocess
import sys

IGNORED = {"V2", "V3", "U1", "A4_1", "A4_2", "X4_2"}
FORBIDDEN_DOMAIN = set(chr(c) for c in range(0x21)) | set("#%/:<>?@[\\]^|\x7f")


def unescape(s):
    s = re.sub(r"\\u([0-9A-Fa-f]{4})", lambda m: chr(int(m.group(1), 16)), s)
    return re.sub(r"\\x\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), s)


def codes(s):
    s = s.strip()
    if not s or s == "[]":
        return []
    return [c.strip() for c in s.strip("[]").split(",") if c.strip()]


def ends_in_number(d):
    labels = d.split(".")
    if labels and labels[-1] == "":
        labels = labels[:-1]
    if not labels:
        return False
    last = labels[-1]
    return last != "" and (last.isdigit() or re.fullmatch(r"0[xX][0-9A-Fa-f]*", last) is not None)


def load(path):
    out = []
    seen = set()
    for line in open(path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        p = [x.strip() for x in line.split(";")]
        src = unescape(p[0])
        to_u = unescape(p[1]) or src
        to_u_st = codes(p[2])
        to_a = unescape(p[3]) if p[3] else to_u
        to_a_st = codes(p[4]) if p[4] else to_u_st
        if src in ('""', "") or src in seen:
            continue
        try:
            src.encode("utf-8")
        except UnicodeEncodeError:
            continue
        seen.add(src)
        relevant = [c for c in to_a_st if c not in IGNORED]
        if relevant:
            exp = ""
        else:
            exp = to_a
            if any(ch in FORBIDDEN_DOMAIN for ch in exp) or exp == "":
                exp = ""
        if ends_in_number(to_a) or ends_in_number(src):
            continue
        out.append((src, exp, to_a_st))
    return out


def run(binary, srcs):
    data = "".join("41\t" + s.encode().hex() + "\n" for s in srcs).encode()
    p = subprocess.run([binary], input=data, capture_output=True, timeout=300)
    assert p.returncode == 0
    return [bytes.fromhex(l).decode("utf-8", "replace") for l in p.stdout.decode().splitlines()]


def main():
    path, pion, rust, out = sys.argv[1:5]
    cases = load(path)
    srcs = [c[0] for c in cases]
    pr, rr = run(pion, srcs), run(rust, srcs)
    stats = {"pion": [0, 0], "rust": [0, 0]}
    buckets = {}
    with open(out, "w", encoding="utf-8") as f:
        for (src, exp, st), p, r in zip(cases, pr, rr):
            for who, got in (("pion", p), ("rust", r)):
                ok = got == exp
                stats[who][0 if ok else 1] += 1
            if p != exp:
                # classify pion failure
                if exp == "" and p != "":
                    kind = "accepts-invalid(" + ",".join(sorted(set(c for c in st if c not in IGNORED))) + ")"
                elif exp != "" and p == "":
                    kind = "rejects-valid"
                else:
                    kind = "wrong-output"
                key = re.sub(r"\d+", "", kind) if kind.startswith("accepts") else kind
                buckets[key] = buckets.get(key, 0) + 1
                f.write("%s\n  src  %r\n  want %r\n  pion %r\n  rust %r\n" % (kind, src, exp, p, r))
    total = len(cases)
    print("IdnaTestV2 WHATWG domainToASCII conformance (%d unique sources):" % total)
    for who in ("pion", "rust"):
        ok, bad = stats[who]
        print("  %-4s pass %5d / %d (%.2f%%)  fail %d" % (who, ok, total, 100.0 * ok / total, bad))
    print("  pion failure classes:")
    for k, v in sorted(buckets.items(), key=lambda kv: -kv[1]):
        print("    %5d  %s" % (v, k))


if __name__ == "__main__":
    main()
