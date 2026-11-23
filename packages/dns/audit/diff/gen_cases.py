#!/usr/bin/env python3
"""Deterministic red-team case generator for packages/dns differential runs.

Writes <out>/{msg,name,ip6,tcp,doh}.tsv (one `<id>\t<hex>` per line):
  * `hand_*`   hand-crafted RFC edge cases (mirrors packages/dns/audit/*_test.pion)
  * `seed_*`   valid responses taken from packages/dns/bench/gen_corpus.py
  * `mut_*`    structure-aware mutations of the above (seeded PRNG, reproducible)

Usage: python3 gen_cases.py <out_dir> [--mutants N] [--seed S]
"""
import argparse
import base64
import os
import random
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.normpath(os.path.join(HERE, "..", "..", "bench"))


def name(s):
    if s in (".", ""):
        return b"\x00"
    out = bytearray()
    for p in s.rstrip(".").split("."):
        out.append(len(p))
        out += p.encode()
    return bytes(out + b"\x00")


def hdr(qd=0, an=0, ns=0, ar=0, flags=0x8180, mid=0x1234):
    return struct.pack("!HHHHHH", mid, flags, qd, an, ns, ar)


def rr(owner, rtype, rdata, rclass=1, ttl=60):
    return owner + struct.pack("!HHIH", rtype, rclass, ttl, len(rdata)) + rdata


def one_answer(rtype, rdata):
    return hdr(an=1) + rr(b"\x00", rtype, rdata)


def one_additional(owner, rtype, rclass, rdata):
    return hdr(ar=1) + rr(owner, rtype, rdata, rclass=rclass, ttl=0)


def opt(options):
    return one_additional(b"\x00", 41, 1232, bytes(options))


def svcb(prio, target, params, rtype=64):
    return one_answer(rtype, struct.pack("!H", prio) + target + bytes(params))


def hand_msgs():
    q = name("a.example.") + struct.pack("!HH", 1, 1)
    c = {}
    # --- RFC 9460 SVCB/HTTPS
    c["svcb_alias_with_port"] = svcb(0, name("foo."), [0, 3, 0, 2, 1, 0xBB], 65)
    c["svcb_mandatory_key0"] = svcb(1, b"\x00", [0, 0, 0, 2, 0, 0, 0, 3, 0, 2, 1, 0xBB])
    c["svcb_mandatory_unsorted"] = svcb(1, b"\x00", [0, 0, 0, 4, 0, 3, 0, 1, 0, 1, 0, 3, 2, 0x68, 0x32, 0, 3, 0, 2, 1, 0xBB])
    c["svcb_mandatory_absent"] = svcb(1, b"\x00", [0, 0, 0, 2, 0, 4, 0, 3, 0, 2, 1, 0xBB])
    c["svcb_ech_empty"] = svcb(1, b"\x00", [0, 5, 0, 0], 65)
    c["svcb_alpn_empty_id"] = svcb(1, b"\x00", [0, 1, 0, 1, 0])
    c["svcb_alpn_len0"] = svcb(1, b"\x00", [0, 1, 0, 0])
    c["svcb_ndalpn_nonempty"] = svcb(1, b"\x00", [0, 2, 0, 1, 0])
    c["svcb_port_len3"] = svcb(1, b"\x00", [0, 3, 0, 3, 0, 0, 0])
    c["svcb_v4hint_len0"] = svcb(1, b"\x00", [0, 4, 0, 0])
    c["svcb_v4hint_len5"] = svcb(1, b"\x00", [0, 4, 0, 5, 1, 2, 3, 4, 5])
    c["svcb_v6hint_len15"] = svcb(1, b"\x00", [0, 6, 0, 15] + [0] * 15)
    c["svcb_keys_desc"] = svcb(1, b"\x00", [0, 3, 0, 2, 1, 0xBB, 0, 1, 0, 3, 2, 0x68, 0x32])
    c["svcb_dup_key"] = svcb(1, b"\x00", [0, 3, 0, 2, 1, 0xBB, 0, 3, 0, 2, 1, 0xBB])
    c["svcb_key65535"] = svcb(1, b"\x00", [0xFF, 0xFF, 0, 0])
    c["svcb_target_compressed"] = hdr(qd=1, an=1) + q + rr(b"\xc0\x0c", 64, struct.pack("!H", 1) + b"\xc0\x0c")
    # --- RFC 6891 / 7871 / 7873
    c["ecs_family3"] = opt([0, 8, 0, 8, 0, 3, 24, 0, 1, 2, 3, 4])
    c["ecs_v4_prefix8_4octets"] = opt([0, 8, 0, 8, 0, 1, 8, 0, 10, 1, 2, 3])
    c["ecs_v4_hostbits"] = opt([0, 8, 0, 5, 0, 1, 4, 0, 0x1F])
    c["ecs_family0_prefix8"] = opt([0, 8, 0, 5, 0, 0, 8, 0, 10])
    c["ecs_v4_prefix33"] = opt([0, 8, 0, 8, 0, 1, 33, 0, 1, 2, 3, 4])
    c["ecs_v6_prefix129"] = opt([0, 8, 0, 4, 0, 2, 129, 0])
    c["ecs_v4_short_addr"] = opt([0, 8, 0, 5, 0, 1, 24, 0, 10])
    for n in (0, 7, 8, 9, 15, 16, 40, 41):
        c[f"cookie_len{n}"] = opt([0, 10, 0, n] + list(range(n)))
    c["opt_trunc_hdr"] = opt([0, 12, 0])
    c["opt_trunc_data"] = opt([0, 12, 0, 5, 0])
    one = opt([])
    c["opt_twice"] = hdr(ar=2) + one[12:] + one[12:]
    c["opt_in_answer"] = hdr(an=1) + rr(b"\x00", 41, b"", rclass=1232, ttl=0)
    c["opt_owner_nonroot"] = one_additional(name("a."), 41, 1232, b"")
    # --- RFC 4034 NSEC
    c["nsec_len0"] = one_answer(47, bytes([0, 0, 0]))
    c["nsec_len33"] = one_answer(47, bytes([0, 0, 33] + [0xFF] * 33))
    c["nsec_desc"] = one_answer(47, bytes([0, 1, 1, 0x40, 0, 1, 0x40]))
    c["nsec_trailing_zero"] = one_answer(47, bytes([0, 0, 2, 0x40, 0]))
    c["nsec_allzero_window"] = one_answer(47, bytes([0, 0, 1, 0]))
    c["nsec_compressed_next"] = hdr(qd=1, an=1) + q + rr(b"\xc0\x0c", 47, b"\xc0\x0c" + bytes([0, 1, 0x40]))
    c["rrsig_compressed_signer"] = hdr(qd=1, an=1) + q + rr(b"\xc0\x0c", 46, bytes(18) + b"\xc0\x0c" + b"sig")
    # --- RFC 8659 CAA / TXT
    c["caa_space_tag"] = one_answer(257, bytes([0, 5]) + b"i sue" + b"ca")
    c["caa_tag16"] = one_answer(257, bytes([0, 16]) + b"a" * 16)
    c["caa_tag_nonascii"] = one_answer(257, bytes([0, 2, 0xC3, 0x28]))
    c["caa_tag0"] = one_answer(257, bytes([0, 0]))
    c["txt_empty"] = one_answer(16, b"")
    c["txt_overrun"] = one_answer(16, bytes([5]) + b"abc")
    # --- fixed-size / name RDATA length mismatches
    c["a_len5"] = one_answer(1, bytes([1, 2, 3, 4, 5]))
    c["a_len3"] = one_answer(1, bytes([1, 2, 3]))
    c["aaaa_len15"] = one_answer(28, bytes(15))
    c["cname_extra_byte"] = one_answer(5, name("x.") + b"\x00")
    c["mx_short"] = one_answer(15, b"\x00\x01")
    c["soa_extra"] = one_answer(6, b"\x00\x00" + bytes(21))
    c["srv_short"] = one_answer(33, bytes(6))
    # --- compression pointers
    c["ptr_self"] = hdr(qd=1) + b"\xc0\x0c" + struct.pack("!HH", 1, 1)
    c["ptr_cycle2"] = hdr(qd=1) + b"\xc0\x0e\xc0\x0c" + struct.pack("!HH", 1, 1)
    c["ptr_forward"] = hdr(qd=1) + b"\x03www\xc0\x16" + struct.pack("!HH", 1, 1) + name("com.")
    c["ptr_into_header"] = hdr(qd=1) + b"\xc0\x02" + struct.pack("!HH", 1, 1)
    c["ptr_oob"] = hdr(qd=1) + b"\xc0\xff" + struct.pack("!HH", 1, 1)
    c["ptr_overlap_own_label"] = hdr(qd=1) + b"\x01\x00\xc0\x0d" + struct.pack("!HH", 1, 1)
    c["ptr_mid_label"] = hdr(qd=1, an=1) + b"\x03xyz\x00" + struct.pack("!HH", 1, 1) + rr(b"\xc0\x0d", 1, b"\x01\x02\x03\x04")
    c["ptr_into_rdata"] = (hdr(qd=1, an=2) + q + rr(b"\xc0\x0c", 5, b"\x01b\xc0\x0e") + rr(b"\xc0\x27", 1, b"\x01\x02\x03\x04"))
    c["label_0x40"] = hdr(qd=1) + b"\x41" + b"a" * 1 + b"\x00" + struct.pack("!HH", 1, 1)
    c["label_0x80"] = hdr(qd=1) + b"\x81a\x00" + struct.pack("!HH", 1, 1)
    # pointer chains of k hops, each strictly backward. The chain lives inside
    # opaque TXT character-strings (answer 1); answer 2's owner enters the chain
    # at its last element. RFC-legal shape; only the hop count varies.
    for k in (64, 126, 127, 128, 129, 200):
        rdata = bytearray()
        base = 12 + 11  # RDATA offset of answer 1 (root owner)
        offs = []
        chunk = bytearray()
        def flush():
            rdata.append(len(chunk))
            rdata.extend(chunk)
            chunk.clear()
        # element 0: root label
        chunk.append(0)
        offs.append(base + 1)
        for _ in range(k):
            if len(chunk) + 2 > 254:
                flush()
            at = base + len(rdata) + 1 + len(chunk)
            chunk.extend(struct.pack("!H", 0xC000 | offs[-1]))
            offs.append(at)
        flush()
        c[f"ptr_chain_{k}"] = hdr(an=2) + rr(b"\x00", 16, bytes(rdata)) + rr(struct.pack("!H", 0xC000 | offs[-1]), 1, b"\x01\x02\x03\x04")
    # 255 / 256-byte names assembled through compression
    l63 = b"\x3f" + b"a" * 63
    n255 = l63 * 3 + b"\x3d" + b"d" * 61 + b"\x00"
    n256 = l63 * 3 + b"\x3e" + b"d" * 62 + b"\x00"
    c["name_255"] = hdr(qd=1) + n255 + struct.pack("!HH", 1, 1)
    c["name_256"] = hdr(qd=1) + n256 + struct.pack("!HH", 1, 1)
    tail = b"\x3d" + b"d" * 61 + b"\x00"
    c["name_255_via_ptr"] = hdr(qd=2) + tail + struct.pack("!HH", 1, 1) + l63 * 3 + b"\xc0\x0c" + struct.pack("!HH", 1, 1)
    tail2 = b"\x3e" + b"d" * 62 + b"\x00"
    c["name_256_via_ptr"] = hdr(qd=2) + tail2 + struct.pack("!HH", 1, 1) + l63 * 3 + b"\xc0\x0c" + struct.pack("!HH", 1, 1)
    # RFC 2136 UPDATE: zone SOA, prerequisite ANY/A rdlen 0, update ANY/AAAA rdlen 0
    upd = struct.pack("!HHHHHH", 0x1234, 0x2800, 1, 1, 1, 0) + name("example.") + struct.pack("!HH", 6, 1)
    upd += rr(b"\x03www\xc0\x0c", 1, b"", rclass=255, ttl=0) + rr(b"\x03www\xc0\x0c", 28, b"", rclass=255, ttl=0)
    c["update_rfc2136_empty_rdata"] = upd
    for t, nm in ((1, "a"), (28, "aaaa"), (5, "cname"), (33, "srv"), (64, "svcb"), (47, "nsec"), (46, "rrsig")):
        c[f"rdlen0_{nm}_class_any"] = hdr(an=1) + rr(b"\x00", t, b"", rclass=255, ttl=0)
    # counts claiming 65535 with no data / trailing bytes
    c["qd65535_trunc"] = hdr(qd=65535)
    c["an65535_trunc"] = hdr(an=65535)
    c["trailing_garbage"] = hdr(qd=1) + q + b"\xde\xad"
    c["short_header"] = hdr()[:11]
    # big response: 600 distinct A records => crosses 16 KiB with compressed owners
    big = bytearray(hdr(qd=1, an=600) + q)
    for i in range(600):
        big += rr(bytes([len(f"h{i}")]) + f"h{i}".encode() + b"\xc0\x0e", 1, bytes([10, i >> 8 & 255, i & 255, 1]))
    c["big_600_a"] = bytes(big)
    return c


def seed_corpus(tmp):
    os.makedirs(tmp, exist_ok=True)
    subprocess.run([sys.executable, os.path.join(BENCH, "gen_corpus.py"), tmp], check=True, stdout=subprocess.DEVNULL)
    data = open(os.path.join(tmp, "corpus.bin"), "rb").read()
    out, pos = [], 0
    while pos + 2 <= len(data):
        n = struct.unpack("!H", data[pos:pos + 2])[0]
        out.append(data[pos + 2:pos + 2 + n])
        pos += 2 + n
    return out


def mutate(rng, b):
    b = bytearray(b)
    op = rng.randrange(9)
    if not b:
        return bytes(b)
    if op == 0:  # bit flip(s)
        for _ in range(rng.randint(1, 4)):
            i = rng.randrange(len(b))
            b[i] ^= 1 << rng.randrange(8)
    elif op == 1:  # special byte
        i = rng.randrange(len(b))
        b[i] = rng.choice([0x00, 0x01, 0x3F, 0x40, 0x7F, 0x80, 0xC0, 0xC1, 0xFF])
    elif op == 2:  # truncate
        b = b[: rng.randrange(len(b))]
    elif op == 3:  # insert pointer
        i = rng.randrange(12, max(13, len(b)))
        b[i:i] = bytes([0xC0 | rng.randrange(4), rng.randrange(256)])
    elif op == 4:  # header count tweak
        if len(b) >= 12:
            j = 4 + 2 * rng.randrange(4)
            v = rng.choice([0, 1, 2, 3, 0xFF, 0xFFFF, struct.unpack("!H", b[j:j + 2])[0] + 1])
            b[j:j + 2] = struct.pack("!H", v & 0xFFFF)
    elif op == 5:  # duplicate a slice
        i = rng.randrange(len(b))
        j = min(len(b), i + rng.randint(1, 32))
        b[j:j] = b[i:j]
    elif op == 6:  # delete a slice
        i = rng.randrange(len(b))
        del b[i:i + rng.randint(1, 8)]
    elif op == 7:  # random tail
        b += bytes(rng.randrange(256) for _ in range(rng.randint(1, 16)))
    else:  # overwrite a 16-bit field with an extreme
        i = rng.randrange(len(b) - 1) if len(b) > 1 else 0
        b[i:i + 2] = struct.pack("!H", rng.choice([0, 0xFFFF, 0x8000, 0x3FFF, 0x4000, 0xC00C]))
    return bytes(b)


NAMES = [
    "", ".", "..", "a..b.", ".a.", "a.", "a", "example.com", "example.com.", "A.ExAmPlE.",
    "a\\000b.", "\\000.", "\\.", "a\\.b.c.", "a\\\\b.", "\\065\\066c.", "\\128\\255.",
    "a\\256.", "a\\999.", "a\\12", "a\\1x.", "a\\", "a\\b.", "a\\ b.", "a b.", "a;b.", "a(b).",
    "a\"b.", "a@b.", "a$b.", "*.example.", "_srv._tcp.example.", "xn--bcher-kva.example.",
    "ü.example.", "中文.", "-a-.", "a" * 63 + ".", "a" * 64 + ".",
    ("a" * 63 + ".") * 3 + "d" * 61 + ".", ("a" * 63 + ".") * 3 + "d" * 62 + ".",
    ("a" * 63 + ".") * 3 + "d" * 61, "\\065" * 63 + ".", "\\065" * 64 + ".",
    "a.\\.", "\\..", "a\\..", "\\\\.", "a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.",
]

IP6 = [
    "::", "::1", "1::", "2001:db8::1", "2001:0db8:0000:0000:0000:0000:0000:0001", "2001:db8:0:0:1:0:0:1",
    "2001:db8:0:1:1:1:1:1", "1:0:0:2:0:0:0:3", "::1:2:3:4:5:6:7", "1:2:3:4:5:6:7::", "2001:DB8::AbCd",
    "::ffff:192.0.2.1", "64:ff9b::192.0.2.33", "::192.0.2.1", "0:0:0:0:0:ffff:192.0.2.1", "::ffff:c000:201",
    ":::", "1::2::3", "12345::", "g::", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7", ":1::", "1::2:", "",
    "::1:2:3:4:5:6:7:8", "fe80::1%eth0", "00000::1", "0001:2:3:4:5:6:7:8", "1:2:3:4:5:6:7:8",
    "::ffff:1.2.3", "::ffff:256.1.1.1", "::ffff:01.2.3.4", "1:2:3:4:5:6:1.2.3.4", "1:2:3:4:5:6:7:1.2.3.4",
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--mutants", type=int, default=6000)
    ap.add_argument("--seed", type=int, default=0xD15EA5E)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rng = random.Random(a.seed)
    hand = hand_msgs()
    seeds = seed_corpus(os.path.join(a.out, "seed_corpus"))
    msgs = [(f"hand_{k}", v) for k, v in hand.items()]
    msgs += [(f"seed_{i:04d}", s) for i, s in enumerate(seeds[:300])]
    pool = list(hand.values()) + seeds[:300]
    for i in range(a.mutants):
        b = rng.choice(pool)
        for _ in range(rng.randint(1, 3)):
            b = mutate(rng, b)
        msgs.append((f"mut_{i:05d}", b))
    with open(os.path.join(a.out, "msg.tsv"), "w") as f:
        for k, v in msgs:
            f.write(f"{k}\t{v.hex()}\n")
    # names: fixed + mutated
    names = list(NAMES)
    alphabet = "abcXYZ09-_.\;()\"@ \x00\x7f"
    for i in range(1500):
        base = rng.choice(NAMES)
        s = list(base)
        for _ in range(rng.randint(1, 4)):
            op = rng.randrange(3)
            if op == 0 or not s:
                s.insert(rng.randrange(len(s) + 1), rng.choice(alphabet))
            elif op == 1:
                del s[rng.randrange(len(s))]
            else:
                s[rng.randrange(len(s))] = rng.choice(alphabet + "0123456789")
        names.append("".join(s))
    with open(os.path.join(a.out, "name.tsv"), "w") as f:
        for i, s in enumerate(names):
            f.write(f"name_{i:05d}\t{s.encode('utf-8').hex()}\n")
    ip6 = list(IP6)
    hexd = "0123456789abcdefABCDEF:.g"
    for i in range(600):
        s = list(rng.choice(IP6) or "::")
        for _ in range(rng.randint(1, 3)):
            op = rng.randrange(3)
            if op == 0 or not s:
                s.insert(rng.randrange(len(s) + 1), rng.choice(hexd))
            elif op == 1:
                del s[rng.randrange(len(s))]
            else:
                s[rng.randrange(len(s))] = rng.choice(hexd)
        ip6.append("".join(s))
    with open(os.path.join(a.out, "ip6.tsv"), "w") as f:
        for i, s in enumerate(ip6):
            f.write(f"ip6_{i:04d}\t{s.encode().hex()}\n")
    # tcp framing
    with open(os.path.join(a.out, "tcp.tsv"), "w") as f:
        fixed = [b"", b"\x00", b"\x00\x00", b"\x00\x0c" + hdr(), b"\x00\x0d" + hdr(), b"\xff\xff" + hdr()]
        for i, s in enumerate(fixed):
            f.write(f"tcp_fixed_{i}\t{s.hex()}\n")
        for i in range(800):
            m = rng.choice(seeds[:300] + list(hand.values()))
            fr = struct.pack("!H", len(m) & 0xFFFF) + m
            k = rng.randrange(5)
            if k == 0:
                fr = fr + fr  # two glued frames
            elif k == 1:
                fr = fr[: rng.randrange(len(fr) + 1)]
            elif k == 2:
                fr = mutate(rng, fr)
            elif k == 3:
                fr = struct.pack("!H", rng.randrange(65536)) + m
            f.write(f"tcp_{i:04d}\t{fr.hex()}\n")
    with open(os.path.join(a.out, "doh.tsv"), "w") as f:
        for i in range(800):
            m = rng.choice(seeds[:300] + list(hand.values()))
            s = base64.urlsafe_b64encode(m).decode().rstrip("=")
            k = rng.randrange(6)
            if k == 1:
                s += "=="
            elif k == 2 and s:
                j = rng.randrange(len(s))
                s = s[:j] + rng.choice("+/ =.!~") + s[j + 1:]
            elif k == 3 and s:
                s = s[:-1] + rng.choice("BCDEFGHIJKLMNOPQRSTUVWXYZ")  # perturb trailing bits
            elif k == 4:
                s = s[: rng.randrange(len(s) + 1)]
            f.write(f"doh_{i:04d}\t{s.encode().hex()}\n")
    print(f"msg={len(msgs)} name={len(names)} ip6={len(ip6)} tcp=806 doh=800 -> {a.out}")


if __name__ == "__main__":
    main()
