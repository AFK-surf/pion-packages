#!/usr/bin/env python3
"""Differential driver: Go 1.27 archive/tar vs Pion `tar` (and Rust `tar` for interop).

  compare.py dump  <go_bin> <pion_bin> <file>...       field-level diff of canonical dumps
  compare.py trunc <go_bin> <pion_bin> <stride> <file>...   every-prefix truncation diff
  compare.py mutate <go_bin> <pion_bin> <seed> <n> <file>...  deterministic mutation diff
  compare.py writer <go_bin> <pion_bin> <spec> <tmpdir>   per-entry Writer differential (bytes + Go re-read)

A dump line is `E k=v ...`, `D len=.. fnv=..`, `D skip`, `EOF`, `ERR next`, `ERR data`.
Field names in the summary make the category obvious (fmt-only, name, size, data, status...).
Exit status is the number of files that differ (capped at 100), so CI can assert on it.
"""
import subprocess
import sys


def run(cmd):
    p = subprocess.run(cmd, capture_output=True)
    out = p.stdout.decode("latin-1")
    if p.returncode < 0:
        out += f"CRASH signal {-p.returncode}\n"
    elif p.returncode != 0:
        out += f"CRASH rc={p.returncode} {p.stderr.decode('latin-1')[:200]}\n"
    return out


def parse_line(line):
    parts = line.split(" ")
    kind = parts[0]
    fields = {}
    for p in parts[1:]:
        if "=" in p:
            k, v = p.split("=", 1)
            fields[k] = v
        else:
            fields[p] = ""
    return kind, fields


def unhex(s):
    try:
        return bytes.fromhex(s).decode("utf-8", "backslashreplace")
    except ValueError:
        return s


def short(k, v):
    if k in ("name", "link", "uname", "gname"):
        v = repr(unhex(v))
    elif k in ("pax", "xattr"):
        v = "{" + ", ".join(f"{unhex(a)}={unhex(b)[:24]!r}" for a, b in (x.split("=", 1) for x in v.split(",") if x)) + "}"
    return v if len(v) < 90 else v[:87] + "..."


def diff_dump(a, b):
    """Return a list of human-readable differences between two dumps."""
    la, lb = a.splitlines(), b.splitlines()
    out = []
    for i in range(max(len(la), len(lb))):
        x = la[i] if i < len(la) else "<missing>"
        y = lb[i] if i < len(lb) else "<missing>"
        if x == y:
            continue
        kx, fx = parse_line(x)
        ky, fy = parse_line(y)
        if kx == ky == "E":
            for k in fx:
                if fx.get(k) != fy.get(k):
                    out.append(f"line {i}: {k}: go={short(k, fx.get(k, ''))} pion={short(k, fy.get(k, ''))}")
        else:
            out.append(f"line {i}: go={x[:120]!r} pion={y[:120]!r}")
        if kx != ky:
            break  # streams diverged; the rest is noise
    return out


FIELDS = [(0, 100, "name"), (100, 108, "mode"), (108, 116, "uid"), (116, 124, "gid"), (124, 136, "size"),
          (136, 148, "mtime"), (148, 156, "chksum"), (156, 157, "typeflag"), (157, 257, "linkname"),
          (257, 263, "magic"), (263, 265, "version"), (265, 297, "uname"), (297, 329, "gname"),
          (329, 337, "devmajor"), (337, 345, "devminor"), (345, 500, "prefix/atime/ctime"), (500, 512, "pad")]


def field_at(off):
    blk, o = divmod(off, 512)
    for a, b, n in FIELDS:
        if a <= o < b:
            return f"block {blk} field {n}"
    return f"block {blk}"


def writer(go, pion, spec, tmp):
    import os
    os.makedirs(tmp, exist_ok=True)
    lines = [l for l in open(spec, encoding="latin-1").read().splitlines() if l.startswith("H ")]
    n_status = n_bytes = n_sem = 0
    for i, line in enumerate(lines):
        sp = os.path.join(tmp, "one.spec")
        open(sp, "w", encoding="latin-1").write(line + "\n")
        og, op = os.path.join(tmp, "g.tar"), os.path.join(tmp, "p.tar")
        for f in (og, op):
            if os.path.exists(f):
                os.remove(f)
        lg = run([go, "writespec", sp, og]).replace("W 0 ", "")
        lp = run([pion, "writespec", sp, op]).replace("W 0 ", "")
        desc = " ".join(line.split(" ")[1:2]) + " " + repr(unhex(line.split(" ")[2])[:40])
        if lg.split() != lp.split():
            n_status += 1
            print(f"STATUS #{i} {desc}: go={lg.split()} pion={lp.split()}")
            print(f"    spec: {line[:160]}")
            continue
        if not os.path.exists(og):
            continue
        bg, bp = open(og, "rb").read(), open(op, "rb").read()
        if bg == bp:
            continue
        n_bytes += 1
        first = next((k for k in range(min(len(bg), len(bp))) if bg[k] != bp[k]), min(len(bg), len(bp)))
        sem = diff_dump(run([go, "dump", og]), run([go, "dump", op]))
        if sem:
            n_sem += 1
        print(f"BYTES #{i} {desc}: len go={len(bg)} pion={len(bp)}, first diff at {first} ({field_at(first)}): "
              f"go={bg[first:first+16]!r} pion={bp[first:first+16]!r}")
        for x in sem[:4]:
            print(f"    Go re-reading Pion's output differs: {x}")
        rust = os.environ.get("RUST_BIN")
        if rust:
            rg, rp = run([rust, "lite", og]), run([rust, "lite", op])
            if rg != rp:
                print(f"    Rust re-reading differs: go-written={rg.splitlines()[:2]} pion-written={rp.splitlines()[:2]}")
    print(f"writer: {len(lines)} specs, {n_status} accept/reject differences, {n_bytes} byte differences "
          f"({n_sem} of them change what Go reads back)")
    return n_status + n_sem


def main():
    flags = []
    if sys.argv[-1] == "nofmt":
        flags = ["nofmt"]
        sys.argv.pop()
    mode = sys.argv[1]
    go, pion = sys.argv[2], sys.argv[3]
    ndiff = 0
    if mode == "writer":
        sys.exit(min(writer(go, pion, sys.argv[4], sys.argv[5]), 100))
    if mode == "dump":
        for f in sys.argv[4:]:
            d = diff_dump(run([go, "dump", f] + flags), run([pion, "dump", f] + flags))
            if d:
                ndiff += 1
                print(f"DIFF {f}")
                for x in d[:6]:
                    print("   ", x)
        print(f"dump: {len(sys.argv) - 4} files, {ndiff} differ")
    elif mode in ("trunc", "mutate"):
        extra = sys.argv[4:5] if mode == "trunc" else sys.argv[4:6]
        files = sys.argv[5:] if mode == "trunc" else sys.argv[6:]
        total = 0
        known = 0
        for f in files:
            full_differs = bool(diff_dump(run([go, "dump", f] + flags), run([pion, "dump", f] + flags)))
            ga = run([go, mode, f] + extra + flags).splitlines()
            pa = run([pion, mode, f] + extra + flags).splitlines()
            bad = [(x, y) for x, y in zip(ga, pa) if x != y]
            if len(ga) != len(pa):
                bad.append((f"{len(ga)} lines", f"{len(pa)} lines"))
            total += len(ga)
            crash = [y for y in pa if "CRASH" in y]
            if crash:
                print(f"PION CRASH {f}: {crash[0][:200]}")
            if bad and full_differs:
                known += 1
                print(f"KNOWN {f}: {len(bad)}/{len(ga)} cases differ (the full archive already differs in `dump`)")
            elif bad:
                ndiff += 1
                print(f"DIFF {f}: {len(bad)}/{len(ga)} cases differ, e.g.")
                for x, y in bad[:3]:
                    print(f"    go:   {x}\n    pion: {y}")
        print(f"{mode}: {len(files)} files, {total} cases, {ndiff} files with NEW differences, {known} files already different in dump")
    sys.exit(min(ndiff, 100))


if __name__ == "__main__":
    main()
