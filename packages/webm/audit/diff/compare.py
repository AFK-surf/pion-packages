#!/usr/bin/env python3
"""Differential: Pion webm (native --release, wasm32 --release) vs matroska-demuxer 0.6.1 vs ffprobe vs symphonia.

  compare.py <bin_dir> <corpus_dir>

Per file it checks, and prints one verdict line:
  * native == wasm32 dump byte-for-byte;
  * vs matroska-demuxer: same track table (number/type/codec/CodecPrivate fnv/DefaultDuration) and, frame by
    frame, same track / size / pts_ns / keyframe (SimpleBlock only: matroska-demuxer has no flag for BlockGroup)
    / payload fnv64 (which proves Pion's `offset` points at the right bytes);
  * vs ffprobe -show_packets: same packet count, per packet track / size / keyframe flag, and pts_ms after removing
    the constant per-track CodecDelay shift ffmpeg applies; pts differences that are *not* that constant are
    reported (laced frames: ffmpeg interpolates lace timestamps, Pion stamps every lace with the Block time);
  * symphonia-format-mkv (audio-only files): packet sizes + payload fnv64;
  * find_keyframe_at vs a brute-force oracle over every frame pts (+-1 ms).
"""
import os
import subprocess
import sys

B, C = sys.argv[1], sys.argv[2]
RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")


def run(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    return p.returncode, p.stdout.decode(errors="replace")


def frames(txt):
    return [l.split() for l in txt.splitlines() if l.startswith("F ")]


def tracks(txt):
    return [l.split() for l in txt.splitlines() if l.startswith("T ")]


def ffprobe(path):
    _, s = run(["ffprobe", "-v", "error", "-show_entries", "stream=index", "-of", "csv=p=0", path])
    _, p = run(["ffprobe", "-v", "error", "-show_entries", "packet=stream_index,pts,size,flags", "-of", "csv=p=0", path])
    pk = []
    for l in p.splitlines():
        f = [x for x in l.split(",") if x != ""]
        if len(f) >= 4:
            pk.append((int(f[0]), f[1], int(f[2]), "K" in f[3]))
    return pk


files = sorted(f for f in os.listdir(C) if f.endswith((".webm", ".mkv")) and not f.startswith("mse_"))
totals = dict(files=0, frames=0, defects=0)
issues_all = []
for name in files:
    path = os.path.join(C, name)
    totals["files"] += 1
    issues = []
    _, pn = run([os.path.join(B, "pion_audit"), "dump", path])
    _, pw = run(["node", RT, os.path.join(B, "pion_audit.wasm"), "dump", path])
    if pn != pw:
        issues.append("DEFECT native!=wasm32")
    _, rs = run([os.path.join(B, "rust_audit"), "dump", path])
    pf, rf = frames(pn), frames(rs)
    totals["frames"] += len(pf)
    head = pn.splitlines()[0] if pn else "?"
    # tracks
    pt = [(t[1], t[2], t[3], t[4], t[5], t[-1]) for t in tracks(pn)]
    rt = [(t[1], t[2], t[3], t[4], t[5], t[-1]) for t in tracks(rs)]
    if pt != rt:
        issues.append(f"tracks differ vs matroska-demuxer: pion={pt} rust={rt}")
    if len(pf) != len(rf):
        issues.append(f"frame count pion={len(pf)} matroska-demuxer={len(rf)}")
    nd = 0
    for i, (a, b) in enumerate(zip(pf, rf)):
        # F track size pts_ns pts_ms dur key fnv
        same = a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[7] == b[7] and (b[6] == "?" or a[6] == b[6])
        if not same:
            nd += 1
            if nd == 1:
                issues.append(f"first frame diff vs matroska-demuxer #{i}: pion={a} rust={b}")
    if nd:
        issues.append(f"{nd} frames differ vs matroska-demuxer")
    # ffprobe
    pk = ffprobe(path)
    tnums = [t[1] for t in tracks(pn)]
    if len(pk) != len(pf):
        issues.append(f"packet count pion={len(pf)} ffprobe={len(pk)}")
    shift = {}
    lace_pts = 0
    other = 0
    first_other = None
    for i, (a, (si, pts, size, key)) in enumerate(zip(pf, pk)):
        tn = tnums[si] if si < len(tnums) else "?"
        if a[1] != tn or int(a[2]) != size or (a[6] == "1") != key:
            other += 1
            first_other = first_other or f"#{i} pion={a[1:3]+[a[6]]} ffprobe=({tn},{size},{key})"
            continue
        if pts == "N/A":
            continue
        d = int(a[4]) - int(pts)
        shift.setdefault(tn, d)
        if d != shift[tn]:
            lace_pts += 1
    if other:
        issues.append(f"{other} packets differ vs ffprobe (track/size/key), first {first_other}")
    if lace_pts:
        issues.append(f"{lace_pts} pts_ms differ vs ffprobe beyond the constant CodecDelay shift {shift}")
    # symphonia (audio-only files)
    if all(t[2] == "2" for t in tracks(pn)) and tracks(pn):
        _, sy = run([os.path.join(B, "rust_audit"), "symph", path])
        sp = [l.split() for l in sy.splitlines() if l.startswith("P ")]
        if sy.startswith("ERR"):
            issues.append("symphonia: " + sy.strip()[:80])
        elif [(x[4], x[5]) for x in sp] != [(a[2], a[7]) for a in pf]:
            issues.append(f"symphonia packets differ: symphonia={len(sp)} pion={len(pf)}")
    _, kf = run([os.path.join(B, "pion_audit"), "kf", path])
    if " mismatches=0" not in kf:
        issues.append("find_keyframe_at: " + kf.strip())
    print(f"{'OK  ' if not issues else 'DIFF'} {name:34s} {head}")
    for x in issues:
        print("       " + x)
    issues_all += issues

# MSE pairs
for init, media in (("mse_init.webm", "mse_media.webm"), ("mse_init_yt.webm", "mse_media_yt.webm")):
    ip, mp = os.path.join(C, init), os.path.join(C, media)
    if not os.path.exists(ip):
        continue
    _, pn = run([os.path.join(B, "pion_audit"), "mse", ip, mp])
    _, pw = run(["node", RT, os.path.join(B, "pion_audit.wasm"), "mse", ip, mp])
    joined = os.path.join(os.path.dirname(C.rstrip("/")), "mse_joined_" + init)
    open(joined, "wb").write(open(ip, "rb").read() + open(mp, "rb").read())
    _, rs = run([os.path.join(B, "rust_audit"), "dump", joined])
    pf, rf = frames(pn), frames(rs)
    ok = pn == pw and [(a[1], a[2], a[3], a[7]) for a in pf] == [(b[1], b[2], b[3], b[7]) for b in rf]
    hdr = [l for l in pn.splitlines() if l.startswith(("INIT", "MEDIA"))]
    print(f"{'OK  ' if ok else 'DIFF'} {init + '+' + media:34s} {' | '.join(hdr)} (matroska-demuxer on init||media: {len(rf)} frames)")
    if not ok:
        issues_all.append("mse " + init)
print(f"SUMMARY files={totals['files']} frames={totals['frames']} issue_lines={len(issues_all)} "
      f"native_wasm_mismatch={sum('native!=wasm32' in x for x in issues_all)}")
