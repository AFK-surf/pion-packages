"""Tiny DER builder used by the red-team corpus generator (no third-party deps).

Everything returns `bytes`. `tlv()` takes a raw tag byte (or bytes for high-tag forms)
so callers can deliberately build non-canonical encodings.
"""

import calendar


def enc_len(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def tlv(tag, content, length=None):
    tag = bytes([tag]) if isinstance(tag, int) else tag
    return tag + (enc_len(len(content)) if length is None else length) + content


def seq(*xs):
    return tlv(0x30, b"".join(xs))


def set_(*xs):
    return tlv(0x31, b"".join(xs))


def ctx(n, content, constructed=True):
    return tlv(0x80 | (0x20 if constructed else 0) | n, content)


def int_bytes(v):
    if v == 0:
        return b"\x00"
    n = (v.bit_length() + 8) // 8 if v > 0 else ((-v - 1).bit_length() + 8) // 8
    return v.to_bytes(n, "big", signed=True)


def integer(v):
    return tlv(0x02, int_bytes(v))


def boolean(v):
    return tlv(0x01, b"\xff" if v else b"\x00")


def null():
    return b"\x05\x00"


def oid_content(dotted):
    arcs = [int(x) for x in dotted.split(".")]
    out = bytearray()
    first = arcs[0] * 40 + arcs[1]
    for a in [first] + arcs[2:]:
        chunk = [a & 0x7F]
        a >>= 7
        while a:
            chunk.append(0x80 | (a & 0x7F))
            a >>= 7
        out += bytes(reversed(chunk))
    return bytes(out)


def oid(dotted):
    return tlv(0x06, oid_content(dotted))


def octet(b):
    return tlv(0x04, b)


def bitstring(b, unused=0):
    return tlv(0x03, bytes([unused]) + b)


def utf8(s):
    return tlv(0x0C, s.encode() if isinstance(s, str) else s)


def printable(s):
    return tlv(0x13, s.encode() if isinstance(s, str) else s)


def ia5(s):
    return tlv(0x16, s.encode() if isinstance(s, str) else s)


def utctime(s):
    return tlv(0x17, s.encode())


def gentime(s):
    return tlv(0x18, s.encode())


def unix(s):
    """'YYYYMMDDHHMMSS' -> unix seconds."""
    return calendar.timegm((int(s[0:4]), int(s[4:6]), int(s[6:8]), int(s[8:10]), int(s[10:12]), int(s[12:14])))


# ---------------------------------------------------------------------------
# Certificate builder
# ---------------------------------------------------------------------------

OID_ED25519 = "1.3.101.112"
OID_ECDSA_SHA256 = "1.2.840.10045.4.3.2"
OID_SHA256_RSA = "1.2.840.113549.1.1.11"
# Fixed Ed25519 public key (RFC 8032 test 1); parsers only check its length.
ED25519_PUB = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")


def name(cn="Pion RT", extra=()):
    rdns = [set_(seq(oid("2.5.4.6"), printable("US"))), set_(seq(oid("2.5.4.3"), utf8(cn)))]
    rdns += list(extra)
    return seq(*rdns)


def ed25519_spki():
    return seq(seq(oid(OID_ED25519)), bitstring(ED25519_PUB))


def ext(oid_s, value, critical=None):
    parts = [oid(oid_s)]
    if critical is not None:
        parts.append(boolean(critical))
    parts.append(octet(value))
    return seq(*parts)


def san(*names):
    return ext("2.5.29.17", seq(*names))


def dns(s):
    return tlv(0x82, s.encode() if isinstance(s, str) else s)


def ipaddr(b):
    return tlv(0x87, b)


def cert(
    *,
    version=2,
    version_raw=None,
    serial=0x1234,
    serial_raw=None,
    sig_alg=None,
    outer_sig_alg=None,
    issuer=None,
    subject=None,
    not_before=None,
    not_after=None,
    spki=None,
    exts=None,
    ext_block=None,
    tbs_tail=b"",
    tbs_override=None,
    signature=None,
    cert_tail=b"",
    outer_tail=b"",
):
    sig_alg = sig_alg if sig_alg is not None else seq(oid(OID_ED25519))
    outer_sig_alg = outer_sig_alg if outer_sig_alg is not None else sig_alg
    parts = []
    if version_raw is not None:
        parts.append(version_raw)
    elif version is not None:
        parts.append(ctx(0, integer(version)))
    parts.append(serial_raw if serial_raw is not None else integer(serial))
    parts.append(sig_alg)
    parts.append(issuer if issuer is not None else name("Pion RT CA"))
    parts.append(seq(not_before or utctime("260101000000Z"), not_after or utctime("361231235959Z")))
    parts.append(subject if subject is not None else name("leaf.example.com"))
    parts.append(spki if spki is not None else ed25519_spki())
    if ext_block is not None:
        parts.append(ext_block)
    elif exts is not None:
        parts.append(ctx(3, seq(*exts)))
    tbs = tbs_override if tbs_override is not None else seq(*parts, tbs_tail)
    sig = signature if signature is not None else bitstring(b"\x00" * 64)
    return tlv(0x30, tbs + outer_sig_alg + sig + cert_tail) + outer_tail


def default_exts(*names):
    names = names or (dns("leaf.example.com"),)
    return [
        ext("2.5.29.19", seq(), True),
        ext("2.5.29.15", bitstring(b"\x80", 7), True),
        san(*names),
    ]
