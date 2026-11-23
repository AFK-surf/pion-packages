#!/usr/bin/env python3
"""Generate deterministic RFC 1035/3596/6891 mixed DNS response corpus for head-to-head benchmarks.

Format: stream of 1,000 length-prefixed DNS wire messages (2-byte big-endian length + wire bytes).
"""

import os
import struct
import sys


def encode_name_uncomp(domain: str) -> bytes:
    if domain == ".":
        return b"\x00"
    parts = [p for p in domain.rstrip(".").split(".") if p]
    out = bytearray()
    for p in parts:
        b = p.encode("ascii")
        out.append(len(b))
        out.extend(b)
    out.append(0)
    return bytes(out)


class DnsBuilder:
    def __init__(self, msg_id: int, qd: int, an: int, ns: int, ar: int):
        # QR=1, RD=1, RA=1, NOERROR
        self.buf = bytearray(struct.pack("!HHHHHH", msg_id & 0xFFFF, 0x8180, qd, an, ns, ar))
        self.offsets = {}

    def write_name(self, domain: str, compress: bool = True) -> None:
        if domain == ".":
            self.buf.append(0)
            return
        labels = [p for p in domain.rstrip(".").split(".") if p]
        for i in range(len(labels)):
            suffix = ".".join(labels[i:]).lower()
            if compress and suffix in self.offsets:
                ptr = 0xC000 | self.offsets[suffix]
                self.buf.extend(struct.pack("!H", ptr))
                return
            pos = len(self.buf)
            if compress and pos < 16384 and suffix not in self.offsets:
                self.offsets[suffix] = pos
            lbl = labels[i].encode("ascii")
            self.buf.append(len(lbl))
            self.buf.extend(lbl)
        self.buf.append(0)

    def add_question(self, name: str, qtype: int, qclass: int = 1) -> None:
        self.write_name(name, True)
        self.buf.extend(struct.pack("!HH", qtype, qclass))

    def add_rr(self, name: str, rtype: int, rclass: int, ttl: int, rdata: bytes) -> None:
        self.write_name(name, True)
        self.buf.extend(struct.pack("!HHIH", rtype, rclass, ttl, len(rdata)))
        self.buf.extend(rdata)

    def add_rr_name(self, name: str, rtype: int, ttl: int, target: str, compress_target: bool = True) -> None:
        self.write_name(name, True)
        self.buf.extend(struct.pack("!HHI", rtype, 1, ttl))
        rdlen_pos = len(self.buf)
        self.buf.extend(b"\x00\x00")
        start = len(self.buf)
        self.write_name(target, compress_target)
        rdlen = len(self.buf) - start
        struct.pack_into("!H", self.buf, rdlen_pos, rdlen)

    def add_mx(self, name: str, ttl: int, pref: int, exchange: str) -> None:
        self.write_name(name, True)
        self.buf.extend(struct.pack("!HHI", 15, 1, ttl))
        rdlen_pos = len(self.buf)
        self.buf.extend(b"\x00\x00")
        start = len(self.buf)
        self.buf.extend(struct.pack("!H", pref))
        self.write_name(exchange, True)
        struct.pack_into("!H", self.buf, rdlen_pos, len(self.buf) - start)

    def add_soa(self, name: str, ttl: int, mname: str, rname: str, serial: int) -> None:
        self.write_name(name, True)
        self.buf.extend(struct.pack("!HHI", 6, 1, ttl))
        rdlen_pos = len(self.buf)
        self.buf.extend(b"\x00\x00")
        start = len(self.buf)
        self.write_name(mname, True)
        self.write_name(rname, True)
        self.buf.extend(struct.pack("!IIIII", serial, 7200, 900, 1209600, 300))
        struct.pack_into("!H", self.buf, rdlen_pos, len(self.buf) - start)

    def add_srv(self, name: str, ttl: int, prio: int, weight: int, port: int, target: str) -> None:
        self.write_name(name, True)
        self.buf.extend(struct.pack("!HHI", 33, 1, ttl))
        rdlen_pos = len(self.buf)
        self.buf.extend(b"\x00\x00")
        start = len(self.buf)
        self.buf.extend(struct.pack("!HHH", prio, weight, port))
        # RFC 2782: SRV target uncompressed
        self.write_name(target, False)
        struct.pack_into("!H", self.buf, rdlen_pos, len(self.buf) - start)

    def add_opt(self, udp_size: int = 4096) -> None:
        # OPT RR: name=., type=41, class=udp_size, ttl=0x00008000 (DO=1), rdlen=0
        self.buf.append(0)
        self.buf.extend(struct.pack("!HHIH", 41, udp_size, 0x00008000, 0))

    def finish(self) -> bytes:
        return bytes(self.buf)


def build_packet(idx: int) -> bytes:
    kind = idx % 5
    msg_id = (0x1000 + idx * 37) & 0xFFFF
    if kind == 0:
        # Web CDN: CNAME + 2x A + 1x AAAA + OPT
        q = f"www.s{idx}.example.com."
        c = f"cdn.s{idx}.example.com."
        b = DnsBuilder(msg_id, 1, 4, 0, 1)
        b.add_question(q, 1)
        b.add_rr_name(q, 5, 300, c, True)
        b.add_rr(c, 1, 1, 60, bytes([93, 184, (idx >> 8) & 255, idx & 255]))
        b.add_rr(c, 1, 1, 60, bytes([93, 184, ((idx + 1) >> 8) & 255, (idx + 1) & 255]))
        v6 = struct.pack("!HHHHHHHH", 0x2606, 0x2800, 0x0220, 0x0001, 0, 0, idx & 0xFFFF, 0x0001)
        b.add_rr(c, 28, 1, 60, v6)
        b.add_opt(4096)
        return b.finish()
    elif kind == 1:
        # Mail: 2x MX + TXT + NS + OPT
        dom = f"org{idx}.example.net."
        b = DnsBuilder(msg_id, 1, 3, 1, 1)
        b.add_question(dom, 15)
        b.add_mx(dom, 3600, 10, f"mx1.org{idx}.example.net.")
        b.add_mx(dom, 3600, 20, f"mx2.org{idx}.example.net.")
        txt_s = f"v=spf1 ip4:192.0.2.{idx % 250}/24 include:_spf.example.net ~all".encode("ascii")
        b.add_rr(dom, 16, 1, 600, bytes([len(txt_s)]) + txt_s)
        b.add_rr_name(dom, 2, 86400, f"ns1.example.net.", True)
        b.add_opt(4096)
        return b.finish()
    elif kind == 2:
        # Service discovery: 2x SRV + 2x A + OPT
        q = f"_grpc._tcp.svc{idx}.internal.example.org."
        t1 = f"node1.svc{idx}.internal.example.org."
        t2 = f"node2.svc{idx}.internal.example.org."
        b = DnsBuilder(msg_id, 1, 2, 0, 3)
        b.add_question(q, 33)
        b.add_srv(q, 120, 10, 50, 8443, t1)
        b.add_srv(q, 120, 20, 50, 8444, t2)
        b.add_rr(t1, 1, 1, 120, bytes([10, 20, (idx >> 8) & 255, idx & 255]))
        b.add_rr(t2, 1, 1, 120, bytes([10, 21, (idx >> 8) & 255, idx & 255]))
        b.add_opt(4096)
        return b.finish()
    elif kind == 3:
        # Authority: 2x NS + SOA + OPT
        dom = f"zone{idx}.example.com."
        b = DnsBuilder(msg_id, 1, 2, 1, 1)
        b.add_question(dom, 2)
        b.add_rr_name(dom, 2, 86400, f"ns1.zone{idx}.example.com.", True)
        b.add_rr_name(dom, 2, 86400, f"ns2.zone{idx}.example.com.", True)
        b.add_soa(dom, 3600, f"ns1.zone{idx}.example.com.", f"hostmaster.zone{idx}.example.com.", 2026112300 + idx)
        b.add_opt(1232)
        return b.finish()
    else:
        # Dual-stack + multi-chunk TXT + OPT
        dom = f"api{idx}.cloud.example.io."
        b = DnsBuilder(msg_id, 1, 3, 0, 1)
        b.add_question(dom, 1)
        b.add_rr(dom, 1, 1, 300, bytes([198, 51, 100, (idx % 250) + 1]))
        v6 = struct.pack("!HHHHHHHH", 0x2001, 0x0DB8, 0xABCD, idx & 0xFFFF, 0, 0, 0, 0x0042)
        b.add_rr(dom, 28, 1, 300, v6)
        c1 = f"region=ap-northeast-1;cluster={idx}".encode("ascii")
        c2 = b";version=2026.11"
        b.add_rr(dom, 16, 1, 300, bytes([len(c1)]) + c1 + bytes([len(c2)]) + c2)
        b.add_opt(4096)
        return b.finish()


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: gen_corpus.py <out_dir>", file=sys.stderr)
        return 1
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "corpus.bin")
    total_pkt_bytes = 0
    with open(out_path, "wb") as f:
        for i in range(1000):
            pkt = build_packet(i)
            total_pkt_bytes += len(pkt)
            f.write(struct.pack("!H", len(pkt)))
            f.write(pkt)
    print(f"Generated 1000 packets ({total_pkt_bytes} wire bytes) -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
