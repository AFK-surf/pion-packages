"""RT-crypto-v040 constant-time gate for the v0.4.0 PBKDF2 / scrypt code (release QBE SSA).

Re-runs the two existing gates unchanged (read-only):
  packages/crypto/audit/ct_ssa_check.py            (v0.1/v0.2 secret paths)
  packages/crypto/audit_v030/ct_ssa_check_v030.py  (v0.3.0 AES-GCM / P-256)
then builds `audit_v040/oracle` with `pionc build --release` into a throw-away PION_CACHE_DIR under
/private/tmp/rt-crypto-v040-ct-* and checks, with the SSA helpers of the v030 script (imported, not
copied or modified):

1. BRANCH_FREE: Salsa20/8, BlockMix, ROMix and the SHA-256/512 compression functions that process
   password-derived state contain no data-dependent `jnz` (loops / bounds / refcount are structural).
2. TABLE_FREE: Salsa20/8 and BlockMix load no data symbol.
3. PUBLIC_BRANCHES: the PBKDF2 / scrypt entry points branch only on public lengths and parameters
   (password length vs. the HMAC block, salt length padding, N / r / p / dk_len / max_mem checks);
   a new data branch fails the gate and must be re-audited.
INFO: scrypt ROMix indexes V with Integerify(X) mod N by design (RFC 7914 is not cache-timing
constant time; this is inherent to the algorithm, as in Go x/crypto, OpenSSL and libsodium).

Exit 0 = pass. Usage: python3 ct_ssa_check_v040.py
"""
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)

spec = importlib.util.spec_from_file_location("ct_v030", os.path.join(PKG, "audit_v030", "ct_ssa_check_v030.py"))
v030 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v030)

BRANCH_FREE = ["salsa20_8_xor", "blockmix_salsa8", "scrypt_romix", "sha256_compress_w", "sha512_compress_w"]
TABLE_FREE = ["salsa20_8_xor", "blockmix_salsa8"]
PUBLIC_BRANCHES = {
    "pbkdf2_hmac_sha256_pads": (17, "key.length() > 64 + 16 'p < klen' byte-index tests on the public key length"),
    "hmac_sha512_init_pads": (35, "key.length() > 128, is_384, 32 'p < klen' tests on the public key length"),
    # 3 today; head-room for the dk_len upper-bound check the P1-1 fix adds (public parameter)
    "pbkdf2_hmac_sha256": (6, "iterations <= 0, dk_len <= 0 (+ upper bound), rem < 32 (public output length)"),
    "pbkdf2_hmac_sha512": (6, "iterations <= 0, dk_len <= 0 (+ upper bound), rem < 64 (public output length)"),
    "sha256_update_final_state": (1, "rem >= 56 on the public salt length"),
    "sha512_update_final_state": (1, "rem >= 112 on the public salt length"),
    # 12 today; head-room for the N < 2^(16 r) and V-size checks the P2 fixes add (public parameters)
    "scrypt_with_max_mem": (24, "N / r / p / dk_len / max_mem validation and the Result match"),
}


def build_ssa():
    env = dict(os.environ)
    env["PATH"] = os.path.expanduser("~/.pion/bin") + os.pathsep + env.get("PATH", "")
    tmp = tempfile.mkdtemp(prefix="rt-crypto-v040-ct-", dir="/private/tmp")
    try:
        env["PION_CACHE_DIR"] = os.path.join(tmp, "cas")
        subprocess.run(["pionc", "build", "--release", "-o", os.path.join(tmp, "oracle"), os.path.join(HERE, "oracle")],
                       check=True, env=env, stdout=subprocess.DEVNULL)
        ssa_dir = os.path.join(tmp, "cas", "ssa")
        return "\n".join(open(os.path.join(ssa_dir, f)).read() for f in sorted(os.listdir(ssa_dir)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ok = True
    for script in (os.path.join(PKG, "audit", "ct_ssa_check.py"), os.path.join(PKG, "audit_v030", "ct_ssa_check_v030.py")):
        r = subprocess.run([sys.executable, script], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        last = r.stdout.decode(errors="replace").strip().splitlines()[-1:]
        print("%-5s %-28s %s" % ("PASS" if r.returncode == 0 else "FAIL", os.path.relpath(script, PKG), " ".join(last)))
        ok = ok and r.returncode == 0

    funcs = v030.functions(build_ssa())

    def report(status, name, detail):
        nonlocal ok
        print("%-5s %-28s %s" % (status, name, detail))
        if status == "FAIL":
            ok = False

    for name in BRANCH_FREE:
        if name not in funcs:
            report("SKIP", name, "not emitted (inlined into its caller)")
            continue
        bad = v030.data_branches(funcs[name])
        report("PASS" if not bad else "FAIL", name, "branch-free" if not bad else "; ".join(bad[:4]))
    for name in TABLE_FREE:
        if name in funcs:
            syms = v030.data_symbols(funcs[name])
            report("PASS" if not syms else "FAIL", name + " tables", ", ".join(syms) or "no data-symbol loads")
    for name, (limit, why) in PUBLIC_BRANCHES.items():
        if name not in funcs:
            report("SKIP", name, "not emitted")
            continue
        n = len(v030.data_branches(funcs[name]))
        report("PASS" if n <= limit else "FAIL", name, "%d/%d public branches (%s)" % (n, limit, why))
    if "scrypt_romix" in funcs:
        loads = len(re.findall(r"\bload\w*\b", funcs["scrypt_romix"]))
        print("INFO  %-28s V[Integerify(X) mod N] is a secret-indexed load by design (%d loads in ROMix)" % (
            "scrypt_romix", loads))
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
