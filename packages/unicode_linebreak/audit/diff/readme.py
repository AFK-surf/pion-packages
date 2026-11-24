"""Claims of packages/unicode_linebreak/README.md, parsed at run time (nothing hard-coded in run_audit.sh).

  readme.py <README.md> <key>    prints the claimed value; exit 1 when the claim cannot be found
"""
import re
import sys


def claims(t):
    c = {}

    def grab(key, pat, fn=lambda m: m.group(1), flags=0):
        m = re.search(pat, t, flags)
        if m:
            c[key] = fn(m)

    grab("unicode_version", r"Unicode (\d+\.\d+\.\d+) Line Breaking Algorithm")
    grab("unit", r"\*\*`(\d+)/(\d+)` passed\*\* after full implementation", lambda m: m.group(1) + "/" + m.group(2))
    grab("red", r"`(\d+)/(\d+)` passed on stub build", lambda m: m.group(1) + "/" + m.group(2))
    grab("lbtest", r"\*\*`([\d,]+)/([\d,]+)` PASS", lambda m: (m.group(1) + "/" + m.group(2)).replace(",", ""))
    grab("lbtest_total", r"\*\*([\d,]+) test vectors\*\*", lambda m: m.group(1).replace(",", ""))
    grab("smoke_stdout", r"- Stdout: `([^`]+)`")
    grab("smoke_sha", r"- Stdout SHA-256: `([0-9a-f]{64})`")
    grab("wasm_size", r"Wasm32 binary size: `([\d,]+) B`", lambda m: m.group(1).replace(",", ""))
    grab("diff_cases", r"\*\*`(\d+)/(\d+)` PASS \(0 deviations\)\*\*", lambda m: m.group(1) + "/" + m.group(2))
    shas = re.findall(r"Verified stdout SHA-256: `([0-9a-f]{64})`", t)
    if len(shas) == 2:
        c["sha_c1"], c["sha_c2"] = shas
    sp = re.findall(r"^\| `pion_linebreak`[^\n]*\| ([0-9.]+)x \|$", t, re.M)
    if len(sp) == 2:
        c["speedup_c1"], c["speedup_c2"] = sp
    tp = re.findall(r"^\| `pion_linebreak`[^|]*\|[^|]*\|[^|]*\|[^|]*\| ([0-9.]+) \|", t, re.M)
    if len(tp) == 2:
        c["mbps_c1"], c["mbps_c2"] = tp
    m = re.search(r"\*\*`Send` types\*\*[^:]*:(.*)", t)
    if m:
        c["send_types"] = " ".join(x for x in re.findall(r"`([A-Za-z\[\]]+)`", m.group(1)) if x != "String")
    m = re.search(r"\*\*Non-`Send` types\*\*:(.*)", t)
    if m:
        c["notsend_types"] = " ".join(t for t in re.findall(r"`([A-Za-z]+(?:\[[A-Za-z]+\])?)`", m.group(1).split(". ")[0])
                                      if t not in ("E_NOT_SEND", "pionc", "line_breaks", "line_breaks_with_limits"))
    grab("table_kb", r"lookup table \(`([0-9.]+) KB`\)")
    return c


def main(argv):
    t = open(argv[0], encoding="utf-8").read()
    c = claims(t)
    if argv[1] == "all":
        for k, v in sorted(c.items()):
            print("%s=%s" % (k, v))
        return 0
    if argv[1] not in c:
        print("README.md claim %s not found" % argv[1], file=sys.stderr)
        return 1
    print(c[argv[1]])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
