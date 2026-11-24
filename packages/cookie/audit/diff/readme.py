"""Extract the numbers packages/cookie/README.md claims (parsed at run time; nothing is hard-coded in run_audit.sh).

    readme.py <README.md> <key> [arg]

keys: smoke_sha | smoke_lines | sizes ("ndbg nrel wdbg wrel" KiB) | rules ("total icann private") | table_kib |
      tests | diffcounts ("parse_ok parse_n psl_ok psl_n") | bench <parse|psl> ("pion_ms rust_ms speedup") |
      psl_snapshot (prints the date / commit the README gives for the embedded PSL, or "none")
"""

import re
import sys


def num(s):
    return float(s.replace(",", ""))


def main():
    text = open(sys.argv[1], encoding="utf-8").read()
    key = sys.argv[2]
    if key == "smoke_sha":
        m = re.search(r"SHA-256:\s*`([0-9a-f]{64})`", text)
        print(m.group(1) if m else "none")
    elif key == "smoke_lines":
        # the backticked stdout lines listed right before the SHA-256 line of the 4-mode section
        sec = text[text.find("4-Mode"):]
        sec = sec[:sec.find("SHA-256")]
        for m in re.finditer(r"^\s*-\s*`([^`]+)`\s*$", sec, re.M):
            print(m.group(1))
    elif key == "sizes":
        vals = re.findall(r"`(native debug|native --release|wasm32 debug|wasm32 --release)`\s*\(\*\*([\d.]+) KiB\*\*\)", text)
        d = dict(vals)
        print(" ".join(d.get(k, "nan") for k in ("native debug", "native --release", "wasm32 debug", "wasm32 --release")))
    elif key == "rules":
        m = re.search(r"\*\*([\d,]+)\*\* rules: \*\*([\d,]+)\*\* ICANN \+ \*\*([\d,]+)\*\* Private", text)
        print(" ".join(str(int(num(x))) for x in m.groups()) if m else "nan nan nan")
    elif key == "table_kib":
        m = re.search(r"sorted immutable string literal \(\*\*([\d.]+) KiB\*\*\)", text)
        print(m.group(1) if m else "nan")
    elif key == "tests":
        m = re.search(r"\*\*(\d+)\*\* test groups", text)
        print(m.group(1) if m else "nan")
    elif key == "diffcounts":
        a = re.search(r"Set-Cookie Parsing\*\*[^\n]*?\*\*(\d+) / (\d+)\*\*", text)
        b = re.search(r"Mozilla PSL Lookup\*\*[^\n]*?\*\*(\d+) / (\d+)\*\*", text)
        print(" ".join(a.groups() + b.groups()) if a and b else "nan nan nan nan")
    elif key == "bench":
        label = {"parse": "Set-Cookie Parsing", "psl": "Mozilla PSL Lookup"}[sys.argv[3]]
        for line in text.splitlines():
            if line.startswith("| " + label):
                cells = [c.strip() for c in line.strip("|").split("|")]
                pion_ms = num(cells[1])
                rust_ms = num(cells[3].split()[0])
                speed = num(cells[5].rstrip("x"))
                print(pion_ms, rust_ms, speed)
                return
        print("nan nan nan")
    elif key == "psl_snapshot":
        m = re.search(r"(?:Public Suffix List|PSL)[^\n]{0,240}?(\d{4}-\d{2}-\d{2}|\b[0-9a-f]{7,40}\b)", text)
        print(m.group(1) if m else "none")
    else:
        sys.exit(2)


if __name__ == "__main__":
    main()
