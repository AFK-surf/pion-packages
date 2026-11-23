#!/usr/bin/env python3
"""Differential driver: Pion `webp_audit digest` vs Go `webpdiff digest` (golang.org/x/image/webp), with
libwebp (`webpdiff ref`: dwebp verdict/alpha, lossy RGB through Go's YCbCr->RGB) as the tie-breaker.

usage: compare.py <strict|fuzz> <dir> <webpdiff> <pion_cmd...>

Every line is "<file> OK <w> <h> <sha256(RGBA8888)>" or "<file> ERR <reason>".
A Pion result is CORRECT when it equals Go's, or equals libwebp's (the two references disagree with each
other on some malformed inputs); an ERR is correct when either reference also rejects the input.
strict: generated corpus; additionally every non-random input must be accepted by Go.
fuzz:   mutated inputs; "Pion OK while both references reject" is counted as leniency, not a failure.
FAIL on: Pion crash / panic / timeout, or a result that matches neither reference. Exit 1 on any FAIL.
"""
import collections
import glob
import os
import subprocess
import sys


def abort_msg(stderr, rc):
    """First `pion panic` line (native and wasm runtimes word it differently), else the last stderr line."""
    lines = stderr.strip().splitlines()
    for ln in lines:
        if "pion panic" in ln:
            return ln.strip()
    return lines[-1].strip() if lines else "rc=%d" % rc

CHUNK = 500
TIMEOUT = 300


def parse(stdout, files):
    out = {}
    for line in stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2 and parts[0] in files:
            out[parts[0]] = parts[1].strip()
    return out


def run(cmd, files):
    out = {}
    for i in range(0, len(files), CHUNK):
        chunk = files[i:i + CHUNK]
        r = subprocess.run(cmd + chunk, capture_output=True, text=True, timeout=TIMEOUT)
        out.update(parse(r.stdout, set(chunk)))
    return out


def pion_digest(cmd, files):
    """Lines are printed (and flushed) in order, so after an abort the next file is the culprit: record
    it as CRASH and resume after it. A run that exceeds the timeout marks the next file as a hang."""
    res = {}
    pending = list(files)
    while pending:
        chunk = pending[:CHUNK]
        try:
            r = subprocess.run(cmd + chunk, capture_output=True, text=True, timeout=TIMEOUT)
            stdout, rc, err = r.stdout, r.returncode, r.stderr
        except subprocess.TimeoutExpired as e:
            stdout = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
            rc, err = -9, "timeout %ds" % TIMEOUT
        got = parse(stdout, set(chunk))
        res.update(got)
        done = 0
        while done < len(chunk) and chunk[done] in got:
            done += 1
        if done == len(chunk) and rc == 0:
            pending = pending[len(chunk):]
            continue
        if done < len(chunk):
            msg = abort_msg(err, rc)
            res[chunk[done]] = "CRASH " + msg[:120]
            done += 1
        pending = pending[done:]
    return res


def is_ok(v):
    return v.startswith("OK")


def main():
    mode, d, go_bin = sys.argv[1], sys.argv[2], sys.argv[3]
    pion_cmd = sys.argv[4:]
    files = sorted(glob.glob(os.path.join(d, "*.webp")))
    go = run([go_bin, "digest"], files)
    pi = pion_digest(pion_cmd, files)
    dump = os.environ.get("COMPARE_DUMP")
    if dump:
        with open(dump, "w") as fh:
            for f in files:
                v = pi.get(f, "MISSING")
                # abort messages are worded differently by the native and wasm runtimes
                fh.write("%s %s\n" % (os.path.basename(f), "CRASH" if v.startswith("CRASH") else v))
    need_ref = [f for f in files if not pi.get(f, "").startswith("CRASH")
                and (go.get(f) != pi.get(f)) and (is_ok(go.get(f, "")) or is_ok(pi.get(f, "")))]
    ref = run([go_bin, "ref"], need_ref) if need_ref else {}
    stats = collections.Counter()
    fails = []
    for f in files:
        g, p, l = go.get(f, "MISSING"), pi.get(f, "MISSING"), ref.get(f, "")
        base = os.path.basename(f)
        if p.startswith("CRASH") or p == "MISSING":
            stats["pion_crash"] += 1
            fails.append((base, "pion crash: " + p, g))
            continue
        if mode == "strict" and not base.startswith(("rvp8_", "rvp8l_", "ralph_")) and not is_ok(g):
            fails.append((base, "go rejected a corpus input", g))
            continue
        if is_ok(g) and g == p:
            stats["identical_to_go"] += 1
        elif not is_ok(g) and not is_ok(p):
            stats["both_reject"] += 1
        elif is_ok(p) and p == l:
            stats["pion==libwebp (go differs)"] += 1
        elif not is_ok(p) and l and not is_ok(l):
            stats["pion,libwebp reject (go accepts)"] += 1
        elif is_ok(p) and not is_ok(g) and l and not is_ok(l):
            stats["lenient (both refs reject)"] += 1
            if mode == "strict":
                fails.append((base, "pion accepts what go and libwebp reject", g))
        else:
            kind = "both_ok_DIFFERENT" if is_ok(p) and is_ok(g) else ("pion_rejects" if is_ok(g) else "pion_accepts")
            stats[kind] += 1
            fails.append((base, "%s pion=%s" % (kind, p[:60]), "go=%s libwebp=%s" % (g[:60], l[:60])))
    print("  inputs: %d" % len(files))
    for k in sorted(stats):
        print("  %-34s %d" % (k, stats[k]))
    for f, why, g in fails[:30]:
        print("  FAIL %s :: %s :: %s" % (f, why, g))
    if len(fails) > 30:
        print("  ... %d more failures" % (len(fails) - 30))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
