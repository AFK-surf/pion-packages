#!/usr/bin/env python3
"""Red-team differential test: packages/fts (Pion) vs SQLite FTS5 (Python sqlite3).

Usage: python3 difftest.py <fts_audit_diff binary> <work_dir> [seed] [rounds]

For every generated corpus it checks:
  1. token parity  - each `fts5_index_text` token is exactly one FTS5 unicode61 token, unchanged
                     (no splitting, dropping, diacritic or case folding on the SQLite side);
  2. query safety  - every `fts5_match_expr` is accepted by `MATCH ?` (no syntax error);
  3. result parity - Pion `Index::search` returns the same ids in the same order with the same
                     BM25 scores as `ORDER BY bm25(docs), rowid`.
"""

import random
import sqlite3
import subprocess
import sys

FRAGS = [
    "hello", "world", "Hello", "WORLD", "foo", "bar", "baz", "foo_bar", "FooBar", "fooBar",
    "HTTPServer", "nc_follow", "__init__", "_", "__", "#1234", "#12", "pr1234", "PR12x",
    "a1b2c3d4e5f60718", "deadbeef1", "abcdef1", "1234567", "0xdeadbeef",
    "café", "cafe", "CAFÉ", "naïve", "naive", "Ÿ", "ÿ", "ſ", "ß", "ẞ", "İ", "ı", "ŉ", "ĸ",
    "Ωμέγα", "ΔΕΛΤΑ", "ς", "σ", "Σ", "ΐ", "ΰ", "Привет", "Ёлка", "ёлка", "ѐ", "Ѐ",
    "中文", "全文检索", "中", "文", "日本語", "ひらがな", "カタカナ", "ア・イ", "・", "ー", "゛", "゜",
    "゠", "ゝ", "ゞ", "ヽ", "ヾ", "ㇰ", "한국어", "ᄀ", "ᅡ", "ᆨ", "ힰ", "𠀀", "𪛖", "\U0002a6e0", "\U0002fa1f",
    "\U0002ffff", "\U00030000", "豈", "﩮", "぀", "゗", "䷀", "鿿", "﫿", "ㇿ",
    "🚀", "😀", " ", "　", "\t", "\n", " ", "  ", ",", ".", "-", "'", '"', "(", ")", "*",
    "^", ":", "col:foo", "NEAR", "AND", "OR", "NOT", "+", "{", "}", "\\", "\x00", "\x01", "\x7f",
    "µ", "ª", "º", "²", "½", "×", "÷", "Æ", "æ", "Ø", "ø", "Þ", "þ", "Ð", "ð", "Ĳ", "ĳ", "Ŋ", "ŋ",
    "́", "é", "İ", "ŉ", "ſ", "Ÿ", "Ά", "ΐ", "ΰ",
    "ς", "ϴ", "Ѐ", "Ѝ", "ѝ", "Ѡ",
]
QFRAGS = FRAGS + ['"', '"foo bar"', '"hello world"', "foo*", "Foo*", "中*", "中文*", "*", "**",
                  "NOT", "NOT NOT", "-foo", '"foo foo"', '"hello hello world"', '"中文 中"',
                  '"foobar foo"', '"FooBar baz"', '"foo bar foo"', '"a1b2c3d4e5f60718 hello"', '"café cafe"',
                  '"全文检索"', '"ア・イ"', 'hel*', 'na*', 'ca*', 'u_*', 'pr*', '"\x00"', "foo NOT foo", "foo:", '"unclosed', "deadbeef*", "#1*", "x" * 300]
BAD_BYTES = [b"\xc0\xaf", b"\xe0\x80\xaf", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"\xf8\x88\x80\x80\x80",
             b"\xe4\xb8", b"\xf0\x9f\x9a", b"\x80", b"\xff", b"\xfe", b"\xc2", b"\xc3\x28"]


def rand_text(rng, frags, n):
    parts = []
    for _ in range(n):
        r = rng.random()
        if r < 0.05:
            parts.append(rng.choice(BAD_BYTES))
        else:
            parts.append(rng.choice(frags).encode("utf-8", "surrogatepass"))
        sep = rng.random()
        if sep < 0.6:
            parts.append(b" ")
        elif sep < 0.7:
            parts.append(b"")
        else:
            parts.append(rng.choice([b",", b"\t", b"\xe3\x80\x80", b"-", b"."]))
    return b"".join(parts)


def fts5_tokens(con, text):
    con.execute("DELETE FROM t")
    con.execute("INSERT INTO t(rowid, body) VALUES (1, ?)", (text,))
    rows = con.execute("SELECT term, offset FROM tv ORDER BY offset").fetchall()
    return [r[0] for r in rows]


def main():
    binary, work = sys.argv[1], sys.argv[2]
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    rounds = int(sys.argv[4]) if len(sys.argv) > 4 else 20
    rng = random.Random(seed)
    tok_fail = expr_fail = res_fail = 0
    checked_q = 0
    nonempty = 0
    examples = {"tok": [], "expr": [], "res": []}
    tcon = sqlite3.connect(":memory:")
    tcon.execute("CREATE VIRTUAL TABLE t USING fts5(body, tokenize=\"unicode61 tokenchars '_'\")")
    tcon.execute("CREATE VIRTUAL TABLE tv USING fts5vocab(t, instance)")
    for rd in range(rounds):
        docs = [(i + 1, rand_text(rng, FRAGS, rng.randint(0, 14))) for i in range(rng.randint(1, 40))]
        queries = [rand_text(rng, QFRAGS, rng.randint(0, 5)) for _ in range(60)]
        if rd == 0:
            queries += [f.encode("utf-8", "surrogatepass") for f in QFRAGS] + BAD_BYTES
        with open(f"{work}/docs.tsv", "w") as f:
            for i, d in docs:
                f.write(f"{i}\t{d.hex()}\n")
        with open(f"{work}/q.txt", "w") as f:
            for q in queries:
                f.write(q.hex() + "\n")
        subprocess.run([binary, "run", f"{work}/docs.tsv", f"{work}/q.txt", f"{work}/out"], check=True)
        index = {}
        for line in open(f"{work}/out.index"):
            i, h = line.rstrip("\n").split("\t")
            index[int(i)] = bytes.fromhex(h).decode("utf-8")
        exprs = [bytes.fromhex(l.rstrip("\n")).decode("utf-8") for l in open(f"{work}/out.expr")]
        hits = []
        for l in open(f"{work}/out.hits"):
            p = l.split()
            hits.append([(int(x.split(":")[0]), int(x.split(":")[1])) for x in p[1:]])
        # 1. token parity
        for i, txt in index.items():
            want = txt.split(" ") if txt else []
            got = fts5_tokens(tcon, txt)
            if want != got:
                tok_fail += 1
                if len(examples["tok"]) < 8:
                    diff = [(a, b) for a, b in zip(want, got) if a != b][:3]
                    examples["tok"].append((txt[:80], len(want), len(got), diff))
        # 2/3. query safety + result parity
        con = sqlite3.connect(":memory:")
        con.execute("CREATE VIRTUAL TABLE docs USING fts5(body, tokenize=\"unicode61 tokenchars '_'\")")
        con.executemany("INSERT INTO docs(rowid, body) VALUES (?, ?)", list(index.items()))
        for qi, (q, e) in enumerate(zip(queries, exprs)):
            checked_q += 1
            if e == "":
                rows = []
            else:
                try:
                    rows = con.execute(
                        "SELECT rowid, -bm25(docs) FROM docs WHERE docs MATCH ? ORDER BY bm25(docs), rowid",
                        (e,)).fetchall()
                except sqlite3.Error as ex:
                    expr_fail += 1
                    if len(examples["expr"]) < 8:
                        examples["expr"].append((q, e, str(ex)))
                    continue
            want = [(r[0], int(r[1] * 1e12 + 0.5)) for r in rows]
            got = hits[qi]
            nonempty += 1 if got else 0
            same = len(want) == len(got) and all(
                a[0] == b[0] and abs(a[1] - b[1]) <= max(2, abs(a[1]) // 10**9) for a, b in zip(want, got))
            if not same:
                res_fail += 1
                if len(examples["res"]) < 8:
                    examples["res"].append((q, e, want[:5], got[:5]))
        con.close()
    # 4. snippet safety: valid UTF-8, bounded length, sorted disjoint highlights on char boundaries
    snip_fail = snip_hl = 0
    pairs = []
    for _ in range(rounds * 40):
        text = rand_text(rng, FRAGS, rng.randint(0, 60))
        q = rand_text(rng, QFRAGS, rng.randint(0, 4))
        mc = rng.choice([0, 1, 2, 3, 5, 8, 16, 33, 120, 2147483647, -1, rng.randint(1, 200)])
        pairs.append((text, q, mc))
    with open(f"{work}/snip.tsv", "w") as f:
        for t, q, mc in pairs:
            f.write(f"{t.hex()}\t{q.hex()}\t{mc}\n")
    subprocess.run([binary, "snip", f"{work}/snip.tsv", f"{work}/snip.out"], check=True)
    for (t, q, mc), line in zip(pairs, open(f"{work}/snip.out")):
        p = line.split()
        raw = bytes.fromhex(p[0]) if p and ":" not in p[0] else b""
        hls = [tuple(map(int, x.split(":"))) for x in (p[1:] if raw or (p and ":" not in p[0]) else p)]
        err = None
        try:
            txt = raw.decode("utf-8")
            nchars = len(txt.replace("\u2026", ""))
            src_chars = len(t.decode("utf-8", "replace"))
            if mc > 0 and src_chars > 0 and nchars > mc:
                err = "too long"
            if mc > 0 and nchars == 0 and src_chars > 0:
                err = "empty snippet"
            last = -1
            for lo, hi in hls:
                if not (0 <= lo < hi <= len(raw)) or lo <= last:
                    err = f"bad range {lo}:{hi}"
                raw[lo:hi].decode("utf-8")
                last = hi
            snip_hl += len(hls)
        except UnicodeDecodeError as ex:
            err = f"utf8 {ex}"
        if err:
            snip_fail += 1
            if len(examples.setdefault("snip", [])) < 8:
                examples["snip"].append((t[:60], q, mc, err))
    print(f"snippets={len(pairs)} highlights={snip_hl} snippet_failures={snip_fail}")
    print(f"seed={seed} rounds={rounds} queries={checked_q} nonempty={nonempty} token_mismatch_docs={tok_fail} "
          f"expr_errors={expr_fail} result_mismatches={res_fail}")
    for k, v in examples.items():
        for ex in v:
            print(k, repr(ex))
    return 1 if (tok_fail or expr_fail or res_fail or snip_fail) else 0


if __name__ == "__main__":
    sys.exit(main())
