"""RT-crypto-v040 mutation sensitivity: does the corpus notice re-created PBKDF2 / scrypt bug classes?

For every mutant a copy of the package (`src/`, `pion.toml`) plus `audit_v040/oracle` is written to
/private/tmp/rt-crypto-v040-mut/<name>/ (the git worktree is never touched), one source line is
changed (its first occurrence: SHA-256 code precedes SHA-512 code in pbkdf2.pion), the oracle is rebuilt with `pionc build --release` and run over the full Go corpus. A mutant
is KILLED when any line differs from the unmutated native_rel output (or the run crashes). A
surviving mutant fails the gate. A mutant whose anchor text no longer exists in `src/` (because a fix
rewrote that line) is reported as SKIP and does not fail the gate.

Usage: python3 mutants.py <corpus.tsv> <baseline native_rel.out>
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
ROOT = "/private/tmp/rt-crypto-v040-mut"

MUTANTS = [  # name, file, old, new, bug class
    ("salsa20_6_rounds", "scrypt.pion", "while round < 4 {", "while round < 3 {", "Salsa20/6 instead of /8"),
    ("integerify_first_subblock", "scrypt.pion", "let int_off_x = block_words - 16", "let int_off_x = 0",
     "Integerify reads B[0] instead of B[2r-1] (X half)"),
    ("integerify_y_offset", "scrypt.pion", "let int_off_y = (block_words << 1) - 16", "let int_off_y = block_words",
     "Integerify reads B[0] instead of B[2r-1] (Y half)"),
    ("blockmix_no_shuffle", "scrypt.pion", "salsa20_8_xor(x_blk, xy, even_in + 16, xy, even_out + half)",
     "salsa20_8_xor(x_blk, xy, even_in + 16, xy, even_out + 16)", "BlockMix without even/odd split (only r > 1)"),
    ("blockmix_x_init_b0", "scrypt.pion", "let last_in = in_off + ((r << 5) - 16)", "let last_in = in_off",
     "BlockMix X = B[0] instead of B[2r-1]"),
    ("romix_mask_half", "scrypt.pion", "let mask = (n - 1).to_uint()", "let mask = (n - 1).to_uint() >> 1U",
     "j = Integerify mod N/2"),
    ("romix_same_lane", "scrypt.pion", "scrypt_romix(b, bi * block_bytes, r, n, xy, v, x_blk)",
     "scrypt_romix(b, 0, r, n, xy, v, x_blk)", "every p lane mixes block 0"),
    ("salsa_rotation_9_to_8", "scrypt.pion", "t = x4 + x0\n    x8 = x8 ^ ((t << 9U) | (t >> 23U))",
     "t = x4 + x0\n    x8 = x8 ^ ((t << 8U) | (t >> 24U))",
     "one wrong Salsa rotation"),
    ("maxmem_drops_p", "scrypt.pion", "let n_plus = n.to_int64() + p64 + 2L", "let n_plus = n.to_int64() + 2L",
     "memory rule 128 r (N + 2) (ignores p)"),
    ("hmac256_fold_at_64", "pbkdf2.pion", "let k = if key.length() > 64 { sha256(key) } else { key }",
     "let k = if key.length() >= 64 { sha256(key) } else { key }", "HMAC-SHA256 folds a 64-byte key"),
    ("hmac512_fold_at_128", "hmac.pion", "let k = if key.length() > 128 {", "let k = if key.length() >= 128 {",
     "HMAC-SHA512 folds a 128-byte key"),
    ("pbkdf2_counter_le", "pbkdf2.pion", "salt_ctr[salt_len] = ((b_u >> 24U) & 0xFFU).to_int().to_byte()\n    salt_ctr[salt_len + 1] = ((b_u >> 16U) & 0xFFU).to_int().to_byte()\n    salt_ctr[salt_len + 2] = ((b_u >> 8U) & 0xFFU).to_int().to_byte()\n    salt_ctr[salt_len + 3] = (b_u & 0xFFU).to_int().to_byte()\n\n    // U_1 = HMAC-SHA256",
     "salt_ctr[salt_len + 3] = ((b_u >> 24U) & 0xFFU).to_int().to_byte()\n    salt_ctr[salt_len + 2] = ((b_u >> 16U) & 0xFFU).to_int().to_byte()\n    salt_ctr[salt_len + 1] = ((b_u >> 8U) & 0xFFU).to_int().to_byte()\n    salt_ctr[salt_len] = (b_u & 0xFFU).to_int().to_byte()\n\n    // U_1 = HMAC-SHA256",
     "INT(i) little-endian (SHA-256)"),
    ("pbkdf2_256_one_iter_less", "pbkdf2.pion", "    let mut iter = 1\n    while iter < iterations {\n      inner_st[0] = ipad[0]\n      inner_st[1] = ipad[1]",
     "    let mut iter = 2\n    while iter < iterations {\n      inner_st[0] = ipad[0]\n      inner_st[1] = ipad[1]",
     "c - 1 iterations (first loop = SHA-256)"),
    ("pbkdf2_256_salt_len_minus1", "pbkdf2.pion", "let salt_total_bytes = (64 + salt_ctr_len).to_int64()",
     "let salt_total_bytes = (63 + salt_ctr_len).to_int64()", "wrong SHA-256 length field"),
    ("sha256_pad_boundary_56", "sha256.pion", "  if rem >= 56 {\n    sha256_compress_w(state, w)",
     "  if rem > 56 {\n    sha256_compress_w(state, w)", "extra-block decision off by one (salt+4 = 56 mod 64)"),
    ("sha512_pad_boundary_112", "sha512.pion", "  if rem >= 112 {\n    sha512_compress_w(state, w)",
     "  if rem > 112 {\n    sha512_compress_w(state, w)", "extra-block decision off by one (salt+4 = 112 mod 128)"),
    ("pbkdf2_512_truncate_63", "pbkdf2.pion", "let take = if rem < 64 { rem } else { 64 }",
     "let take = if rem < 63 { rem } else { 63 }", "SHA-512 T_i copied one byte short"),
]


def main():
    corpus, baseline = sys.argv[1], sys.argv[2]
    want = open(baseline, "rb").read()
    env = dict(os.environ)
    env["PATH"] = os.path.expanduser("~/.pion/bin") + os.pathsep + env.get("PATH", "")
    env["PION_CACHE_DIR"] = ROOT + "-cas"
    shutil.rmtree(ROOT, ignore_errors=True)
    ok = True
    killed = survived = skipped = 0
    print("| mutant | bug class | result |")
    print("| --- | --- | --- |")
    for name, fname, old, new, why in MUTANTS:
        src = open(os.path.join(PKG, "src", fname)).read()
        if src.count(old) == 0:
            print("| %s | %s | SKIP (anchor not found: line rewritten by a fix?) |" % (name, why))
            skipped += 1
            continue
        d = os.path.join(ROOT, name, "crypto")
        shutil.copytree(os.path.join(PKG, "src"), os.path.join(d, "src"))
        shutil.copy(os.path.join(PKG, "pion.toml"), os.path.join(d, "pion.toml"))
        shutil.copytree(os.path.join(HERE, "oracle"), os.path.join(d, "audit_v040", "oracle"))
        open(os.path.join(d, "src", fname), "w").write(src.replace(old, new, 1))  # first occurrence
        exe = os.path.join(ROOT, name, "oracle")
        b = subprocess.run(["pionc", "build", "--release", "-o", exe, os.path.join(d, "audit_v040", "oracle")],
                           env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if b.returncode != 0:
            print("| %s | %s | FAIL (mutant does not build) |" % (name, why))
            ok = False
            continue
        r = subprocess.run([exe, "vectors", corpus], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        got = r.stdout
        if r.returncode != 0 or got != want:
            wl, gl = want.decode().splitlines(), got.decode(errors="replace").splitlines()
            diffs = [w.split("\t")[0] for w, g in zip(wl, gl) if w != g]
            fams = sorted({x.split("/")[0] if x.startswith("ml/") else "/".join(x.split("/")[:2]) for x in diffs})
            print("| %s | %s | KILLED (%d rows; %s%s) |" % (
                name, why, len(diffs) + abs(len(wl) - len(gl)), ", ".join(fams[:4]),
                "" if r.returncode == 0 else "; exit %d" % r.returncode))
            killed += 1
        else:
            print("| %s | %s | **SURVIVED** |" % (name, why))
            survived += 1
            ok = False
        sys.stdout.flush()
    shutil.rmtree(ROOT, ignore_errors=True)
    shutil.rmtree(ROOT + "-cas", ignore_errors=True)
    print("killed=%d survived=%d skipped=%d" % (killed, survived, skipped))
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
