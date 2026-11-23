"""RT-crypto-v030 mutation sensitivity check: proves the Go-oracle corpus is not vacuous.

For each mutant, copies packages/crypto to /private/tmp/rt-crypto-v030-mut/<id>/ (the git worktree is
never touched), applies one exact source replacement that re-creates a classic bug, rebuilds the
audit oracle (native --release) and runs the corpus. A mutant must produce >= 1 mismatch against
the Go expectations ("KILLED"). If its anchor text no longer exists (the code was refactored), the
mutant is reported SKIP, not FAIL, so later fix branches can rerun this without editing it.

Usage: python3 mutants.py <corpus.tsv> <expected.out>   (exit 0 = every applicable mutant killed)
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
OUT = "/private/tmp/rt-crypto-v030-mut"

MUTANTS = [
    ("M1-inc32-carries-into-128bit", "src/aes_gcm.pion",
     "  let mut i = 15\n  while i >= 12 {", "  let mut i = 15\n  while i >= 0 {"),
    ("M2-gcm-skip-tag-check", "src/aes_gcm.pion",
     "  if !constant_time_eq(computed_tag, expected_tag) {", "  if false && !constant_time_eq(computed_tag, expected_tag) {"),
    ("M3-ghash-drop-length-block", "src/aes_gcm.pion",
     "  ghash_update_block_be(st, aad_bits, ct_bits)", "  ghash_update_block_be(st, 0UL, ct_bits)"),
    ("M4-j0-nonce12-counter-0", "src/aes_gcm.pion",
     "    j0[15] = (1).to_byte()", "    j0[15] = (0).to_byte()"),
    ("M5-p256-accept-y-ge-p", "src/p256.pion",
     "    if big_cmp(x, ctx.p) >= 0 || big_cmp(y, ctx.p) >= 0 {", "    if big_cmp(x, ctx.p) >= 0 {"),
    ("M6-p256-skip-on-curve", "src/p256.pion",
     "    if !big_eq(lhs, rhs) {", "    if false && !big_eq(lhs, rhs) {"),
    ("M7-p256-compressed-parity-swapped", "src/p256.pion",
     "    let want_odd = prefix == 0x03", "    let want_odd = prefix == 0x02"),
    ("M8-p256-skip-sqrt-check (twist)", "src/p256.pion",
     "    if !big_eq(check, rhs) || big_is_zero(y_root) {", "    if big_is_zero(y_root) {"),
    ("M9-ecdh-accept-d-eq-n", "src/p256.pion",
     "  if big_is_zero(d) || big_cmp(d, n) >= 0 {\n    return Err(CryptoError::InvalidScalar)\n  }\n  let ctx = p256_ctx()\n  let (px, py)",
     "  if big_is_zero(d) || big_cmp(d, n) > 0 {\n    return Err(CryptoError::InvalidScalar)\n  }\n  let ctx = p256_ctx()\n  let (px, py)"),
    ("M10-p256-accept-hybrid-06", "src/p256.pion",
     "    if (pubkey[0].to_int() & 0xFF) != 0x04 {", "    if (pubkey[0].to_int() & 0xFF) != 0x04 && (pubkey[0].to_int() & 0xFF) != 0x06 {"),
]


def main():
    corpus, expected = sys.argv[1], sys.argv[2]
    want = open(expected).read().splitlines()
    env = dict(os.environ)
    env["PATH"] = os.path.expanduser("~/.pion/bin") + os.pathsep + env.get("PATH", "")
    env["PION_CACHE_DIR"] = OUT + "-cas"
    shutil.rmtree(OUT, ignore_errors=True)
    ok = True
    for mid, rel, old, new in MUTANTS:
        src_path = os.path.join(PKG, rel)
        text = open(src_path).read()
        if text.count(old) != 1:
            print("SKIP    %-38s anchor not found (code refactored)" % mid)
            continue
        root = os.path.join(OUT, mid.split()[0])
        dst = os.path.join(root, "crypto")
        shutil.copytree(PKG, dst, ignore=shutil.ignore_patterns("bench", "audit", ".git"))
        with open(os.path.join(dst, rel), "w") as f:
            f.write(text.replace(old, new))
        exe = os.path.join(root, "oracle")
        b = subprocess.run(["pionc", "build", "--release", "-o", exe, os.path.join(dst, "audit_v030", "oracle")],
                           env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if b.returncode != 0:
            print("SKIP    %-38s mutant does not compile" % mid)
            continue
        r = subprocess.run([exe, "vectors", corpus], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        got = r.stdout.decode(errors="replace").splitlines()
        diffs = [w.split("\t")[0] for w, g in zip(want, got) if w != g]
        diffs += ["<missing lines>"] * abs(len(want) - len(got))
        if r.returncode not in (0,) and not diffs:
            diffs = ["<oracle exit %d>" % r.returncode]
        how = "corpus"
        if not diffs:
            # Error-kind mutants (e.g. d = n now fails later with InvalidPoint instead of InvalidScalar)
            # are invisible to the ERR-only corpus; the control tests assert exact CryptoError kinds.
            t = subprocess.run(["pionc", "test", "--json", os.path.join(dst, "audit_v030", "tests")],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if t.returncode != 0:
                how = "control tests"
                diffs = ["<control test failed>"]
        status = "KILLED" if diffs else "SURVIVED"
        ok = ok and bool(diffs)
        print("%-8s %-38s by %-13s %5d mismatches  e.g. %s" % (status, mid, how, len(diffs), diffs[0] if diffs else "-"))
    shutil.rmtree(OUT, ignore_errors=True)
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
