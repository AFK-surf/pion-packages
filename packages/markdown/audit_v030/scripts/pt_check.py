#!/usr/bin/env python3
"""plain_text invariants over a fuzz + handcrafted corpus (harness `ptbatch`).

Per input, 6 option sets are rendered (see harness): S1 collapse/unlimited, S2 collapse/unlimited/
placeholders, S3 multiline/unlimited/placeholders, S4 collapse/max=1, S5 collapse/max=7/placeholders,
S6 multiline/max=13/placeholders. Invariants:
  I1 every output is valid UTF-8;
  I2 code points of S4/S5/S6 <= max_chars;
  I3 S4 is a prefix of S1, S5 of S2, S6 of S3 (truncation never alters what precedes the cut);
  I4 collapse outputs have no leading space, no "\\n", no double ASCII space.
usage: pt_check.py <harness_bin> <out_dir> [--fuzz N]
"""
import os, random, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "audit", "scripts"))
from corpus import handcrafted  # noqa: E402

H, OUT = sys.argv[1:3]
FUZZ = int(sys.argv[sys.argv.index("--fuzz") + 1]) if "--fuzz" in sys.argv else 3000
os.makedirs(OUT, exist_ok=True)
ATOMS = ["*", "**", "_", "~~", "`", "[", "]", "(u)", "![", "](u)", "<", ">", "\\", "&amp;", "&#x4F60;",
         "|", "-", "1.", "#", "\t", "  ", " ", "\n", "\n\n", "\r\n", "a", "é", "é", "你", "好",
         "世界", "😀", "👨‍👩‍👧", "🇨🇳", "　", " ", "<div>", "</div>", "<b>",
         "</b>", "<!--", "-->", "<br>", "    ", "> ", "- ", "- [x] ", "```", "$", "|-|-|\n",
         "|a|b|\n", "[^1]", "[^1]: n\n"]
r = random.Random(0xC0DE)
srcs = [s for _, s in handcrafted()] + ["".join(r.choice(ATOMS) for _ in range(r.randint(1, 30)))
                                         for _ in range(FUZZ)]
cases = [(m, s) for s in srcs for m in (7, 7 | 64)]
inp = os.path.join(OUT, "pt.in")
with open(inp, "wb") as f:
    for m, s in cases:
        b = s.encode("utf-8")
        f.write(f"{m}\t{len(b)}\n".encode() + b)
p = subprocess.run([H, "ptbatch", inp], capture_output=True, timeout=900)
if p.returncode != 0:
    print(f"harness rc={p.returncode}")
    sys.exit(2)
data, fr, i = p.stdout, [], 0
while i < len(data):
    nl = data.index(b"\n", i)
    ln = int(data[i:nl])
    fr.append(data[nl + 1:nl + 1 + ln])
    i = nl + 1 + ln
assert len(fr) == 6 * len(cases)
viol = {"I1": [], "I2": [], "I3": [], "I4": []}
for k, (m, s) in enumerate(cases):
    o = fr[6 * k:6 * k + 6]
    try:
        t = [x.decode("utf-8") for x in o]
    except UnicodeDecodeError:
        viol["I1"].append(s)
        continue
    for idx, mx in ((3, 1), (4, 7), (5, 13)):
        if len(t[idx]) > mx:
            viol["I2"].append((s, idx + 1, t[idx]))
    for a, b in ((3, 0), (4, 1), (5, 2)):
        if not t[b].startswith(t[a]):
            viol["I3"].append((s, a + 1, t[a], t[b]))
    for idx in (0, 1, 3, 4):
        x = t[idx]
        if x.startswith(" ") or "\n" in x or "  " in x:
            viol["I4"].append((s, idx + 1, x))
print(f"cases={len(cases)} outputs={len(fr)} " + " ".join(f"{k}={len(v)}" for k, v in viol.items()))
for k, v in viol.items():
    for e in v[:3]:
        print(f"  {k} {e!r}"[:300])
sys.exit(1 if any(viol.values()) else 0)
