"""Bug injection for the idna audit: each mutant is a copy of packages/idna (src + audit package) in <outdir>
with one realistic bug; run_audit.sh builds the mutant's audit CLI and runs every `control_*` case, which must
catch it. The repository is never modified.

  inject.py <pkg_dir> <outdir>   prints `<n> <mutant_dir|SKIP> <description>` per mutant
A mutant whose target text is no longer present exactly once (the package changed) is reported as SKIP.
"""
import os
import shutil
import sys

MUTANTS = [
    ("src/punycode.pion", "      if digit < t {\n        break\n      }",
     "      if digit <= t {\n        break\n      }",
     "RFC 3492 decoder: off-by-one in the variable-length integer threshold (digit <= t)"),
    ("src/uts46.pion", "      if has_en && has_an {\n        return li\n      }\n", "",
     "RFC 5893 Bidi rule 4 (EN and AN mixed in an RTL label) dropped"),
    ("src/uts46.pion", "  if ln >= 4 && lab[2] == 45 && lab[3] == 45 {\n    return false\n  }\n", "",
     "CheckHyphens: '--' in positions 3-4 no longer rejected on the full UTS #46 path"),
    ("src/uts46.pion", "      if i == 0 || unicode_ccc(label[i - 1]) != 9 {",
     "      if i == 0 || unicode_ccc(label[i - 1]) == 9 {",
     "RFC 5892 A.2 ContextJ: ZWJ virama test inverted"),
    ("src/uts39.pion", "!has_latin && script_ids.length() == 1 {", "!has_latin && script_ids.length() == 2 {",
     "UTS #39 whole-script confusable test never fires (single-script condition broken)"),
    ("src/uts46.pion", "      if llen > 63 {", "      if llen > 64 {",
     "VerifyDnsLength: 64-byte labels accepted"),
    ("src/uts46.pion", "              if !cps_equal(dec, dec_nfc) {", "              if false && !cps_equal(dec, dec_nfc) {",
     "UTS #46 V1: non-NFC Punycode labels accepted"),
]


def main():
    pkg, out = sys.argv[1], sys.argv[2]
    for n, (rel, old, new, desc) in enumerate(MUTANTS, 1):
        src = open(os.path.join(pkg, rel), encoding="utf-8").read()
        if src.count(old) != 1:
            print("%d SKIP %s" % (n, desc))
            continue
        root = os.path.join(out, "m%d" % n, "idna")
        if os.path.exists(root):
            shutil.rmtree(root)
        shutil.copytree(os.path.join(pkg, "src"), os.path.join(root, "src"))
        shutil.copy(os.path.join(pkg, "pion.toml"), os.path.join(root, "pion.toml"))
        a = os.path.join(root, "audit")
        shutil.copytree(os.path.join(pkg, "audit", "src"), os.path.join(a, "src"))
        shutil.copy(os.path.join(pkg, "audit", "pion.toml"), os.path.join(a, "pion.toml"))
        with open(os.path.join(root, rel), "w", encoding="utf-8") as f:
            f.write(src.replace(old, new))
        print("%d %s %s" % (n, a, desc))


if __name__ == "__main__":
    main()
