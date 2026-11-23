#!/usr/bin/env python3
"""Cross-validity of Pion's formatter against cedar-policy =4.15.0.

usage: xfmt.py <cases> <pion --fmt output>  >  xfmt.cases
For every case Pion can parse, emit `<id>.xfmt` = the same case with the policies replaced by
Pion's `format_policy_set(..)` output (mode A). run_audit.sh feeds it to the Rust oracle and
compares against the oracle's answer for the ORIGINAL text: `format_policy_set` must emit Cedar
that the reference parser accepts with identical meaning (no injection, no reinterpretation).
"""
import sys

fmt = {}
for line in open(sys.argv[2], encoding="utf-8"):
    line = line.rstrip("\n")
    if line:
        cid, h = line.split("\t")
        fmt[cid] = h
orig_out, xf_out = [], []
for line in open(sys.argv[1], encoding="utf-8"):
    f = line.rstrip("\n").split("\t")
    if len(f) < 5 or f[0] not in fmt or f[1] == "F":
        continue
    print("%s\tA\t%s\t%s\t%s" % (f[0] + ".xfmt", fmt[f[0]], f[3], f[4]))
