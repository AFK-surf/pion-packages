#!/usr/bin/env python3
"""Deterministic corpus generator for packages/jwt verify benchmark."""

import base64
import hashlib
import hmac
import json
import os
import sys

KEY = b"pion-jwt-benchmark-secret-key-2026-0123456789abcdef"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def main() -> int:
    out_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-jwt-bench/tokens_50000.txt"
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 50000

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    hdr_256 = b64url(b'{"alg":"HS256"}')
    hdr_512 = b64url(b'{"alg":"HS512"}')

    lines = []
    for i in range(count):
        is_256 = (i & 1) == 0
        payload_obj = {
            "iss": "https://auth.pion.dev",
            "sub": f"user-{i}",
            "aud": "api-gateway",
            "exp": 2000000000 + (i % 3600),
            "nbf": 1700000000,
            "iat": 1700000000,
            "jti": f"tok-{i}",
        }
        pay_json = json.dumps(payload_obj, separators=(",", ":")).encode("utf-8")
        pay_b64 = b64url(pay_json)
        if is_256:
            signing_input = f"{hdr_256}.{pay_b64}"
            sig = hmac.new(KEY, signing_input.encode("ascii"), hashlib.sha256).digest()
            lines.append(f"256 {signing_input}.{b64url(sig)}\n")
        else:
            signing_input = f"{hdr_512}.{pay_b64}"
            sig = hmac.new(KEY, signing_input.encode("ascii"), hashlib.sha512).digest()
            lines.append(f"512 {signing_input}.{b64url(sig)}\n")

    with open(out_path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    return 0


if __name__ == "__main__":
    sys.exit(main())
