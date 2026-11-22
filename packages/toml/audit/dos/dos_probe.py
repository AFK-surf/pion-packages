#!/usr/bin/env python3
"""DoS / pathological-input probes: Pion vs Rust toml 1.2 vs Go BurntSushi.

For each input: exit status (139 = SIGSEGV), wall time, peak RSS. Inputs are generated here.
usage: dos_probe.py <workdir> [--quick]
env: AUDIT_BIN (dir with pion_cli, rust_ref, go_ref, hashdos_gen), DOS_TIMEOUT (s, default 60)
"""
import os, re, string, random, subprocess, sys, time

BIN = os.environ.get("AUDIT_BIN", "/tmp/pion-toml-audit/bin")
TIMEOUT = float(os.environ.get("DOS_TIMEOUT", "60"))
work = sys.argv[1]
quick = "--quick" in sys.argv
os.makedirs(work, exist_ok=True)
IMPLS = {"pion": f"{BIN}/pion_cli", "rust_toml_1.2": f"{BIN}/rust_ref", "go_burntsushi": f"{BIN}/go_ref"}


def measure(cmd):
    t = time.perf_counter()
    try:
        r = subprocess.run(["/usr/bin/time", "-l"] + cmd, capture_output=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return f"TIMEOUT>{TIMEOUT:.0f}s", "", ""
    dt = time.perf_counter() - t
    err = r.stderr.decode(errors="replace")
    m = re.search(r"(\d+)\s+maximum resident set size", err)
    rss = f"{int(m.group(1)) / 2**20:.0f}MiB" if m else "?"
    out = r.stdout.decode(errors="replace").strip().splitlines()
    verdict = out[0][:48] if out else ""
    rc = r.returncode
    status = "SIGSEGV(139)" if rc in (139, -11) or "Segmentation" in err else f"rc={rc}"
    return f"{status} {dt * 1000:9.1f}ms {rss:>7s}", verdict, err


def row(label, path, mode="errpos", impls=IMPLS):
    size = os.path.getsize(path)
    print(f"\n## {label}  ({size / 1024:.0f} KiB)")
    for name, b in impls.items():
        m, verdict, _ = measure([b, mode, path])
        print(f"   {name:14s} {m}  {verdict}")


def write(name, text):
    p = os.path.join(work, name)
    with open(p, "w") as f:
        f.write(text)
    return p


print("# F8 unbounded recursion (Rust: 'recursion limit' error; Pion: stack overflow)")
for d in ([20000, 100000] if quick else [10000, 20000, 40000, 100000]):
    row(f"nested arrays depth {d}", write(f"arr{d}.toml", "a = " + "[" * d + "]" * d + "\n"))
for d in ([20000, 50000] if quick else [20000, 30000, 50000]):
    row(f"table header with {d} dotted parts", write(f"hdr{d}.toml", "[" + ".".join(["a"] * d) + "]\nx = 1\n"))
for d in ([50000] if quick else [20000, 50000]):
    row(f"dotted key with {d} parts", write(f"dot{d}.toml", ".".join(["a"] * d) + " = 1\n"), impls={k: v for k, v in IMPLS.items() if k != "go_burntsushi"})

print("\n# F9 super-linear nested inline tables (seal_inline_table re-walks the subtree on every '}')")
for d in ([2500, 5000, 10000] if quick else [2500, 5000, 10000, 20000]):
    row(f"inline tables depth {d}", write(f"inl{d}.toml", "a = " + "{a = " * d + "1" + "}" * d + "\n"),
        impls={k: v for k, v in IMPLS.items() if not (k == "go_burntsushi" and d > 5000)})

print("\n# F10 HashDoS on the unseeded runtime String hash (pion_str_hash, linear probing on h & (cap-1))")
r = random.Random(1)
A = string.ascii_letters + string.digits + "_-"
for n, bits in ([(20000, 16)] if quick else [(20000, 16), (60000, 17)]):
    keys = []
    per = n // 6
    procs = [subprocess.Popen([f"{BIN}/hashdos_gen", str(per), str(bits), "1", str(j * 1000000)], stdout=subprocess.PIPE) for j in range(6)]
    for p in procs:
        keys += p.communicate()[0].decode().split()
    ctrl = set()
    while len(ctrl) < len(keys):
        ctrl.add("".join(r.choice(A) for _ in range(12)))
    row(f"{len(keys)} random 12-char keys (control)", write(f"hd{len(keys)}_control.toml", "".join(f"{k} = {i}\n" for i, k in enumerate(sorted(ctrl)))))
    row(f"{len(keys)} colliding 12-char keys (attack, same size)", write(f"hd{len(keys)}_attack.toml", "".join(f"{k} = {i}\n" for i, k in enumerate(keys))))
    row(f"{len(keys)} colliding keys inside ONE inline table", write(f"hd{len(keys)}_inline.toml", "t = {" + ", ".join(f"{k} = {i}" for i, k in enumerate(keys)) + "}\n"))

print("\n# F11 toml::get is a linear scan: looking up every key of a wide table is O(n^2)")
for n in ([10000, 30000] if quick else [1000, 10000, 30000]):
    p = write(f"lookup{n}.toml", "".join(f"key_{i} = {i}\n" for i in range(n)))
    row(f"get() every key of a {n}-key table", p, mode="bench-lookup", impls={k: v for k, v in IMPLS.items() if k != "go_burntsushi"})

print("\n# Large but flat inputs (memory)")
row("500k empty tables [tNNNNNN]", write("empty_tables.toml", "".join(f"[t{i:06d}]\n" for i in range(500000))))
row("1 key of 8 MiB", write("long_key.toml", '"' + "k" * (8 << 20) + '" = 1\n'))
row("1 basic string of 32 MiB", write("long_str.toml", 'a = "' + "x" * (32 << 20) + '"\n'))
row("1 basic string of 16 MiB, every char escaped", write("long_esc.toml", 'a = "' + "\\t" * (8 << 20) + '"\n'))
