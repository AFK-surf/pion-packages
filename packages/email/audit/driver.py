#!/usr/bin/env python3
"""Red-team audit driver for packages/email (invoked by run_audit.sh).

Runs the Pion probe in the 4 build modes, checks byte-identical output, cross-verifies
Pion-signed DKIM messages with go-msgauth, prints the oracle comparison tables, runs the
DoS probes in every mode, checks mbox linear scaling, then prints a PASS/FAIL summary.
Exit 0 only when no check FAILs.
"""
import hashlib
import os
import subprocess
import sys
import time

AUDIT_DIR = os.environ["AUDIT_DIR"]
OUT = os.environ["AUDIT_OUT"]
BIN = os.environ["BIN"]
WASM_RT = os.environ["WASM_RT"]
CASES = os.path.join(AUDIT_DIR, "cases")
FX = os.path.join(OUT, "fx")
NL = b"\n"
MODES = ["native_dbg", "native_rel", "wasm_dbg", "wasm_rel"]

results = []  # (status, id, sev, title, observed)


def cmd_for(mode, args):
    if mode.startswith("wasm"):
        return ["node", "--stack-size=984", WASM_RT, os.path.join(BIN, mode + ".wasm")] + args
    return [os.path.join(BIN, mode)] + args


def run(mode, args, timeout):
    t0 = time.time()
    try:
        p = subprocess.run(cmd_for(mode, args), capture_output=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr, time.time() - t0
    except subprocess.TimeoutExpired:
        return "TIMEOUT", b"", b"", time.time() - t0


def add(status, cid, sev, title, observed=""):
    results.append((status, cid, sev, title, observed))
    line = f"{status} {cid} {sev} {title}"
    if status == "FAIL" and observed:
        line += f" :: {observed}"
    print("  " + line)


def crash_desc(rc, err):
    tail = err.decode("utf-8", "replace").strip().splitlines()
    msg = next((l for l in tail if "Error" in l or "panic" in l or "abort" in l), tail[-1] if tail else "")
    if isinstance(rc, int) and rc < 0:
        return f"signal {-rc} {msg[:80]}"
    return f"rc={rc} {msg[:80]}"


# ---------------------------------------------------------------- 4-mode suite
print("==> [4/6] suite: 4-mode run of `email_audit all`")
outs = {}
for m in MODES:
    od = os.path.join(OUT, "modes", m)
    os.makedirs(od, exist_ok=True)
    rc, so, se, dt = run(m, ["all", CASES, FX, od], 600)
    open(os.path.join(OUT, f"suite_{m}.txt"), "wb").write(so)
    ok = rc == 0 and so.rstrip().endswith(b"END")
    print(f"  {m:10s} rc={rc} {dt:6.2f}s sha256={hashlib.sha256(so).hexdigest()[:16]} lines={so.count(NL)}")
    if not ok:
        add("FAIL", f"suite_{m}_completes", "P0", f"probe completes in {m}", crash_desc(rc, se))
    outs[m] = so

primary = outs.get("native_rel", b"")
for line in primary.decode("utf-8", "replace").splitlines():
    if line.startswith("PASS ") or line.startswith("FAIL "):
        st, rest = line.split(" ", 1)
        cid, sev, rest = rest.split(" ", 2)
        title, _, obs = rest.partition(" :: ")
        results.append((st, cid, sev, title, obs))
    elif line.startswith("INFO "):
        results.append(("INFO", line.split(" ")[1], "-", line[5:], ""))
    elif line.startswith("HARNESS"):
        print("  " + line)
        sys.exit(2)

hashes = {m: hashlib.sha256(outs[m]).hexdigest() for m in MODES}
same = len(set(hashes.values())) == 1
add("PASS" if same else "FAIL", "wasm4_suite_stdout_identical", "P1",
    "suite stdout byte-identical across native_dbg/native_rel/wasm_dbg/wasm_rel",
    "" if same else " ".join(f"{m}={h[:12]}" for m, h in hashes.items()))


def tree_hash(d):
    h = hashlib.sha256()
    for n in sorted(os.listdir(d)):
        h.update(n.encode() + b"\0" + open(os.path.join(d, n), "rb").read())
    return h.hexdigest()


th = {m: tree_hash(os.path.join(OUT, "modes", m)) for m in MODES}
same = len(set(th.values())) == 1
add("PASS" if same else "FAIL", "wasm4_signed_bytes_identical", "P1",
    "DKIM-signed output bytes identical across the 4 modes",
    "" if same else " ".join(f"{m}={h[:12]}" for m, h in th.items()))

# ---------------------------------------------------------------- go-msgauth verification
print("==> [5/6] go-msgauth v0.7.0 verifies Pion-signed messages")
p = subprocess.run([os.path.join(BIN, "go_oracle"), "verify", os.path.join(OUT, "modes", "native_rel")],
                   capture_output=True, text=True)
gov = dict(l.split("\t", 1) for l in p.stdout.splitlines() if "\t" in l)
signed = {k: v for k, v in gov.items() if not k.startswith("pion_atk_")}
bad = [f"{k}: {v}" for k, v in signed.items() if v != "PASS"]
add("PASS" if signed and not bad else "FAIL", "dkim_interop_pion_to_go", "P0",
    f"go-msgauth verifies all {len(signed)} Pion-signed messages (ed25519 + rsa-2048, 4 canon x 6 bodies)",
    "; ".join(bad[:3]) or "no Pion-signed messages produced")
for k, v in sorted(gov.items()):
    if k.startswith("pion_atk_"):
        print(f"  INFO go-msgauth on {k}: {v}")

# ---------------------------------------------------------------- oracle tables
print("==> oracle comparison (expected = RFC; INFO only, verdicts come from the suite above)")
pion_out = {}
for line in primary.decode("utf-8", "replace").splitlines():
    if line.startswith("OUT "):
        parts = line[4:].split("\t")
        if len(parts) == 3:
            pion_out[(parts[0], parts[1])] = parts[2]


def oracle(binname, mode, path):
    if binname is None:
        return {}
    p = subprocess.run([os.path.join(BIN, binname), mode, path], capture_output=True, text=True)
    return dict(l.split("\t", 1) for l in p.stdout.splitlines() if "\t" in l)


def load_expected(fn):
    rows = []
    for l in open(os.path.join(CASES, fn), encoding="utf-8"):
        l = l.rstrip("\n")
        if not l or l.startswith("#"):
            continue
        c = l.split("\t")
        rows.append((c[0], c[1], c[2]))
    return rows


for set_name, fn, go_mode, rust_mode, path in [
    ("addr", "addr.tsv", "addr", "addr", os.path.join(CASES, "addr.tsv")),
    ("date", "date.tsv", "date", "date", os.path.join(CASES, "date.tsv")),
    ("rfc2047", "rfc2047.tsv", None, "subj", os.path.join(CASES, "rfc2047.tsv")),
    ("mime", "mime_expected.tsv", None, "mime", os.path.join(CASES, "mime")),
]:
    go = oracle("go_oracle", go_mode, path) if go_mode else {}
    ru = oracle("rust_oracle", rust_mode, path)
    rows = load_expected(fn)
    agree_go = sum(1 for i, _, e in rows if e != "*" and go.get(i) == e)
    agree_ru = sum(1 for i, _, e in rows if e != "*" and ru.get(i) == e)
    agree_pi = sum(1 for i, _, e in rows if e != "*" and pion_out.get((set_name, i)) == e)
    n = sum(1 for r in rows if r[2] != "*")
    print(f"  [{set_name}] matches RFC expectation: pion {agree_pi}/{n}"
          + (f", go net/mail {agree_go}/{n}" if go_mode else "") + f", rust mail-parser {agree_ru}/{n}")
    for i, inp, e in rows:
        pv = pion_out.get((set_name, i), "<missing>")
        if pv != e and e != "*":
            print(f"    {i}: expected [{e}]")
            print(f"    {'':{len(i)}}  pion     [{pv}]")
            if go_mode:
                print(f"    {'':{len(i)}}  go       [{go.get(i, '-')}]")
            print(f"    {'':{len(i)}}  rust     [{ru.get(i, '-')}]")

# ---------------------------------------------------------------- DoS probes
print("==> [6/6] DoS probes x 4 modes (must return Err/Ok gracefully: no SIGSEGV/SIGABRT/RangeError/trap/OOM)")
DOS = [
    # name, expected stdout prefix, severity, budget seconds (native / wasm)
    ("mp_deep_2000", "DOS mp_deep_2000 ERR LimitExceeded", "P0", 10, 60),
    ("rfc822_deep_2000", "DOS rfc822_deep_2000 ERR LimitExceeded", "P0", 10, 60),
    ("headers_10k", "DOS headers_10k ERR LimitExceeded", "P0", 10, 60),
    ("parts_10k", "DOS parts_10k ERR", "P0", 10, 60),
    ("header_1mib", "DOS header_1mib ERR LimitExceeded", "P0", 10, 60),
    ("addr_comment_10k", "DOS addr_comment_10k ERR", "P0", 10, 60),
    ("date_comment_10k", "DOS date_comment_10k ERR", "P0", 10, 60),
    ("addr_list_100k", "DOS addr_list_100k OK 100000", "P1", 10, 60),
    ("rfc2047_6k_words", "DOS rfc2047_6k_words OK", "P1", 10, 60),
    ("dkim_h_40k", "DOS dkim_h_40k ERR", "P1", 10, 60),
    ("rfc822_deep_1000_raised_limit", "DOS rfc822_deep_1000_raised_limit ", "P2", 20, 120),
    ("rfc822_deep_20000_raised_limit", "DOS rfc822_deep_20000_raised_limit ", "P2", 60, 300),
]
for name, want, sev, nb, wb in DOS:
    obs = []
    ok = True
    for m in MODES:
        budget = wb if m.startswith("wasm") else nb
        rc, so, se, dt = run(m, ["dos", name], budget * 2)
        out = so.decode("utf-8", "replace").strip()
        good = rc == 0 and out.startswith(want) and dt <= budget
        if not good:
            ok = False
            obs.append(f"{m}: " + (f"{out} {dt:.1f}s>budget" if rc == 0 and out.startswith(want) else
                                   (f"unexpected [{out}]" if rc == 0 else crash_desc(rc, se))))
        print(f"    {name:32s} {m:10s} {dt:7.2f}s rc={rc} {out[:60]}")
    add("PASS" if ok else "FAIL", f"dos_{name}", sev, f"{name}: graceful in all 4 modes", "; ".join(obs))

# mbox linear complexity: 10x the input must cost < 20x the time (native release)
ts = {}
for n in (50000, 500000):
    best = None
    for _ in range(3):
        rc, so, se, dt = run("native_rel", ["mbox-scale", str(n)], 120)
        if rc != 0 or not so.startswith(f"MBOX {n}".encode()):
            best = None
            break
        best = dt if best is None else min(best, dt)
    ts[n] = best
if ts[50000] and ts[500000]:
    ratio = ts[500000] / max(ts[50000], 1e-3)
    add("PASS" if ratio < 20 else "FAIL", "mbox_linear_scaling", "P1",
        f"mbox 50k->500k messages scales linearly ({ts[50000]:.3f}s -> {ts[500000]:.3f}s, x{ratio:.1f})",
        f"x{ratio:.1f}")
else:
    add("FAIL", "mbox_linear_scaling", "P1", "mbox-scale probe ran", "probe failed")

# ---------------------------------------------------------------- summary
print("")
print("================ SUMMARY ================")
fails = [r for r in results if r[0] == "FAIL"]
passes = [r for r in results if r[0] == "PASS"]
infos = [r for r in results if r[0] == "INFO"]
for sev in ("P0", "P1", "P2"):
    fs = [r for r in fails if r[2] == sev]
    print(f"{sev}: {len(fs)} FAIL")
    for r in fs:
        print(f"  FAIL {r[1]}  {r[3]}" + (f"  :: {r[4][:160]}" if r[4] else ""))
print(f"TOTAL: {len(passes)} PASS, {len(fails)} FAIL, {len(infos)} INFO")
print("RESULT: " + ("PASS (exit 0)" if not fails else "FAIL (exit 1)"))
sys.exit(1 if fails else 0)
