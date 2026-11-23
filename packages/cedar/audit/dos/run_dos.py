#!/usr/bin/env python3
"""DoS / complexity / stack probes: Pion (4 build modes) vs Rust `cedar-policy =4.15.0`.

usage: run_dos.py <pion_dos native-release bin> <pion_dos native-debug bin> <rust dos bin> <pion_dos dir>
       [--quick]
Environment: PION_CACHE_DIR for the wasm32 runs (`pionc run --target wasm32 ...`).

Gates (exit 1 if any fails):
  same      Pion native-release prints the same line as cedar-policy
  time      Pion wall time <= FACTOR x cedar-policy + SLACK seconds (generous: only super-linear
            blow-ups trip it, never constant-factor noise)
  selfrel   chain_rev (descending insertion) <= 10 x chain_fwd + 0.5 s on the SAME Pion build
  not_allow the decision must not be Allow (fail-open); a request-level error is acceptable
  4mode     native-debug / wasm32-debug / wasm32-release print the native-release line with exit 0
            (no SIGSEGV, no RangeError) and that line equals cedar-policy's
"""
import os
import subprocess
import sys
import time

TIMEOUT = 180


def run(cmd, env=None):
    t0 = time.perf_counter()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT, env=env)
        dt = time.perf_counter() - t0
        out = p.stdout.strip().splitlines()
        line = out[-1] if out else ""
        if p.returncode != 0:
            err = (p.stderr.strip().splitlines() or ["?"])
            tag = "RangeError" if "RangeError" in p.stderr else ("SIGSEGV" if p.returncode in (-11, 139) else "exit=%d" % p.returncode)
            line = "CRASH(%s) %s" % (tag, err[0][:80] if tag.startswith("exit") else "")
        return line.strip(), dt
    except subprocess.TimeoutExpired:
        return "TIMEOUT(>%ds)" % TIMEOUT, float(TIMEOUT)


def strip(line, name, args):
    pre = "probe=%s n=%s " % (name, args[0])
    return line[len(pre):] if line.startswith(pre) else line


def main():
    pion_rel, pion_dbg, rust, pdir = sys.argv[1:5]
    quick = "--quick" in sys.argv
    env = dict(os.environ)
    # (probe, args, gates, factor, slack)
    probes = [
        ("chain_fwd", ["4000"], ["same"], 5, 1.0),
        ("chain_rev", ["4000"], ["same", "selfrel"], 0, 0),
        ("star", ["100000"], ["same", "time"], 5, 0.5),
        ("ctx_set", ["50000"], ["same", "time"], 20, 0.5),
        ("ent_set", ["50000"], ["same", "time"], 20, 0.5),
        ("set_lit", ["50000"], ["same", "time"], 20, 0.5),
        ("contains_all", ["50000"], ["same", "time"], 20, 0.5),
        ("set_eq", ["50000"], ["same", "time"], 20, 0.5),
        ("like", ["200000", "200"], ["same", "time"], 20, 0.5),
        ("budget", ["7000"], ["not_allow"], 0, 0),
        ("deep_eval", ["120"], ["same", "4mode"], 0, 0),
        ("fmt_chain_default", ["3000"], ["same", "4mode"], 0, 0),
        ("deep_parse", ["0"], ["same", "4mode"], 0, 0),  # 0 = max_safe_depth() - 6
        ("deep_eval", ["0"], ["same", "4mode"], 0, 0),
        ("fmt_chain", ["200000"], [], 0, 0),  # informational: raised max_tokens, native stack
    ]
    if quick:
        probes = [p for p in probes if p[0] not in ("chain_fwd", "chain_rev", "ent_set", "set_eq")]
    fwd_time = None
    failures = 0
    print("  %-22s %-9s %-9s %-7s %s" % ("probe", "pion(s)", "rust(s)", "gate", "pion line | rust line"))
    for name, args, gates, factor, slack in probes:
        pl, pt = run([pion_rel, name] + args)
        rl, rt = run([rust, name] + args)
        verdict = []
        if not gates and pl != rl:
            verdict.append("differs (not gated)")
        if "same" in gates and pl != rl:
            verdict.append("same")
        if "time" in gates and pt > factor * rt + slack:
            verdict.append("time(>%gx+%gs)" % (factor, slack))
        if name == "chain_fwd":
            fwd_time = pt
        if "selfrel" in gates and fwd_time is not None and pt > 10 * fwd_time + 0.5:
            verdict.append("selfrel(%.1fx fwd)" % (pt / max(fwd_time, 1e-3)))
        if "not_allow" in gates and " Allow" in (" " + pl.split(" ", 2)[-1]):
            verdict.append("fail-open")
        modes = ""
        if "4mode" in gates:
            outs = {"native-dbg": run([pion_dbg, name] + args)[0]}
            for m, flags in (("wasm-dbg", []), ("wasm-rel", ["--release"])):
                outs[m] = run(["pionc", "run"] + flags + ["--target", "wasm32", pdir, "--"] + [name] + args, env)[0]
            bad = [m for m, o in outs.items() if o != pl or o != rl]
            if bad:
                verdict.append("4mode")
                modes = "  [" + ", ".join("%s: %s" % (m, outs[m][:60]) for m in bad) + "]"
        status = "ok" if not verdict else "FAIL"
        if verdict and not gates:
            status = "info"
        elif verdict:
            failures += 1
        print("  %-22s %-9.3f %-9.3f %-7s %s | %s%s%s" % (
            name + " " + " ".join(args), pt, rt, status, strip(pl, name, args)[:44],
            strip(rl, name, args)[:30], ("  <- " + ",".join(verdict)) if verdict else "", modes))
    print("  dos: %d gated probe(s) FAILED" % failures if failures else "  dos: all gated probes pass")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
