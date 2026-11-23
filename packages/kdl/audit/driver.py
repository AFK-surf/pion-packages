"""Red-team driver for packages/kdl (invoked by run_audit.sh; reads env set there).

Prints one verdict line per check:
  PASS <id> <sev> <title>
  FAIL <id> <sev> <title> :: <observed>
  INFO <id> <title> :: <observed>            (never affects the exit status)
Exit status: 0 = no FAIL, 1 = at least one FAIL, 2 = harness error.
"""
import hashlib
import os
import subprocess
import sys
import time

AUDIT_DIR = os.environ["AUDIT_DIR"]
AUDIT_OUT = os.environ["AUDIT_OUT"]
BIN = os.environ["BIN"]
WASM_RT = os.environ["WASM_RT"]
SPEC_DIR = os.environ["KDL_SPEC_DIR"]
RUST = os.path.join(BIN, "rust_oracle")
MODES = ["native_dbg", "native_rel", "wasm_dbg", "wasm_rel"]
sys.path.insert(0, AUDIT_DIR)
import cases  # noqa: E402

RESULTS = []


def add(status, cid, sev, title, obs=""):
    RESULTS.append(status)
    if status == "INFO":
        line = "INFO %s %s :: %s" % (cid, title, obs)
    elif status == "PASS":
        line = "PASS %s %s %s" % (cid, sev, title)
    else:
        line = "FAIL %s %s %s :: %s" % (cid, sev, title, obs)
    print(line, flush=True)


def harness(msg):
    print("HARNESS ERROR: " + msg, flush=True)
    sys.exit(2)


def cmd(mode, args):
    if mode.startswith("wasm"):
        return ["node", "--stack-size=984", WASM_RT, os.path.join(BIN, mode + ".wasm")] + args
    return [os.path.join(BIN, mode)] + args


def run(argv, timeout):
    t0 = time.time()
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        return p.returncode, p.stdout, p.stderr, time.time() - t0
    except subprocess.TimeoutExpired:
        return "timeout", b"", b"", time.time() - t0


def short(s, n=220):
    s = s if isinstance(s, str) else s.decode("utf-8", "replace")
    return s if len(s) <= n else s[:n] + "..."


def parse_dump(text):
    """-> {id: {"P": (status, payload), "FMT": status, "CMP": status}}"""
    out = {}
    for line in text.decode("utf-8", "replace").split("\n"):
        if not line:
            continue
        f = line.split("\t")
        d = out.setdefault(f[0], {})
        if f[1] in ("FMT", "CMP"):
            d[f[1]] = f[2] if len(f) > 2 else ""
        else:
            d["P"] = (f[1], f[2] if len(f) > 2 else "")
    return out


# ------------------------------------------------------------------ corpus
CORPUS = os.path.join(AUDIT_OUT, "corpus")
os.makedirs(CORPUS, exist_ok=True)
off_in = os.path.join(SPEC_DIR, "tests", "test_cases", "input")
off_exp = os.path.join(SPEC_DIR, "tests", "test_cases", "expected_kdl")
if not os.path.isdir(off_in):
    harness("official KDL test suite not found at " + off_in)
OFFICIAL = sorted(f[:-4] for f in os.listdir(off_in) if f.endswith(".kdl"))

v2_rows = []  # (id, path)
v1_rows = []
for b in OFFICIAL:
    v2_rows.append(("off/" + b, os.path.join(off_in, b + ".kdl")))
custom_meta = {}


def write_case(cid, src):
    p = os.path.join(CORPUS, cid.replace("/", "__") + ".kdl")
    with open(p, "wb") as fh:
        fh.write(src if isinstance(src, bytes) else src.encode("utf-8"))
    return p


for c in cases.CASES:
    cid = "case/" + c[0]
    custom_meta[cid] = c
    v2_rows.append((cid, write_case(cid, c[3])))
for c in cases.FMT_CASES:
    cid = "fmt/" + c[0]
    custom_meta[cid] = c
    v2_rows.append((cid, write_case(cid, c[3])))
for c in cases.V1_CASES:
    cid = "v1/" + c[0]
    custom_meta[cid] = c
    v1_rows.append((cid, write_case(cid, c[3])))


def write_list(name, rows, mode, fmt_dir=None):
    p = os.path.join(AUDIT_OUT, name)
    with open(p, "w", encoding="utf-8") as fh:
        for cid, path in rows:
            pre = os.path.join(fmt_dir, cid.replace("/", "__")) if fmt_dir else ""
            fh.write("%s\t%s\t%s\t%s\n" % (cid, mode, path, pre))
    return p


# ------------------------------------------------------------------ Rust oracle
rust_rows = [(cid, "v2", p) for cid, p in v2_rows]
rust_rows += [("exp/" + b, "v2", os.path.join(off_exp, b + ".kdl")) for b in OFFICIAL
              if os.path.exists(os.path.join(off_exp, b + ".kdl"))]
rust_rows += [(cid, "v1", p) for cid, p in v1_rows]
rl = os.path.join(AUDIT_OUT, "rust.list")
with open(rl, "w", encoding="utf-8") as fh:
    for cid, m, p in rust_rows:
        fh.write("%s\t%s\t%s\n" % (cid, m, p))
rc, rout, rerr, _ = run([RUST, "dump", rl], 600)
if rc != 0:
    harness("rust oracle failed: " + short(rerr))
RUSTR = parse_dump(rout)

# ------------------------------------------------------------------ Pion, 4 modes
dump_out = {}
for m in MODES:
    fdir = os.path.join(AUDIT_OUT, "modes", m, "fmt")
    os.makedirs(fdir, exist_ok=True)
    lst = write_list("pion_v2_%s.list" % m, v2_rows, "v2", fdir)
    with open(lst, "a", encoding="utf-8") as fh:
        for cid, p in v1_rows:
            fh.write("%s\tv1\t%s\t\n" % (cid, p))
    rc, out, err, dt = run(cmd(m, ["dump", lst]), 900)
    if rc != 0:
        harness("pion %s dump failed rc=%s: %s" % (m, rc, short(err)))
    dump_out[m] = out
    with open(os.path.join(AUDIT_OUT, "modes", m, "dump.txt"), "wb") as fh:
        fh.write(out)
P = parse_dump(dump_out["native_rel"])


def pion(cid):
    return P.get(cid, {}).get("P", ("MISSING", ""))


def rust(cid):
    return RUSTR.get(cid, {}).get("P", ("MISSING", ""))


# ------------------------------------------------------------------ Rust re-parse of Pion's formatter output
fmt_dir = os.path.join(AUDIT_OUT, "modes", "native_rel", "fmt")
fl = os.path.join(AUDIT_OUT, "rust_fmt.list")
fmt_ids = []
with open(fl, "w", encoding="utf-8") as fh:
    for cid, _ in v2_rows:
        base = os.path.join(fmt_dir, cid.replace("/", "__"))
        for kind in ("fmt", "cmp"):
            fp = base + "." + kind + ".kdl"
            if os.path.exists(fp):
                fh.write("%s#%s\tv2\t%s\n" % (cid, kind, fp))
                fmt_ids.append(cid)
rc, rfo, rerr, _ = run([RUST, "dump", fl], 600)
if rc != 0:
    harness("rust oracle (fmt) failed: " + short(rerr))
RUSTF = parse_dump(rfo)


def roundtrip_checks(cid, sev, title):
    """Pion self round-trip (format + compact) and Rust acceptance of Pion's output."""
    st, canon = pion(cid)
    if st != "OK":
        return
    bad = []
    for kind, key in (("fmt", "FMT"), ("cmp", "CMP")):
        s = P.get(cid, {}).get(key, "MISSING")
        if s != "same":
            bad.append("pion %s round-trip: %s" % (kind, short(s, 160)))
        r = RUSTF.get(cid + "#" + kind, {}).get("P", ("MISSING", ""))
        if r[0] != "OK":
            bad.append("rust rejects pion %s output" % kind)
        elif r[1] != canon:
            bad.append("rust reads pion %s output as %s (pion canon %s)" % (kind, short(r[1], 120), short(canon, 120)))
    add("FAIL" if bad else "PASS", "rt_" + cid.replace("/", "_"), sev, "format/format_compact round-trip: " + title,
        "; ".join(bad))


# ------------------------------------------------------------------ 1. official KDL 2.0.0 suite
print("==> [A] official KDL 2.0.0 test suite (%d cases, kdl-org/kdl @ 2.0.0) vs Pion and Rust kdl 6.7.1" % len(OFFICIAL))
n_ok = 0
rust_dev = []
for b in OFFICIAL:
    cid = "off/" + b
    valid = os.path.exists(os.path.join(off_exp, b + ".kdl"))
    st, canon = pion(cid)
    rst, rcanon = rust(cid)
    if valid:
        est, ecanon = rust("exp/" + b)
        if est != "OK":
            harness("rust cannot parse expected_kdl/%s.kdl" % b)
        if rst != "OK" or rcanon != ecanon:
            rust_dev.append(b)
        if st == "OK" and canon == ecanon:
            n_ok += 1
            add("PASS", cid.replace("/", "_"), "P1", "official valid case")
        else:
            sev = "P2" if b.startswith(("hex", "vertical_tab")) else "P1"
            add("FAIL", cid.replace("/", "_"), sev, "official valid case",
                "pion=%s %s expected=%s" % (st, short(canon, 120), short(ecanon, 120)))
    else:
        if rst == "OK":
            rust_dev.append(b)
        if st == "ERR":
            n_ok += 1
            add("PASS", cid.replace("/", "_"), "P1", "official invalid case rejected")
        else:
            add("FAIL", cid.replace("/", "_"), "P0", "official invalid case rejected", "pion accepted: " + short(canon))
add("INFO", "official_suite_score", "", "pion %d/%d official cases; rust kdl 6.7.1 deviates on %d: %s" % (
    n_ok, len(OFFICIAL), len(rust_dev), ", ".join(rust_dev)))
for b in OFFICIAL:
    if os.path.exists(os.path.join(off_exp, b + ".kdl")):
        roundtrip_checks("off/" + b, "P1", "official " + b)

# ------------------------------------------------------------------ 2. hand-written adversarial cases
print("==> [B] adversarial v2 cases (spec grammar; Rust shown for reference)")
for c in cases.CASES:
    cid = "case/" + c[0]
    sev, title, expect = c[1], c[2], c[4]
    want = c[5] if len(c) > 5 else None
    st, canon = pion(cid)
    rst, rcanon = rust(cid)
    ref = "rust=%s%s" % (rst, (" " + short(rcanon, 100)) if rst == "OK" else "")
    if expect == "err":
        ok = st == "ERR"
        obs = "pion accepted: %s | %s" % (short(canon, 140), ref)
    else:
        if want is not None:
            ok = st == "OK" and canon == want
            obs = "pion=%s %s want=%s | %s" % (st, short(canon, 140), short(want, 100), ref)
        else:
            ok = st == "OK" and (rst != "OK" or canon == rcanon)
            obs = "pion=%s %s | %s" % (st, short(canon, 140), ref)
    add("PASS" if ok else "FAIL", cid.replace("/", "_"), sev, title, obs)
    if expect == "ok":
        roundtrip_checks(cid, "P1", c[0])

print("==> [C] formatter-hostile values (format/format_compact must re-parse to the same AST in Pion and Rust)")
for c in cases.FMT_CASES:
    cid = "fmt/" + c[0]
    st, canon = pion(cid)
    if st != "OK":
        add("FAIL", cid.replace("/", "_"), c[1], "fixture parses: " + c[2], "pion=%s %s" % (st, canon))
        continue
    rst, rcanon = rust(cid)
    if rst == "OK" and rcanon != canon:
        add("FAIL", cid.replace("/", "_") + "_vs_rust", c[1], "parse agrees with Rust: " + c[2],
            "pion %s | rust %s" % (short(canon, 160), short(rcanon, 160)))
    roundtrip_checks(cid, c[1], c[2])

print("==> [D] KDL v1 compatibility (parse_v1 vs Rust kdl 6.7.1 parse_v1 / kdl 4.7.1)")
for c in cases.V1_CASES:
    cid = "v1/" + c[0]
    sev, title, expect = c[1], c[2], c[4]
    want = c[5] if len(c) > 5 else None
    st, canon = pion(cid)
    rst, rcanon = rust(cid)
    ref = "rust=%s%s" % (rst, (" " + short(rcanon, 100)) if rst == "OK" else "")
    if expect == "err":
        ok = st == "ERR"
    elif want is not None:
        ok = st == "OK" and canon == want
    else:
        ok = st == "OK" and (rst != "OK" or canon == rcanon)
    add("PASS" if ok else "FAIL", cid.replace("/", "_"), sev, title,
        "pion=%s %s want=%s | %s" % (st, short(canon, 120), expect if want is None else short(want, 80), ref))

# ------------------------------------------------------------------ 3. query engine
print("==> [E] query engine (README grammar + KQL QUERY-SPEC; no Rust oracle: kdl 6.7.1 ships its query API disabled)")
qrows = []
for c in cases.Q_CASES:
    p = write_case("q_" + c[0], c[3])
    qrows.append("%s\t%s\t%s" % (c[0], p, c[4]))
ql = os.path.join(AUDIT_OUT, "query.list")
with open(ql, "w", encoding="utf-8") as fh:
    fh.write("\n".join(qrows) + "\n")
q_out = {}
for m in MODES:
    rc, out, err, _ = run(cmd(m, ["query", ql]), 300)
    if rc != 0:
        harness("pion %s query failed rc=%s: %s" % (m, rc, short(err)))
    q_out[m] = out
QR = {}
for line in q_out["native_rel"].decode("utf-8", "replace").split("\n"):
    if line:
        f = line.split("\t")
        QR[f[0]] = "ERR" if f[1] == "ERR" else f[2] + "\t" + f[3]
for c in cases.Q_CASES:
    got = QR.get(c[0], "MISSING")
    ok = got == c[5] or (c[5] == "ERR" and got.startswith("ERR"))
    if c[1] == "INFO":
        add("INFO", "q_" + c[0], "", c[2] + " (not claimed by README; feature gap)", "got=%r kql=%r" % (got, c[5]))
    else:
        add("PASS" if ok else "FAIL", "q_" + c[0], c[1], c[2], "got=%r want=%r" % (got, c[5]))

# ------------------------------------------------------------------ 4. API-level checks
print("==> [F] API-level checks")
api_out = {}
for m in MODES:
    rc, out, err, _ = run(cmd(m, ["api"]), 120)
    if rc != 0:
        harness("pion %s api failed rc=%s: %s" % (m, rc, short(err)))
    api_out[m] = out
for line in api_out["native_rel"].decode("utf-8", "replace").split("\n"):
    if line.startswith(("PASS ", "FAIL ")):
        print(line, flush=True)
        RESULTS.append(line.split(" ")[0])

# ------------------------------------------------------------------ 5. DoS / stack probes in 4 modes
print("==> [G] DoS / deep-nesting probes (4 modes, wall-clock budgets)")
# (case, n, expected stdout, sev, native budget s, wasm budget s, title)
DOS = [
    ("deep_children", 20000, "deep_children OK depth=20000 cmp_len=59998 equals=true query=20000 compact_reparse=same",
     "P0", 10, 60, "20,000-deep children with max_depth raised: parse/compact/equals/query/drop without SIGSEGV or RangeError"),
    ("deep_children_default", 20000, "deep_children_default ERR LimitExceeded", "P0", 5, 20,
     "20,000-deep children rejected by default max_depth=128"),
    ("deep_children_unlimited", 200000, "deep_children_unlimited OK nodes=1 depth=200000", "P0", 10, 60,
     "200,000-deep children with KdlLimits(0,0,0): no recursion anywhere (incl. drop)"),
    ("deep_slashdash_children", 20000, "deep_slashdash_children OK nodes=1 depth=1", "P0", 5, 30,
     "20,000-deep slashdashed children block"),
    ("deep_format", 3000, "deep_format OK fmt_len=35994000 reparse=same", "P1", 10, 60,
     "pretty format of 3,000-deep tree (output is O(depth^2) indentation)"),
    ("deep_block_comment", 100000, "deep_block_comment OK nodes=1 depth=1", "P0", 5, 20,
     "100,000 nested block comments"),
    ("deep_block_comment_unclosed", 100000, "deep_block_comment_unclosed ERR UnterminatedComment", "P0", 5, 20,
     "100,000 nested block comments, one unclosed"),
    ("slashdash_run", 100000, "slashdash_run OK nodes=1 depth=1", "P1", 5, 20, "100,000 slashdashed arguments"),
    ("wide_args", 100000, "wide_args OK entries=100000", "P1", 5, 20, "100,000 arguments on one node"),
    ("wide_props", 100000, "wide_props OK entries=100000", "P1", 2, 10,
     "100,000 distinct properties on one node (duplicate-key bookkeeping must not be O(n^2))"),
    ("wide_doc", 1000000, "wide_doc OK nodes=1000000 depth=1", "P1", 10, 30, "1,000,000 top-level nodes"),
    ("raw_hashes", 10000, "raw_hashes OK len=80000", "P1", 5, 20, "raw string with 10,000 `#` and near-miss closers"),
    ("multiline_lines", 100000, "multiline_lines OK len=1099999", "P1", 5, 20, "100,000-line multi-line string"),
    ("long_float", 100000, "long_float OK nodes=1 depth=1", "P1", 5, 20, "100,000-digit float literal"),
    ("long_int_digits", 100000, "long_int_digits OK nodes=1 depth=1", "P1", 5, 20, "100,000 leading zeros integer"),
    ("query_dup_explosion", 24, "query_dup_explosion OK count=17 expected=17", "P0", 5, 20,
     "8-step descendant query on a 24-deep chain returns each node once"),
    ("query_dup_explosion", 40, "query_dup_explosion OK count=33 expected=33", "P0", 5, 20,
     "8-step descendant query on a 40-deep chain finishes quickly (no combinatorial blow-up)"),
]
dos_stdout = {m: [] for m in MODES}
dos_complete = []
for case, n, want, sev, nb, wb, title in DOS:
    obs = []
    for m in MODES:
        budget = wb if m.startswith("wasm") else nb
        rc, out, err, dt = run(cmd(m, ["dos", case, str(n)]), max(budget * 3, 30))
        got = out.decode("utf-8", "replace").strip()
        dos_stdout[m].append(got)
        if rc != 0:
            obs.append("%s rc=%s %s" % (m, rc, short(err.decode("utf-8", "replace").strip().split("\n")[-1] if err else "", 120)))
        elif got != want:
            obs.append("%s got %r (%.2fs)" % (m, short(got, 120), dt))
        elif dt > budget:
            obs.append("%s %.2fs > %ds budget" % (m, dt, budget))
        else:
            obs.append("%s ok %.2fs" % (m, dt))
    bad = [o for o in obs if " ok " not in o]
    dos_complete.append(not any(" rc=" in o for o in obs))
    add("FAIL" if bad else "PASS", "dos_%s_%d" % (case, n), sev, title, "; ".join(obs))

# Rust timing reference for the wide-props input (parse only).
wp = os.path.join(CORPUS, "wide_props_100k.kdl")
with open(wp, "w") as fh:
    fh.write("node" + "".join(" k%d=1" % i for i in range(100000)) + "\n")
wl = os.path.join(AUDIT_OUT, "wide.list")
with open(wl, "w") as fh:
    fh.write("w\tv2\t%s\n" % wp)
rc, out, err, dt = run([RUST, "count", wl], 120)
add("INFO", "rust_wide_props_100k", "", "Rust kdl 6.7.1 parses the same 100,000-property node", "%.2fs %s" % (dt, short(out.strip())))

# ------------------------------------------------------------------ 5b. float parsing vs correctly rounded strtod
print("==> [G2] 20,000 generated decimal floats vs Python float() (correctly rounded), 4 modes")
import random  # noqa: E402
import struct  # noqa: E402

rnd = random.Random(20261124)
nums = []
while len(nums) < 20000:
    k = rnd.random()
    if k < 0.3:
        ip = str(rnd.randint(0, 10 ** rnd.randint(0, 25)))
        s = ip + "." + "".join(rnd.choice("0123456789") for _ in range(rnd.randint(1, 40)))
        if rnd.random() < 0.6:
            s += "e" + rnd.choice(["", "+", "-"]) + str(rnd.randint(0, 330))
    elif k < 0.5:
        s = "%.*e" % (rnd.randint(15, 24), rnd.uniform(-1, 1) * 10 ** rnd.randint(-320, 308))
    elif k < 0.7:
        x = struct.unpack("<d", struct.pack("<Q", rnd.getrandbits(64)))[0]
        if x != x or x in (float("inf"), float("-inf")):
            continue
        s = repr(x)
        if "e" not in s and "." not in s:
            s += ".0"
        if rnd.random() < 0.5 and s[-1].isdigit():
            s = s[:-1] + str((int(s[-1]) + 1) % 10)
    elif k < 0.85:
        s = str(rnd.randint(1, 9)) + "e" + str(rnd.randint(-400, 400))
    else:
        s = rnd.choice(["-", ""]) + "0." + "0" * rnd.randint(0, 330) + str(rnd.randint(1, 99999))
    if rnd.random() < 0.2 and s[0].isdigit():
        p = s.find(".")
        if p > 1:
            s = s[:1] + "_" + s[1:]
    nums.append(s)
nf = write_case("floats/fuzz", "".join("n %s\n" % x for x in nums))
nl = os.path.join(AUDIT_OUT, "floats.list")
with open(nl, "w") as fh:
    fh.write("floats\tv2\t%s\t\n" % nf)
want = ";".join('"n"[f%016x][]' % struct.unpack("<Q", struct.pack("<d", float(x.replace("_", ""))))[0] for x in nums)
fl_out = {}
for m in MODES:
    rc, out, err, _ = run(cmd(m, ["dump", nl]), 300)
    fl_out[m] = out
got = fl_out["native_rel"].decode().rstrip("\n").split("\t")
if len(got) < 3 or got[1] != "OK":
    add("FAIL", "float_fuzz_20000", "P1", "20,000 decimal floats parse bit-exactly", "pion=%s" % short(" ".join(got[1:]), 160))
else:
    g = got[2].split(";")
    w = want.split(";")
    bad = [(nums[i], g[i], w[i]) for i in range(len(w)) if g[i] != w[i]]
    add("FAIL" if bad else "PASS", "float_fuzz_20000", "P1", "20,000 decimal floats parse bit-exactly (correct rounding)",
        "%d mismatches, e.g. %r" % (len(bad), bad[:3]))
FLOAT_OUT = fl_out

# ------------------------------------------------------------------ 6. 4-mode byte identity
print("==> [H] 4-mode byte identity (native_dbg / native_rel / wasm_dbg / wasm_rel)")


def ident(label, blobs, sev="P1"):
    hs = {m: hashlib.sha256(b).hexdigest() for m, b in blobs.items()}
    same = len(set(hs.values())) == 1
    add("PASS" if same else "FAIL", "mode4_" + label, sev, label + " output byte-identical in 4 modes",
        " ".join("%s=%s" % (m, h[:16]) for m, h in hs.items()))
    return hs


h = ident("dump", dump_out)
ident("query", q_out)
ident("api", api_out)
ident("float_fuzz", FLOAT_OUT)
# DoS outputs are compared only for probes that finished in every mode (a timeout is reported above).
ident("dos", {m: "\n".join(x for x, done in zip(v, dos_complete) if done).encode() for m, v in dos_stdout.items()})
fmt_blobs = {}
for m in MODES:
    d = os.path.join(AUDIT_OUT, "modes", m, "fmt")
    hh = hashlib.sha256()
    for f in sorted(os.listdir(d)):
        hh.update(f.encode() + b"\0")
        with open(os.path.join(d, f), "rb") as fh:
            hh.update(fh.read())
    fmt_blobs[m] = hh.hexdigest().encode()
ident("format_files", fmt_blobs)
add("INFO", "dump_sha256", "", "native_rel dump stdout", h["native_rel"])

# ------------------------------------------------------------------ summary
n_fail = RESULTS.count("FAIL")
n_pass = RESULTS.count("PASS")
print("==> SUMMARY: %d PASS, %d FAIL" % (n_pass, n_fail))
sys.exit(1 if n_fail else 0)
