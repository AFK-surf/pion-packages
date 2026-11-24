"""Parse the numbers packages/idna/README.md claims, so that run_audit.sh never hard-codes them.

  readme.py <README.md> <key>
keys: smoke_stdout smoke_sha wasm_dbg wasm_rel unit_pass unit_total diff_cases idnatest_valid idnatest_valid_total
      rust_agree rust_total speedup_mixed speedup_rw sha_mixed sha_rw unicode_version send_types notsend_types
      restrictive
A key that is not found exits 1 (the claim was removed or reworded: run_audit.sh reports it, never guesses).
"""
import re
import sys


def num(s):
    return s.replace(",", "")


def main():
    t = open(sys.argv[1], encoding="utf-8").read()
    key = sys.argv[2]
    pats = {
        "smoke_stdout": r"Stdout: `(idna_wasm_smoke:[^`]*)`",
        "smoke_sha": r"Stdout SHA-256: `([0-9a-f]{64})`",
        "wasm_dbg": r"Wasm32 binary size: `([0-9,]+) B` \(debug\)",
        "wasm_rel": r"`([0-9,]+) B` \(`--release`\)",
        "unit_pass": r"All \*\*([0-9]+)/[0-9]+\*\* tests",
        "unit_total": r"All \*\*[0-9]+/([0-9]+)\*\* tests",
        "diff_cases": r"\*\*([0-9]+)/[0-9]+ PASS",
        "idnatest_valid": r"Spec valid vectors: \*\*([0-9,]+)/",
        "idnatest_valid_total": r"Spec valid vectors: \*\*[0-9,]+/([0-9,]+)",
        "rust_agree": r"Exact agreement with Rust `idna 1\.1\.0`: \*\*([0-9,]+)/",
        "rust_total": r"Exact agreement with Rust `idna 1\.1\.0`: \*\*[0-9,]+/([0-9,]+)",
        "speedup_mixed": r"Corpus 1:.*?\| `pion_idna`[^\n]*\| ([0-9.]+)x \|",
        "speedup_rw": r"Corpus 2:.*?\| `pion_idna`[^\n]*\| ([0-9.]+)x \|",
        "sha_mixed": r"Corpus 1:.*?Verified stdout SHA-256: `([0-9a-f]{64})`",
        "sha_rw": r"Corpus 2:.*?Verified stdout SHA-256: `([0-9a-f]{64})`",
        "unicode_version": r"Unicode ([0-9]+\.[0-9]+\.[0-9]+)",
        "restrictive": r"UTS #39 (Highly|Moderately|Minimally) Restrictive",
    }
    if key == "send_types":
        m = re.search(r"\*\*`Send` types\*\*[^:]*:(.*)", t)
        if not m:
            sys.exit(1)
        print(" ".join(x for x in re.findall(r"`([A-Za-z]+)`", m.group(1)) if x != "String"))
        return
    if key == "notsend_types":
        m = re.search(r"\*\*Non-`Send` types\*\*:(.*)", t)
        if not m:
            sys.exit(1)
        print(" ".join(x for x in re.findall(r"`([A-Z][A-Za-z]+)`", m.group(1).split("(")[0])))
        return
    m = re.search(pats[key], t, re.S)
    if not m:
        sys.exit(1)
    print(num(m.group(1)))


if __name__ == "__main__":
    main()
