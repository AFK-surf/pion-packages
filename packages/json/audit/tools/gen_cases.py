#!/usr/bin/env python3
"""Deterministic case generator for the packages/json red-team audit.

usage: gen_cases.py <out_dir> [<JSONTestSuite test_parsing dir>]

Writes (one case per line, inputs hex-encoded so any byte sequence survives):
  syntax.hex    hand-written RFC 8259 / UTF-8 / surrogate / number-grammar vectors + 6,000 mutated docs
  jsonts.hex    every nst/JSONTestSuite test_parsing file (`<hex>\t<name>`), when the dir is given
  numparse.hex  30,000+ number literals: strtod torture points, exact binary64 midpoints,
                subnormal/overflow edges, 400..800-digit decimals, i64/u64 boundaries, random doubles
  numfmt.txt    30,000 IEEE-754 bit patterns for Number::toString / round-trip checks
  jcs.hex       RFC 8785 examples + 3,000 random documents with adversarial keys and numbers
  ptr.txt       `<hex doc>\t<hex pointer>`: RFC 6901 examples + 3,000 random (doc, pointer) pairs
"""
import json
import os
import random
import struct
import sys
from decimal import Decimal, getcontext
from fractions import Fraction

getcontext().prec = 1200
R = random.Random(0x5EED_150)


def hx(b):
    if isinstance(b, str):
        b = b.encode("utf-8", "surrogatepass")
    return b.hex()


def f2b(x):
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def b2f(b):
    return struct.unpack("<d", struct.pack("<Q", b))[0]


# ---------------------------------------------------------------------------------------------
# syntax
# ---------------------------------------------------------------------------------------------
SYNTAX = [
    # numbers: RFC 8259 §6 grammar
    "0", "-0", "-0.0", "0.0", "1", "-1", "01", "-01", "00", "+1", "1.", ".1", "-.1", "1e", "1e+", "1e-",
    "1E5", "1e05", "1.5e+05", "-", "--1", "0x10", "1_000", "Infinity", "-Infinity", "NaN", "1.0e", "2.e3",
    "1e1.5", "0e", "0e0", "-0e-0", "1ee2", "1e+-2", "123abc", "0.0000", "[1,]", "[-]", "[0-1]",
    # literals
    "true", "false", "null", "True", "nul", "nulll", "truee", "tru", "[true false]", "NULL",
    # structure
    "", " ", "[]", "{}", "[", "]", "{", "}", "[[]", "[]]", "{\"a\":1,}", "[1,2,]", "{,}", "[,]", "[,1]",
    "{\"a\" 1}", "{\"a\":}", "{a:1}", "{'a':1}", "['a']", "{\"a\":1 \"b\":2}", "[1 2]", "{\"a\":1}x",
    "[1]]", "1 2", "\"a\" \"b\"", "{}{}", "[]  ", "  []", "\t\n\r []\t\n\r ", "[\u000b]", "[\u000c]",
    "\u00a0[]", "[]\u00a0", "\ufeff[]", "\ufeff", "//c\n[]", "/*c*/[]", "[]//c", "[1/*c*/]", "#[]",
    "{\"a\":1,\"a\":2}", "{\"a\":1,\"\\u0061\":2}", "{\"a\":{\"b\":1,\"b\":2}}",
    # strings / escapes
    "\"\"", "\"abc\"", "\"\\a\"", "\"\\x41\"", "\"\\v\"", "\"\\'\"", "\"\\0\"", "\"\\u\"", "\"\\u12\"",
    "\"\\u12G4\"", "\"\\U0041\"", "\"\\u0041\"", "\"\\/\"", "\"\\b\\f\\n\\r\\t\\\"\\\\\"", "\"\\",
    "\"\\uD800\"", "\"\\uDFFF\"", "\"\\uDC00\\uD800\"", "\"\\uD83D\\uDE00\"", "\"\\ud83d\\ude00\"",
    "\"\\uD83D\"", "\"\\uD83Dx\"", "\"\\uD83D\\u0041\"", "\"\\uD83D\\uD83D\"", "\"\\uD83D\\\"",
    "\"\\uD83D\\uDE0\"", "\"\\uDBFF\\uDFFF\"", "\"\\u0000\"", "\"\\u001f\"", "\"\\uFFFF\"", "\"\\uFFFE\"",
    "\"\\uD800\\uDC00\"", "\"a\\uD800\"", "\"\\uD800\\n\"", "'a'", "\"abc", "\"\\\"", "[\"a\\\"]",
]
for c in range(0, 0x20):
    SYNTAX.append('"' + chr(c) + '"')
    SYNTAX.append('["a' + chr(c) + 'b"]')
SYNTAX.append('"\x7f"')
SYNTAX_BYTES = [
    b'"\xff"', b'"\xc0\x80"', b'"\xc1\xbf"', b'"\xe0\x80\x80"', b'"\xe0\x9f\xbf"', b'"\xed\xa0\x80"',
    b'"\xed\xbf\xbf"', b'"\xed\xa0\xbd\xed\xb8\x80"',  # CESU-8 U+1F600
    b'"\xf0\x80\x80\x80"', b'"\xf0\x8f\xbf\xbf"', b'"\xf4\x90\x80\x80"', b'"\xf5\x80\x80\x80"', b'"\xf8\x88\x80\x80\x80"',
    b'"\x80"', b'"\xbf"', b'"\xc2"', b'"\xe2\x82"', b'"\xf0\x9f\x98"', b'"\xc2\x41"', b'"\xe2\x28\xa1"',
    b'"\xf0\x9f\x98\x80"', b'"\xef\xbf\xbf"', b'"\xf4\x8f\xbf\xbf"', b'"\xc2\x80"', b'"\xe0\xa0\x80"',
    b'\xef\xbb\xbf{}', b'[\xff]', b'[1]\xff', b'\xff', b'{"\xff":1}', b'"a\x00b"', b'[1]\x00',
]


def random_doc(depth=0, budget=None):
    t = R.random()
    if depth > 4 or t < 0.35:
        k = R.randrange(8)
        if k == 0:
            return R.choice([None, True, False])
        if k == 1:
            return R.randrange(-10**R.randrange(1, 25), 10**R.randrange(1, 25))
        if k == 2:
            return b2f(R.getrandbits(64)) if R.random() < 0.3 else R.uniform(-1e6, 1e6)
        if k == 3:
            return R.choice([0.0, -0.0, 1.0, 1e21, 1e-7, 2**53 + 1, -(2**63), 2**64, 5e-324])
        return random_str()
    if t < 0.65:
        return [random_doc(depth + 1) for _ in range(R.randrange(5))]
    return {random_str(): random_doc(depth + 1) for _ in range(R.randrange(5))}


ALPH = ["a", "b", "\"", "\\", "/", "\n", "\x00", "\x1f", "\x7f", "é", "€", "\u2028", "\ue000", "\uffff",
        "\U0001F600", "\U00010000", "\U0010FFFF", "~", "0", "1"]


def random_str():
    return "".join(R.choice(ALPH) for _ in range(R.randrange(5)))


def dumps(v, ascii_):
    s = json.dumps(v, ensure_ascii=ascii_)
    return s.replace("Infinity", "1e400").replace("NaN", "0")


def mutate(b):
    b = bytearray(b)
    for _ in range(R.randrange(1, 4)):
        op = R.randrange(4)
        pos = R.randrange(len(b) + 1)
        if op == 0 and b:
            del b[min(pos, len(b) - 1)]
        elif op == 1:
            b[pos:pos] = bytes([R.choice(b'{}[],:"\\ 0-+.eE1tfnu\x00\x1f\x7f\xff\xc3\xed')])
        elif op == 2 and b:
            b[min(pos, len(b) - 1)] = R.randrange(256)
        else:
            b[pos:pos] = R.choice([b"\\u", b"\\uD800", b"\\uDC00", b"1e", b"-0", b",", b"//", b"\xef\xbb\xbf"])
    return bytes(b)


def gen_syntax():
    out = [hx(s) for s in SYNTAX] + [b.hex() for b in SYNTAX_BYTES]
    for _ in range(3000):
        out.append(hx(dumps(random_doc(), R.random() < 0.5)))
    for _ in range(3000):
        out.append(mutate(dumps(random_doc(), R.random() < 0.5).encode()).hex())
    return out


# ---------------------------------------------------------------------------------------------
# numbers
# ---------------------------------------------------------------------------------------------
def exact_midpoint(x):
    """(mantissa, exponent) of the exact decimal midpoint between finite positive double x and its successor."""
    m = (Fraction(x) + Fraction(b2f(f2b(x) + 1))) / 2
    d = (Decimal(m.numerator) / Decimal(m.denominator)).normalize()
    mant, ex = format(d, "e").split("e")
    if "." not in mant:
        mant += ".0"
    return mant, ex


def gen_numparse():
    out = []
    fixed = [
        "-9223372036854775808", "9223372036854775807", "-9223372036854775809", "9223372036854775808",
        "9007199254740992", "9007199254740993", "18446744073709551615", "18446744073709551616",
        "-18446744073709551616", "0", "-0", "-0.0", "0.0", "1e0", "1.0", "1E0", "1e-0", "1e+0", "-0e0",
        "1e400", "-1e400", "1e309", "1e308", "1.7976931348623157e308", "1.7976931348623158e308",
        "1.7976931348623159e308", "179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497791.9999999",
        "2.2250738585072011e-308", "2.2250738585072012e-308", "2.2250738585072014e-308",
        "2.2250738585072009e-308", "4.9406564584124654e-324", "5e-324", "2.4703282292062327e-324",
        "2.4703282292062328e-324", "2.4703282292062327208828439643411068618252990130716238221279284125033775364e-324",
        "1e-324", "3e-324", "7.4109846876186982e-324", "1e-400", "-1e-400", "0.1", "0.2", "0.3",
        "1.00000000000000011102230246251565404236316680908203125",
        "1.00000000000000011102230246251565404236316680908203124",
        "1.00000000000000011102230246251565404236316680908203126",
        "9007199254740993.0", "9007199254740993.000000000000000000000000001", "123456789012345678901234567890",
        "1e23", "8.533e+68", "4.1006e-184", "9.998e+307", "9.9538452227e-280", "6.47660115e-260",
        "7.4e+47", "5.92e+48", "7.35e+66", "8.32116e+55", "2.4e-324", "2.5e-324",
        "0.000000000000000000000000000000000000000000001e300", "1" + "0" * 400 + "e-400",
        "0." + "0" * 400 + "1e400", "1e99999999", "1e-99999999", "0e99999999", "1e2147483648",
        "-1e2147483648", "1e-2147483649", "0." + "0" * 330 + "1e10000",
    ]
    out += fixed
    # 100,000-digit literals (DoS / linear-time check)
    out.append("9" * 100000)
    out.append("0." + "1" * 100000)
    out.append("1" + "0" * 100000 + "e-100000")
    # exact midpoints (ties-to-even both directions) and neighbours
    for _ in range(3000):
        bits = R.choice([R.getrandbits(63) & 0x7FEFFFFFFFFFFFFE, R.randrange(1, 1 << 52), R.randrange(1, 1 << 20)])
        x = b2f(bits)
        if x == 0 or x != x:
            continue
        mant, ex = exact_midpoint(x)
        out.append(mant + "e" + ex)
        out.append(mant + "1e" + ex)  # just above the midpoint
        if mant[-1] in "123456789":  # just below the midpoint
            out.append(mant[:-1] + str(int(mant[-1]) - 1) + "9" * 20 + "e" + ex)
    # random doubles in several renderings
    for _ in range(12000):
        x = b2f(R.getrandbits(64))
        if x != x or x in (float("inf"), float("-inf")):
            continue
        out.append(R.choice([repr(x), "%.17g" % x, "%.20e" % x, "%.30e" % x, "%.40g" % x]))
    for _ in range(4000):
        x = R.uniform(-1e5, 1e5)
        out.append(R.choice([repr(x), "%.3f" % x, "%.10f" % x, "%.25f" % x]))
    # long random decimals (400..800 digits) around random exponents
    for _ in range(2000):
        nd = R.randrange(400, 801)
        d = str(R.randrange(1, 10)) + "".join(R.choice("0123456789") for _ in range(nd - 1))
        e = R.randrange(-760 - nd, 320 - nd)
        out.append(R.choice([d + "e" + str(e), d[:1] + "." + d[1:] + "e" + str(e + nd - 1)]))
    # subnormal / normal boundary sweep and big integers near 2^53 / i64 / u64
    for k in range(-1080, -1018):
        x = 2.0 ** k if k >= -1074 else 0.0
        if x:
            out.append(repr(x))
            out.append("%.25e" % x)
    for base in (2**53, 2**63, 2**64, 10**19, 10**20):
        for dlt in range(-3, 4):
            for sgn in ("", "-"):
                out.append(sgn + str(base + dlt))
                out.append(sgn + str(base + dlt) + ".0")
                out.append(sgn + str(base + dlt) + "e0")
    for k in range(-30, 30):
        out.append("1e%d" % k)
        out.append("1.5e%+d" % k)
    return out


def gen_numfmt():
    out = set()
    special = [0.0, -0.0, 1.0, -1.0, 0.1, 1e20, 1e21, 1e-6, 1e-7, 1e22, 1e23, 9.999999999999999e20,
               1.0000000000000001e21, 9.999999999999999e-7, 1.0000000000000002e-6, 5e-324, 2.2250738585072014e-308,
               1.7976931348623157e308, 2.0**53, 2.0**53 + 2, 2.0**63, 2.0**64, 123456789012345680000.0,
               4.35, 0.000001, 0.0000001, 1e300, 333333333.33333329, 1e30, 4.50, 2e-3, 1e-27,
               float("inf"), float("-inf"), float("nan")]
    for x in special:
        out.add(f2b(x))
    for k in range(-330, 310):
        try:
            x = float("1e%d" % k)
        except OverflowError:
            continue
        for d in (-2, -1, 0, 1, 2):
            b = f2b(x) + d
            if 0 <= b < 0x7FF0000000000000:
                out.add(b)
                out.add(b | (1 << 63))
    while len(out) < 30000:
        k = R.randrange(4)
        if k == 0:
            out.add(R.getrandbits(64))
        elif k == 1:
            out.add(f2b(round(R.uniform(-1e7, 1e7), R.randrange(0, 8))))
        elif k == 2:
            out.add(f2b(float(R.randrange(1, 10**R.randrange(1, 23)))))
        else:
            out.add(R.randrange(1, 1 << 52))  # subnormals
    return ["%016x" % b for b in sorted(out)]


# ---------------------------------------------------------------------------------------------
# JCS
# ---------------------------------------------------------------------------------------------
RFC8785 = [
    # RFC 8785 §3.2.2 example (input as printed in the RFC)
    '{"numbers": [333333333.33333329, 1E30, 4.50, 2e-3, 0.000000000000000000000000001], '
    '"string": "\\u20ac$\\u000F\\u000aA\'\\u0042\\u0022\\u005c\\\\\\"\\/", "literals": [null, true, false]}',
    # §3.2.3 sorting example
    '{"\\u20ac": "Euro Sign", "\\r": "Carriage Return", "\\ufb33": "Hebrew Letter Dalet With Dagesh", '
    '"1": "One", "\\ud83d\\ude00": "Emoji: Grinning Face", "\\u0080": "Control", "\\u00f6": "Latin Small Letter O With Diaeresis"}',
    '{"\\ue000":1,"\\ud800\\udc00":2,"\\uffff":3,"\\udbff\\udfff":4,"\\uff61":5,"\\ud83d\\ude00":6}',
    '[1e20, 1e21, 1e-6, 1e-7, -0.0, 0.0, -0, 1.0, 1e2, 1.00, 100, 5e-324, 1.7976931348623157e308]',
    '[9007199254740992, 9007199254740993, 9223372036854775807, -9223372036854775808, 18446744073709551615, 18446744073709551616]',
    '[1e400]', '[-1e400]', '{"a":1e999}', '[123456789012345678901234567890]', '[1E400, 1e400, 10e399]',
    '"\\u0000\\u0001\\u001f\\u007f\\u0080\\u2028\\u2029\\b\\f\\n\\r\\t\\"\\\\\\/"',
    '{"b":1,"a":2,"a":3}', '{"":0,"\\u0000":1," ":2}',
]


def rand_key():
    pools = [
        lambda: chr(R.randrange(0x20, 0x7F)),
        lambda: chr(R.randrange(0, 0x20)),
        lambda: chr(R.randrange(0x80, 0x800)),
        lambda: chr(R.randrange(0xE000, 0x10000)),
        lambda: chr(R.randrange(0x10000, 0x110000)),
        lambda: chr(R.choice([0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF, 0xFB33, 0x1F600, 0xFF61])),
    ]
    return "".join(R.choice(pools)() for _ in range(R.randrange(0, 4)))


def rand_num_lit():
    k = R.randrange(6)
    if k == 0:
        return repr(b2f(R.getrandbits(64) & 0x7FEFFFFFFFFFFFFF))
    if k == 1:
        return str(R.randrange(-2**70, 2**70))
    if k == 2:
        return R.choice(["-0", "-0.0", "0.0", "1e21", "1e20", "1e-7", "1E+3", "4.50", "2e-3", "1e400",
                         "9007199254740993", "18446744073709551616", "0.1e1", "100e-2"])
    if k == 3:
        return str(R.randrange(-2**53, 2**53))
    return "%.17g" % R.uniform(-1e30, 1e30)


def rand_jcs_doc(depth=0):
    t = R.random()
    if depth > 3 or t < 0.4:
        k = R.randrange(4)
        if k == 0:
            return rand_num_lit()
        if k == 1:
            return json.dumps(rand_key(), ensure_ascii=R.random() < 0.5)
        return R.choice(["null", "true", "false"])
    if t < 0.6:
        return "[" + ",".join(rand_jcs_doc(depth + 1) for _ in range(R.randrange(4))) + "]"
    return "{" + ",".join(json.dumps(rand_key(), ensure_ascii=R.random() < 0.5) + ":" + rand_jcs_doc(depth + 1)
                          for _ in range(R.randrange(6))) + "}"


def gen_jcs():
    out = [hx(s) for s in RFC8785]
    for _ in range(3000):
        out.append(hx(rand_jcs_doc()))
    return out


# ---------------------------------------------------------------------------------------------
# RFC 6901 pointer
# ---------------------------------------------------------------------------------------------
RFC6901_DOC = '{"foo":["bar","baz"],"":0,"a/b":1,"c%d":2,"e^f":3,"g|h":4,"i\\\\j":5,"k\\"l":6," ":7,"m~n":8,"~1":9,"01":10}'
RFC6901_PTRS = ["", "/foo", "/foo/0", "/", "/a~1b", "/c%d", "/e^f", "/g|h", "/i\\j", "/k\"l", "/ ", "/m~0n",
                "/~01", "/01", "/foo/01", "/foo/-", "/foo/2", "/foo/00", "/foo/+1", "/foo/-1", "/foo/1/x", "/foo/ 1",
                "/foo/1e0", "/foo/18446744073709551616", "/foo/4294967296", "/nope", "/foo/0/0"]


def esc_tok(t):
    return t.replace("~", "~0").replace("/", "~1")


def gen_ptr():
    out = [hx(RFC6901_DOC) + "\t" + hx(p) for p in RFC6901_PTRS]
    for _ in range(3000):
        doc = random_doc()
        text = dumps(doc, False)
        # walk a random existing path (sometimes break it)
        toks = []
        cur = doc
        while isinstance(cur, (list, dict)) and (cur) and R.random() < 0.8:
            if isinstance(cur, list):
                i = R.randrange(len(cur))
                toks.append(str(i))
                cur = cur[i]
            else:
                k = R.choice(list(cur))
                toks.append(esc_tok(k))
                cur = cur[k]
        if R.random() < 0.3 and toks:
            toks[-1] = R.choice(["-", "0" + toks[-1], toks[-1] + "x", "", "~0~1"])
        out.append(hx(text) + "\t" + hx("".join("/" + t for t in toks)))
    return out


def main():
    od = sys.argv[1]
    os.makedirs(od, exist_ok=True)

    def w(name, rows):
        with open(os.path.join(od, name), "w") as f:
            f.write("\n".join(rows) + "\n")
        print(f"{name}: {len(rows)}")

    w("syntax.hex", gen_syntax())
    w("numparse.hex", [hx(s) for s in gen_numparse()])
    w("numfmt.txt", gen_numfmt())
    w("jcs.hex", gen_jcs())
    w("ptr.txt", gen_ptr())
    if len(sys.argv) > 2:
        d = sys.argv[2]
        rows = []
        for name in sorted(os.listdir(d)):
            if name.endswith(".json"):
                rows.append(open(os.path.join(d, name), "rb").read().hex() + "\t" + name)
        w("jsonts.hex", rows)


if __name__ == "__main__":
    main()
