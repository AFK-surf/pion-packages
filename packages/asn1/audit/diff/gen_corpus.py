#!/usr/bin/env python3
"""Red-team corpus for packages/asn1 differential testing.

  gen_corpus.py <out_dir>

Writes <out_dir>/corpus.tsv with one vector per line: "<label>\t<kind>\t<hex>[\t<hex2>]".
Kinds: bool int64 uint64 bits octet null oid utf8 printable ia5 bmp utc gen tree
       x509 spki pkcs8 pem host
Deterministic (seeded) except for the OpenSSL-generated keys/certs, which are produced
fresh in <out_dir>/openssl (every oracle sees the same bytes).
"""

import base64
import os
import random
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from derlib import *  # noqa: E402,F403

RNG = random.Random(0xA5_1A_2026)
ROWS = []


def add(label, kind, data, extra=None):
    h = data.hex() if isinstance(data, (bytes, bytearray)) else data
    row = f"{label}\t{kind}\t{h}"
    if extra is not None:
        row += "\t" + (extra.hex() if isinstance(extra, (bytes, bytearray)) else extra)
    ROWS.append(row)


# ---------------------------------------------------------------------------
# 1. Typed primitive vectors (hand-written X.690 / Wycheproof style edge cases)
# ---------------------------------------------------------------------------

def typed_handwritten():
    H = bytes.fromhex
    v = {
        "bool": ["010100", "0101ff", "010101", "01017f", "010180", "0100", "01020000", "01810100", "2101ff",
                 "0101", "01", ""],
        "int64": ["020100", "02017f", "0202007f", "0202ff80", "020180", "0200", "02080000000000000000"[:0] + "0208" + "7fffffffffffffff",
                  "02088000000000000000"[:20], "0209008000000000000000", "0209ff7fffffffffffffff", "020900ffffffffffffffff",
                  "02810100", "028200017f", "0280", "2201ff", "02020000", "0202ffff", "020200ff", "0201ff"],
        "uint64": ["020100", "0209" + "00ffffffffffffffff", "0208ffffffffffffffff", "020900" + "80" + "00" * 7,
                   "020a0001" + "00" * 8, "0201ff", "0202007f", "020180"],
        "bits": ["030100", "030101", "030107", "030200ff", "030201fe", "030201ff", "030208ff", "030207800", "0302078000"[:8],
                 "03020780", "0303070080", "0303070100", "0300", "2303030100", "23800301000000", "030180",
                 "030400ffffff", "03810200ff"],
        "octet": ["0400", "040100", "0403616263", "2403040161", "2480040161 0000".replace(" ", ""), "04810161",
                  "0481800" + "0" * 0, "048180" + "00" * 128],
        "null": ["0500", "050100", "058100", "2500", "0580"],
        "oid": ["06032a0304", "0603550403", "0600", "0602807f", "060280", "0601ff", "06022a80", "0603813403",
                "06012a", "060100", "060127", "060128", "06014f", "060150", "06027f00"[:4] + "7f",
                "060b2a8648ce3d0401" + "8000", "060a2a" + "ffffffffffffffffff" + "7f",
                "060a2a" + "81ffffffffffffffff" + "7f", "060b2a" + "82808080808080808000",
                "060a2a" + "8fffffffff" + "ffffffff7f", "06092a" + "8180808080808080" + "00",
                "0603883703", "06048837" + "8100"[:4], "2603550403", "06810355" + "0403",
                # 2.25.<128-bit UUID> (ITU-T X.667)
                "0614" + "6981" + "e0a0c6d0e5bbd6f0dae9a2ab95fcc3b6c3cf18"[:34] + "05"],
        "utf8": ["0c00", "0c0161", "0c03e282ac", "0c02c0af", "0c03eda080", "0c04f4908080", "0c02c280", "0c0180",
                 "0c03efbfbf", "0c04f0908080", "0c03e08080", "0c0100", "0c05edb080e282ac", "2c03" + "0c0161"],
        "printable": ["1300", "130141", "13012a", "130126", "130140", "13015f", "130100", "13020a41", "130121",
                      "13012e", "1303612062", "1301ff", "13013a", "13013d", "13013f", "13012b"],
        "ia5": ["1600", "160141", "160100", "16017f", "160180", "1601ff", "16021b5b"],
        "bmp": ["1e00", "1e020041", "1e0100", "1e03004100", "1e02d800", "1e02dfff", "1e04d83dde00", "1e02fffe",
                "1e02feff", "1e020000", "1e0420ac0041"],
    }
    for kind, items in v.items():
        for i, hx in enumerate(items):
            hx = hx.replace(" ", "")
            if len(hx) % 2:
                hx = hx[:-1]
            add(f"hand.{kind}.{i}", kind, H(hx))
    # Times
    utc = ["991231235959Z", "000101000000Z", "491231235959Z", "500101000000Z", "240229000000Z", "230229000000Z",
           "000229000000Z", "991231235960Z", "991231236059Z", "991231245959Z", "991232235959Z", "991331235959Z",
           "990001000000Z", "991200000000Z", "9912312359Z", "991231235959", "991231235959+0000", "991231235959-0100",
           "991231235959.5Z", "99123123595 Z", " 91231235959Z", "991231235959z", "9912312359590Z", "+91231235959Z",
           "99-231235959Z", "991231235959Z\x00", "\x3999\x31231235959Z"[0:0] + "0a1231235959Z"]
    gen = ["20501231235959Z", "20491231235959Z", "19500101000000Z", "00000101000000Z", "99991231235959Z",
           "20240229000000Z", "21000229000000Z", "20000229000000Z", "19000229000000Z", "20161231235960Z",
           "20240101000000.5Z", "20240101000000.Z", "20240101000000.50Z", "20240101000000+0000",
           "20240101000000", "202401010000Z", "2024010100Z", "20240101000000-0800", "20240101000000z",
           "20241301000000Z", "20240132000000Z", "20240101240000Z", "20240101006000Z", "-2024010100000Z",
           "20240101000000ZZ", "2024010100000Z"]
    for i, s in enumerate(utc):
        add(f"hand.utc.{i}", "utc", utctime(s))
    for i, s in enumerate(gen):
        add(f"hand.gen.{i}", "gen", gentime(s))
    # Header-level malleability vectors applied to every kind's simplest valid value
    base = {"bool": "0101ff", "int64": "02017f", "uint64": "02017f", "bits": "03020780", "octet": "040161",
            "null": "0500", "oid": "0603550403", "utf8": "0c0161", "printable": "130141", "ia5": "160141",
            "bmp": "1e020041", "utc": utctime("991231235959Z").hex(), "gen": gentime("20240101000000Z").hex()}
    for kind, hx in base.items():
        b = H(hx)
        t, l, c = b[:1], b[1], b[2:]
        muts = {
            "indef": t + b"\x80" + c + b"\x00\x00",
            "len81": t + b"\x81" + bytes([l]) + c,
            "len82": t + b"\x82\x00" + bytes([l]) + c,
            "len84": t + b"\x84\x00\x00\x00" + bytes([l]) + c,
            "len85": t + b"\x85\x00\x00\x00\x00" + bytes([l]) + c,
            "len88": t + b"\x88" + b"\x00" * 7 + bytes([l]) + c,
            "lenff": t + b"\xff" + c,
            "constructed": bytes([t[0] | 0x20]) + bytes([l]) + c,
            "hightag": bytes([t[0] | 0x1F, t[0] & 0x1F]) + bytes([l]) + c,
            "hightag80": bytes([t[0] | 0x1F, 0x80, t[0] & 0x1F]) + bytes([l]) + c,
            "ctxclass": bytes([0x80 | t[0]]) + bytes([l]) + c,
            "trail1": b + b"\x00",
            "trail_tlv": b + b"\x05\x00",
            "short": b[:-1],
            "len_over": t + bytes([l + 1]) + c,
            "len_under": t + bytes([max(l - 1, 0)]) + c,
            "empty": b"",
        }
        for m, mb in muts.items():
            add(f"hdr.{kind}.{m}", kind, mb)


# ---------------------------------------------------------------------------
# 2. Random structural mutations of valid typed encodings (bulk differential)
# ---------------------------------------------------------------------------

def rand_valid(kind):
    r = RNG
    if kind == "bool":
        return boolean(r.random() < 0.5)
    if kind == "int64":
        return integer(r.choice([0, 1, -1, 127, 128, -128, -129, 2**63 - 1, -2**63, r.randint(-2**63, 2**63 - 1),
                                 r.randint(-300, 300)]))
    if kind == "uint64":
        return integer(r.choice([0, 1, 255, 256, 2**63, 2**64 - 1, r.randint(0, 2**64 - 1)]))
    if kind == "bits":
        n = r.randint(0, 6)
        data = bytes(r.randrange(256) for _ in range(n))
        if n == 0:
            return bitstring(b"", 0)
        u = r.randint(0, 7)
        data = data[:-1] + bytes([data[-1] & (0xFF << u) & 0xFF])
        return bitstring(data, u)
    if kind == "octet":
        return octet(bytes(r.randrange(256) for _ in range(r.randint(0, 10))))
    if kind == "null":
        return null()
    if kind == "oid":
        arcs = [r.choice([0, 1, 2])]
        arcs.append(r.randint(0, 39) if arcs[0] < 2 else r.choice([r.randint(0, 200), r.randint(0, 2**40)]))
        for _ in range(r.randint(0, 6)):
            arcs.append(r.choice([r.randint(0, 127), r.randint(128, 2**14), r.randint(0, 2**32), r.randint(0, 2**64 - 1)]))
        return oid(".".join(map(str, arcs)))
    if kind == "utf8":
        return utf8("".join(r.choice(["a", "Z", "é", "€", "𝄞", " ", "\u0000", "�"]) for _ in range(r.randint(0, 6))))
    if kind == "printable":
        return printable("".join(r.choice("AZaz09 '()+,-./:=?") for _ in range(r.randint(0, 8))))
    if kind == "ia5":
        return ia5(bytes(r.randrange(128) for _ in range(r.randint(0, 8))))
    if kind == "bmp":
        return tlv(0x1E, b"".join(r.choice([b"\x00A", b"\x20\xac", b"\x00\xe9", b"\xff\xfd"]) for _ in range(r.randint(0, 5))))
    if kind == "utc":
        y = r.randint(0, 99)
        return utctime(f"{y:02d}{r.randint(1,12):02d}{r.randint(1,28):02d}{r.randint(0,23):02d}{r.randint(0,59):02d}{r.randint(0,59):02d}Z")
    if kind == "gen":
        return gentime(f"{r.randint(1,9999):04d}{r.randint(1,12):02d}{r.randint(1,28):02d}{r.randint(0,23):02d}{r.randint(0,59):02d}{r.randint(0,59):02d}Z")
    raise ValueError(kind)


def mutate(b):
    r = RNG
    b = bytearray(b)
    op = r.randrange(9)
    if op == 0 and b:  # flip a random bit
        i = r.randrange(len(b))
        b[i] ^= 1 << r.randrange(8)
    elif op == 1 and b:  # replace a byte
        b[r.randrange(len(b))] = r.choice([0x00, 0x7F, 0x80, 0xFF, 0x30, 0x1F, r.randrange(256)])
    elif op == 2:  # insert a byte
        b.insert(r.randrange(len(b) + 1), r.choice([0x00, 0x80, 0xFF, 0x2E, r.randrange(256)]))
    elif op == 3 and b:  # delete a byte
        del b[r.randrange(len(b))]
    elif op == 4 and len(b) > 1:  # truncate
        b = b[: r.randrange(len(b))]
    elif op == 5 and len(b) >= 2:  # re-encode length in long form
        b = b[:1] + bytes([0x81, b[1]]) + b[2:] if b[1] < 0x80 else b
    elif op == 6 and b:  # toggle constructed bit on tag
        b[0] ^= 0x20
    elif op == 7 and len(b) >= 2:  # length +- 1
        b[1] = (b[1] + r.choice([-1, 1])) & 0xFF
    else:  # append garbage
        b += bytes([r.randrange(256)])
    return bytes(b)


def typed_mutations(per_kind=420):
    kinds = ["bool", "int64", "uint64", "bits", "octet", "null", "oid", "utf8", "printable", "ia5", "bmp", "utc", "gen"]
    for kind in kinds:
        for i in range(per_kind):
            v = rand_valid(kind)
            if i % 3 != 0:
                for _ in range(1 + RNG.randrange(2)):
                    v = mutate(v)
            add(f"mut.{kind}.{i}", kind, v)


# ---------------------------------------------------------------------------
# 3. Generic tree vectors
# ---------------------------------------------------------------------------

def tree_vectors(real_ders):
    H = bytes.fromhex
    hand = ["3000", "30020500", "3080050000000000", "31060201020201 01".replace(" ", ""), "310602010102 0102".replace(" ", ""),
            "a0030201 05".replace(" ", ""), "1f1f00", "1f2000", "3f2000", "1f8f0000", "1f8000", "df0000", "1f1e00",
            "bf8a3b00", "1f" + "ff" * 5 + "7f00", "1f87ffffff7f00", "0000", "300200 00", "30 03 020100 00".replace(" ", ""),
            "3003020100", "3004020100", "300402010000", "30810100", "3081803000" + "00" * 0, "2280", "2380",
            "10020500", "11020500", "6000", "e000", "ff00"]
    for i, hx in enumerate(hand):
        add(f"tree.hand.{i}", "tree", H(hx.replace(" ", "")))
    for i, d in enumerate(real_ders):
        add(f"tree.real.{i}", "tree", d)
        for j in range(60):
            m = d
            for _ in range(1 + RNG.randrange(3)):
                m = mutate_deep(m)
            add(f"tree.realmut.{i}.{j}", "tree", m)


def mutate_deep(b):
    """Mutate anywhere inside a large DER blob (not just the first header)."""
    r = RNG
    b = bytearray(b)
    if not b:
        return bytes(b)
    i = r.randrange(len(b))
    op = r.randrange(6)
    if op == 0:
        b[i] ^= 1 << r.randrange(8)
    elif op == 1:
        b[i] = r.choice([0x00, 0x80, 0xFF, 0x81, 0x30, 0x05])
    elif op == 2:
        b.insert(i, r.randrange(256))
    elif op == 3:
        del b[i]
    elif op == 4:
        b = b[:i]
    else:
        b += bytes([r.randrange(256)])
    return bytes(b)


# ---------------------------------------------------------------------------
# 4. X.509 structural attack vectors (built with derlib; dummy signatures)
# ---------------------------------------------------------------------------

def x509_vectors():
    E = default_exts
    alg_ed = seq(oid(OID_ED25519))
    alg_ec = seq(oid(OID_ECDSA_SHA256))
    vec = {
        "control_v3": cert(exts=E()),
        "control_v1": cert(version=None),
        "control_v1_no_ext": cert(version=None, exts=None),
        "explicit_v1_version": cert(version=0),
        "v2_with_unique_ids": cert(version=1, ext_block=ctx(1, b"\x00\xaa", False) + ctx(2, b"\x00\xbb", False)),
        "v1_with_extensions": cert(version=None, exts=E()),
        "v2_with_extensions": cert(version=1, exts=E()),
        "v1_with_issuer_uid": cert(version=None, ext_block=ctx(1, b"\x00\xaa", False)),
        "version_v4": cert(version=3, exts=E()),
        "version_neg1": cert(version=-1),
        "version_nonminimal": cert(version_raw=ctx(0, tlv(0x02, b"\x00\x02")), exts=E()),
        "version_trailing": cert(version_raw=ctx(0, integer(2) + b"\x05\x00"), exts=E()),
        "version_implicit_tag": cert(version_raw=tlv(0x80, b"\x02"), exts=E()),
        "sigalg_mismatch": cert(exts=E(), outer_sig_alg=alg_ec),
        "sigalg_params_mismatch": cert(exts=E(), outer_sig_alg=seq(oid(OID_ED25519), null())),
        "sigalg_trailing": cert(exts=E(), sig_alg=seq(oid(OID_ED25519), null(), null())),
        "serial_zero": cert(serial=0, exts=E()),
        "serial_negative": cert(serial=-5, exts=E()),
        "serial_21_bytes": cert(serial=2**160, exts=E()),
        "serial_20_bytes": cert(serial=2**159 - 1, exts=E()),
        "serial_nonminimal": cert(serial_raw=tlv(0x02, b"\x00\x01"), exts=E()),
        "serial_empty": cert(serial_raw=tlv(0x02, b""), exts=E()),
        "empty_issuer": cert(issuer=seq(), exts=E()),
        "empty_subject_with_san": cert(subject=seq(), exts=E()),
        "empty_rdn_set": cert(subject=seq(set_()), exts=E()),
        "validity_inverted": cert(not_before=utctime("361231235959Z"), not_after=utctime("260101000000Z"), exts=E()),
        "validity_gen_before_2050": cert(not_before=gentime("20260101000000Z"), exts=E()),
        "validity_utc_after_2050": cert(not_after=utctime("500101000000Z"), exts=E()),
        "validity_gen_2050": cert(not_after=gentime("20500101000000Z"), exts=E()),
        "validity_gen_fraction": cert(not_after=gentime("20360101000000.5Z"), exts=E()),
        "validity_utc_no_seconds": cert(not_after=utctime("3601010000Z"), exts=E()),
        "validity_utc_offset": cert(not_after=utctime("360101000000+0000"), exts=E()),
        "validity_leap_feb29_2028": cert(not_after=utctime("280229000000Z"), exts=E()),
        "validity_nonleap_feb29": cert(not_after=utctime("270229000000Z"), exts=E()),
        "validity_leap_second": cert(not_after=utctime("361231235960Z"), exts=E()),
        "validity_trailing": cert(exts=E(), not_after=utctime("361231235959Z") + null()),
        "trailing_after_cert": cert(exts=E(), outer_tail=b"\x00"),
        "trailing_inside_cert": cert(exts=E(), cert_tail=b"\x05\x00"),
        "trailing_inside_tbs": cert(exts=E(), tbs_tail=b"\x05\x00"),
        "trailing_ctx4_inside_tbs": cert(exts=E(), tbs_tail=ctx(4, b"")),
        "sig_unused_bits": cert(exts=E(), signature=bitstring(b"\x00" * 63 + b"\x80", 7)),
        "dup_ext": cert(exts=E() + [ext("2.5.29.15", bitstring(b"\x80", 7))]),
        "two_ext_blocks": cert(ext_block=ctx(3, seq(*E()[:2])) + ctx(3, seq(E()[2]))),
        "uid_after_extensions": cert(ext_block=ctx(3, seq(*E())) + ctx(1, b"\x00\xaa", False)),
        "dup_issuer_uid": cert(ext_block=ctx(1, b"\x00\xaa", False) + ctx(1, b"\x00\xaa", False) + ctx(3, seq(*E()))),
        "uid_constructed": cert(ext_block=ctx(1, b"\x03\x01\x00", True) + ctx(3, seq(*E()))),
        "empty_extensions_seq": cert(exts=[]),
        "ext_critical_false_explicit": cert(exts=E() + [ext("1.2.3.4", b"\x05\x00", False)]),
        "ext_critical_bad_bool": cert(exts=E() + [seq(oid("1.2.3.4"), tlv(0x01, b"\x01"), octet(b"\x05\x00"))]),
        "unknown_critical_ext": cert(exts=E() + [ext("1.2.3.4.5", b"\x05\x00", True)]),
        "ext_value_trailing": cert(exts=[ext("2.5.29.19", seq() + b"\x00", True)] + E()[1:]),
        "bc_ca_false_explicit": cert(exts=[ext("2.5.29.19", seq(boolean(False)), True)] + E()[1:]),
        "bc_pathlen_without_ca": cert(exts=[ext("2.5.29.19", seq(integer(3)), True)] + E()[1:]),
        "bc_pathlen_negative": cert(exts=[ext("2.5.29.19", seq(boolean(True), integer(-1)), True)] + E()[1:]),
        "bc_pathlen_huge": cert(exts=[ext("2.5.29.19", seq(boolean(True), integer(2**40)), True)] + E()[1:]),
        "bc_ca_bad_bool": cert(exts=[ext("2.5.29.19", seq(tlv(0x01, b"\x01")), True)] + E()[1:]),
        "bc_order_swapped": cert(exts=[ext("2.5.29.19", seq(integer(1), boolean(True)), True)] + E()[1:]),
        "ku_empty": cert(exts=[E()[0], ext("2.5.29.15", bitstring(b""), True), E()[2]]),
        "ku_10_bits": cert(exts=[E()[0], ext("2.5.29.15", bitstring(b"\x80\x40", 6), True), E()[2]]),
        "ku_trailing_zero_byte": cert(exts=[E()[0], ext("2.5.29.15", bitstring(b"\x80\x00", 0), True), E()[2]]),
        "ku_nonzero_padding": cert(exts=[E()[0], ext("2.5.29.15", bitstring(b"\x81", 7), True), E()[2]]),
        "san_empty_seq": cert(exts=E()[:2] + [ext("2.5.29.17", seq())]),
        "san_nul_dns": cert(exts=E(dns(b"good.example.com\x00.evil.com"))),
        "san_nonascii_dns": cert(exts=E(dns(b"b\xc3\xbccher.example"))),
        "san_idn_punycode": cert(exts=E(dns("xn--bcher-kva.example"))),
        "san_ip_5_bytes": cert(exts=E(ipaddr(b"\x01\x02\x03\x04\x05"))),
        "san_ip_0_bytes": cert(exts=E(ipaddr(b""))),
        "san_ip_8_bytes_constraint": cert(exts=E(ipaddr(b"\x0a\x00\x00\x00\xff\x00\x00\x00"))),
        "san_unknown_tag": cert(exts=E(tlv(0x89, b"abc"))),
        "san_universal_tag": cert(exts=E(ia5("leaf.example.com"))),
        "san_dns_constructed": cert(exts=E(tlv(0xA2, ia5("leaf.example.com")))),
        "san_uri_nonascii": cert(exts=E(tlv(0x86, b"https://\xff\xfe/"))),
        "san_email_nonascii": cert(exts=E(tlv(0x81, b"a@\xc3\xa9.example"))),
        "san_uri_invalid_utf8": cert(exts=E(tlv(0x86, b"\xc0\xaf"))),
        "san_email_invalid_utf8": cert(exts=E(tlv(0x81, b"\xed\xa0\x80"))),
        "san_dirname": cert(exts=E(ctx(4, name("x")))),
        "san_othername": cert(exts=E(ctx(0, oid("1.3.6.1.4.1.311.20.2.3") + ctx(0, utf8("u@x"))))),
        "san_trailing_after_seq": cert(exts=E()[:2] + [ext("2.5.29.17", seq(dns("a.example.com")) + b"\x00")]),
        "eku_empty": cert(exts=E() + [ext("2.5.29.37", seq())]),
        "eku_uuid_oid": cert(exts=E() + [ext("2.5.29.37", seq(oid("2.25.329800735698586629295641978511506172918")))]),
        "ext_uuid_oid": cert(exts=E() + [ext("2.25.329800735698586629295641978511506172918", b"\x05\x00")]),
        "dn_uuid_oid": cert(subject=name("x", [set_(seq(oid("2.25.329800735698586629295641978511506172918"), utf8("v")))]), exts=E()),
        "dn_printable_asterisk": cert(subject=seq(set_(seq(oid("2.5.4.3"), printable("*.example.com")))), exts=E()),
        "dn_printable_ampersand": cert(subject=seq(set_(seq(oid("2.5.4.10"), printable("AT&T")))), exts=E()),
        "dn_printable_underscore": cert(subject=seq(set_(seq(oid("2.5.4.3"), printable("a_b")))), exts=E()),
        "dn_numeric_string": cert(subject=seq(set_(seq(oid("2.5.4.5"), tlv(0x12, b"12345")))), exts=E()),
        "dn_universal_string": cert(subject=seq(set_(seq(oid("2.5.4.3"), tlv(0x1C, b"\x00\x00\x00A")))), exts=E()),
        "dn_t61_latin1": cert(subject=seq(set_(seq(oid("2.5.4.3"), tlv(0x14, b"caf\xe9")))), exts=E()),
        "dn_utf8_nul": cert(subject=seq(set_(seq(oid("2.5.4.3"), utf8(b"a\x00b")))), exts=E()),
        "dn_utf8_overlong": cert(subject=seq(set_(seq(oid("2.5.4.3"), utf8(b"\xc0\xaf")))), exts=E()),
        "dn_bmp_odd": cert(subject=seq(set_(seq(oid("2.5.4.3"), tlv(0x1E, b"\x00A\x00")))), exts=E()),
        "dn_value_integer": cert(subject=seq(set_(seq(oid("2.5.4.3"), integer(5)))), exts=E()),
        "dn_multi_valued_unsorted": cert(subject=seq(set_(seq(oid("2.5.4.6"), printable("US")), seq(oid("2.5.4.3"), utf8("a")))), exts=E()),
        "dn_atv_trailing": cert(subject=seq(set_(seq(oid("2.5.4.3"), utf8("a"), null()))), exts=E()),
        "spki_trailing": cert(spki=seq(seq(oid(OID_ED25519)), bitstring(ED25519_PUB), null()), exts=E()),
        "spki_ed25519_params_null": cert(spki=seq(seq(oid(OID_ED25519), null()), bitstring(ED25519_PUB)), exts=E()),
        "spki_ed25519_short_key": cert(spki=seq(seq(oid(OID_ED25519)), bitstring(ED25519_PUB[:31])), exts=E()),
        "spki_bitstring_unused": cert(spki=seq(seq(oid(OID_ED25519)), bitstring(ED25519_PUB[:31] + b"\x00", 1)), exts=E()),
        "aki_universal_child": cert(exts=E() + [ext("2.5.29.35", seq(null()))]),
        "aki_dup_keyid": cert(exts=E() + [ext("2.5.29.35", seq(tlv(0x80, b"\x01"), tlv(0x80, b"\x02")))]),
        "aki_trailing": cert(exts=E() + [ext("2.5.29.35", seq(tlv(0x80, b"\x01")) + b"\x00")]),
        "ski_not_octet": cert(exts=E() + [ext("2.5.29.14", integer(1))]),
        "tbs_indefinite": None,
        "cert_nonminimal_len": None,
        "high_tag_in_tbs_tail": cert(exts=E(), tbs_tail=b"\x9f\x1f\x00"),
        "bool_in_tbs_tail": cert(exts=E(), tbs_tail=boolean(True)),
    }
    good = cert(exts=E())
    # Re-encode the outer SEQUENCE header non-minimally (0x30 0x82 <len> -> 0x30 0x83 00 <len>)
    hdr_len = good[1] & 0x7F
    content = good[2 + hdr_len:]
    vec["cert_nonminimal_len"] = b"\x30\x83" + len(content).to_bytes(3, "big") + content
    # TBS with indefinite length
    tbs_start = 2 + hdr_len
    tbs_hl = good[tbs_start + 1] & 0x7F if good[tbs_start + 1] & 0x80 else 0
    tbs_content_start = tbs_start + 2 + tbs_hl
    tbs_len = int.from_bytes(good[tbs_start + 2: tbs_content_start], "big") if tbs_hl else good[tbs_start + 1]
    tbs_content = good[tbs_content_start: tbs_content_start + tbs_len]
    rest = good[tbs_content_start + tbs_len:]
    vec["tbs_indefinite"] = tlv(0x30, b"\x30\x80" + tbs_content + b"\x00\x00" + rest)
    for k, v in vec.items():
        add(f"x509.{k}", "x509", v)
    return good


def x509_mutations(real_ders):
    for i, d in enumerate(real_ders):
        add(f"x509.real.{i}", "x509", d)
        for j in range(120):
            m = d
            for _ in range(1 + RNG.randrange(2)):
                m = mutate_deep(m)
            add(f"x509.realmut.{i}.{j}", "x509", m)


# ---------------------------------------------------------------------------
# 5. Hostname / IP verification vectors
# ---------------------------------------------------------------------------

def host_vectors():
    ip = lambda s: ipaddr(__import__("ipaddress").ip_address(s).packed)  # noqa: E731
    sets = {
        "std": [dns("example.com"), dns("*.example.com"), dns("API.Example.ORG")],
        "deep": [dns("*.a.example.com")],
        "ips": [ip("192.0.2.1"), ip("::1"), ip("2001:db8::1"), ip("10.0.0.1")],
        # Go 1.27 refuses to parse this one ("SAN iPAddress contains IPv4-mapped IPv6 address")
        "mapped": [ip("::ffff:198.51.100.7")],
        "ip_in_dns": [dns("192.0.2.7"), dns("::1"), dns("010.0.0.1"), dns("[::1]"), dns("fe80::1%eth0")],
        "cn_only": None,
        "partial": [dns("f*.example.com"), dns("*o.example.net"), dns("a*b.example.org"), dns("*.*.example.io")],
        "idn": [dns("xn--*.example.com"), dns("*.xn--bcher-kva.example"), dns("xn--bcher-kva.example")],
        "tld": [dns("*.com"), dns("*"), dns("*."), dns("*.co.uk"), dns("*.local")],
        "dots": [dns("trailing.example.com."), dns("*..example.net"), dns("a..example.net"), dns(".lead.example")],
        "weird": [dns("a b.example.com"), dns("_srv.example.com"), dns("*.wild.example"), dns("UPPER.EXAMPLE.COM")],
        "empty": [dns("")],
    }
    hosts = ["example.com", "EXAMPLE.COM", "example.com.", "www.example.com", "WWW.Example.Com", "a.b.example.com",
             ".example.com", "*.example.com", "x*.example.com", "a b.example.com", "foo.example.com", "fo.example.com",
             "o.example.net", "fooo.example.net", "ab.example.org", "axb.example.org", "x.y.example.io", "x.example.io",
             "xn--abc.example.com", "a.xn--bcher-kva.example", "xn--bcher-kva.example", "co.uk", "x.co.uk", "com",
             "x.com", "x.local", "trailing.example.com", "trailing.example.com.", "a..example.net", "x..example.net",
             "lead.example", ".lead.example", "_srv.example.com", "x.wild.example", "upper.example.com",
             "api.example.org", "API.EXAMPLE.ORG.", "example.com\x00.evil", "exa\x00mple.com", "example.com\n",
             "example.com:443", "example.com/", "x.a.example.com", "y.x.a.example.com", "a.example.com",
             "192.0.2.1", "192.0.2.1.", "192.000.002.001", "0300.0.2.1", "3221225985", "0xc0.0.2.1", "192.0.2.7",
             "010.0.0.1", "10.0.0.1", "10.0.0.01", "::1", "[::1]", "0:0:0:0:0:0:0:1", "::0:1", "::01", "::001",
             "0000:0000:0000:0000:0000:0000:0000:0001", "::1%eth0", "fe80::1%eth0", "[::1]:443", "2001:DB8::1",
             "2001:db8:0:0:0:0:0:1", "2001:db8::0:1", "::ffff:198.51.100.7", "::FFFF:C633:6407", "198.51.100.7",
             "::ffff:192.0.2.1", "::ffff:c000:201", "::192.0.2.1", "1::", "::", "1:2:3:4:5:6:7::", ":::1", "1:::2",
             "1::2::3", "2001:db8::1::", "[192.0.2.1]", "[2001:db8::1]", "", " ", "*", "..", "."]
    out = []
    for sname, names in sets.items():
        if names is None:
            c = cert(subject=name("example.com"), exts=[ext("2.5.29.19", seq(), True)])
        else:
            c = cert(exts=[ext("2.5.29.19", seq(), True), san(*names)])
        add(f"x509.hostcert.{sname}", "x509", c)
        for i, h in enumerate(hosts):
            add(f"host.{sname}.{i}", "host", c, h.encode())
            out.append(h)
    return len(sets) * len(hosts)


# ---------------------------------------------------------------------------
# 6. PEM vectors
# ---------------------------------------------------------------------------

def pem_vectors(der):
    b64 = base64.b64encode(der).decode()
    lines = "\n".join(b64[i:i + 64] for i in range(0, len(b64), 64))
    good = f"-----BEGIN CERTIFICATE-----\n{lines}\n-----END CERTIFICATE-----\n"
    small = base64.b64encode(b"\x30\x03\x02\x01\x05").decode()  # "MAMCAQU="
    v = {
        "control": good,
        "crlf": good.replace("\n", "\r\n"),
        "cr_only": good.replace("\n", "\r"),
        "no_trailing_newline": good.rstrip("\n"),
        "preamble": "Subject: x\nIssuer: y\n" + good,
        "begin_trailing_space": good.replace("CERTIFICATE-----\n", "CERTIFICATE----- \n", 1),
        "begin_leading_space": " " + good,
        "begin_garbage_after": good.replace("CERTIFICATE-----\n", "CERTIFICATE-----garbage\n", 1),
        "begin_inline_body": f"-----BEGIN CERTIFICATE-----{b64}\n-----END CERTIFICATE-----\n",
        "end_garbage_after": good.replace("-----END CERTIFICATE-----", "-----END CERTIFICATE-----junk"),
        "label_mismatch": good.replace("END CERTIFICATE", "END PRIVATE KEY"),
        "label_lowercase_end": good.replace("END CERTIFICATE", "END certificate"),
        "unclosed": good.split("-----END")[0],
        "nested_begin": good.replace(lines, lines + "\n-----BEGIN CERTIFICATE-----"),
        "rfc1421_headers": good.replace("-----\n", "-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n\n", 1),
        "b64_space_inside": good.replace(lines[:8], lines[:4] + " " + lines[4:8], 1),
        "b64_tab_inside": good.replace(lines[:8], lines[:4] + "\t" + lines[4:8], 1),
        "b64_illegal_char": good.replace(lines[:4], lines[:3] + "!", 1),
        "b64_urlsafe": good.replace("+", "-").replace("/", "_"),
        "b64_missing_padding": f"-----BEGIN X-----\n{small.rstrip('=')}\n-----END X-----\n",
        "b64_extra_padding": f"-----BEGIN X-----\n{small}=\n-----END X-----\n",
        "b64_padding_middle": f"-----BEGIN X-----\nMA==MCAQU=\n-----END X-----\n",
        "b64_nonzero_tail_bits": f"-----BEGIN X-----\nMAMCAQV=\n-----END X-----\n",
        "b64_nonzero_tail_bits2": f"-----BEGIN X-----\nMAMCAQW=\n-----END X-----\n",
        "b64_long_line": f"-----BEGIN CERTIFICATE-----\n{b64}\n-----END CERTIFICATE-----\n",
        "empty_body": "-----BEGIN X-----\n-----END X-----\n",
        "empty_label": f"-----BEGIN -----\n{small}\n-----END -----\n",
        "label_with_space": f"-----BEGIN X509 CRL-----\n{small}\n-----END X509 CRL-----\n",
        "label_double_space": f"-----BEGIN X  Y-----\n{small}\n-----END X  Y-----\n",
        "label_trailing_hyphen": f"-----BEGIN X------\n{small}\n-----END X------\n",
        "label_nonascii": f"-----BEGIN Xé-----\n{small}\n-----END Xé-----\n",
        "four_dashes": f"----BEGIN X----\n{small}\n----END X----\n",
        "two_blocks": good + good,
        "trailing_text": good + "trailing text\n",
        "nul_in_body": good.replace(lines[:4], lines[:4] + "\x00", 1),
        "blank_lines_in_body": good.replace("\n", "\n\n", 3),
    }
    for k, s in v.items():
        add(f"pem.{k}", "pem", s.encode())


# ---------------------------------------------------------------------------
# 7. SPKI / PKCS#8 (real OpenSSL keys + structural attacks)
# ---------------------------------------------------------------------------

def openssl(args, cwd):
    return subprocess.run(["openssl"] + args, cwd=cwd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def keys_and_certs(outdir):
    d = os.path.join(outdir, "openssl")
    os.makedirs(d, exist_ok=True)
    algs = {
        "rsa2048": ["-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"],
        "rsa4096": ["-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:4096"],
        "p256": ["-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"],
        "p384": ["-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-384"],
        "p521": ["-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-521"],
        "ed25519": ["-algorithm", "ED25519"],
        "x25519": ["-algorithm", "X25519"],
    }
    spkis, pk8s, certs = {}, {}, {}
    for a, args in algs.items():
        key = f"{a}.key"
        if not os.path.exists(os.path.join(d, key)):
            openssl(["genpkey"] + args + ["-out", key], d)
        pk8s[a] = openssl(["pkcs8", "-topk8", "-nocrypt", "-in", key, "-outform", "DER"], d)
        spkis[a] = openssl(["pkey", "-in", key, "-pubout", "-outform", "DER"], d)
    # Self-signed / CA-signed certs with SANs (x25519 cannot sign: issued by the ed25519 key)
    cnf = os.path.join(d, "ext.cnf")
    with open(cnf, "w") as f:
        f.write("[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nC=US\nO=Pion RT\nCN=rt.example.com\n"
                "[v3]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n"
                "extendedKeyUsage=serverAuth\nsubjectAltName=DNS:rt.example.com,DNS:*.rt.example.com,IP:192.0.2.9,IP:2001:db8::9,email:a@rt.example.com,URI:https://rt.example.com/\n"
                "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n"
                "certificatePolicies=1.2.3.4,2.25.329800735698586629295641978511506172918\n")
    for a in ["rsa2048", "rsa4096", "p256", "p384", "p521", "ed25519"]:
        pem = os.path.join(d, f"{a}.crt")
        if not os.path.exists(pem):
            openssl(["req", "-x509", "-new", "-key", f"{a}.key", "-days", "3650", "-set_serial", "0x4a6f", "-config", cnf,
                     "-extensions", "v3", "-out", pem], d)
        certs[a] = openssl(["x509", "-in", pem, "-outform", "DER"], d)
    xpem = os.path.join(d, "x25519.crt")
    if not os.path.exists(xpem):
        openssl(["x509", "-new", "-force_pubkey", "x25519.key", "-key", "ed25519.key", "-subj", "/CN=x25519.example",
                 "-days", "365", "-extfile", cnf, "-extensions", "v3", "-out", xpem], d)
    certs["x25519"] = openssl(["x509", "-in", xpem, "-outform", "DER"], d)
    # v1 certificate (no extensions)
    v1 = os.path.join(d, "v1.crt")
    if not os.path.exists(v1):
        openssl(["x509", "-new", "-key", "p256.key", "-subj", "/CN=v1.example", "-days", "365", "-out", v1], d)
        # OpenSSL 3 always emits v3; keep it anyway as an extra real cert.
    certs["v1"] = openssl(["x509", "-in", v1, "-outform", "DER"], d)
    return spkis, pk8s, certs


def spki_pkcs8_vectors(spkis, pk8s):
    for a, b in spkis.items():
        add(f"spki.real.{a}", "spki", b)
        add(f"spki.trail1.{a}", "spki", b + b"\x00")
        add(f"spki.inner_trail.{a}", "spki", tlv(0x30, b[2 + (b[1] & 0x7F if b[1] & 0x80 else 0):] + b"\x05\x00"))
        for j in range(40):
            add(f"spki.mut.{a}.{j}", "spki", mutate_deep(b))
    for a, b in pk8s.items():
        add(f"pkcs8.real.{a}", "pkcs8", b)
        add(f"pkcs8.trail1.{a}", "pkcs8", b + b"\x00")
        hl = b[1] & 0x7F if b[1] & 0x80 else 0
        inner = b[2 + hl:]
        add(f"pkcs8.inner_trail_null.{a}", "pkcs8", tlv(0x30, inner + b"\x05\x00"))
        add(f"pkcs8.v1_with_pubkey.{a}", "pkcs8", tlv(0x30, inner + ctx(1, b"\x00" + b"\x01" * 32, False)))
        v2 = b"\x02\x01\x01" + inner[3:]
        add(f"pkcs8.v2_with_pubkey.{a}", "pkcs8", tlv(0x30, v2 + ctx(1, b"\x00" + b"\x01" * 32, False)))
        add(f"pkcs8.v2_attrs_pubkey.{a}", "pkcs8", tlv(0x30, v2 + ctx(0, seq(oid("1.2.840.113549.1.9.14"), set_(seq()))) + ctx(1, b"\x00" + b"\x01" * 32, False)))
        add(f"pkcs8.v2_garbage_tail.{a}", "pkcs8", tlv(0x30, v2 + ctx(1, b"\x00\x01", False) + b"\x05\x00"))
        add(f"pkcs8.version2.{a}", "pkcs8", tlv(0x30, b"\x02\x01\x02" + inner[3:]))
        add(f"pkcs8.version_neg.{a}", "pkcs8", tlv(0x30, b"\x02\x01\xff" + inner[3:]))
        for j in range(40):
            add(f"pkcs8.mut.{a}.{j}", "pkcs8", mutate_deep(b))
    # Hand-built: Ed25519 with params, RSA without NULL
    ed = spkis["ed25519"]
    add("spki.ed25519_with_null_params", "spki", seq(seq(oid(OID_ED25519), null()), bitstring(ed[-32:])))
    add("spki.ed25519_unused_bits", "spki", seq(seq(oid(OID_ED25519)), bitstring(ed[-32:-1] + b"\x00", 1)))
    add("spki.alg_trailing", "spki", seq(seq(oid(OID_ED25519), null(), null()), bitstring(ed[-32:])))
    add("spki.empty_alg", "spki", seq(seq(), bitstring(ed[-32:])))


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    spkis, pk8s, certs = keys_and_certs(out)
    typed_handwritten()
    typed_mutations()
    good = x509_vectors()
    real = [certs[k] for k in sorted(certs)]
    tree_vectors(real[:4] + [good])
    x509_mutations(real)
    nhost = host_vectors()
    pem_vectors(certs["p256"])
    spki_pkcs8_vectors(spkis, pk8s)
    with open(os.path.join(out, "corpus.tsv"), "w") as f:
        f.write("\n".join(ROWS) + "\n")
    with open(os.path.join(out, "real_certs.derbin"), "wb") as f:
        for k in sorted(certs):
            f.write(len(certs[k]).to_bytes(4, "big") + certs[k])
    kinds = {}
    for r in ROWS:
        k = r.split("\t")[1]
        kinds[k] = kinds.get(k, 0) + 1
    print(f"wrote {len(ROWS)} vectors ({nhost} hostname) -> {out}/corpus.tsv  " +
          " ".join(f"{k}={v}" for k, v in sorted(kinds.items())))


if __name__ == "__main__":
    main()
