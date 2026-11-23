#!/usr/bin/env python3
"""Differential fuzz of packages/avro (Pion) against Go hamba/avro/v2 v2.28.0.

usage: diff_oracle.py <pion_probe> <go_oracle> <workdir> [n_random] [seed]

Case groups (one line per case, protocol in go/main.go):
  S  schema parsing / Parsing Canonical Form / CRC-64-AVRO   (hand-written + random)
  D  binary decode of valid, block-split and mutated datums  (random)
  R  writer -> reader resolution                             (hand-written + random evolutions)

Every disagreement is triaged into a bucket. Buckets tagged hamba-deviation /
pion-stricter / spec-ambiguity (see HAND and classify_random) do not fail the run; FINDING
buckets are Pion defects and make this script exit 1.
"""
import json
import os
import random
import struct
import subprocess
import sys

# --------------------------------------------------------------------------------------------
# Avro binary helpers
# --------------------------------------------------------------------------------------------


def zz(n):
    return (n << 1) ^ (n >> 63)


def varint(u):
    u &= (1 << 64) - 1
    out = bytearray()
    while u >= 0x80:
        out.append((u & 0x7F) | 0x80)
        u >>= 7
    out.append(u)
    return bytes(out)


def enc_long(n):
    return varint(zz(n))


def enc_bytes(b):
    return enc_long(len(b)) + b


def hx(b):
    if isinstance(b, str):
        b = b.encode()
    return b.hex()


# --------------------------------------------------------------------------------------------
# Random schema generator (valid schemas only)
# --------------------------------------------------------------------------------------------

PRIMS = ["null", "boolean", "int", "long", "float", "double", "bytes", "string"]


class Gen:
    def __init__(self, rnd):
        self.r = rnd
        self.n = 0
        self.named = []  # (fullname, schema-dict)

    def name(self):
        self.n += 1
        return "N%d" % self.n

    def schema(self, depth, ns):
        r = self.r
        k = r.random()
        if depth <= 0 or k < 0.35:
            if self.named and r.random() < 0.15:
                return self.named[r.randrange(len(self.named))][0]
            p = r.choice(PRIMS)
            return p if r.random() < 0.8 else {"type": p}
        k = r.randrange(6)
        if k == 0:
            return {"type": "array", "items": self.schema(depth - 1, ns)}
        if k == 1:
            return {"type": "map", "values": self.schema(depth - 1, ns)}
        if k == 2:
            return self.union(depth - 1, ns)
        if k == 3:
            nm = self.name()
            syms = ["S%d" % i for i in range(r.randint(1, 5))]
            d = {"type": "enum", "name": nm, "symbols": syms}
            if r.random() < 0.3:
                d["namespace"] = "e.ns"
            self.named.append((self.full(d, ns), d))
            return d
        if k == 4:
            nm = self.name()
            d = {"type": "fixed", "name": nm, "size": r.randint(0, 6)}
            self.named.append((self.full(d, ns), d))
            return d
        return self.record(depth - 1, ns)

    def full(self, d, ns):
        n = d["name"]
        if "." in n:
            return n
        s = d.get("namespace", ns)
        return (s + "." + n) if s else n

    def record(self, depth, ns):
        r = self.r
        nm = self.name()
        d = {"type": "record", "name": nm, "fields": []}
        own = ns
        if r.random() < 0.3:
            d["namespace"] = r.choice(["", "r.ns", "x.y"])
            own = d["namespace"]
        self.named.append((self.full(d, ns), d))
        for i in range(r.randint(0, 5)):
            d["fields"].append({"name": "f%d" % i, "type": self.schema(depth, own)})
        return d

    def union(self, depth, ns):
        r = self.r
        out, seen = [], set()
        for _ in range(r.randint(1, 4)):
            s = self.schema(depth, ns)
            key = self.ukey(s, ns)
            if key in seen or key == "union":
                continue
            seen.add(key)
            out.append(s)
        return out or ["null"]

    def ukey(self, s, ns):
        if isinstance(s, list):
            return "union"
        if isinstance(s, str):
            return s if s in PRIMS else "named:" + s
        t = s["type"]
        if t in ("record", "enum", "fixed"):
            return "named:" + self.full(s, ns)
        return t


# --------------------------------------------------------------------------------------------
# Random datum encoder (walks the JSON schema, so it resolves names itself)
# --------------------------------------------------------------------------------------------


class Enc:
    def __init__(self, rnd, schema):
        self.r = rnd
        self.names = {}
        self.collect(schema, "")

    def collect(self, s, ns):
        if isinstance(s, list):
            for x in s:
                self.collect(x, ns)
        elif isinstance(s, dict):
            t = s["type"]
            if t in ("record", "enum", "fixed"):
                n = s["name"]
                sp = s.get("namespace", ns)
                full = n if "." in n else ((sp + "." + n) if sp else n)
                self.names[full] = (s, full.rpartition(".")[0])
                if t == "record":
                    for f in s["fields"]:
                        self.collect(f["type"], full.rpartition(".")[0])
            elif t == "array":
                self.collect(s["items"], ns)
            elif t == "map":
                self.collect(s["values"], ns)

    def lookup(self, n, ns):
        if "." not in n and ns and (ns + "." + n) in self.names:
            return self.names[ns + "." + n]
        return self.names[n]

    def rstr(self):
        r = self.r
        pool = ["", "a", "é", "日本", "😀", "x" * 3, "\u0000", "\"\\"]
        return "".join(r.choice(pool) for _ in range(r.randint(0, 3)))

    def block(self, items, enc_item):
        r = self.r
        out = bytearray()
        i = 0
        while i < len(items):
            n = r.randint(1, len(items) - i)
            body = b"".join(enc_item(x) for x in items[i:i + n])
            if r.random() < 0.4:
                out += enc_long(-n) + enc_long(len(body)) + body
            else:
                out += enc_long(n) + body
            i += n
        return bytes(out + b"\x00")

    def enc(self, s, ns, depth=0):
        r = self.r
        if isinstance(s, list):
            i = r.randrange(len(s))
            return enc_long(i) + self.enc(s[i], ns, depth + 1)
        if isinstance(s, str) and s not in PRIMS:
            d, sns = self.lookup(s, ns)
            return self.enc(d, sns, depth + 1)
        t = s if isinstance(s, str) else s["type"]
        if t == "null":
            return b""
        if t == "boolean":
            return bytes([r.randrange(2)])
        if t == "int":
            return enc_long(r.choice([0, -1, 1, 2**31 - 1, -2**31, r.randint(-2**31, 2**31 - 1)]))
        if t == "long":
            return enc_long(r.choice([0, -1, 2**63 - 1, -2**63, r.randint(-2**63, 2**63 - 1)]))
        if t == "float":
            return struct.pack("<I", r.choice([0, 0x80000000, 0x7FC00000, 0x7F800001, 1, r.getrandbits(32)]))
        if t == "double":
            return struct.pack("<Q", r.choice([0, 1 << 63, 0x7FF8000000000000, 1, r.getrandbits(64)]))
        if t == "bytes":
            return enc_bytes(bytes(r.getrandbits(8) for _ in range(r.randint(0, 5))))
        if t == "string":
            return enc_bytes(self.rstr().encode())
        if t == "fixed":
            return bytes(r.getrandbits(8) for _ in range(s["size"]))
        if t == "enum":
            return enc_long(r.randrange(len(s["symbols"])))
        if depth > 12:
            raise RecursionError
        if t == "array":
            items = list(range(r.randint(0, 4)))
            return self.block(items, lambda _: self.enc(s["items"], ns, depth + 1))
        if t == "map":
            keys = [self.rstr() for _ in range(r.randint(0, 4))]
            keys = list(dict.fromkeys(keys))
            return self.block(keys, lambda k: enc_bytes(k.encode()) + self.enc(s["values"], ns, depth + 1))
        if t == "record":
            own = s.get("namespace", ns)
            n = s["name"]
            if "." in n:
                own = n.rpartition(".")[0]
            return b"".join(self.enc(f["type"], own, depth + 1) for f in s["fields"])
        return b""


# --------------------------------------------------------------------------------------------
# Hand-written schema / resolution cases (label, line)
# --------------------------------------------------------------------------------------------


def S(label, schema):
    if not isinstance(schema, str):
        schema = json.dumps(schema, ensure_ascii=False)
    return (label, "S " + hx(schema))


def R(label, w, r, data):
    j = json.dumps
    return (label, "R %s %s %s" % (hx(j(w)), hx(j(r)), data.hex()))


def hand_cases():
    c = []
    c.append(S("ns:inherit", {"type": "record", "name": "R", "namespace": "a", "fields": [
        {"name": "e", "type": {"type": "enum", "name": "E", "symbols": ["X"]}}]}))
    c.append(S("ns:empty-clears", {"type": "record", "name": "R", "namespace": "a", "fields": [
        {"name": "e", "type": {"type": "enum", "name": "E", "namespace": "", "symbols": ["X"]}},
        {"name": "f", "type": "E"}]}))
    c.append(S("ns:dotted-overrides", {"type": "record", "name": "x.y.R", "namespace": "ignored", "fields": [
        {"name": "e", "type": {"type": "fixed", "name": "F", "size": 1}}]}))
    c.append(S("ns:ref-fallback-null-ns", {"type": "record", "name": "R", "fields": [
        {"name": "a", "type": {"type": "fixed", "name": "F", "size": 1}},
        {"name": "b", "type": {"type": "record", "name": "Q", "namespace": "z", "fields": [
            {"name": "c", "type": "F"}]}}]}))
    c.append(S("names:bad-start-digit", {"type": "fixed", "name": "1F", "size": 1}))
    c.append(S("names:bad-ns-segment", {"type": "fixed", "name": "F", "namespace": "a..b", "size": 1}))
    c.append(S("names:dup-def", ["null", {"type": "fixed", "name": "F", "size": 1}, {"type": "fixed", "name": "F", "size": 1}]))
    c.append(S("names:undefined-ref", {"type": "array", "items": "Nope"}))
    c.append(S("names:redefine-primitive", {"type": "fixed", "name": "int", "size": 1}))
    c.append(S("names:redefine-primitive-in-ns", {"type": "fixed", "name": "a.int", "size": 1}))
    c.append(S("union:nested", ["null", ["int"]]))
    c.append(S("union:dup-prim", ["int", "int"]))
    c.append(S("union:dup-array", [{"type": "array", "items": "int"}, {"type": "array", "items": "long"}]))
    c.append(S("union:two-records", [{"type": "record", "name": "A", "fields": []}, {"type": "record", "name": "B", "fields": []}]))
    c.append(S("union:dup-record-name-via-ns", ["null", {"type": "record", "name": "a.R", "fields": []}, "a.R"]))
    c.append(S("union:empty", []))
    c.append(S("obj:named-ref-object-form", {"type": "record", "name": "R", "fields": [
        {"name": "a", "type": {"type": "fixed", "name": "F", "size": 2}},
        {"name": "b", "type": {"type": "F"}}]}))
    c.append(S("pcf:strip-everything", {"type": "record", "name": "R", "namespace": "n", "doc": "d", "aliases": ["Z"],
                                       "fields": [{"name": "a", "type": {"type": "long", "logicalType": "timestamp-millis"},
                                                   "doc": "x", "default": 1, "order": "descending", "aliases": ["q"]}]}))
    c.append(S("pcf:escape-unicode-doc", {"type": "record", "name": "R", "doc": "é ", "fields": []}))
    c.append(S("pcf:decimal-fixed", {"type": "fixed", "name": "D", "size": 8, "logicalType": "decimal", "precision": 18, "scale": 2}))
    c.append(S("pcf:recursive", {"type": "record", "name": "L", "fields": [{"name": "n", "type": ["null", "L"]}]}))
    c.append(S("pcf:mutual-recursion", {"type": "record", "name": "A", "fields": [{"name": "b", "type": [
        "null", {"type": "record", "name": "B", "fields": [{"name": "a", "type": ["null", "A"]}]}]}]}))
    c.append(S("enum:default-not-symbol", {"type": "enum", "name": "E", "symbols": ["A"], "default": "B"}))
    c.append(S("enum:dup-symbol", {"type": "enum", "name": "E", "symbols": ["A", "A"]}))
    c.append(S("enum:bad-symbol", {"type": "enum", "name": "E", "symbols": ["a-b"]}))
    c.append(S("field:dup-name", {"type": "record", "name": "R", "fields": [{"name": "a", "type": "int"}, {"name": "a", "type": "int"}]}))
    c.append(S("field:bad-default", {"type": "record", "name": "R", "fields": [{"name": "a", "type": "int", "default": "x"}]}))
    c.append(S("field:union-default-second-branch", {"type": "record", "name": "R", "fields": [{"name": "a", "type": ["null", "int"], "default": 1}]}))
    c.append(S("fixed:negative-size", {"type": "fixed", "name": "F", "size": -1}))
    c.append(S("json:dup-key-type", '{"type":"int","type":"string"}'))
    c.append(S("json:trailing-comma", '{"type":"int",}'))
    # --- resolution -----------------------------------------------------------------------
    rec = lambda name, fields, **kw: dict({"type": "record", "name": name, "fields": fields}, **kw)
    c.append(R("res:unqualified-record-name", rec("a.X", [{"name": "f", "type": "int"}]),
               rec("b.X", [{"name": "f", "type": "int"}]), enc_long(7)))
    c.append(R("res:unqualified-enum-name", {"type": "enum", "name": "a.E", "symbols": ["A"]},
               {"type": "enum", "name": "b.E", "symbols": ["A"]}, enc_long(0)))
    c.append(R("res:unqualified-fixed-name", {"type": "fixed", "name": "a.F", "size": 1},
               {"type": "fixed", "name": "b.F", "size": 1}, b"\x05"))
    c.append(R("res:alias-and-name-both-in-writer", rec("R", [{"name": "b", "type": "int"}, {"name": "a", "type": "int"}]),
               rec("R", [{"name": "b", "type": "int", "aliases": ["a"]}]), enc_long(1) + enc_long(2)))
    c.append(R("res:alias-shadows-exact-field", rec("R", [{"name": "y", "type": "int"}]),
               rec("R", [{"name": "x", "type": "int", "aliases": ["y"]}, {"name": "y", "type": "int", "default": 0}]), enc_long(5)))
    c.append(R("res:record-alias", rec("old.R", [{"name": "f", "type": "int"}]),
               rec("new.R2", [{"name": "f", "type": "int"}], aliases=["old.R"]), enc_long(3)))
    c.append(R("res:long-to-float-double-rounding", "long", "float", enc_long(2**60 + 2**36 + 1)))
    c.append(R("res:long-to-float-max", "long", "float", enc_long(2**63 - 1)))
    c.append(R("res:int-to-float-rounding", "int", "float", enc_long(16777217)))
    c.append(R("res:writer-int-reader-union-long-int", "int", ["long", "int"], enc_long(5)))
    c.append(R("res:writer-int-reader-union-float-long", "int", ["float", "long"], enc_long(5)))
    c.append(R("res:writer-union-reader-nonunion", ["null", "int"], "long", enc_long(1) + enc_long(9)))
    c.append(R("res:writer-union-branch-incompatible-unused", ["string", "int"], "long", enc_long(1) + enc_long(9)))
    c.append(R("res:enum-missing-symbol-default", {"type": "enum", "name": "E", "symbols": ["A", "B"]},
               {"type": "enum", "name": "E", "symbols": ["A", "Z"], "default": "Z"}, enc_long(1)))
    c.append(R("res:enum-missing-symbol-no-default", {"type": "enum", "name": "E", "symbols": ["A", "B"]},
               {"type": "enum", "name": "E", "symbols": ["A"]}, enc_long(0)))
    c.append(R("res:fixed-size-mismatch", {"type": "fixed", "name": "F", "size": 2}, {"type": "fixed", "name": "F", "size": 3}, b"ab"))
    c.append(R("res:new-field-no-default", rec("R", []), rec("R", [{"name": "a", "type": "int"}]), b""))
    c.append(R("res:new-field-record-default", rec("R", []), rec("R", [{"name": "a", "type": rec("S", [
        {"name": "x", "type": "int"}, {"name": "y", "type": {"type": "array", "items": "string"}}]),
        "default": {"x": 1, "y": ["p", "q"]}}]), b""))
    c.append(R("res:new-field-bytes-default", rec("R", []), rec("R", [{"name": "a", "type": "bytes", "default": "ÿ\u0000a"}]), b""))
    c.append(R("res:skip-nested-negative-blocks", rec("R", [
        {"name": "drop", "type": {"type": "map", "values": {"type": "array", "items": "string"}}}, {"name": "k", "type": "int"}]),
        rec("R", [{"name": "k", "type": "int"}]),
        enc_long(-1) + enc_long(6) + enc_bytes(b"m") + enc_long(1) + enc_bytes(b"z") + b"\x00" + b"\x00" + enc_long(4)))
    c.append(R("res:string-to-bytes", "string", "bytes", enc_bytes("é".encode())))
    c.append(R("res:bytes-to-string-invalid-utf8", "bytes", "string", enc_bytes(b"\xff")))
    return c


# --------------------------------------------------------------------------------------------
# Random evolution (writer record -> reader record)
# --------------------------------------------------------------------------------------------

PROMO = {"int": ["long", "float", "double"], "long": ["float", "double"], "float": ["double"],
         "string": ["bytes"], "bytes": ["string"]}
DEFAULTS = {"null": None, "boolean": True, "int": 7, "long": -3, "float": 1.5, "double": -2.25,
            "bytes": "ÿ\u0001", "string": "dflt"}


def evolve(rnd, w):
    r = json.loads(json.dumps(w))
    fields = []
    for f in r["fields"]:
        if rnd.random() < 0.2:
            continue  # drop: writer field must be skipped
        t = f["type"]
        if isinstance(t, str) and t in PROMO and rnd.random() < 0.5:
            f["type"] = rnd.choice(PROMO[t])
        elif isinstance(t, str) and t in PRIMS and t != "null" and rnd.random() < 0.3:
            others = [p for p in PRIMS if p != t]
            f["type"] = [t, rnd.choice(others)] if rnd.random() < 0.5 else [rnd.choice(others), t]
        if rnd.random() < 0.15:
            f["aliases"] = [f["name"]]
            f["name"] = f["name"] + "_renamed"
        fields.append(f)
    for i in range(rnd.randint(0, 2)):
        p = rnd.choice(PRIMS)
        fields.append({"name": "new%d" % i, "type": p, "default": DEFAULTS[p]})
    rnd.shuffle(fields)
    r["fields"] = fields
    return r


def random_cases(n, seed):
    rnd = random.Random(seed)
    out = []
    while len(out) < n:
        g = Gen(rnd)
        s = g.schema(4, "")
        sj = json.dumps(s, ensure_ascii=False)
        out.append(("rand:S", "S " + hx(sj)))
        try:
            data = Enc(rnd, s).enc(s, "")
        except (RecursionError, KeyError, IndexError):
            continue
        out.append(("rand:D-valid", "D %s %s" % (hx(sj), data.hex())))
        m = bytearray(data)
        if m:
            k = rnd.randrange(3)
            if k == 0:
                m[rnd.randrange(len(m))] ^= 1 << rnd.randrange(8)
            elif k == 1:
                del m[rnd.randrange(len(m)):]
            else:
                m[rnd.randrange(len(m))] = rnd.choice([0x80, 0xFF, 0x7F, 0x01, 0x00])
            out.append(("rand:D-mutated", "D %s %s" % (hx(sj), bytes(m).hex())))
        # record evolution
        w = g.record(3, "")
        w = {"type": "record", "name": "Top", "fields": w["fields"]}
        try:
            wd = Enc(rnd, w).enc(w, "")
        except (RecursionError, KeyError, IndexError):
            continue
        rd = evolve(rnd, w)
        out.append(("rand:R", "R %s %s %s" % (hx(json.dumps(w)), hx(json.dumps(rd)), wd.hex())))
    return out


# --------------------------------------------------------------------------------------------
# Triage
# --------------------------------------------------------------------------------------------

# Verdicts for the hand-written cases whose Pion and Go answers differ.
#   FINDING          Pion deviates from Avro 1.11.1 (and from Java) -> fails the run
#   hamba-deviation  hamba deviates from the spec/Java, Pion is right
#   pion-stricter    Pion rejects input that the spec calls invalid but hamba tolerates
#   spec-ambiguity   the spec allows both answers (Pion follows Java)
HAND = {
    "res:unqualified-record-name": ("FINDING", "F-01 spec: records match on the unqualified name"),
    "res:unqualified-enum-name": ("FINDING", "F-01 spec: enums match on the unqualified name"),
    "res:unqualified-fixed-name": ("FINDING", "F-01 spec: fixed match on size + unqualified name"),
    "res:long-to-float-double-rounding": ("FINDING", "F-04 long->float double rounding"),
    "obj:named-ref-object-form": ("FINDING", "F-06 {\"type\":\"F\"} reference rejected"),
    "union:empty": ("FINDING", "F-10 [] rejected (Java and hamba accept)"),
    "enum:dup-symbol": ("hamba-deviation", "spec: symbols must be unique"),
    "field:dup-name": ("hamba-deviation", "spec: field names must be unique"),
    "fixed:negative-size": ("hamba-deviation", "size is a non-negative int"),
    "names:redefine-primitive": ("hamba-deviation", "Java: Can't redefine: int"),
    "names:redefine-primitive-in-ns": ("spec-ambiguity", "spec text forbids primitive names in any namespace; Java allows a.int"),
    "ns:empty-clears": ("hamba-deviation", "spec: namespace \"\" is the null namespace; hamba keeps the enclosing one"),
    "ns:ref-fallback-null-ns": ("hamba-deviation", "Java falls back to the null namespace for an unqualified reference"),
    "pcf:decimal-fixed": ("hamba-deviation", "PCF [STRIP] drops logicalType; hamba keeps it (different fingerprints)"),
    "pcf:strip-everything": ("hamba-deviation", "PCF [STRIP] drops logicalType; hamba keeps it (different fingerprints)"),
    "res:writer-union-reader-nonunion": ("hamba-deviation", "spec: error only if the selected writer branch does not match"),
    "res:writer-union-branch-incompatible-unused": ("hamba-deviation", "spec: error only if the selected writer branch does not match"),
    "res:enum-missing-symbol-no-default": ("hamba-deviation", "spec: error only when the missing symbol is read"),
    "res:bytes-to-string-invalid-utf8": ("pion-stricter", "Pion validates UTF-8 on bytes->string"),
    "res:writer-int-reader-union-long-int": ("spec-ambiguity", "Pion/Java prefer the exact branch, hamba the first promotable one"),
    "json:dup-key-type": ("spec-ambiguity", "duplicate JSON keys are undefined"),
    "union:dup-record-name-via-ns": ("hamba-deviation", "same record twice in a union"),
}

HAMBA_ERRS = ["schema type null is unsupported", "union type must be unique", "unknown type", "err writer",
              "err reader", "err schema", "lacking writer schema", "not compatible with writer schema",
              "unexpected EOF", "is missing symbol", "canon missing field"]
import re  # noqa: E402

_TOK = re.compile(r"([ILfdbsxe])([-0-9a-fA-Z]*)")


def _quiet(m):
    v = int(m.group(1), 16)
    if (v >> 52) & 0x7FF == 0x7FF and v & ((1 << 52) - 1):
        v |= 1 << 51
    return "d%016x" % v


def classify_random(label, p, g, line=""):
    pok, gok = p.startswith("ok"), g.startswith("ok")
    if label == "rand:S" and pok and gok and '"namespace": ""' in bytes.fromhex(line.split()[1]).decode():
        return label + ":hamba-ignores-empty-namespace", "hamba-deviation"
    if not pok:
        for k, why in (("invalid utf-8", "UTF-8 validation"), ("byte_size", "negative-count byte_size checked against input"),
                       ("varint overflow", "varint bits beyond 32/64 rejected"), ("invalid boolean", "boolean byte not 0/1")):
            if k in p:
                return label + ":pion-stricter:" + why, "pion-stricter"
        if "unexpected eof" in p:
            return label + ":hamba-reads-past-eof-as-zero", "hamba-deviation"
        return label + ":pion-rejects-go-accepts", "FINDING"
    if not gok:
        for k in HAMBA_ERRS:
            if k in g:
                return label + ":hamba-error:" + k, "hamba-deviation"
        return label + ":pion-accepts-go-rejects", "FINDING"
    if re.sub(r"d([0-9a-f]{16})", _quiet, p) == re.sub(r"d([0-9a-f]{16})", _quiet, g):
        return label + ":F-05 float->double keeps sNaN", "FINDING"
    tp, tg = _TOK.findall(p[3:]), _TOK.findall(g[3:])
    if len(tp) == len(tg) and all(a[0] in "ILfd" and b[0] in "ILfd" for a, b in zip(tp, tg) if a != b):
        if all(a[0] == b[0] for a, b in zip(tp, tg)):
            return label + ":F-04 numeric promotion rounding", "FINDING"
        return label + ":reader-union-branch-preference", "spec-ambiguity"
    return label + ":value-mismatch", "FINDING"


def run(cmd):
    return subprocess.run(cmd, check=True)


def main():
    pion, go, wd = sys.argv[1], sys.argv[2], sys.argv[3]
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 3000
    seed = int(sys.argv[5]) if len(sys.argv) > 5 else 1111
    os.makedirs(wd, exist_ok=True)
    cases = hand_cases() + random_cases(n, seed)
    cf = os.path.join(wd, "cases.txt")
    with open(cf, "w") as f:
        for _, line in cases:
            f.write(line + "\n")
    po, go_ = os.path.join(wd, "pion.out"), os.path.join(wd, "go.out")
    run([pion, "batch", cf, po])
    run([go, "batch", cf, go_])
    P = open(po).read().split("\n")
    G = open(go_).read().split("\n")
    buckets = {}
    tags = {}
    skipped = 0
    for i, (label, line) in enumerate(cases):
        p, g = P[i], G[i]
        pok, gok = p.startswith("ok"), g.startswith("ok")
        if pok and gok and p == g:
            continue
        if p.startswith("skip") or g.startswith("skip"):
            skipped += 1
            continue
        if not pok and not gok:
            continue
        if label.startswith("rand:"):
            key, tag = classify_random(label, p, g, line)
        else:
            tag, why = HAND.get(label, ("FINDING", "unclassified hand-written case"))
            key = label + " -- " + why
        tags[key] = tag
        buckets.setdefault(key, []).append((line, p, g))
    total = len(cases)
    print("cases: %d (hand-written %d, random %d, seed %d); %d skipped (hamba cannot resolve/decode recursive schemas)"
          % (total, len(hand_cases()), total - len(hand_cases()), seed, skipped))
    findings = 0
    order = {"FINDING": 0, "spec-ambiguity": 1, "pion-stricter": 2, "hamba-deviation": 3}
    for key in sorted(buckets, key=lambda k: (order[tags[k]], k)):
        items = buckets[key]
        tag = tags[key]
        if tag == "FINDING":
            findings += 1
        line, p, g = items[0]
        print("  [%-15s] %s  x%d" % (tag, key, len(items)))
        print("      case: %s" % (line if len(line) < 400 else line[:400] + "..."))
        print("      pion: %s" % (p if len(p) < 200 else p[:200] + "..."))
        print("      go  : %s" % (g if len(g) < 200 else g[:200] + "..."))
    agree = total - skipped - sum(len(v) for v in buckets.values())
    print("agree: %d/%d   disagreement buckets: %d (%d FINDING buckets)" % (agree, total - skipped, len(buckets), findings))
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()
