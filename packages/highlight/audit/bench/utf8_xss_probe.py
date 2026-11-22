#!/usr/bin/env python3
"""UTF-8 boundary + HTML-escaping (XSS) probe over all 17 languages.
Checks for every input: (1) no span boundary falls inside a UTF-8 sequence, (2) highlight_html output is valid
UTF-8, (3) the only raw `<`/`>` in the output belong to `<span class="hl-...">` / `</span>`, (4) no raw `"`/`'`/`&`
outside markup, (5) tag-stripped + entity-decoded output == source. usage: utf8_xss_probe.py <probe-bin>"""
import os, random, re, subprocess, sys, tempfile

PROBE = sys.argv[1]
LANGS = "pion rust go typescript javascript python c cpp json toml yaml sql shell html css diff markdown".split()
FIXED = [
    "let x = a·b × c ≠ d → e€ 'é' \"ü\" /* ☃ */ // 😀\n",
    "a\u2028b\u00a0c\u200bd\ufeffe 中文 = «q»\n",
    "<p title=\"😀\">é&ü</p> #é .ü { ü: é; }\n",
    "\U0001F468\u200d\U0001F469\u200d\U0001F467 + 1e5ü 0x😀 'a😀' $😀 ${😀} @😀 #😀 [[😀\n",
    "</span><script>alert(1)</script><img src=x onerror=alert(1)> \"><svg/onload=alert`1`> &lt; &#x3C; '\n",
    "// </span><b>\n\"</span>\" '<' `${'<\"'}` /* & */ # <x>\n",
    "\r\n\r\r\n\t\x00\x01\x7f\n",
]
random.seed(7)
ALPH = list("abc019 '\"`/\\*#$@{}()[]<>!-+.:;,=&\n\r") + ["é", "中", "😀", "\u200d", "·", "→"]
RANDOM = ["".join(random.choice(ALPH) for _ in range(300)) for _ in range(60)]
SPAN = re.compile(rb'<span class="hl-[a-z-]+">|</span>')

def run(mode, lang, data):
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(data)
        p = f.name
    try:
        return subprocess.run([PROBE, mode, lang, p], capture_output=True, check=True).stdout
    finally:
        os.unlink(p)

def decode(h):
    t = SPAN.sub(b"", h)
    for a, b in ((b"&lt;", b"<"), (b"&gt;", b">"), (b"&quot;", b'"'), (b"&#39;", b"'"), (b"&amp;", b"&")):
        t = t.replace(a, b)
    return t

fails = {"split": [], "invalid_utf8": [], "raw_markup": [], "roundtrip": []}
for lang in LANGS:
    for si, s in enumerate(FIXED + RANDOM):
        b = s.encode()
        for line in run("spans", lang, b).decode().splitlines():
            st, en, k = line.split(" ")
            for off in (int(st), int(en)):
                if off < len(b) and (b[off] & 0xC0) == 0x80:
                    fails["split"].append((lang, si, off, k, b[max(0, off - 4):off + 4]))
        h = run("html", lang, b)
        try:
            h.decode("utf-8")
        except UnicodeDecodeError as e:
            fails["invalid_utf8"].append((lang, si, str(e)[:80]))
        rest = SPAN.sub(b"", h)
        if re.search(rb"[<>\"']", rest) or re.search(rb"&(?!(amp|lt|gt|quot|#39);)", rest):
            fails["raw_markup"].append((lang, si))
        if decode(h) != b:
            fails["roundtrip"].append((lang, si))

for k, v in fails.items():
    print(f"{k}: {len(v)}")
    for x in v[:6]:
        print("   ", x)
seen = sorted({(x[0]) for x in fails["split"]})
print("languages with split UTF-8 boundaries:", seen or "none")
