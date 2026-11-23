#!/usr/bin/env python3
"""Adversarial-shape benchmark inputs for packages/asn1 (length-prefixed DER files).

  gen_bench.py <out_dir> [--scale N]

Shapes (each <shape>.derbin + <shape>.iters, iterations sized for roughly 0.2-1 s of work):
  real          the 8 OpenSSL certificates of the differential corpus (RSA-2048/4096, P-256/384/521,
                Ed25519, X25519, plain) - needs <out_dir>/../real_certs.derbin from gen_corpus.py
  many_san      one certificate with 4,000 dNSName SAN entries
  many_rdn      one certificate whose subject has 4,000 RDNs
  many_ext      one certificate with 4,000 distinct (unknown, non-critical) extensions
  big_rsa_cert  the RSA-4096 certificate alone
  ext_scaling   many_ext at 1k / 4k / 16k / 64k extensions (one file per size: ext_<n>.derbin)
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from derlib import cert, default_exts, dns, ext, name, oid, printable, seq, set_, utf8  # noqa: E402


def write(out, shape, ders, iters):
    with open(os.path.join(out, f"{shape}.derbin"), "wb") as f:
        for d in ders:
            f.write(len(d).to_bytes(4, "big") + d)
    with open(os.path.join(out, f"{shape}.iters"), "w") as f:
        f.write(str(iters))


def read_derbin(path):
    raw = open(path, "rb").read()
    out, p = [], 0
    while p + 4 <= len(raw):
        n = int.from_bytes(raw[p:p + 4], "big")
        out.append(raw[p + 4:p + 4 + n])
        p += 4 + n
    return out


def many_ext(n):
    exts = default_exts()
    for i in range(n):
        exts.append(ext(f"1.3.6.1.4.1.55555.{i // 1000}.{i % 1000}", b"\x05\x00"))
    return cert(exts=exts)


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    real = read_derbin(os.path.join(os.path.dirname(os.path.abspath(out)), "real_certs.derbin"))
    write(out, "real", real, 20000)
    write(out, "big_rsa_cert", [max(real, key=len)], 100000)
    write(out, "many_san", [cert(exts=default_exts(*[dns(f"h{i}.example.com") for i in range(4000)]))], 300)
    rdns = [set_(seq(oid("2.5.4.11"), utf8(f"unit {i}"))) for i in range(4000)]
    write(out, "many_rdn", [cert(subject=seq(set_(seq(oid("2.5.4.6"), printable("US"))), *rdns), exts=default_exts())], 300)
    write(out, "many_ext", [many_ext(4000)], 20)
    for n in (1000, 4000, 16000, 64000):
        write(out, f"ext_{n}", [many_ext(n)], 1)
    print(f"bench inputs -> {out}")


if __name__ == "__main__":
    main()
