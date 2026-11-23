#!/usr/bin/env python3
"""Crash/hang-tolerant differential runner: Pion driver vs Rust `regex =1.11.1` oracle.

usage: run_diff.py <pion_cmd> <rust_cmd> <cases> <out_prefix> [--timeout S]

<pion_cmd>/<rust_cmd> are shell-split command prefixes; the case file path is appended.
A case that crashes (signal / non-zero exit) or hangs the Pion driver is recorded,
commented out in a working copy (line numbers are preserved) and the run resumes.
Writes <out_prefix>.mismatch.txt and prints a one-line JSON summary.
"""
import json
import shlex
import subprocess
import sys


def blocks(text):
    out, cur, idx = {}, None, None
    for line in text.splitlines():
        if line.startswith("## "):
            idx = int(line[3:])
            cur = out.setdefault(idx, [])
        elif idx is not None:
            cur.append(line)
    return out


def decode_case(line):
    f = line.split("\t")
    d = lambda x: bytes.fromhex(x).decode("utf-8")
    if f[0] == "S":
        pats = [d(p) for p in f[2].split(",")] if len(f) > 2 and f[2] else []
        return f"SET pats={pats!r} hay={d(f[1])!r}"
    return f"pat={d(f[1])!r} hay={d(f[2])!r} rep={d(f[3])!r}"


def main():
    args = sys.argv[1:]
    timeout = 60.0
    if "--timeout" in args:
        i = args.index("--timeout")
        timeout = float(args[i + 1])
        del args[i:i + 2]
    pion_cmd, rust_cmd, cases, prefix = args
    lines = open(cases, encoding="utf-8").read().split("\n")
    work = prefix + ".work.cases"
    failures = []  # (lineno, kind)
    pion_out = ""
    resume = 1
    open(work, "w", encoding="utf-8").write("\n".join(lines))
    while True:
        try:
            p = subprocess.run(shlex.split(pion_cmd) + [work, str(resume)], capture_output=True, timeout=timeout)
            rc, out, kind = p.returncode, p.stdout.decode("utf-8", "replace"), None
            if rc != 0:
                kind = f"crash(rc={rc})"
        except subprocess.TimeoutExpired as e:
            out = (e.stdout or b"").decode("utf-8", "replace")
            kind = f"hang(>{timeout:.0f}s)"
        if kind is None:
            pion_out += out
            break
        # keep only complete blocks (a block is printed in one write after the case ran)
        done = max(blocks(out).keys(), default=resume - 1)
        pion_out += out
        # if the last printed block is complete the culprit is the next case; the driver
        # prints a case only after it fully ran, so the culprit is the first case after `done`.
        nxt = done  # 0-based index of line `done+1`
        while nxt < len(lines) and (not lines[nxt] or lines[nxt].startswith("#")):
            nxt += 1
        if nxt >= len(lines):
            failures.append((None, kind))
            break
        failures.append((nxt + 1, kind, decode_case(lines[nxt])))
        resume = nxt + 2
    r = subprocess.run(shlex.split(rust_cmd) + [work], capture_output=True, check=True)
    rb, pb = blocks(r.stdout.decode()), blocks(pion_out)
    mism = []
    field_count = {}
    crashed = {fl[0] for fl in failures}
    for idx in sorted(rb):
        a, b = rb[idx], pb.get(idx)
        if idx in crashed:
            continue
        if a == b:
            continue
        fields = []
        if b is None:
            fields = ["<pion crashed/hung>"]
        else:
            am = dict(l.split("=", 1) for l in a if "=" in l)
            bm = dict(l.split("=", 1) for l in b if "=" in l)
            for k in list(am) + [k for k in bm if k not in am]:
                if am.get(k) != bm.get(k):
                    fields.append(k)
        for k in fields:
            field_count[k] = field_count.get(k, 0) + 1
        mism.append((idx, fields, a, b))
    with open(prefix + ".mismatch.txt", "w", encoding="utf-8") as f:
        for fl in failures:
            f.write(f"!! {fl[1]} at line {fl[0]}: {fl[2] if len(fl) > 2 else ''}\n")
        for idx, fields, a, b in mism:
            f.write(f"== line {idx}: {decode_case(lines[idx - 1])}\n   fields: {fields}\n")
            for l in a:
                f.write(f"   rust {l}\n")
            for l in (b or []):
                f.write(f"   pion {l}\n")
    total = len([l for l in lines if l and not l.startswith("#")])
    print(json.dumps({"cases": total, "crashes_or_hangs": len(failures),
                      "mismatched_cases": len(mism), "fields": field_count}))


if __name__ == "__main__":
    main()
