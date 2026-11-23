#!/usr/bin/env python3
"""Generate every differential corpus for the json5 red-team audit (deterministic, seed fixed).

usage: gen_cases.py <out_dir>

Writes:
  numfmt.txt     60,000+ IEEE-754 bit patterns (random bits, subnormals, extremes, powers, ties)
  numparse.hex   40,000+ hex-encoded numeric literals (17..40 digit decimals, halfway cases,
                 hex literals of 1..40 digits, JSON5 sign / dot forms)
  syntax.hex     hand-written JSON5 / ES5.1 edge cases (strings, escapes, numbers, keys, comments)
  strict.hex     the same syntax cases, run in strict-JSON mode against JSON.parse / serde_json
  ptr.txt        RFC 6901 pointer edge cases (`<hex doc> <hex ptr>`)
  patch.txt      RFC 6902 edge cases (`<hex doc> <hex patch>`)
  diff.txt       2,000 random (a, b) JSON document pairs for diff()/apply_patch round trip
"""
import json
import os
import random
import struct
import sys

R = random.Random(0x6A736F6E35)


def hx(s):
    return s.encode("utf-8", "surrogatepass").hex()


def bits(x):
    return struct.unpack(">Q", struct.pack(">d", x))[0]


def gen_numfmt(path):
    pats = set()
    specials = [0.0, -0.0, 5e-324, -5e-324, 2.2250738585072014e-308, 2.225073858507201e-308,
                1.7976931348623157e308, -1.7976931348623157e308, 1e21, 1e-7, 1e-6, 9.999999999999999e20,
                123456789012345680000.0, 0.1, 0.2, 0.30000000000000004, 1 / 3, 2 ** 53, 2 ** 53 + 2,
                9007199254740993.0, 1e23, 8.41e21, 5e-310, 4.9406564584124654e-324]
    for x in specials:
        pats.add(bits(x))
    for e in range(-1074, 1024):
        pats.add(bits(2.0 ** e) if e > -1075 else 0)
    for e in range(-325, 309):
        try:
            pats.add(bits(float(f"1e{e}")))
        except OverflowError:
            pass
    while len(pats) < 40000:
        pats.add(R.getrandbits(64) & ~(0x7FF << 52) | (R.randrange(0, 0x7FF) << 52))
    while len(pats) < 50000:  # subnormals
        pats.add(R.getrandbits(52) | (R.getrandbits(1) << 63))
    while len(pats) < 60000:  # short decimals: 1-17 significant digits
        d = R.randrange(1, 18)
        pats.add(bits(float(f"{R.randrange(10 ** (d - 1), 10 ** d)}e{R.randrange(-330, 310)}")))
    with open(path, "w") as f:
        for p in sorted(pats):
            f.write(f"{p:016x}\n")
    return len(pats)


def gen_numparse(path):
    lits = []
    # exact halfway / near-halfway decimal strings (classic strtod killers)
    lits += ["9007199254740993", "9007199254740995", "18014398509481987", "1.00000000000000011102230246251565404236316680908203125",
             "1.00000000000000011102230246251565404236316680908203124", "1.00000000000000011102230246251565404236316680908203126",
             "2.2250738585072011e-308", "2.2250738585072012e-308", "2.4703282292062327e-324", "2.4703282292062328e-324",
             "1.7976931348623158e308", "1.7976931348623157e308", "1.797693134862315807e308", "4.9406564584124654e-324",
             "7.2057594037927933e16", "1e23", "8.41e21", "5e-324", "0.1e-1", "123456789012345678901234567890",
             "9223372036854775807", "9223372036854775808", "-9223372036854775809", "18446744073709551615",
             "18446744073709551616", "1e400", "-1e400", "1e309", "1e-400", "0e9999", "-0", "-0.0", "-0e5"]
    for _ in range(25000):
        nd = R.randrange(15, 41)
        digits = str(R.randrange(1, 10)) + "".join(str(R.randrange(10)) for _ in range(nd - 1))
        e = R.randrange(-340, 320)
        dot = R.randrange(1, nd + 1)
        lits.append(f"{digits[:dot]}.{digits[dot:] or '0'}e{e}")
    for _ in range(8000):  # halfway between adjacent doubles, printed exactly
        m = R.getrandbits(52) | (1 << 52)
        e = R.randrange(-60, 60)
        from fractions import Fraction
        v = Fraction(2 * m + 1) * Fraction(2) ** (e - 1)
        s = f"{v.numerator / v.denominator:.25e}"
        lits.append(s)
    for n in list(range(1, 41)) * 120:  # hex literals 1..40 digits
        lits.append("0x" + "".join(R.choice("0123456789abcdefABCDEF") for _ in range(n)))
    for n in range(13, 33):  # structured hex: 1 followed by zeros, a rounding bit and a sticky bit
        for tail in ("81", "80", "7f", "01", "ff", "100"):
            lits.append("0x1" + "0" * max(0, n - 1 - len(tail)) + tail)
    for s in ("+", "-", ""):
        for body in (".5", "5.", "5.e3", ".5e-3", "0x1F", "0X1f", "Infinity", "NaN", "0", "00", "01", "0.0", "1e+0", "1E-0"):
            lits.append(s + body)
    with open(path, "w") as f:
        for s in lits:
            f.write(hx(s) + "\n")
    return len(lits)


SYNTAX = [
    # whitespace / BOM / line terminators
    "\ufeff{a:1}", "{\ufeffa:1}", "[1,\ufeff2]", "[1\u2028,2\u2029]", "\u00a0[1]\u3000", "[\u000b1\u000c]",
    "[\u180e1]", "[\u200b1]", "[\u00851]",
    # comments
    "/**/1", "1//x", "[1/*,*/]", "/* /* */ */1", "1/", "[1 /* x", "//\u20281", "{a/**/:1}", "-/**/1",
    # strings
    "'a\"b'", '"a\'b"', "'\\''", '"\\""', "'\\a\\c\\d'", '"\\/"', "'\\0'", "'\\00'", "'\\01'", "'\\08'", "'\\1'",
    "'\\9'", "'\\x41'", "'\\x4'", "'\\xZZ'", "'\\u004'", "'\\u{41}'", "'\\uD83D\\uDE00'", "'\\uD800'",
    "'\\uDC00'", "'\\uD800\\u0041'", "'\\v\\f\\b'", "'a\\\nb'", "'a\\\r\nb'", "'a\\\rb'", "'a\\\u2028b'",
    "'a\\\u2029b'", "'a\nb'", "'a\rb'", "'a\u2028b'", "'a\u2029b'", "'a\tb'", "'a\x00b'", "'a\x1fb'",
    "'\\\u00e9'", "'\\\U0001f600'", "'unterminated",
    # numbers
    "0x", "0x1.5", "0x1p2", "-0x0", "+0x10", "0X1a", "0xFFFFFFFFFFFFFFFF", "0x100000000000000000000",
    "01", "-01", "+01", "00.5", ".", "+.", "-.", "1e", "1e+", ".e1", "5.e3", "Infinityx", "-Infinity",
    "+NaN", "-NaN", "infinity", "nan", "+-1", "--1", "1_000", "0b101", "0o17", "1n",
    # keys
    "{\\u0061:1}", "{\\u0030:1}", "{a\\u0030:1}", "{\\u200C:1}", "{a\\u200C:1}", "{a\\u0020b:1}",
    "{true:1}", "{null:1}", "{Infinity:1}", "{NaN:1}", "{if:1}", "{$:1}", "{_:1}", "{a-b:1}",
    "{'':1}", "{\"\":1}", "{\\uD835\\uDC00:1}", "{\U0001d400:1}", "{\u0660:1}", "{a\u0660:1}",
    "{\U0001f600:1}", "{\uff01:1}", "{\uff04:1}", "{\u207f:1}", "{a\u20d7:1}", "{\u3231:1}",
    "{\U00030000:1}", "{a\u00b7:1}", "{\u0483:1}", "{a\U000e0100:1}", "{\u2e2f:1}", "{\u309b:1}",
    # structure
    "[1,]", "[1,,]", "[,]", "[,1]", "{a:1,}", "{a:1,,}", "{,}", "{}", "[]", "", " ", "1 2", "[1 2]",
    "{a 1}", "{a:1 b:2}", "{'a':1,a:2}", "{a:1,a:2}", "{__proto__:1}", "{a:{b:[{c:null}]}}",
    "\"\\u0000\"", "[true,false,null]", "[tru]", "[nul]", "[truefalse]",
]


def gen_syntax(path, strict_path):
    with open(path, "w") as f:
        for s in SYNTAX:
            f.write(hx(s) + "\n")
    strict = SYNTAX + ['"\\u2028"', '"a\tb"', '{"a":1}', "[1.5e3,-0,0.0]", '"\\x41"', '"\\v"', '"\\\'"',
                       "1.", ".5", "+1", "0x1", "Infinity", "NaN", "[1,]", "//c\n1", "'a'", "{a:1}",
                       '"\\\nx"', "\u00a0 1", "\ufeff1", "[\u000b1]"]
    with open(strict_path, "w") as f:
        for s in strict:
            f.write(hx(s) + "\n")
    return len(SYNTAX), len(strict)


PTR = [
    ('{"a":1}', ""), ('{"":1}', "/"), ('{"a":{"":2}}', "/a/"), ('[1,2]', "/01"), ('[1,2]', "/1"), ('[1,2]', "/-"),
    ('{"-":7}', "/-"), ('{"a~b":1}', "/a~0b"), ('{"a/b":1}', "/a~1b"), ('{"~1":5}', "/~01"), ('{"a":1}', "/a~"),
    ('{"a~2":1}', "/a~2"), ('{"a":1}', "a"), ('[1]', "/ 0"), ('[1]', "/+0"), ('[1]', "/-0"), ('[1]', "/0x0"),
    ('[1]', "/2147483648"), ('[1]', "/99999999999999999999"), ('{"0":1}', "/0"), ('{"01":1}', "/01"),
    ('{"a":[{"b":3}]}', "/a/0/b"), ('{"a":[{"b":3}]}', "/a/-/b"), ('{"%25":1}', "/%25"), ('{"\u00e9":1}', "/\u00e9"),
]

PATCH = [
    # move / copy
    ('{"a":{"b":1}}', [{"op": "move", "from": "/a", "path": "/a"}]),
    ('{"a":{"b":1}}', [{"op": "move", "from": "/a", "path": "/a/b"}]),
    ('{"a":{"b":1}}', [{"op": "move", "from": "/a", "path": "/ab"}]),
    ('{"a":1}', [{"op": "move", "from": "/x", "path": "/x"}]),
    ('[1,2,3]', [{"op": "move", "from": "/0", "path": "/-"}]),
    ('[1,2,3]', [{"op": "move", "from": "/0", "path": "/2"}]),
    ('[1,2,3]', [{"op": "move", "from": "/2", "path": "/0"}]),
    ('{"a":[1]}', [{"op": "copy", "from": "/a", "path": "/b"}, {"op": "add", "path": "/b/-", "value": 2}]),
    ('{"a":1}', [{"op": "copy", "from": "", "path": "/b"}]),
    ('{"a":1}', [{"op": "move", "from": "", "path": "/b"}]),
    ('{"a":1}', [{"op": "move", "from": "/a", "path": ""}]),
    # '-' rules
    ('[1]', [{"op": "remove", "path": "/-"}]), ('[1]', [{"op": "replace", "path": "/-", "value": 0}]),
    ('[[1]]', [{"op": "add", "path": "/-/0", "value": 0}]), ('[1]', [{"op": "test", "path": "/-", "value": 1}]),
    ('[1]', [{"op": "copy", "from": "/-", "path": "/0"}]), ('{"a":1}', [{"op": "add", "path": "/-", "value": 2}]),
    ('[1,2]', [{"op": "add", "path": "/01", "value": 0}]), ('[1,2]', [{"op": "add", "path": "/2", "value": 3}]),
    ('[1,2]', [{"op": "add", "path": "/3", "value": 3}]),
    # test equality corner cases
    ('{"a":1}', [{"op": "test", "path": "/a", "value": 1.0}]),
    ('{"a":-0.0}', [{"op": "test", "path": "/a", "value": 0}]),
    ('{"a":{"x":1,"y":2}}', [{"op": "test", "path": "/a", "value": {"y": 2, "x": 1}}]),
    ('{"a":[1,2]}', [{"op": "test", "path": "/a", "value": [2, 1]}]),
    ('{"a":9007199254740993}', [{"op": "test", "path": "/a", "value": 9007199254740992}]),
    ('{"a":9223372036854775807}', [{"op": "test", "path": "/a", "value": 9223372036854775806}]),
    ('{"a":18446744073709551615}', [{"op": "test", "path": "/a", "value": 18446744073709551614}]),
    ('{"a":null}', [{"op": "test", "path": "/a", "value": None}]),
    ('{"a":1}', [{"op": "test", "path": "/b", "value": None}]),
    ('{"a":"1"}', [{"op": "test", "path": "/a", "value": 1}]),
    # atomicity: second op fails
    ('{"a":1}', [{"op": "add", "path": "/b", "value": 2}, {"op": "remove", "path": "/zz"}]),
    # malformed operations
    ('{"a":1}', [{"op": "add", "path": "/b"}]), ('{"a":1}', [{"op": "bogus", "path": "/b"}]),
    ('{"a":1}', [{"op": "add", "path": "b", "value": 1}]), ('{"a":1}', [{"path": "/b", "value": 1}]),
    ('{"a":1}', [{"op": "add", "path": "/b", "value": 1, "extra": True}]),
    ('{"a":1}', [{"op": "replace", "path": "", "value": [1]}]), ('{"a":1}', [{"op": "remove", "path": ""}]),
    ('{"a":1}', [{"op": "add", "path": "", "value": 5}]), ('{"a":1}', {"op": "add", "path": "/b", "value": 1}),
    ('{"a":1}', [{"op": "add", "path": "/a~2", "value": 1}]), ('{"a":1}', [{"op": "add", "path": "/x/y", "value": 1}]),
    ('{"a":1}', [{"op": 5, "path": "/b", "value": 1}]),
]


def rand_key():
    return R.choice(["a", "b", "c", "d", "a/b", "~", "~1", "", "0", "-", "x~0y", "\u00e9", "k" + str(R.randrange(30))])


def rand_val(depth):
    t = R.randrange(9 if depth < 4 else 5)
    if t == 0:
        return None
    if t == 1:
        return R.choice([True, False])
    if t == 2:
        return R.choice([0, 1, -1, 2.5, 1e300, -0.5, R.randrange(-1000, 1000)])
    if t in (3, 4):
        return R.choice(["", "x", "y", "/", "~"])
    if t in (5, 6):
        return [rand_val(depth + 1) for _ in range(R.randrange(0, 6))]
    return {rand_key(): rand_val(depth + 1) for _ in range(R.randrange(0, 6))}


def mutate(v, depth=0):
    if R.random() < 0.15:
        return rand_val(depth)
    if isinstance(v, list):
        v = [mutate(x, depth + 1) if R.random() < 0.5 else x for x in v]
        for _ in range(R.randrange(0, 3)):
            op = R.randrange(3)
            if op == 0:
                v.insert(R.randrange(len(v) + 1), rand_val(depth + 1))
            elif op == 1 and v:
                v.pop(R.randrange(len(v)))
            elif op == 2 and v:
                R.shuffle(v)
        return v
    if isinstance(v, dict):
        v = {k: (mutate(x, depth + 1) if R.random() < 0.5 else x) for k, x in v.items()}
        for _ in range(R.randrange(0, 3)):
            if R.random() < 0.5:
                v[rand_key()] = rand_val(depth + 1)
            elif v:
                del v[R.choice(list(v))]
        return v
    return v


def gen_diff(path, n=2000):
    with open(path, "w") as f:
        for _ in range(n):
            a = {rand_key(): rand_val(1) for _ in range(R.randrange(1, 7))}
            b = mutate(json.loads(json.dumps(a)))
            f.write(hx(json.dumps(a)) + " " + hx(json.dumps(b)) + "\n")
    return n


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    print("numfmt", gen_numfmt(os.path.join(out, "numfmt.txt")))
    print("numparse", gen_numparse(os.path.join(out, "numparse.hex")))
    print("syntax/strict", gen_syntax(os.path.join(out, "syntax.hex"), os.path.join(out, "strict.hex")))
    with open(os.path.join(out, "ptr.txt"), "w") as f:
        for d, p in PTR:
            f.write(hx(d) + " " + hx(p) + "\n")
    with open(os.path.join(out, "patch.txt"), "w") as f:
        for d, p in PATCH:
            f.write(hx(d) + " " + hx(json.dumps(p)) + "\n")
    print("ptr", len(PTR), "patch", len(PATCH))
    print("diff", gen_diff(os.path.join(out, "diff.txt")))


if __name__ == "__main__":
    main()
