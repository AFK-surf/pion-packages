#!/usr/bin/env python3
"""RT-zstd DoS / zip-bomb / complexity gate. usage: dos.py <work_dir> <native_cmd> <wasm_cmd>

Decompression bombs: every bomb runs through `zstd_audit bomb <file> [limits]` in native --release and wasm32
--release. Both must print the same result (minus time), match the expected result, stay within the time budget
(native 20 s, wasm32 60 s) and the peak-RSS budget of the bomb (native, Linux /proc VmHWM), and never crash.
Scaling: pairs (n, 4n) are timed with the harness' own in-process microseconds (clock_monotonic_us, so process
start-up and machine load spikes do not count), the minimum of 3 runs each; the ratio must stay below 8x
(linear ~4x, quadratic 16x).
Compressor: `zstd_audit cbomb <level> <file>` on degenerate inputs (zeros, 2-byte period, 4-byte hash-collision
chain, random, text) at levels 0/1/3/6/9: output must round-trip, 1 MiB must compress within 2 s (in-process), and
256 KiB -> 1 MiB must scale below 8x whenever the 1 MiB run takes 20 ms or more.
Prints OPENIDS <ids> for findings it reproduces; exit 1 on any P0 condition."""
import os
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rss  # noqa: E402
import zmodel as Z  # noqa: E402

work, native, wasm = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(work, exist_ok=True)
MiB = 1 << 20
BIG = ["268435456", "268435456", "268435456", "100000"]  # max_in, max_out, max_window, max_frames


def lim(out, frames=1024, window=8 * MiB):
    return [str(64 * MiB), str(out), str(window), str(frames)]


B = []


def bomb(name, data, limits, want, rss_mib, wasm_too=True):
    f = os.path.join(work, name + ".zst")
    with open(f, "wb") as o:
        o.write(data)
    B.append((name, limits, want, rss_mib, wasm_too))


H = Z.frame_header
rle128 = Z.rle_block(0x61, 131072, last=False)
body = rle128 * (MiB // 4)
# 1 MiB of input that declares 32 GiB of output: RLE blocks, no Frame_Content_Size
bomb("d01-fcs-100GiB-30B", H(fcs=100 << 30, window_log=20, fcs_flag=3) + Z.raw_block(b"x"), None,
     "ERR LimitExceeded", 16)
bomb("d02-fcs-u64max", H(fcs=(1 << 64) - 1, window_log=20, fcs_flag=3) + Z.raw_block(b"x"), None,
     "ERR LimitExceeded", 16)
bomb("d03-fcs-60MiB-truncated", H(fcs=60 * MiB, window_log=20, fcs_flag=2) + Z.raw_block(b"x", last=False), None,
     "ERR UnexpectedEof", 24)
bomb("d04-rle-32GiB-default-limit", H(window_log=17) + body, None, "ERR LimitExceeded", 400)
bomb("d05-rle-32GiB-limit-1KiB", H(window_log=17) + body, lim(1024), "ERR LimitExceeded", 16)
bomb("d06-rle-32GiB-limit-64KiB", H(window_log=17) + body, lim(65536), "ERR LimitExceeded", 16)
bomb("d07-rle-exact-64MiB", H(window_log=17) + rle128 * 511 + Z.rle_block(0x61, 131072), None,
     "OK 67108864 ", 400)
sw = Z.SeqWriter()
mblk = Z.cmp_block(Z.lits_raw(b"a") + sw.section([(1, 4, 131071)]), last=False)
bomb("d08-match-bomb-default-limit", H(window_log=17) + mblk * 20000, None, "ERR LimitExceeded", 400)
bomb("d09-match-bomb-limit-64KiB", H(window_log=17) + mblk * 20000, lim(65536), "ERR LimitExceeded", 16)
fr = Z.frame([Z.rle_block(0x62, 131072, last=False)] * 15 + [Z.rle_block(0x62, 131072)], window_log=17)
bomb("d10-multi-frame-1024x2MiB", fr * 1024, None, "ERR LimitExceeded", 400)
bomb("d11-multi-frame-limit-1KiB", fr * 1024, lim(1024), "ERR LimitExceeded", 16)
bomb("d12-skippable-flood-200k", Z.skippable(b"") * 200000, None, "ERR LimitExceeded", 16)
bomb("d13-empty-frames-1024", Z.frame([Z.raw_block(b"")], fcs=0, single=True) * 1024, None,
     "OK 0 cbf29ce484222325", 16)
bomb("d14-empty-frames-100k-raised", Z.frame([Z.raw_block(b"")], fcs=0, single=True) * 100000, BIG,
     "OK 0 cbf29ce484222325", 64)
bomb("d15-window-exp31", H(wd=0xF8) + Z.raw_block(b"x"), None, "ERR LimitExceeded", 16)
bomb("d16-skippable-4GiB-claim", Z.skippable(b"", size=0xFFFFFFFF) + b"x" * 100, None, "ERR UnexpectedEof", 16)
sw = Z.SeqWriter()
nseq_max = [(1, 4, 3)] + [(0, 2, 3)] * 43689
bomb("d17-43690-sequences-one-block", Z.frame([Z.cmp_block(Z.lits_raw(b"a") + sw.section(nseq_max))], window_log=17),
     None, "OK 131071 ", 16)
sw = Z.SeqWriter()
bomb("d18-98047-sequences-over-block", Z.frame([Z.cmp_block(Z.lits_raw(b"a") + sw.section([(1, 4, 3)] + [(0, 2, 3)] * 98046))],
                                               window_log=17), None, "ERR", 16)
lit = Z.lits_huff(bytes((i * i) % 7 + 97 for i in range(131072)), four=True)[0]
bomb("d19-4stream-huffman-128KiB-x64", Z.frame([Z.cmp_block(lit + b"\x00", last=False)] * 63 +
                                               [Z.cmp_block(lit + b"\x00")], window_log=17), None, "OK 8388608 ", 160)
bomb("d20-4stream-huffman-128KiB-x512", Z.frame([Z.cmp_block(lit + b"\x00", last=False)] * 511 +
                                                [Z.cmp_block(lit + b"\x00")], window_log=17), None, "OK 67108864 ", 1024)
bomb("d21-4stream-huffman-x512-limit-1MiB", Z.frame([Z.cmp_block(lit + b"\x00", last=False)] * 511 +
                                                    [Z.cmp_block(lit + b"\x00")], window_log=17), lim(1 << 20),
     "ERR LimitExceeded", 64)  # the 23 MB input itself is resident

SCALE = []


def pair(tag, small, large, limits=None):
    """(n, 4n) decompression scaling pair."""
    bomb(tag + "-1x", small, limits, None, 400, wasm_too=False)
    bomb(tag + "-4x", large, limits, None, 1200, wasm_too=False)
    SCALE.append(("dec " + tag, tag + "-1x", tag + "-4x"))


pair("s01-rle", H(window_log=17) + rle128 * 127 + Z.rle_block(0x61, 131072),
     H(window_log=17) + rle128 * 511 + Z.rle_block(0x61, 131072))
pair("s02-match", H(window_log=17) + mblk * 127 + Z.cmp_block(Z.lits_raw(b"a") + Z.SeqWriter().section([(1, 4, 131071)])),
     H(window_log=17) + mblk * 511 + Z.cmp_block(Z.lits_raw(b"a") + Z.SeqWriter().section([(1, 4, 131071)])))
pair("s03-huff", Z.frame([Z.cmp_block(lit + b"\x00", last=False)] * 31 + [Z.cmp_block(lit + b"\x00")], window_log=17),
     Z.frame([Z.cmp_block(lit + b"\x00", last=False)] * 127 + [Z.cmp_block(lit + b"\x00")], window_log=17))


# ---------------------------------------------------------------- compressor inputs
def collide(n):
    """4-grams that all fall in hash4 bucket 0 for hash_bits 13 and 15 (v * 2654435761 >> 17 == 0)."""
    kinv = pow(2654435761, -1, 1 << 32)
    out = bytearray()
    t = 0
    while len(out) < n:
        out += ((t * kinv) & 0xFFFFFFFF).to_bytes(4, "little")
        t += 1
    return bytes(out[:n])


def lcg(n, seed):
    out = bytearray(n)
    x = seed
    for i in range(n):
        x = (x * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        out[i] = x >> 56
    return bytes(out)


def words(n):
    w = b"alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma ".split()
    out = bytearray()
    x = 7
    while len(out) < n:
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        out += w[x % len(w)] + b" "
    return bytes(out[:n])


CIN = {
    "zeros": lambda n: bytes(n),
    "ab": lambda n: (b"ab" * n)[:n],
    "abc-period3": lambda n: (b"abc" * n)[:n],
    "collide4": collide,
    "random": lambda n: lcg(n, 1),
    "text": words,
    "zeros-then-random": lambda n: bytes(n // 2) + lcg(n - n // 2, 2),
}
CLV = [0, 1, 3, 6, 9]
for k, fn in CIN.items():
    for n, tag in ((256 * 1024, "256k"), (1024 * 1024, "1m")):
        with open(os.path.join(work, "c-%s-%s.bin" % (k, tag)), "wb") as o:
            o.write(fn(n))


def run(cmd, args):
    out, rc, secs, peak = rss.run(shlex.split(cmd) + args)
    return out.strip(), rc, secs, peak


def us_of(s):
    for t in s.split():
        if t.startswith("us="):
            return int(t[3:])
    return -1


def strip_us(s):
    return " ".join(t for t in s.split() if not t.startswith("us="))


bad = 0
opened = []
print("  %-34s %-40s %8s %8s %8s" % ("bomb", "native --release result", "native s", "RSS MiB", "wasm32 s"))
best = {}
for name, limits, want, rss_mib, wasm_too in B:
    f = os.path.join(work, name + ".zst")
    args = ["bomb", f] + (limits or [])
    no, nrc, nt, nrss = run(native, args)
    us = [us_of(no)]
    if name.startswith("s0"):
        for _ in range(2):
            us.append(us_of(run(native, args)[0]))
    best[name] = min(u for u in us if u >= 0) if any(u >= 0 for u in us) else -1
    if wasm_too:
        wo, wrc, wt, _ = run(wasm, args)
    else:
        wo, wrc, wt = no, nrc, 0.0
    flag = ""
    if nrc != 0 or wrc != 0 or not no.startswith(("OK", "ERR")):
        flag += " CRASH(native=%d wasm=%d)" % (nrc, wrc)
    if strip_us(no) != strip_us(wo):
        flag += " NATIVE!=WASM(%s)" % strip_us(wo)
    if want is not None and not strip_us(no).startswith(want.strip()) and strip_us(no) != want:
        flag += " WANT(%s)" % want
    if nt > 20 or wt > 60:
        flag += " SLOW"
    if nrss and nrss > rss_mib * MiB:
        flag += " RSS>%dMiB" % rss_mib
    if flag:
        bad += 1
    print("  %-34s %-40s %8.3f %8.1f %8s%s" % (name, strip_us(no)[:40], nt, nrss / MiB,
                                               ("%.3f" % wt) if wasm_too else "-", flag))

print("  scaling (in-process us, min of 3 runs; linear ~4x, quadratic ~16x, gate < 8x):")
for label, a, b in SCALE:
    r = best[b] / max(best[a], 1)
    print("    %-30s %10d us -> %10d us  x%.2f%s" % (label, best[a], best[b], r, "" if r < 8 else "  SUPERLINEAR"))
    if r >= 8:
        bad += 1

print("  compressor (cbomb, in-process us, min of 3 runs; round-trip through Pion decompress):")
print("    %-20s %5s %14s %14s %8s %12s" % ("input", "level", "256 KiB us", "1 MiB us", "ratio", "1 MiB size"))
for k in CIN:
    for lv in CLV:
        res = {}
        for tag in ("256k", "1m"):
            f = os.path.join(work, "c-%s-%s.bin" % (k, tag))
            outs = [run(native, ["cbomb", str(lv), f]) for _ in range(3)]
            o = outs[0][0]
            res[tag] = (min(us_of(x[0]) for x in outs), o, max(x[2] for x in outs), outs[0][1])
        r = res["1m"][0] / max(res["256k"][0], 1)
        flag = ""
        for tag in res:
            if res[tag][3] != 0 or "roundtrip=ok" not in res[tag][1]:
                flag += " BAD(%s: %s)" % (tag, strip_us(res[tag][1]))
            if res[tag][2] > 30:
                flag += " SLOW"
        # the ratio is only meaningful once the 1 MiB run takes >= 20 ms: below that (level 0 = a memcpy of
        # ~1 ms) timer resolution and allocator effects dominate; those runs are held to an absolute budget
        if r >= 8 and res["1m"][0] >= 20000:
            flag += " SUPERLINEAR"
        if res["1m"][0] >= 2000000:
            flag += " SLOW"
        if flag:
            bad += 1
        print("    %-20s %5d %14d %14d %8.2f %12s%s" % (k, lv, res["256k"][0], res["1m"][0], r,
                                                      res["1m"][1].split()[1] if res["1m"][1].startswith("OK") else "-",
                                                      flag))
print("OPENIDS " + " ".join(opened))
print("  dos: %d bombs + %d scaling pairs + %d compressor cases, %d problems" % (len(B), len(SCALE),
                                                                                 len(CIN) * len(CLV), bad))
sys.exit(1 if bad else 0)
