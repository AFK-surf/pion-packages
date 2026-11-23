"""RT-mp4 performance probe: build patched copies of packages/mp4/src (under $AUDIT_OUT/perf, never in the
repo) and time `prof-fmp4` (init / media split) interleaved against the unmodified source.

    python3 perf.py [iters]

Variants are *experiments* proving where the fMP4 time goes; each keeps the dump output identical
(checked with dump-fmp4 SHA-256 on the bench segment and every fMP4 corpus input).
"""
import hashlib
import os
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
OUT = os.environ.get("AUDIT_OUT", "/private/tmp/pion-mp4-audit")
PERF = os.path.join(OUT, "perf")
ITERS = int(sys.argv[1]) if len(sys.argv) > 1 else 500000
INIT = os.path.join(OUT, "bench", "yt_init_0.m4s")
SEG = os.path.join(OUT, "bench", "yt_seg_0_1.m4s")

TIMELINE_OLD = """      let mut si = 0
      while si < frag.samples.length() {
        let sm = frag.samples[si]
        let s_ms = (sm.pts * 1000L) / ts
        let e_ms = ((sm.pts + sm.duration.to_int64()) * 1000L) / ts
        if !has_pts {
          has_pts = true
          min_ms = s_ms
          max_ms = e_ms
        } else {
          if s_ms < min_ms {
            min_ms = s_ms
          }
          if e_ms > max_ms {
            max_ms = e_ms
          }
        }
        si = si + 1
      }"""
# Truncating division by a positive timescale is monotone, so min/max over raw ticks then one
# division per fragment gives the identical [start_pts_ms, end_pts_ms].
TIMELINE_NEW = """      let n = frag.samples.length()
      if n > 0 {
        let mut lo = frag.samples[0].pts
        let mut hi = lo + frag.samples[0].duration.to_int64()
        let mut si = 1
        while si < n {
          let sm = frag.samples[si]
          if sm.pts < lo {
            lo = sm.pts
          }
          let e = sm.pts + sm.duration.to_int64()
          if e > hi {
            hi = e
          }
          si = si + 1
        }
        let s_ms = (lo * 1000L) / ts
        let e_ms = (hi * 1000L) / ts
        if !has_pts {
          has_pts = true
          min_ms = s_ms
          max_ms = e_ms
        } else {
          if s_ms < min_ms {
            min_ms = s_ms
          }
          if e_ms > max_ms {
            max_ms = e_ms
          }
        }
      }"""

VARIANTS = {
    "base": [],
    "timeline_per_fragment": [(TIMELINE_OLD, TIMELINE_NEW)],
    "timeline_skipped(bound)": [(TIMELINE_OLD, "      let _ = frag")],
}


def build(name, patches):
    d = os.path.join(PERF, name.replace("(", "_").replace(")", ""))
    if os.path.exists(d):
        shutil.rmtree(d)
    os.makedirs(os.path.join(d, "mp4", "src"))
    for f in os.listdir(os.path.join(PKG, "src")):
        src = open(os.path.join(PKG, "src", f)).read()
        for old, new in patches:
            if f == "mp4.pion":
                assert old in src, (name, old[:40])
                src = src.replace(old, new)
        open(os.path.join(d, "mp4", "src", f), "w").write(src)
    shutil.copy(os.path.join(PKG, "pion.toml"), os.path.join(d, "mp4", "pion.toml"))
    drv = os.path.join(d, "driver")
    os.makedirs(os.path.join(drv, "src"))
    shutil.copy(os.path.join(HERE, "src", "main.pion"), os.path.join(drv, "src", "main.pion"))
    open(os.path.join(drv, "pion.toml"), "w").write('[package]\nname = "mp4_audit"\nversion = "0.1.0"\n\n[dependencies]\nmp4 = { path = "../mp4" }\n')
    exe = os.path.join(d, "bin")
    subprocess.run(["pionc", "build", "--release", "-o", exe, drv], check=True)
    return exe


def dump_hash(exe):
    h = hashlib.sha256()
    pairs = [(INIT, SEG)]
    for line in open(os.path.join(OUT, "media", "manifest.tsv")):
        name, kind, a, b = line.rstrip("\n").split("\t")
        if kind == "fmp4":
            pairs.append((a, b))
    for a, b in pairs:
        h.update(subprocess.run([exe, "dump-fmp4", a, b], capture_output=True, check=True).stdout)
    return h.hexdigest()[:16]


def main():
    os.environ["PATH"] = os.path.expanduser("~/.pion/bin") + ":" + os.environ["PATH"]
    exes = {n: build(n, p) for n, p in VARIANTS.items()}
    hashes = {n: dump_hash(e) for n, e in exes.items()}
    res = {n: {"init": [], "media": []} for n in exes}
    for _ in range(5):
        for n, e in exes.items():
            out = subprocess.run([e, "prof-fmp4", INIT, SEG, str(ITERS)], capture_output=True, text=True, check=True).stdout
            kv = dict(x.split("=") for x in out.split())
            res[n]["init"].append(int(kv["init_ms"]))
            res[n]["media"].append(int(kv["media_ms"]))
    base = min(res["base"]["media"])
    print("  fMP4 video bench segment (60 samples, sidx + 1 moof), %d iterations, 5 interleaved rounds, min wall:" % ITERS)
    for n in exes:
        im, mm = min(res[n]["init"]), min(res[n]["media"])
        print("  %-26s init %5d ms (%.0f ns/iter)  media %5d ms (%.0f ns/iter, %.2fx of base)  dump-sha %s%s" % (
            n, im, im * 1e6 / ITERS, mm, mm * 1e6 / ITERS, base / mm if mm else 0, hashes[n],
            "" if n.endswith("(bound)") or hashes[n] == hashes["base"] else "  !! OUTPUT DIFFERS"))


main()
