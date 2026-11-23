#!/usr/bin/env python3
"""AST round-trip differential for markdown v0.3.0.

For every input and option mask: render_html_pulldown(parse*(src)) must equal
render_html_pulldown(lower(parse_document*(src))) where `lower` turns the Document tree back
into events (harness `batch`). Any mismatch = the tree lost / reordered / mis-nested content.
Also compares the front matter seen by both paths (mask 64 = extended).

usage: ast_diff.py <harness_bin> <pulldown_crate_dir_or_-> <out_dir> [--fuzz N]
"""
import json, os, random, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "audit", "scripts"))
from corpus import handcrafted  # noqa: E402  (read-only reuse of the v0.2 audit corpus)

H, CRATE, OUT = sys.argv[1:4]
FUZZ = int(sys.argv[sys.argv.index("--fuzz") + 1]) if "--fuzz" in sys.argv else 3000
os.makedirs(OUT, exist_ok=True)

EXTRA = [
    ("ast/nested_quote_list_code", "> - a\n>\n>   ```\n>   code\n>   ```\n> - b\n"),
    ("ast/quote_list_table", "> - |a|b|\n>   |-|-|\n>   |1|2|\n"),
    ("ast/loose_vs_tight", "- a\n- b\n\n- c\n\n1. x\n2. y\n"),
    ("ast/ordered_start", "7. a\n8. b\n\n0. z\n\n003. q\n"),
    ("ast/task_states", "- [x] a\n- [ ] b\n- [X] c\n- [y] d\n-  [x] e\n"),
    ("ast/table_cells", "|a|b|c|\n|:-|:-:|-:|\n|1|\n|1|2|3|4|\n"),
    ("ast/footnote_nested", "x[^n]\n\n[^n]: para\n\n    - list in note\n    > quote\n"),
    ("ast/frontmatter_yaml", "---\ntitle: a\n---\n# h\n"),
    ("ast/frontmatter_toml", "+++\ntitle = 'a'\n+++\n# h\n"),
    ("ast/inline_nest", "***a*** [**b**](u) [![alt](img)](link) **[c](d)** ~~*e*~~\n"),
    ("ast/html", "<div>\nx\n</div>\n\na <span>b</span> c\n"),
    ("ast/escapes_entities", "\\*a\\* &amp; &copy; &#x4F60; \\[x\\]\n"),
    ("ast/math", "$a$ and $$b$$\n\n$$\nc\n$$\n"),
    ("ast/email_autolink", "<foo@bar.com> <http://x.y> www.a.b\n"),
    ("ast/image_title", "![a *b* `c`](u \"t\") [l](u 't')\n"),
    ("ast/hard_soft", "a  \nb\\\nc\nd\n"),
    ("ast/setext", "a\n===\n\nb\n---\n"),
    ("ast/code_info", "```rust ignore\nfn x(){}\n```\n~~~\nq\n~~~\n"),
    ("ast/empty_item", "- \n- a\n-\n  b\n"),
    ("ast/deep_mix", "> 1. > - [x] **a** `b`\n>    >   | x |\n>    >   |---|\n>    >   | y |\n"),
]

ATOMS = ["*", "**", "_", "~~", "`", "[", "]", "(", ")", "![", "<", ">", "\\", "&amp;", "|", ":",
         "-", "1.", "#", "\t", "  ", " ", "\n", "\n\n", "\r\n", "a", "b", "中文", "😀", "<div>",
         "</div>", "<!--", "-->", "[x]: /u", "[^1]", "[^1]: n\n", "    ", "> ", "- ", "- [x] ",
         "```", "$", "<b>", "</b>", "http://x.y", "---\n", "+++\n", "|-|-|\n", "|a|b|\n"]


def suite_inputs():
    out = []
    d = os.path.join(CRATE, "tests", "suite") if CRATE != "-" else ""
    if not d or not os.path.isdir(d):
        return out
    for fn in sorted(os.listdir(d)):
        if fn.endswith(".rs"):
            txt = open(os.path.join(d, fn), encoding="utf-8").read()
            for i, m in enumerate(re.finditer(r'let original = r##"(.*?)"##;', txt, re.S)):
                out.append((f"suite/{fn[:-3]}#{i + 1}", m.group(1)))
    return out


def fuzz(n, seed=0xA57):
    r = random.Random(seed)
    return [(f"fuzz#{k}", "".join(r.choice(ATOMS) for _ in range(r.randint(1, 40)))) for k in range(n)]


def frames(data):
    res, i = [], 0
    while i < len(data):
        nl = data.index(b"\n", i)
        ln = int(data[i:nl])
        res.append(data[nl + 1:nl + 1 + ln])
        i = nl + 1 + ln
    return res


srcs = suite_inputs() + [(n, s) for n, s in handcrafted()] + EXTRA + fuzz(FUZZ)
MASKS = [0, 7, 7 | 64, 63 | 64]
cases = [(n, m, s) for n, s in srcs for m in MASKS]
inp = os.path.join(OUT, "batch.in")
with open(inp, "wb") as f:
    for _, m, s in cases:
        b = s.encode("utf-8", "surrogatepass")
        f.write(f"{m}\t{len(b)}\n".encode() + b)
p = subprocess.run([H, "batch", inp], capture_output=True, timeout=900)
if p.returncode != 0:
    print(f"harness rc={p.returncode} {p.stderr[-500:]!r}")
    sys.exit(2)
fr = frames(p.stdout)
assert len(fr) == 3 * len(cases), (len(fr), len(cases))
FNREF = re.compile(r'<sup class="footnote-reference"><a href="#([^"]*)">\d+</a></sup>')


def fn_norm(h):
    return FNREF.sub(lambda m: "[^" + m.group(1) + "]", h)


bad, pre = [], []
for k, (n, m, s) in enumerate(cases):
    ev, ast, fm = fr[3 * k], fr[3 * k + 1], fr[3 * k + 2].decode("utf-8", "replace")
    e_fm, a_fm = fm[2:].split("|A:", 1)
    if ev != ast or e_fm != a_fm:
        e_s, a_s = ev.decode("utf-8", "replace"), ast.decode("utf-8", "replace")
        if e_fm == a_fm and fn_norm(e_s) == fn_norm(a_s) and "<pre>" in a_s:
            # PRE-1: parse_extended rewrites `[^x]` inside code blocks; the AST keeps it literal.
            pre.append(n)
            continue
        bad.append({"name": n, "mask": m, "src": s, "events_html": ev.decode("utf-8", "replace"),
                    "ast_html": ast.decode("utf-8", "replace"), "fm_events": e_fm, "fm_ast": a_fm})
json.dump(bad, open(os.path.join(OUT, "ast_diff.json"), "w"), ensure_ascii=False, indent=1)
print(f"cases={len(cases)} (inputs={len(srcs)} x masks={MASKS}) AST-side mismatches={len(bad)}"
      f"  (+{len(pre)} event-path-only PRE-1 footnote-in-code divergences, not gating)")
seen = set()
for b in bad:
    key = b["name"].split("#")[0]
    if key in seen and len(seen) > 12:
        continue
    seen.add(key)
    print(f"  MISMATCH {b['name']} mask={b['mask']} src={b['src'][:80]!r}")
    print(f"    events: {b['events_html'][:160]!r}")
    print(f"    ast   : {b['ast_html'][:160]!r}")
    if b["fm_events"] != b["fm_ast"]:
        print(f"    frontmatter events={b['fm_events']!r} ast={b['fm_ast']!r}")
sys.exit(1 if bad else 0)
