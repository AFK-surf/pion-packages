#!/usr/bin/env python3
"""Independent hand-written RFC 8489 / RFC 5769 reference for the packages/stun red-team audit.

  stunref.py gen <outdir>        write specs.tsv (encode specs), ref_wire.tsv (reference encodings)
                                 and corpus.tsv (decode corpus: RFC 5769 + valid + attack + mutated)
  stunref.py decode <corpus.tsv> canonical decode/verify line per vector (same format as the oracles)

Only the Python standard library (hmac/hashlib/zlib) is used. Decoding rules follow the RFC text,
not the audited implementation; see README.md for where they intentionally differ (MI-SHA256 truncation).
"""
import hashlib
import hmac
import random
import struct
import sys
import zlib

COOKIE = 0x2112A442
FPX = 0x5354554E


def tlv(t, v):
    return struct.pack(">HH", t, len(v)) + v + b"\0" * ((4 - len(v) % 4) % 4)


def hdr(mtype, body_len, tx):
    return struct.pack(">HHI", mtype, body_len, COOKIE) + tx


def xor_addr(v, tx):
    """plain address value -> XOR-MAPPED-ADDRESS value"""
    fam = v[1]
    port = struct.unpack(">H", v[2:4])[0] ^ 0x2112
    mask = struct.pack(">I", COOKIE) + (tx if fam == 2 else b"")
    ip = bytes(a ^ b for a, b in zip(v[4:], mask))
    return bytes([0, fam]) + struct.pack(">H", port) + ip


def encode(mtype, tx, key, mode, attrs):
    body = b""
    for t, v in attrs:
        body += tlv(t, xor_addr(v, tx) if t == 0x0020 else v)
    if mode in ("s1", "s1f", "s2", "s2f"):
        sha256 = mode.startswith("s2")
        milen = 32 if sha256 else 20
        h = hdr(mtype, len(body) + 4 + milen, tx)
        mac = hmac.new(key, h + body, hashlib.sha256 if sha256 else hashlib.sha1).digest()
        body += tlv(0x001C if sha256 else 0x0008, mac)
    if mode in ("f", "s1f", "s2f"):
        h = hdr(mtype, len(body) + 8, tx)
        crc = (zlib.crc32(h + body) & 0xFFFFFFFF) ^ FPX
        body += tlv(0x8028, struct.pack(">I", crc))
    return hdr(mtype, len(body), tx) + body


# ---------------------------------------------------------------------------- decode (RFC rules)


def framing(raw):
    """RFC 8489 §5/§6 framing; returns list of (type, off, len) or None."""
    if len(raw) < 20 or raw[0] & 0xC0:
        return None
    mlen = struct.unpack(">H", raw[2:4])[0]
    if mlen % 4 or struct.unpack(">I", raw[4:8])[0] != COOKIE or 20 + mlen != len(raw):
        return None
    out, pos = [], 20
    while pos < len(raw):
        if pos + 4 > len(raw):
            return None
        t, l = struct.unpack(">HH", raw[pos:pos + 4])
        if pos + 4 + ((l + 3) & ~3) > len(raw):
            return None
        out.append((t, pos + 4, l))
        pos += 4 + ((l + 3) & ~3)
    return out


def has_attr(raw, t):
    if len(raw) < 20:
        return False
    pos = 20
    while pos + 4 <= len(raw):
        at, al = struct.unpack(">HH", raw[pos:pos + 4])
        if at == t:
            return True
        pos += 4 + ((al + 3) & ~3)
    return False


def addr(raw, off, l, xor):
    if l < 4:
        raise ValueError
    fam = raw[off + 1]
    port = struct.unpack(">H", raw[off + 2:off + 4])[0]
    tx = raw[8:20]
    if fam == 1 and l == 8:
        ip = raw[off + 4:off + 8]
        if xor:
            port ^= 0x2112
            ip = bytes(a ^ b for a, b in zip(ip, struct.pack(">I", COOKIE)))
        return "%d.%d.%d.%d:%d" % (ip[0], ip[1], ip[2], ip[3], port)
    if fam == 2 and l == 20:
        ip = raw[off + 4:off + 20]
        if xor:
            port ^= 0x2112
            ip = bytes(a ^ b for a, b in zip(ip, struct.pack(">I", COOKIE) + tx))
        return "[%s]:%d" % (ip.hex(), port)
    raise ValueError


FIXED = {0x0024: 4, 0x0025: 0, 0x8029: 8, 0x802A: 8, 0x0008: 20, 0x8028: 4}


def typed_ok(raw, t, off, l):
    if t in (0x0001, 0x0020):
        addr(raw, off, l, t == 0x0020)
    elif t in FIXED:
        if l != FIXED[t]:
            raise ValueError
    elif t == 0x001C:
        # RFC 8489 §14.6: 16..32 bytes, multiple of 4 (truncation allowed)
        if l < 16 or l > 32 or l % 4:
            raise ValueError
    elif t == 0x0009:
        if l < 4:
            raise ValueError
        cls, num = raw[off + 2] & 7, raw[off + 3]
        if cls < 3 or cls > 6 or num > 99:
            raise ValueError
    elif t == 0x000A:
        if l % 2:
            raise ValueError


def verify(raw, key, t):
    fr = framing(raw)
    if fr is None:
        return "err"
    for i, (at, off, l) in enumerate(fr):
        if at != t:
            continue
        if t == 0x8028:
            if l != 4:
                return "err"
            if i != len(fr) - 1:
                return "err"
            want = (zlib.crc32(raw[:off - 4]) & 0xFFFFFFFF) ^ FPX
            return "true" if struct.unpack(">I", raw[off:off + 4])[0] == want else "false"
        if t == 0x0008:
            if l != 20:
                return "err"
            h = bytearray(raw[:20])
            h[2:4] = struct.pack(">H", off + 20 - 20)
            mac = hmac.new(key, bytes(h) + raw[20:off - 4], hashlib.sha1).digest()
            return "true" if hmac.compare_digest(mac, raw[off:off + 20]) else "false"
        if t == 0x001C:
            if l < 16 or l > 32 or l % 4:
                return "err"
            h = bytearray(raw[:20])
            h[2:4] = struct.pack(">H", off + l - 20)
            mac = hmac.new(key, bytes(h) + raw[20:off - 4], hashlib.sha256).digest()[:l]
            return "true" if hmac.compare_digest(mac, raw[off:off + l]) else "false"
    return "err"


def decode_line(raw, key):
    fr = framing(raw)
    d, xa = "err", "-"
    if fr is not None:
        try:
            for at, off, l in fr:
                typed_ok(raw, at, off, l)
            d = "ok:%d:%s" % (len(fr), ",".join("%04x" % a[0] for a in fr[:12]))
            for at, off, l in fr:
                if at == 0x0020:
                    xa = addr(raw, off, l, True)
                    break
        except ValueError:
            d, xa = "err", "-"

    def v(t):
        return verify(raw, key, t) if has_attr(raw, t) else "none"

    return "D=%s\tFP=%s\tMI=%s\tM2=%s\tXA=%s" % (d, v(0x8028), v(0x0008), v(0x001C), xa)


# ---------------------------------------------------------------------------- corpus


def v4(a, b, c, d, port):
    return bytes([0, 1]) + struct.pack(">H", port) + bytes([a, b, c, d])


def v6(ip16, port):
    return bytes([0, 2]) + struct.pack(">H", port) + ip16


def specs():
    """ICE / STUN encode vectors shaped like Chrome / Google Meet / libwebrtc traffic."""
    rnd = random.Random(8489)
    out = []
    keys = {
        "pwd22": b"VOkJxbRl1RmTxUk/WvJxBt",
        "pwd24": b"Q9wQj99nsQzldVI5ZuGXbEWR",
        "empty": b"",
        "k64": bytes(range(64)),
        "k65": bytes(range(65)),
        "k200": bytes((i * 7) & 0xFF for i in range(200)),
        "utf8": "pässwörd-ключ-密码".encode(),
        "lt_md5": hashlib.md5("マトリックス:example.org:TheMatrIX".encode()).digest(),
    }
    for n in range(48):
        kname = list(keys)[n % len(keys)]
        key = keys[kname]
        tx = bytes(rnd.randrange(256) for _ in range(12))
        kind = n % 6
        mode = ["s1f", "s1f", "s1", "f", "n", "s2f"][(n // 6) % 6]
        if kind == 0:  # Chrome connectivity check (controlling, nominating)
            uf = "%s:%s" % ("".join(rnd.choice("abcdefghijKLMN0123456789+/") for _ in range(4)), "".join(rnd.choice("abcdefXYZ0123456789") for _ in range(4)))
            attrs = [(0x0006, uf.encode()), (0xC057, struct.pack(">HH", 1, 10)), (0x802A, rnd.getrandbits(64).to_bytes(8, "big")),
                     (0x0025, b""), (0x0024, struct.pack(">I", 1853759231 - n))]
            mtype = 0x0001
        elif kind == 1:  # controlled check, GOOG-NETWORK-INFO + long ufrag
            attrs = [(0x0006, ("x" * (n % 9 + 4) + ":" + "y" * 16).encode()), (0x8029, rnd.getrandbits(64).to_bytes(8, "big")),
                     (0x0024, struct.pack(">I", 2122260223))]
            mtype = 0x0001
        elif kind == 2:  # success response IPv4
            attrs = [(0x0020, v4(rnd.randrange(256), rnd.randrange(256), 0, n, [0, 1, 3478, 65535, 0x2112][n % 5]))]
            mtype = 0x0101
        elif kind == 3:  # success response IPv6
            ip = [bytes(16), b"\xff" * 16, bytes(15) + b"\1", bytes(rnd.randrange(256) for _ in range(16))][n % 4]
            attrs = [(0x0020, v6(ip, [0, 65535, 3478, 51234][n % 4])), (0x8022, b"libwebrtc")]
            mtype = 0x0101
        elif kind == 4:  # error responses (487 role conflict, 401, 420 + UNKNOWN-ATTRIBUTES, 400)
            code = [487, 401, 420, 400, 438, 500][n % 6]
            attrs = [(0x0009, bytes([0, 0, code // 100, code % 100]) + ["Role Conflict", "Unauthorized", "Unknown Attribute", "Bad Request", "Stale Nonce", "Server Error x"][n % 6].encode())]
            if code == 420:
                attrs.append((0x000A, struct.pack(">HH", 0x0024, 0x7FFF)))
            mtype = 0x0111
        else:  # long-term style request with REALM / NONCE / SOFTWARE / MAPPED-ADDRESS
            attrs = [(0x0006, "マトリックス".encode()), (0x0015, b"f//499k954d6OL34oL9FSTvy64sA"),
                     (0x0014, b"example.org"), (0x8022, "STUN test client é".encode()), (0x0001, v4(10, 0, 0, 1, 5000))]
            mtype = 0x0003 if n % 2 else 0x0001
        out.append(("enc%02d_%s_%s_k%s" % (n, ["chk_ctl", "chk_ced", "resp_v4", "resp_v6", "err", "lt"][kind], mode, kname), mtype, tx, key, mode, attrs))
    return out


RFC5769 = [
    ("rfc5769_2_1", "000100582112a442b7e7a701bc34d686fa87dfae802200105354554e207465737420636c69656e74002400046e0001ff80290008932ff9b151263b36000600096576746a3a68367659202020000800149aeaa70cbfd8cb56781ef2b5b2d3f249c1b571a280280004e57a3bcf", b"VOkJxbRl1RmTxUk/WvJxBt"),
    ("rfc5769_2_2", "0101003c2112a442b7e7a701bc34d686fa87dfae8022000b7465737420766563746f7220002000080001a147e112a643000800142b91f599fd9e90c38c7489f92af9ba53f06be7d780280004c07d4c96", b"VOkJxbRl1RmTxUk/WvJxBt"),
    ("rfc5769_2_3", "010100482112a442b7e7a701bc34d686fa87dfae8022000b7465737420766563746f7220002000140002a1470113a9faa5d3f179bc25f4b5bed2b9d900080014a382954e4be67bf11784c97c8292c275bfe3ed4180280004c8fb0b4c", b"VOkJxbRl1RmTxUk/WvJxBt"),
    ("rfc5769_2_4", "000100602112a44278ad3433c6ad72c029da412e00060012e3839ee38388e383aae38383e382afe382b900000015001c662f2f3439396b39353464364f4c33346f4c394653547679363473410014000b6578616d706c652e6f72670000080014f67024656dd64a3e02b8e0712e85c9a28ca89666",
     hashlib.md5("マトリックス:example.org:TheMatrIX".encode()).digest()),
]


def attack_vectors(valid):
    """Hand-built attacks on top of a valid signed ICE check (key pwd22)."""
    key = b"VOkJxbRl1RmTxUk/WvJxBt"
    tx = bytes(range(1, 13))
    base_attrs = [(0x0006, b"abcd:efgh"), (0x0024, struct.pack(">I", 1853759231)), (0x802A, bytes(8))]
    good = encode(0x0001, tx, key, "s1f", base_attrs)
    nofp = encode(0x0001, tx, key, "s1", base_attrs)
    out = [("atk_good", good, key)]

    def refp(b):
        h = bytearray(b[:20])
        h[2:4] = struct.pack(">H", len(b) - 20 + 8)
        body = bytes(h) + b[20:]
        return body + tlv(0x8028, struct.pack(">I", (zlib.crc32(body) & 0xFFFFFFFF) ^ FPX))

    def fixlen(b):
        return b[:2] + struct.pack(">H", len(b) - 20) + b[4:]

    for name, extra in [("use_cand", tlv(0x0025, b"")), ("username", tlv(0x0006, b"evil:evil")), ("xma", tlv(0x0020, xor_addr(v4(6, 6, 6, 6, 6666), tx))),
                        ("second_mi", tlv(0x0008, bytes(20))), ("mi256", tlv(0x001C, bytes(32))), ("unknown_req", tlv(0x7FFF, b"x")),
                        ("errcode", tlv(0x0009, b"\0\0\x04\x57"))]:
        out.append(("atk_after_mi_" + name, refp(nofp + extra), key))
        out.append(("atk_after_mi_nofp_" + name, fixlen(nofp + extra), key))
    out.append(("atk_fp_stripped", nofp, key))
    out.append(("atk_fp_not_last", fixlen(good + tlv(0x8022, b"tail")), key))
    out.append(("atk_two_fp", refp(good), key))
    out.append(("atk_fp_before_mi", encode(0x0001, tx, b"", "n", base_attrs + [(0x8028, bytes(4)), (0x0008, bytes(20))]), key))
    out.append(("atk_trailing_garbage", good + b"\0\0\0\0", key))
    out.append(("atk_len_covers_less", good[:2] + struct.pack(">H", len(good) - 28) + good[4:], key))
    out.append(("atk_mi_len19", fixlen(nofp[:-24] + struct.pack(">HH", 8, 19) + nofp[-20:]), key))
    out.append(("atk_mi_len21", fixlen(nofp[:-24] + struct.pack(">HH", 8, 21) + nofp[-20:] + b"\0" * 4), key))
    out.append(("atk_mi_outer_len", nofp[:2] + nofp[2:4] + nofp[4:], key))
    # MI computed with the OUTER length (incl. FINGERPRINT) -- a classic implementation bug; must be "false"
    h = hdr(0x0001, len(nofp) - 20 + 8, tx)
    body = b"".join(tlv(t, v) for t, v in base_attrs)
    mac = hmac.new(key, h + body, hashlib.sha1).digest()
    wrong = hdr(0x0001, len(body) + 24, tx) + body + tlv(0x0008, mac)
    out.append(("atk_mi_over_outer_length", refp(wrong), key))
    # long keys / empty key / truncated MI-SHA256 (RFC 8489 allows 16..32, multiple of 4)
    for kl in (0, 1, 63, 64, 65, 128, 300):
        k = bytes((i * 13 + 1) & 0xFF for i in range(kl))
        out.append(("key_len_%d" % kl, encode(0x0001, tx, k, "s1f", base_attrs), k))
        out.append(("key256_len_%d" % kl, encode(0x0001, tx, k, "s2f", base_attrs), k))
    for tl in (16, 20, 24, 28):
        k = b"trunc-key"
        hh = hdr(0x0001, len(body) + 4 + tl, tx)
        mac = hmac.new(k, hh + body, hashlib.sha256).digest()[:tl]
        out.append(("mi256_trunc_%d" % tl, hdr(0x0001, len(body) + 4 + tl, tx) + body + tlv(0x001C, mac), k))
    # address shapes
    for name, val in [("v4_len7", bytes([0, 1, 0, 1, 1, 2, 3])), ("v6_len8", v4(1, 2, 3, 4, 5)[:1] + b"\2" + v4(1, 2, 3, 4, 5)[2:]), ("fam0", b"\0\0\0\1\1\2\3\4"),
                      ("fam3", b"\0\3\0\1\1\2\3\4"), ("famff", b"\0\xff\0\1\1\2\3\4"), ("resv_nonzero", b"\xff\1\0\1\1\2\3\4"), ("port0", xor_addr(v4(0, 0, 0, 0, 0), tx)),
                      ("allff", xor_addr(v4(255, 255, 255, 255, 65535), tx))]:
        out.append(("addr_" + name, encode(0x0101, tx, key, "n", []) [:0] + hdr(0x0101, len(tlv(0x0020, val)), tx) + tlv(0x0020, val), key))
    # error-code and unknown-attributes shapes
    for name, val in [("cls2", b"\0\0\2\0"), ("cls7", b"\0\0\7\0"), ("num100", b"\0\0\4\x64"), ("resv_bits", b"\xff\xff\xfc\x01x"), ("long_reason", b"\0\0\4\1" + b"A" * 900),
                      ("badutf8", b"\0\0\4\1\xff\xfe")]:
        out.append(("err_" + name, hdr(0x0111, len(tlv(0x0009, val)), tx) + tlv(0x0009, val), key))
    for name, val in [("odd", b"\0\x24\0"), ("empty", b""), ("many", b"\x7f\xff" * 2000)]:
        out.append(("unk_" + name, hdr(0x0111, len(tlv(0x000A, val)), tx) + tlv(0x000A, val), key))
    for name, t, val in [("prio3", 0x0024, b"\0\0\0"), ("ctl7", 0x802A, bytes(7)), ("ced9", 0x8029, bytes(9)), ("usecand4", 0x0025, bytes(4)), ("fp3", 0x8028, bytes(3))]:
        out.append(("len_" + name, hdr(0x0001, len(tlv(t, val)), tx) + tlv(t, val), key))
    # header shapes
    for tb in (0x40, 0x80, 0xC0):
        out.append(("hdr_top_%02x" % tb, bytes([good[0] | tb]) + good[1:], key))
    out.append(("hdr_cookie", good[:4] + b"\x21\x12\xa4\x43" + good[8:], key))
    out.append(("hdr_len_odd", good[:3] + bytes([good[3] + 1]) + good[4:], key))
    out.append(("hdr_short19", good[:19], key))
    out.append(("attr_ffff", fixlen(hdr(0x0001, 0, tx) + struct.pack(">HH", 0x8022, 0xFFFF) + bytes(64)), key))
    out.append(("attr_nonzero_pad", fixlen(hdr(0x0001, 0, tx) + struct.pack(">HH", 0x8022, 1) + b"a\xff\xff\xff"), key))
    out.append(("max_size_msg", fixlen(hdr(0x0001, 0, tx) + b"".join(tlv(0x8022, bytes(4092)) for _ in range(15)) + tlv(0x8022, bytes(65532 - 15 * 4096 - 4))), key))
    return out


def mutations(seeds, n, seed=7983):
    rnd = random.Random(seed)
    out = []
    for i in range(n):
        name, b, key = seeds[rnd.randrange(len(seeds))]
        b = bytearray(b)
        op = rnd.randrange(6)
        if op == 0 and b:
            for _ in range(rnd.randrange(1, 4)):
                b[rnd.randrange(len(b))] ^= 1 << rnd.randrange(8)
        elif op == 1:
            b = b[:rnd.randrange(len(b) + 1)]
        elif op == 2 and len(b) >= 4:
            b[2:4] = struct.pack(">H", rnd.randrange(0, 0x400) & ~3 if rnd.random() < .7 else rnd.randrange(0x10000))
        elif op == 3 and len(b) > 24:
            # patch one attribute length
            pos = 20
            for _ in range(rnd.randrange(4)):
                if pos + 4 > len(b):
                    break
                pos += 4 + ((struct.unpack(">H", b[pos + 2:pos + 4])[0] + 3) & ~3)
            if pos + 4 <= len(b):
                b[pos + 2:pos + 4] = struct.pack(">H", rnd.choice([0, 1, 3, 4, 7, 8, 19, 20, 21, 32, 0xFFFF, rnd.randrange(0x10000)]))
        elif op == 4 and 28 <= len(b) < 65000:
            # move FINGERPRINT / append TLV and re-fix the length only
            b = b[:-8] + tlv(rnd.choice([0x0025, 0x0006, 0x8028, 0x0008]), bytes(rnd.choice([0, 4, 20]))) + b[-8:]
            b[2:4] = struct.pack(">H", len(b) - 20)
        else:
            if len(b) > 20:
                cut = rnd.randrange(20, len(b))
                b = b[:cut] + bytes(rnd.randrange(256) for _ in range(rnd.choice([1, 2, 3, 4, 8]))) + b[cut:]
        out.append(("mut%04d_%s" % (i, name), bytes(b), key))
    return out


def gen(outdir):
    sp = specs()
    with open(outdir + "/specs.tsv", "w") as f, open(outdir + "/ref_wire.tsv", "w") as g:
        for label, mtype, tx, key, mode, attrs in sp:
            f.write("%s\t%04x\t%s\t%s\t%s\t%s\n" % (label, mtype, tx.hex(), key.hex(), mode, ";".join("%04x:%s" % (t, v.hex()) for t, v in attrs) + (";" if attrs else "")))
            g.write("%s\tW=%s\n" % (label, encode(mtype, tx, key, mode, attrs).hex()))
    vecs = [(l, bytes.fromhex(h), k) for l, h, k in RFC5769]
    vecs += [("valid_" + label, encode(mtype, tx, key, mode, attrs), key) for label, mtype, tx, key, mode, attrs in sp]
    vecs += attack_vectors(vecs)
    vecs += mutations(vecs, 10000)
    with open(outdir + "/corpus.tsv", "w") as f:
        for label, b, key in vecs:
            f.write("%s\t%s\t%s\n" % (label, b.hex(), key.hex()))
    print("specs=%d corpus=%d" % (len(sp), len(vecs)))


def main():
    if sys.argv[1] == "gen":
        gen(sys.argv[2])
    elif sys.argv[1] == "decode":
        out = []
        for line in open(sys.argv[2]):
            f = line.rstrip("\n").split("\t")
            out.append(f[0] + "\t" + decode_line(bytes.fromhex(f[1]), bytes.fromhex(f[2]) if len(f) > 2 else b""))
        sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
