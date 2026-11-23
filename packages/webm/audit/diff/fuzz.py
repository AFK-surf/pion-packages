#!/usr/bin/env python3
"""Structure-aware fuzzing of packages/webm: Pion Native --release vs Pion Wasm32 --release (+ matroska-demuxer verdicts).

  fuzz.py <bin_dir> <corpus_dir> <work_dir> <n_cases> [seed]

Cases = random bytes (5%) + mutations of seeds (hand-built vectors + miniaturised real ffmpeg files: Info/Tracks and the
first Cluster(s) with payloads cut to <= 24 bytes).  Mutators are EBML-aware: rewrite a size VINT (random, 0,
unknown-size, 8-byte long form, +-1), swap an ID for a boundary/master ID, flip SimpleBlock lacing bits / lace count /
lace sizes, splice / duplicate / delete whole elements, truncate, plus plain byte flips / inserts.

Every case runs through parse_webm, parse_init_segment and parse_media_segment(<fixed init>) on both targets.
Defects counted: native crash (non-zero exit / signal), wasm32 trap, hang (> per-batch timeout), native != wasm32
result line, a returned frame whose payload slice is outside the input ("INV").  Rust verdict (OK/ERR) disagreements
are tallied for information (matroska-demuxer is lenient on many malformed inputs and strict on others).
"""
import os
import random
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ebml import *  # noqa: E402,F401,F403
import vectors  # noqa: E402

B, C, W, N = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
rng = random.Random(int(sys.argv[5]) if len(sys.argv) > 5 else 20261123)
RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
os.makedirs(W, exist_ok=True)
BOUNDARY = [EBML, SEGMENT, CLUSTER, CUES, SEEKHEAD, INFO, TRACKS, 0x1254C367, SIMPLEBLOCK, BLOCKGROUP, BLOCK, VOID,
            TIMESTAMP, 0xAE, 0xE0, 0xE1, 0xBB, 0xB7, 0x4489, 0x2AD7B1, 0x63A2, 0x86, 0xD7, 0x23E383]


def mini(path, nclusters=2, nblocks=12):
    d = open(path, "rb").read()
    hdr, items = split_file(d)
    kids = [raw for (i, raw, _p) in items if i in (INFO, TRACKS)]
    cls = []
    for i, raw, payload in items:
        if i != CLUSTER or len(cls) >= nclusters:
            continue
        out = []
        for ci, cs, cps, cpe in children(payload, 0, len(payload)):
            if ci == SIMPLEBLOCK and len(out) < nblocks:
                pl = payload[cps:cpe]
                tr, rel, flags, hp = block_header(pl)
                out.append(elem(SIMPLEBLOCK, pl[:hp] + pl[hp:hp + 24]))
            elif ci != SIMPLEBLOCK:
                out.append(payload[cs:cpe])
        cls.append(elem(CLUSTER, b"".join(out)))
    body = b"".join(kids) + b"".join(cls)
    return hdr + enc_id(SEGMENT) + enc_size(len(body), 8) + body


def seeds():
    s = [v[0] for v in vectors.VECTORS.values()]
    for f in sorted(os.listdir(C)):
        if f.endswith((".webm", ".mkv")) and not f.startswith("mse_"):
            try:
                s.append(mini(os.path.join(C, f)))
            except Exception:
                pass
    return [x for x in s if len(x) < 64 * 1024]


def elements(d):
    """All element spans (start, id_len, size_off, size_len, payload_start, payload_end) found by a lenient walk."""
    out = []

    def walk(start, end, depth):
        p = start
        while p < end and depth < 6:
            try:
                i, q = read_id(d, p)
                sz, r = read_size(d, q)
            except Exception:
                return
            pe = end if sz is None else r + sz
            if pe > end:
                return
            out.append((p, q - p, q, r - q, r, pe, i))
            if i in (SEGMENT, CLUSTER, INFO, TRACKS, 0xAE, 0xE0, 0xE1, CUES, 0xBB, 0xB7, BLOCKGROUP, EBML):
                walk(r, pe, depth + 1)
            p = pe

    walk(0, len(d), 0)
    return out


def mutate(d):
    d = bytearray(d)
    for _ in range(rng.choice((1, 1, 1, 1, 1, 2, 3))):
        el = elements(bytes(d))
        k = rng.randrange(12)
        if k == 0 or not el:  # byte flips
            for _ in range(rng.randint(1, 4)):
                if d:
                    d[rng.randrange(len(d))] = rng.randrange(256)
        elif k == 1:  # size VINT rewrite
            p, il, so, sl, ps, pe, i = rng.choice(el)
            sz = pe - ps
            new = rng.choice([0, sz + 1, max(0, sz - 1), rng.randrange(1 << 16), (1 << 56) - 2, None, sz])
            enc = UNKNOWN8 if new is None else (enc_size(new, 8) if rng.random() < 0.3 else enc_size(new))
            d[so:so + sl] = enc
        elif k == 2:  # ID swap
            p, il, so, sl, ps, pe, i = rng.choice(el)
            d[p:p + il] = enc_id(rng.choice(BOUNDARY))
        elif k in (3, 4):  # SimpleBlock lacing
            sb = [e for e in el if e[6] in (SIMPLEBLOCK, BLOCK)]
            if sb:
                p, il, so, sl, ps, pe, i = rng.choice(sb)
                try:
                    tr, rel, flags, hp = block_header(bytes(d[ps:pe]))
                    f = ps + hp - 1
                    d[f] = (d[f] & ~0x06) | rng.choice((0x00, 0x02, 0x04, 0x06))
                    if f + 1 < pe:
                        d[f + 1] = rng.choice((0, 1, 2, 3, 7, 127, 255, rng.randrange(256)))
                    if f + 2 < pe and rng.random() < 0.5:
                        d[f + 2] = rng.choice((0x00, 0x80, 0xFF, 0x01, 0x40, 0xBF))
                    if rng.random() < 0.3:  # rel ts extremes
                        d[ps + hp - 3:ps + hp - 1] = rng.choice((b"\x80\x00", b"\x7f\xff", b"\xff\xff"))
                except Exception:
                    pass
        elif k == 5:  # delete element
            p, il, so, sl, ps, pe, i = rng.choice(el)
            del d[p:pe]
        elif k == 6:  # duplicate element
            p, il, so, sl, ps, pe, i = rng.choice(el)
            d[pe:pe] = d[p:pe] * rng.randint(1, 8)
        elif k == 7:  # splice element from another seed
            o = rng.choice(SEEDS)
            oe = elements(o)
            if oe:
                p2, _, _, _, _, pe2, _ = rng.choice(oe)
                at = rng.choice(el)[rng.choice((0, 5))]
                d[at:at] = o[p2:pe2]
        elif k == 8:  # truncate
            if d:
                del d[rng.randrange(len(d)):]
        elif k == 9:  # numeric payload extremes (timestamps, scale, duration, track numbers)
            sc = [e for e in el if e[5] - e[4] <= 8 and e[6] in (TIMESTAMP, 0x2AD7B1, 0x4489, 0xD7, 0x83, 0xB3, 0x9B, 0x23E383, 0xF1)]
            if sc:
                p, il, so, sl, ps, pe, i = rng.choice(sc)
                n = pe - ps
                val = rng.choice([b"\xff" * n, b"\x00" * n, b"\x7f" + b"\xff" * max(0, n - 1), b"\x80" + b"\x00" * max(0, n - 1),
                                  struct.pack(">d", rng.choice([float("inf"), float("-inf"), float("nan"), 1e300, -1.0]))[:n]])
                d[ps:pe] = val[:n]
        elif k == 10:  # insert random bytes
            at = rng.randrange(len(d) + 1)
            d[at:at] = bytes(rng.randrange(256) for _ in range(rng.randint(1, 8)))
        else:  # unknown-size a master
            ms = [e for e in el if e[6] in (CLUSTER, SEGMENT, BLOCKGROUP, CUES, TRACKS)]
            if ms:
                p, il, so, sl, ps, pe, i = rng.choice(ms)
                d[so:so + sl] = UNKNOWN8
    return bytes(d[:65536])


def durations(b):
    """Every 4/8-byte Duration (0x4489) float in the case, wherever it sits."""
    out, i = [], 0
    while True:
        i = b.find(b"\x44\x89", i)
        if i < 0:
            return out
        try:
            sz, p = read_size(b, i + 2)
            if sz in (4, 8) and p + sz <= len(b):
                out.append(struct.unpack(">f" if sz == 4 else ">d", b[p:p + sz])[0])
        except Exception:
            pass
        i += 1


def write_batch(path, cases):
    with open(path, "wb") as f:
        for c in cases:
            f.write(struct.pack("<I", len(c)) + c)


def run_resumable(cmd, path, init, n, timeout):
    """Run a batch, resuming after any case that crashes / traps / hangs; return (lines dict, crashes list)."""
    lines, crashes, start = {}, [], 0
    while start < n:
        args = cmd + ["batch", path] + ([init] if init else []) + [str(start)]
        try:
            p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
            out, rc, err = p.stdout.decode(errors="replace"), p.returncode, p.stderr.decode(errors="replace")
        except subprocess.TimeoutExpired as e:
            out, rc, err = (e.stdout or b"").decode(errors="replace"), "TIMEOUT", ""
        got = [l for l in out.splitlines() if l and l.split(" ", 1)[0].isdigit()]
        for l in got:
            lines[int(l.split(" ", 1)[0])] = l.split(" ", 1)[1]
        last = int(got[-1].split(" ", 1)[0]) if got else start - 1
        if rc == 0 and last == n - 1:
            break
        if rc == 0:
            break
        crashes.append((last + 1, str(rc), (err.strip().splitlines() or [""])[0][:160]))
        start = last + 2
    return lines, crashes


SEEDS = seeds()
init = os.path.join(C, "mse_init.webm")
t0 = time.time()
BATCH = 1000
trap_causes = {}
tot = dict(rust_abort=0, cases=0, native_crash=0, wasm_trap=0, hang=0, mismatch=0, inv=0, w_ok=0, r_ok=0, verdict_disagree=0, rust_panic=0)
crash_dir = os.path.join(W, "crashes")
os.makedirs(crash_dir, exist_ok=True)
examples = {}
for b in range((N + BATCH - 1) // BATCH):
    cases = []
    for _ in range(min(BATCH, N - b * BATCH)):
        if rng.random() < 0.05:
            cases.append(bytes(rng.randrange(256) for _ in range(rng.randint(1, 256))))
        else:
            cases.append(mutate(rng.choice(SEEDS)))
    path = os.path.join(W, f"batch_{b:03d}.bin")
    write_batch(path, cases)
    nl, nc = run_resumable([os.path.join(B, "pion_audit")], path, init, len(cases), 120)
    wl, wc = run_resumable(["node", RT, os.path.join(B, "pion_audit.wasm")], path, init, len(cases), 240)
    rl, rc_ = run_resumable([os.path.join(B, "rust_audit")], path, None, len(cases), 600)
    tot["rust_abort"] += len(rc_)
    for idx, rc, msg in wc:
        ds = durations(cases[idx])
        cause = ("Info/Duration non-finite or |Duration*scale/1e6| >= 2^63 -> Double::to_int64 (webm.pion:370)"
                 if any(v != v or abs(v) == float("inf") or abs(v) > 1e12 for v in ds) else "OTHER durations=" + repr(ds[:3]))
        trap_causes[cause] = trap_causes.get(cause, 0) + 1
    for idx, rc, msg in nc:
        kind = "hang" if rc == "TIMEOUT" else "native_crash"
        tot[kind] += 1
        open(os.path.join(crash_dir, f"native_{b}_{idx}.webm"), "wb").write(cases[idx])
        examples.setdefault(kind + ":" + msg[:60], (b, idx, msg))
    for idx, rc, msg in wc:
        kind = "hang" if rc == "TIMEOUT" else "wasm_trap"
        tot[kind] += 1
        open(os.path.join(crash_dir, f"wasm_{b}_{idx}.webm"), "wb").write(cases[idx])
        examples.setdefault(kind + ":" + msg[:60], (b, idx, msg))
    for i in range(len(cases)):
        tot["cases"] += 1
        a, w = nl.get(i), wl.get(i)
        if a is not None and w is not None and a != w:
            tot["mismatch"] += 1
            open(os.path.join(crash_dir, f"mismatch_{b}_{i}.webm"), "wb").write(cases[i])
            examples.setdefault("mismatch", (b, i, f"native={a[:90]} wasm={w[:90]}"))
        if a and "INV(" in a:
            tot["inv"] += 1
            examples.setdefault("inv", (b, i, a[:160]))
        r = rl.get(i, "")
        if r == "R:PANIC":
            tot["rust_panic"] += 1
        wok = bool(a) and a.startswith("W:OK")
        rok = r.startswith("R:OK")
        tot["w_ok"] += wok
        tot["r_ok"] += rok
        tot["verdict_disagree"] += (wok != rok)
    os.remove(path)
dt = time.time() - t0
print(f"  seeds={len(SEEDS)} " + " ".join(f"{k}={v}" for k, v in tot.items()) + f" seconds={dt:.0f}")
for k, v in trap_causes.items():
    print(f"  wasm32 trap root cause: {k}: {v}")
for k, (b, i, msg) in examples.items():
    print(f"  example {k}: batch {b} case {i}: {msg}")
defects = tot["native_crash"] + tot["hang"] + tot["mismatch"] + tot["inv"] + tot["wasm_trap"]
print(f"  FUZZ {'CLEAN' if defects == 0 else 'DEFECTS'}: native_crash={tot['native_crash']} wasm_trap={tot['wasm_trap']} "
      f"hang={tot['hang']} native!=wasm32={tot['mismatch']} invalid_frame_slice={tot['inv']} (of {tot['cases']} cases x 3 APIs)")
