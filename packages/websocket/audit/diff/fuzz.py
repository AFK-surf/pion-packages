#!/usr/bin/env python3
"""Mutation fuzz: bit-flip / length-tamper / splice valid frame streams, run all three
decoders, report Pion crashes (process abort) and verdict mismatches vs tungstenite.

usage: fuzz.py <diff_pion> <diff_rust> <diff_go> <workdir> [cases=2000] [seed=1]"""
import os, random, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

def frame(op, payload=b"", fin=True, rsv=0, mask=True):
    n = len(payload)
    b0 = (0x80 if fin else 0) | (rsv << 4) | op
    m = 0x80 if mask else 0
    if n < 126:
        hdr = bytes([b0, m | n])
    elif n <= 0xFFFF:
        hdr = bytes([b0, m | 126]) + n.to_bytes(2, "big")
    else:
        hdr = bytes([b0, m | 127]) + n.to_bytes(8, "big")
    key = b"\x01\x02\x03\x04"
    return hdr + (key + bytes(p ^ key[i & 3] for i, p in enumerate(payload)) if mask else payload)

def seed_stream(rng):
    parts = []
    for _ in range(rng.randint(1, 6)):
        k = rng.random()
        n = rng.choice([0, 1, 5, 125, 126, 300, 70000])
        if k < 0.3:
            parts.append(frame(1, ("é" * n).encode()[:n]))
        elif k < 0.5:
            parts.append(frame(2, bytes(rng.randrange(256) for _ in range(min(n, 400))) * max(1, n // 400)))
        elif k < 0.7:
            parts.append(frame(1, "κόσμε".encode(), fin=False) + frame(9, b"p") + frame(0, "ab".encode()))
        elif k < 0.85:
            parts.append(frame(9, b"x" * rng.randint(0, 125)))
        else:
            parts.append(frame(8, b"\x03\xe8bye"))
    return b"".join(parts)

def mutate(rng, b):
    b = bytearray(b)
    for _ in range(rng.randint(1, 4)):
        r = rng.random()
        if r < 0.5 and b:
            i = rng.randrange(min(len(b), 64))
            b[i] ^= 1 << rng.randrange(8)
        elif r < 0.7 and len(b) > 2:
            i = rng.randrange(min(len(b), 64))
            b[i] = rng.choice([0x00, 0x7e, 0x7f, 0x80, 0xfe, 0xff])
        elif r < 0.85:
            i = rng.randrange(len(b) + 1)
            b[i:i] = bytes(rng.randrange(256) for _ in range(rng.randint(1, 8)))
        else:
            b = b[: rng.randrange(len(b) + 1)]
    return bytes(b)

def main():
    pion, rust, go, wd = sys.argv[1:5]
    n = int(sys.argv[5]) if len(sys.argv) > 5 else 2000
    rng = random.Random(int(sys.argv[6]) if len(sys.argv) > 6 else 1)
    os.makedirs(wd, exist_ok=True)
    lines = []
    for i in range(n):
        role = "s"
        mx = rng.choice([65536, 1 << 20, 2147483647])
        ch = rng.choice([0, 1, 7, 4096])
        lines.append(f"fz{i} {role} {mx} {ch} {mutate(rng, seed_stream(rng)).hex()}")
    crashes = []
    pending = list(lines)
    pion_out = {}
    while pending:
        path = os.path.join(wd, "fuzz_corpus.txt")
        open(path, "w").write("\n".join(pending) + "\n")
        res = subprocess.run([pion, path], capture_output=True, text=True)
        done = [l for l in res.stdout.splitlines() if l]
        for l in done:
            pion_out[l.split(" ")[0]] = l.split(" ", 1)[1]
        if res.returncode == 0:
            break
        bad = pending[len(done)]
        crashes.append((bad, res.stderr.strip().splitlines()[-1] if res.stderr.strip() else f"rc={res.returncode}"))
        pending = pending[len(done) + 1:]
        if len(crashes) >= 50:
            break
    path = os.path.join(wd, "fuzz_corpus_all.txt")
    open(path, "w").write("\n".join(lines) + "\n")
    rust_out = dict(l.split(" ", 1) for l in subprocess.run([rust, path], capture_output=True, text=True).stdout.splitlines() if l)
    go_out = dict(l.split(" ", 1) for l in subprocess.run([go, path], capture_output=True, text=True).stdout.splitlines() if l)
    def cls(v):
        # Canonical verdict up to and including the first Close (post-Close handling is a
        # separately reported divergence); tungstenite reports a protocol close as `C1002`.
        if v is None:
            return "CRASH"
        ev = []
        for t in v.split(" "):
            ev.append(t)
            if t.startswith("C"):
                break
        last = ev[-1]
        if last.startswith("ERR") or last == "C1002":
            ev[-1] = "ERR"
        elif last == "END":
            ev = ev[:-1]
        return " ".join(ev)
    mism_r = [k for k in rust_out if cls(pion_out.get(k)) != cls(rust_out[k])]
    mism_g = [k for k in go_out if cls(pion_out.get(k)) != cls(go_out[k])]
    print(f"fuzz cases={n} pion_crashes={len(crashes)} verdict_mismatch_vs_tungstenite={len(mism_r)} vs_coder={len(mism_g)}")
    for bad, why in crashes[:10]:
        f = bad.split(" ")
        print(f"CRASH {f[0]} max={f[2]} chunk={f[3]} bytes={len(f[4])//2} head={f[4][:40]} :: {why}")
    for k in mism_r[:15]:
        f = lines[int(k[2:])].split(" ")
        print(f"MISMATCH {k} max={f[2]} chunk={f[3]} pion={pion_out.get(k)} rust={rust_out[k]} go={go_out.get(k)} wire={f[4][:48]}")

main()
