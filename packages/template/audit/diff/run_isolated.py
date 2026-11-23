#!/usr/bin/env python3
"""Run every case of a corpus in its own process, under a wall-clock and RSS watchdog.

    python3 run_isolated.py <corpus> <out.records> <label>=<cmd prefix> [...] [--md out.md]
        [--timeout SEC] [--rss-mib MIB]

Each command prefix is invoked as `<prefix> one <corpus> <case>` (the probe / Rust mirror
CLI). Per case and engine we record: status (OK/ERR from the record, or CRASH(signal),
TRAP(wasm runtime error), TIMEOUT, RSS-KILL), wall ms, peak RSS and output size.
`<out.records>` collects the records of the FIRST engine so it can be byte-compared with
a whole-corpus run (used for the wasm32-vs-native diff).
"""
import os
import shlex
import signal
import subprocess
import sys
import tempfile
import time


def load_names(corpus):
    data = open(corpus, "rb").read().decode("utf-8")
    return [r.split("\x1f", 1)[0] for r in data.split("\x1e") if "\x1f" in r]


def rss_kib(pid):
    try:
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout
        return int(out.strip() or 0)
    except Exception:
        return 0


def run_one(cmd, timeout, rss_cap_kib):
    with tempfile.TemporaryFile() as so, tempfile.TemporaryFile() as se:
        t0 = time.monotonic()
        p = subprocess.Popen(cmd, stdout=so, stderr=se, start_new_session=True)
        peak = 0
        killed = None
        last_ps = 0.0
        while True:
            pid, status, ru = os.wait4(p.pid, os.WNOHANG)
            if pid:
                break
            now = time.monotonic()
            if now - t0 > timeout:
                killed = "TIMEOUT"
            elif now - last_ps > 0.1:
                last_ps = now
                r = rss_kib(p.pid)
                peak = max(peak, r)
                if r > rss_cap_kib:
                    killed = "RSS-KILL"
            if killed:
                os.killpg(p.pid, signal.SIGKILL)
                pid, status, ru = os.wait4(p.pid, 0)
                break
            time.sleep(0.01)
        ms = (time.monotonic() - t0) * 1000
        # ru_maxrss: bytes on macOS, KiB on Linux.
        maxrss = ru.ru_maxrss // 1024 if sys.platform == "darwin" else ru.ru_maxrss
        peak = max(peak, maxrss)
        so.seek(0)
        out = so.read()
        se.seek(0)
        err = se.read().decode("utf-8", "replace")
    if killed:
        st = killed
    elif os.WIFSIGNALED(status):
        st = "CRASH(" + signal.Signals(os.WTERMSIG(status)).name + ")"
    elif os.WEXITSTATUS(status) != 0 and not out:
        first = (err.strip().splitlines() or ["exit " + str(os.WEXITSTATUS(status))])[0]
        st = "TRAP(" + first[:70] + ")"
    else:
        parts = out.decode("utf-8", "replace").split("\x1f", 2)
        if len(parts) == 3:
            st = parts[1]
            if st == "ERR":
                st = "ERR(" + parts[2].split(":", 1)[0] + ")"
            else:
                st = "OK(" + str(len(parts[2].rstrip("\x1e").encode())) + "B)"
        else:
            st = "NO-OUTPUT(exit " + str(os.WEXITSTATUS(status)) + ")"
    return st, ms, peak, out


def main():
    args = sys.argv[1:]
    opts = {"--md": None, "--timeout": "20", "--rss-mib": "4096"}
    for k in list(opts):
        if k in args:
            i = args.index(k)
            opts[k] = args[i + 1]
            del args[i : i + 2]
    corpus, records = args[0], args[1]
    engines = [a.split("=", 1) for a in args[2:]]
    names = load_names(corpus)
    timeout = float(opts["--timeout"])
    cap = int(opts["--rss-mib"]) * 1024
    rows = []
    with open(records, "wb") as rec:
        for n in names:
            row = [n]
            for idx, (label, prefix) in enumerate(engines):
                st, ms, peak, out = run_one(shlex.split(prefix) + ["one", corpus, n], timeout, cap)
                if idx == 0:
                    rec.write(out if out else (n + "\x1f" + st + "\x1f\x1e").encode())
                row.append(f"{st} {ms:.0f}ms {peak / 1024:.0f}MiB")
            rows.append(row)
            print(" | ".join(row), flush=True)
    if opts["--md"]:
        with open(opts["--md"], "w") as fh:
            fh.write("| case | " + " | ".join(e[0] for e in engines) + " |\n")
            fh.write("|---" * (len(engines) + 1) + "|\n")
            for r in rows:
                fh.write("| `" + r[0] + "` | " + " | ".join(r[1:]) + " |\n")


if __name__ == "__main__":
    main()
