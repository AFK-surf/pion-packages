"""Generate the adversarial differential corpus (BSON 1.1 binary, Extended JSON v2, Decimal128).

usage: gen_vectors.py <out.tsv> [seed] [n_fuzz]     -> lines `<category>\t<op>\t<hex payload>`
Deterministic for a given seed. Categories group the report; ops are the probe ops (B/J/D/X).
"""
import json
import random
import struct
import sys

out_path = sys.argv[1]
seed = int(sys.argv[2]) if len(sys.argv) > 2 else 20261123
n_fuzz = int(sys.argv[3]) if len(sys.argv) > 3 else 2000
rng = random.Random(seed)
V = []


def add(cat, op, payload):
    if isinstance(payload, str):
        payload = payload.encode("utf-8", "surrogatepass")
    V.append((cat, op, payload))


def i32(v):
    return struct.pack("<i", v) if -2**31 <= v < 2**31 else struct.pack("<I", v & 0xFFFFFFFF)


def doc(body):
    return i32(len(body) + 5) + body + b"\x00"


def el(t, key, payload):
    return bytes([t]) + key + b"\x00" + payload


def bstr(s, declared=None):
    return i32(len(s) + 1 if declared is None else declared) + s + b"\x00"


# ---------------------------------------------------------------- BSON binary
B = lambda cat, b: add(cat, "B", b)

# envelope
for body, name in [(b"", "empty")]:
    pass
for raw in [b"", b"\x05\x00\x00", b"\x04\x00\x00\x00\x00", b"\x05\x00\x00\x00\x01", b"\xff\xff\xff\x7f\x00",
            b"\xff\xff\xff\xff\x00", b"\x00\x00\x00\x80\x00", b"\x06\x00\x00\x00\x00", b"\x05\x00\x00\x00\x00\x00"]:
    B("envelope", raw)
# declared root length too large/small with a valid body
inner = el(0x10, b"a", i32(1))
for d in [-1, 0, 4, 5, len(inner) + 4, len(inner) + 6, 0x7FFFFFFF]:
    B("envelope", i32(d) + inner + b"\x00")

# length-prefixed element types with adversarial lengths (signed-overflow hunt)
EVIL = [-2**31, -2, -1, 0, 1, 2, 3, 4, 5, 13, 14, 0x7FFFFFFF, 0x7FFFFFFE, 0x7FFFFFF0, 0x7FFFFF00, 0x40000000,
        0x7FFFFFFF - 5, 0x7FFFFFFF - 9, 0x7FFFFFFF - 13]
for L in EVIL:
    for t in (0x02, 0x0D, 0x0E):
        B("len_string", doc(el(t, b"a", i32(L) + b"x\x00")))
    B("len_dbpointer", doc(el(0x0C, b"a", i32(L) + b"x\x00" + b"\x01" * 12)))
    B("len_binary", doc(el(0x05, b"a", i32(L) + b"\x00" + b"\xaa\xbb")))
    B("len_binary_old", doc(el(0x05, b"a", i32(L) + b"\x02" + i32(2) + b"\xaa\xbb")))
    B("len_binary_old", doc(el(0x05, b"a", i32(6) + b"\x02" + i32(L) + b"\xaa\xbb")))
    for t in (0x03, 0x04):
        B("len_subdoc", doc(el(t, b"a", i32(L) + b"\x00")))
    code = bstr(b"x")
    scope = doc(b"")
    B("len_cws", doc(el(0x0F, b"a", i32(L) + code + scope)))
    B("len_cws", doc(el(0x0F, b"a", i32(4 + len(code) + len(scope)) + i32(L) + b"x\x00" + scope)))
    B("len_cws", doc(el(0x0F, b"a", i32(4 + len(code) + len(scope)) + code + i32(L) + b"\x00")))
# nested length crossing the outer boundary
B("len_subdoc", doc(el(0x03, b"a", doc(el(0x10, b"b", i32(1)))[:-1] + b"\x01")))
sub = doc(el(0x10, b"b", i32(1)))
B("len_subdoc", doc(el(0x03, b"a", i32(len(sub) + 1) + sub[4:])))
B("len_subdoc", doc(el(0x03, b"a", i32(len(sub) - 1) + sub[4:])))

# strings: embedded NUL (legal in BSON strings), UTF-8 edge cases
UTF8 = [b"", b"a\x00b", b"\x00", b"\x00\x00\x00", "é".encode(), "☆".encode(), "😀".encode(), b"\xef\xbf\xbf",
        b"\xf4\x8f\xbf\xbf", b"\xf4\x90\x80\x80", b"\xc0\x80", b"\xc1\xbf", b"\xe0\x80\x80", b"\xed\xa0\x80",
        b"\xed\xbf\xbf", b"\xf0\x80\x80\x80", b"\xf5\x80\x80\x80", b"\xff", b"\x80", b"\xc3", b"\xe2\x98",
        b"\xf0\x9f\x98", b"a\xc3", b"\x7f", b"\x1f", b"\"\\/"]
for s in UTF8:
    for t in (0x02, 0x0D, 0x0E):
        B("string_utf8", doc(el(t, b"a", bstr(s))))
    if b"\x00" not in s:
        B("key_utf8", doc(el(0x10, s, i32(1))))
        B("regex_utf8", doc(el(0x0B, b"a", s + b"\x00" + b"\x00")))
        B("regex_utf8", doc(el(0x0B, b"a", b"x\x00" + s + b"\x00")))
    B("dbpointer_utf8", doc(el(0x0C, b"a", bstr(s) + b"\x01" * 12)))
    B("cws_utf8", doc(el(0x0F, b"a", i32(4 + len(bstr(s)) + 5) + bstr(s) + doc(b""))))

# regex options: order, duplicates, unknown flags
for opts in [b"", b"i", b"mi", b"xsmli", b"ii", b"zi", b"u", b"imsxlu", b"ba", b"\xc3\xa9"]:
    B("regex_options", doc(el(0x0B, b"a", b"p\x00" + opts + b"\x00")))

# binary subtypes and sizes
for st in list(range(0, 0x0B)) + [0x7F, 0x80, 0xFF]:
    for n in (0, 1, 15, 16, 17):
        payload = bytes(rng.randrange(256) for _ in range(n))
        if st == 0x02:
            B("binary_subtype", doc(el(0x05, b"a", i32(n + 4) + b"\x02" + i32(n) + payload)))
        else:
            B("binary_subtype", doc(el(0x05, b"a", i32(n) + bytes([st]) + payload)))
# vector (0x09) malformed headers
for payload in [b"", b"\x27", b"\x27\x00\x00", b"\x27\x01\x00\x00\x00\x00", b"\x03\x00", b"\x03\x01\x7f",
                b"\x10\x00", b"\x10\x08\xff", b"\x10\x01\x00", b"\x99\x00"]:
    B("binary_vector", doc(el(0x05, b"a", i32(len(payload)) + b"\x09" + payload)))

# array keys
for keys in [[b"0"], [b""], [b"1"], [b"00"], [b"-1"], [b"a"], [b"0", b"0"], [b"0", b"2"], [b"1", b"0"],
             [b"0", b"1", b"2", b"3", b"4", b"5", b"6", b"7", b"8", b"9", b"10"], [b"0", b"01"], [b"+0"], [b" 0"]]:
    body = b"".join(el(0x10, k, i32(7)) for k in keys)
    B("array_keys", doc(el(0x04, b"a", doc(body))))

# booleans / unknown types / zero-length payloads
for v in (0, 1, 2, 0x80, 0xFF):
    B("bool", doc(el(0x08, b"a", bytes([v]))))
for t in (0x14, 0x15, 0x20, 0x7E, 0x80, 0xFE, 0x00):
    B("unknown_type", doc(el(t, b"a", b"")))

# DateTime boundaries
for ms in [0, 1, -1, 999, -999, 1000, -1000, 253402300799999, 253402300800000, -62135596800000,
           -62135596800001, -62167219200000, 2**63 - 1, -2**63, 2**53, -2**53, 1752914535321, 951782400000,
           951868800000, 4107542400000, 32503680000000]:
    B("datetime", doc(el(0x09, b"a", struct.pack("<q", ms))))

# Doubles: specials, subnormals, shortest-roundtrip stress, random
DBL = [0.0, -0.0, 1.0, -1.0, 0.1, 0.2, 0.30000000000000004, 1 / 3, 2 / 3, 1e21, 1e22, 1e23, 1e-5, 1e-6, 1e-7,
       5e-324, -5e-324, 2.2250738585072014e-308, 2.225073858507201e-308, 1.7976931348623157e308,
       -1.7976931348623157e308, 9007199254740992.0, 9007199254740993.0, 9007199254740994.0,
       123456789012345678.0, 1.2345678921232e18, 1e15, 1e16, 1e17, 100.0, 1e100, 1e-100, 4.35, 0.000001,
       0.0000001, 1234567.0, 12345678901234567890.0, 2.5, 1.5e300, 3.0e-310, 1.0001220703125, 0.1 + 0.7]
for d in DBL:
    B("double_value", doc(el(0x01, b"d", struct.pack("<d", d))))
for bits in [0x7FF8000000000000, 0xFFF8000000000000, 0x7FF0000000000001, 0x7FF4000000000000, 0xFFF0000000000001,
             0x7FF8000000000001, 0x7FFFFFFFFFFFFFFF, 0x7FF0000000000000, 0xFFF0000000000000, 0x0000000000000001,
             0x8000000000000001, 0x000FFFFFFFFFFFFF, 0x0010000000000000]:
    B("double_bits", doc(el(0x01, b"d", struct.pack("<Q", bits))))
for _ in range(400):
    bits = rng.getrandbits(64)
    if (bits >> 52) & 0x7FF == 0x7FF:
        continue
    B("double_random", doc(el(0x01, b"d", struct.pack("<Q", bits))))
for _ in range(200):
    d = rng.choice([rng.random() * 10 ** rng.randint(-30, 30), float(rng.randint(-2**60, 2**60)),
                    round(rng.random() * 1000, rng.randint(0, 6))])
    B("double_decimalish", doc(el(0x01, b"d", struct.pack("<d", d))))

# Int32 / Int64 / Timestamp boundaries
for v in (0, -1, 2**31 - 1, -2**31):
    B("int32", doc(el(0x10, b"i", i32(v))))
for v in (0, -1, 2**63 - 1, -2**63, 2**53 + 1, 2**31, -2**31 - 1):
    B("int64", doc(el(0x12, b"i", struct.pack("<q", v))))
for t, i in [(0, 0), (2**32 - 1, 2**32 - 1), (2**31, 1), (1, 2**31)]:
    B("timestamp", doc(el(0x11, b"t", struct.pack("<II", i, t))))

# duplicate keys (BSON allows; check preservation on decode -> encode)
B("duplicate_keys", doc(el(0x10, b"a", i32(1)) + el(0x10, b"a", i32(2))))
B("duplicate_keys", doc(el(0x10, b"a", i32(1)) + el(0x02, b"a", bstr(b"x")) + el(0x10, b"b", i32(3))))

# code_w_scope structure
code, scope = bstr(b"x"), doc(el(0x10, b"y", i32(1)))
B("cws", doc(el(0x0F, b"a", i32(4 + len(code) + len(scope)) + code + scope)))
B("cws", doc(el(0x0F, b"a", i32(4 + len(code) + len(scope) + 1) + code + scope + b"\x00")))
B("cws", doc(el(0x0F, b"a", i32(4 + len(code) + 5) + code + doc(b""))))
B("cws", doc(el(0x0F, b"a", i32(4 + len(code) + len(scope)) + code + scope[:-1] + b"\x01")))
B("cws", doc(el(0x0F, b"a", i32(4 + len(code) + len(scope)) + code + scope) + el(0x10, b"z", i32(2))))

# Decimal128 inside BSON (random bit patterns incl. non-canonical / NaN payloads)
for _ in range(150):
    hi = rng.getrandbits(64)
    lo = rng.getrandbits(64)
    B("decimal_bson", doc(el(0x13, b"d", struct.pack("<QQ", lo, hi))))

# mutation fuzz of well-formed seeds
SEEDS = [v[2] for v in V if v[1] == "B" and len(v[2]) > 6]
for k in range(n_fuzz):
    b = bytearray(rng.choice(SEEDS))
    for _ in range(rng.randint(1, 4)):
        m = rng.randrange(5)
        if m == 0:
            p = rng.randrange(len(b)); b[p] = rng.randrange(256)
        elif m == 1:
            p = rng.randrange(len(b)); b[p] ^= 1 << rng.randrange(8)
        elif m == 2 and len(b) > 6:
            p = rng.randrange(len(b) - 4); b[p:p + 4] = i32(rng.choice(EVIL + [rng.randrange(-64, 64)]))
        elif m == 3 and len(b) > 6:
            del b[rng.randrange(4, len(b))]
        else:
            b.insert(rng.randrange(4, len(b)), rng.randrange(256))
    if rng.random() < 0.7 and len(b) >= 4:  # keep envelope length consistent most of the time
        b[0:4] = i32(len(b))
    B("fuzz_mutation", bytes(b))

# ---------------------------------------------------------------- Extended JSON
J = lambda cat, s: add(cat, "J", s)
wrap = lambda v: '{"a":' + v + '}'

for v in ['{"$oid":"65a00102030405060708090a","x":1}', '{"$numberInt":"1","x":1}', '{"x":1,"$numberInt":"1"}',
          '{"$numberLong":"1","x":1}', '{"$numberDouble":"1.0","x":1}', '{"$numberDecimal":"1","x":1}',
          '{"$date":{"$numberLong":"1"},"x":1}', '{"$date":"1970-01-01T00:00:00Z","x":1}',
          '{"$binary":{"base64":"AA==","subType":"00"},"x":1}', '{"$uuid":"12345678-9abc-4def-8123-456789abcdef","x":1}',
          '{"$regularExpression":{"pattern":"a","options":""},"x":1}', '{"$timestamp":{"t":1,"i":1},"x":1}',
          '{"$symbol":"s","x":1}', '{"$dbPointer":{"$ref":"a","$id":{"$oid":"65a00102030405060708090a"}},"x":1}',
          '{"$undefined":true,"x":1}', '{"$minKey":1,"x":1}', '{"$maxKey":1,"x":1}', '{"$code":"c","x":1}',
          '{"$code":"c","$scope":{},"x":1}', '{"$numberInt":"1","$numberLong":"1"}']:
    J("ej_wrapper_extra_field", wrap(v))
for v in ['{"$numberInt":1}', '{"$numberInt":"01"}', '{"$numberInt":"+1"}', '{"$numberInt":" 1"}', '{"$numberInt":"1.0"}',
          '{"$numberInt":"-0"}', '{"$numberInt":"2147483648"}', '{"$numberInt":"-2147483649"}', '{"$numberInt":""}',
          '{"$numberInt":"0x10"}', '{"$numberInt":"1e2"}',
          '{"$numberLong":"9223372036854775807"}', '{"$numberLong":"9223372036854775808"}',
          '{"$numberLong":"-9223372036854775808"}', '{"$numberLong":"-9223372036854775809"}', '{"$numberLong":"+5"}',
          '{"$numberLong":"007"}', '{"$numberLong":"-"}', '{"$numberLong":1}', '{"$numberLong":"١٢"}']:
    J("ej_int", wrap(v))
for s in ["1", "1.", ".5", "-.5", "1e5", "1E+5", "+1.0", "-0", "-0.0", "0.0", "Infinity", "-Infinity", "+Infinity",
          "inf", "-inf", "infinity", "NaN", "-NaN", "nan", "+NaN", " 1.0", "1.0 ", "0x10", "1_0", "", "1e400", "-1e400",
          "1e-400", "4.9e-324", "2.4703282292062328e-324", "1.7976931348623159e308", "00.5", "1.0e", "1..0",
          "123456789012345678901234567890"]:
    J("ej_number_double", wrap(json.dumps({"$numberDouble": s})))
for s in ["1", "-0", "0E+6111", "1E+6145", "1E+6144", "1E-6177", "NaN", "-NaN", "sNaN", "-sNaN", "Inf", "-Inf",
          "Infinity", "+Infinity", ".1", "1.", " 1", "1 ", "1e", "1E-", "١", ""]:
    J("ej_number_decimal", wrap(json.dumps({"$numberDecimal": s})))
for s in ["65a00102030405060708090a", "65A00102030405060708090A", "65a00102030405060708090", "65a00102030405060708090a1",
          "zza00102030405060708090a", "", "65a00102030405060708090é"]:
    J("ej_oid", wrap(json.dumps({"$oid": s})))
J("ej_oid", wrap('{"$oid":1}'))
for s in ["1970-01-01T00:00:00Z", "1970-01-01T00:00:00.000Z", "1970-01-01T00:00:00.1Z", "1970-01-01T00:00:00.1234Z",
          "1970-01-01t00:00:00z", "1970-01-01T00:00:00+00:00", "1970-01-01T00:00:00+0000", "1970-01-01T00:00:00+00",
          "1970-01-01T01:00:00+01:00", "1969-12-31T23:59:59.999Z", "2000-02-29T00:00:00Z", "2001-02-29T00:00:00Z",
          "1900-02-29T00:00:00Z", "9999-12-31T23:59:59.999Z", "10000-01-01T00:00:00Z", "0000-01-01T00:00:00Z",
          "1970-01-01T24:00:00Z", "1970-01-01T23:59:60Z", "1970-01-01 00:00:00Z", "1970-01-01T00:00Z",
          "1970-01-01T00:00:00", "1970-1-01T00:00:00Z", "1970-01-01T00:00:00.Z", "1970-01-01T00:00:00+24:00",
          "1970-01-01T00:00:00-00:30", "1970-01-01T00:00:00+05:30:00", "١970-01-01T00:00:00Z", ""]:
    J("ej_date_iso", wrap(json.dumps({"$date": s})))
for v in ['{"$date":0}', '{"$date":1752914535321}', '{"$date":-1}', '{"$date":1.5}', '{"$date":{"$numberInt":"5"}}',
          '{"$date":{"$numberLong":"9223372036854775807"}}', '{"$date":{"$numberLong":"9223372036854775808"}}',
          '{"$date":{"$numberLong":"1","x":1}}', '{"$date":null}', '{"$date":true}', '{"$date":{"$numberDouble":"1"}}']:
    J("ej_date_other", wrap(v))
for v in ['{"$binary":{"base64":"AA==","subType":"0"}}', '{"$binary":{"base64":"AA==","subType":"000"}}',
          '{"$binary":{"base64":"AA==","subType":"0x00"}}', '{"$binary":{"base64":"AA==","subType":"g0"}}',
          '{"$binary":{"base64":"AA==","subType":"FF"}}', '{"$binary":{"base64":"AA==","subType":"ff"}}',
          '{"$binary":{"base64":"AA==","subType":0}}', '{"$binary":{"base64":"AA","subType":"00"}}',
          '{"$binary":{"base64":"AA=","subType":"00"}}', '{"$binary":{"base64":"A A==","subType":"00"}}',
          '{"$binary":{"base64":"AB==","subType":"00"}}', '{"$binary":{"base64":"-_8=","subType":"00"}}',
          '{"$binary":{"base64":"AA==\\n","subType":"00"}}', '{"$binary":{"base64":"AA==","subType":"00","x":1}}',
          '{"$binary":{"base64":"AA=="}}', '{"$binary":"AA==","$type":"00"}', '{"$binary":"AA==","$type":"0"}',
          '{"$binary":{"base64":"AAAA","subType":"02"}}', '{"$binary":{"base64":"AAAAAAAAAAAAAAAAAAAAAA==","subType":"04"}}',
          '{"$binary":{"base64":"AAAA","subType":"04"}}',
          '{"$binary":{"base64":"AA==","subType":"09"}}', '{"$binary":{"base64":"","subType":"09"}}']:
    J("ej_binary", wrap(v))
for s in ["12345678-9abc-4def-8123-456789abcdef", "12345678-9ABC-4DEF-8123-456789ABCDEF", "123456789abc4def8123456789abcdef",
          "12345678-9abc-4def-8123-456789abcde", "{12345678-9abc-4def-8123-456789abcdef}", "12345678-9abc4def-8123-456789abcdef-",
          "12345678_9abc_4def_8123_456789abcdef", "g2345678-9abc-4def-8123-456789abcdef", ""]:
    J("ej_uuid", wrap(json.dumps({"$uuid": s})))
for v in ['{"$regularExpression":{"pattern":"a","options":"mix"}}', '{"$regularExpression":{"pattern":"a","options":"z"}}',
          '{"$regularExpression":{"pattern":"a","options":"ii"}}', '{"$regularExpression":{"pattern":"a\\u0000b","options":""}}',
          '{"$regularExpression":{"pattern":"a","options":"i\\u0000"}}', '{"$regularExpression":{"options":"","pattern":"a"}}',
          '{"$regex":"a","$options":"i"}', '{"$regex":"a"}', '{"$regex":{"$regularExpression":{"pattern":"a","options":""}}}']:
    J("ej_regex", wrap(v))
for v in ['{"$timestamp":{"t":1,"i":2}}', '{"$timestamp":{"i":2,"t":1}}', '{"$timestamp":{"t":-1,"i":2}}',
          '{"$timestamp":{"t":4294967296,"i":2}}', '{"$timestamp":{"t":4294967295,"i":4294967295}}',
          '{"$timestamp":{"t":1.0,"i":2}}', '{"$timestamp":{"t":"1","i":2}}', '{"$timestamp":{"t":1}}',
          '{"$timestamp":{"t":1,"i":2,"x":3}}', '{"$timestamp":{"t":{"$numberInt":"1"},"i":2}}',
          '{"$timestamp":{"t":1,"t":2}}']:
    J("ej_timestamp", wrap(v))
for v in ['{"$code":"x","$scope":{"a":1}}', '{"$scope":{"a":1},"$code":"x"}', '{"$code":"x","$scope":1}',
          '{"$code":1}', '{"$scope":{}}', '{"$code":"x","$scope":{"$numberInt":"1"}}', '{"$code":"x","$scope":{"$oid":"65a00102030405060708090a"}}',
          '{"$symbol":1}', '{"$undefined":false}', '{"$undefined":1}', '{"$minKey":2}', '{"$minKey":{"$numberInt":"1"}}',
          '{"$maxKey":"1"}', '{"$maxKey":1.0}', '{"$dbPointer":{"$ref":"a","$id":"65a00102030405060708090a"}}',
          '{"$dbPointer":{"$ref":1,"$id":{"$oid":"65a00102030405060708090a"}}}',
          '{"$dbPointer":{"$id":{"$oid":"65a00102030405060708090a"},"$ref":"a"}}',
          '{"$ref":"c","$id":{"$oid":"65a00102030405060708090a"}}', '{"$ref":"c","$id":1,"$db":"d"}', '{"$foo":1}',
          '{"$numberint":"1"}', '{"$NumberInt":"1"}']:
    J("ej_misc_wrappers", wrap(v))
# plain JSON numbers (relaxed typing)
for s in ["0", "-0", "1", "2147483647", "2147483648", "-2147483648", "-2147483649", "9223372036854775807",
          "9223372036854775808", "-9223372036854775808", "-9223372036854775809", "18446744073709551616", "1.0", "-0.0",
          "1e2", "1E400", "-1e400", "1e-400", "0.1", "123456789012345678901234567890", "5e-324", "01", "1.", ".5", "+1",
          "NaN", "Infinity", "0x1"]:
    J("ej_json_number", '{"n":' + s + '}')
# strings and keys
for s in ['"a\\u0000b"', '"\\ud83d\\ude00"', '"\\ud83d"', '"\\ude00"', '"\\ud83dx"', '"\\u00e9"', '"\\/"', '"\\x41"',
          '"a\tb"', '"\\u000"', '"\\U0041"', '" "', '"é"']:
    J("ej_string", '{"s":' + s + '}')
    J("ej_key", '{' + s + ':1}')
for s in ['{"a":1,"a":2}', '{"a":1,"b":2,"a":3}', '{"$oid":"65a00102030405060708090a"}', '[1]', '1', '"x"', '{}', '{} ',
          ' {}', '{}{}', '{"a":1,}', '{"a":[1,]}', '{,}', '{"a" 1}', '{"a":tru}', '{"a":nulll}', "{'a':1}", '{"a":1}\u0000',
          '﻿{}', '{"a":[]}', '{"a":[[]]}', '{"a":{"b":{}}}']:
    J("ej_structure", s)

# ---------------------------------------------------------------- Decimal128
D = lambda cat, s: add(cat, "D", s)
X = lambda cat, b: add(cat, "X", b)
DEC = ["0", "-0", "+0", "0.0", "0.00", "-0.00", "0E+0", "0E-0", "0E+6111", "0E+6112", "0E-6176", "0E-6177",
       "0E+99999999999", "-0E-99999999999", "0E+2147483648", "0.000000000000000000000000000000000000000000000E-6170",
       "1", "-1", "1E+6111", "1E+6144", "1E+6145", "1E-6176", "1E-6177", "10E-6177", "100E-6178",
       "9999999999999999999999999999999999", "99999999999999999999999999999999999", "9999999999999999999999999999999999E+6111",
       "9999999999999999999999999999999999E+6112", "10000000000000000000000000000000000", "10000000000000000000000000000000001",
       "1000000000000000000000000000000000E+6111", "1000000000000000000000000000000000E+6112",
       "1.000000000000000000000000000000000E+6144", "1.000000000000000000000000000000000E+6145",
       "0.0000001", "1E-7", "0.000001", "1E-6", "100.00", "123.456E-7", "1.23E+3", "1E3", "1e3", "1E+3", "1E03",
       "12345678901234567890123456789012345E-1", "1234567890123456789012345678901234.0",
       "1234567890123456789012345678901234.5", "0.1234567890123456789012345678901234",
       "0.12345678901234567890123456789012345", "00000000000000000000000000000000000000001",
       "NaN", "-NaN", "+NaN", "nan", "NAN", "sNaN", "-sNaN", "SNAN", "NaN123", "Inf", "-Inf", "+Inf", "inf",
       "Infinity", "-Infinity", "+Infinity", "INFINITY", "infinite", "Infinit", "1.", ".1", ".", "-.", "E1", "1E", "1E+",
       "1E-", "1E+-1", "--1", "+-1", "1.2.3", "1e1.5", " 1", "1 ", "1_000", "0x1", "١", "", "-", "+"]
for s in DEC:
    D("dec_edge", s)
for _ in range(700):
    digits = "".join(rng.choice("0123456789") for _ in range(rng.choice([1, 2, 5, 15, 33, 34, 35, 36, 40])))
    if rng.random() < 0.3:
        p = rng.randrange(len(digits) + 1)
        digits = digits[:p] + "." + digits[p:]
    e = rng.choice(["", "E%d" % rng.randint(-6200, 6200), "E+%d" % rng.randint(0, 6200), "e%d" % rng.randint(-40, 40),
                    "E%d" % rng.choice([6111, 6112, 6144, 6145, -6176, -6177, -6143, -6210])])
    sign = rng.choice(["", "", "-", "+"])
    D("dec_random", sign + digits + e)
for hi in [0x7C00000000000000, 0xFC00000000000000, 0x7E00000000000000, 0xFE00000000000000, 0x7C00000000000001,
           0x7800000000000000, 0xF800000000000000, 0x7A00000000000000, 0x6000000000000000, 0x6FFFFFFFFFFFFFFF,
           0x77FFFFFFFFFFFFFF, 0x3040000000000000, 0x3041ED09BEAD87C0, 0x3041ED09BEAD87C1, 0x5FFFFFFFFFFFFFFF,
           0x0000000000000000, 0x8000000000000000, 0x6000000000000001, 0x5FFE000000000000, 0x3042000000000000]:
    for lo in [0, 1, 0x378D8E63FFFFFFFF, 0x378D8E6400000000, 0xFFFFFFFFFFFFFFFF]:
        X("dec_bits_edge", struct.pack("<QQ", lo, hi))
for _ in range(400):
    hi = rng.getrandbits(64)
    if rng.random() < 0.6:  # bias to finite canonical range with interesting exponents
        exp = rng.randrange(0, 12288)
        coeff = rng.randrange(0, 10 ** rng.randint(1, 34))
        hi = (rng.getrandbits(1) << 63) | (exp << 49) | (coeff >> 64)
        lo = coeff & 0xFFFFFFFFFFFFFFFF
    else:
        lo = rng.getrandbits(64)
    X("dec_bits_random", struct.pack("<QQ", lo, hi))

with open(out_path, "w") as f:
    for cat, op, payload in V:
        f.write("%s\t%s\t%s\n" % (cat, op, payload.hex()))
print("generated %d vectors -> %s" % (len(V), out_path))
