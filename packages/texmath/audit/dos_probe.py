#!/usr/bin/env python3
"""DoS / crash probes: each pathological input runs in its own process under KaTeX and Pion.

usage: dos_probe.py <pion_diff_driver_bin> <katex_diff.mjs> <katex_path> [--timeout S] [--rss-cap-mib M] [probe ...]
A probe is killed (whole process group) once it exceeds the timeout or the RSS cap.
Peak RSS is sampled every 20 ms with ps(1), so very short runs under-report.
Prints one row per probe: exit status, wall time, peak RSS and first bytes of output.
"""
import os, re, signal, subprocess, sys, tempfile, time

pion_bin, katex_mjs, katex_path = sys.argv[1:4]
timeout = float(sys.argv[sys.argv.index("--timeout") + 1]) if "--timeout" in sys.argv else 10.0
rss_cap = float(sys.argv[sys.argv.index("--rss-cap-mib") + 1]) if "--rss-cap-mib" in sys.argv else 4096.0

def nest(open_, close, inner, n):
    return open_ * n + inner + close * n

PROBES = [
    ("macro_bomb_self", r"\def\a{\a}\a"),
    ("macro_bomb_double", r"\def\a{\a\a}\a"),
    ("macro_billion_laughs", r"\def\a{xxxxxxxxxx}\def\b{\a\a\a\a\a\a\a\a\a\a}\def\c{\b\b\b\b\b\b\b\b\b\b}\def\d{\c\c\c\c\c\c\c\c\c\c}\def\e{\d\d\d\d\d\d\d\d\d\d}\def\f{\e\e\e\e\e\e\e\e\e\e}\f"),
    ("newcommand_bomb", r"\newcommand{\a}{\a}\a"),
    ("def_arg_growth", r"\def\a#1{\a{#1#1}}\a{x}"),
    ("arg_laughs_10x7", r"\def\a#1{#1#1#1#1#1#1#1#1#1#1}\a{\a{\a{\a{\a{\a{\a{x}}}}}}}"),
    ("newcommand_arg_laughs", r"\newcommand{\a}[1]{#1#1#1#1#1#1#1#1#1#1}\a{\a{\a{\a{\a{\a{\a{x}}}}}}}"),
    ("color_flat_32000", r"\color{red}{x}" * 32000),
    ("braces_1e3", nest("{", "}", "x", 1000)),
    ("braces_1e4", nest("{", "}", "x", 10000)),
    ("braces_1e5", nest("{", "}", "x", 100000)),
    ("frac_1e3", nest(r"\frac{", "}{x}", "x", 1000)),
    ("frac_1e4", nest(r"\frac{", "}{x}", "x", 10000)),
    ("sqrt_1e4", nest(r"\sqrt{", "}", "x", 10000)),
    ("sup_1e4", nest("x^{", "}", "x", 10000)),
    ("left_right_1e4", nest(r"\left(", r"\right)", "x", 10000)),
    ("text_math_1e3", nest(r"\text{$", "$}", "x", 1000)),
    ("color_1e4", nest(r"\color{red}{", "}", "x", 10000)),
    ("long_flat_1MB", "x+" * 500000 + "x"),
    ("matrix_300x300", r"\begin{matrix}" + r"\\".join(["&".join(["x"] * 300)] * 300) + r"\end{matrix}"),
    ("huge_rule", r"\rule{100000000em}{100000000em}"),
    ("huge_kern", r"\kern99999999999em x"),
    ("huge_hspace_inf", r"\hspace{1e400em} x"),
    ("huge_genfrac", r"\genfrac{}{}{99999999pt}{}{a}{b}"),
    ("empty", ""),
    ("only_space", "   "),
    ("nul_byte", "x\x00y"),
    ("lone_surrogate_like", "x� y"),
    ("backslash_eof", "x\\"),
    ("unterminated_text", r"\text{abc"),
    ("unterminated_left", r"\left(" * 1000),
]

def rss_mib(pgid):
    """Sum of RSS (MiB) over every process in the probe's process group."""
    out = subprocess.run(["ps", "-A", "-o", "pgid=,rss="], capture_output=True, text=True).stdout
    total = 0
    for line in out.split("\n"):
        parts = line.split()
        if len(parts) == 2 and parts[0] == str(pgid):
            total += int(parts[1])
    return total / 1024

def run(cmd, env=None):
    """Run in its own process group; sample peak RSS; kill the group on timeout or RSS cap."""
    t0 = time.monotonic()
    p = subprocess.Popen(["/usr/bin/time", "-l"] + cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, start_new_session=True)
    import threading
    chunks = {"out": b"", "err": b""}
    def pump(stream, key):
        chunks[key] = stream.read()
    ts = [threading.Thread(target=pump, args=(p.stdout, "out")), threading.Thread(target=pump, args=(p.stderr, "err"))]
    for t in ts:
        t.start()
    peak, status = 0.0, None
    while p.poll() is None:
        peak = max(peak, rss_mib(p.pid))
        dt = time.monotonic() - t0
        if dt > timeout:
            status = "TIMEOUT"
        elif peak > rss_cap:
            status = "RSS>CAP"
        if status:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            break
        time.sleep(0.02)
    for t in ts:
        t.join()
    dt = time.monotonic() - t0
    out = chunks["out"].decode("utf-8", "replace").strip().split("\n")[0][:110]
    err = chunks["err"].decode("utf-8", "replace").strip()
    m = re.search(r"(\d+)\s+maximum resident set size", err)
    if m:
        peak = int(m.group(1)) / 1048576  # exact peak from /usr/bin/time -l (bytes on macOS)
    err = "\n".join(l for l in err.split("\n") if l.strip() and not re.match(r"\s*\d+\s+\S", l) and "real" not in l)
    if status:
        return (status, dt, peak, "")
    if p.returncode != 0:
        name = f"rc={p.returncode}"
        if "Segmentation fault" in err or "terminated abnormally" in err:
            name = "CRASH"
        return (name, dt, peak, (err.split("\n")[0][:110] + " " + out).strip())
    return ("ok", dt, peak, out)

env = dict(os.environ, KATEX_PATH=katex_path)
only, skip = [], False
for a in sys.argv[4:]:
    if skip:
        skip = False
    elif a in ("--timeout", "--rss-cap-mib"):
        skip = True
    else:
        only.append(a)
print(f"{'probe':24} | {'impl':6} | {'status':8} | {'wall_s':>7} | {'rss_MiB':>8} | output")
with tempfile.TemporaryDirectory() as td:
    for name, tex in PROBES:
        if only and name not in only:
            continue
        path = os.path.join(td, name + ".txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write("I " + tex + "\n")
        for impl, cmd in (("katex", ["node", katex_mjs, path]), ("pion", [pion_bin, path])):
            st, dt, rss, out = run(cmd, env)
            out = re.sub(r"<span class=\"katex\"><math[^>]*><semantics>", "", out)
            rs = f"{rss:8.1f}" if rss is not None else "       -"
            print(f"{name:24} | {impl:6} | {st:8} | {dt:7.2f} | {rs} | {out}", flush=True)
