#!/usr/bin/env python3
"""RT-sfv corpus generator (stdlib only, deterministic). Writes into <out_dir>:
  official.cases / official.json   every parsing vector of httpwg/structured-field-tests (audit/sft, all 20 files)
  official_ser.vec / official_ser.json   the serialisation-tests/ vectors (hand-built structures)
  named.cases    adversarial byte sweeps 0x00..0xFF per syntactic position, number / date / binary / display string
                 boundary grids, whitespace and multi-line joining
  fuzz.cases     <n> structure-aware random fields + byte-level mutations of them (seeded)
  ser.vec        hand-built ASTs: header-injection, invalid keys / tokens / strings / UTF-8, range edges, duplicates
  helpers.cases  RFC 9218 Priority / W3C Permissions-Policy vectors
usage: gen.py <sft_dir> <out_dir> <fuzz_n>
"""
import base64
import decimal
import gzip
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model  # noqa: E402

SFT, OUT, N = sys.argv[1], sys.argv[2], int(sys.argv[3])
os.makedirs(OUT, exist_ok=True)


def hx(b):
    return b.hex()


def line(name, typ, fields):
    return "%s\t%s\t%s\n" % (name, typ, ",".join(hx(f) for f in fields))


# ------------------------------------------------------------------------------------------- official
def load(path):
    with gzip.open(path, "rb") as f:
        return json.loads(f.read().decode(), parse_float=decimal.Decimal)


def e_bare(v):
    if isinstance(v, bool):
        return ("?", v)
    if isinstance(v, int):
        return ("i", v)
    if isinstance(v, decimal.Decimal):
        m = v * 1000
        if m == int(m):
            return ("d", int(m))
        sign, digits, exp = v.as_tuple()  # more than 3 fractional digits: the serializer has to round
        val = int("".join(map(str, digits))) * (-1 if sign else 1)
        return ("r", (val, -exp))
    if isinstance(v, str):
        return ("s", v.encode())
    t = v["__type"]
    if t == "token":
        return ("t", v["value"].encode())
    if t == "binary":
        return ("b", base64.b32decode(v["value"]))
    if t == "date":
        return ("@", v["value"])
    if t == "displaystring":
        return ("%", v["value"].encode("utf-8", "surrogatepass"))
    raise ValueError(t)


def e_params(ps):
    return [(k.encode(), e_bare(v)) for k, v in ps]


def e_entry(x):
    v, ps = x
    if isinstance(v, list):
        return ("inner", [("item", e_bare(i[0]), e_params(i[1])) for i in v], e_params(ps))
    return ("item", e_bare(v), e_params(ps))


def e_top(exp, typ):
    if typ == "item":
        return e_entry(exp)
    if typ == "list":
        return [e_entry(x) for x in exp]
    return [(k.encode(), e_entry(x)) for k, x in exp]


files = sorted(f for f in os.listdir(SFT) if f.endswith(".json.gz"))
meta = {}
with open(os.path.join(OUT, "official.cases"), "w") as o:
    for f in files:
        for i, t in enumerate(load(os.path.join(SFT, f))):
            name = "%s#%d" % (f[:-8], i)
            raw = [r.encode("latin-1") for r in t["raw"]]
            typ = t["header_type"]
            o.write(line(name, typ, raw))
            m = {"title": t["name"], "must_fail": bool(t.get("must_fail")), "can_fail": bool(t.get("can_fail"))}
            if "expected" in t:
                m["typed"] = model.typed(e_top(t["expected"], typ), typ)
                canon = t["canonical"] if "canonical" in t else t["raw"]
                m["canonical"] = ", ".join(canon).encode("latin-1").hex()
            meta[name] = m
json.dump(meta, open(os.path.join(OUT, "official.json"), "w"), indent=0, sort_keys=True)

smeta = {}
with open(os.path.join(OUT, "official_ser.vec"), "w") as o:
    d = os.path.join(SFT, "serialisation-tests")
    for f in sorted(os.listdir(d)):
        for i, t in enumerate(load(os.path.join(d, f))):
            name = "ser-%s#%d" % (f[:-8], i)
            typ = t["header_type"]
            try:
                ast = e_top(t["expected"], typ)
            except (ValueError, UnicodeEncodeError):
                continue
            o.write("%s\t%s\t%s\n" % (name, typ, model.typed(ast, typ)))
            smeta[name] = {"title": t["name"], "must_fail": bool(t.get("must_fail")),
                           "canonical": ", ".join(t.get("canonical", [])).encode().hex()}
json.dump(smeta, open(os.path.join(OUT, "official_ser.json"), "w"), indent=0, sort_keys=True)

# --------------------------------------------------------------------------------------------- named
named = []


def add(name, typ, *fields):
    named.append(line(name, typ, list(fields)))


for b in range(256):
    c = bytes([b])
    add("tok-first-%02x" % b, "item", c + b"a")
    add("tok-mid-%02x" % b, "item", b"a" + c + b"a")
    add("tok-end-%02x" % b, "item", b"a" + c)
    add("key-first-dict-%02x" % b, "dictionary", c + b"a=1")
    add("key-mid-dict-%02x" % b, "dictionary", b"a" + c + b"a=1")
    add("key-single-dict-%02x" % b, "dictionary", c + b"=1")
    add("key-first-param-%02x" % b, "item", b"x;" + c + b"a=1")
    add("key-mid-param-%02x" % b, "item", b"x;a" + c + b"a=1")
    add("str-%02x" % b, "item", b'"' + c + b'"')
    add("str-esc-%02x" % b, "item", b'"\\' + c + b'"')
    add("disp-raw-%02x" % b, "item", b'%"' + c + b'"')
    add("disp-pct-%02x" % b, "item", b'%"%' + b"%02x" % b + b'"')
    add("disp-pctU-%02x" % b, "item", b'%"%' + b"%02X" % b + b'"')
    add("disp-pcthalf-%02x" % b, "item", b'%"%a' + c + b'"')
    add("bin-%02x" % b, "item", b":aG" + c + b"s:")
    add("bin-end-%02x" % b, "item", b":aGVs" + c + b":")
    add("bool-%02x" % b, "item", b"?" + c)
    add("date-%02x" % b, "item", b"@" + c + b"1")
    add("num-after-%02x" % b, "item", b"1" + c)
    add("num-dec-%02x" % b, "item", b"1." + c)
    add("bare-start-%02x" % b, "item", c)
    for typ in ("item", "list", "dictionary"):
        v = b"a=1" if typ == "dictionary" else b"a"
        add("lead-%s-%02x" % (typ, b), typ, c + v)
        add("trail-%s-%02x" % (typ, b), typ, v + c)
        add("trail-sp-%s-%02x" % (typ, b), typ, v + b" " + c)
        add("trail-%s-%02x-sp" % (typ, b), typ, v + c + b" ")
    add("list-sep-before-%02x" % b, "list", b"a" + c + b",b")
    add("list-sep-after-%02x" % b, "list", b"a," + c + b"b")
    add("dict-sep-before-%02x" % b, "dictionary", b"a=1" + c + b",b=2")
    add("dict-sep-after-%02x" % b, "dictionary", b"a=1," + c + b"b=2")
    add("dict-eq-before-%02x" % b, "dictionary", b"a" + c + b"=1")
    add("inner-sep-%02x" % b, "list", b"(a" + c + b"b)")
    add("inner-open-%02x" % b, "list", b"(" + c + b"a)")
    add("inner-close-%02x" % b, "list", b"(a" + c + b")")
    add("param-semi-after-%02x" % b, "item", b"a;" + c + b"b")
    add("param-semi-before-%02x" % b, "item", b"a" + c + b";b")

# numbers: every digit count, sign, leading zeros, decimal int / fraction split
for nd in range(1, 18):
    for lead in (b"1", b"0", b"9"):
        d = lead + b"0" * (nd - 1) if lead != b"9" else b"9" * nd
        for sign in (b"", b"-"):
            add("int-%s%s-%d" % (sign.decode(), lead.decode(), nd), "item", sign + d)
            add("date-%s%s-%d" % (sign.decode(), lead.decode(), nd), "item", b"@" + sign + d)
for ni in range(0, 15):
    for nf in range(0, 5):
        for sign in (b"", b"-"):
            i = b"9" * ni
            f = b"9" * nf
            add("dec-%s%d.%d" % (sign.decode(), ni, nf), "item", sign + i + b"." + f)
            add("dec0-%s%d.%d" % (sign.decode(), ni, nf), "item", sign + b"0" * ni + b"." + b"0" * nf)
            add("decmix-%s%d.%d" % (sign.decode(), ni, nf), "item", sign + b"1" * ni + b"." + b"5" * nf)
for s in [b"+1", b"--1", b"-", b"-a", b"1e5", b"0x10", b"1_000", b".5", b"-.5", b"1..2", b"1.2.3", b"00", b"-00.10",
          b"1.0;a", b"-0", b"-0.0", b"0.000", b"-0.001", b"999999999999.999", b"-999999999999.999",
          b"1000000000000.0", b"999999999999999", b"-999999999999999", b"1000000000000000", b"0000000000000001",
          b"000000000000001", b"@-0", b"@0.0", b"@-", b"@+1", b"@ 1", b"@1.0", b"@--1", b"@@1"]:
    add("num-%s" % s.hex(), "item", s)

# binary: every length 0..9 with every padding count, pad bits
for ln in range(0, 10):
    body = (b"QUJDREVGR0hJ" * 2)[:ln]
    for pad in range(0, 5):
        add("binlen-%d-%d" % (ln, pad), "item", b":" + body + b"=" * pad + b":")
for last in b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/":
    add("binbits2-%02x" % last, "item", b":Y" + bytes([last]) + b":")
    add("binbits3-%02x" % last, "item", b":YW" + bytes([last]) + b":")
    add("binbits2p-%02x" % last, "item", b":Y" + bytes([last]) + b"==:")
for s in [b":=:", b":==:", b":====:", b":YQ==YQ==:", b":YQ=a:", b":Y=Q=:", b": YQ==:", b":YQ== :", b":YQ==\t:",
          b":YQ==", b"::", b":", b"::a", b":YWJj:;a"]:
    add("binx-%s" % s.hex(), "item", s)

# display strings: UTF-8 structure sweeps (every lead byte with boundary continuations), truncations, overlongs
conts = [0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0]
for lead in range(0x80, 0x100):
    for c1 in conts:
        add("utf8-2-%02x%02x" % (lead, c1), "item", b'%"' + b"%%%02x%%%02x" % (lead, c1) + b'"')
        for c2 in (0x80, 0xBF):
            add("utf8-3-%02x%02x%02x" % (lead, c1, c2), "item", b'%"' + b"%%%02x%%%02x%%%02x" % (lead, c1, c2) + b'"')
            add("utf8-4-%02x%02x%02x" % (lead, c1, c2), "item",
                b'%"' + b"%%%02x%%%02x%%%02x%%80" % (lead, c1, c2) + b'"')
for cp in [0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xE000, 0xFFFD, 0xFFFF, 0x10000,
           0x10FFFF]:
    enc = chr(cp).encode("utf-8", "surrogatepass")
    add("cp-%x" % cp, "item", b'%"' + b"".join(b"%%%02x" % x for x in enc) + b'"')
    for cut in range(1, len(enc)):
        add("cp-%x-cut%d" % (cp, cut), "item", b'%"' + b"".join(b"%%%02x" % x for x in enc[:cut]) + b'"')
for s in [b'%"', b"%", b'%"%', b'%"%"', b'%"%a"', b'%"%2"', b'%"%25"', b'%"%22"', b'%" "', b"%'a'", b'%a"b"',
          b'% "a"', b'%"a" ', b'%"a"\t', b'%"\\"', b'%"\\%22"', b'%"%e9"', b'%"%c3%a9"', b'%"%C3%A9"']:
    add("dispx-%s" % s.hex(), "item", s)

# structures, whitespace and multi-line joining
for s, t in [(b"", "list"), (b"", "dictionary"), (b"", "item"), (b"   ", "list"), (b"\t", "list"), (b",", "list"),
             (b"()", "list"), (b"(), (), ()", "list"), (b"( )", "list"), (b"(  )", "list"), (b"()()", "list"),
             (b"(1)(2)", "list"), (b"((1))", "list"), (b"(1 (2))", "list"), (b"a=()", "dictionary"),
             (b"a=(1 2);x;y=?0, b", "dictionary"), (b"a;x=1;x=2", "dictionary"), (b"a=1;a=2", "dictionary"),
             (b"a=1, a, a=?0", "dictionary"), (b"a=(1), a=2", "dictionary"), (b"*=1", "dictionary"),
             (b"a=1,b=2", "dictionary"), (b"a=1 ,b=2", "dictionary"), (b"a=1\t,\tb=2", "dictionary"),
             (b"a=1\t \t,  \t b=2  ", "dictionary"), (b"a=1\t", "dictionary"), (b"a=1 \t", "dictionary"),
             (b"a=1\t ", "dictionary"), (b"a=1\t\t", "dictionary"), (b"1\t", "list"), (b"1 \t", "list"),
             (b"1\t ", "list"), (b"(1)\t", "list"), (b"1;a\t", "list"), (b"1, 2\t", "list"), (b"1\t", "item"),
             (b"a;b=?0;c", "item"), (b"a; b", "item"), (b"a;  b", "item"), (b"a ;b", "item"), (b"a;b =1", "item"),
             (b"a;b= 1", "item"), (b"(a;b) ;c", "list"), (b"(a;b);c", "list"), (b"(a b;c=1);d=:YQ==:", "list")]:
    add("struct-%s-%s" % (t, s.hex()), t, s)
for t in ("list", "dictionary", "item"):
    v = b"a=1" if t == "dictionary" else b"a"
    for fl in [[v, b""], [b"", v], [b"", b""], [b" "], [v, b" "], [b" ", v], [v + b",", v], [v, b"," + v],
               [v + b"\t", v], [v, v + b"\t"], [v, b"\t" + v], [v + b" ", b" " + v], [v, v, v], [v, b"b=2"],
               [b"a=1", b"a=2"], [v, b"x\r\nX-Evil: 1"], [v, b"\x00"], [v + b"\r", b"\n" + v], [b"(1", b"2)"],
               [b'"a', b'b"'], [b":YQ", b"==:"], [b"1.", b"5"]]:
        add("lines-%s-%s" % (t, "-".join(x.hex() or "e" for x in fl)), t, *fl)

# RFC 9651 section 3 minimums: 1024 list / dict members, 256 inner items / params, 64-char key, 1024-char
# string, 512-char token, 16384-byte byte sequence (all must parse under the default SfvLimits)
add("min-list-1024", "list", b", ".join(b"a%d" % i for i in range(1024)))
add("min-dict-1024", "dictionary", b", ".join(b"k%d=%d" % (i, i) for i in range(1024)))
add("min-inner-256", "list", b"(" + b" ".join(b"%d" % i for i in range(256)) + b")")
add("min-params-256", "item", b"a" + b"".join(b";k%d" % i for i in range(256)))
add("min-key-64", "dictionary", b"a" * 64 + b"=1")
add("min-str-1024", "item", b'"' + b"x" * 1024 + b'"')
add("min-tok-512", "item", b"a" * 512)
add("min-bin-16384", "item", b":" + base64.b64encode(bytes(range(256)) * 64) + b":")
with open(os.path.join(OUT, "named.cases"), "w") as o:
    o.writelines(named)

# ---------------------------------------------------------------------------------------------- fuzz
rng = random.Random(9651)
KEYS = [b"a", b"b", b"*", b"a-b", b"a.b", b"a_b", b"k9", b"x*y"]


def r_bare():
    k = rng.randrange(8)
    if k == 0:
        return ("i", rng.choice([0, 1, -1, 7, 999999999999999, -999999999999999, rng.randrange(-10**15 + 1, 10**15)]))
    if k == 1:
        return ("d", rng.choice([0, 1, -1, 1500, 999999999999999, -999999999999999, rng.randrange(-10**15 + 1, 10**15)]))
    if k == 2:
        return ("s", bytes(rng.choice(range(0x20, 0x7F)) for _ in range(rng.randrange(6))))
    if k == 3:
        first = rng.choice(b"aZ*")
        return ("t", bytes([first]) + bytes(rng.choice(b"az09!#$%&'*+-.^_`|~:/") for _ in range(rng.randrange(5))))
    if k == 4:
        return ("b", bytes(rng.randrange(256) for _ in range(rng.randrange(7))))
    if k == 5:
        return ("?", rng.random() < 0.5)
    if k == 6:
        return ("@", rng.randrange(-10**15 + 1, 10**15))
    cps = [rng.choice([0x41, 0x25, 0x22, 0xE9, 0x3042, 0x1F600, 0x7F, 0x0A, 0x10FFFF]) for _ in range(rng.randrange(5))]
    return ("%", "".join(chr(c) for c in cps).encode())


def r_params():
    return [(rng.choice(KEYS), r_bare()) for _ in range(rng.choice([0, 0, 1, 2, 3]))]


def r_entry():
    if rng.random() < 0.25:
        return ("inner", [("item", r_bare(), r_params()) for _ in range(rng.randrange(4))], r_params())
    return ("item", r_bare(), r_params())


def r_field():
    t = rng.choice(["item", "list", "dictionary"])
    if t == "item":
        ast = ("item", r_bare(), r_params())
    elif t == "list":
        ast = [r_entry() for _ in range(rng.randrange(1, 5))]
    else:
        ast = [(rng.choice(KEYS), r_entry()) for _ in range(rng.randrange(1, 5))]
    try:
        return t, model.serialize(ast, t).encode(), ast
    except model.Fail:  # duplicate keys
        return None


JUNK = [b" ", b"\t", b",", b";", b"=", b"(", b")", b'"', b"\\", b":", b"%", b"?", b"@", b"-", b".", b"0", b"A", b"\r",
        b"\n", b"\x00", b"\x7f", b"\xc3\xa9", b"%c3", b"%C3", b"==", b"*"]


def mutate(s):
    s = bytearray(s)
    for _ in range(rng.randrange(1, 4)):
        op = rng.randrange(5)
        p = rng.randrange(len(s) + 1)
        if op == 0 and s:
            del s[min(p, len(s) - 1)]
        elif op == 1:
            s[p:p] = rng.choice(JUNK)
        elif op == 2 and s:
            s[min(p, len(s) - 1)] = rng.randrange(256)
        elif op == 3 and s:
            q = rng.randrange(len(s))
            a, b = sorted((p, q))
            s[b:b] = s[a:b]
        else:
            s[p:p] = bytes([rng.choice(b" \t")]) * rng.randrange(1, 3)
    return bytes(s)


fuzz = []
sers = []
i = 0
while len(fuzz) < N:
    g = r_field()
    if g is None:
        continue
    t, s, ast = g
    fuzz.append(line("fz%d-ok" % i, t, [s]))
    fuzz.append(line("fz%d-mut" % i, t, [mutate(s)]))
    if rng.random() < 0.2 and t != "item":
        cut = rng.randrange(len(s) + 1)
        fuzz.append(line("fz%d-split" % i, t, [s[:cut], s[cut:]]))
    sers.append("sfz%d\t%s\t%s\n" % (i, t, model.typed(ast, t)))
    i += 1
with open(os.path.join(OUT, "fuzz.cases"), "w") as o:
    o.writelines(fuzz)

# ----------------------------------------------------------------------------------- serializer vectors
sv = []


def vec(name, typ, typed):
    sv.append("%s\t%s\t%s\n" % (name, typ, typed))


for b in range(256):
    c = bytes([b])
    vec("s-str-%02x" % b, "item", "s" + hx(b"a" + c + b"b"))
    vec("s-tok-first-%02x" % b, "item", "t" + hx(c + b"a"))
    vec("s-tok-mid-%02x" % b, "item", "t" + hx(b"a" + c))
    vec("s-key-first-%02x" % b, "item", "i1;" + hx(c + b"a") + "=i1")
    vec("s-key-mid-%02x" % b, "item", "i1;" + hx(b"a" + c) + "=i1")
    vec("s-dkey-first-%02x" % b, "dictionary", hx(c + b"a") + "=i1")
    vec("s-disp-byte-%02x" % b, "item", "%" + hx(c))
for v in [0, 1, -1, 999999999999999, -999999999999999, 1000000000000000, -1000000000000000, 2**63 - 1, -2**63]:
    vec("s-int-%d" % v, "item", "i%d" % v)
    vec("s-dec-%d" % v, "item", "d%d" % v)
    vec("s-date-%d" % v, "item", "@%d" % v)
for name, typed_ in [("empty-tok", "t"), ("empty-key", "i1;=i1"), ("crlf-str", "s" + hx(b"a\r\nX-Evil: 1")),
                     ("crlf-tok", "t" + hx(b"a\r\nX-Evil: 1")), ("crlf-key", "i1;" + hx(b"a\r\nx") + "=i1"),
                     ("nul-str", "s" + hx(b"a\x00")), ("bin-empty", "b"), ("bin-1", "b00"), ("bin-2", "bffff"),
                     ("disp-empty", "%"), ("disp-crlf", "%" + hx(b"a\r\nX: 1")),
                     ("disp-pct", "%" + hx(b"100%")), ("disp-all-ascii", "%" + hx(bytes(range(128)))),
                     ("dup-param", "i1;61=i1;61=i2"), ("dup-param-bool", "i1;61=?1;62=?0;61=?1"),
                     ("param-bool-true", "i1;61=?1"), ("param-bool-false", "i1;61=?0")]:
    vec("s-" + name, "item", typed_)
for bad in [b"\xc0\xaf", b"\xe0\x80\xaf", b"\xf0\x80\x80\xaf", b"\xed\xa0\x80", b"\xed\xbf\xbf", b"\xf4\x90\x80\x80",
            b"\xf5\x80\x80\x80", b"\xff", b"\x80", b"\xc3", b"\xe2\x82", b"\xf0\x9f\x98", b"a\xc3\x28"]:
    vec("s-disp-bad-%s" % bad.hex(), "item", "%" + hx(bad))
for typ, typed_ in [("dictionary", "61=i1,61=i2"), ("dictionary", "61=i1,62=i2,61=?1"), ("dictionary", "61=?1;61=i1;61=i2"),
                    ("dictionary", "61=?1"), ("dictionary", "61=?0"), ("dictionary", "61=(i1 i2);78=?1"),
                    ("dictionary", "61=(),62=?1;63=i1"), ("list", "(i1;61=i1;61=i2)"), ("list", "()"),
                    ("list", "(),()"), ("list", "i1,(i2 i3);61=?1"), ("dictionary", "41=i1"),
                    ("dictionary", hx(b"a b") + "=i1"), ("list", "(t)")]:
    vec("s-struct-%s-%s" % (typ, typed_.encode().hex()[:40]), typ, typed_)
with open(os.path.join(OUT, "ser.vec"), "w") as o:
    o.writelines(sv + sers)

# ------------------------------------------------------------------------------------------- helpers
hv = []
for s in [b"u=1, i", b"", b"u=0", b"u=7", b"u=8", b"u=-1", b"u=1.0", b'u="1"', b"u=(1)", b"u=?1", b"i=?0", b"i=?1",
          b"i=1", b"u=2, u=9", b"u=9, u=2", b"u=2;x=1, foo=bar, i;y", b"U=1", b"u = 1", b"u=1,", b"u=1 i",
          b"i, u=0, i=?0", b"u=3", b"u=@1", b"u=%\"1\"", b"u=7;i", b"u=0000000000000007",
          b"geolocation=(self \"https://a.example\"), camera=(), fullscreen=*, usb=self",
          b"camera=(\"https://a.example\" * self)", b'camera="https://a.example"', b"camera=src", b"camera=(src)",
          b"camera=none", b"camera=?0", b"camera=(self);report-to=x", b"camera=(), camera=*", b"camera=(*), mic=()",
          b'camera=("javascript:alert(1)")', b"Camera=*", b"camera=*\t", b"camera=(\"a\" \"b\" \"a\")"]:
    hv.append(line("h-" + s.hex(), "dictionary", [s]))
with open(os.path.join(OUT, "helpers.cases"), "w") as o:
    o.writelines(hv)

print(len(meta), len(smeta), len(named), len(fuzz), len(sv) + len(sers), len(hv))
