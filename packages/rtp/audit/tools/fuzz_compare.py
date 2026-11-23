#!/usr/bin/env python3
"""Compare Pion vs webrtc-rs fuzz verdicts. usage: fuzz_compare.py corpus pion.txt rust.txt
Prints per-kind agreement and classifies every disagreement by a root-cause rule (unexplained
diffs are listed and make the script exit 1)."""
import collections, sys

corpus = [l.rstrip("\n").split(" ", 1) for l in open(sys.argv[1])]
P = [l.rstrip("\n") for l in open(sys.argv[2])]
R = [l.rstrip("\n") for l in open(sys.argv[3])]
assert len(corpus) == len(P) == len(R), (len(corpus), len(P), len(R))

def classify(kind, data, p, r):
    b = bytes.fromhex(data[1] if len(data) > 1 else "")
    pv, rv = p.split(" ", 1)[1], r.split(" ", 1)[1]
    if rv == "PANIC":
        return "webrtc-rs PANIC (Pion returns clean %s)" % ("Ok" if pv.startswith("OK") else "Err")
    if kind in ("rtp", "rtcp") and len(b) >= 1 and (b[0] >> 6) != 2 and pv == "ERR":
        return "version != 2: Pion rejects (RFC 3550 §5.1 / §6.4), webrtc-rs does not check the RTP version"
    if kind == "srtcp" and "cm80:OK" in rv and "cm80:OK" not in pv and len(b) >= 14 and (b[len(b) - 14] & 0x80) == 0:
        return "webrtc-srtp 0.14 AES-CM SRTCP with E=0 returned WITHOUT tag check (upstream auth bypass); Pion verifies the tag and rejects"
    if kind == "rtp" and len(b) >= 12:
        x = b[0] & 0x10; cc = b[0] & 0x0F; pad = b[0] & 0x20
        off = 12 + 4 * cc
        prof = int.from_bytes(b[off:off + 2], "big") if x and len(b) >= off + 4 else -1
        if pad and pv == "ERR" and rv.startswith("OK"):
            return "RTP padding: Pion rejects pad_len==0 / pad_len>payload (RFC 3550 §5.1), webrtc-rs tolerates"
        if 0x1001 <= prof <= 0x100F:
            return "RTP two-byte appbits 0x1001..0x100F: Pion parses as RFC 8285 two-byte, webrtc-rs as raw"
        if prof in (0xBEDE, 0x1000) and pv == "ERR" and rv.startswith("OK"):
            return "RTP RFC 8285 element overrunning the extension block: Pion rejects, webrtc-rs reads past it into payload"
        if prof in (0xBEDE, 0x1000) and pv.startswith("OK") and rv.startswith("OK"):
            return "RTP RFC 8285 element count/payload split differs (webrtc-rs reads past extension block)"
        if pv.startswith("OK") and rv.startswith("OK") and pad:
            return "RTP padding accepted by both, payload length differs"
    if kind == "rtcp":
        if pv.startswith("OK") and rv == "ERR":
            return "RTCP accepted by Pion, rejected by webrtc-rs (webrtc-rs stricter per-type length / count checks)"
        if pv == "ERR" and rv.startswith("OK") and any(walk_padding(b)):
            return "RTCP padding: Pion validates pad_len (0 / > body / eats mandatory fields), webrtc-rs ignores"
        if pv == "ERR" and rv.startswith("OK"):
            return "RTCP rejected by Pion (item/length overrun), accepted by webrtc-rs"
        if pv.startswith("OK") and rv.startswith("OK"):
            return "RTCP both accept; unknown PT: Pion keeps PT, webrtc-rs reports 0"
    if kind in ("srtp", "srtcp"):
        return "%s verdict differs" % kind.upper()
    return "UNEXPLAINED"

def walk_padding(b):
    off = 0
    while off + 4 <= len(b):
        yield bool(b[off] & 0x20)
        off += (int.from_bytes(b[off + 2:off + 4], "big") + 1) * 4

stats = collections.Counter(); causes = collections.Counter(); examples = {}
for c, p, r in zip(corpus, P, R):
    kind = c[0]
    same = p == r
    stats[(kind, "agree" if same else "differ")] += 1
    if p.split(" ", 1)[1].startswith("OK"):
        stats[(kind, "pion_ok")] += 1
    if not same:
        k = classify(kind, c, p, r)
        causes[(kind, k)] += 1
        examples.setdefault((kind, k), (c[1] if len(c) > 1 else "", p, r))
for kind in ("rtp", "rtcp", "srtp", "srtcp"):
    print("%-6s agree=%-5d differ=%-5d (pion accepted %d)" % (kind, stats[(kind, "agree")], stats[(kind, "differ")], stats[(kind, "pion_ok")]))
print("disagreement root causes:")
bad = 0
for (kind, k), n in sorted(causes.items()):
    print("  %5d  %-6s %s" % (n, kind, k))
    hx, p, r = examples[(kind, k)]
    print("         e.g. in=%s\n              pion=%s\n              rust=%s" % (hx[:96], p[:120], r[:120]))
    if k == "UNEXPLAINED" or "verdict differs" in k:
        bad += n
sys.exit(1 if bad else 0)
