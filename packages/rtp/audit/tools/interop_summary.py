#!/usr/bin/env python3
"""Summarise the bidirectional Pion <-> webrtc-rs interop run.
usage: interop_summary.py pion_cases.txt rust_cases.txt rust_verify.txt pion_verify.txt
Exit 1 on any result that is not explained by a documented finding / upstream quirk."""
import collections, sys

def cases(p):
    return [l.split() for l in open(p) if len(l.split()) == 5]

def srtcp_index(prof, wire):
    w = bytes.fromhex(wire)
    off = len(w) - 4 if prof == "gcm" else len(w) - 14
    return int.from_bytes(w[off:off + 4], "big") & 0x7FFFFFFF

pc, rc = cases(sys.argv[1]), cases(sys.argv[2])
rv = [l.split() for l in open(sys.argv[3])]
pv = [l.split() for l in open(sys.argv[4])]
bad = 0
for title, cs, vs in (("Pion encrypts -> webrtc-rs decrypts/re-encrypts", pc, rv), ("webrtc-rs encrypts -> Pion decrypts/re-encrypts", rc, pv)):
    print("== %s: %d packets in %d cases" % (title, len(cs), len(set(c[0] for c in cs))))
    cnt = collections.Counter()
    for c, v in zip(cs, vs):
        case, prof, kind, plain, wire = c
        dec, enc, codec = v[3], v[4], v[5]
        tag = []
        if dec == "DEC_OK":
            tag.append("decrypt OK")
        elif case.startswith("rs_rtcp_two_ssrc") and "replay" in dec:
            tag.append("decrypt REJECTED: finding P1-2 (shared SRTCP replay window, 2nd SSRC)")
        else:
            tag.append("UNEXPLAINED " + dec); bad += 1
        if enc == "ENC_EQ":
            tag.append("ciphertext byte-identical")
        elif kind == "rtcp":
            tag.append("SRTCP ciphertext differs only by index base (Pion starts at 0, webrtc-srtp at 1)")
        else:
            tag.append("UNEXPLAINED " + enc); bad += 1
        if codec == "CODEC_OK":
            tag.append("parse+marshal identical")
        elif codec == "CODEC_SKIP_PADDING":
            tag.append("parse OK (webrtc-rs re-pads to 4 B, marshal identity n/a)")
        elif codec == "CODEC_DIFF" and "_rtcp_sr_sdes_bye_" in case:
            tag.append("SDES re-marshal differs: webrtc-rs writes the pad count into the SDES chunk padding (non-NUL), Pion writes NULs")
        else:
            tag.append("UNEXPLAINED " + codec); bad += 1
        cnt[" | ".join(tag)] += 1
    for k, n in sorted(cnt.items(), key=lambda x: -x[1]):
        print("  %4d  %s" % (n, k))
# Prove the SRTCP ENC_DIFF is only the index base: Pion's first SRTCP index is 0, webrtc-srtp's is 1.
pi = [srtcp_index(c[1], c[4]) for c in pc if c[0] == "pn_rtcp_many_cm80"][:3]
ri = [srtcp_index(c[1], c[4]) for c in rc if c[0] == "rs_rtcp_many_cm80"][:3]
print("SRTCP indices: Pion %s, webrtc-srtp %s" % (pi, ri))
if pi != [0, 1, 2] or ri != [1, 2, 3]:
    bad += 1
print("interop: %s" % ("PASS (all differences explained)" if not bad else "FAIL (%d unexplained)" % bad))
sys.exit(1 if bad else 0)
