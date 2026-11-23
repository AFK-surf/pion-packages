"""RT-mp4 differential / fuzz / DoS driver.

    python3 difftest.py compare   # Pion dump vs ffprobe -show_packets (+ RFC 6381 codec strings from raw config)
    python3 difftest.py fuzz      # structure-aware + byte mutation fuzz, Native --release vs Wasm32 --release
    python3 difftest.py dos       # amplification / pathological inputs: wall time + peak RSS
    python3 difftest.py seek      # find_sync_sample_at vs linear reference on every corpus track
    python3 difftest.py vectors   # write the crafted red-team vectors to $AUDIT_OUT/vectors

All outputs live under $AUDIT_OUT (default /private/tmp/pion-mp4-audit).
"""
import json
import os
import random
import resource
import struct
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bmff  # noqa: E402
import vectors as vec  # noqa: E402

OUT = os.environ.get("AUDIT_OUT", "/private/tmp/pion-mp4-audit")
BIN = os.path.join(OUT, "bin")
MEDIA = os.path.join(OUT, "media")
FFPROBE = os.environ.get("FFPROBE", "/opt/homebrew/bin/ffprobe")
WASM_RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
NATIVE = [os.path.join(BIN, "mp4_audit")]
WASM = ["node", WASM_RT, os.path.join(BIN, "mp4_audit.wasm")]


def manifest():
    rows = []
    for line in open(os.path.join(MEDIA, "manifest.tsv")):
        name, kind, init, media = line.rstrip("\n").split("\t")
        rows.append((name, kind, init, media))
    return rows


# ------------------------------------------------------------------------------------------
# compare vs ffprobe

def ffprobe(path, ignore_editlist):
    cmd = [FFPROBE, "-v", "error"]
    if ignore_editlist:
        cmd += ["-ignore_editlist", "1"]
    cmd += ["-show_entries", "stream=index,id,codec_name,codec_tag_string,width,height,sample_rate,channels,time_base"
            ":packet=stream_index,pts,dts,duration,size,pos,flags", "-of", "json", path]
    return json.loads(subprocess.run(cmd, capture_output=True, check=True).stdout)


def parse_dump(text):
    tracks = {}
    order = []
    cur = None
    frag_track = None
    rng = None
    for line in text.splitlines():
        if line.startswith("track "):
            parts = line.split()
            tid = int(parts[1])
            kv = dict(p.split("=", 1) for p in parts[2:])
            cur = {"meta": kv, "samples": []}
            tracks[tid] = cur
            order.append(tid)
        elif line.startswith("frag "):
            frag_track = int(line.split()[2].split("=")[1])
        elif line.startswith("range "):
            rng = tuple(int(x) for x in line.split()[1:])
        elif line.startswith("s "):
            off, sz, dts, pts, dur, sync = (int(x) for x in line.split()[1:])
            t = tracks[frag_track] if frag_track is not None else cur
            t["samples"].append((off, sz, dts, pts, dur, sync))
        elif line.startswith("ERR"):
            return {"err": line}
    return {"tracks": tracks, "order": order, "range": rng}


def rfc6381(path):
    """Independent RFC 6381 codec strings from the raw sample-entry config boxes (ISO 14496-15 Annex E,
    AV1-ISOBMFF §5, VP9-ISOBMFF §6, RFC 6381 §3.3)."""
    data = open(path, "rb").read()
    out = {}
    for trak in [b for b in bmff.all_boxes(bmff.parse(data)) if b.type == b"trak"]:
        tkhd = trak.find(b"tkhd")[0].payload
        tid = struct.unpack_from(">I", tkhd, 20 if tkhd[0] == 1 else 12)[0]
        stsd = [b for b in trak.walk() if b.type == b"stsd"][0].payload
        entry = stsd[8:]
        fourcc = entry[4:8].decode("latin1")
        body = entry[8:struct.unpack_from(">I", entry, 0)[0]]

        def child(tag, skip):
            p = skip
            while p + 8 <= len(body):
                sz = struct.unpack_from(">I", body, p)[0]
                if sz < 8:
                    break
                if body[p + 4:p + 8] == tag:
                    return body[p + 8:p + sz]
                p += sz
            return None
        s = None
        if fourcc in ("avc1", "avc3"):
            c = child(b"avcC", 78)
            s = "%s.%02x%02x%02x" % (fourcc, c[1], c[2], c[3])
        elif fourcc in ("hvc1", "hev1"):
            c = child(b"hvcC", 78)
            space = c[1] >> 6
            tier = "H" if (c[1] >> 5) & 1 else "L"
            compat = int.from_bytes(c[2:6], "big")
            rev = int("{:032b}".format(compat)[::-1], 2)
            cons = list(c[6:12])
            while cons and cons[-1] == 0:
                cons.pop()
            s = "%s.%s%d.%X.%s%d" % (fourcc, ["", "A", "B", "C"][space], c[1] & 31, rev, tier, c[12])
            s += "".join(".%X" % b for b in cons)
        elif fourcc == "av01":
            c = child(b"av1C", 78)
            hb, tw = (c[2] >> 6) & 1, (c[2] >> 5) & 1
            bd = 12 if hb and tw else (10 if hb else 8)
            s = "av01.%d.%02d%s.%02d" % (c[1] >> 5, c[1] & 31, "H" if c[2] >> 7 else "M", bd)
        elif fourcc == "vp09":
            c = child(b"vpcC", 78)
            s = "vp09.%02d.%02d.%02d" % (c[4], c[5], c[6] >> 4)
        elif fourcc == "mp4a":
            c = child(b"esds", 28)
            # walk descriptors
            p = 4
            oti = aot = None
            while p < len(c):
                tag = c[p]
                p += 1
                ln = 0
                for _ in range(4):
                    b = c[p]
                    p += 1
                    ln = (ln << 7) | (b & 127)
                    if not b & 128:
                        break
                if tag == 3:
                    fl = c[p + 2]
                    p += 3 + (2 if fl & 128 else 0) + ((1 + c[p + 3]) if fl & 64 else 0) + (2 if fl & 32 else 0)
                elif tag == 4:
                    oti = c[p]
                    p += 13
                elif tag == 5:
                    aot = c[p] >> 3
                    if aot == 31:
                        aot = 32 + (((c[p] & 7) << 3) | (c[p + 1] >> 5))
                    break
                else:
                    p += ln
            if oti == 0x40:
                s = "mp4a.40.%d" % aot
            else:
                s = "mp4a.%02x" % oti
        elif fourcc == "Opus":
            s = "opus"
        elif fourcc == "fLaC":
            s = "fLaC"
        out[tid] = s
    return out


def compare_one(name, kind, init, media, report):
    if kind == "mp4":
        dump = subprocess.run(NATIVE + ["dump-mp4", init], capture_output=True, text=True).stdout
        probe_path = init
        base = 0
    else:
        dump = subprocess.run(NATIVE + ["dump-fmp4", init, media], capture_output=True, text=True).stdout
        if init == media:
            probe_path, base = init, 0
        else:
            probe_path = os.path.join(OUT, "cat_" + name + ".mp4")
            open(probe_path, "wb").write(open(init, "rb").read() + open(media, "rb").read())
            base = os.path.getsize(init)
    d = parse_dump(dump)
    if "err" in d:
        report.append((name, "PION-ERR", [d["err"]], []))
        return
    issues = []
    infos = []
    for ign in (True, False):
        pr = ffprobe(probe_path, ign)
        sid2tid = {s["index"]: int(s["id"], 16) for s in pr["streams"]}
        per = {}
        for p in pr["packets"]:
            per.setdefault(sid2tid[p["stream_index"]], []).append(p)
        for tid, t in d["tracks"].items():
            ff = per.get(tid, [])
            ps = t["samples"]
            if kind == "fmp4" and len(ps) != len(ff):
                # media segment only covers part of the stream when init != media in DASH (ffprobe sees all)
                pass
            if len(ps) != len(ff):
                issues.append("%s t%d count pion=%d ffprobe=%d" % ("noelst" if ign else "elst", tid, len(ps), len(ff)))
                continue
            bad = {"pos": 0, "size": 0, "dts": 0, "pts": 0, "dur": 0, "key": 0}
            first = {}
            dshift = pshift = None
            for i, (s, p) in enumerate(zip(ps, ff)):
                off, sz, dts, pts, dur, sync = s
                checks = {
                    "pos": off + base == int(p.get("pos", -1)),
                    "size": sz == int(p["size"]),
                    "key": bool(sync) == ("K" in p["flags"]),
                }
                if p.get("duration") is not None and not (i == len(ps) - 1 and kind == "mp4"):
                    # ffmpeg re-derives the last packet duration from the codec frame size (mp3) -> skip last
                    checks["dur"] = dur == int(p["duration"])
                if "dts" in p and "pts" in p:
                    if dshift is None:
                        dshift = int(p["dts"]) - dts
                        pshift = int(p["pts"]) - pts
                    checks["dts"] = dts + dshift == int(p["dts"])
                    checks["pts"] = pts + pshift == int(p["pts"])
                for k, ok in checks.items():
                    if not ok:
                        bad[k] += 1
                        first.setdefault(k, "i=%d pion=%s ff=%s" % (i, s, {x: p.get(x) for x in ("pos", "size", "dts", "pts", "duration", "flags")}))
            tag = "noelst" if ign else "elst"
            for k, v in bad.items():
                if v:
                    issues.append("%s t%d %s mismatches=%d/%d first: %s" % (tag, tid, k, v, len(ps), first[k]))
            if dshift or pshift:
                infos.append("%s t%d constant shift ffprobe-pion dts=%d pts=%d (ts=%s)" % (tag, tid, dshift, pshift, t["meta"]["ts"]))
    # codec strings
    exp = rfc6381(init)
    for tid, t in d["tracks"].items():
        want = exp.get(tid)
        got = t["meta"]["codec"]
        if want is not None and want.lower() != got.lower():
            issues.append("codec t%d pion=%s rfc6381=%s" % (tid, got, want))
    report.append((name, "OK" if not issues else "DIFF", issues, infos))


def compare():
    report = []
    rows = manifest()
    for r in rows:
        compare_one(*r, report)
    nok = 0
    shifts = {}
    for name, st, issues, infos in report:
        if st == "OK":
            nok += 1
        print("  %-34s %s" % (name, st))
        for i in issues:
            print("      - " + i)
        for i in infos:
            print("        (info) " + i)
    print("  compare: %d/%d inputs exact vs ffprobe on pos/size/keyframe/duration, dts/pts up to a per-track constant + codec string" % (nok, len(report)))
    json.dump(report, open(os.path.join(OUT, "compare.json"), "w"), indent=1)


# ------------------------------------------------------------------------------------------
# seek

def seek():
    bad = 0
    for name, kind, init, media in manifest():
        if kind != "mp4":
            continue
        out = subprocess.run(NATIVE + ["seek", init], capture_output=True, text=True).stdout
        for line in out.splitlines():
            if "mismatches=0 " not in line + " ":
                bad += 1
                print("  %-34s %s" % (name, line))
    print("  seek: %d track(s) where find_sync_sample_at disagrees with the linear reference" % bad)


# ------------------------------------------------------------------------------------------
# fuzz: Native release vs Wasm32 release

def rec(kind, payload):
    return struct.pack("<I", len(payload) + 1) + bytes([kind]) + payload


INT_EDGES = [0, 1, 2, 7, 8, 15, 16, 0x7F, 0x80, 0xFF, 0xFFFF, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFE, 0xFFFFFFFF]


def box_fields(data):
    """Offsets of every box header and of the first 64 payload u32 fields of leaf boxes."""
    sites = []

    def walk(start, end, depth):
        pos = start
        while pos + 8 <= end:
            size = struct.unpack_from(">I", data, pos)[0]
            typ = data[pos + 4:pos + 8]
            hdr = 8
            if size == 1 and pos + 16 <= end:
                size = struct.unpack_from(">Q", data, pos + 8)[0]
                hdr = 16
            elif size == 0:
                size = end - pos
            if size < hdr or pos + size > end:
                return
            sites.append(("hdr", pos, typ))
            if typ in bmff.CONTAINERS and depth < 12:
                walk(pos + hdr, pos + size, depth + 1)
            elif typ in (b"stsd",):
                walk(pos + hdr + 8, pos + size, depth + 1)
            elif typ in (b"avc1", b"avc3", b"hvc1", b"hev1", b"av01", b"vp09"):
                walk(pos + hdr + 78, pos + size, depth + 1)
            elif typ in (b"mp4a", b"Opus", b"fLaC"):
                walk(pos + hdr + 28, pos + size, depth + 1)
            else:
                for k in range(0, min(size - hdr, 256) - 3, 4):
                    sites.append(("u32", pos + hdr + k, typ))
            pos += size
    walk(0, len(data), 0)
    return sites


def mutate(data, rnd, sites):
    b = bytearray(data)
    nmut = rnd.choice([1, 1, 1, 2, 3, 5])
    for _ in range(nmut):
        try:
            mutate_once(b, data, rnd, sites)
        except (struct.error, IndexError, ValueError):
            pass
        if not b:
            b = bytearray(data[:8])
    return bytes(b)


def mutate_once(b, data, rnd, sites):
    if True:
        r = rnd.random()
        if sites and r < 0.55:
            kind, pos, typ = rnd.choice(sites)
            if kind == "hdr":
                c = rnd.random()
                if c < 0.5:
                    struct.pack_into(">I", b, pos, rnd.choice(INT_EDGES + [rnd.randrange(0, 64), len(b) - pos, len(b) - pos + 1]))
                elif c < 0.7:  # 64-bit largesize
                    struct.pack_into(">I", b, pos, 1)
                    if pos + 16 <= len(b):
                        struct.pack_into(">Q", b, pos + 8, rnd.choice([0, 8, 15, 16, 0x7FFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, len(b) - pos, rnd.randrange(16, 1 << 20)]))
                elif c < 0.85 and pos + 12 <= len(b):  # FullBox version/flags
                    b[pos + 8] = rnd.choice([0, 1, 2, 255])
                    if rnd.random() < 0.5:
                        b[pos + 9:pos + 12] = struct.pack(">I", rnd.randrange(1 << 24))[1:]
                else:  # retype
                    b[pos + 4:pos + 8] = rnd.choice([b"moov", b"trak", b"stbl", b"moof", b"traf", b"uuid", b"stz2", b"co64", b"trun", b"esds", b"wave"])
            else:
                if pos + 4 <= len(b):
                    struct.pack_into(">I", b, pos, rnd.choice(INT_EDGES + [rnd.randrange(1 << 32), rnd.randrange(0, 4096)]))
        elif r < 0.75:
            for _ in range(rnd.randrange(1, 9)):
                b[rnd.randrange(len(b))] = rnd.randrange(256)
        elif r < 0.85:
            cut = rnd.randrange(len(b))
            del b[max(cut, 8):]
        elif r < 0.93 and sites:
            # duplicate a box region (more boxes / repeated tables)
            kind, pos, typ = rnd.choice([s for s in sites if s[0] == "hdr"] or sites)
            size = struct.unpack_from(">I", b, pos)[0] if pos + 4 <= len(b) else 0
            if 8 <= size <= 4096 and pos + size <= len(b):
                b[pos:pos] = b[pos:pos + size]
        else:
            p = rnd.randrange(len(b))
            b[p:p] = bytes(rnd.randrange(256) for _ in range(rnd.randrange(1, 16)))


def run_batch(cmd, path, timeout):
    t0 = time.time()
    try:
        p = subprocess.run(cmd + ["batch", path], capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.splitlines(), p.stderr, time.time() - t0
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode() if e.stdout else ""
        return "timeout", out.splitlines(), "", time.time() - t0


def fuzz():
    n = int(os.environ.get("FUZZ_N", "12000"))
    seed = int(os.environ.get("FUZZ_SEED", "20261123"))
    rnd = random.Random(seed)
    seeds = []
    for name, kind, init, media in manifest():
        if kind == "mp4":
            d = open(init, "rb").read()
            if len(d) <= 400_000:
                seeds.append((0, d, None))
        else:
            ini = open(init, "rb").read()
            med = open(media, "rb").read()
            if init == media or len(med) > 400_000:
                continue
            seeds.append((1, ini, med))
    for v in vec.all_vectors():
        seeds.append(v[1:])
    cases = []
    for i in range(n):
        kind, a, bseg = rnd.choice(seeds)
        if kind == 1:
            if rnd.random() < 0.35:
                ini = mutate(a, rnd, box_fields(a))
                med = bseg
            else:
                ini = a
                med = mutate(bseg, rnd, box_fields(bseg))
            payload = struct.pack("<I", len(ini)) + ini + med
        else:
            payload = mutate(a, rnd, box_fields(a))
            if rnd.random() < 0.1:
                kind = 2
        cases.append(rec(kind, payload))
    fuzz_dir = os.path.join(OUT, "fuzz")
    os.makedirs(fuzz_dir, exist_ok=True)
    # shards so that a crash only loses one shard and is then bisected
    shard = 500
    stats = {"cases": n, "ok": 0, "err": 0, "native_crash": [], "wasm_crash": [], "diverge": [], "timeout": []}
    t_native = t_wasm = 0.0
    for s in range(0, n, shard):
        part = cases[s:s + shard]
        path = os.path.join(fuzz_dir, "shard_%05d.bin" % s)
        open(path, "wb").write(b"".join(part))
        rn, on, en, tn = run_batch(NATIVE, path, 300)
        rw, ow, ew, tw = run_batch(WASM, path, 600)
        t_native += tn
        t_wasm += tw
        if rn != 0 or len(on) != len(part):
            stats["native_crash"].append((s, rn, len(on), en[-300:]))
        if rw != 0 or len(ow) != len(part):
            stats["wasm_crash"].append((s, rw, len(ow), ew[-300:]))
        for a, b in zip(on, ow):
            if a != b:
                stats["diverge"].append((s, a, b))
        for a in on:
            if " OK " in a:
                stats["ok"] += 1
            else:
                stats["err"] += 1
        if rn != 0 or rw != 0 or len(on) != len(part) or len(ow) != len(part):
            k = min(len(on), len(ow))
            crash = os.path.join(fuzz_dir, "crash_%05d.bin" % (s + k))
            open(crash, "wb").write(part[k])
            print("  !! crash/timeout in shard %d at case %d -> %s" % (s, s + k, crash))
    kinds = {}
    for f in os.listdir(fuzz_dir):
        if f.startswith("shard_"):
            os.remove(os.path.join(fuzz_dir, f))
    print("  fuzz: %d cases (seed %d), %d parsed OK, %d rejected with Err" % (n, seed, stats["ok"], stats["err"]))
    print("  native --release crashes/timeouts: %d   wasm32 --release crashes/timeouts: %d   Native<->Wasm32 divergences: %d"
          % (len(stats["native_crash"]), len(stats["wasm_crash"]), len(stats["diverge"])))
    print("  wall: native %.1fs, wasm32 %.1fs" % (t_native, t_wasm))
    for d in stats["diverge"][:5]:
        print("    diverge: %s" % (d,))
    for c in stats["native_crash"][:5] + stats["wasm_crash"][:5]:
        print("    crash: %s" % (c,))
    json.dump(stats, open(os.path.join(OUT, "fuzz.json"), "w"), indent=1)
    return 0 if not (stats["native_crash"] or stats["wasm_crash"] or stats["diverge"]) else 1


# ------------------------------------------------------------------------------------------
# DoS / amplification

def timed(cmd):
    t0 = time.time()
    p = subprocess.run(["/usr/bin/time", "-l"] + cmd, capture_output=True, text=True, timeout=600)
    rss = 0
    for line in p.stderr.splitlines():
        if "maximum resident set size" in line:
            rss = int(line.split()[0])
    return p.stdout.strip(), time.time() - t0, rss, p.returncode


def dos():
    vdir = write_vectors()
    print("  %-40s %9s  %-58s %8s %9s" % ("vector", "bytes", "native --release result", "wall", "peakRSS"))
    for name, kind, a, b in vec.all_vectors():
        if not name.startswith("dos_"):
            continue
        path = os.path.join(vdir, name + ".bin")
        sz = os.path.getsize(path)
        out, wall, rss, rc = timed(NATIVE + ["file", str(kind), path])
        print("  %-40s %9d  %-58s %7.2fs %8.1fMB" % (name, sz, out[:58], wall, rss / 1048576))
        if os.environ.get("DOS_WASM", "1") == "1":
            out, wall, rss, rc = timed(WASM + ["file", str(kind), path])
            print("  %-40s %9s  %-58s %7.2fs %8.1fMB" % ("   (wasm32 --release, node)", "", out[:58], wall, rss / 1048576))


def write_vectors():
    vdir = os.path.join(OUT, "vectors")
    os.makedirs(vdir, exist_ok=True)
    for name, kind, a, b in vec.all_vectors():
        payload = a if kind != 1 else struct.pack("<I", len(a)) + a + b
        open(os.path.join(vdir, name + ".bin"), "wb").write(payload)
    return vdir


if __name__ == "__main__":
    sec = sys.argv[1] if len(sys.argv) > 1 else "compare"
    if sec == "compare":
        compare()
    elif sec == "fuzz":
        sys.exit(fuzz())
    elif sec == "dos":
        dos()
    elif sec == "seek":
        seek()
    elif sec == "vectors":
        print("  vectors -> " + write_vectors())
