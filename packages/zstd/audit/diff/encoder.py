#!/usr/bin/env python3
"""RT-zstd compressor gate. usage: encoder.py <corpus_dir> <res_dir> <oracle> <native_rel> <native_dbg> <wasm_dbg> <wasm_rel>

Every raw input of <corpus>/raw.bin is compressed by Pion at levels 0..9, with and without checksum, in all four
modes (the four output containers must be byte-identical). Every frame must then
  * decode to the raw input byte for byte in libzstd 1.5.7, pure safe Rust ruzstd 0.9.0 and the official CLI
    (`zstd -t` and `zstd -d`), and in Pion itself;
  * pass the strict model (diff/zmodel.py: offsets <= Window_Size, block sizes, bitstreams consumed exactly, no
    unused / reserved header bits), for inputs up to 300 KB (the pure-Python model is slow);
  * respect the frame rules a decoder does not have to check: Frame_Content_Size present and equal to the input,
    Content_Checksum present iff requested, FHD reserved / unused bits 0, no Dictionary_ID, Window_Size >= every
    offset (model) and a Compressed_Block strictly smaller than its decompressed size (RFC 8878 3.1.1.2.3).
Invalid levels (-1, 10, 22, 2^31-1) must return InvalidLevel. Exit 1 on any violation (P0)."""
import hashlib
import json
import os
import shlex
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zmodel as Z  # noqa: E402

C, R, ORACLE = sys.argv[1:4]
RUN = {"native_rel": sys.argv[4], "native_dbg": sys.argv[5], "wasm_dbg": sys.argv[6], "wasm_rel": sys.argv[7]}


def records(blob):
    out, p = [], 0
    while p + 4 <= len(blob):
        n = int.from_bytes(blob[p:p + 4], "little")
        out.append(blob[p + 4:p + 4 + n])
        p += 4 + n
    return out


def walk(fr, n):
    """Header + block walk without decoding (large inputs). Pion splits its input at 128 KiB boundaries, so the
    decompressed size of block k is min(128 KiB, n - 128 KiB * k)."""
    fhd = fr[4]
    fcsf, ss, chk, didf = fhd >> 6, (fhd >> 5) & 1, (fhd >> 2) & 1, fhd & 3
    p = 5 + (0 if ss else 1) + [0, 1, 2, 4][didf]
    fn = [1 if ss else 0, 2, 4, 8][fcsf]
    fcs = int.from_bytes(fr[p:p + fn], "little") + (256 if fn == 2 else 0) if fn else None
    p += fn
    blocks, done = [], 0
    while True:
        bh = int.from_bytes(fr[p:p + 3], "little")
        bt, bs = (bh >> 1) & 3, bh >> 3
        dec = bs if bt != 2 else min(131072, n - done)
        blocks.append((bt, bs, dec))
        done += dec
        p += 3 + (1 if bt == 1 else bs)
        if bh & 1:
            break
    if p + 4 * chk != len(fr):
        blocks.append((9, 0, 0))
    return [{"fhd": fhd, "fcs": fcs, "checksum": chk, "did_flag": didf, "blocks": blocks}]


raw_idx = [json.loads(l) for l in open(os.path.join(C, "raw.json"))]
raws = records(open(os.path.join(C, "raw.bin"), "rb").read())
bad = 0
stats = {"frames": 0, "oracle_ok": 0, "cli_ok": 0, "model_ok": 0, "model_skipped": 0, "rules_ok": 0}
sizes = {}
os.makedirs(os.path.join(R, "enc"), exist_ok=True)
feats = {}


def problem(msg):
    global bad
    bad += 1
    if bad <= 30:
        print("  FAIL " + msg)


for lv in range(10):
    for chk in (0, 1):
        outs = {}
        for m, cmd in RUN.items():
            o = os.path.join(R, "enc", "pion_l%d_c%d_%s.bin" % (lv, chk, m))
            r = subprocess.run(shlex.split(cmd) + ["enc", str(lv), str(chk), os.path.join(C, "raw.bin"), o],
                               capture_output=True, text=True)
            if r.returncode != 0 or "ERR" in r.stdout:
                problem("enc L%d chk=%d %s: rc=%d %s" % (lv, chk, m, r.returncode, (r.stdout + r.stderr)[-200:]))
            outs[m] = open(o, "rb").read() if os.path.exists(o) else b""
        h = {m: hashlib.sha256(v).hexdigest() for m, v in outs.items()}
        if len(set(h.values())) != 1:
            problem("L%d chk=%d: the 4 modes produce different frames %s" % (lv, chk, h))
        cont = os.path.join(R, "enc", "pion_l%d_c%d_native_rel.bin" % (lv, chk))
        frames = records(outs["native_rel"])
        orc = subprocess.run([ORACLE, "dec", cont], capture_output=True, text=True).stdout.splitlines()
        pdec = subprocess.run(shlex.split(RUN["native_rel"]) + ["dec", cont], capture_output=True, text=True).stdout.splitlines()
        for i, (ri, raw, fr) in enumerate(zip(raw_idx, raws, frames)):
            stats["frames"] += 1
            name = "%s L%d chk=%d" % (ri["name"], lv, chk)
            want = "OK %d %016x" % (len(raw), Z.fnv64(raw))
            sizes.setdefault((ri["name"], lv), len(fr))
            ru, lz = orc[i].split("\t")
            if ru == want and lz == want and pdec[i] == want:
                stats["oracle_ok"] += 1
            else:
                problem("%s: ruzstd=%s libzstd=%s pion=%s" % (name, ru[:60], lz[:60], pdec[i]))
            f = os.path.join(R, "enc", "one.zst")
            open(f, "wb").write(fr)
            t = subprocess.run(["zstd", "-q", "-t", f], capture_output=True, text=True)
            d = subprocess.run(["zstd", "-q", "-d", "-c", f], capture_output=True)
            if t.returncode == 0 and d.returncode == 0 and d.stdout == raw:
                stats["cli_ok"] += 1
            else:
                problem("%s: zstd -t rc=%d %s / zstd -d rc=%d" % (name, t.returncode, t.stderr.strip()[-120:], d.returncode))
            trace = []
            ft = set()
            if len(raw) <= 300000:
                try:
                    o = Z.decode(fr, feat=ft, trace=trace)
                    if o != raw:
                        problem("%s: model decodes different content" % name)
                    else:
                        stats["model_ok"] += 1
                except Z.ZErr as e:
                    problem("%s: strict model rejects the frame: %s" % (name, e))
                for k in ft:
                    feats[k] = feats.get(k, 0) + 1
            else:
                stats["model_skipped"] += 1
                trace = walk(fr, len(raw))
            ok = True
            if trace:
                tf = trace[0]
                if tf["fhd"] & 0x18 or tf["did_flag"]:
                    ok = False
                    problem("%s: FHD reserved/unused/dictionary bits set (0x%02x)" % (name, tf["fhd"]))
                if tf["fcs"] != len(raw):
                    ok = False
                    problem("%s: Frame_Content_Size %r != %d" % (name, tf["fcs"], len(raw)))
                if tf["checksum"] != chk:
                    ok = False
                    problem("%s: Content_Checksum flag %d, requested %d" % (name, tf["checksum"], chk))
                for bt, bs, dec in tf["blocks"]:
                    if bt == 9:
                        ok = False
                        problem("%s: bytes after the frame" % name)
                        break
                    if bt == 2 and bs >= dec:
                        ok = False
                        problem("%s: Compressed_Block of %d bytes for %d decompressed (RFC 8878 3.1.1.2.3)" % (name, bs, dec))
                        break
                if len(trace) != 1:
                    ok = False
                    problem("%s: %d frames" % (name, len(trace)))
            if ok and trace:
                stats["rules_ok"] += 1
# invalid levels
for lv in (-1, 10, 22, 2147483647, -2147483648):
    o = os.path.join(R, "enc", "bad.bin")
    r = subprocess.run(shlex.split(RUN["native_rel"]) + ["enc", str(lv), "0", os.path.join(C, "raw.bin"), o],
                       capture_output=True, text=True)
    got = set(r.stdout.split("\n")) - {""}
    if got != {"ERR InvalidLevel"}:
        problem("level %d: %s" % (lv, sorted(got)[:3]))
print("  %(frames)d Pion frames (48 inputs x levels 0..9 x checksum on/off), 4 modes byte-identical" % stats)
print("  libzstd + ruzstd + Pion decode byte-exact: %(oracle_ok)d/%(frames)d; zstd -t + zstd -d: %(cli_ok)d/%(frames)d" % stats)
print("  strict model: %(model_ok)d decoded byte-exact (%(model_skipped)d inputs > 300 KB skipped); frame rules: %(rules_ok)d" % stats)
print("  invalid levels -1, 10, 22, 2^31-1, -2^31 -> ERR InvalidLevel")
print("  features of Pion frames: " + ", ".join("%s %d" % kv for kv in sorted(feats.items())))
print("  compressed size, Pion level 0/1/3/6/9 vs official zstd -1/-3/-19 (bytes):")
for k in ("text_1024", "text_131073", "html_262144", "binlog_262144", "cjk_65536", "rand_131072", "mixed_300000",
          "html_1048576", "binlog_1048576", "rle_200000"):
    p = os.path.join(C, "tmp", k)
    ref = []
    for lv in ("-1", "-3", "-19"):
        ref.append(len(subprocess.run(["zstd", "-q", "-c", lv, p], capture_output=True).stdout))
    print("    %-16s %9d raw | pion %s | zstd %s" % (k, os.path.getsize(p), " ".join("%8d" % sizes[(k, l)] for l in (0, 1, 3, 6, 9)),
                                                 " ".join("%8d" % x for x in ref)))
print("  encoder problems: %d" % bad)
sys.exit(1 if bad else 0)
