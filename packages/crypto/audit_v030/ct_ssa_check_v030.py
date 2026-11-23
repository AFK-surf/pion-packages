"""RT-crypto-v030 constant-time gate for the v0.3.0 secret paths (release QBE SSA).

Extends `packages/crypto/audit/ct_ssa_check.py` (read-only reference, not modified) to the new
AES-GCM and P-256 ECDH code. Builds `audit_v030/oracle` with `pionc build --release` into a
throw-away PION_CACHE_DIR under /private/tmp/rt-crypto-v030-*, reads the emitted QBE SSA and checks:

1. BRANCH_FREE: functions that touch key / round-key / H / keystream / scalar data contain no `jnz`
   except compiler structure (loops `wh_*`, array alloc `amk_*`, bounds `arr_oob*`/`bytes_oob*`,
   read-only Bytes write guard `bytes_ro*`, refcount `_rcd_*`/`_rci_*`).
2. TABLE_FREE: the AES / GHASH / scalar-mult functions reference no data symbol (no S-box,
   T-table or GHASH 4-bit table), so no secret-indexed memory access is possible.
3. PUBLIC_BRANCHES: functions allowed to branch only on public lengths / loop indices carry at most
   the audited number of data branches (a new one fails the gate and must be re-audited).
4. CALLS: the scalar multiplication and the AES/GHASH core never call a variable-time BigUint helper.

Exit 0 = pass. Usage: python3 ct_ssa_check_v030.py
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PREFIX = "pion_pkg_crypto_fn_"
STRUCTURAL = ("wh_", "amk_", "arr_oob", "bytes_oob", "bytes_ro", "_rcd_", "_rci_")

BRANCH_FREE = [
    "aes_delta_swap", "aes_transpose_8x8", "aes_bitslice_sbox", "aes_bitslice_shift_rows",
    "aes_rotr16", "aes_rotr32", "aes_bitslice_mix_columns", "aes_sub_word_ct", "aes_load32_le",
    "aes_rotr8_u32", "aes_pack_round_key", "aes_encrypt_4blocks", "aes_encrypt_block",
    "ghash_rev64", "ghash_load64_be_arr", "ghash_load64_be_bytes", "ghash_store64_be_arr",
    "ghash_bmul32", "ghash_bmul64", "ghash_mul_gf128", "ghash_init", "ghash_update_block_be",
    "ghash_finalize_arr", "gcm_inc32", "gcm_compute_tag", "p256_scalarmult_ct",
    # helpers the scalar multiplication relies on (already gated by audit/ct_ssa_check.py; re-checked)
    "p256_add", "p256_dbl", "fp_add", "fp_sub", "fp_mul", "mont_mul_limbs",
]
TABLE_FREE = [n for n in BRANCH_FREE if n.startswith(("aes_", "ghash_", "gcm_", "p256_scalarmult"))]

# name -> (max data branches, why they are public)
PUBLIC_BRANCHES = {
    "aes_key_expand": (6, "i % nk == 0 / nk == 8 && i % nk == 4 on the public word index (2 unrolled copies)"),
    "gcm_gctr": (3, "len <= 0, rem >= 64, rem < 64 on the public message length"),
    "gcm_derive_j0": (1, "nonce.length() == 12"),
    "ghash_update_padded": (1, "off < end (public length of the partial block)"),
    "aes_gcm_seal_inner": (2, "key.length() != expected, nonce.length() == 0"),
    "aes_gcm_open_inner": (4, "key / nonce / total < 16 length checks + the final tag verdict"),
    "constant_time_eq": (1, "a.length() != b.length() (lengths are public)"),
}
FORBIDDEN_CALLS = {
    name: {"big_mod", "big_mod_pow", "big_mul_mod", "big_add_mod", "big_sub_mod", "mont_r2", "big_cmp",
           "big_from_be", "big_from_be_slice", "big_trim"}
    for name in TABLE_FREE + ["aes_key_expand", "gcm_gctr", "gcm_derive_j0", "ghash_update_padded"]
}


def build_ssa():
    env = dict(os.environ)
    env["PATH"] = os.path.expanduser("~/.pion/bin") + os.pathsep + env.get("PATH", "")
    tmp = tempfile.mkdtemp(prefix="rt-crypto-v030-ct-", dir="/private/tmp")
    try:
        env["PION_CACHE_DIR"] = os.path.join(tmp, "cas")
        subprocess.run(
            ["pionc", "build", "--release", "-o", os.path.join(tmp, "oracle"), os.path.join(HERE, "oracle")],
            check=True, env=env, stdout=subprocess.DEVNULL,
        )
        ssa_dir = os.path.join(tmp, "cas", "ssa")
        return "\n".join(open(os.path.join(ssa_dir, f)).read() for f in sorted(os.listdir(ssa_dir)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def functions(src):
    out = {}
    for chunk in re.split(r"\n(?=(?:export )?function )", src):
        m = re.search(r"function (?:\w+ )?\$" + PREFIX + r"(\w+)\(", chunk)
        if m:
            out[m.group(1)] = chunk
    return out


def data_branches(body):
    defs = {}
    for line in body.split("\n"):
        m = re.match(r"\s*(%\S+)\s*=\w?\s*(.*)", line)
        if m:
            defs[m.group(1)] = m.group(2)
    bad = []
    for line in body.split("\n"):
        m = re.search(r"jnz (%\S+),\s*@(\S+?),", line)
        if m and not m.group(2).startswith(STRUCTURAL):
            bad.append(m.group(2) + " <= " + defs.get(m.group(1), "?"))
    return bad


def data_symbols(body):
    syms = set(re.findall(r"\$([A-Za-z_][\w.]*)", body))
    return sorted(s for s in syms if not s.startswith("pion_") and s not in ("memset", "memcpy"))


def main():
    funcs = functions(build_ssa())
    ok = True

    def report(status, name, detail):
        nonlocal ok
        print("%-5s %-28s %s" % (status, name, detail))
        if status == "FAIL":
            ok = False

    for name in BRANCH_FREE:
        if name not in funcs:
            report("SKIP", name, "not emitted (inlined into its caller, which is checked)")
            continue
        bad = data_branches(funcs[name])
        report("PASS" if not bad else "FAIL", name, "branch-free" if not bad else "; ".join(bad[:4]))
    for name in TABLE_FREE:
        if name in funcs:
            syms = data_symbols(funcs[name])
            report("PASS" if not syms else "FAIL", name + " tables", ", ".join(syms) or "no data-symbol loads")
    for name, (limit, why) in PUBLIC_BRANCHES.items():
        if name not in funcs:
            report("SKIP", name, "not emitted")
            continue
        n = len(data_branches(funcs[name]))
        report("PASS" if n <= limit else "FAIL", name, "%d/%d public branches (%s)" % (n, limit, why))
    for name, forbidden in FORBIDDEN_CALLS.items():
        if name not in funcs:
            continue
        calls = {c[len(PREFIX):] for c in re.findall(r"call \$(" + PREFIX + r"\w+)", funcs[name])}
        hit = sorted(calls & forbidden)
        report("PASS" if not hit else "FAIL", name + " calls", ", ".join(hit) or "no variable-time BigUint helper")
    # Informational: the ECDH scalar range check reuses the variable-time BigUint parser/compare
    # (same pattern as p256_public_key / p256_sign_es256, see REPORT.md INFO-1).
    if "p256_ecdh" in funcs:
        calls = {c[len(PREFIX):] for c in re.findall(r"call \$(" + PREFIX + r"\w+)", funcs["p256_ecdh"])}
        vt = sorted(calls & {"big_from_be_slice", "big_cmp", "big_trim"})
        print("INFO  %-28s secret d flows through %s (range check only; see REPORT INFO-1)" % ("p256_ecdh", ", ".join(vt)))
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
