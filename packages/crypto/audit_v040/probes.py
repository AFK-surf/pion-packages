"""RT-crypto-v040 crash-isolated hostile-parameter probes (P1-1, P2-1, P2-2 in REPORT.md).

Each probe is one `oracle one <op> <args...>` process per build mode (native_dbg, native_rel,
wasm_dbg, wasm_rel), because a runtime abort or a wasm32 trap would end a streamed corpus run.
A probe passes when, in every mode, the process exits 0 within the time limit, prints one line in the
probe's acceptance set, and all four modes print the same line.

Acceptance:
  ERR    any `ERR:<kind>` (a clean CryptoError)
  TAIL   `ERR:<kind>`, or `OKBIG:len=<dk>:tail=<t>` where t is the real last 32 bytes of the PBKDF2
         output (computed block-wise by `go_oracle tail`, so an all-zero or truncated key fails)
  NZTAIL `ERR:<kind>`, or `OKBIG:len=<dk>:tail=<t>` with t not all zero (scrypt: no cheap reference)
  MEM    `ERR:MemoryLimitExceeded`, or the Go x/crypto hex (when the Go side can afford computing it)

Usage: python3 probes.py   (needs run_audit.sh build first; exit 0 = every probe passes)
"""
import os
import subprocess
import sys

OUT = os.environ.get("RT_OUT", "/private/tmp/rt-crypto-v040-out")
BIN = os.path.join(OUT, "bin")
WASM_RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
TIMEOUT = int(os.environ.get("RT_PROBE_TIMEOUT", "600"))
I64MAX = "9223372036854775807"
P, S = "70617373", "73616c74"  # "pass", "salt"

PROBES = [  # name, args, acceptance, why
    ("pbkdf2_sha256_dk_2^31-31", ["P256", P, S, "1", "2147483617"], "TAIL", "(dk_len + 31) wraps: n_blocks < 0"),
    ("pbkdf2_sha256_dk_2^31-17", ["P256", P, S, "1", "2147483631"], "TAIL", "largest Bytes the runtime allows"),
    ("pbkdf2_sha256_dk_2^31-16", ["P256", P, S, "1", "2147483632"], "TAIL", "Bytes::new above the runtime maximum"),
    ("pbkdf2_sha256_dk_INT_MAX", ["P256", P, S, "1", "2147483647"], "TAIL", "Bytes::new(Int::MAX)"),
    ("pbkdf2_sha512_dk_2^31-63", ["P512", P, S, "1", "2147483585"], "TAIL", "(dk_len + 63) wraps: n_blocks < 0"),
    ("pbkdf2_sha512_dk_INT_MAX", ["P512", P, S, "1", "2147483647"], "TAIL", "Bytes::new(Int::MAX)"),
    ("scrypt_dk_2^31-28", ["SC", P, S, "2", "1", "1", "2147483620", "D"], "NZTAIL", "final PBKDF2 inherits the wrap"),
    ("scrypt_V_1GiB_wasm32", ["SC", P, S, "4194304", "2", "1", "32", I64MAX], "MEM", "FixedArray[UInt] of 2^28 words"),
    ("scrypt_V_2GiB_wasm32", ["SC", P, S, "1048576", "16", "1", "32", I64MAX], "MEM", "FixedArray[UInt] of 2^29 words"),
    ("scrypt_V_4GiB", ["SC", P, S, "16777216", "2", "1", "32", I64MAX], "ERR", "4 GiB V: no wasm32 address space"),
]


def run(cmd):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, "TIMEOUT(%ds)" % TIMEOUT
    out = p.stdout.decode(errors="replace").strip()
    if p.returncode != 0:
        err = p.stderr.decode(errors="replace").strip().splitlines()
        msg = next((l for l in err if "panic" in l or "Error" in l), err[0] if err else "")
        return p.returncode, "CRASH rc=%d %s" % (p.returncode, msg[:110])
    return 0, out


def accepted(kind, args, line):
    if line.startswith("ERR:"):
        return kind != "MEM" or line == "ERR:MemoryLimitExceeded"
    if kind in ("TAIL", "NZTAIL") and line.startswith("OKBIG:"):
        dk = args[4] if args[0] != "SC" else args[6]
        head, _, tail = line.rpartition(":tail=")
        if head != "OKBIG:len=" + dk:
            return False
        if kind == "NZTAIL":
            return tail.strip("0") != ""
        want = subprocess.run([os.path.join(BIN, "go_oracle"), "tail"] + args, stdout=subprocess.PIPE).stdout.decode().strip()
        return tail == want
    if kind == "MEM" and not line.startswith(("CRASH", "TIMEOUT", "OKBIG")):
        want = subprocess.run([os.path.join(BIN, "go_oracle"), "one"] + args, stdout=subprocess.PIPE).stdout.decode().strip()
        return line in want.split(" || ")
    return False


def main():
    ok = True
    print("| probe | why | native_dbg | native_rel | wasm_dbg | wasm_rel | verdict |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for name, args, kind, why in PROBES:
        res = {}
        for m in ("native_dbg", "native_rel"):
            res[m] = run([os.path.join(BIN, "oracle_" + m), "one"] + args)[1]
        for m in ("wasm_dbg", "wasm_rel"):
            res[m] = run(["node", WASM_RT, os.path.join(BIN, "oracle_%s.wasm" % m), "one"] + args)[1]
        same = len(set(res.values())) == 1
        good = same and all(accepted(kind, args, v) for v in res.values())
        ok = ok and good
        cells = [v if len(v) <= 60 else v[:57] + "..." for v in res.values()]
        print("| %s | %s | %s | %s |" % (name, why, " | ".join(cells),
                                         "PASS" if good else ("FAIL (modes disagree)" if not same else "FAIL")))
        sys.stdout.flush()
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
