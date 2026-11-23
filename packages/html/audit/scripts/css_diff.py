"""CSS selector differential: Pion html::Selector vs Rust scraper =0.22.0 (Servo `selectors`).

Documents are chosen so that Pion and html5ever build the SAME tree (checked: tree dumps equal),
so every result difference is a selector-engine difference. Output = pre-order element indices.
Usage: css_diff.py [--json out.json]
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import run, PION, RUST

DOC = ('<!DOCTYPE html><html lang="en-US"><head><title>t</title></head><body>'
       '<div id="main" class="a b" data-x="foo bar" title="Hello World">'
       '<ul class="list"><li class="item first" lang="en">1</li><li class="item" lang="en-GB">2</li>'
       '<li class="item" lang="fr">3</li><li class="item\tlast" data-v="a\tb\nc">4</li><li>5</li><li>6</li><li>7</li></ul>'
       '<p id="123">digits</p><p class="foo.bar">dot</p><p class="x:y">colon</p><p id="a b">space</p>'
       '<span></span><span> </span><span><!--c--></span><em>e</em>'
       '<a href="https://example.com/x.pdf" hreflang="en">pdf</a><a href="HTTP://EXAMPLE.COM">up</a><a>none</a>'
       '<input type="TEXT" value=""><input type="checkbox" checked>'
       '</div><section><h1>h</h1><p>p1</p><p>p2</p><div><p>p3</p></div></section></body></html>')

SELS = [
    "li", "LI", "Li.item", "*", "div *", "#main", "#123", "#\\31 23", "#\\31\\32\\33", ".foo\\.bar", ".x\\:y", "#a\\ b",
    ".item", ".item.first", ".last", "li.item:not(.first)", "li:not(.item)", ":not(li)", "li:not(.first, .last)",
    "li:not(.first.item)", "li:not(:first-child)",
    "[lang]", "[lang=en]", "[lang|=en]", "[lang|=EN]", "[lang|=en i]", "[lang=EN i]", "[lang=EN s]", "[lang='en']",
    '[lang="en"]', "[data-x~=bar]", "[data-x~='foo bar']", "[data-v~=b]", "[data-v~=c]", "[class~=last]",
    "[href^=https]", "[href$=\".pdf\"]", "[href*=example]", "[href*=EXAMPLE i]", "[href^='']", "[href$='']", "[href*='']",
    "[title='hello world' i]", "[type=text]", "[type=text i]", "[type=TEXT]", "input[type=checkbox]", "[value='']",
    "[value]", "[checked]", "[ lang = en ]", "[data-x~='']",
    "li:nth-child(2n+1)", "li:nth-child(-n+3)", "li:nth-child(2n-1)", "li:nth-child(0n+5)", "li:nth-child(odd)",
    "li:nth-child(even)", "li:nth-child( 2n + 1 )", "li:nth-child(n)", "li:nth-child(-2n+5)", "li:nth-child(+3)",
    "li:nth-child(3)", "li:nth-child(-n)", "li:nth-child(ODD)", "li:nth-child(2N+1)", "li:nth-child(n+)",
    "li:nth-child(2n + -1)", "li:nth-last-child(1)", "li:nth-of-type(2)", "li:nth-last-of-type(1)",
    "li:first-child", "li:last-child", "li:only-child", "p:first-of-type", "p:last-of-type", "span:empty",
    ":root", "html:root", "body > :first-child", "em:only-of-type",
    "div > ul li + li ~ li", "div > ul > li", "ul li + li", "ul li ~ li", "section > p + p", "section p",
    "section > p", "h1 ~ p", "h1 + p", "div p", "div, p", "p, div", "li, li.item", "li , ul",
    "section :is(p, h1)", ":is(h1, em)", ":where(h1)", "section:has(> h1)", "div:has(p)", ":scope > body",
    "a:link", "a:any-link", "input:checked", ":disabled", "a[href]:not([hreflang])",
    "*|li", "|li", "ns|li", "li::before", "li:hover", ":nth-child(2 of .item)",
    # invalid
    "", " ", ",", "li,", ",li", "li >", "> li", "li >> p", "[", "[lang", "[lang=]", "[lang=en", "[=en]", "#", ".",
    "li:nth-child()", "li:nth-child(2n+)", "li:unknown", ":not()", "li!", "li)", "li(", "123", ".1a", "#-",
    "[lang=en x]", "li:not(", "a b c d e f g h", "div   >   ul",
]


def main():
    trees = run(PION, "tree", [DOC], "doc"), run(RUST, "tree", [DOC], "doc")
    same_tree = trees[0][0] == trees[1][0]
    recs = []
    for s in SELS:
        recs += [s, DOC]
    p = run(PION, "sel", recs)
    r = run(RUST, "sel", recs)
    diffs = [(s, a, b) for s, a, b in zip(SELS, p, r) if a != b]
    print(f"same tree in both engines: {same_tree}; selectors={len(SELS)} diffs={len(diffs)}")
    for s, a, b in diffs:
        print(f"  {s!r:34s} pion={a!r:28s} scraper={b!r}")
    if "--json" in sys.argv:
        json.dump({"same_tree": same_tree, "total": len(SELS), "diffs": diffs},
                  open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
