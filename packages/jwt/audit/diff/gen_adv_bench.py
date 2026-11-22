#!/usr/bin/env python3
"""Adversarial-shape verify corpora for the head-to-head bench (one JWTV file per shape).

  gen_adv_bench.py <out_dir>

Every token is HS256, valid, < 16 KiB (Pion's default max_token_bytes), nests at most
31 levels (Pion's default max_json_depth = 32) and is accepted by Pion, jsonwebtoken
12.0.0 and golang-jwt v5.3.1 alike, so all three do identical work and print identical
stdout. Shapes stress the parser rather than SHA-2.
"""

import base64
import hashlib
import hmac
import json
import os
import sys

KEY = b"red-team-audit-secret-key-0123456789abcdef"
FUT = 4000000000


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=")


def tok(payload: bytes) -> bytes:
    si = b64(b'{"alg":"HS256","typ":"JWT"}') + b"." + b64(payload)
    return si + b"." + b64(hmac.new(KEY, si, hashlib.sha256).digest())


def line(label, payload):
    t = tok(payload)
    assert len(t) <= 16384, (label, len(t))
    return f"JWTV\t{label}\tHS256\t{KEY.hex()}\t{t.hex()}\n"


def shapes():
    base = {"iss": "https://auth.example", "sub": "user-1", "aud": "api", "exp": FUT, "nbf": 1000000000, "iat": 1000000000, "jti": "j"}
    yield "baseline_small", [json.dumps(dict(base, n=i), separators=(",", ":")).encode() for i in range(64)]
    yield "long_ascii_string_11k", [json.dumps(dict(base, blob="x" * 11000 + str(i)), separators=(",", ":")).encode() for i in range(8)]
    esc = "".join("\\u00e9\\n\\\"" for _ in range(900))
    yield "escape_heavy_string", [(b'{"sub":"e","exp":%d,"s":"%s%d"}' % (FUT, esc.encode(), i)) for i in range(8)]
    yield "many_custom_claims_700", [
        json.dumps(dict(base, **{f"c{k}": k + i for k in range(700)}), separators=(",", ":")).encode() for i in range(8)
    ]
    deep = "[" * 30 + "1" + "]" * 30
    yield "deep_nesting_30x150", [
        (b'{"exp":%d,%s}' % (FUT, ",".join(f'"d{k}":{deep}' for k in range(150)).encode())) for _ in range(8)
    ]
    yield "float_array_700", [
        (b'{"exp":%d,"f":[%s]}' % (FUT, ",".join(f"{(k + i) * 1.0000001:.9e}" for k in range(700)).encode())) for i in range(8)
    ]
    yield "unicode_raw_3k", [json.dumps(dict(base, u="用户é😀" * 700 + str(i)), ensure_ascii=False, separators=(",", ":")).encode() for i in range(8)]


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, payloads in shapes():
        with open(os.path.join(out, f"adv_{name}.tsv"), "w") as f:
            for i, p in enumerate(payloads):
                f.write(line(f"{name}/{i}", p))
        print(name)


if __name__ == "__main__":
    main()
