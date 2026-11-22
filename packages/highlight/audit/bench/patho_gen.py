#!/usr/bin/env python3
"""Generate 1 MiB adversarial inputs into <outdir> (never inside the repo). usage: patho_gen.py <outdir>"""
import os, sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
N = 1 << 20
CASES = {
    "javascript.minified_1MB": 'var a=function(b,c){return b/c+"x"+`t${b}`+/re\\/g/.test(c)};' * 20000,
    "javascript.dense_tokens": "a;" * (N // 2),
    "javascript.slashes": "/" * N,
    "javascript.escaped_quotes": '"' + '\\"' * (N // 2),
    "javascript.template_nesting": "`${" * (N // 3),
    "rust.raw_hashes": "r" + "#" * (N - 2) + '"',
    "rust.raw_lines": ("r" + "#" * 200 + '"x\n') * (N // 205),
    "rust.nested_comments": "/*" * (N // 2),
    "rust.lifetimes": "'a" * (N // 2),
    "python.triple_quotes": '"""' + '""' * (N // 2),
    "cpp.attributes": "[[" * (N // 2),
    "html.lt": "<" * N,
    "html.attrs": "<a " + 'x=" ' * (N // 4),
    "css.braces": "{" * N,
    "yaml.block_scalars": "".join(" " * i + "k: |\n" for i in range(1000)) * 20,
    "markdown.backticks": "`" * N,
    "sql.quotes": "'" * N,
    "shell.dollar_brace": "${" * (N // 2),
    "json.deep": "[" * N,
}
for name, s in CASES.items():
    with open(os.path.join(out, name), "wb") as f:
        f.write(s.encode()[:N])
print("\n".join(sorted(CASES)))
