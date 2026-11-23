"""P0 XSS / mXSS red team for html::sanitize (vs ammonia =4.0.0).

For every vector: Pion sanitize -> re-parse the OUTPUT with real html5ever as a <body> fragment
(round-trip mXSS check: script/iframe/svg/math/style/..., on* attrs, javascript:/vbscript:/data: URLs).
Also: idempotence sanitize(sanitize(x)) == sanitize(x), and keep-comments config (`sanc`).
Then a grammar fuzzer (seeded, deterministic) over the same checks.
Usage: xss.py [--fuzz N] [--seed S] [--json out.json]
"""
import json, os, random, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import run, PION, RUST

VECTORS = [
    # classic mXSS
    '<form><math><mtext></form><form><mglyph><style></math><img src onerror=alert(1)>',
    '<noscript><p title="</noscript><img src=x onerror=alert(1)>">',
    '<math><mtext><table><mglyph><style><!--</style><img title="--&gt;&lt;img src=1 onerror=alert(1)&gt;">',
    '<svg><desc><![CDATA[</desc><script>alert(1)</script>]]></svg>',
    '<style><!--</style><script>alert(1)</script>',
    '<iframe srcdoc="<script>alert(1)</script>"></iframe>',
    '<template><script>alert(1)</script></template><img src=x onerror=alert(1)>',
    '<textarea></textarea><script>alert(1)</script></textarea>',
    '<title></title><img src=x onerror=alert(1)></title>',
    '<xmp></xmp><img src=x onerror=alert(1)></xmp>',
    '<textarea>&lt;/textarea&gt;&lt;script&gt;alert(1)&lt;/script&gt;</textarea>',
    '<svg><style><img src=x onerror=alert(1)></style></svg>',
    '<math><style><img src=x onerror=alert(1)></style></math>',
    '<svg></p><style><a id="</style><img src=1 onerror=alert(1)>">',
    '<svg><p><style><img src=x onerror=alert(1)>',
    '<math><mi><mglyph><svg><mtext><textarea><path id="</textarea><img onerror=alert(1) src=1>">',
    '<select><template><style><!--</style><a rel="--></style></template></select><img src=x onerror=alert(1)>">',
    '<plaintext><img src=x onerror=alert(1)>',
    '<script><!--<script></script><img src=x onerror=alert(1)>--></script>',
    '<a href="</a><img src=x onerror=alert(1)>">x</a>',
    '</div title="><img src=x onerror=alert(1)>">',
    '<div </div><img src=x onerror=alert(1)>',
    '<img src=x onerror=alert(1)//',
    '<img/src=x/onerror=alert(1)>',
    '<img src=x on\x00error=alert(1)>',
    '<img src=x ONERROR=alert(1)>',
    '<img src=x OnErRoR=alert(1)>',
    '<img """><script>alert(1)</script>">',
    '<<script>alert(1)//<</script>',
    '<scr<script>ipt>alert(1)</script>',
    '<!--><img src=x onerror=alert(1)>-->',
    '<!---><img src=x onerror=alert(1)>-->',
    '<!--a--!><img src=x onerror=alert(1)>-->',
    '<!-- --!> <img src=x onerror=alert(1)> -->',
    '<?xml ?><img src=x onerror=alert(1)>',
    '<!foo><img src=x onerror=alert(1)>',
    '<![CDATA[><img src=x onerror=alert(1)>]]>',
    '<a href="javascript:alert(1)">x</a>',
    '<a href="JaVaScRiPt:alert(1)">x</a>',
    '<a href="&#x09;javascript:alert(1)">x</a>',
    '<a href="java&#x09;script:alert(1)">x</a>',
    '<a href="java&#x0A;script:alert(1)">x</a>',
    '<a href="java&#x0D;script:alert(1)">x</a>',
    '<a href=" &#14; javascript:alert(1)">x</a>',
    '<a href="&#0000106;avascript:alert(1)">x</a>',
    '<a href="&#106&#97&#118&#97&#115&#99&#114&#105&#112&#116&#58alert(1)">x</a>',
    '<a href="&#x6aavascript:alert(1)">x</a>',
    '<a href="&#x6A;avascript:alert(1)">x</a>',
    '<a href="javascript&colon;alert(1)">x</a>',
    '<a href="javascript&#58;alert(1)">x</a>',
    '<a href="javascript&#x3a;alert(1)">x</a>',
    '<a href=" javascript:alert(1)">x</a>',
    '<a href="​javascript:alert(1)">x</a>',
    '<a href="﻿javascript:alert(1)">x</a>',
    '<a href="\x00javascript:alert(1)">x</a>',
    '<a href="\x01javascript:alert(1)">x</a>',
    '<a href="vbscript:msgbox(1)">x</a>',
    '<a href="data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==">x</a>',
    '<a href="data:text/html,<script>alert(1)</script>">x</a>',
    '<a href="//evil.com">x</a>',
    '<a href="https://ok" href="javascript:alert(1)">x</a>',
    '<a href="javascript:alert(1)" href="https://ok">x</a>',
    '<a HREF="javascript:alert(1)">x</a>',
    '<a href=javascript:alert(1)>x</a>',
    '<a href=\'javascript:alert(1)\'>x</a>',
    '<a href=`javascript:alert(1)`>x</a>',
    '<a href="javascript:alert(1)" rel="nofollow" REL="x">x</a>',
    '<img src="javascript:alert(1)">',
    '<img src="data:image/svg+xml,<svg onload=alert(1)>">',
    '<img srcset="javascript:alert(1) 1x">',
    '<blockquote cite="javascript:alert(1)">q</blockquote>',
    '<q cite="javascript:alert(1)">q</q>',
    '<del cite="javascript:alert(1)">d</del>',
    '<ins cite="javascript:alert(1)">i</ins>',
    '<area href="javascript:alert(1)">',
    '<button formaction="javascript:alert(1)">b</button>',
    '<video poster="javascript:alert(1)"></video>',
    '<a title="x" onmouseover="alert(1)">x</a>',
    '<a title=\'a"b\' >x</a>',
    '<a title="a\'b`c<d>e&f\x00g">x</a>',
    '<p title="&quot;><img src=x onerror=alert(1)>">x</p>',
    '<p title="&amp;quot;&gt;&lt;img src=x onerror=alert(1)&gt;">x</p>',
    '<div style="background:url(javascript:alert(1))">x</div>',
    '<object data="javascript:alert(1)"></object>',
    '<embed src="javascript:alert(1)">',
    '<base href="javascript:alert(1)//">',
    '<meta http-equiv="refresh" content="0;url=javascript:alert(1)">',
    '<link rel=stylesheet href="javascript:alert(1)">',
    '<form action="javascript:alert(1)"><input type=submit></form>',
    '<isindex action="javascript:alert(1)" type=image>',
    '<table background="javascript:alert(1)"><tr><td>x</td></tr></table>',
    '<table><td background="javascript:alert(1)">x</td></table>',
    '<details open ontoggle=alert(1)>x</details>',
    '<img src=x:alert(alt) onerror=eval(src) alt=0>',
    '<a href="&#1;javascript:alert(1)">x</a>',
    '<a href="jav&#x0;ascript:alert(1)">x</a>',
    '<a href="\tjavascript:alert(1)">x</a>',
    '<a href="javas\tcript:alert(1)">x</a>',
    '<a href="javascript\t:alert(1)">x</a>',
    '<a href="ja\nvascript:alert(1)">x</a>',
    '<a href="&NewLine;javascript:alert(1)">x</a>',
    '<a href="&Tab;javascript:alert(1)">x</a>',
    '<a href="java&Tab;script:alert(1)">x</a>',
    '<a href="javascript&#0058;alert(1)">x</a>',
    '<a href="ht\x00tp://ok">x</a>',
    '<svg><a xlink:href="javascript:alert(1)"><text>x</text></a></svg>',
    '<math href="javascript:alert(1)">x</math>',
    '<math><maction actiontype="statusline" xlink:href="javascript:alert(1)">x</maction></math>',
    '<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>',
    '<p>&#60;script&#62;alert(1)&#60;/script&#62;</p>',
    '<p>&lt<script>alert(1)</script></p>',
    '<noembed><img src=x onerror=alert(1)></noembed>',
    '<noframes><img src=x onerror=alert(1)></noframes>',
    '<frameset><frame src="javascript:alert(1)"></frameset>',
    '<applet code="javascript:alert(1)"></applet>',
    '<img src="x" alt="</img><img src=x onerror=alert(1)>">',
    '<div><a href="https://ok/<script>">x</a></div>',
    '<a href="https://ok" target="_blank">x</a>',
    '<x onclick=alert(1)>x</x>',
    '<custom-el onclick=alert(1)>x</custom-el>',
    '<img src="&#x6a;&#x61;&#x76;&#x61;&#x73;&#x63;&#x72;&#x69;&#x70;&#x74;&#x3a;alert(1)">',
    '<a href="&#X6A;avascript:alert(1)">x</a>',
    '<a href="&#106avascript:alert(1)">x</a>',
    '<!--<img src="--><img src=x onerror=alert(1)//">',
    '<!-- <a href="--!><img src=x onerror=alert(1)>"> -->',
    '<p><!--</p><img src=x onerror=alert(1)>-->x</p>',
    '<!--->--><img src=x onerror=alert(1)>',
    '<!----!><img src=x onerror=alert(1)>-->',
    '<!--<!--><img src=x onerror=alert(1)>-->',
    '<b><!--x--!><script>alert(1)</script>--></b>',
    '<?><img src=x onerror=alert(1)>',
    '</ ><img src=x onerror=alert(1)>',
    '<p id="x\r\nonerror=alert(1)">x</p>',
    '<table><tr><td><a href="javascript:alert(1)">x</td></tr></table>',
    '<li><a href="data:,x">x</a></li>',
    '<a href="mailto:x@y">m</a><a href="MAILTO:x">M</a><a href="Https://ok">H</a>',
    '<a href="file:///etc/passwd">f</a><a href="ftp://x">f</a><a href="tel:1">t</a>',
]


def gen(rng, depth=0):
    toks = ['<a href="javascript:alert(1)">', '<img src=x onerror=alert(1)>', '<svg>', '</svg>', '<math>', '</math>',
            '<mtext>', '<mglyph>', '<style>', '</style>', '<script>', '</script>', '<!--', '-->', '--!>', '<!-->',
            '<noscript>', '</noscript>', '<textarea>', '</textarea>', '<title>', '</title>', '<template>', '</template>',
            '<table>', '<tr>', '<td>', '</table>', '<p>', '</p>', '<b>', '</b>', '<form>', '</form>', '<select>',
            '<option>', '"', "'", '>', '<', '&lt;', '&gt;', '&quot;', '&#x09;', '&colon;', 'javascript:', ' title="',
            '<![CDATA[', ']]>', '<iframe>', '</iframe>', '<xmp>', '</xmp>', '<div title="', '<a title="', '</a>',
            'alert(1)', '<desc>', '<foreignObject>', '<plaintext>', '<?x', '<!x', '</ x', '\x00', '\r', '<br/>',
            '<img src="javascript:alert(1)">', '<area href="vbscript:x">', '<blockquote cite="data:text/html,x">']
    return "".join(rng.choice(toks) for _ in range(rng.randint(1, 18)))


def main():
    fuzz = int(sys.argv[sys.argv.index("--fuzz") + 1]) if "--fuzz" in sys.argv else 20000
    seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 1337
    rng = random.Random(seed)
    corpus = VECTORS + [gen(rng) for _ in range(fuzz)]
    report = {"vectors": len(VECTORS), "fuzz": fuzz, "seed": seed}
    for cfg in ("san", "sanc"):
        outs = run(PION, cfg, corpus)
        checks = run(RUST, "check", outs)
        again = run(PION, cfg, outs)
        unsafe = [(i, corpus[i], outs[i], checks[i]) for i in range(len(corpus)) if checks[i] != "SAFE"]
        nonidem = [(i, corpus[i], outs[i], again[i]) for i in range(len(corpus)) if again[i] != outs[i]]
        report[cfg] = {"unsafe": len(unsafe), "non_idempotent": len(nonidem),
                       "unsafe_examples": unsafe[:15], "non_idempotent_examples": nonidem[:10]}
        print(f"[{cfg}] corpus={len(corpus)} roundtrip-unsafe={len(unsafe)} non-idempotent={len(nonidem)}")
        for u in unsafe[:15]:
            print(f"   UNSAFE in={u[1]!r}\n          out={u[2]!r}\n          html5ever-reparse={u[3]}")
        for u in nonidem[:5]:
            print(f"   NON-IDEMPOTENT in={u[1]!r}\n          once={u[2]!r}\n          twice={u[3]!r}")
    # ammonia on the hand-written vectors (reference behaviour + its own round-trip)
    amm = run(RUST, "san", VECTORS)
    amm_chk = run(RUST, "check", amm)
    pion = run(PION, "san", VECTORS)
    diffs = [(VECTORS[i], pion[i], amm[i]) for i in range(len(VECTORS)) if pion[i] != amm[i]]
    report["ammonia_unsafe"] = sum(1 for c in amm_chk if c != "SAFE")
    report["vector_output_diffs_vs_ammonia"] = len(diffs)
    report["vector_diffs"] = diffs
    print(f"[ammonia] vectors={len(VECTORS)} roundtrip-unsafe={report['ammonia_unsafe']} pion!=ammonia outputs={len(diffs)}")
    if "--json" in sys.argv:
        json.dump(report, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
