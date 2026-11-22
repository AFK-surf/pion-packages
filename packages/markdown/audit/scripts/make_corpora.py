#!/usr/bin/env python3
"""Write benchmark corpora into <dir>: corpus_gfm.md (same generator as bench/run_bench.sh, ~2.5 MB),
corpus_spec.md (all pulldown-cmark 0.13.1 spec-suite inputs concatenated, repeated to ~2.5 MB),
and a few pathological inputs.  usage: make_corpora.py <pulldown_crate_dir> <dir>"""
import os, re, subprocess, sys

CRATE, D = sys.argv[1:3]
os.makedirs(D, exist_ok=True)
here = os.path.dirname(os.path.abspath(__file__))
sh = open(os.path.join(here, "..", "..", "bench", "run_bench.sh"), encoding="utf-8").read()
py = sh.split("python3 - \"$TMP_DIR/corpus_gfm.md\" << 'PYEOF'\n", 1)[1].split("\nPYEOF", 1)[0]
subprocess.run([sys.executable, "-c", py, os.path.join(D, "corpus_gfm.md")], check=True)
spec = open(os.path.join(CRATE, "tests", "suite", "spec.rs"), encoding="utf-8").read()
docs = re.findall(r'let original = r##"(.*?)"##;', spec, re.S)
one = "\n\n".join(docs) + "\n"
open(os.path.join(D, "corpus_spec.md"), "w", encoding="utf-8").write(one * (2_500_000 // len(one.encode()) + 1))
P = {
    "patho_nested_strong_emph_4000.md": "*a **a " * 4000 + "b" + " a** a*" * 4000 + "\n",
    "patho_smart_quotes_nested_16000.md": "\"'" * 16000 + "a" + "'\"" * 16000 + "\n",
    "patho_unclosed_comments_32000.md": "</" + "<!--" * 32000 + "\n",
    "patho_backticks_increasing.md": "".join("e" + "`" * i for i in range(1, 1000)) + "\n",
    "patho_deep_list_lines_32000.md": "".join(" " * (2 * (i % 200)) + "- a\n" for i in range(32000)),
    "patho_deep_list_inline_16000.md": "- " * 16000 + "a\n",
}
for k, v in P.items():
    open(os.path.join(D, k), "w", encoding="utf-8").write(v)
print("\n".join(sorted(os.listdir(D))))
