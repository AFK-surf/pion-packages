#!/usr/bin/env python3
"""Incremental-state probe: per-byte class of highlight() vs editor-style highlight_line() (lines fed WITHOUT
terminators) vs highlight() on the same text with CRLF endings. usage: incremental_probe.py <probe-bin>"""
import os, subprocess, sys, tempfile

PROBE = sys.argv[1]
CASES = [
    ("rust", 'let s = r##"a\n"# b\n"##; /* a\n/* b */\nc */ x\n'),
    ("pion", "let s =\n  #|raw \\{x}\n  #|more\n/* a /* b */\n*/ let y = 1\n"),
    ("typescript", "const t = `a\n${b + `c\nd`}\ne`; f\n/* x\n*/ g\n"),
    ("javascript", "const t = `a\n${ {k: 1} }\nc`; d\n"),
    ("python", 'x = """a\nb\'\'\'"""\ny = r\'\'\'c\nd\'\'\'\nz = 1\n'),
    ("go", "r := `a\nb // x`\nc := 1 /* d\ne */\n"),
    ("c", "/* a\nb */ int x;\n#define X 1\n"),
    ("cpp", "/* a\n*/ auto x = 1;\n"),
    ("json", '{\n  "a": [1,\n  2], // c\n  "b": "x"\n}\n'),
    ("toml", 'a = """\nx # y\n"""\nb = \'\'\'\nz\n\'\'\'\nc = 1\n'),
    ("yaml", "key: |\n  a\n  b # x\nnext: >\n  c\nn: 1\n"),
    ("sql", "SELECT /* a\nb */ 1, 'x\ny' FROM t;\n"),
    ("shell", "echo a # c\nif [ 1 ]; then\n  ls\nfi\n"),
    ("html", "<!-- a\nb -->\n<div\n  class=\"x\">\n<script>\nlet x = 1\n</script>\n<style>\na { b: c }\n</style>\n"),
    ("css", "/* a\nb */ .x {\n  color: red;\n}\n"),
    ("diff", "--- a\n+++ b\n@@ -1 +1 @@\n-x\n+y\n"),
    ("markdown", "# T\n```js\nlet x = 1\n```\n~~~\ny\n~~~\ntext\n"),
]

def kinds(mode, lang, data):
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(data)
        path = f.name
    try:
        out = subprocess.run([PROBE, mode, lang, path], capture_output=True, text=True, check=True).stdout
    finally:
        os.unlink(path)
    k = ["?"] * len(data)
    for line in out.splitlines():
        a, b, c = line.split(" ")
        for i in range(int(a), int(b)):
            k[i] = c
    return k

total_bad = 0
print("| language | bytes | full vs editor-lines (no `\\n`) | full vs CRLF |")
print("| --- | ---: | ---: | ---: |")
for lang, text in CASES:
    src = text.encode()
    full = kinds("spans", lang, src)
    nonl = kinds("lines-nonl", lang, src)
    crlf = src.replace(b"\n", b"\r\n")
    fc_raw = kinds("spans", lang, crlf)
    fc = [fc_raw[i] for i in range(len(crlf)) if not (crlf[i] == 13 and i + 1 < len(crlf) and crlf[i + 1] == 10)]
    d1 = sum(1 for i in range(len(src)) if src[i] != 10 and full[i] != nonl[i])
    d2 = sum(1 for i in range(len(src)) if src[i] != 10 and full[i] != fc[i])
    total_bad += d1 + d2
    print(f"| {lang} | {len(src)} | {d1} differing bytes | {d2} differing bytes |")
print(f"\nTOTAL differing bytes: {total_bad}")
