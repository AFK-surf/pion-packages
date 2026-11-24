#!/usr/bin/env python3
"""Headless Chrome as a live CSS Color 4/5 oracle (validity via CSS.supports + computed `color` serialization).
  python3 -I chrome.py <casefile> <out> [chrome binary]
Case lines are `<target>\t<input>` (target ignored); inputs may be `hex:<utf-8 bytes>`.
Output: one line per case: `V\t<computed>` (valid) or `I` (invalid). Nothing is written in the repository: the page
and the throw-away profile live next to <out>."""
import json, os, subprocess, sys, tempfile, html

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def decode(s):
    if s.startswith("hex:"):
        return bytes.fromhex(s[4:]).decode("utf-8", "surrogateescape")
    return s


def main():
    cases, out = sys.argv[1], sys.argv[2]
    chrome = sys.argv[3] if len(sys.argv) > 3 else CHROME
    inputs = []
    for line in open(cases, encoding="utf-8", errors="surrogateescape").read().split("\n"):
        if line == "":
            continue
        inputs.append(decode(line.split("\t", 1)[1] if "\t" in line else line))
    work = tempfile.mkdtemp(prefix="chrome-oracle-", dir=os.path.dirname(os.path.abspath(out)))
    page = os.path.join(work, "page.html")
    data = json.dumps(inputs, ensure_ascii=True)
    with open(page, "w", encoding="ascii") as f:
        f.write("<!doctype html><meta charset=utf-8><body><div id=t></div><pre id=o></pre><script>\n")
        f.write("const xs=" + data.replace("</", "<\\/") + ";\nconst t=document.getElementById('t');const r=[];\n")
        f.write("for(const x of xs){let v='I';try{if(CSS.supports('color',x)){t.style.color='';t.style.color=x;"
                "v='V\\t'+getComputedStyle(t).color;}}catch(e){v='I';}r.push(v);}\n"
                "document.getElementById('o').textContent=JSON.stringify(r);</script>\n")
    dom = subprocess.run([chrome, "--disable-gpu", "--no-first-run", "--no-default-browser-check",
                          "--user-data-dir=" + os.path.join(work, "profile"), "--virtual-time-budget=60000",
                          "--dump-dom", "file://" + page], capture_output=True, text=True, timeout=600).stdout
    i = dom.index('<pre id="o">') + len('<pre id="o">')
    res = json.loads(html.unescape(dom[i:dom.index("</pre>", i)]))
    assert len(res) == len(inputs), (len(res), len(inputs))
    with open(out, "w", encoding="utf-8") as f:
        for v in res:
            f.write(v + "\n")
    subprocess.run(["rm", "-rf", work])
    print("chrome: %d cases, %d valid (%s)" % (len(res), sum(1 for v in res if v != "I"),
          subprocess.run([chrome, "--version"], capture_output=True, text=True).stdout.strip()))


if __name__ == "__main__":
    main()
