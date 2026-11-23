#!/usr/bin/env python3
"""RT-mqtt deterministic adversarial / differential vector generator.

Writes two files into OUT_DIR:
  vectors.bin  : repeated records  [ver:u8 (4|5)] [len:u32 BE] [packet bytes]
  labels.tsv   : id \t ver \t family \t expect \t note \t hex

`expect` is the OASIS oracle label for a *receiver* decoding the single packet:
  accept  - well-formed, the spec requires it to be accepted
  reject  - the spec says Malformed Packet / Protocol Error (MUST-level)
  strict  - outside the value set the spec defines (sender MUST), receiver
            behaviour not spelled out; rejecting is the conservative reading
  either  - MAY / SHOULD / implementation limit: both outcomes conform
Every vector is fed to Pion, Go paho.golang/packets v0.23.0 (v5 only) and
Rust rumqttc 0.25.1 (v4 + v5) by run_audit.sh; compare.py joins the verdicts.
"""

import os
import random
import struct
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/rt-mqtt-diff"
RNG = random.Random(0x5EED_3117)
VEC = []  # (ver, family, expect, note, bytes)


def vbi(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            b |= 0x80
        out.append(b)
        if not n:
            return bytes(out)


def s(x):
    b = x if isinstance(x, (bytes, bytearray)) else x.encode()
    return struct.pack("!H", len(b)) + bytes(b)


def u16(n):
    return struct.pack("!H", n)


def u32(n):
    return struct.pack("!I", n)


def props(raw=b""):
    return vbi(len(raw)) + raw


def pkt(h, body):
    return bytes([h]) + vbi(len(body)) + body


def add(ver, fam, exp, note, b):
    VEC.append((ver, fam, exp, note, bytes(b)))


# ---------------------------------------------------------------- bodies
def connect_body(ver, flags=0x02, cid="c", will=None, user=None, pw=None,
                 cprops=b"", wprops=b"", name="MQTT", level=None, ka=60):
    lv = level if level is not None else (5 if ver == 5 else 4)
    body = s(name) + bytes([lv, flags]) + u16(ka)
    if ver == 5:
        body += props(cprops)
    body += s(cid)
    if will is not None:
        if ver == 5:
            body += props(wprops)
        body += s(will[0]) + s(will[1])
    if user is not None:
        body += s(user)
    if pw is not None:
        body += s(pw)
    return body


def publish(ver, flags=0x02, topic="a/b", pid=1, pr=b"", payload=b"x"):
    qos = (flags >> 1) & 3
    body = s(topic)
    if qos > 0:
        body += u16(pid)
    if ver == 5:
        body += props(pr)
    return pkt(0x30 | flags, body + payload)


def minimal_body(ver, t, flags):
    if t == 1:
        return connect_body(ver)
    if t == 2:
        return b"\x00\x00" + (props() if ver == 5 else b"")
    if t == 3:
        qos = (flags >> 1) & 3
        b = s("a/b") + (u16(1) if qos else b"")
        return b + (props() if ver == 5 else b"") + b"x"
    if t in (4, 5, 6, 7):
        return u16(1)
    if t == 8:
        return u16(1) + (props() if ver == 5 else b"") + s("a/b") + b"\x01"
    if t == 9:
        return u16(1) + (props() if ver == 5 else b"") + b"\x00"
    if t == 10:
        return u16(1) + (props() if ver == 5 else b"") + s("a/b")
    if t == 11:
        return u16(1) + (props() + b"\x00" if ver == 5 else b"")
    return b""  # 0, 12, 13, 14, 15


REQUIRED_FLAGS = {1: 0, 2: 0, 4: 0, 5: 0, 6: 2, 7: 0, 8: 2, 9: 0, 10: 2,
                  11: 0, 12: 0, 13: 0, 14: 0, 15: 0}

# ---------------------------------------------------------------- A. fixed header
for ver in (4, 5):
    for t in range(16):
        for fl in range(16):
            body = minimal_body(ver, t, fl)
            if t == 0 or (t == 15 and ver == 4):
                exp, note = "reject", "reserved packet type"
            elif t == 3:
                qos, dup = (fl >> 1) & 3, fl & 8
                if qos == 3:
                    exp, note = "reject", "PUBLISH QoS=3 [MQTT-3.3.1-4]"
                elif qos == 0 and dup:
                    exp, note = "either", "PUBLISH QoS0 DUP=1 (sender MUST NOT)"
                else:
                    exp, note = "accept", "PUBLISH flags"
            else:
                exp = "accept" if fl == REQUIRED_FLAGS[t] else "reject"
                note = "type %d flags %x [MQTT-2.1.3-1]" % (t, fl)
            add(ver, "A.fixed_header", exp, note, pkt((t << 4) | fl, body))

# ---------------------------------------------------------------- B. remaining length
for ver in (4, 5):
    # canonical boundaries on PUBLISH QoS0 payload length
    for plen in (0, 1, 120, 121, 122, 16380, 16384):
        add(ver, "B.vbi", "accept", "PUBLISH rem_len boundary payload=%d" % plen,
            publish(ver, 0, "t", payload=b"p" * plen))
    # non canonical encodings of small values
    for enc, note in ((b"\x82\x00", "2B for 2"), (b"\x80\x80\x00", "3B for 0"),
                      (b"\x80\x80\x80\x00", "4B for 0"), (b"\x80\x00", "2B for 0")):
        add(ver, "B.vbi", "either", "non-canonical VBI " + note, b"\xc0" + enc)
    add(ver, "B.vbi", "reject", "5-byte VBI", b"\x30\xff\xff\xff\xff\x01")
    add(ver, "B.vbi", "either", "declared 268435455 (5B header only)",
        b"\x30\xff\xff\xff\x7f")
    add(ver, "B.vbi", "either", "declared 256MiB, 16B present",
        b"\x30\x80\x80\x80\x7f" + b"\x00\x01a" + b"x" * 13)
    # remaining length mismatch: declared rem shorter/longer than structure
    for t in (2, 4, 5, 6, 7, 9, 11, 12, 13, 14):
        fl = REQUIRED_FLAGS[t]
        body = minimal_body(ver, t, fl)
        for extra in (1, 2, 3):
            if ver == 5 and t in (4, 5, 6, 7, 14):
                exp = "accept" if extra <= 2 else "reject"  # rc / rc+proplen0 / trailing
            elif t in (9,) or (ver == 5 and t == 11):
                exp = "accept"  # extra zero bytes are additional reason codes
            else:
                exp = "reject"
            add(ver, "B.rem_mismatch", exp, "type %d rem_len +%d (zero bytes)" % (t, extra),
                pkt((t << 4) | fl, body + bytes(extra)))
        if len(body) >= 1:
            add(ver, "B.rem_mismatch", "reject", "type %d rem_len -1 truncated structure" % t,
                pkt((t << 4) | fl, body[:-1]))
    # truncated stream (declared > present): incomplete
    for t in (1, 3, 4, 8):
        full = pkt((t << 4) | REQUIRED_FLAGS.get(t, 2 if t == 3 else 0), minimal_body(ver, t, 2))
        for cut in (1, 2, len(full) - 1):
            add(ver, "B.truncated", "incomplete", "type %d cut at %d" % (t, cut), full[:cut])

# ---------------------------------------------------------------- C. UTF-8
UTF8 = []
for c in range(0x00, 0x80):
    if c == 0:
        UTF8.append((bytes([c]), "reject", "U+0000 [MQTT-1.5.4-2]"))
    elif c < 0x20 or c == 0x7F:
        UTF8.append((bytes([c]), "either", "C0/DEL U+%04X SHOULD NOT" % c))
    elif c in (0x2B, 0x23):
        UTF8.append((bytes([c]), "accept", "wildcard char %r" % chr(c)))
    else:
        UTF8.append((bytes([c]), "accept", "ascii U+%04X" % c))
for c in range(0x80, 0xA0):
    UTF8.append((chr(c).encode(), "either", "C1 U+%04X SHOULD NOT" % c))
for cp in (0xA0, 0x7FF, 0x800, 0xFEFF, 0xFFFD, 0x10000, 0x10FFFF):
    UTF8.append((chr(cp).encode(), "accept", "valid U+%04X" % cp))
for cp in (0xFDD0, 0xFFFE, 0xFFFF, 0x1FFFE, 0x10FFFF - 0):
    if cp != 0x10FFFF:
        UTF8.append((chr(cp).encode(), "either", "noncharacter U+%04X SHOULD NOT" % cp))
BAD = [
    (b"\xed\xa0\x80", "surrogate U+D800 [MQTT-1.5.4-1]"),
    (b"\xed\xbf\xbf", "surrogate U+DFFF"),
    (b"\xed\xa0\x80\xed\xb0\x80", "surrogate pair CESU-8"),
    (b"\xc0\x80", "overlong NUL"), (b"\xc1\xbf", "overlong 2B"),
    (b"\xe0\x80\xaf", "overlong 3B"), (b"\xe0\x9f\xbf", "overlong 3B max"),
    (b"\xf0\x80\x80\xaf", "overlong 4B"), (b"\xf0\x8f\xbf\xbf", "overlong 4B max"),
    (b"\xf4\x90\x80\x80", "> U+10FFFF"), (b"\xf5\x80\x80\x80", "F5 lead"),
    (b"\xf8\x88\x80\x80\x80", "5-byte form"), (b"\xff", "0xFF"), (b"\xfe", "0xFE"),
    (b"\x80", "lone continuation"), (b"\xbf", "lone continuation BF"),
    (b"\xc2", "truncated 2B"), (b"\xe2\x82", "truncated 3B"),
    (b"\xf0\x9f\x98", "truncated 4B"), (b"\xc2\x41", "bad continuation 2B"),
    (b"\xe2\x41\x82", "bad continuation 3B #1"), (b"\xe2\x82\x41", "bad continuation 3B #2"),
    (b"\xe1\xc0\x80", "bad continuation 3B E1"), (b"\xee\x7f\x80", "bad continuation 3B EE"),
    (b"\xf1\x41\x80\x80", "bad continuation 4B F1"), (b"\xf0\x9f\x41\x80", "bad cont 4B #2"),
]
for b, note in BAD:
    UTF8.append((b, "reject", "ill-formed UTF-8: " + note))
UTF8.append((b"\xef\xbb\xbf" + b"a", "accept", "BOM must not be stripped [MQTT-1.5.4-3]"))

for ver in (4, 5):
    for raw, exp, note in UTF8:
        # topic name (wildcards forbidden there)
        e = exp
        if raw in (b"+", b"#"):
            e = "reject"
        add(ver, "C.utf8.topic", e, "PUBLISH topic a%sb: %s" % ("", note),
            publish(ver, 0, b"a" + raw + b"b"))
        # client identifier
        add(ver, "C.utf8.client_id", exp, "CONNECT client id: " + note,
            pkt(0x10, connect_body(ver, cid=b"c" + raw)))
        # subscribe filter (wildcards inside a level are malformed)
        e = exp if raw not in (b"+", b"#") else "reject"
        add(ver, "C.utf8.filter", e, "SUBSCRIBE filter: " + note,
            pkt(0x82, u16(1) + (props() if ver == 5 else b"") + s(b"x" + raw) + b"\x00"))
        if ver == 5:
            add(5, "C.utf8.user_prop", exp, "PUBLISH user property value: " + note,
                publish(5, 0, "t", pr=b"\x26" + s("k") + s(b"v" + raw)))
            add(5, "C.utf8.reason_string", exp, "PUBACK reason string: " + note,
                pkt(0x40, u16(1) + b"\x00" + props(b"\x1f" + s(b"r" + raw))))
    # 65535-byte boundary
    add(ver, "C.utf8.len", "accept", "topic 65535 bytes", publish(ver, 0, "a" * 65535, payload=b""))
    add(ver, "C.utf8.len", "accept", "client id 65535 bytes", pkt(0x10, connect_body(ver, cid="c" * 65535)))
    add(ver, "C.utf8.len", "reject", "string length prefix exceeds remaining",
        pkt(0x30, b"\xff\xff" + b"abc"))

# ---------------------------------------------------------------- D. MQTT 5 properties
PROP_VALUE = {
    0x01: b"\x01", 0x02: u32(60), 0x03: s("text/plain"), 0x08: s("r/t"),
    0x09: s(b"\x00\x01"), 0x0B: vbi(7), 0x11: u32(30), 0x12: s("aid"),
    0x13: u16(10), 0x15: s("SCRAM"), 0x16: s(b"\x01"), 0x17: b"\x01",
    0x18: u32(5), 0x19: b"\x01", 0x1A: s("ri"), 0x1C: s("srv"), 0x1F: s("why"),
    0x21: u16(10), 0x22: u16(10), 0x23: u16(1), 0x24: b"\x01", 0x25: b"\x01",
    0x26: s("k") + s("v"), 0x27: u32(1024), 0x28: b"\x01", 0x29: b"\x01", 0x2A: b"\x01",
}
ALLOWED = {
    "PUBLISH": {0x01, 0x02, 0x03, 0x08, 0x09, 0x0B, 0x23, 0x26},
    "WILL": {0x01, 0x02, 0x03, 0x08, 0x09, 0x18, 0x26},
    "CONNECT": {0x11, 0x15, 0x16, 0x17, 0x19, 0x21, 0x22, 0x26, 0x27},
    "CONNACK": {0x11, 0x12, 0x13, 0x15, 0x16, 0x1A, 0x1C, 0x1F, 0x21, 0x22, 0x24,
                0x25, 0x26, 0x27, 0x28, 0x29, 0x2A},
    "PUBACK": {0x1F, 0x26}, "PUBREC": {0x1F, 0x26}, "PUBREL": {0x1F, 0x26},
    "PUBCOMP": {0x1F, 0x26}, "SUBSCRIBE": {0x0B, 0x26}, "SUBACK": {0x1F, 0x26},
    "UNSUBSCRIBE": {0x26}, "UNSUBACK": {0x1F, 0x26},
    "DISCONNECT": {0x11, 0x1C, 0x1F, 0x26}, "AUTH": {0x15, 0x16, 0x1F, 0x26},
}


def with_props(ctx, raw):
    if ctx == "PUBLISH":
        return publish(5, 0, "t", pr=raw)
    if ctx == "WILL":
        return pkt(0x10, connect_body(5, flags=0x06, will=("w/t", "bye"), wprops=raw))
    if ctx == "CONNECT":
        return pkt(0x10, connect_body(5, cprops=raw))
    if ctx == "CONNACK":
        return pkt(0x20, b"\x00\x00" + props(raw))
    if ctx in ("PUBACK", "PUBREC", "PUBREL", "PUBCOMP"):
        h = {"PUBACK": 0x40, "PUBREC": 0x50, "PUBREL": 0x62, "PUBCOMP": 0x70}[ctx]
        return pkt(h, u16(1) + b"\x00" + props(raw))
    if ctx == "SUBSCRIBE":
        return pkt(0x82, u16(1) + props(raw) + s("a/b") + b"\x01")
    if ctx == "SUBACK":
        return pkt(0x90, u16(1) + props(raw) + b"\x00")
    if ctx == "UNSUBSCRIBE":
        return pkt(0xA2, u16(1) + props(raw) + s("a/b"))
    if ctx == "UNSUBACK":
        return pkt(0xB0, u16(1) + props(raw) + b"\x00")
    if ctx == "DISCONNECT":
        return pkt(0xE0, b"\x00" + props(raw))
    if ctx == "AUTH":
        return pkt(0xF0, b"\x00" + props(raw))
    raise KeyError(ctx)


for ctx, allowed in ALLOWED.items():
    for pid in range(0x00, 0x30):
        if pid in PROP_VALUE:
            exp = "accept" if pid in allowed else "reject"
            add(5, "D.prop_allowed", exp, "%s property 0x%02X" % (ctx, pid),
                with_props(ctx, bytes([pid]) + PROP_VALUE[pid]))
        else:
            add(5, "D.prop_unknown", "reject", "%s unknown property id 0x%02X" % (ctx, pid),
                with_props(ctx, bytes([pid]) + b"\x00"))
    for pid in allowed:
        raw = bytes([pid]) + PROP_VALUE[pid]
        multi = pid == 0x26 or (pid == 0x0B and ctx == "PUBLISH")
        add(5, "D.prop_duplicate", "accept" if multi else "reject",
            "%s property 0x%02X twice (\u00a72.2.2.2 Protocol Error)" % (ctx, pid), with_props(ctx, raw + raw))

BYTE_PROPS = {0x01: "PUBLISH", 0x17: "CONNECT", 0x19: "CONNECT", 0x24: "CONNACK",
              0x25: "CONNACK", 0x28: "CONNACK", 0x29: "CONNACK", 0x2A: "CONNACK"}
for pid, ctx in BYTE_PROPS.items():
    for v in range(0, 256):
        exp = "accept" if v in (0, 1) else "reject"
        add(5, "D.prop_byte_value", exp, "%s prop 0x%02X = %d" % (ctx, pid, v),
            with_props(ctx, bytes([pid, v])))
for pid, ctx, v, exp, note in (
        (0x21, "CONNACK", 0, "reject", "Receive Maximum 0"),
        (0x21, "CONNECT", 0, "reject", "Receive Maximum 0"),
        (0x21, "CONNACK", 65535, "accept", "Receive Maximum 65535"),
        (0x22, "CONNACK", 0, "accept", "Topic Alias Maximum 0"),
        (0x23, "PUBLISH", 0, "reject", "Topic Alias 0 [MQTT-3.3.2-8]"),
        (0x23, "PUBLISH", 65535, "accept", "Topic Alias 65535"),
        (0x13, "CONNACK", 0, "accept", "Server Keep Alive 0")):
    add(5, "D.prop_u16_value", exp, "%s %s" % (ctx, note), with_props(ctx, bytes([pid]) + u16(v)))
add(5, "D.prop_u32_value", "reject", "CONNACK Maximum Packet Size 0", with_props("CONNACK", b"\x27" + u32(0)))
add(5, "D.prop_u32_value", "reject", "CONNECT Maximum Packet Size 0", with_props("CONNECT", b"\x27" + u32(0)))
for v, exp in ((0, "reject"), (1, "accept"), (268435455, "accept")):
    add(5, "D.prop_subid", exp, "PUBLISH Subscription Identifier %d" % v, with_props("PUBLISH", b"\x0b" + vbi(v)))
    add(5, "D.prop_subid", exp, "SUBSCRIBE Subscription Identifier %d" % v, with_props("SUBSCRIBE", b"\x0b" + vbi(v)))
add(5, "D.prop_len", "reject", "PUBACK property length 5 but 0 bytes follow",
    pkt(0x40, u16(1) + b"\x00\x05"))
add(5, "D.prop_len", "reject", "PUBLISH property length > remaining",
    pkt(0x30, s("t") + b"\x7f" + b"\x01\x01"))
add(5, "D.prop_len", "either", "CONNACK non-canonical property length 0x80 0x00",
    pkt(0x20, b"\x00\x00\x80\x00"))
add(5, "D.prop_len", "reject", "property value truncated inside property block",
    pkt(0x20, b"\x00\x00" + props(b"\x11\x00\x00")))
add(5, "D.prop_len", "either", "256 user properties", with_props("PUBLISH", (b"\x26" + s("k") + s("v")) * 256))
add(5, "D.prop_len", "either", "257 user properties (limit probe)", with_props("PUBLISH", (b"\x26" + s("k") + s("v")) * 257))
add(5, "D.prop_semantic", "reject",
    "CONNECT Authentication Data without Authentication Method (\u00a73.1.2.11.10)",
    with_props("CONNECT", b"\x16" + s(b"\x01")))
add(5, "D.prop_semantic", "accept", "CONNECT Authentication Method + Data",
    with_props("CONNECT", b"\x15" + s("SCRAM") + b"\x16" + s(b"\x01")))

# ---------------------------------------------------------------- E. reason codes
RC = {
    "CONNACK": {0x00} | set(range(0x80, 0x8B)) | {0x8C, 0x90, 0x95, 0x97, 0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9F},
    "PUBACK": {0x00, 0x10, 0x80, 0x83, 0x87, 0x90, 0x91, 0x97, 0x99},
    "PUBREC": {0x00, 0x10, 0x80, 0x83, 0x87, 0x90, 0x91, 0x97, 0x99},
    "PUBREL": {0x00, 0x92}, "PUBCOMP": {0x00, 0x92},
    "SUBACK": {0x00, 0x01, 0x02, 0x80, 0x83, 0x87, 0x8F, 0x91, 0x97, 0x9E, 0xA1, 0xA2},
    "UNSUBACK": {0x00, 0x11, 0x80, 0x83, 0x87, 0x8F, 0x91},
    "DISCONNECT": {0x00, 0x04, 0x80, 0x81, 0x82, 0x83, 0x87, 0x89, 0x8B, 0x8D, 0x8E, 0x8F,
                   0x90} | set(range(0x93, 0xA3)),
    "AUTH": {0x00, 0x18, 0x19},
}
for ctx, valid in RC.items():
    for rc in range(256):
        exp = "accept" if rc in valid else "strict"
        if ctx == "CONNACK":
            b = pkt(0x20, b"\x00" + bytes([rc]) + props())
        elif ctx in ("PUBACK", "PUBREC", "PUBREL", "PUBCOMP"):
            h = {"PUBACK": 0x40, "PUBREC": 0x50, "PUBREL": 0x62, "PUBCOMP": 0x70}[ctx]
            b = pkt(h, u16(1) + bytes([rc]))
        elif ctx == "SUBACK":
            b = pkt(0x90, u16(1) + props() + bytes([rc]))
        elif ctx == "UNSUBACK":
            b = pkt(0xB0, u16(1) + props() + bytes([rc]))
        elif ctx == "DISCONNECT":
            b = pkt(0xE0, bytes([rc]))
        else:
            b = pkt(0xF0, bytes([rc]) + props())
        add(5, "E.reason_code", exp, "%s reason code 0x%02X" % (ctx, rc), b)
for rc in range(256):
    add(4, "E.return_code", "accept" if rc <= 5 else "strict",
        "v3.1.1 CONNACK return code 0x%02X" % rc, pkt(0x20, b"\x00" + bytes([rc])))
    add(4, "E.return_code", "accept" if rc in (0, 1, 2, 0x80) else "reject",
        "v3.1.1 SUBACK return code 0x%02X [MQTT-3.9.3-2]" % rc, pkt(0x90, u16(1) + bytes([rc])))
for ver in (4, 5):
    for af in range(256):
        exp = "accept" if af in (0, 1) else "reject"
        add(ver, "E.connack_flags", exp, "CONNACK ack flags 0x%02X [MQTT-3.2.2-1]" % af,
            pkt(0x20, bytes([af, 0]) + (props() if ver == 5 else b"")))
    add(ver, "E.connack_flags", "strict", "CONNACK session_present=1 with error code [MQTT-3.2.2-4/6]",
        pkt(0x20, b"\x01" + (b"\x87" if ver == 5 else b"\x05") + (props() if ver == 5 else b"")))
# v5 short forms
for name, h in (("PUBACK", 0x40), ("PUBREC", 0x50), ("PUBREL", 0x62), ("PUBCOMP", 0x70)):
    add(5, "E.short_form", "accept", name + " rem_len=2 (rc omitted)", pkt(h, u16(1)))
    add(5, "E.short_form", "accept", name + " rem_len=3 (props omitted)", pkt(h, u16(1) + b"\x00"))
    add(5, "E.short_form", "accept", name + " rem_len=4 (empty props)", pkt(h, u16(1) + b"\x00\x00"))
    add(5, "E.short_form", "reject", name + " packet id 0", pkt(h, u16(0)))
    add(4, "E.short_form", "reject", name + " v3.1.1 packet id 0", pkt(h, u16(0)))
for name, h in (("DISCONNECT", 0xE0), ("AUTH", 0xF0)):
    add(5, "E.short_form", "accept", name + " rem_len=0", pkt(h, b""))
    add(5, "E.short_form", "accept", name + " rem_len=1", pkt(h, b"\x00"))
    add(5, "E.short_form", "accept", name + " rem_len=2", pkt(h, b"\x00\x00"))

# ---------------------------------------------------------------- F. CONNECT semantics
for ver in (4, 5):
    for fl in range(256):
        will = ("w/t", "bye") if fl & 0x04 else None
        user = "u" if fl & 0x80 else None
        pw = "p" if fl & 0x40 else None
        wq = (fl >> 3) & 3
        if fl & 1:
            exp, note = "reject", "reserved bit [MQTT-3.1.2-3]"
        elif not (fl & 4) and (wq or fl & 0x20):
            exp, note = "reject", "Will QoS/Retain without Will Flag [MQTT-3.1.2-11/13/15]"
        elif fl & 4 and wq == 3:
            exp, note = "reject", "Will QoS=3 [MQTT-3.1.2-14]"
        elif ver == 4 and (fl & 0x40) and not (fl & 0x80):
            exp, note = "reject", "v3.1.1 password without username [MQTT-3.1.2-22]"
        else:
            exp, note = "accept", "valid connect flags"
        add(ver, "F.connect_flags", exp, "CONNECT flags 0x%02X: %s" % (fl, note),
            pkt(0x10, connect_body(ver, flags=fl, will=will, user=user, pw=pw)))
    for name, lvls in (("MQTT", range(0, 8)), ("MQIsdp", (3, 4)), ("mqtt", (4, 5)),
                       ("MQTT\x00", (4, 5)), ("MQT", (4, 5)), ("", (4, 5))):
        for lv in lvls:
            ok = name == "MQTT" and lv in (4, 5)
            exp = "accept" if ok else ("either" if name == "MQIsdp" and lv == 3 else "reject")
            add(ver, "F.connect_proto", exp, "CONNECT protocol %r level %d" % (name, lv),
                pkt(0x10, connect_body(5 if lv == 5 else 4, name=name, level=lv)))
    add(ver, "F.connect_cid", "either", "empty client id + CleanSession=0 (server MUST CONNACK 0x02 in v3.1.1)",
        pkt(0x10, connect_body(ver, flags=0x00, cid="")))
    add(ver, "F.connect_cid", "accept", "empty client id + CleanSession=1",
        pkt(0x10, connect_body(ver, flags=0x02, cid="")))
    for wt, exp in (("w/+", "reject"), ("w/#", "reject"), ("", "reject"), ("$SYS/w", "accept")):
        add(ver, "F.connect_will_topic", exp, "will topic %r" % wt,
            pkt(0x10, connect_body(ver, flags=0x06, will=(wt, "x"))))
    add(ver, "F.connect_trailing", "reject", "CONNECT trailing byte after payload",
        pkt(0x10, connect_body(ver) + b"\x00"))
    add(ver, "F.connect_trailing", "reject", "CONNECT missing client id",
        pkt(0x10, connect_body(ver)[:-3]))

# ---------------------------------------------------------------- G. SUBSCRIBE / UNSUBSCRIBE
FILTERS = [
    ("a/b", "accept"), ("a//b", "accept"), ("/a", "accept"), ("a/", "accept"), ("/", "accept"),
    ("#", "accept"), ("+", "accept"), ("+/+", "accept"), ("a/#", "accept"), ("a/+/c", "accept"),
    ("+/#", "accept"), ("$SYS/#", "accept"), ("a/#/b", "reject"), ("a#", "reject"),
    ("a/b#", "reject"), ("a+", "reject"), ("a/+b", "reject"), ("++", "reject"), ("##", "reject"),
    ("", "reject"), ("$share/g/a/b", "accept5"), ("$share/g/#", "accept5"),
    ("$share//a", "reject5"), ("$share/g/", "reject5"), ("$share/g", "reject5"),
    ("$share/g+/a", "reject"), ("$share/g#/a", "reject"), ("$share/+/a", "reject5"),
    ("$share/g/a#", "reject"), ("$share", "accept"), ("$shared/g/a", "accept"),
]
for ver in (4, 5):
    pr = props() if ver == 5 else b""
    for f, e in FILTERS:
        exp = e.replace("5", "") if ver == 5 else ("accept" if e.endswith("5") else e)
        add(ver, "G.filter", exp, "SUBSCRIBE filter %r" % f, pkt(0x82, u16(1) + pr + s(f) + b"\x00"))
        add(ver, "G.filter", exp, "UNSUBSCRIBE filter %r" % f, pkt(0xA2, u16(1) + pr + s(f)))
    for opt in range(256):
        if ver == 4:
            exp = "accept" if opt in (0, 1, 2) else "reject"
        else:
            exp = "accept" if (opt & 3) != 3 and (opt & 0xC0) == 0 and ((opt >> 4) & 3) != 3 else "reject"
        add(ver, "G.sub_options", exp, "SUBSCRIBE options 0x%02X" % opt,
            pkt(0x82, u16(1) + pr + s("a/b") + bytes([opt])))
    add(ver, "G.empty", "reject", "SUBSCRIBE no topic filters [MQTT-3.8.3-3]", pkt(0x82, u16(1) + pr))
    add(ver, "G.empty", "reject", "UNSUBSCRIBE no topic filters [MQTT-3.10.3-2]", pkt(0xA2, u16(1) + pr))
    add(ver, "G.empty", "reject", "SUBACK no return codes", pkt(0x90, u16(1) + pr))
    add(ver, "G.pid0", "reject", "SUBSCRIBE packet id 0", pkt(0x82, u16(0) + pr + s("a") + b"\x00"))
    add(ver, "G.pid0", "reject", "UNSUBSCRIBE packet id 0", pkt(0xA2, u16(0) + pr + s("a")))
    add(ver, "G.pid0", "reject", "PUBLISH QoS1 packet id 0", publish(ver, 0x02, "t", pid=0))
    add(ver, "G.missing_opts", "reject", "SUBSCRIBE filter without options byte",
        pkt(0x82, u16(1) + pr + s("a")))
    add(ver, "G.many", "accept", "SUBSCRIBE 1000 filters",
        pkt(0x82, u16(1) + pr + b"".join(s("t/%d" % i) + b"\x01" for i in range(1000))))
add(4, "G.empty", "reject", "v3.1.1 UNSUBACK with trailing reason code", pkt(0xB0, u16(1) + b"\x00"))
add(5, "G.empty", "strict", "v5 UNSUBACK without reason codes", pkt(0xB0, u16(1) + props()))
add(5, "G.shared_nolocal", "reject", "$share/g/a with No Local=1 [MQTT-3.8.3-4]",
    pkt(0x82, u16(1) + props() + s("$share/g/a") + b"\x04"))
add(5, "G.shared_nolocal", "accept", "plain filter with No Local=1",
    pkt(0x82, u16(1) + props() + s("a") + b"\x04"))

# ---------------------------------------------------------------- H. PUBLISH topic rules
for ver in (4, 5):
    for t, exp in (("", "reject"), ("a/+", "reject"), ("a/#", "reject"), ("+", "reject"),
                   ("#", "reject"), ("/", "accept"), ("$SYS/x", "accept"), ("a//b", "accept")):
        add(ver, "H.topic_name", exp, "PUBLISH topic %r" % t, publish(ver, 0, t))
add(5, "H.topic_alias", "accept", "v5 empty topic + Topic Alias 1", publish(5, 0, "", pr=b"\x23" + u16(1)))
add(5, "H.topic_alias", "reject", "v5 empty topic without Topic Alias", publish(5, 0, "", pr=b""))
add(5, "H.pfi", "either", "Payload Format Indicator=1 with non-UTF-8 payload (MAY 0x99)",
    publish(5, 0, "t", pr=b"\x01\x01", payload=b"\xff\xfe"))

# ---------------------------------------------------------------- I. mutation fuzz
SEEDS = []
for ver, fam, exp, note, b in list(VEC):
    if exp == "accept" and len(b) < 400:
        SEEDS.append((ver, b))
RNG.shuffle(SEEDS)
for i in range(2500):
    ver, b = SEEDS[i % len(SEEDS)]
    m = bytearray(b)
    op = RNG.randrange(5)
    if op == 0 and len(m) > 2:  # bit flip in body
        j = RNG.randrange(2, len(m))
        m[j] ^= 1 << RNG.randrange(8)
    elif op == 1 and len(m) > 2:  # byte replace
        j = RNG.randrange(1, len(m))
        m[j] = RNG.choice((0x00, 0x7F, 0x80, 0xFF, RNG.randrange(256)))
    elif op == 2:  # insert random bytes and fix remaining length
        j = RNG.randrange(2, len(m) + 1)
        ins = bytes(RNG.randrange(256) for _ in range(RNG.randrange(1, 4)))
        hdr_len = 1
        while m[hdr_len] & 0x80:
            hdr_len += 1
        body = bytes(m[hdr_len + 1:])
        k = max(0, j - hdr_len - 1)
        body = body[:k] + ins + body[k:]
        m = bytearray(pkt(m[0], body))
    elif op == 3:  # delete bytes and fix remaining length
        hdr_len = 1
        while m[hdr_len] & 0x80:
            hdr_len += 1
        body = bytes(m[hdr_len + 1:])
        if body:
            k = RNG.randrange(len(body))
            body = body[:k] + body[k + RNG.randrange(1, 3):]
        m = bytearray(pkt(m[0], body))
    else:  # type swap keeping body
        m[0] = (RNG.randrange(1, 16) << 4) | (m[0] & 0x0F)
    add(ver, "I.mutation", "either", "mutation op=%d #%d" % (op, i), m)

# ---------------------------------------------------------------- write
os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, "vectors.bin"), "wb") as fb, \
        open(os.path.join(OUT, "labels.tsv"), "w") as fl:
    fl.write("id\tver\tfamily\texpect\tnote\thex\n")
    for i, (ver, fam, exp, note, b) in enumerate(VEC):
        fb.write(bytes([ver]) + struct.pack("!I", len(b)) + b)
        hx = b.hex() if len(b) <= 512 else b[:256].hex() + "..(%dB)" % len(b)
        fl.write("%d\t%d\t%s\t%s\t%s\t%s\n" % (i, ver, fam, exp, note.replace("\t", " "), hx))
print("vectors=%d out=%s" % (len(VEC), OUT))
