#!/usr/bin/env python3
"""Adversarial performance probes for packages/mime (written to <out_dir>, never into the repo).

  bmh_worst_<MB>.bin     boundary 'a'*70, one part whose body is all 'a' bytes: Horspool's classic
                         worst case (last byte always matches, 70-byte backward verify, shift 1).
  bmh_nearmiss_<MB>.bin  baseline the package's own red-team suite uses (distinct-byte near-miss).
  bmh_random_<MB>.bin    random printable body (typical case), same size.
  mp_fanout.bin          200k tiny parts (max_parts raised by nothing: default 1000 -> TooManyParts) and
  mp_fanout_1k.bin       1000 tiny parts (exactly at the default limit).
  mp_param_bomb.bin      64 parts, each Content-Disposition ~60 KiB of distinct plain params; harness reads form_name().
  mp_cont_bomb.bin       same with distinct RFC 2231 bases `pK*0=x` (slow path).
  hdr_params_<N>.txt     one Content-Type with N distinct plain params (fast-path O(N^2) duplicate scan).
  hdr_cont_<N>.txt       one Content-Type with N distinct RFC 2231 bases `pK*0=x` (slow-path O(N^2) reassembly).
  hdr_sect_<N>.txt       one Content-Type with N sections of a single base `a*K=x` (O(N^2) section lookup).
Lines in the .txt probes use the harness `.hex` batch format.
"""
import os
import random
import sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
MB = int(os.environ.get("PROBE_MB", "8"))
n = MB * 1024 * 1024


def mp(boundary, body):
    return (b"--" + boundary + b"\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\n" + body +
            b"\r\n--" + boundary + b"--\r\n")


bd = b"a" * 70
open(os.path.join(out, "bmh_worst_%d.bin" % MB), "wb").write(mp(bd, b"a" * n))
near = b"--boundary1234567890"
open(os.path.join(out, "bmh_nearmiss_%d.bin" % MB), "wb").write(mp(b"boundary1234567890X", near * (n // len(near))))
r = random.Random(7)
open(os.path.join(out, "bmh_random_%d.bin" % MB), "wb").write(
    mp(bd, bytes(r.choice(b"abcdefghijklmnopqrstuvwxyz0123456789 \r\n") for _ in range(n))))
for name, cnt in (("mp_fanout_1k.bin", 1000), ("mp_fanout.bin", 200000)):
    body = b"".join(b"--b\r\nContent-Disposition: form-data; name=\"f%d\"\r\n\r\nv\r\n" % i for i in range(cnt))
    open(os.path.join(out, name), "wb").write(body + b"--b--\r\n")
for N in (1000, 4000, 16000):
    h1 = b"text/plain" + b"".join(b"; p%d=x" % i for i in range(N))
    h2 = b"text/plain" + b"".join(b"; p%d*0=x" % i for i in range(N))
    h3 = b"text/plain" + b"".join(b"; a*%d=x" % i for i in range(min(N, 10000)))
    for tag, h in (("params", h1), ("cont", h2), ("sect", h3)):
        open(os.path.join(out, "hdr_%s_%d.txt" % (tag, N)), "w").write("." + h.hex() + "\n")
# 64 parts whose Content-Disposition carries ~60 KiB of distinct params (each part stays under the 64 KiB
# max_header_bytes default); the harness reads form_name() of every part, as server code does.
for tag, fmt_ in (("param", b"; p%d=x"), ("cont", b"; p%d*0=x")):
    cd = b"form-data; name=\"f\""
    i = 0
    while len(cd) < 60000:
        cd += fmt_ % i
        i += 1
    open(os.path.join(out, "mp_%s_bomb.bin" % tag), "wb").write(
        b"".join(b"--b\r\nContent-Disposition: " + cd + b"\r\n\r\nv\r\n" for _ in range(64)) + b"--b--\r\n")
print("probes written to", out)
