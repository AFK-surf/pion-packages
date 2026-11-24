#!/usr/bin/env python3
"""Independent RFC 9651 reference model for the RT-sfv audit (stdlib only).

Written from the RFC 9651 section 4 algorithms (4.1 serializing, 4.2 parsing), not from the Pion source or
from Rust `sfv`. Every step names the RFC step it implements.

Shared dump format (src/dump.pion, diff/rust/src/main.rs and this file print the same thing):
  =<name>
  P <typed>        (parse result)            or   ERR
  S <hex>          (canonical serialization) or   S ERR
typed grammar (all free text is lowercase hex, so every byte value round-trips):
  entry  := item | '(' [item (' ' item)*] ')' params
  item   := bare params
  params := (';' keyhex '=' bare)*
  bare   := 'i'int | 'd'milli | 's'hex | 't'hex | 'b'hex | '?0' | '?1' | '@'int | '%'hex
  list   := [entry (',' entry)*]         dict := [keyhex '=' entry (',' keyhex '=' entry)*]

Usage:
  model.py dump <cases>      corpus line: <name>\t<item|list|dictionary>\t<hex>[,<hex>...]  (field lines)
  model.py ser <vectors>     vector line: <name>\t<item|list|dictionary>\t<typed>           (hand-built AST)
  model.py selftest
"""
import base64
import sys

MAX_INT = 999_999_999_999_999
DIGIT = frozenset(b"0123456789")
ALPHA = frozenset(range(65, 91)) | frozenset(range(97, 123))
LCALPHA = frozenset(range(97, 123))
TCHAR = frozenset(b"!#$%&'*+-.^_`|~") | DIGIT | ALPHA  # RFC 9110 5.6.2
TOKEN_REST = TCHAR | frozenset(b":/")  # RFC 9651 3.3.4
KEY_REST = LCALPHA | DIGIT | frozenset(b"_-.*")  # RFC 9651 3.1.2
B64 = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
HEXL = b"0123456789abcdef"


class Fail(Exception):
    pass


class P:
    def __init__(self, s):
        self.s = s
        self.i = 0

    def empty(self):
        return self.i >= len(self.s)

    def peek(self):
        return self.s[self.i] if self.i < len(self.s) else None

    def take(self):
        c = self.s[self.i]
        self.i += 1
        return c

    def sp(self):
        while self.peek() == 0x20:
            self.i += 1

    def ows(self):
        while self.peek() in (0x20, 0x09):
            self.i += 1

    # 4.2.1
    def list(self):
        members = []
        while not self.empty():
            members.append(self.item_or_inner())  # 2.1
            self.ows()  # 2.2
            if self.empty():  # 2.3
                return members
            if self.take() != 0x2C:  # 2.4
                raise Fail("list: expected ,")
            self.ows()  # 2.5
            if self.empty():  # 2.6
                raise Fail("list: trailing comma")
        return members  # 3

    # 4.2.1.1
    def item_or_inner(self):
        if self.peek() == 0x28:
            return self.inner()
        return self.item()

    # 4.2.1.2
    def inner(self):
        if self.take() != 0x28:  # 1
            raise Fail("inner: (")
        items = []
        while not self.empty():  # 3
            self.sp()  # 3.1
            if self.peek() == 0x29:  # 3.2
                self.take()
                return ("inner", items, self.params())
            items.append(self.item())  # 3.3 / 3.4
            if self.peek() not in (0x20, 0x29):  # 3.5
                raise Fail("inner: expected SP or )")
        raise Fail("inner: end of input")  # 4

    # 4.2.2
    def dictionary(self):
        d = []
        while not self.empty():
            k = self.key()  # 1.1
            if self.peek() == 0x3D:  # 1.2
                self.take()
                member = self.item_or_inner()
            else:  # 1.3
                member = ("item", ("?", True), self.params())
            for n, (kk, _) in enumerate(d):  # 1.4 overwrite in place
                if kk == k:
                    d[n] = (k, member)
                    break
            else:
                d.append((k, member))
            self.ows()  # 1.5
            if self.empty():
                return d
            if self.take() != 0x2C:
                raise Fail("dict: expected ,")
            self.ows()
            if self.empty():
                raise Fail("dict: trailing comma")
        return d

    # 4.2.3
    def item(self):
        bare = self.bare()
        return ("item", bare, self.params())

    # 4.2.3.1
    def bare(self):
        c = self.peek()
        if c is None:
            raise Fail("bare: empty")
        if c == 0x2D or c in DIGIT:
            return self.number()
        if c == 0x22:
            return self.string()
        if c == 0x2A or c in ALPHA:
            return self.token()
        if c == 0x3A:
            return self.binary()
        if c == 0x3F:
            return self.boolean()
        if c == 0x40:
            return self.date()
        if c == 0x25:
            return self.display()
        raise Fail("bare: unknown start")

    # 4.2.3.2
    def params(self):
        ps = []
        while not self.empty():
            if self.peek() != 0x3B:
                break
            self.take()
            self.sp()
            k = self.key()
            v = ("?", True)
            if self.peek() == 0x3D:
                self.take()
                v = self.bare()
            for n, (kk, _) in enumerate(ps):
                if kk == k:
                    ps[n] = (k, v)
                    break
            else:
                ps.append((k, v))
        return ps

    # 4.2.3.3
    def key(self):
        c = self.peek()
        if c is None or not (c in LCALPHA or c == 0x2A):
            raise Fail("key: first char")
        out = bytearray()
        while not self.empty() and self.peek() in KEY_REST:
            out.append(self.take())
        return bytes(out)

    # 4.2.4
    def number(self):
        typ = "integer"
        sign = 1
        num = bytearray()
        if self.peek() == 0x2D:
            self.take()
            sign = -1
        if self.empty():
            raise Fail("number: empty")
        if self.peek() not in DIGIT:
            raise Fail("number: not digit")
        while not self.empty():
            c = self.take()
            if c in DIGIT:
                num.append(c)
            elif typ == "integer" and c == 0x2E:
                if len(num) > 12:
                    raise Fail("number: >12 before .")
                num.append(c)
                typ = "decimal"
            else:
                self.i -= 1
                break
            if typ == "integer" and len(num) > 15:
                raise Fail("number: >15")
            if typ == "decimal" and len(num) > 16:
                raise Fail("number: >16")
        if typ == "integer":
            return ("i", sign * int(num))
        if num.endswith(b"."):
            raise Fail("number: ends with .")
        ip, fp = bytes(num).split(b".")
        if len(fp) > 3:
            raise Fail("number: >3 fraction")
        milli = int(ip) * 1000 + int(fp.ljust(3, b"0"))
        return ("d", sign * milli)

    # 4.2.5
    def string(self):
        if self.take() != 0x22:
            raise Fail("string: quote")
        out = bytearray()
        while not self.empty():
            c = self.take()
            if c == 0x5C:
                if self.empty():
                    raise Fail("string: dangling backslash")
                n = self.take()
                if n not in (0x22, 0x5C):
                    raise Fail("string: bad escape")
                out.append(n)
            elif c == 0x22:
                return ("s", bytes(out))
            elif c <= 0x1F or c >= 0x7F:
                raise Fail("string: bad char")
            else:
                out.append(c)
        raise Fail("string: unterminated")

    # 4.2.6
    def token(self):
        c = self.peek()
        if not (c in ALPHA or c == 0x2A):
            raise Fail("token: first")
        out = bytearray()
        while not self.empty():
            if self.peek() not in TOKEN_REST:
                break
            out.append(self.take())
        return ("t", bytes(out))

    # 4.2.7
    def binary(self):
        if self.take() != 0x3A:
            raise Fail("binary: :")
        rest = self.s[self.i:]
        j = rest.find(b":")
        if j < 0:
            raise Fail("binary: no closing :")
        content = rest[:j]
        self.i += j + 1
        if any(c not in B64 for c in content):
            raise Fail("binary: bad char")
        return ("b", b64decode_lenient(content))

    # 4.2.8
    def boolean(self):
        if self.take() != 0x3F:
            raise Fail("bool: ?")
        if self.peek() == 0x31:
            self.take()
            return ("?", True)
        if self.peek() == 0x30:
            self.take()
            return ("?", False)
        raise Fail("bool: value")

    # 4.2.9
    def date(self):
        if self.take() != 0x40:
            raise Fail("date: @")
        v = self.number()
        if v[0] != "i":
            raise Fail("date: decimal")
        return ("@", v[1])

    # 4.2.10
    def display(self):
        if self.peek() != 0x25 or self.s[self.i + 1:self.i + 2] != b'"':
            raise Fail('display: %"')
        self.i += 2
        arr = bytearray()
        while not self.empty():
            c = self.take()
            if c <= 0x1F or c >= 0x7F:
                raise Fail("display: bad char")
            if c == 0x25:
                h = self.s[self.i:self.i + 2]
                self.i += 2
                if len(h) < 2 or any(x not in HEXL for x in h):
                    raise Fail("display: bad hex")
                arr.append(int(h, 16))
            elif c == 0x22:
                try:
                    bytes(arr).decode("utf-8", "strict")  # Python's codec rejects overlongs / surrogates / > U+10FFFF
                except UnicodeDecodeError:
                    raise Fail("display: utf-8")
                return ("%", bytes(arr))
            else:
                arr.append(c)
        raise Fail("display: unterminated")


def b64decode_lenient(content):
    """RFC 9651 4.2.7: base64-decode, synthesizing padding; SHOULD NOT fail on missing padding or non-zero pad bits.
    '=' is only valid as trailing padding inside the final 4-character quantum (RFC 4648 3.3 / 4)."""
    data = content.rstrip(b"=")
    pad = len(content) - len(data)
    if b"=" in data:
        raise Fail("binary: = inside data")
    r = len(data) % 4
    if r == 1:
        raise Fail("binary: length")
    if pad > (4 - r) % 4:
        raise Fail("binary: padding beyond the quantum")
    full = data + b"=" * ((4 - r) % 4)
    # non-zero pad bits: Python's decoder ignores them (validate=True only checks the alphabet)
    return base64.b64decode(full, validate=True)


def parse_field(lines, typ):
    raw = b", ".join(lines)
    if any(c >= 0x80 for c in raw):  # 4.2 step 1: ASCII conversion fails
        raise Fail("non-ASCII")
    p = P(raw)
    p.sp()  # 4.2 step 2
    if typ == "list":
        out = p.list()
    elif typ == "dictionary":
        out = p.dictionary()
    else:
        out = p.item()
    p.sp()  # 4.2 step 6
    if not p.empty():  # 4.2 step 7
        raise Fail("trailing characters")
    return out


# ------------------------------------------------------------------------------------------- typed dump

def h(b):
    return b.hex()


def t_bare(b):
    k, v = b
    if k in "id@":
        return "%s%d" % (k, v)
    if k == "r":
        return "r%de%d" % v
    if k == "?":
        return "?1" if v else "?0"
    return k + h(v)


def t_params(ps):
    return "".join(";%s=%s" % (h(k), t_bare(v)) for k, v in ps)


def t_entry(e):
    if e[0] == "item":
        return t_bare(e[1]) + t_params(e[2])
    return "(" + " ".join(t_entry(x) for x in e[1]) + ")" + t_params(e[2])


def typed(out, typ):
    if typ == "list":
        return ",".join(t_entry(e) for e in out)
    if typ == "dictionary":
        return ",".join("%s=%s" % (h(k), t_entry(e)) for k, e in out)
    return t_entry(out)


# --------------------------------------------------------------------------------------- typed -> AST

class TP:
    def __init__(self, s):
        self.s = s
        self.i = 0

    def peek(self):
        return self.s[self.i] if self.i < len(self.s) else ""

    def hexrun(self):
        j = self.i
        while self.i < len(self.s) and self.s[self.i] in "0123456789abcdef":
            self.i += 1
        return bytes.fromhex(self.s[j:self.i])

    def intrun(self):
        j = self.i
        if self.peek() == "-":
            self.i += 1
        while self.i < len(self.s) and self.s[self.i].isdigit():
            self.i += 1
        return int(self.s[j:self.i])

    def bare(self):
        c = self.s[self.i]
        self.i += 1
        if c in "id@":
            return (c, self.intrun())
        if c == "r":  # exact value * 10^-scale, to be rounded by the serializer (RFC 9651 4.1.5)
            v = self.intrun()
            assert self.s[self.i] == "e"
            self.i += 1
            return ("r", (v, self.intrun()))
        if c == "?":
            v = self.s[self.i] == "1"
            self.i += 1
            return ("?", v)
        return (c, self.hexrun())

    def params(self):
        ps = []
        while self.peek() == ";":
            self.i += 1
            k = self.hexrun()
            assert self.s[self.i] == "="
            self.i += 1
            ps.append((k, self.bare()))
        return ps

    def entry(self):
        if self.peek() == "(":
            self.i += 1
            items = []
            while self.peek() != ")":
                if items:
                    assert self.s[self.i] == " "
                    self.i += 1
                b = self.bare()
                items.append(("item", b, self.params()))
            self.i += 1
            return ("inner", items, self.params())
        b = self.bare()
        return ("item", b, self.params())

    def top(self, typ):
        if typ == "item":
            e = self.entry()
            out = e
        elif typ == "list":
            out = []
            while self.i < len(self.s):
                if out:
                    assert self.s[self.i] == ","
                    self.i += 1
                out.append(self.entry())
        else:
            out = []
            while self.i < len(self.s):
                if out:
                    assert self.s[self.i] == ","
                    self.i += 1
                k = self.hexrun()
                assert self.s[self.i] == "="
                self.i += 1
                out.append((k, self.entry()))
        assert self.i == len(self.s), (self.s, self.i)
        return out


# ------------------------------------------------------------------------------------------ 4.1 serialize

def s_int(v):  # 4.1.4
    if not -MAX_INT <= v <= MAX_INT:
        raise Fail("integer range")
    return str(v)


def s_dec(m):  # 4.1.5 (value already exact in thousandths, so no rounding is needed)
    if not -MAX_INT <= m <= MAX_INT:
        raise Fail("decimal range")
    sign = "-" if m < 0 else ""
    a = abs(m)
    ip, fp = divmod(a, 1000)
    frac = ("%03d" % fp).rstrip("0") or "0"
    return "%s%d.%s" % (sign, ip, frac)


def round_half_even_milli(v, scale):
    """4.1.5 step: round value * 10^-scale to three fractional digits, ties to even (exact integers)."""
    if scale <= 3:
        return v * 10 ** (3 - scale)
    div = 10 ** (scale - 3)
    q, r = divmod(abs(v), div)
    if 2 * r > div or (2 * r == div and q % 2 == 1):
        q += 1
    return -q if v < 0 else q


def s_str(b):  # 4.1.6
    out = '"'
    for c in b:
        if c <= 0x1F or c >= 0x7F:
            raise Fail("string char")
        if c in (0x22, 0x5C):
            out += "\\"
        out += chr(c)
    return out + '"'


def s_tok(b):  # 4.1.7
    if not b or not (b[0] in ALPHA or b[0] == 0x2A) or any(c not in TOKEN_REST for c in b[1:]):
        raise Fail("token")
    return b.decode()


def s_key(b):  # 4.1.1.3
    if not b or any(c not in KEY_REST for c in b) or not (b[0] in LCALPHA or b[0] == 0x2A):
        raise Fail("key")
    return b.decode()


def s_disp(b):  # 4.1.11
    try:
        b.decode("utf-8", "strict")
    except UnicodeDecodeError:
        raise Fail("display: not a sequence of Unicode code points")
    out = '%"'
    for c in b:
        if c in (0x25, 0x22) or c <= 0x1F or c >= 0x7F:
            out += "%" + "%02x" % c
        else:
            out += chr(c)
    return out + '"'


def s_bare(b):  # 4.1.3.1
    k, v = b
    if k == "i":
        return s_int(v)
    if k == "d":
        return s_dec(v)
    if k == "r":
        return s_dec(round_half_even_milli(*v))
    if k == "s":
        return s_str(v)
    if k == "t":
        return s_tok(v)
    if k == "b":
        return ":" + base64.b64encode(v).decode() + ":"
    if k == "?":
        return "?1" if v else "?0"
    if k == "@":
        return "@" + s_int(v)
    return s_disp(v)


def uniq(keys):
    # RFC 9651 3.1.2 / 3.2: Parameters and Dictionaries are ordered maps, keys are unique. A hand-built AST with
    # a duplicate key is not a Structured Field value; the model refuses to serialize it.
    if len(set(keys)) != len(keys):
        raise Fail("duplicate key in an ordered map")


def s_params(ps):  # 4.1.1.2
    uniq([k for k, _ in ps])
    out = ""
    for k, v in ps:
        out += ";" + s_key(k)
        if v != ("?", True):
            out += "=" + s_bare(v)
    return out


def s_entry(e):  # 4.1.1.1 / 4.1.3
    if e[0] == "item":
        return s_bare(e[1]) + s_params(e[2])
    return "(" + " ".join(s_entry(x) for x in e[1]) + ")" + s_params(e[2])


def serialize(out, typ):
    if typ == "list":  # 4.1.1
        return ", ".join(s_entry(e) for e in out)
    if typ == "dictionary":  # 4.1.2
        uniq([k for k, _ in out])
        parts = []
        for k, e in out:
            s = s_key(k)
            if e[0] == "item" and e[1] == ("?", True):
                s += s_params(e[2])
            else:
                s += "=" + s_entry(e)
            parts.append(s)
        return ", ".join(parts)
    return s_entry(out)


# ------------------------------------------------------------------------------------------------- CLI

def dump_cases(path):
    w = sys.stdout.write
    for line in open(path, "rb").read().decode().split("\n"):
        if not line:
            continue
        name, typ, hx = line.split("\t")
        lines = [bytes.fromhex(x) for x in hx.split(",")] if hx else []
        w("=%s\n" % name)
        try:
            out = parse_field(lines, typ)
        except Fail:
            w("ERR\n")
            continue
        w("P %s\n" % typed(out, typ))
        try:
            w("S %s\n" % serialize(out, typ).encode().hex())
        except Fail:
            w("S ERR\n")


def ser_vectors(path):
    w = sys.stdout.write
    for line in open(path, "rb").read().decode().split("\n"):
        if not line:
            continue
        name, typ, t = line.split("\t")
        w("=%s\n" % name)
        try:
            w("S %s\n" % serialize(TP(t).top(typ), typ).encode().hex())
        except Fail:
            w("S ERR\n")


def selftest():
    ok = 0
    for raw, typ, want in [
        (b"a=1, b;x, c=(1 2);y=?0", "dictionary", "a=1, b;x, c=(1 2);y=?0"),
        (b"  1.50  ", "item", "1.5"),
        (b"-0.0", "item", "0.0"),
        (b'%"f%c3%bc"', "item", '%"f%c3%bc"'),
        (b":aGVsbG8:", "item", ":aGVsbG8=:"),
        (b"a\t", "list", "a"),
        (b"a=1, a=2, b", "dictionary", "a=2, b"),
    ]:
        got = serialize(parse_field([raw], typ), typ)
        assert got == want, (raw, got, want)
        ok += 1
    for raw, typ in [(b"a\t", "item"), (b"\ta", "list"), (b"1.", "item"), (b"1.1234", "item"),
                     (b"1234567890123456", "item"), (b"%\"%C3%BC\"", "item"), (b":a=b:", "item")]:
        try:
            parse_field([raw], typ)
        except Fail:
            ok += 1
            continue
        raise AssertionError(raw)
    print("model self-test: %d/14 ok" % ok)


if __name__ == "__main__":
    if sys.argv[1] == "dump":
        dump_cases(sys.argv[2])
    elif sys.argv[1] == "ser":
        ser_vectors(sys.argv[2])
    else:
        selftest()
