#!/usr/bin/env python3
"""Independent reference model of packages/dash (ISO/IEC 23009-1 MPD parse + segment resolution + ABR).

Written from the specifications (XML 1.0 5th ed., Namespaces are not modelled, xs: lexical spaces,
ISO/IEC 23009-1 5.3.9 / 5.3.2, RFC 3986 5.2), not from the Pion sources. Where a specification leaves a choice
open the model follows the package's documented design (README.md / doc comments) and says so ("design").

It prints the same canonical dump as ../src/dump.pion. Every case is evaluated twice:
  * spec mode  - what a conforming implementation must output; a list of alternatives where a fix may
                 legitimately choose (reject at parse time or at resolution time, ...);
  * emu mode   - the spec model with the behaviour of each OPEN finding switched on (FLAGS below).
compare.py accepts the Pion dump if it equals a spec alternative, or equals the emu output (then the
divergence is explained by the findings whose flag changes the output). Anything else is unexplained.

Usage: model.py <cases-file>            -> '=<name>' blocks: 'S' alternatives and one 'E' (emu) dump
       model.py --api <vector-file>     -> spec / emu lines for the API sweep
       model.py --expat <cases-file>    -> cross-check of the strict XML layer against expat (pyexpat)
"""
import sys
import xml.parsers.expat

FLAGS = ("P1-1", "P1-2", "P1-3", "P2-1", "P2-2", "P2-4", "P2-5", "P2-6", "P2-8")

I64_MAX = (1 << 63) - 1
I64_MIN = -(1 << 63)

LIM = dict(max_input_bytes=16777216, max_xml_depth=64, max_elements=200000, max_attributes=256, max_periods=1024,
           max_adaptation_sets=1024, max_representations=4096, max_segments=100000, max_timeline_entries=100000,
           max_text_bytes=1048576)


class Err(Exception):
    def __init__(self, kind, msg=""):
        Exception.__init__(self, kind + ": " + msg)
        self.kind = kind


def wrap64(v):
    v &= (1 << 64) - 1
    return v - (1 << 64) if v >= 1 << 63 else v


# ------------------------------------------------------------------ dump helpers (mirror of src/dump.pion)

def esc(b):
    out = []
    for c in b:
        if 32 < c < 127 and c not in (37, 124, 92, 34, 44):
            out.append(chr(c))
        else:
            out.append("%%%02X" % c)
    return "".join(out)


def qs(b):
    return '"' + esc(b)


def os_(o):
    return "-" if o is None else qs(o)


def oi(o):
    return "-" if o is None else str(o)


def ob(o):
    return "-" if o is None else ("1" if o else "0")


def orat(o):
    return "-" if o is None else "%d/%d" % o


# ------------------------------------------------------------------ XML 1.0 layer

def is_name_start_strict(c):
    return (c == 58 or 65 <= c <= 90 or c == 95 or 97 <= c <= 122 or 0xC0 <= c <= 0xD6 or 0xD8 <= c <= 0xF6
            or 0xF8 <= c <= 0x2FF or 0x370 <= c <= 0x37D or 0x37F <= c <= 0x1FFF or 0x200C <= c <= 0x200D
            or 0x2070 <= c <= 0x218F or 0x2C00 <= c <= 0x2FEF or 0x3001 <= c <= 0xD7FF or 0xF900 <= c <= 0xFDCF
            or 0xFDF0 <= c <= 0xFFFD or 0x10000 <= c <= 0xEFFFF)


def is_name_char_strict(c):
    return (is_name_start_strict(c) or c == 45 or c == 46 or 48 <= c <= 57 or c == 0xB7 or 0x300 <= c <= 0x36F
            or 0x203F <= c <= 0x2040)


def is_char(c):
    return c in (9, 10, 13) or 0x20 <= c <= 0xD7FF or 0xE000 <= c <= 0xFFFD or 0x10000 <= c <= 0x10FFFF


def is_ws(c):
    return c in (32, 9, 10, 13)


def utf8(cp):
    return chr(cp).encode("utf-8", "surrogatepass")


class Elem:
    __slots__ = ("name", "local", "attrs", "text", "children")

    def __init__(self, name, attrs, text, children):
        self.name = name
        self.local = name.split(b":", 1)[1] if b":" in name else name
        self.attrs = attrs
        self.text = text
        self.children = children

    def get(self, local):  # design: lookup by local name, first match (namespaces are not resolved)
        for (n, v) in self.attrs:
            ln = n.split(b":", 1)[1] if b":" in n else n
            if ln == local:
                return v
        return None


class Xml:
    """Recursive-descent XML 1.0 parser without DTD support.

    strict (P2-5 off): input is decoded as UTF-8, every code point must match Char, end-of-line handling is applied
    to the whole entity, Name / PITarget / XMLDecl / ']]>' / character-reference rules are those of XML 1.0.
    lenient (P2-5 on): the package's byte-level lexer (C0 checks only in text / attributes / CDATA, every byte
    >= 0x80 is a name character, PI targets / XML declaration unchecked, '&#X..;' accepted, references longer than
    24 characters rejected, CR inside CDATA kept).
    attr_norm (P2-6 off): XML 1.0 3.3.3 attribute-value normalisation of literal TAB / LF (CR after EOL handling).
    """

    def __init__(self, data, lenient, attr_norm):
        self.lenient = lenient
        self.attr_norm = attr_norm
        if lenient:
            self.s = list(data)
        else:
            try:
                txt = data.decode("utf-8")
            except UnicodeDecodeError:
                raise Err("InvalidXml", "invalid UTF-8")
            for ch in txt:
                if not is_char(ord(ch)):
                    raise Err("InvalidXml", "not a Char")
            txt = txt.replace("\r\n", "\n").replace("\r", "\n")
            self.s = [ord(ch) for ch in txt]
        self.n = len(self.s)
        self.pos = 0
        self.elems = 0

    def out(self, units):
        if self.lenient:
            return bytes(units)
        return "".join(chr(c) for c in units).encode("utf-8", "surrogatepass")

    def at(self, lit, ci=False):
        k = len(lit)
        if self.pos + k > self.n:
            return False
        for i in range(k):
            c = self.s[self.pos + i]
            if ci and 97 <= c <= 122:
                c -= 32
            if c != lit[i]:
                return False
        return True

    def name_start(self, c):
        return (65 <= c <= 90 or 97 <= c <= 122 or c in (95, 58) or c >= 128) if self.lenient else is_name_start_strict(c)

    def name_char(self, c):
        return (self.name_start(c) or 48 <= c <= 57 or c in (45, 46)) if self.lenient else is_name_char_strict(c)

    def name(self):
        if self.pos >= self.n or not self.name_start(self.s[self.pos]):
            raise Err("InvalidXml", "expected name")
        st = self.pos
        self.pos += 1
        while self.pos < self.n and self.name_char(self.s[self.pos]):
            self.pos += 1
        return self.out(self.s[st:self.pos])

    def skip_ws(self):
        while self.pos < self.n and is_ws(self.s[self.pos]):
            self.pos += 1

    def comment(self):
        self.pos += 4
        while self.pos + 2 < self.n:
            if self.s[self.pos] == 45 and self.s[self.pos + 1] == 45:
                if self.s[self.pos + 2] == 62:
                    self.pos += 3
                    return
                raise Err("InvalidXml", "-- in comment")
            self.pos += 1
        raise Err("InvalidXml", "unterminated comment")

    def pi(self, first):
        self.pos += 2
        if not self.lenient:
            st = self.pos
            tgt = self.name()  # PITarget is a Name ...
            if tgt == b"xml" and first and st == 2 + self.bom:
                self.xmldecl()
                return
            if tgt.lower() == b"xml":
                raise Err("InvalidXml", "reserved PI target / XML declaration not at the start")
            if self.pos < self.n and not is_ws(self.s[self.pos]) and not self.at(b"?>"):
                raise Err("InvalidXml", "PI target")
        while self.pos + 1 < self.n:
            if self.s[self.pos] == 63 and self.s[self.pos + 1] == 62:
                self.pos += 2
                return
            self.pos += 1
        raise Err("InvalidXml", "unterminated PI")

    def xmldecl(self):
        # XMLDecl ::= '<?xml' VersionInfo EncodingDecl? SDDecl? S? '?>'
        def attr(nm):
            self.skip_ws()
            if not self.at(nm):
                return None
            self.pos += len(nm)
            self.skip_ws()
            if not self.at(b"="):
                raise Err("InvalidXml", "XMLDecl")
            self.pos += 1
            self.skip_ws()
            if self.pos >= self.n or self.s[self.pos] not in (34, 39):
                raise Err("InvalidXml", "XMLDecl")
            q = self.s[self.pos]
            self.pos += 1
            st = self.pos
            while self.pos < self.n and self.s[self.pos] != q:
                self.pos += 1
            if self.pos >= self.n:
                raise Err("InvalidXml", "XMLDecl")
            v = self.out(self.s[st:self.pos])
            self.pos += 1
            return v
        if self.pos >= self.n or not is_ws(self.s[self.pos]):
            raise Err("InvalidXml", "XMLDecl")
        v = attr(b"version")
        if v is None or not (v.startswith(b"1.") and len(v) > 2 and v[2:].isdigit()):
            raise Err("InvalidXml", "VersionNum")
        p0 = self.pos
        e = attr(b"encoding")
        if e is not None:
            if self.s[p0] not in (9, 10, 13, 32) or e.lower() not in (b"utf-8",):
                raise Err("InvalidXml", "EncodingDecl")
        p0 = self.pos
        sd = attr(b"standalone")
        if sd is not None and (sd not in (b"yes", b"no") or self.s[p0] not in (9, 10, 13, 32)):
            raise Err("InvalidXml", "SDDecl")
        self.skip_ws()
        if not self.at(b"?>"):
            raise Err("InvalidXml", "XMLDecl end")
        self.pos += 2

    def cdata(self):
        self.pos += 9
        st = self.pos
        while self.pos + 2 < self.n:
            if self.s[self.pos] == 93 and self.s[self.pos + 1] == 93 and self.s[self.pos + 2] == 62:
                v = self.s[st:self.pos]
                self.pos += 3
                if len(self.out(v)) > LIM["max_text_bytes"]:
                    raise Err("LimitExceeded", "cdata")
                return self.out(v)
            c = self.s[self.pos]
            if c < 32 and c not in (9, 10, 13):
                raise Err("InvalidXml", "C0 in CDATA")
            self.pos += 1
        raise Err("InvalidXml", "unterminated CDATA")

    def decode(self, units, is_attr):
        """Character data / attribute value with references; returns bytes."""
        out = []
        i = 0
        n = len(units)
        if not self.lenient and not is_attr:
            # CharData must not contain ']]>'
            for k in range(n - 2):
                if units[k] == 93 and units[k + 1] == 93 and units[k + 2] == 62:
                    raise Err("InvalidXml", "]]> in content")
        while i < n:
            c = units[i]
            if c < 32 and c not in (9, 10, 13):
                raise Err("InvalidXml", "C0")
            if c == 13:  # lenient mode only (strict input is EOL-normalised already)
                if i + 1 < n and units[i + 1] == 10:
                    i += 1
                out.append(32 if (is_attr and self.attr_norm) else 10)
                i += 1
                continue
            if c != 38:
                if is_attr and self.attr_norm and c in (9, 10):
                    out.append(32)
                else:
                    out.append(c)
                i += 1
                continue
            semi = i + 1
            if self.lenient:
                while semi < n and units[semi] != 59 and semi - i <= 24:
                    semi += 1
            else:
                while semi < n and units[semi] != 59:
                    semi += 1
            if semi >= n or units[semi] != 59:
                raise Err("InvalidXml", "unterminated reference")
            body = bytes(b if b < 128 else 63 for b in units[i + 1:semi])
            pre = {b"amp": 38, b"lt": 60, b"gt": 62, b"quot": 34, b"apos": 39}
            if body in pre:
                out.append(pre[body])
            elif len(body) >= 2 and body[0:1] == b"#":
                hexa = body[1:2] == b"x" or (self.lenient and body[1:2] == b"X")
                digs = body[2:] if hexa else body[1:]
                ok = b"0123456789abcdefABCDEF" if hexa else b"0123456789"
                if len(digs) == 0 or any(d not in ok for d in digs):
                    raise Err("InvalidXml", "char ref")
                cp = int(digs, 16 if hexa else 10)
                if not is_char(cp):
                    raise Err("InvalidXml", "char ref not a Char")
                if self.lenient:
                    out.extend(utf8(cp))
                else:
                    out.append(cp)
            else:
                raise Err("InvalidXml", "unknown entity")
            i = semi + 1
        v = self.out(out)
        if len(v) > LIM["max_text_bytes"]:
            raise Err("LimitExceeded", "text")
        return v

    def element(self, depth):
        if depth > LIM["max_xml_depth"]:
            raise Err("LimitExceeded", "depth")
        self.elems += 1
        if self.elems > LIM["max_elements"]:
            raise Err("LimitExceeded", "elements")
        self.pos += 1
        nm = self.name()
        attrs = []
        selfclose = False
        while True:
            had_ws = self.pos < self.n and is_ws(self.s[self.pos])
            self.skip_ws()
            if self.pos >= self.n:
                raise Err("InvalidXml", "EOF in tag")
            c = self.s[self.pos]
            if c == 62:
                self.pos += 1
                break
            if c == 47:
                if self.pos + 1 >= self.n or self.s[self.pos + 1] != 62:
                    raise Err("InvalidXml", "/")
                self.pos += 2
                selfclose = True
                break
            if not had_ws:
                raise Err("InvalidXml", "ws before attribute")
            if len(attrs) >= LIM["max_attributes"]:
                raise Err("LimitExceeded", "attributes")
            an = self.name()
            if any(a == an for (a, _) in attrs):
                raise Err("InvalidXml", "duplicate attribute")
            self.skip_ws()
            if self.pos >= self.n or self.s[self.pos] != 61:
                raise Err("InvalidXml", "=")
            self.pos += 1
            self.skip_ws()
            if self.pos >= self.n or self.s[self.pos] not in (34, 39):
                raise Err("InvalidXml", "quote")
            q = self.s[self.pos]
            self.pos += 1
            st = self.pos
            while self.pos < self.n and self.s[self.pos] != q:
                if self.s[self.pos] == 60:
                    raise Err("InvalidXml", "< in attribute")
                self.pos += 1
            if self.pos >= self.n:
                raise Err("InvalidXml", "unterminated attribute")
            raw = self.s[st:self.pos]
            self.pos += 1
            attrs.append((an, self.decode(raw, True)))
        if selfclose:
            return Elem(nm, attrs, b"", [])
        children = []
        text = []
        tlen = 0
        while self.pos < self.n:
            if self.s[self.pos] == 60:
                if self.at(b"</"):
                    self.pos += 2
                    cn = self.name()
                    self.skip_ws()
                    if self.pos >= self.n or self.s[self.pos] != 62:
                        raise Err("InvalidXml", "close >")
                    self.pos += 1
                    if cn != nm:
                        raise Err("InvalidXml", "mismatched close tag")
                    return Elem(nm, attrs, b"".join(text), children)
                elif self.at(b"<!--"):
                    self.comment()
                elif self.at(b"<![CDATA["):
                    cd = self.cdata()
                    tlen += len(cd)
                    if tlen > LIM["max_text_bytes"]:
                        raise Err("LimitExceeded", "text")
                    text.append(cd)
                elif self.at(b"<!DOCTYPE", True) or self.at(b"<!ENTITY", True):
                    raise Err("SecurityRejected", "doctype")
                elif self.at(b"<?"):
                    self.pi(False)
                elif self.at(b"<!"):
                    raise Err("InvalidXml", "<!")
                else:
                    children.append(self.element(depth + 1))
            else:
                st = self.pos
                while self.pos < self.n and self.s[self.pos] != 60:
                    self.pos += 1
                d = self.decode(self.s[st:self.pos], False)
                tlen += len(d)
                if tlen > LIM["max_text_bytes"]:
                    raise Err("LimitExceeded", "text")
                text.append(d)
        raise Err("InvalidXml", "unclosed")

    def document(self):
        self.bom = 0
        if self.lenient:
            if self.n >= 3 and self.s[0:3] == [0xEF, 0xBB, 0xBF]:
                self.pos = 3
                self.bom = 3
        elif self.n >= 1 and self.s[0] == 0xFEFF:
            self.pos = 1
            self.bom = 1
        root = None
        first = True
        while self.pos < self.n:
            self.skip_ws()
            if self.pos >= self.n:
                break
            if self.s[self.pos] != 60:
                raise Err("InvalidXml", "text outside root")
            if self.at(b"<!--"):
                self.comment()
            elif self.at(b"<?"):
                self.pi(first)
            elif self.at(b"<!DOCTYPE", True) or self.at(b"<!ENTITY", True):
                raise Err("SecurityRejected", "doctype")
            elif self.at(b"<!") or self.at(b"</"):
                raise Err("InvalidXml", "markup in prolog")
            else:
                if root is not None:
                    raise Err("InvalidXml", "multiple roots")
                root = self.element(1)
            first = False
        if root is None:
            raise Err("InvalidXml", "empty")
        return root


# ------------------------------------------------------------------ xs: lexical spaces

def trim(b):
    return b.strip(b" \t\n\r")


def nonneg(b, fl, plus=True):
    s = trim(b)
    if plus and not fl.on("P2-4") and s[:1] == b"+":  # xs:unsignedInt / unsignedLong allow a leading '+'
        s = s[1:]
    if not s or not s.isdigit() or not s.isascii():
        raise Err("InvalidNumber", "nonneg")
    v = int(s)
    if v > I64_MAX:
        raise Err("InvalidNumber", "overflow")  # design: Int64 range
    return v


def posint(b, fl, plus=True):
    v = nonneg(b, fl, plus)
    if v <= 0:
        raise Err("InvalidNumber", "positive")
    return v


def signed(b):  # S@r: optional sign (both '+' and '-')
    s = trim(b)
    neg = False
    if s[:1] in (b"-", b"+"):
        neg = s[:1] == b"-"
        s = s[1:]
    if not s or not s.isdigit() or not s.isascii():
        raise Err("InvalidNumber", "int")
    v = -int(s) if neg else int(s)
    if v > I64_MAX or v < I64_MIN:
        raise Err("InvalidNumber", "range")
    return v


def boolean(b):
    s = trim(b)
    if s in (b"true", b"1"):
        return True
    if s in (b"false", b"0"):
        return False
    raise Err("InvalidMpd", "bool")


def duration_us(b, fl):
    """xs:duration subset used by DASH (design: non-negative only; Y = 365 d, M = 30 d; W accepted; >6 fraction
    digits truncated; Int64 microseconds)."""
    s = trim(b)
    if len(s) < 2 or s[0:1] != b"P":
        raise Err("InvalidDuration", "P")
    i = 1
    n = len(s)
    in_t = False
    last = 0
    total = 0
    anyc = False
    while i < n:
        if s[i] == 84:
            if in_t:
                raise Err("InvalidDuration", "T")
            in_t = True
            i += 1
            if i >= n:
                raise Err("InvalidDuration", "T")
            continue
        st = i
        while i < n and 48 <= s[i] <= 57:
            i += 1
        if i == st:
            raise Err("InvalidDuration", "digits")
        num = int(s[st:i])
        if num > I64_MAX:
            raise Err("InvalidDuration", "overflow")
        frac = None
        if i < n and (s[i] == 46 or (s[i] == 44 and fl.on("P2-4"))):  # xs:duration: '.' only
            i += 1
            fs = i
            while i < n and 48 <= s[i] <= 57:
                i += 1
            if i == fs:
                raise Err("InvalidDuration", "fraction")
            frac = int((s[fs:i] + b"000000")[:6])
        if i >= n:
            raise Err("InvalidDuration", "unit")
        u = s[i]
        i += 1
        if not in_t:
            tbl = {89: (1, 31536000000000), 77: (2, 2592000000000), 87: (3, 604800000000), 68: (4, 86400000000)}
        else:
            tbl = {72: (5, 3600000000), 77: (6, 60000000), 83: (7, 1000000)}
        if u not in tbl:
            raise Err("InvalidDuration", "unit")
        rank, mult = tbl[u]
        if frac is not None and rank != 7:
            raise Err("InvalidDuration", "fraction")
        if rank <= last:
            raise Err("InvalidDuration", "order")
        last = rank
        anyc = True
        total += num * mult + (frac or 0)
        if total > I64_MAX or num * mult > I64_MAX:
            raise Err("InvalidDuration", "overflow")
    if not anyc:
        raise Err("InvalidDuration", "empty")
    return total


def days_from_civil(y, m, d):
    y -= m <= 2
    era = (y if y >= 0 else y - 399) // 400
    yoe = y - era * 400
    mp = m - 3 if m > 2 else m + 9
    doy = (153 * mp + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def leap(y):
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


def mdays(y, m):
    return 29 if m == 2 and leap(y) else 28 if m == 2 else 30 if m in (4, 6, 9, 11) else 31


def datetime_us(b, fl):
    """xs:dateTime (4-digit years, design). Spec: 'T' / 'Z' upper case, zone optional (DASH-IF: then UTC),
    offset +-HH:MM up to 14:00, 24:00:00 = next day. Emu (P2-4): the package's grammar."""
    s = trim(b)
    lenient = fl.on("P2-4")
    if lenient and len(s) < 20:
        raise Err("InvalidDateTime", "short")

    def dig(st, k):
        v = s[st:st + k]
        if len(v) != k or not v.isdigit() or not v.isascii():
            raise Err("InvalidDateTime", "digits")
        return int(v)
    if len(s) < 19:
        raise Err("InvalidDateTime", "short")
    y = dig(0, 4)
    if s[4] != 45:
        raise Err("InvalidDateTime", "-")
    mo = dig(5, 2)
    if not 1 <= mo <= 12 or s[7] != 45:
        raise Err("InvalidDateTime", "month")
    d = dig(8, 2)
    if not 1 <= d <= mdays(y, mo):
        raise Err("InvalidDateTime", "day")
    if not (s[10] == 84 or (lenient and s[10] == 116)):
        raise Err("InvalidDateTime", "T")
    h = dig(11, 2)
    if s[13] != 58:
        raise Err("InvalidDateTime", ":")
    mi = dig(14, 2)
    if s[16] != 58:
        raise Err("InvalidDateTime", ":")
    se = dig(17, 2)
    i = 19
    frac = 0
    fdig = b""
    if i < len(s) and s[i] == 46:
        i += 1
        fs = i
        while i < len(s) and 48 <= s[i] <= 57:
            i += 1
        if i == fs:
            raise Err("InvalidDateTime", "fraction")
        fdig = s[fs:i]
        frac = int((fdig + b"000000")[:6])
    if lenient:
        if h > 23:
            raise Err("InvalidDateTime", "hour")
    else:
        if h > 24 or (h == 24 and (mi != 0 or se != 0 or fdig.strip(b"0"))):
            raise Err("InvalidDateTime", "hour")
    if mi > 59 or se > 59:
        raise Err("InvalidDateTime", "range")
    off = 0
    if i >= len(s):
        if lenient:
            raise Err("InvalidDateTime", "zone")
    elif s[i] == 90 or (lenient and s[i] == 122):
        i += 1
    elif s[i] in (43, 45):
        sign = 1 if s[i] == 43 else -1
        i += 1
        th = dig(i, 2)
        i += 2
        if i >= len(s) or s[i] != 58:
            raise Err("InvalidDateTime", "zone")
        i += 1
        tm = dig(i, 2)
        i += 2
        if lenient:
            if th > 23 or tm > 59:
                raise Err("InvalidDateTime", "zone")
        elif tm > 59 or th > 14 or (th == 14 and tm != 0):
            raise Err("InvalidDateTime", "zone")
        off = sign * (th * 3600 + tm * 60)
    else:
        raise Err("InvalidDateTime", "zone")
    if i != len(s):
        raise Err("InvalidDateTime", "trailing")
    secs = days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se - off
    return secs * 1000000 + frac


def rational(b, fl):  # design: FrameRateType with positive numerator / denominator
    s = trim(b)
    if not s:
        raise Err("InvalidNumber", "empty")
    if s.count(b"/") > 1:
        raise Err("InvalidNumber", "/")
    if b"/" in s:
        a, c = s.split(b"/")
        return (posint(a, fl, False), posint(c, fl, False))  # a pattern-restricted string: no sign
    return (posint(s, fl, False), 1)


def fmt_duration(us):
    if us <= 0:
        return "PT0S"
    ts, rem = divmod(us, 1000000)
    h, m, s = ts // 3600, (ts % 3600) // 60, ts % 60
    out = "PT"
    if h:
        out += "%dH" % h
    if m:
        out += "%dM" % m
    if s or rem or (h == 0 and m == 0):
        out += str(s)
        if rem:
            out += "." + ("%06d" % rem).rstrip("0")
        out += "S"
    return out


# ------------------------------------------------------------------ MPD model

class Flags:
    def __init__(self, on, choice=None):
        self.set = set(on)
        self.choice = choice or {}
        self.hit = set()

    def on(self, f):
        return f in self.set

    def pick(self, point, n):
        """A spec choice point with n alternatives (enumerated by run_case)."""
        self.hit.add((point, n))
        return self.choice.get(point, 0)


def opt(el, nm, fn):
    v = el.get(nm)
    return None if v is None else fn(v)


def descriptor(el):
    sc = el.get(b"schemeIdUri")
    if sc is None:
        raise Err("InvalidMpd", "schemeIdUri")
    return (sc, el.get(b"value"), el.get(b"id"))


def content_protection(el):
    sc = el.get(b"schemeIdUri")
    if sc is None:
        raise Err("InvalidMpd", "schemeIdUri")
    pssh = [trim(c.text) for c in el.children if c.local == b"pssh"]
    return (sc, el.get(b"value"), el.get(b"default_KID"), pssh)


def init_child(el):
    src = rng = None
    for c in el.children:
        if c.local == b"Initialization":
            src, rng = c.get(b"sourceURL"), c.get(b"range")
    return src, rng


def seg_base(el, fl):
    src, rng = init_child(el)
    return dict(timescale=opt(el, b"timescale", lambda v: posint(v, fl)),
                pto=opt(el, b"presentationTimeOffset", lambda v: nonneg(v, fl)),
                index_range=el.get(b"indexRange"), exact=opt(el, b"indexRangeExact", boolean), init_src=src,
                init_range=rng)


def seg_list(el, fl):
    src, rng = init_child(el)
    urls = []
    for c in el.children:
        if c.local == b"SegmentURL":
            if len(urls) >= LIM["max_segments"]:
                raise Err("LimitExceeded", "SegmentURL")
            urls.append((c.get(b"media"), c.get(b"mediaRange"), c.get(b"index"), c.get(b"indexRange")))
    return dict(timescale=opt(el, b"timescale", lambda v: posint(v, fl)),
                duration=opt(el, b"duration", lambda v: posint(v, fl)),
                start_number=opt(el, b"startNumber", lambda v: nonneg(v, fl)),
                pto=opt(el, b"presentationTimeOffset", lambda v: nonneg(v, fl)), init_src=src, init_range=rng,
                urls=urls)


def seg_template(el, fl):
    tl = []
    for c in el.children:
        if c.local != b"SegmentTimeline":
            continue
        for s in c.children:
            if s.local != b"S":
                continue
            if len(tl) >= LIM["max_timeline_entries"]:
                raise Err("LimitExceeded", "S")
            t = opt(s, b"t", lambda v: nonneg(v, fl))
            dv = s.get(b"d")
            if dv is None:
                raise Err("InvalidMpd", "S@d")
            d = posint(dv, fl)
            r = 0 if s.get(b"r") is None else signed(s.get(b"r"))
            if r < -1 and not fl.on("P2-2"):
                if fl.pick("r<-1", 2) == 0:
                    raise Err("InvalidMpd", "S@r < -1")  # alternative 1: rejected at resolution time
            tl.append((t, d, r))
    return dict(timescale=opt(el, b"timescale", lambda v: posint(v, fl)),
                duration=opt(el, b"duration", lambda v: posint(v, fl)),
                start_number=opt(el, b"startNumber", lambda v: nonneg(v, fl)),
                pto=opt(el, b"presentationTimeOffset", lambda v: nonneg(v, fl)), init=el.get(b"initialization"),
                media=el.get(b"media"), timeline=tl)


def seg_children(el, fl):
    sb = sl = st = None
    for c in el.children:  # design: the last element of each kind wins
        if c.local == b"SegmentBase":
            sb = seg_base(c, fl)
        elif c.local == b"SegmentList":
            sl = seg_list(c, fl)
        elif c.local == b"SegmentTemplate":
            st = seg_template(c, fl)
    return sb, sl, st


def representation(el, fl):
    rid = el.get(b"id")
    if rid is None or rid == b"":
        raise Err("InvalidMpd", "Representation@id")
    bw = el.get(b"bandwidth")
    if bw is None:
        raise Err("InvalidMpd", "bandwidth")
    r = dict(id=rid, bandwidth=posint(bw, fl))
    # xs:unsignedInt width / height: 0 is a valid value (P2-4: the package requires > 0)
    dim = (lambda v: posint(v, fl)) if fl.on("P2-4") else (lambda v: nonneg(v, fl))
    r.update(width=opt(el, b"width", dim), height=opt(el, b"height", dim),
             frame_rate=opt(el, b"frameRate", lambda v: rational(v, fl)),
             sap=opt(el, b"startWithSAP", lambda v: nonneg(v, fl)), sar=el.get(b"sar"), codecs=el.get(b"codecs"),
             mime=el.get(b"mimeType"), asr=el.get(b"audioSamplingRate"))
    r["bu"] = [trim(c.text) for c in el.children if c.local == b"BaseURL"]
    r["cp"] = [content_protection(c) for c in el.children if c.local == b"ContentProtection"]
    r["ach"] = [descriptor(c) for c in el.children if c.local == b"AudioChannelConfiguration"]
    r["sb"], r["sl"], r["st"] = seg_children(el, fl)
    return r


def adaptation_set(el, fl, tot):
    a = dict(id=el.get(b"id"), group=opt(el, b"group", lambda v: nonneg(v, fl)), ct=el.get(b"contentType"),
             mime=el.get(b"mimeType"), codecs=el.get(b"codecs"), lang=el.get(b"lang"),
             sa=opt(el, b"segmentAlignment", boolean), ssa=opt(el, b"subsegmentAlignment", boolean),
             bss=opt(el, b"bitstreamSwitching", boolean))
    for k, nm in (("minbw", b"minBandwidth"), ("maxbw", b"maxBandwidth"), ("minw", b"minWidth"), ("maxw", b"maxWidth"),
                  ("minh", b"minHeight"), ("maxh", b"maxHeight"), ("sap", b"startWithSAP")):
        a[k] = opt(el, nm, lambda v: nonneg(v, fl))
    a.update(par=el.get(b"par"), frame_rate=opt(el, b"frameRate", lambda v: rational(v, fl)), sar=el.get(b"sar"),
             asr=el.get(b"audioSamplingRate"))
    a["bu"] = []
    a["role"], a["cp"], a["acc"], a["ach"], a["supp"], a["ess"], a["reps"] = [], [], [], [], [], [], []
    m = {b"Role": "role", b"Accessibility": "acc", b"AudioChannelConfiguration": "ach", b"SupplementalProperty": "supp",
         b"EssentialProperty": "ess"}
    for c in el.children:
        if c.local == b"BaseURL":
            a["bu"].append(trim(c.text))
        elif c.local in m:
            a[m[c.local]].append(descriptor(c))
        elif c.local == b"ContentProtection":
            a["cp"].append(content_protection(c))
        elif c.local == b"Representation":
            if tot["rep"] >= LIM["max_representations"]:
                raise Err("LimitExceeded", "reps")
            tot["rep"] += 1
            a["reps"].append(representation(c, fl))
    a["sb"], a["sl"], a["st"] = seg_children(el, fl)
    return a


def period(el, fl, tot):
    p = dict(id=el.get(b"id"), start=opt(el, b"start", lambda v: duration_us(v, fl)),
             dur=opt(el, b"duration", lambda v: duration_us(v, fl)), bss=opt(el, b"bitstreamSwitching", boolean))
    p["bu"] = [trim(c.text) for c in el.children if c.local == b"BaseURL"]
    p["as"] = []
    for c in el.children:
        if c.local == b"AdaptationSet":
            if tot["as"] >= LIM["max_adaptation_sets"]:
                raise Err("LimitExceeded", "as")
            tot["as"] += 1
            p["as"].append(adaptation_set(c, fl, tot))
    p["sb"], p["sl"], p["st"] = seg_children(el, fl)
    return p


def mpd(root, fl):
    if root.local != b"MPD":
        raise Err("InvalidMpd", "root")
    t = root.get(b"type")
    if t is not None and t not in (b"static", b"dynamic"):
        raise Err("InvalidMpd", "type")
    m = dict(id=root.get(b"id"), type=b"dynamic" if t == b"dynamic" else b"static",
             profiles=root.get(b"profiles") or b"")
    for k, nm in (("dur", b"mediaPresentationDuration"), ("mbt", b"minBufferTime"), ("mup", b"minimumUpdatePeriod"),
                  ("tsbd", b"timeShiftBufferDepth"), ("spd", b"suggestedPresentationDelay"),
                  ("msd", b"maxSegmentDuration")):
        m[k] = opt(root, nm, lambda v: duration_us(v, fl))
    m["ast"] = root.get(b"availabilityStartTime")
    m["ast_us"] = None if m["ast"] is None else datetime_us(m["ast"], fl)
    m["pt"] = root.get(b"publishTime")
    m["pt_us"] = None if m["pt"] is None else datetime_us(m["pt"], fl)
    m["bu"], m["loc"], m["utc"], m["periods"] = [], [], [], []
    tot = {"as": 0, "rep": 0}
    for c in root.children:
        if c.local == b"BaseURL":
            m["bu"].append(trim(c.text))
        elif c.local == b"Location":
            m["loc"].append(trim(c.text))
        elif c.local == b"UTCTiming":
            m["utc"].append(descriptor(c))
        elif c.local == b"Period":
            if len(m["periods"]) >= LIM["max_periods"]:
                raise Err("LimitExceeded", "periods")
            m["periods"].append(period(c, fl, tot))
    return m


# ------------------------------------------------------------------ RFC 3986 reference resolution

def split_ref(u):
    """RFC 3986 appendix B: scheme, authority, path, query, fragment (None when absent)."""
    scheme = auth = query = frag = None
    i = 0
    n = len(u)
    # scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"
    if n and (65 <= (u[0] | 32) - 32 <= 90 or 97 <= u[0] <= 122):
        k = 1
        while k < n and (u[k:k + 1].isalnum() and u[k] < 128 or u[k] in b"+-."):
            k += 1
        if k < n and u[k] == 58:
            scheme = u[:k]
            i = k + 1
    rest = u[i:]
    if b"#" in rest:
        rest, frag = rest.split(b"#", 1)
    if b"?" in rest:
        rest, query = rest.split(b"?", 1)
    if rest.startswith(b"//"):
        k = 2
        while k < len(rest) and rest[k] != 47:
            k += 1
        auth = rest[2:k]
        rest = rest[k:]
    return scheme, auth, rest, query, frag


def remove_dot_segments(path, keep_leading=False):
    """RFC 3986 5.2.4. keep_leading: for a relative (rootless) base, '..' that cannot be resolved is kept, so that
    the composed reference resolves exactly like the chain against any document URL (design for relative bases,
    which RFC 3986 leaves undefined)."""
    inp = path
    out = []
    lead = []
    while inp:
        if inp.startswith(b"../"):
            inp = inp[3:]
            if keep_leading and not out:
                lead.append(b"../")
            elif out:
                out.pop()
        elif inp.startswith(b"./"):
            inp = inp[2:]
        elif inp.startswith(b"/./"):
            inp = b"/" + inp[3:]
        elif inp == b"/.":
            inp = b"/"
        elif inp.startswith(b"/../"):
            inp = b"/" + inp[4:]
            if out:
                out.pop()
        elif inp == b"/..":
            inp = b"/"
            if out:
                out.pop()
        elif inp in (b".", b".."):
            if inp == b".." and keep_leading and not out:
                lead.append(b"../")
            inp = b""
        else:
            k = inp.find(b"/", 1) if inp.startswith(b"/") else inp.find(b"/")
            if k < 0:
                k = len(inp)
            out.append(inp[:k])
            inp = inp[k:]
    return b"".join(lead) + b"".join(out)


def rootless_norm(p):
    """Dot-segment removal for a rootless relative path (relative BaseURL chains, which RFC 3986 does not define):
    '..' that cannot be resolved is kept, empty segments are kept, a final '.' / '..' leaves a trailing '/', so the
    composed reference resolves exactly like the chain against any document URL."""
    segs = p.split(b"/")
    out = []
    for i, sg in enumerate(segs):
        last = i == len(segs) - 1
        if sg == b".":
            if last:
                out.append(b"")
            continue
        if sg == b"..":
            if out and out[-1] != b"..":
                out.pop()
            else:
                out.append(b"..")
            if last:
                out.append(b"")
            continue
        out.append(sg)
    return b"/".join(out)


def rfc_resolve(base, rel):
    if rel == b"":
        return base
    if base == b"":
        return rel
    rs, ra, rp, rq, rf = split_ref(rel)
    bs, ba, bp, bq, bf = split_ref(base)
    if rs is not None:
        ts, ta, tp, tq = rs, ra, remove_dot_segments(rp), rq
    else:
        if ra is not None:
            ta, tp, tq = ra, remove_dot_segments(rp), rq
        else:
            if rp == b"":
                tp = bp
                tq = rq if rq is not None else bq
            else:
                if rp.startswith(b"/"):
                    tp = remove_dot_segments(rp)
                else:
                    if ba is not None and bp == b"":
                        merged = b"/" + rp
                    else:
                        k = bp.rfind(b"/")
                        merged = (bp[:k + 1] if k >= 0 else b"") + rp
                    rootless = bs is None and ba is None and not merged.startswith(b"/")
                    tp = rootless_norm(merged) if rootless else remove_dot_segments(merged)
                tq = rq
            ta = ba
        ts = bs
    out = b""
    if ts is not None:
        out += ts + b":"
    if ta is not None:
        out += b"//" + ta
    out += tp
    if tq is not None:
        out += b"?" + tq
    if rf is not None:
        out += b"#" + rf
    return out


def pkg_resolve(base, rel):
    """Emu (P1-1): the package's documented algorithm, re-derived from its observable behaviour (path segments are
    split on '/', empty / '.' segments dropped, '..' pops if possible, trailing '/' kept only if the input ends with
    '/', the base query / fragment dropped, absolute references returned verbatim)."""
    def scheme_end(s):
        if not s or not (65 <= s[0] <= 90 or 97 <= s[0] <= 122):
            return -1
        for i in range(1, len(s)):
            c = s[i]
            if c == 58:
                return i
            if not (65 <= c <= 90 or 97 <= c <= 122 or 48 <= c <= 57 or c in (43, 45, 46)):
                return -1
        return -1

    def norm(p):
        lead = p.startswith(b"/")
        trail = p.endswith(b"/")
        segs = []
        for part in p.split(b"/"):
            if part in (b"", b"."):
                continue
            if part == b"..":
                if segs:
                    segs.pop()
                continue
            segs.append(part)
        return (b"/" if lead else b"") + b"/".join(segs) + (b"/" if trail and segs else b"")
    if rel == b"":
        return base
    if base == b"":
        return rel
    if scheme_end(rel) >= 0:
        return rel
    sc = scheme_end(base)
    if rel.startswith(b"//"):
        return base[:sc + 1] + rel if sc >= 0 else rel
    be = len(base)
    for i, c in enumerate(base):
        if c in (63, 35):
            be = i
            break
    bc = base[:be]
    oe = 0
    if sc >= 0 and sc + 2 < len(bc) and bc[sc + 1] == 47 and bc[sc + 2] == 47:
        p = sc + 3
        while p < len(bc) and bc[p] != 47:
            p += 1
        oe = p
    re_ = len(rel)
    for i, c in enumerate(rel):
        if c in (63, 35):
            re_ = i
            break
    rp, rs = rel[:re_], rel[re_:]
    if rp.startswith(b"/"):
        return (bc[:oe] if oe > 0 else b"") + norm(rp) + rs
    if rp == b"":
        return bc + rs
    bp = bc[oe:] if oe > 0 else bc
    k = bp.rfind(b"/")
    merged = bp[:k + 1] + rp if k >= 0 else (b"/" + rp if oe > 0 else rp)
    return (bc[:oe] if oe > 0 else b"") + norm(merged) + rs


def resolve(base, rel, fl):
    a = pkg_resolve(base, rel)
    if fl.on("P1-1"):
        return a
    return rfc_resolve(base, rel)


# ------------------------------------------------------------------ SegmentTemplate expansion (5.3.9.4.4)

def expand(tpl, rid, number, bw, time):
    """Design: identifiers $$, $RepresentationID$, $Number$, $Bandwidth$, $Time$ with an optional '%[0]<w>d'
    (w <= 32, at most 4 digits); anything else is an error. Negative values are zero-padded after the sign
    character the way the package does it (outside the DASH value space)."""
    out = []
    i = 0
    n = len(tpl)
    while i < n:
        if tpl[i] != 36:
            j = tpl.find(b"$", i)
            j = n if j < 0 else j
            out.append(tpl[i:j])
            i = j
            continue
        if i + 1 < n and tpl[i + 1] == 36:
            out.append(b"$")
            i += 2
            continue
        e = tpl.find(b"$", i + 1)
        if e < 0:
            raise Err("InvalidTemplate", "unterminated")
        tok = tpl[i + 1:e]
        val = None
        for nm, v in ((b"RepresentationID", None), (b"Number", number), (b"Bandwidth", bw), (b"Time", time)):
            if tok == nm:
                val = rid if v is None else str(v).encode()
                break
            if v is not None and tok.startswith(nm) and len(tok) > len(nm):
                spec = tok[len(nm):]
                if len(spec) < 2 or spec[0:1] != b"%" or spec[-1:] != b"d":
                    raise Err("InvalidTemplate", "format")
                w = 0
                digs = 0
                for c in spec[1:-1]:
                    if not 48 <= c <= 57:
                        raise Err("InvalidTemplate", "width")
                    w = w * 10 + c - 48
                    digs += 1
                    if w > 32 or digs > 4:
                        raise Err("LimitExceeded", "width")
                s = str(v).encode()
                val = s if w <= len(s) else b"0" * (w - len(s)) + s
                break
        if val is None:
            raise Err("InvalidTemplate", "identifier")
        out.append(val)
        i = e + 1
    return b"".join(out)


# ------------------------------------------------------------------ resolution

def merge(p, c, keep_list):
    if p is None:
        return c
    if c is None:
        return p
    r = {}
    for k in c:
        if k == keep_list:
            r[k] = c[k] if c[k] else p[k]
        else:
            r[k] = c[k] if c[k] is not None else p[k]
    return r


def period_timing(m, fl):
    """Returns [(start_us|None, dur_us|None)]. Spec (5.3.2.1): absent Period@start is the previous start + duration,
    or 0 for the first Period of a static MPD; the duration is the next start - start, or (last Period)
    mediaPresentationDuration - start. Emu (P2-1): only explicit @start values are used."""
    ps = m["periods"]
    out = []
    if fl.on("P2-1"):
        for i, p in enumerate(ps):
            if p["dur"] is not None:
                out.append((p["start"], p["dur"]))
                continue
            d = None
            if i + 1 < len(ps) and p["start"] is not None and ps[i + 1]["start"] is not None and ps[i + 1]["start"] >= p["start"]:
                d = ps[i + 1]["start"] - p["start"]
            elif m["dur"] is not None:
                st = p["start"] or 0
                d = m["dur"] - st if m["dur"] >= st else 0
            out.append((p["start"], d))
        return out
    starts = []
    for i, p in enumerate(ps):
        if p["start"] is not None:
            s = p["start"]
        elif i == 0 and m["type"] == b"static":
            s = 0
        elif i > 0 and starts[i - 1] is not None and ps[i - 1]["dur"] is not None:
            s = starts[i - 1] + ps[i - 1]["dur"]
        else:
            s = None
        starts.append(s)
    for i, p in enumerate(ps):
        if p["dur"] is not None:
            out.append((starts[i], p["dur"]))
            continue
        d = None
        if i + 1 < len(ps):
            if starts[i] is not None and starts[i + 1] is not None and starts[i + 1] >= starts[i]:
                d = starts[i + 1] - starts[i]
        elif m["dur"] is not None:
            st = starts[i] or 0
            d = m["dur"] - st if m["dur"] >= st else 0
        out.append((starts[i], d))
    return out


def ticks(us, ts, fl):
    # design: floor(us * timescale / 1e6); spec arithmetic is exact (count = ceil(duration * ts / d))
    v = us * ts
    if fl.on("P2-1"):
        return (v // 1000000, False)
    return (v // 1000000, v % 1000000 != 0)


def seg(num, url, st, d, ts, rng):
    """url is bytes, or a thunk producing bytes (only materialised for the dumped segments)."""
    return (num, url, st, d, ts, rng)


def seg_line(t):
    num, url, st, d, ts, rng = t
    if callable(url):
        url = url()
    return "SEG|%d|%s|%d|%d|%d|%s\n" % (num, qs(url), st, d, ts, os_(rng))


def tpl_url(base, media, rid, num, bw, cur, fl):
    return lambda: resolve(base, expand(media, rid, num, bw, cur), fl)


def resolve_track(m, pi, ai, ri, fl):
    p = m["periods"][pi]
    a = p["as"][ai]
    r = a["reps"][ri]
    base = b""
    for lvl in (m, p, a, r):
        if lvl["bu"]:
            base = resolve(base, lvl["bu"][0], fl)
    tpl = merge(merge(p["st"], a["st"], "timeline"), r["st"], "timeline")
    lst = merge(merge(p["sl"], a["sl"], "urls"), r["sl"], "urls")
    sb = merge(merge(p["sb"], a["sb"], None), r["sb"], None)
    maxs = LIM["max_segments"]
    pdur = period_timing(m, fl)[pi][1]
    segs = []
    if tpl is not None:
        ts = tpl["timescale"] or 1
        sn = 1 if tpl["start_number"] is None else tpl["start_number"]
        init = None
        if tpl["init"] is not None:
            init = resolve(base, expand(tpl["init"], r["id"], sn, r["bandwidth"], 0), fl)
        if tpl["media"] is None:
            return init, None, None, segs
        media = tpl["media"]
        pto = tpl["pto"] or 0
        if tpl["timeline"]:
            pend = None
            if pdur is not None:
                tk, frac = ticks(pdur, ts, fl)
                if frac:
                    tk += 1  # exact end: segments starting before a fractional end tick belong to the Period
                pend = tk if fl.on("P1-3") else tk + pto  # 5.3.9.6: Period end on the timeline = PTO + duration
            cur = 0
            num = sn
            tl = tpl["timeline"]
            for k, (t, d, rr) in enumerate(tl):
                if t is not None:
                    cur = t
                if rr >= 0:
                    if rr >= maxs:
                        raise Err("LimitExceeded", "r")
                    cnt = rr + 1
                else:
                    if rr < -1 and not fl.on("P2-2"):
                        raise Err("InvalidMpd", "S@r < -1")  # alternative 1 of choice point r<-1
                    end = tl[k + 1][0] if k + 1 < len(tl) else pend
                    if end is None:
                        cnt = 1  # design: unknown Period end -> one segment (needs wall-clock / MPD update)
                    elif end <= cur:
                        cnt = 0
                    else:
                        cnt = -(-(end - cur) // d)
                        if cnt > maxs:
                            raise Err("LimitExceeded", "r=-1")
                stop = False
                for _ in range(cnt):
                    if len(segs) >= maxs:
                        raise Err("LimitExceeded", "segments")
                    if cur + d > I64_MAX:
                        raise Err("InvalidNumber", "time overflow")
                    if num > I64_MAX:  # spec: a segment that needs a number beyond Int64
                        if fl.pick("numwrap", 2) == 0:
                            raise Err("InvalidNumber", "number overflow")
                        stop = True
                        break
                    if not segs:
                        expand(media, r["id"], num, r["bandwidth"], cur)  # template errors do not depend on values
                    segs.append(seg(num, tpl_url(base, media, r["id"], num, r["bandwidth"], cur, fl), cur, d, ts, None))
                    cur += d
                    if fl.on("P1-2") and num + 1 > I64_MAX:
                        raise Err("InvalidNumber", "number overflow")  # emu: checked after the last segment too
                    num += 1
                if stop:
                    break
        elif tpl["duration"] is not None and pdur is not None:
            d = tpl["duration"]
            tk, frac = ticks(pdur, ts, fl)
            if tk > I64_MAX:
                raise Err("InvalidNumber", "ticks")
            cnt = -(-tk // d) if not frac else tk // d + 1
            if cnt > maxs:
                raise Err("LimitExceeded", "count")
            cur = 0
            num = sn
            for k in range(cnt):
                if cur + d > I64_MAX:
                    raise Err("InvalidNumber", "time overflow")
                if num > I64_MAX:
                    if fl.on("P1-2"):
                        num = wrap64(num)
                    elif fl.pick("numwrap", 2) == 0:
                        raise Err("InvalidNumber", "number overflow")
                    else:
                        break
                if not segs:
                    expand(media, r["id"], num, r["bandwidth"], cur)  # template errors do not depend on values
                segs.append(seg(num, tpl_url(base, media, r["id"], num, r["bandwidth"], cur, fl), cur, d, ts, None))
                cur += d
                num += 1
        return init, None, None, segs
    if lst is not None:
        ts = lst["timescale"] or 1
        d = lst["duration"] or 0
        sn = 1 if lst["start_number"] is None else lst["start_number"]
        init = resolve(base, lst["init_src"], fl) if lst["init_src"] is not None else (
            base if lst["init_range"] is not None and base else None)
        if len(lst["urls"]) > maxs:
            raise Err("LimitExceeded", "list")
        cur = 0
        for i, (med, mr, _ix, _ir) in enumerate(lst["urls"]):
            num = sn + i
            if num > I64_MAX:
                if fl.on("P1-2"):
                    num = wrap64(num)
                elif fl.pick("numwrap", 2) == 0:
                    raise Err("InvalidNumber", "number overflow")
                else:
                    break
            segs.append(seg(num, resolve(base, med, fl) if med is not None else base, cur, d, ts, mr))
            if d > 0:
                if cur + d > I64_MAX:
                    raise Err("InvalidNumber", "time overflow")
                cur += d
        return init, lst["init_range"], None, segs
    if sb is not None:
        ts = sb["timescale"] or 1
        init = resolve(base, sb["init_src"], fl) if sb["init_src"] is not None else (base if base else None)
        if base:
            dt = 0
            if pdur is not None:
                v = pdur * ts // 1000000
                dt = v if v <= I64_MAX else 0
            segs.append(seg(1, base, 0, dt, ts, None))
        return init, sb["init_range"], sb["index_range"], segs
    if base:
        segs.append(seg(1, base, 0, 0, 1, None))
    return None, None, None, segs


# ------------------------------------------------------------------ ABR

BUDGETS = (-1, 0, 500000, 1000000, 3000000, 10 ** 18)
PREFS = ((), (b"avc1",), (b"av01", b"avc1"), (b"mp4a",), (b"hvc1", b"hev1"), (b"AVC1",))


def codec_match(codec, pref):
    if not pref:
        return True
    if len(codec) < len(pref) or codec[:len(pref)].lower() != pref.lower():
        return False
    return len(codec) == len(pref) or codec[len(pref)] in (46, 44, 32)


def select(a, budget, prefs, fl):
    reps = a["reps"]
    if not reps:
        return None
    idx = list(range(len(reps)))
    if prefs:
        def ok(r):
            c = r["codecs"] if r["codecs"] is not None else a["codecs"]
            if c is None:
                return False
            # RFC 6381: @codecs is a comma-separated list; spec mode matches any listed codec
            cands = [c] if fl.on("P2-8") else [x.strip(b" ") for x in c.split(b",")]
            return any(codec_match(x, p) for x in cands for p in prefs)
        m = [i for i in idx if ok(reps[i])]
        if m:
            idx = m
    best, bbw = None, -1
    low, lbw = idx[0], reps[idx[0]]["bandwidth"]
    for i in idx:
        bw = reps[i]["bandwidth"]
        if bw <= budget and bw > bbw:
            best, bbw = i, bw
        if bw < lbw:
            low, lbw = i, bw
    return best if best is not None else low


# ------------------------------------------------------------------ dump

def w_segs(o, sb, sl, st):
    if sb is not None:
        o.append("SB|%s|%s|%s|%s|%s|%s\n" % (oi(sb["timescale"]), oi(sb["pto"]), os_(sb["index_range"]), ob(sb["exact"]),
                                              os_(sb["init_src"]), os_(sb["init_range"])))
    if sl is not None:
        o.append("LIST|%s|%s|%s|%s|%s|%s|%d\n" % (oi(sl["timescale"]), oi(sl["duration"]), oi(sl["start_number"]),
                                                  oi(sl["pto"]), os_(sl["init_src"]), os_(sl["init_range"]), len(sl["urls"])))
        for u in sl["urls"]:
            o.append("SU|%s|%s|%s|%s\n" % tuple(os_(x) for x in u))
    if st is not None:
        o.append("TPL|%s|%s|%s|%s|%s|%s|%d\n" % (oi(st["timescale"]), oi(st["duration"]), oi(st["start_number"]),
                                                 oi(st["pto"]), os_(st["init"]), os_(st["media"]), len(st["timeline"])))
        for (t, d, r) in st["timeline"]:
            o.append("S|%s|%d|%d\n" % (oi(t), d, r))


def w_desc(o, tag, ds):
    for (s, v, i) in ds:
        o.append("%s|%s|%s|%s\n" % (tag, qs(s), os_(v), os_(i)))


def w_cp(o, cps):
    for (s, v, k, ps) in cps:
        o.append("CP|%s|%s|%s|%d\n" % (qs(s), os_(v), os_(k), len(ps)))
        for x in ps:
            o.append("PSSH|%s\n" % qs(x))


def dump_structure(m):
    o = ["MPD|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" % (
        os_(m["id"]), m["type"].decode(), qs(m["profiles"]), oi(m["dur"]), oi(m["mbt"]), oi(m["mup"]), os_(m["ast"]),
        oi(m["ast_us"]), os_(m["pt"]), oi(m["pt_us"]), oi(m["tsbd"]), oi(m["spd"]), oi(m["msd"]))]
    o += ["BU|%s\n" % qs(x) for x in m["bu"]]
    o += ["LOC|%s\n" % qs(x) for x in m["loc"]]
    w_desc(o, "UTC", m["utc"])
    for pi, p in enumerate(m["periods"]):
        o.append("P|%d|%s|%s|%s|%s\n" % (pi, os_(p["id"]), oi(p["start"]), oi(p["dur"]), ob(p["bss"])))
        o += ["BU|%s\n" % qs(x) for x in p["bu"]]
        w_segs(o, p["sb"], p["sl"], p["st"])
        for ai, a in enumerate(p["as"]):
            o.append("A|%d.%d|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" % (
                pi, ai, os_(a["id"]), oi(a["group"]), os_(a["ct"]), os_(a["mime"]), os_(a["codecs"]), os_(a["lang"]),
                ob(a["sa"]), ob(a["ssa"]), ob(a["bss"]), oi(a["minbw"]), oi(a["maxbw"]), oi(a["minw"]), oi(a["maxw"]),
                oi(a["minh"]), oi(a["maxh"]), os_(a["par"]), orat(a["frame_rate"]), os_(a["sar"]), os_(a["asr"]),
                oi(a["sap"])))
            o += ["BU|%s\n" % qs(x) for x in a["bu"]]
            w_desc(o, "ROLE", a["role"])
            w_cp(o, a["cp"])
            w_desc(o, "ACC", a["acc"])
            w_desc(o, "ACH", a["ach"])
            w_desc(o, "SUPP", a["supp"])
            w_desc(o, "ESS", a["ess"])
            w_segs(o, a["sb"], a["sl"], a["st"])
            for ri, r in enumerate(a["reps"]):
                o.append("R|%d.%d.%d|%s|%d|%s|%s|%s|%s|%s|%s|%s|%s\n" % (
                    pi, ai, ri, qs(r["id"]), r["bandwidth"], oi(r["width"]), oi(r["height"]), orat(r["frame_rate"]),
                    os_(r["sar"]), os_(r["codecs"]), os_(r["mime"]), os_(r["asr"]), oi(r["sap"])))
                o += ["BU|%s\n" % qs(x) for x in r["bu"]]
                w_cp(o, r["cp"])
                w_desc(o, "ACH", r["ach"])
                w_segs(o, r["sb"], r["sl"], r["st"])
    return "".join(o)


def dump_tracks(m, fl):
    o = []
    for pi, p in enumerate(m["periods"]):
        for ai, a in enumerate(p["as"]):
            for ri, _r in enumerate(a["reps"]):
                tag = "TRK|%d.%d.%d|" % (pi, ai, ri)
                try:
                    init, ir, xr, segs = resolve_track(m, pi, ai, ri, fl)
                except Err as e:
                    o.append(tag + "ERR " + e.kind + "\n")
                    continue
                n = len(segs)
                o.append(tag + "%s|%s|%s|%d\n" % (os_(init), os_(ir), os_(xr), n))
                for k, s in enumerate(segs):
                    if k < 6 or k >= n - 3:
                        o.append(seg_line(s))
    return "".join(o)


def dump_abr(m, fl):
    o = []
    for pi, p in enumerate(m["periods"]):
        for ai, a in enumerate(p["as"]):
            parts = []
            for pr in PREFS:
                for b in BUDGETS:
                    v = select(a, b, pr, fl)
                    parts.append("-" if v is None else str(v))
            o.append("ABR|%d.%d|%s\n" % (pi, ai, ",".join(parts)))
    return "".join(o)


def text_has_cr(m):
    """format_mpd writes CR in element text unescaped, so a re-parse turns it into LF (only reachable from a parse
    while CR inside CDATA is kept, P2-5)."""
    texts = list(m["bu"]) + list(m["loc"])
    for p in m["periods"]:
        texts += p["bu"]
        for a in p["as"]:
            texts += a["bu"] + [x for cp in a["cp"] for x in cp[3]]
            for r in a["reps"]:
                texts += r["bu"] + [x for cp in r["cp"] for x in cp[3]]
    return any(b"\r" in t for t in texts)


def dump_doc(data, fl):
    try:
        if len(data) > LIM["max_input_bytes"]:
            raise Err("LimitExceeded", "input")
        root = Xml(data, fl.on("P2-5"), not fl.on("P2-6")).document()
        m = mpd(root, fl)
    except Err as e:
        return "ERR " + e.kind + "\n"
    except RecursionError:
        return "ERR LimitExceeded\n"
    fmt = "FMT|DIFF\n" if text_has_cr(m) else "FMT|SAME\n"
    return dump_structure(m) + dump_tracks(m, fl) + dump_abr(m, fl) + fmt


def spec_alternatives(data):
    """All outputs a conforming implementation may produce (enumerating the spec choice points it hits)."""
    seen = []
    todo = [{}]
    done = []
    while todo:
        ch = todo.pop()
        fl = Flags((), ch)
        out = dump_doc(data, fl)
        if out not in seen:
            seen.append(out)
        done.append(ch)
        for (pt, n) in fl.hit:
            if pt not in ch:
                for k in range(1, n):
                    c2 = dict(ch)
                    c2[pt] = k
                    if c2 not in done and c2 not in todo:
                        todo.append(c2)
    return seen


def emu(data, flags=FLAGS):
    return dump_doc(data, Flags(flags))


# ------------------------------------------------------------------ API vectors

def api_line(fields, fl):
    k = fields[0]
    try:
        if k == "DUR":
            s = bytes.fromhex(fields[1])
            try:
                r = str(duration_us(s, fl))
            except Err as e:
                r = "ERR " + e.kind
            return "DUR|%s|%s\n" % (qs(s), r)
        if k == "DT":
            s = bytes.fromhex(fields[1])
            try:
                r = str(datetime_us(s, fl))
            except Err as e:
                r = "ERR " + e.kind
            return "DT|%s|%s\n" % (qs(s), r)
        if k == "RAT":
            s = bytes.fromhex(fields[1])
            try:
                n, d = rational(s, fl)
                r = "%d/%d %s" % (n, d, str(n) if d == 1 else "%d/%d" % (n, d))
            except Err as e:
                r = "ERR " + e.kind
            return "RAT|%s|%s\n" % (qs(s), r)
        if k == "FDUR":
            v = int(fields[1])
            s = fmt_duration(v)
            return "FDUR|%d|%s|%d\n" % (v, s, duration_us(s.encode(), fl))
        if k == "URL":
            b, r = bytes.fromhex(fields[1]), bytes.fromhex(fields[2])
            return "URL|%s|%s|%s\n" % (qs(b), qs(r), qs(resolve(b, r, fl)))
        if k == "TPL":
            t, i = bytes.fromhex(fields[1]), bytes.fromhex(fields[2])
            try:
                r = qs(expand(t, i, int(fields[3]), int(fields[4]), int(fields[5])))
            except Err as e:
                r = "ERR " + e.kind
            return "TPL|%s|%s|%s|%s|%s|%s\n" % (qs(t), qs(i), fields[3], fields[4], fields[5], r)
    except Err as e:
        return "?" + e.kind + "\n"
    return "?\n"


# ------------------------------------------------------------------ expat cross-check of the strict XML layer

def expat_tree(data):
    p = xml.parsers.expat.ParserCreate()
    p.ordered_attributes = True
    stack = [["#doc", [], [], []]]
    doctype = []

    def start(name, attrs):
        stack.append([name, list(zip(attrs[0::2], attrs[1::2])), [], []])

    def end(name):
        e = stack.pop()
        stack[-1][3].append(e)

    def chars(d):
        stack[-1][2].append(d)
    p.StartElementHandler = start
    p.EndElementHandler = end
    p.CharacterDataHandler = chars
    p.StartDoctypeDeclHandler = lambda *a: doctype.append(1)
    p.Parse(data, True)
    return stack[0][3][0], bool(doctype)


def tree_sig(e):
    if isinstance(e, Elem):
        return (e.name.decode("utf-8", "surrogatepass"), [(a.decode(), v.decode("utf-8", "surrogatepass")) for a, v in e.attrs],
                e.text.decode("utf-8", "surrogatepass"), [tree_sig(c) for c in e.children])
    return (e[0], e[1], "".join(e[2]), [tree_sig(c) for c in e[3]])


def expat_check(path):
    agree = dis = skipped = known = 0
    for line in open(path, encoding="ascii"):
        name, hx = line.rstrip("\n").split("\t")
        data = bytes.fromhex(hx)
        try:
            mine = Xml(data, False, True).document()
            mine_err = None
            mine_msg = ""
        except Err as e:
            mine, mine_err, mine_msg = None, e.kind, str(e)
        except RecursionError:
            mine, mine_err, mine_msg = None, "LimitExceeded", ""
        try:
            ex, has_doctype = expat_tree(data)
            ex_err = None
        except (xml.parsers.expat.ExpatError, LookupError, ValueError) as e:
            ex, ex_err, has_doctype = None, str(e), False
        except RecursionError:
            ex, ex_err, has_doctype = None, "recursion", False
        if mine_err in ("SecurityRejected", "LimitExceeded") or has_doctype:
            skipped += 1  # policy (DOCTYPE rejected) / resource limits: not an XML well-formedness question
            continue
        if (mine is None) != (ex is None):
            if mine is None and ex is not None and mine_msg.endswith("VersionNum"):
                known += 1  # expat 2.x accepts any VersionNum; XML 1.0 5th ed. requires '1.' [0-9]+ (quick-xml agrees)
                continue
            dis += 1
            print("XML-DISAGREE %s strict=%s expat=%s" % (name, mine_err or "ok", ex_err or "ok"))
            continue
        if mine is not None and tree_sig(mine) != tree_sig(ex):
            dis += 1
            print("XML-TREE-DIFF %s" % name)
            continue
        agree += 1
    print("EXPAT strict XML layer vs pyexpat %s: %d agree, %d known expat leniencies (VersionNum), %d disagree, %d skipped"
          " (DOCTYPE policy / limits)" % (xml.parsers.expat.EXPAT_VERSION, agree, known, dis, skipped))
    return dis == 0


def main():
    sys.setrecursionlimit(20000)
    if sys.argv[1] == "--expat":
        sys.exit(0 if expat_check(sys.argv[2]) else 1)
    if sys.argv[1] == "--api":
        w = sys.stdout.write
        for line in open(sys.argv[2], encoding="ascii"):
            f = line.rstrip("\n").split("\t")
            if not f[0]:
                continue
            w("S " + api_line(f, Flags(())))
            w("E " + api_line(f, Flags(FLAGS)))
        return
    w = sys.stdout.write
    only = sys.argv[3].split(",") if len(sys.argv) > 3 else None
    for line in open(sys.argv[1], encoding="ascii"):
        name, hx = line.rstrip("\n").split("\t")
        data = bytes.fromhex(hx)
        w("=" + name + "\n")
        for alt in spec_alternatives(data):
            w("S\n" + alt)
        w("E\n" + emu(data, only if only is not None else FLAGS))


if __name__ == "__main__":
    main()
