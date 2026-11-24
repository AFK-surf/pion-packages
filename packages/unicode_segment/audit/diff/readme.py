"""Extract the claims packages/unicode_segment/README.md makes, so run_audit.sh hard-codes none of them.

    python3 -I -B readme.py <README.md> <key>
"""

import re
import sys


def claims(text):
    c = {}

    def one(key, pat, conv=lambda m: m.group(1)):
        m = re.search(pat, text)
        if m:
            c[key] = conv(m)

    one("unit_pass", r"\*\*(\d+)/(\d+)\*\* tests")
    one("unit_total", r"\*\*(\d+)/(\d+)\*\* tests", lambda m: m.group(2))
    for key, f in (("gb", "Grapheme"), ("wb", "Word"), ("sb", "Sentence")):
        one(key, r"`%sBreakTest\.txt` \| ([\d,]+) / ([\d,]+)" % f, lambda m: m.group(1).replace(",", "") + "/" + m.group(2).replace(",", ""))
    one("smoke_stdout", r"- Stdout: `([^`]+)`")
    one("smoke_sha", r"Stdout SHA-256 \(all 4 modes\): `([0-9a-f]{64})`")
    one("wasm_dbg", r"`([\d,]+) B` \(debug\)", lambda m: m.group(1).replace(",", ""))
    one("wasm_rel", r"/ `([\d,]+) B` \(`--release`\)", lambda m: m.group(1).replace(",", ""))
    one("diff_cases", r"\*\*(\d+)/\d+\*\* multilingual")
    shas = re.findall(r"Verified stdout SHA-256: `([0-9a-f]{64})`", text)
    if len(shas) >= 2:
        c["sha_multi"], c["sha_tech"] = shas[0], shas[1]
    sp = re.findall(r"^\| `pion_segment`.*\| ([0-9.]+)x \|$", text, re.M)
    if len(sp) >= 2:
        c["speedup_multi"], c["speedup_tech"] = sp[0], sp[1]
    one("rust_unicode", r"unicode-segmentation 1\.13\.3` \(Unicode ([0-9.]+) aligned\)")
    m = re.search(r"\*\*`Send` types\*\*[^:]*:(.*)", text)
    if m:
        c["send_types"] = " ".join(t for t in re.findall(r"`([A-Za-z_\[\]]+)`", m.group(1)))
    m = re.search(r"\*\*Non-`Send` types\*\*:(.*?)returned", text)
    if m:
        c["notsend_types"] = " ".join(re.findall(r"`([A-Za-z_\[\]]+)`", m.group(1)))
    c["mutex_claim"] = "1" if "Mutex::new(...)" in text else "0"
    return c


if __name__ == "__main__":
    c = claims(open(sys.argv[1], encoding="utf-8").read())
    if sys.argv[2] == "all":
        for k, v in sorted(c.items()):
            print("%s=%s" % (k, v))
        sys.exit(0)
    if sys.argv[2] not in c:
        sys.exit(1)
    print(c[sys.argv[2]])
