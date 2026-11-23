#!/usr/bin/env python3
"""RT-git three-way differential harness: Pion `packages/git` vs real `git` CLI vs Rust `gix`.

Usage: python3 difftest.py --pion <oracle> --gix <gix_oracle> --work <dir> [--modes tree,commit,...]

Every vector is fed to:
  * Pion oracle   (`packages/git/audit/src/main.pion`, batch mode)
  * gix oracle    (`packages/git/audit/gix_oracle`, batch mode)
  * git reference (`git hash-object` with built-in fsck, `git cat-file`, `git index-pack`
                   + `git verify-pack -v`, `git ls-files -s`, `git check-ref-format`)
and the verdict (OK/ERR) plus a canonical content hash are compared.
No vector is written inside the repository; everything lives under --work.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import zlib

EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbe4904b"
BLOB_OID = bytes.fromhex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
SIG = b"A U Thor <a@example.com> 1700000000 +0000"


def sha1(b):
    return hashlib.sha1(b).hexdigest()


def obj_oid(kind, payload):
    return sha1(kind.encode() + b" " + str(len(payload)).encode() + b"\0" + payload)


# ---------------------------------------------------------------------------
# Vector generators. Each returns list of (label, bytes).
# ---------------------------------------------------------------------------

def gen_tree():
    out = []
    modes = [b"100644", b"100755", b"120000", b"160000", b"40000", b"040000", b"0100644",
             b"100664", b"100600", b"100775", b"644", b"755", b"1000644", b"10644",
             b"100645", b"40755", b"140000", b"060000", b"000000", b"", b"10064a", b" 100644"]
    names = [b"a", b"file.txt", b".git", b".GIT", b".Git", b"GIT~1", b"git~1", b".git.", b".git..",
             b".git ", b".git::$INDEX_ALLOCATION", b".g\xe2\x80\x8cit", b".gi\xe2\x80\x8dt",
             b".gitmodules", b".GITMODULES", b"GITMOD~1", b".gitattributes", b".gitignore",
             b"..", b".", b"...", b"", b"a\\b", b"..\\x", b"a/b", b"\xff\xfe", b"\xc3\x28",
             b"\xe6\x97\xa5\xe6\x9c\xac", b"caf\xc3\xa9", b"foo.", b"foo ", b"CON", b"aux.txt",
             b"x" * 255, b"x" * 4096, b"\x01ctl", b"\x7f", b"-", b"~", b"a b", b".git\x00"]
    for m in modes:
        for nm in names[:8]:
            out.append((f"mode={m!r} name={nm!r}", m + b" " + nm + b"\0" + BLOB_OID))
    for nm in names:
        out.append((f"blob name={nm!r}", b"100644 " + nm + b"\0" + BLOB_OID))
        out.append((f"tree name={nm!r}", b"40000 " + nm + b"\0" + BLOB_OID))
        out.append((f"link name={nm!r}", b"120000 " + nm + b"\0" + BLOB_OID))
        out.append((f"gitlink name={nm!r}", b"160000 " + nm + b"\0" + BLOB_OID))
    # ordering / duplicates
    def ent(m, n):
        return m + b" " + n + b"\0" + BLOB_OID
    pairs = [(b"a", b"b"), (b"a", b"a-b"), (b"a-b", b"a"), (b"a.c", b"a"), (b"a", b"a.c"),
             (b"A", b"a"), (b"a", b"A"), (b"\xff", b"a"), (b"a", b"\xff"), (b"ab", b"a")]
    for x, y in pairs:
        for mx in (b"100644", b"40000"):
            for my in (b"100644", b"40000"):
                out.append((f"pair {mx!r}:{x!r} {my!r}:{y!r}", ent(mx, x) + ent(my, y)))
    out.append(("dup file/file", ent(b"100644", b"a") + ent(b"100644", b"a")))
    out.append(("dup dir/dir", ent(b"40000", b"a") + ent(b"40000", b"a")))
    out.append(("dup file/dir adjacent", ent(b"100644", b"a") + ent(b"40000", b"a")))
    out.append(("dup file,a-b,dir non-adjacent (sorted)",
                ent(b"100644", b"a") + ent(b"100644", b"a-b") + ent(b"40000", b"a")))
    out.append(("dup dir,file non-adjacent",
                ent(b"100644", b"a-b") + ent(b"40000", b"a") + ent(b"100644", b"a")))
    out.append(("dup file x3", ent(b"100644", b"a") * 3))
    # truncation / framing
    good = ent(b"100644", b"a")
    for cut in range(1, len(good)):
        out.append((f"truncated@{cut}", good[:cut]))
    out.append(("empty tree", b""))
    out.append(("trailing NUL", good + b"\0"))
    out.append(("no space", b"100644a\0" + BLOB_OID))
    out.append(("two spaces", b"100644  a\0" + BLOB_OID))
    # large
    big = b"".join(ent(b"100644", b"f%06d" % i) for i in range(5000))
    out.append(("5000 sorted entries", big))
    return out


def commit(tree=b"tree " + EMPTY_TREE.encode() + b"\n", parents=b"", author=b"author " + SIG + b"\n",
           committer=b"committer " + SIG + b"\n", extra=b"", msg=b"\nmsg\n"):
    return tree + parents + author + committer + extra + msg


def gen_commit():
    out = []
    P = b"parent " + EMPTY_TREE.encode() + b"\n"
    out.append(("canonical", commit()))
    out.append(("no message, no blank", commit(msg=b"")))
    out.append(("blank no body", commit(msg=b"\n")))
    out.append(("trailing blank lines", commit(msg=b"\nmsg\n\n\n")))
    out.append(("no trailing LF", commit(msg=b"\nmsg")))
    out.append(("parents x3", commit(parents=P * 3)))
    out.append(("missing tree", commit(tree=b"")))
    out.append(("missing author", commit(author=b"")))
    out.append(("missing committer", commit(committer=b"")))
    out.append(("double tree", commit(tree=b"tree " + EMPTY_TREE.encode() + b"\n" * 1 + b"tree " + EMPTY_TREE.encode() + b"\n")))
    out.append(("double author", commit(author=b"author " + SIG + b"\n" + b"author " + SIG + b"\n")))
    out.append(("double committer", commit(committer=b"committer " + SIG + b"\ncommitter " + SIG + b"\n")))
    out.append(("author before tree", b"author " + SIG + b"\n" + b"tree " + EMPTY_TREE.encode() + b"\ncommitter " + SIG + b"\n\nm\n"))
    out.append(("parent after author", b"tree " + EMPTY_TREE.encode() + b"\nauthor " + SIG + b"\n" + P + b"committer " + SIG + b"\n\nm\n"))
    out.append(("uppercase tree hex", commit(tree=b"tree " + EMPTY_TREE.upper().encode() + b"\n")))
    out.append(("short tree hex", commit(tree=b"tree " + EMPTY_TREE[:39].encode() + b"\n")))
    out.append(("tree hex + trailing space", commit(tree=b"tree " + EMPTY_TREE.encode() + b" \n")))
    out.append(("encoding header", commit(extra=b"encoding ISO-8859-1\n")))
    out.append(("latin1 message", commit(extra=b"encoding ISO-8859-1\n", msg=b"\ncaf\xe9\n")))
    out.append(("invalid utf8 message", commit(msg=b"\n\xff\xfe\xfd\n")))
    out.append(("invalid utf8 author name", commit(author=b"author J\xf6rg <j@x> 1700000000 +0000\n")))
    gpg = b"gpgsig -----BEGIN PGP SIGNATURE-----\n \n iQEz\n -----END PGP SIGNATURE-----\n"
    out.append(("gpgsig multiline", commit(extra=gpg)))
    out.append(("gpgsig + encoding order", commit(extra=gpg + b"encoding UTF-8\n")))
    out.append(("encoding + gpgsig order", commit(extra=b"encoding UTF-8\n" + gpg)))
    mt = b"mergetag object " + EMPTY_TREE.encode() + b"\n type tree\n tag v1\n tagger " + SIG + b"\n \n msg\n"
    out.append(("mergetag", commit(parents=P * 2, extra=mt)))
    out.append(("continuation after author", commit(author=b"author " + SIG + b"\n cont\n")))
    out.append(("extra header before author", commit(parents=b"foo bar\n")))
    out.append(("header with empty value", commit(extra=b"x-empty \n")))
    out.append(("header without value", commit(extra=b"x-novalue\n")))
    out.append(("CRLF lines", commit().replace(b"\n", b"\r\n")))
    out.append(("NUL in header", commit(extra=b"x-nul a\0b\n")))
    dates = [b"1700000000 +0000", b"0 +0000", b"-1 +0000", b"-5 +0000", b"01700000000 +0000",
             b"+1700000000 +0000", b"00 +0000", b"9223372036854775807 +0000",
             b"9223372036854775808 +0000", b"18446744073709551616 +0000",
             b"99999999999999999999999 +0000", b"1700000000 +2500", b"1700000000 -0000",
             b"1700000000 +0060", b"1700000000 +9999", b"1700000000 0000", b"1700000000 +000",
             b"1700000000 +00000", b"1700000000 +0a00", b"1700000000  +0000", b"1700000000",
             b"1700000000 +0000 ", b" 1700000000 +0000", b"1700000000 \xe2\x88\x920100",
             b"1e9 +0000", b"0x10 +0000", b"1700000000 Z"]
    idents = [b"A U Thor <a@example.com>", b"<a@x>", b"A <>", b"A<a@x>", b"A  <a@x>",
              b"A <a>b@x>", b"A <a<b@x>", b"A <a@x>>", b"A >a@x<", b"A <a@x", b"A a@x>",
              b"A\n <a@x>", b"A <a@\nx>", b"A <a@x\x00>", b" <a@x>", b"A> <a@x>", b"A< <a@x>",
              b"J\xc3\xb6rg <j@x>", b"J\xf6rg <j@x>"]
    for d in dates:
        out.append((f"author date={d!r}", commit(author=b"author " + SIG.split(b"> ")[0] + b"> " + d + b"\n")))
    for i in idents:
        out.append((f"author ident={i!r}", commit(author=b"author " + i + b" 1700000000 +0000\n")))
        out.append((f"committer ident={i!r}", commit(committer=b"committer " + i + b" 1700000000 +0000\n")))
    for d in dates:
        for i in idents[:6]:
            out.append((f"combo {i!r} {d!r}", commit(committer=b"committer " + i + b" " + d + b"\n")))
    return out


def tag(obj=b"object " + EMPTY_TREE.encode() + b"\n", typ=b"type tree\n", name=b"tag v1.0\n",
        tagger=b"tagger " + SIG + b"\n", extra=b"", msg=b"\nmessage\n"):
    return obj + typ + name + tagger + extra + msg


def gen_tag():
    out = [("canonical", tag())]
    out.append(("no tagger", tag(tagger=b"")))
    out.append(("missing object", tag(obj=b"")))
    out.append(("missing type", tag(typ=b"")))
    out.append(("missing tag", tag(name=b"")))
    out.append(("type before object", b"type tree\n" + b"object " + EMPTY_TREE.encode() + b"\ntag v\ntagger " + SIG + b"\n\nm\n"))
    out.append(("tag before type", b"object " + EMPTY_TREE.encode() + b"\ntag v\ntype tree\ntagger " + SIG + b"\n\nm\n"))
    out.append(("unknown header kept", tag(extra=b"x-foo bar\n")))
    out.append(("gpgsig header", tag(extra=b"gpgsig -----BEGIN-----\n line\n -----END-----\n")))
    out.append(("double object", tag(obj=b"object " + EMPTY_TREE.encode() + b"\n" * 1 + b"object " + EMPTY_TREE.encode() + b"\n")))
    out.append(("no message", tag(msg=b"")))
    out.append(("invalid utf8 msg", tag(msg=b"\n\xff\xfe\n")))
    out.append(("type=bogus", tag(typ=b"type bogus\n")))
    out.append(("type=Commit", tag(typ=b"type Commit\n")))
    for nm in [b"v1", b"v..1", b"v 1", b"", b"-v", b"v1.lock", b"refs/heads/x", b"v~1", b"v^1",
               b"v:1", b"v?", b"v*", b"v[", b"v\\1", b"@", b"v@{1}", b".v", b"v.", b"/v", b"v/",
               b"a//b", b"\xff", b"\x01", b"\xe6\x97\xa5"]:
        out.append((f"tag name={nm!r}", tag(name=b"tag " + nm + b"\n")))
    for d in [b"1700000000 +0000", b"-1 +0000", b"01 +0000", b"99999999999999999999 +0000",
              b"1 +2500", b"1 -0000", b"1"]:
        out.append((f"tagger date={d!r}", tag(tagger=b"tagger A <a@x> " + d + b"\n")))
    return out


def gen_loose():
    out = []
    payload = b"hello loose\n"
    def lz(raw, level=6):
        return zlib.compress(raw, level)
    out.append(("canonical blob", lz(b"blob %d\0" % len(payload) + payload)))
    out.append(("canonical tree empty", lz(b"tree 0\0")))
    out.append(("leading zero length", lz(b"blob 012\0" + payload)))
    out.append(("length 0 with leading zero", lz(b"blob 00\0")))
    out.append(("negative length", lz(b"blob -12\0" + payload)))
    out.append(("plus length", lz(b"blob +12\0" + payload)))
    out.append(("length overflow 2^31", lz(b"blob 2147483648\0" + payload)))
    out.append(("length overflow 2^32+12", lz(b"blob 4294967308\0" + payload)))
    out.append(("length 2147483649", lz(b"blob 2147483649\0" + payload)))
    out.append(("length 2147483657", lz(b"blob 2147483657\0" + payload)))
    out.append(("length smaller", lz(b"blob 5\0" + payload)))
    out.append(("length larger", lz(b"blob 50\0" + payload)))
    out.append(("no NUL", lz(b"blob 12" + payload)))
    out.append(("two spaces", lz(b"blob  12\0" + payload)))
    out.append(("unknown type", lz(b"blub 12\0" + payload)))
    out.append(("uppercase type", lz(b"BLOB 12\0" + payload)))
    out.append(("OFS_DELTA type name", lz(b"ofs-delta 12\0" + payload)))
    good = lz(b"blob 12\0" + payload)
    for g in [b"\0", b"x", b"garbage!" * 4, good]:
        out.append((f"trailing garbage {len(g)}B", good + g))
    for cut in [len(good) - 1, len(good) - 4, 2, 6]:
        out.append((f"truncated to {cut}", good[:cut]))
    bad_adler = good[:-1] + bytes([good[-1] ^ 1])
    out.append(("bad adler", bad_adler))
    out.append(("raw deflate (no zlib header)", zlib.compress(b"blob 12\0" + payload)[2:]))
    for lvl in range(0, 10):
        out.append((f"level {lvl}", lz(b"blob 12\0" + payload, lvl)))
    header_long = b"blob " + b"0" * 70 + b"12\0" + payload
    out.append(("header > 64 bytes", lz(header_long)))
    big = b"A" * (1 << 20)
    out.append(("1MiB blob", lz(b"blob %d\0" % len(big) + big, 9)))
    return out


def pack_entry_header(ptype, size):
    b = (ptype << 4) | (size & 0x0F)
    size >>= 4
    out = bytearray()
    while size:
        out.append(b | 0x80)
        b = size & 0x7F
        size >>= 7
    out.append(b)
    return bytes(out)


def ofs_encode(v):
    out = [v & 0x7F]
    v >>= 7
    while v:
        v -= 1
        out.append(0x80 | (v & 0x7F))
        v >>= 7
    return bytes(reversed(out))


def build_pack(entries, count=None, version=2, raw_override=None):
    """entries: list of dicts {t: type, data: bytes, base: index (ofs) | oid bytes (ref), size: override,
    ofs_raw: raw bytes for ofs varint}"""
    body = bytearray(b"PACK" + struct.pack(">II", version, len(entries) if count is None else count))
    offs = []
    for e in entries:
        offs.append(len(body))
        size = e.get("size", len(e["data"]))
        body += e.get("hdr", pack_entry_header(e["t"], size))
        if e["t"] == 6:
            if "ofs_raw" in e:
                body += e["ofs_raw"]
            else:
                body += ofs_encode(offs[-1] - offs[e["base"]])
        elif e["t"] == 7:
            body += e["base"]
        body += e.get("z", zlib.compress(e["data"]))
    if raw_override:
        body = raw_override(body)
    return bytes(body) + hashlib.sha1(bytes(body)).digest()


def delta_varint(v):
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def copy_op(off, size):
    cmd = 0x80
    args = bytearray()
    for i in range(4):
        byte = (off >> (8 * i)) & 0xFF
        if byte:
            cmd |= 1 << i
            args.append(byte)
    sz = 0 if size == 0x10000 else size
    for i in range(3):
        byte = (sz >> (8 * i)) & 0xFF
        if byte:
            cmd |= 0x10 << i
            args.append(byte)
    return bytes([cmd]) + bytes(args)


def gen_delta_vectors():
    """Returns (pack vectors, direct delta vectors)."""
    base = bytes(range(256)) * 4  # 1 KiB
    packs, deltas = [], []

    def add(label, delta, b=base):
        deltas.append((label, struct.pack(">I", len(b)) + b + delta))
        packs.append(("delta:" + label, build_pack([{"t": 3, "data": b}, {"t": 6, "data": delta, "base": 0}])))

    hdr = delta_varint(len(base))
    add("copy all", hdr + delta_varint(1024) + copy_op(0, 1024))
    add("insert only", hdr + delta_varint(5) + b"\x05hello")
    add("copy+insert", hdr + delta_varint(10) + copy_op(0, 5) + b"\x05hello")
    add("copy size0=0x10000 on 1KiB base", hdr + delta_varint(0x10000) + bytes([0x80]))
    big = bytes(range(256)) * 512  # 128 KiB
    add("copy size0=0x10000 on 128KiB base", delta_varint(len(big)) + delta_varint(0x10000) + bytes([0x80]), big)
    add("copy explicit 0 size bytes", hdr + delta_varint(0x10000) + bytes([0x90, 0x00]), big[:0x10000] if False else base)
    add("copy past base", hdr + delta_varint(10) + copy_op(1020, 10))
    add("copy off 0x7fffffff size 0x10000", hdr + delta_varint(0x10000) + bytes([0x8F, 0xFF, 0xFF, 0xFF, 0x7F]))
    add("copy off 0xffffffff", hdr + delta_varint(16) + bytes([0x9F, 0xFF, 0xFF, 0xFF, 0xFF, 0x10]))
    add("copy off 0x80000000 size 1", hdr + delta_varint(1) + bytes([0x98, 0x80, 0x01]))
    add("copy size 0xffffff", hdr + delta_varint(0xFFFFFF) + bytes([0xF0, 0xFF, 0xFF, 0xFF]))
    add("insert past delta end", hdr + delta_varint(5) + b"\x05hel")
    add("opcode 0x00", hdr + delta_varint(1) + b"\x00")
    add("result shorter than declared", hdr + delta_varint(10) + copy_op(0, 5))
    add("result longer than declared", hdr + delta_varint(4) + copy_op(0, 5))
    add("base size mismatch", delta_varint(1000) + delta_varint(5) + copy_op(0, 5))
    add("truncated header", b"\x80")
    add("empty delta", b"")
    add("target 0", hdr + delta_varint(0))
    add("target_size 0x7fffffff", hdr + delta_varint(0x7FFFFFFF) + copy_op(0, 1024))
    add("target_size 0xffffffff", hdr + delta_varint(0xFFFFFFFF) + copy_op(0, 1024))
    add("target_size 2^40 varint", hdr + delta_varint(1 << 40) + copy_op(0, 1024))
    add("base_size varint 10 bytes", b"\xff" * 9 + b"\x01" + delta_varint(1) + b"\x01a")
    add("truncated copy args", hdr + delta_varint(4) + bytes([0x91]))
    add("trailing bytes after full result", hdr + delta_varint(5) + b"\x05hello" + b"\x01x")
    # amplification: 64 MiB from small delta
    bomb = big[:0x10000]
    ops = bytes([0x80]) * 1024  # 1024 * 64KiB = 64 MiB
    add("amplify 64MiB (1KiB delta)", delta_varint(len(bomb)) + delta_varint(1024 * 0x10000) + ops, bomb)
    add("amplify 64MiB+64KiB (> max_delta_result_bytes)", delta_varint(len(bomb)) + delta_varint(1025 * 0x10000) + ops + bytes([0x80]), bomb)
    return packs, deltas


def gen_pack():
    out = []
    A = b"base blob content\n" * 20
    B = A + b"appended\n"
    a_oid = bytes.fromhex(obj_oid("blob", A))
    import random
    rnd = random.Random(1234)
    out.append(("single blob", build_pack([{"t": 3, "data": A}])))
    out.append(("empty pack", build_pack([])))
    out.append(("version 3", build_pack([{"t": 3, "data": A}], version=3)))
    out.append(("version 1", build_pack([{"t": 3, "data": A}], version=1)))
    out.append(("count too high", build_pack([{"t": 3, "data": A}], count=2)))
    out.append(("count too low", build_pack([{"t": 3, "data": A}, {"t": 3, "data": B}], count=1)))
    out.append(("count 0x7fffffff", build_pack([{"t": 3, "data": A}], count=0x7FFFFFFF)))
    out.append(("count 0xffffffff", build_pack([{"t": 3, "data": A}], count=0xFFFFFFFF)))
    out.append(("type 0", build_pack([{"t": 0, "data": A}])))
    out.append(("type 5", build_pack([{"t": 5, "data": A}])))
    d = delta_varint(len(A)) + delta_varint(len(B)) + copy_op(0, len(A)) + bytes([9]) + b"appended\n"
    out.append(("ofs delta", build_pack([{"t": 3, "data": A}, {"t": 6, "data": d, "base": 0}])))
    out.append(("ref delta base first", build_pack([{"t": 3, "data": A}, {"t": 7, "data": d, "base": a_oid}])))
    out.append(("ref delta base after (forward)", build_pack([{"t": 7, "data": d, "base": a_oid}, {"t": 3, "data": A}])))
    out.append(("ref delta thin (missing base)", build_pack([{"t": 7, "data": d, "base": b"\x11" * 20}])))
    out.append(("ofs to self (ofs=0)", build_pack([{"t": 3, "data": A}, {"t": 6, "data": d, "ofs_raw": b"\x00"}])))
    out.append(("ofs before header (<12)", build_pack([{"t": 3, "data": A}, {"t": 6, "data": d, "ofs_raw": ofs_encode(1000)}])))
    out.append(("ofs into middle of entry", build_pack([{"t": 3, "data": A}, {"t": 6, "data": d, "ofs_raw": None}])) if False else
               ("ofs into middle of entry", build_pack([{"t": 3, "data": A}, {"t": 6, "data": d, "ofs_raw": ofs_encode(5)}])))
    # OFS varint overflow that wraps to a valid base offset (non-canonical / smuggled encoding)
    # base at offset 12; entry 2 at offset 12+len(entry1)
    e1 = pack_entry_header(3, len(A)) + zlib.compress(A)
    target = len(e1)  # neg offset that points to 12

    def wrap_encoding(t):
        """Non-canonical OFS varint (>= 11 bytes) whose 64-bit wrapping decode equals t."""
        M = 1 << 64
        digits = []
        v = t
        first = True
        while True:
            b = v % 128
            digits.append(b)
            prev = (((v - b) % M) >> 7) - 1
            if first:
                prev += 1 << 57  # inject a high bit that is shifted out (overflow)
                first = False
            prev %= M
            if prev < 128 and len(digits) >= 10:
                digits.append(prev)
                break
            v = prev
        digits.reverse()
        enc = bytes([d | 0x80 for d in digits[:-1]] + [digits[-1]])
        acc = enc[0] & 0x7F
        for x in enc[1:]:
            acc = (((acc + 1) << 7) | (x & 0x7F)) % M
        return enc, acc
    enc, val = wrap_encoding(target)
    signed = val - (1 << 64) if val >= (1 << 63) else val
    out.append((f"ofs varint 64-bit overflow wraps to {signed} (want {target})",
                build_pack([{"t": 3, "data": A}, {"t": 6, "data": d, "ofs_raw": enc}])))
    out.append(("ofs varint 12 bytes 0xff", build_pack([{"t": 3, "data": A}, {"t": 6, "data": d, "ofs_raw": b"\xff" * 11 + b"\x7f"}])))
    # size header
    out.append(("size header too small", build_pack([{"t": 3, "data": A, "size": len(A) - 1}])))
    out.append(("size header too big", build_pack([{"t": 3, "data": A, "size": len(A) + 1}])))
    out.append(("size header bit31 (negative Int)", build_pack([{"t": 3, "data": A, "hdr": bytes([0xB0 | 0, 0x80, 0x80, 0x80, 0x7F])}])))
    out.append(("size header 2^35", build_pack([{"t": 3, "data": A, "hdr": bytes([0xB0, 0x80, 0x80, 0x80, 0x80, 0x01])}])))
    out.append(("size header non-minimal (0x80 0x00)", build_pack([{"t": 3, "data": b"", "hdr": bytes([0xB0, 0x00])}])))
    out.append(("zlib trailing garbage inside pack", build_pack([{"t": 3, "data": A, "z": zlib.compress(A) + b"\x00\x00"}])))
    out.append(("zlib bad adler", build_pack([{"t": 3, "data": A, "z": zlib.compress(A)[:-1] + b"\x00"}])))
    out.append(("bad trailer", build_pack([{"t": 3, "data": A}])[:-1] + b"\x00"))
    out.append(("trailing junk before trailer", build_pack([{"t": 3, "data": A}], raw_override=lambda b: b + b"\x00")))
    out.append(("duplicate object", build_pack([{"t": 3, "data": A}, {"t": 3, "data": A}])))
    # cycles
    out.append(("ref cycle 2", build_pack([{"t": 7, "data": d, "base": bytes.fromhex(obj_oid("blob", B))},
                                           {"t": 7, "data": delta_varint(len(B)) + delta_varint(len(A)) + copy_op(0, len(A)), "base": a_oid}])))
    out.append(("ref self", build_pack([{"t": 7, "data": delta_varint(len(B)) + delta_varint(len(B)) + copy_op(0, len(B)), "base": bytes.fromhex(obj_oid("blob", B))}])))
    # chains of varied depth (OFS)
    for depth in [1, 10, 49, 50, 51, 60, 100, 250]:
        ents = [{"t": 3, "data": b"x"}]
        cur = b"x"
        for i in range(depth):
            nxt = cur + b"y"
            dd = delta_varint(len(cur)) + delta_varint(len(nxt)) + copy_op(0, len(cur)) + b"\x01y"
            ents.append({"t": 6, "data": dd, "base": i})
            cur = nxt
        out.append((f"ofs chain depth {depth}", build_pack(ents)))
    # reversed REF_DELTA chain (children first) to exercise fixed-point loop
    for depth in [10, 50, 51]:
        objs = [b"x"]
        for i in range(depth):
            objs.append(objs[-1] + b"y")
        ents = []
        for i in range(depth, 0, -1):
            cur, prev = objs[i], objs[i - 1]
            dd = delta_varint(len(prev)) + delta_varint(len(cur)) + copy_op(0, len(prev)) + b"\x01y"
            ents.append({"t": 7, "data": dd, "base": bytes.fromhex(obj_oid("blob", prev))})
        ents.append({"t": 3, "data": b"x"})
        out.append((f"reversed ref chain depth {depth}", build_pack(ents)))
    # random mixed packs
    for k in range(40):
        ents = []
        blobs = []
        for i in range(rnd.randint(1, 12)):
            if blobs and rnd.random() < 0.5:
                bi = rnd.randrange(len(blobs))
                bdata = blobs[bi][1]
                tdata = bdata[: rnd.randint(0, len(bdata))] + bytes(rnd.randrange(256) for _ in range(rnd.randint(0, 40)))
                dd = delta_varint(len(bdata)) + delta_varint(len(tdata))
                keep = len(bdata[: len(tdata)]) if tdata.startswith(bdata[: len(tdata)]) else 0
                pref = 0
                while pref < min(len(bdata), len(tdata)) and bdata[pref] == tdata[pref]:
                    pref += 1
                if pref:
                    dd += copy_op(0, pref)
                rest = tdata[pref:]
                while rest:
                    ch = rest[:127]
                    dd += bytes([len(ch)]) + ch
                    rest = rest[127:]
                if rnd.random() < 0.5:
                    ents.append({"t": 6, "data": dd, "base": blobs[bi][0]})
                else:
                    ents.append({"t": 7, "data": dd, "base": bytes.fromhex(obj_oid("blob", bdata))})
                blobs.append((len(ents) - 1, tdata))
            else:
                data = bytes(rnd.randrange(256) for _ in range(rnd.randint(0, 300)))
                ents.append({"t": rnd.choice([1, 2, 3, 4]) if False else 3, "data": data})
                blobs.append((len(ents) - 1, data))
        out.append((f"random pack #{k}", build_pack(ents)))
    # random bit flips on a valid pack (re-checksummed)
    basepack = build_pack([{"t": 3, "data": A}, {"t": 6, "data": d, "base": 0}])[:-20]
    for k in range(80):
        b = bytearray(basepack)
        for _ in range(rnd.randint(1, 3)):
            i = rnd.randrange(12, len(b))
            b[i] ^= 1 << rnd.randrange(8)
        out.append((f"bitflip #{k}", bytes(b) + hashlib.sha1(bytes(b)).digest()))
    return out


def real_packs(repo_git_dir, limit_bytes=64 << 20):
    out = []
    pdir = os.path.join(repo_git_dir, "objects", "pack")
    if os.path.isdir(pdir):
        for f in sorted(os.listdir(pdir)):
            if f.endswith(".pack"):
                p = os.path.join(pdir, f)
                if os.path.getsize(p) <= limit_bytes:
                    with open(p, "rb") as fh:
                        out.append((f"real:{f}", fh.read()))
    return out


def gen_idx(work):
    """Build a real pack + idx with git, then mutate the idx (re-checksummed)."""
    out = []
    A = b"idx base\n" * 50
    ents = [{"t": 3, "data": A + bytes([i]) * i} for i in range(64)]
    pk = build_pack(ents)
    pp = os.path.join(work, "idxsrc.pack")
    for f in (pp, pp[:-5] + ".idx"):
        if os.path.exists(f):
            os.chmod(f, 0o644)
            os.remove(f)
    with open(pp, "wb") as f:
        f.write(pk)
    subprocess.run(["git", "index-pack", "-o", pp[:-5] + ".idx", pp], check=True, capture_output=True)
    with open(pp[:-5] + ".idx", "rb") as f:
        good = f.read()

    def resum(b):
        b = bytes(b[:-20])
        return b + hashlib.sha1(b).digest()
    out.append(("valid", good))
    b = bytearray(good)
    b[8 + 4 * 10: 8 + 4 * 11] = struct.pack(">I", 0)
    out.append(("non-monotonic fanout", resum(b)))
    b = bytearray(good)
    b[1032:1052], b[1052:1072] = good[1052:1072], good[1032:1052]
    out.append(("unsorted oids (swap 0,1)", resum(b)))
    b = bytearray(good)
    b[1052:1072] = good[1032:1052]
    out.append(("duplicate oid", resum(b)))
    n = 64
    off32 = 1032 + n * 24
    b = bytearray(good)
    b[off32: off32 + 4] = struct.pack(">I", 0x80000000)
    out.append(("64-bit offset index 0 with empty off64 table", resum(b)))
    b = bytearray(good[:-40]) + struct.pack(">Q", 0xFFFFFFFFFFFFFFF0) + good[-40:]
    b[off32: off32 + 4] = struct.pack(">I", 0x80000000)
    out.append(("64-bit offset negative", resum(b)))
    b = bytearray(good[:-40]) + struct.pack(">Q", 12) + good[-40:]
    b[off32: off32 + 4] = struct.pack(">I", 0x80000000)
    out.append(("64-bit offset small (non-canonical)", resum(b)))
    b = bytearray(good)
    b[off32: off32 + 4] = struct.pack(">I", 0x7FFFFFFF)
    out.append(("offset past pack end", resum(b)))
    b = bytearray(good)
    b[off32: off32 + 4] = struct.pack(">I", 13)
    out.append(("offset mid-entry", resum(b)))
    b = bytearray(good)
    b[-21] ^= 1
    out.append(("bad idx checksum", bytes(b)))
    b = bytearray(good)
    b[-40] ^= 1
    out.append(("bad pack checksum in idx", resum(b)))
    for fan in [0x7FFFFFFF, 0x80000000, 1000000, 1000001, 153391689]:
        b = bytearray(good)
        for i in range(255, 256):
            b[8 + 4 * i: 12 + 4 * i] = struct.pack(">I", fan)
        out.append((f"fanout[255]={fan}", resum(b)))
    out.append(("version 1 header", resum(b"\xfftOc" + struct.pack(">I", 1) + good[8:])))
    out.append(("v1 idx (no magic)", good[8:]))
    out.append(("truncated", good[:2000]))
    b = bytearray(good)
    b[1032 + 5] ^= 0x10
    out.append(("oid byte flip", resum(b)))
    b = bytearray(good)
    crc = 1032 + n * 20
    b[crc] ^= 1
    out.append(("crc flip", resum(b)))
    return out, pp


def index_entry(path, oid=BLOB_OID, mode=0o100644, flags=None, ext=None, version=2, prev=b""):
    e = struct.pack(">IIIIIIIIII", 0, 0, 0, 0, 0, 0, mode, 0, 0, 0) + oid
    nl = min(len(path), 0xFFF)
    fl = nl if flags is None else flags
    if ext is not None:
        fl |= 0x4000
    e += struct.pack(">H", fl)
    if ext is not None:
        e += struct.pack(">H", ext)
    if version == 4:
        common = 0
        while common < min(len(prev), len(path)) and prev[common] == path[common]:
            common += 1
        e += ofs_encode(len(prev) - common) + path[common:] + b"\0"
    else:
        e += path + b"\0"
        while len(e) % 8:
            e += b"\0"
    return e


def build_index(paths, version=2, entries_raw=None, exts=b"", count=None, **kw):
    body = b"DIRC" + struct.pack(">II", version, len(paths) if count is None else count)
    prev = b""
    if entries_raw is not None:
        body += entries_raw
    else:
        for p in paths:
            body += index_entry(p, version=version, prev=prev, **kw)
            prev = p
    body += exts
    return body + hashlib.sha1(body).digest()


def gen_index():
    out = []
    norm = [b"a.txt", b"b/c.txt", b"b/d.txt", b"z"]
    for v in (2, 3, 4):
        out.append((f"v{v} normal", build_index(norm, version=v)))
    uni = [b"\xe6\x97\xa5\xe6\x9c\xac.txt", b"x.txt"]
    for v in (2, 4):
        out.append((f"v{v} non-ascii prev path", build_index(uni, version=v)))
        out.append((f"v{v} non-ascii shared prefix", build_index([b"\xe6\x97\xa5/a", b"\xe6\x97\xa5/b", b"\xe6\x9c\xac/c"], version=v)))
        out.append((f"v{v} latin1 path", build_index([b"caf\xe9", b"d"], version=v)))
        out.append((f"v{v} invalid utf8", build_index([b"\xff\xfe", b"z"], version=v)))
    long_p = b"d/" + b"x" * 5000
    for v in (2, 4):
        out.append((f"v{v} path >= 0xFFF", build_index([long_p], version=v)))
        out.append((f"v{v} path len 0xFFE", build_index([b"y" * 0xFFE], version=v)))
        out.append((f"v{v} path len 0xFFF", build_index([b"y" * 0xFFF], version=v)))
    # name_len mismatches (v2)
    out.append(("v2 flags name_len shorter than NUL path", build_index([b"abcdef"], flags=3)))
    out.append(("v2 flags name_len longer than path", build_index([b"abc"], flags=6)))
    out.append(("v2 flags name_len 0", build_index([b"abc"], flags=0)))
    # unsorted / duplicate
    out.append(("unsorted", build_index([b"b", b"a"])))
    out.append(("duplicate stage0", build_index([b"a", b"a"])))
    out.append(("dir/file conflict", build_index([b"a", b"a/b"])))
    # stages
    out.append(("stage 1,2,3", build_index_raw_stages()))
    # path safety
    for p in [b".git/config", b".GIT/x", b"a/../b", b"../x", b"/abs", b"a//b", b"a/", b"./a", b"a/.",
              b"GIT~1/x", b".git./x", b"a\\..\\b", b".gitmodules", b"", b"a\x01b"]:
        out.append((f"path={p!r}", build_index([p])))
    # extensions
    out.append(("ext TREE empty", build_index(norm, exts=b"TREE" + struct.pack(">I", 0))))
    out.append(("ext unknown optional (uppercase)", build_index(norm, exts=b"ZZZZ" + struct.pack(">I", 3) + b"abc")))
    out.append(("ext unknown required (lowercase)", build_index(norm, exts=b"link" + struct.pack(">I", 3) + b"abc")))
    out.append(("ext truncated", build_index(norm, exts=b"TREE" + struct.pack(">I", 100) + b"ab")))
    out.append(("ext len 0xffffffff", build_index(norm, exts=b"TREE" + struct.pack(">I", 0xFFFFFFFF))))
    out.append(("ext header partial", build_index(norm, exts=b"TRE")))
    out.append(("count too high", build_index(norm, count=5)))
    out.append(("count 0x7fffffff", build_index(norm, count=0x7FFFFFFF)))
    out.append(("count 0xffffffff", build_index(norm, count=0xFFFFFFFF)))
    out.append(("version 5", build_index(norm, version=5)))
    out.append(("version 1", build_index(norm, version=1)))
    b = bytearray(build_index(norm))
    b[-1] ^= 1
    out.append(("bad checksum", bytes(b)))
    # v2 with extended flag set (only valid in v3+)
    out.append(("v2 with CE_EXTENDED flag", build_index([b"a"], version=2, ext=0)))
    out.append(("v3 extended intent-to-add", build_index([b"a"], version=3, ext=0x2000)))
    out.append(("v3 extended unknown bits", build_index([b"a"], version=3, ext=0x0001)))
    # v4 malformed strip
    raw = index_entry(b"abc", version=4) + index_entry(b"x", version=4, prev=b"abc")
    raw_bad = raw[:-3] + ofs_encode(10) + b"x\0"
    out.append(("v4 strip > prev len", build_index([b"abc", b"x"], version=4, entries_raw=raw_bad)))
    return out


def build_index_raw_stages():
    raw = b""
    for st in (1, 2, 3):
        raw += index_entry(b"conflict", flags=(st << 12) | 8)
    return build_index([b"c"] * 3, entries_raw=raw)


def gen_pkt():
    out = []
    def pl(s):
        return b"%04x" % (len(s) + 4) + s
    out.append(("flush", b"0000"))
    out.append(("delim", b"0001"))
    out.append(("response-end", b"0002"))
    out.append(("len 3", b"0003"))
    out.append(("empty data 0004", b"0004"))
    out.append(("hello", pl(b"hello\n")))
    out.append(("uppercase hex 000A", b"000Ahello\n"))
    out.append(("mixed case 000a", b"000ahello\n"))
    out.append(("non-hex", b"00g0" + b"x" * 12))
    out.append(("space in length", b" 00a" + b"x" * 6))
    out.append(("truncated payload", pl(b"hello")[:-1]))
    out.append(("truncated prefix", b"00"))
    out.append(("max 65520", pl(b"x" * 65516)))
    out.append(("65521", b"fff1" + b"x" * 65517))
    out.append(("ffff", b"ffff" + b"x" * 65531))
    out.append(("sideband 1", pl(b"\x01PACK")))
    out.append(("sideband 0", pl(b"\x00x")))
    out.append(("sideband 4", pl(b"\x04x")))
    out.append(("sequence", pl(b"a") + b"0000" + pl(b"b") + b"0001" + b"0002"))
    for n in range(4, 40):
        out.append((f"len {n}", (b"%04x" % n) + b"z" * (n - 4)))
    return out


def gen_ref():
    names = [
        "refs/heads/main", "HEAD", "main", "refs/heads/feature/x", "refs/heads/a..b", "refs/heads/a.",
        "refs/heads/.a", "refs/heads/a.lock", "refs/heads/a.lock/b", "refs/heads/@", "@", "@{", "a@{b",
        "refs/heads/@{u}", "refs/heads/a@b", "refs/heads/a b", "refs/heads/a~b", "refs/heads/a^b",
        "refs/heads/a:b", "refs/heads/a?b", "refs/heads/a*b", "refs/heads/a[b", "refs/heads/a\\b",
        "refs/heads//a", "/refs/heads/a", "refs/heads/a/", "refs/heads/a\x01", "refs/heads/a\x7f",
        "refs/heads/a\tb", "refs/heads/-a", "-", "refs/heads/a.b", "refs/heads/foo./bar",
        "refs/heads/foo.lock.x", "refs/heads/.lock", "refs/heads/lock", "refs/.heads/a",
        "refs/heads/日本", "refs/heads/café", ".", "..", "refs/heads/.", "refs/heads/..",
        "refs", "refs/", "a/b", "a", "A", "FETCH_HEAD", "refs/heads/a{b", "refs/heads/a}b",
        "refs/heads/a@", "refs/heads/@a", "refs/heads/a@{", "refs/tags/v1.0", "refs/heads/a..",
        "refs/heads/a/.b", "refs/heads/a/b.", "refs/heads/a/b.lock", "refs/heads/a/b..c",
        "refs/heads/" + "x" * 300, "refs/heads/a\"b", "refs/heads/a'b", "refs/heads/a<b",
        "refs/heads/a>b", "refs/heads/a|b", "refs/heads/a#b", "refs/heads/a%b", "refs/heads/a!b",
        "refs/heads/a=b", "refs/heads/a+b", "refs/heads/a,b", "refs/heads/a;b", "refs/heads/a&b",
        "refs/heads/a$b", "refs/heads/a(b)", "refs/heads/a`b", "refs/heads/ab.lock.lock",
        "refs/heads/a/.lock", "refs/heads/a..lock", "refs/heads/@/a", "@/a", "a/@", "refs//heads",
        "refs/heads/a b", "refs/heads/a　b", "refs/heads/﻿a", "refs/heads/a​b",
        "refs/heads/a\x00b", "refs/heads/LOCK", "refs/heads/a.LOCK",
    ]
    # systematic: every printable ASCII char in three positions
    for c in range(0, 128):
        ch = chr(c)
        names.append("refs/heads/x" + ch + "y")
        names.append("refs/heads/" + ch + "y")
        names.append("refs/heads/y" + ch)
    out = []
    for nm in names:
        b = nm.encode("utf-8", "surrogatepass")
        out.append((f"onelevel=0 {nm!r}", b"\x00" + b))
        out.append((f"onelevel=1 {nm!r}", b"\x01" + b))
    return out


# ---------------------------------------------------------------------------
# Runners
# ---------------------------------------------------------------------------

def write_batch(path, recs):
    with open(path, "wb") as f:
        for _, b in recs:
            f.write(struct.pack(">I", len(b)) + b)


def run_oracle(binary, mode, recs, work, tag, runner=None):
    """Run a batch oracle; restart after crashes; returns list of result strings."""
    batch = os.path.join(work, f"{tag}-{mode}.bin")
    write_batch(batch, recs)
    results = [None] * len(recs)
    start = 0
    while start < len(recs):
        cmd = (runner or []) + [binary, mode, batch] + ([str(start)] if tag.startswith("pion") else [])
        p = subprocess.run(cmd, capture_output=True, timeout=600)
        lines = p.stdout.decode("utf-8", "replace").splitlines()
        got = 0
        for ln in lines:
            m = re.match(r"^(\d+) (.*)$", ln)
            if m:
                results[int(m.group(1))] = m.group(2)
                got = int(m.group(1)) + 1
        if p.returncode != 0 or got < len(recs):
            if got < start:
                got = start
            if got >= len(recs):
                break
            results[got] = "CRASH rc=%d %s" % (p.returncode, p.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] if p.stderr else "")
            start = got + 1
            if not tag.startswith("pion"):
                # gix oracle has no restart index: run remaining individually
                for i in range(start, len(recs)):
                    if results[i] is None:
                        r = run_oracle(binary, mode, [recs[i]], work, tag + "-single")
                        results[i] = r[0]
                break
        else:
            break
    return results


class GitRef:
    def __init__(self, work):
        self.work = work
        self.repo = os.path.join(work, "gitrepo")
        if os.path.exists(self.repo):
            shutil.rmtree(self.repo)
        subprocess.run(["git", "init", "-q", self.repo], check=True)

    def git(self, args, inp=None):
        return subprocess.run(["git", "-C", self.repo] + args, input=inp, capture_output=True, timeout=120)

    def hash_object(self, kind, payload):
        r = self.git(["hash-object", "-t", kind, "--stdin"], payload)
        if r.returncode == 0:
            return "OK", ""
        m = re.search(rb"fsck: (\w+):", r.stderr)
        return "ERR", (m.group(1).decode() if m else r.stderr.decode("utf-8", "replace").strip()[:80])

    def loose(self, data):
        try:
            raw = zlib.decompress(data)
            oid = sha1(raw)
        except Exception:
            oid = "ff" * 20
        d = os.path.join(self.repo, ".git", "objects", oid[:2])
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, oid[2:])
        with open(p, "wb") as f:
            f.write(data)
        r = self.git(["fsck", "--no-dangling", "--no-reflogs", "--strict", "--full"])
        t = self.git(["cat-file", "-t", oid])
        os.remove(p)
        err = r.stderr.decode("utf-8", "replace").strip()
        if r.returncode == 0 and "error" not in err and t.returncode == 0:
            return "OK", t.stdout.decode().strip()
        return "ERR", (err.splitlines() or [""])[0][:80]

    def pack(self, data):
        pp = os.path.join(self.work, "ref.pack")
        ip = os.path.join(self.work, "ref.idx")
        for f in (pp, ip):
            if os.path.exists(f):
                os.chmod(f, 0o644)
                os.remove(f)
        with open(pp, "wb") as f:
            f.write(data)
        r = subprocess.run(["git", "index-pack", "-o", ip, pp], capture_output=True, timeout=300, cwd=self.repo)
        if r.returncode != 0:
            return "ERR", r.stderr.decode("utf-8", "replace").strip().splitlines()[-1][:100] if r.stderr else ""
        si = subprocess.run(["git", "show-index"], stdin=open(ip, "rb"), capture_output=True, timeout=300)
        oids = sorted({ln.split()[1] for ln in si.stdout.decode().splitlines() if ln.strip()})
        pdir = os.path.join(self.repo, ".git", "objects", "pack")
        os.makedirs(pdir, exist_ok=True)
        for f in os.listdir(pdir):
            os.chmod(os.path.join(pdir, f), 0o644)
            os.remove(os.path.join(pdir, f))
        shutil.copy(pp, os.path.join(pdir, "pack-x.pack"))
        shutil.copy(ip, os.path.join(pdir, "pack-x.idx"))
        bc = self.git(["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
                      ("\n".join(oids) + "\n").encode())
        lines = set(l for l in bc.stdout.decode().splitlines() if l and "missing" not in l)
        for f in os.listdir(pdir):
            os.chmod(os.path.join(pdir, f), 0o644)
            os.remove(os.path.join(pdir, f))
        s = "".join(l + "\n" for l in sorted(lines))
        return "OK", f"n={len(lines)} h={sha1(s.encode())}"

    def idx(self, data, pack_path):
        ip = pack_path[:-5] + ".idx"
        if os.path.exists(ip):
            os.chmod(ip, 0o644)
            os.remove(ip)
        with open(ip, "wb") as f:
            f.write(data)
        r = subprocess.run(["git", "verify-pack", ip], capture_output=True, timeout=120, cwd=self.repo)
        if r.returncode == 0:
            return "OK", ""
        return "ERR", (r.stderr.decode("utf-8", "replace").strip().splitlines() or [""])[0][:100]

    def index(self, data):
        p = os.path.join(self.repo, ".git", "index")
        with open(p, "wb") as f:
            f.write(data)
        r = self.git(["ls-files", "-s", "-z"])
        os.remove(p)
        if r.returncode != 0:
            return "ERR", (r.stderr.decode("utf-8", "replace").strip().splitlines() or [""])[0][:100]
        s = ""
        n = 0
        for rec in r.stdout.split(b"\0"):
            if not rec:
                continue
            meta, path = rec.split(b"\t", 1)
            mode, oid, stage = meta.split(b" ")
            s += f"{oid.decode()} {stage.decode()} {path.hex()}\n"
            n += 1
        return "OK", f"n={n} h={sha1(s.encode())}"

    def ref(self, rec):
        onelevel = rec[0] != 0
        try:
            name = rec[1:].decode("utf-8")
        except UnicodeDecodeError:
            return "ERR", "non-utf8 argv"
        if "\x00" in name:
            return "ERR", "NUL (unrepresentable in argv)"
        args = ["check-ref-format"] + (["--allow-onelevel"] if onelevel else []) + [name]
        r = subprocess.run(["git"] + args, capture_output=True, timeout=30)
        return ("OK" if r.returncode == 0 else "ERR"), ""


def verdict(s):
    if s is None:
        return "MISSING"
    if s.startswith("OK"):
        return "OK"
    if s.startswith("CRASH") or s.startswith("PANIC"):
        return "CRASH"
    return "ERR"


def extract(s, key):
    m = re.search(key + r"=(\S+)", s or "")
    return m.group(1) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pion", required=True)
    ap.add_argument("--gix", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--modes", default="tree,commit,tag,loose,delta,pack,idx,index,pkt,ref")
    ap.add_argument("--real-git-dir", default="")
    ap.add_argument("--real-pack", action="append", default=[], help="extra real .pack files")
    ap.add_argument("--pion-runner", default="", help="prefix command for the pion oracle (e.g. wasm)")
    ap.add_argument("--json-out", default="")
    args = ap.parse_args()
    os.makedirs(args.work, exist_ok=True)
    gr = GitRef(args.work)
    modes = args.modes.split(",")
    report = {}
    total = 0
    for mode in modes:
        if mode == "tree":
            recs = gen_tree()
        elif mode == "commit":
            recs = gen_commit()
        elif mode == "tag":
            recs = gen_tag()
        elif mode == "loose":
            recs = gen_loose()
        elif mode == "delta":
            packs, recs = gen_delta_vectors()
        elif mode == "pack":
            recs = gen_pack()
            if args.real_git_dir:
                recs += real_packs(args.real_git_dir)
            for rp in args.real_pack:
                with open(rp, "rb") as fh:
                    recs.append(("real:" + os.path.basename(rp), fh.read()))
        elif mode == "idx":
            recs, idx_pack = gen_idx(args.work)
        elif mode == "index":
            recs = gen_index()
        elif mode == "pkt":
            recs = gen_pkt()
        elif mode == "ref":
            recs = gen_ref()
        else:
            continue
        pion_mode = mode
        pion = run_oracle(args.pion, pion_mode, recs, args.work, "pion")
        gixm = mode if mode not in ("delta",) else None
        gix = run_oracle(args.gix, gixm, recs, args.work, "gix") if gixm else [None] * len(recs)
        rows = []
        for i, (label, data) in enumerate(recs):
            g, gnote = ("-", "")
            if mode in ("tree", "commit", "tag"):
                g, gnote = gr.hash_object(mode, data)
            elif mode == "loose":
                g, gnote = gr.loose(data)
            elif mode == "pack":
                g, gnote = gr.pack(data)
            elif mode == "idx":
                g, gnote = gr.idx(data, idx_pack)
            elif mode == "index":
                g, gnote = gr.index(data)
            elif mode == "ref":
                g, gnote = gr.ref(data)
            rows.append({"i": i, "label": label, "pion": pion[i], "gix": gix[i], "git": g, "git_note": gnote})
        if mode == "delta":
            # wrap into packs: three-way on the pack form, plus direct apply_delta crash check
            ppion = run_oracle(args.pion, "pack", packs, args.work, "pion")
            pgix = run_oracle(args.gix, "pack", packs, args.work, "gix")
            for i, (label, data) in enumerate(packs):
                g, gnote = gr.pack(data)
                rows[i]["pion_pack"] = ppion[i]
                rows[i]["gix"] = pgix[i]
                rows[i]["git"] = g
                rows[i]["git_note"] = gnote
        total += len(rows)
        report[mode] = rows
        # summary
        agree = lenient = strict = content = crash = lossy = 0
        for r in rows:
            pv = verdict(r.get("pion_pack", r["pion"]))
            if verdict(r["pion"]) == "CRASH":
                crash += 1
            ref = r["git"] if r["git"] != "-" else verdict(r["gix"])
            if ref not in ("OK", "ERR"):
                continue
            if pv == ref:
                if pv == "OK" and mode in ("pack", "index", "delta"):
                    ph = extract(r.get("pion_pack", r["pion"]), "h")
                    gh = extract(r["git_note"], "h") if r["git"] != "-" else extract(r["gix"], "h")
                    if ph and gh and ph != gh:
                        content += 1
                        r["class"] = "CONTENT_DIFF"
                        continue
                if pv == "OK" and mode in ("tree", "commit", "tag", "index") and extract(r["pion"], "rt") not in (None, "same"):
                    lossy += 1
                    r["class"] = "RT_LOSSY(gix rt=%s)" % extract(r["gix"], "rt")
                    continue
                agree += 1
                r["class"] = "AGREE"
            elif pv == "OK" and ref == "ERR":
                lenient += 1
                r["class"] = "PION_ACCEPTS_GIT_REJECTS"
            elif pv == "ERR" and ref == "OK":
                strict += 1
                r["class"] = "PION_REJECTS_GIT_ACCEPTS"
            else:
                r["class"] = "PION_" + pv
        print(f"{mode:7s} n={len(rows):4d} agree={agree:4d} pion_lenient={lenient:3d} pion_strict={strict:3d} content_diff={content:3d} rt_lossy={lossy:3d} pion_crash={crash}")
        for r in rows:
            if r.get("class", "AGREE") != "AGREE" or verdict(r["pion"]) == "CRASH":
                print(f"   [{r.get('class','?')}] {r['label'][:90]}\n       pion={str(r.get('pion_pack', r['pion']))[:90]} | git={r['git']} {r['git_note'][:60]} | gix={str(r['gix'])[:60]}")
    print(f"TOTAL vectors: {total}")
    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(report, f, indent=1, default=str)


if __name__ == "__main__":
    main()
