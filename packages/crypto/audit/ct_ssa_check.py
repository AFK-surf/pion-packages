"""Constant-time gate for the secret-key paths of packages/crypto (release QBE SSA).

Builds `packages/crypto/wasm_smoke` in release mode with a throw-away PION_CACHE_DIR, reads the
generated QBE SSA and checks two properties:

1. Every helper that handles secret operands contains no `jnz` on data: the only conditional jumps
   allowed are the ones the compiler emits for loops (`wh_*`), array allocation (`amk_*`), bounds
   checks (`arr_oob*`, `bytes_oob*`), reference counting (`_rcd_*`, `_rci_*`), and the inlined
   `to_fixed_limbs` clamp on a BigUint's public limb count (`if_t*` on a `len` field load).
2. The signing entry points never call the variable-time BigUint routines on secret values
   (`big_mod`, `big_mul_mod`, `big_add_mod`, `big_sub_mod`, `mont_r2`; `big_mod_pow` is only allowed
   for the Bellcore check `s^e mod n`, which works on the public signature and exponent).

Usage: python3 packages/crypto/audit/ct_ssa_check.py   (exit status 0 = pass)
"""
import os, re, subprocess, sys, tempfile

PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PREFIX = "pion_pkg_crypto_fn_"
CT_FUNCS = [
    "big_mod_ct", "mont_ctx_ct", "mont_mul_mod_ct", "mod_add_ct", "mod_sub_ct", "mont_pow_ct",
    "limbs_mul_add_ct", "mont_mul_limbs", "mont_n0_inv", "ct_eq_nibble",
    "fp_add", "fp_sub", "fp_mul", "fp_cmov", "p256_cmov", "p256_add", "p256_dbl",
    "fe_cswap_pair", "poly1305_block",
]
FORBIDDEN_CALLS = {
    "rsa_crt_private": {"big_mod", "big_mul_mod", "big_add_mod", "big_sub_mod", "mont_r2"},
    "rsa_sign_rs256": {"big_mod", "big_mul_mod", "big_add_mod", "big_sub_mod", "mont_r2", "big_mod_pow"},
    "p256_sign_es256": {"big_mul_mod", "big_add_mod", "big_sub_mod", "big_mod_pow", "mont_r2"},
    "p256_affine": {"big_mod_pow", "big_mod", "mont_r2"},
    "p256_scalarmult_base_ct": {"big_mod_pow", "big_mul_mod", "big_add_mod", "big_sub_mod"},
}
STRUCTURAL = ("wh_", "amk_", "arr_oob", "bytes_oob", "_rcd_", "_rci_")


def build_ssa():
    env = dict(os.environ)
    env["PATH"] = os.path.expanduser("~/.pion/bin") + os.pathsep + env.get("PATH", "")
    with tempfile.TemporaryDirectory(prefix="pion-ct-") as tmp:
        env["PION_CACHE_DIR"] = os.path.join(tmp, "cas")
        subprocess.run(
            ["pionc", "build", "--release", "-o", os.path.join(tmp, "smoke"), os.path.join(PKG, "wasm_smoke")],
            check=True, env=env, stdout=subprocess.DEVNULL,
        )
        ssa_dir = os.path.join(tmp, "cas", "ssa")
        files = [os.path.join(ssa_dir, f) for f in os.listdir(ssa_dir)]
        return "\n".join(open(f).read() for f in files)


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
        if not m:
            continue
        label = m.group(2)
        if label.startswith(STRUCTURAL):
            continue
        cond = defs.get(m.group(1), "")
        # Inlined `to_fixed_limbs`: `if a.len < k` compares the BigUint `len` field (offset 8).
        if label.startswith("if_t") and re.match(r"cs\w+w %\S+, %\S+", cond):
            lhs = cond.split()[1].rstrip(",")
            if re.match(r"loadsw %\S+", defs.get(lhs, "")):
                addr = defs.get(lhs).split()[1]
                if re.match(r"add %\S+, 8$", defs.get(addr, "")):
                    continue
        bad.append(label + " <= " + cond)
    return bad


def main():
    funcs = functions(build_ssa())
    ok = True
    for name in CT_FUNCS:
        if name not in funcs:
            print("MISSING  %s (not emitted; inlined or renamed?)" % name)
            ok = False
            continue
        bad = data_branches(funcs[name])
        print("%-5s %-24s %s" % ("PASS" if not bad else "FAIL", name, "; ".join(bad[:4])))
        ok = ok and not bad
    for name, forbidden in FORBIDDEN_CALLS.items():
        if name not in funcs:
            print("MISSING  %s" % name)
            ok = False
            continue
        calls = {c[len(PREFIX):] for c in re.findall(r"call \$(" + PREFIX + r"\w+)", funcs[name])}
        hit = sorted(calls & forbidden)
        print("%-5s %-24s %s" % ("PASS" if not hit else "FAIL", name + " calls", ", ".join(hit) or "no variable-time helper"))
        ok = ok and not hit
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
