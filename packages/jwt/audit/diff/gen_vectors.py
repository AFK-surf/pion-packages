#!/usr/bin/env python3
"""Deterministic red-team differential corpus for packages/jwt.

Usage:
  gen_vectors.py crypto <out>   SHA-2 / HMAC / Base64URL vectors (incl. exhaustive tails)
  gen_vectors.py jwt <out>      JWT/JWS attack corpus (HMAC signed with Python stdlib)

Line format (tab separated, every argument hex encoded so arbitrary bytes survive):
  H256|H384|H512   <label> <data_hex>
  M256|M384|M512   <label> <key_hex> <data_hex>
  B64D             <label> <input_hex>
  B64E             <label> <data_hex>
  JWTV             <label> <alg> <key_hex> <token_hex>

Every oracle prints exactly one line per input line: "<label>\t<result>".
"""

import base64
import hashlib
import hmac
import itertools
import json
import sys

B64 = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"


def pattern(n: int, seed: int = 0) -> bytes:
    # xorshift32 stream: deterministic, covers all byte values incl. >= 0x80
    x = (0x9E3779B9 ^ (seed * 0x85EBCA6B) ^ n) & 0xFFFFFFFF or 1
    out = bytearray(n)
    for i in range(n):
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        out[i] = x & 0xFF
    return bytes(out)


def b64url(b: bytes) -> bytes:
    return base64.urlsafe_b64encode(b).rstrip(b"=")


def gen_crypto(out):
    lens = list(range(0, 301)) + [
        383, 384, 447, 448, 511, 512, 1000, 1023, 1024, 4095, 4096, 4097,
        65535, 65536, 1 << 20,
    ]
    for op in ("H256", "H384", "H512"):
        for n in lens:
            out.write(f"{op}\t{op}/len={n}\t{pattern(n, 1).hex()}\n")
    key_lens = [0, 1, 20, 31, 32, 48, 63, 64, 65, 111, 112, 127, 128, 129, 131, 200, 256, 1000]
    data_lens = [0, 1, 55, 56, 63, 64, 65, 111, 112, 119, 120, 127, 128, 129, 200, 1000, 4096]
    for op in ("M256", "M384", "M512"):
        for kl in key_lens:
            for dl in data_lens:
                out.write(
                    f"{op}\t{op}/key={kl}/data={dl}\t{pattern(kl, 2).hex()}\t{pattern(dl, 3).hex()}\n"
                )
    for n in range(0, 200):
        out.write(f"B64E\tB64E/len={n}\t{pattern(n, 4).hex()}\n")

    # --- Base64URL decode: exhaustive tails (remainder 2: 4096, remainder 3: 262144)
    for a, b in itertools.product(B64, repeat=2):
        s = bytes([a, b])
        out.write(f"B64D\tB64D/r2/{s.decode()}\t{s.hex()}\n")
    for a, b, c in itertools.product(B64, repeat=3):
        s = b"AAAA" + bytes([a, b, c])
        out.write(f"B64D\tB64D/r3/{s.decode()}\t{s.hex()}\n")
    # --- every byte value 0..255 in each of 4 positions of a full quad and of a tail
    for v in range(256):
        for pos in range(4):
            q = bytearray(b"QUJD")
            q[pos] = v
            out.write(f"B64D\tB64D/byte{v:02x}@q{pos}\t{bytes(q).hex()}\n")
        for pos in range(3):
            t = bytearray(b"QUJDREU")
            t[4 + pos] = v
            out.write(f"B64D\tB64D/byte{v:02x}@t{pos}\t{bytes(t).hex()}\n")
    specials = [
        b"", b"A", b"AA", b"AAA", b"AAAA", b"AAAAA", b"AAAAAAAAA",
        b"AA==", b"AA=", b"AAA=", b"QQ", b"QR", b"QUI", b"QUJ",
        b"+/+/", b"-_-_", b"AB+C", b"AB/C", b" AAA", b"AAA ", b"AA\nAA", b"AA\rAA",
        b"AA\tA", b"AA\x00A", b"\xffAAA", b"\x80AAA", b"\xc3\xa9AA", b"AAAA\n",
        b"=AAA", b"A=AA",
    ]
    for i, s in enumerate(specials):
        out.write(f"B64D\tB64D/special{i}\t{s.hex()}\n")


# ---------------------------------------------------------------------------
# JWT attack corpus
# ---------------------------------------------------------------------------

KEY = b"red-team-audit-secret-key-0123456789abcdef"
FUT = 4000000000  # far future: valid for every implementation regardless of clock
PAST = 1000000000  # far past


def mac(alg: str, key: bytes, msg: bytes) -> bytes:
    h = {"HS256": hashlib.sha256, "HS384": hashlib.sha384, "HS512": hashlib.sha512}[alg]
    return hmac.new(key, msg, h).digest()


def tok(hdr: bytes, pay: bytes, alg="HS256", key=KEY, sign_alg=None) -> bytes:
    si = b64url(hdr) + b"." + b64url(pay)
    return si + b"." + b64url(mac(sign_alg or alg, key, si))


def gen_jwt(out):
    rows = []

    def add(label, token: bytes, alg="HS256", key=KEY):
        rows.append((label, alg, key, token))

    H = b'{"alg":"HS256","typ":"JWT"}'
    P = b'{"sub":"alice","exp":%d}' % FUT

    # ---- controls -------------------------------------------------------
    add("control/valid_hs256", tok(H, P))
    add("control/valid_hs384", tok(b'{"alg":"HS384"}', P, "HS384"), "HS384")
    add("control/valid_hs512", tok(b'{"alg":"HS512"}', P, "HS512"), "HS512")
    add("control/expired", tok(H, b'{"sub":"alice","exp":%d}' % PAST))
    add("control/nbf_future", tok(H, b'{"sub":"alice","exp":%d,"nbf":%d}' % (FUT, FUT - 1)))
    add("control/no_exp", tok(H, b'{"sub":"alice"}'))
    add("control/wrong_key", tok(H, P, key=b"other-key"))
    add("control/rfc7515_a1_layout", tok(b'{"typ":"JWT",\r\n "alg":"HS256"}', b'{"iss":"joe",\r\n "exp":%d,\r\n "http://example.com/is_root":true}' % FUT))

    # ---- alg attacks ----------------------------------------------------
    for v in ["none", "None", "NONE", "nOnE"]:
        h = b'{"alg":"%s"}' % v.encode()
        si = b64url(h) + b"." + b64url(P)
        add(f"alg/{v}_empty_sig", si + b".")
        add(f"alg/{v}_hs256_sig", si + b"." + b64url(mac("HS256", KEY, si)))
    for label, h in [
        ("missing", b'{"typ":"JWT"}'),
        ("number", b'{"alg":256}'),
        ("null", b'{"alg":null}'),
        ("array", b'{"alg":["HS256"]}'),
        ("lowercase", b'{"alg":"hs256"}'),
        ("space", b'{"alg":"HS256 "}'),
        ("nul_suffix", b'{"alg":"HS256\\u0000"}'),
        ("escaped_ok", b'{"alg":"\\u0048S256"}'),
        ("hs512_in_hs256_allowlist", b'{"alg":"HS512"}'),
        ("rs256", b'{"alg":"RS256"}'),
        ("empty_header", b'{}'),
    ]:
        add(f"alg/{label}", tok(h, P, sign_alg="HS512" if "hs512" in label else "HS256"))

    # ---- duplicate-key / unicode-escape smuggling -----------------------
    smuggle = {
        "dup/sub_raw_raw": b'{"sub":"guest","sub":"admin","exp":%d}' % FUT,
        "dup/sub_escaped": b'{"sub":"guest","\\u0073ub":"admin","exp":%d}' % FUT,
        "dup/sub_escaped_upperhex": b'{"sub":"guest","\\u0073\\u0075\\u0062":"admin","exp":%d}' % FUT,
        "dup/exp_escaped": b'{"exp":%d,"\\u0065xp":1}' % FUT,
        "dup/exp_escaped_first": b'{"\\u0065xp":1,"exp":%d}' % FUT,
        "dup/aud_escaped": b'{"aud":"a","\\u0061ud":"b","exp":%d}' % FUT,
        "dup/custom_escaped": b'{"role":"user","\\u0072ole":"admin","exp":%d}' % FUT,
        "dup/nested_escaped": b'{"x":{"a":1,"\\u0061":2},"exp":%d}' % FUT,
        "dup/solidus_escape": b'{"a/b":1,"a\\/b":2,"exp":%d}' % FUT,
        "dup/surrogate_key": b'{"\\ud83d\\ude00":1,"\xf0\x9f\x98\x80":2,"exp":%d}' % FUT,
    }
    for label, p in smuggle.items():
        add(label, tok(H, p))
    hdr_smuggle = {
        "dup/hdr_alg_escaped": b'{"alg":"HS256","\\u0061lg":"HS512"}',
        "dup/hdr_alg_raw": b'{"alg":"HS256","alg":"HS256"}',
        "dup/hdr_kid_escaped": b'{"alg":"HS256","kid":"a","\\u006bid":"b"}',
        "dup/hdr_crit_escaped_key": b'{"alg":"HS256","\\u0063rit":["exp"]}',
        "dup/hdr_extra_escaped": b'{"alg":"HS256","x5u":"a","\\u0078\\u0035\\u0075":"b"}',
    }
    for label, h in hdr_smuggle.items():
        add(label, tok(h, P))

    # ---- crit -----------------------------------------------------------
    for label, h in [
        ("crit/empty", b'{"alg":"HS256","crit":[]}'),
        ("crit/exp", b'{"alg":"HS256","crit":["exp"]}'),
        ("crit/alg", b'{"alg":"HS256","crit":["alg"]}'),
        ("crit/unknown_present", b'{"alg":"HS256","crit":["foo"],"foo":1}'),
        ("crit/not_array", b'{"alg":"HS256","crit":"exp"}'),
        ("crit/b64_true", b'{"alg":"HS256","crit":["b64"],"b64":true}'),
    ]:
        add(label, tok(h, P))

    # ---- JSON strictness ------------------------------------------------
    jp = {
        "json/ctrl_0x00_raw": b'{"sub":"a\x00b","exp":%d}' % FUT,
        "json/ctrl_0x1f_raw": b'{"sub":"a\x1fb","exp":%d}' % FUT,
        "json/del_0x7f_raw_ok": b'{"sub":"a\x7fb","exp":%d}' % FUT,
        "json/invalid_utf8_ff": b'{"sub":"\xff","exp":%d}' % FUT,
        "json/invalid_utf8_overlong": b'{"sub":"\xc0\xaf","exp":%d}' % FUT,
        "json/invalid_utf8_cesu_surrogate": b'{"sub":"\xed\xa0\x80","exp":%d}' % FUT,
        "json/invalid_utf8_truncated": b'{"sub":"\xe2\x82","exp":%d}' % FUT,
        "json/lone_high_surrogate": b'{"sub":"\\ud800","exp":%d}' % FUT,
        "json/lone_low_surrogate": b'{"sub":"\\udc00","exp":%d}' % FUT,
        "json/reversed_surrogates": b'{"sub":"\\udc00\\ud800","exp":%d}' % FUT,
        "json/valid_surrogate_pair": b'{"sub":"\\ud83d\\ude00","exp":%d}' % FUT,
        "json/raw_emoji": b'{"sub":"\xf0\x9f\x98\x80","exp":%d}' % FUT,
        "json/trailing_comma_obj": b'{"sub":"a","exp":%d,}' % FUT,
        "json/trailing_comma_arr": b'{"aud":["a",],"exp":%d}' % FUT,
        "json/leading_zero": b'{"x":01,"exp":%d}' % FUT,
        "json/neg_leading_zero": b'{"x":-01,"exp":%d}' % FUT,
        "json/plus_number": b'{"x":+1,"exp":%d}' % FUT,
        "json/dot_number": b'{"x":.5,"exp":%d}' % FUT,
        "json/hex_number": b'{"x":0x10,"exp":%d}' % FUT,
        "json/nan_literal": b'{"x":NaN,"exp":%d}' % FUT,
        "json/single_quotes": b"{'sub':'a','exp':%d}" % FUT,
        "json/comment": b'{"sub":"a",/*c*/"exp":%d}' % FUT,
        "json/bom_prefix": b'\xef\xbb\xbf{"sub":"a","exp":%d}' % FUT,
        "json/trailing_garbage": b'{"sub":"a","exp":%d}x' % FUT,
        "json/two_objects": b'{"exp":%d}{"sub":"admin"}' % FUT,
        "json/top_array": b'[{"exp":%d}]' % FUT,
        "json/top_string": b'"exp"',
        "json/top_number": b'123',
        "json/top_null": b'null',
        "json/empty_payload_obj": b'{}',
        "json/ws_everywhere": b' \t\r\n{ "sub" : "a" , "exp" : %d } \n' % FUT,
        "json/bad_escape": b'{"sub":"\\x41","exp":%d}' % FUT,
        "json/short_unicode": b'{"sub":"\\u004","exp":%d}' % FUT,
        "json/big_custom_u64": b'{"n":18446744073709551615,"exp":%d}' % FUT,
        "json/big_custom_2p63": b'{"n":9223372036854775808,"exp":%d}' % FUT,
        "json/big_custom_1e400": b'{"n":1e400,"exp":%d}' % FUT,
        "json/huge_digits_int": b'{"n":%s,"exp":%d}' % (b"9" * 400, FUT),
        "json/float_custom": b'{"n":0.3,"exp":%d}' % FUT,
        "json/deep_custom_31": b'{"d":%s1%s,"exp":%d}' % (b"[" * 31, b"]" * 31, FUT),
        "json/deep_custom_32": b'{"d":%s1%s,"exp":%d}' % (b"[" * 32, b"]" * 32, FUT),
        "json/deep_custom_200": b'{"d":%s1%s,"exp":%d}' % (b"[" * 200, b"]" * 200, FUT),
        "json/deep_unclosed_5000": b'{"d":' + b"[" * 5000,
    }
    for label, p in jp.items():
        add(label, tok(H, p))

    # ---- NumericDate --------------------------------------------------
    nd = {
        "time/exp_float_frac": b'{"exp":%d.5}' % FUT,
        "time/exp_float_exp_form": b'{"exp":4e9}',
        "time/exp_string": b'{"exp":"%d"}' % FUT,
        "time/exp_null": b'{"exp":null}',
        "time/exp_bool": b'{"exp":true}',
        "time/exp_i64_max": b'{"exp":9223372036854775807}',
        "time/exp_i64_max_plus1": b'{"exp":9223372036854775808}',
        "time/exp_u64_max": b'{"exp":18446744073709551615}',
        "time/exp_negative": b'{"exp":-1}',
        "time/exp_i64_min": b'{"exp":-9223372036854775808}',
        "time/exp_i64_min_minus1": b'{"exp":-9223372036854775809}',
        "time/exp_neg_zero": b'{"exp":-0,"sub":"a"}',
        "time/exp_zero": b'{"exp":0,"sub":"a"}',
        "time/exp_1e20": b'{"exp":1e20}',
        "time/nbf_float_past": b'{"exp":%d,"nbf":%d.5}' % (FUT, PAST),
        "time/iat_future": b'{"exp":%d,"iat":%d}' % (FUT, FUT - 10),
        "time/iat_string": b'{"exp":%d,"iat":"x"}' % FUT,
    }
    for label, p in nd.items():
        add(label, tok(H, p))

    # ---- claim types --------------------------------------------------
    ct = {
        "claims/aud_empty_array": b'{"aud":[],"exp":%d}' % FUT,
        "claims/aud_array_number": b'{"aud":[123],"exp":%d}' % FUT,
        "claims/aud_number": b'{"aud":123,"exp":%d}' % FUT,
        "claims/aud_null": b'{"aud":null,"exp":%d}' % FUT,
        "claims/sub_null": b'{"sub":null,"exp":%d}' % FUT,
        "claims/sub_number": b'{"sub":1,"exp":%d}' % FUT,
        "claims/iss_array": b'{"iss":["a","b"],"exp":%d}' % FUT,
        "claims/jti_number": b'{"jti":7,"exp":%d}' % FUT,
    }
    for label, p in ct.items():
        add(label, tok(H, p))

    # ---- structure / signature ----------------------------------------
    good = tok(H, P)
    h, p, s = good.split(b".")
    add("sig/truncated_1", h + b"." + p + b"." + s[:-1])
    add("sig/truncated_half", h + b"." + p + b"." + s[:21])
    add("sig/extended_A", h + b"." + p + b"." + s + b"A")
    add("sig/extended_AAAA", h + b"." + p + b"." + s + b"AAAA")
    add("sig/padding_eq", h + b"." + p + b"." + s + b"=")
    add("sig/std_alphabet", h + b"." + p + b"." + base64.b64encode(base64.urlsafe_b64decode(s + b"=")).rstrip(b"="))
    last = s[-1:]
    idx = B64.index(last)
    for d in (1, 2, 3):  # 43-char sig => low 2 bits of final char are padding bits
        alt = bytes([B64[(idx & ~3) | ((idx + d) & 3)]])
        add(f"sig/noncanonical_tail_{d}", h + b"." + p + b"." + s[:-1] + alt)
    for i in range(len(s)):
        ch = s[i : i + 1]
        flip = bytes([B64[B64.index(ch) ^ 0x20]])
        add(f"sig/flip_char_{i}", h + b"." + p + b"." + s[:i] + flip + s[i + 1 :])
    add("sig/empty", h + b"." + p + b".")
    add("fmt/two_segments", h + b"." + p)
    add("fmt/four_segments", good + b".AAAA")
    add("fmt/empty_header_seg", b"." + p + b"." + s)
    add("fmt/empty_payload_seg_signed", tok(H, b""))
    add("fmt/leading_space", b" " + good)
    add("fmt/trailing_newline", good + b"\n")
    add("fmt/inner_newline", h + b"\n." + p + b"." + s)
    add("fmt/payload_noncanonical_b64", h + b"." + p[:-1] + bytes([B64[B64.index(p[-1:]) | 1]]) + b"." + s)
    add("fmt/payload_padded", (lambda si: si + b"." + b64url(mac("HS256", KEY, si)))(h + b"." + base64.urlsafe_b64encode(P)))

    # ---- keys ---------------------------------------------------------
    add("key/empty_key_signed_empty", tok(H, P, key=b""), key=b"")
    add("key/one_byte", tok(H, P, key=b"k"), key=b"k")
    add("key/129_bytes_hs256", tok(H, P, key=bytes(range(129))), key=bytes(range(129)))
    add("key/200_bytes_hs384", tok(b'{"alg":"HS384"}', P, "HS384", key=bytes(range(200))), "HS384", bytes(range(200)))
    add("key/200_bytes_hs512", tok(b'{"alg":"HS512"}', P, "HS512", key=bytes(range(200))), "HS512", bytes(range(200)))

    # ---- unicode content interop ---------------------------------------
    uni = json.dumps(
        {"sub": "用户-é-😀- -\"q\"-\\-\t", "exp": FUT, "aud": ["a", "β"], "nested": {"k": [1, 2.5, None, True, {"z": "ü"}]}},
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode()
    add("interop/unicode_raw", tok(H, uni))
    uni_esc = json.dumps(json.loads(uni), ensure_ascii=True, separators=(",", ":")).encode()
    add("interop/unicode_escaped", tok(H, uni_esc))

    for label, alg, key, t in rows:
        out.write(f"JWTV\t{label}\t{alg}\t{key.hex()}\t{t.hex()}\n")


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in ("crypto", "jwt"):
        sys.stderr.write(__doc__)
        return 2
    with open(sys.argv[2], "w", encoding="ascii") as f:
        (gen_crypto if sys.argv[1] == "crypto" else gen_jwt)(f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
