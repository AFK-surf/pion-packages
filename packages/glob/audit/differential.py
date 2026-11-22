#!/usr/bin/env python3
"""Red-team differential: Pion `glob` vs real Rust globset/ignore vs real `git check-ignore`.

usage: differential.py <pion_driver> <rust_oracle> <out_dir>
Writes <out_dir>/diff_summary.json and diff_divergences.txt; exit 1 if anything diverges.
"""
import collections, json, os, random, shutil, subprocess, sys, tempfile

PATTERNS = r"""
a|*|**|?|??|***|****|/|//|///|/**|**/|**/**|**/**/**|a/**|a/**/|a/**/b|a/**/**/b|**/a|**/a/b|/**/a|a**|**a|a**b|a/**b|a**/b|**.rs|*.rs|**/*.rs|a/*.rs|*.tar.gz|**/*.tar.gz|.*|*.|.|..|../*|./a|a/./b|a//b|a/|/a|
?.rs|a?c|?/?|a/?|*/*|*/a|a/*|*a*|*a*b*|*/**/*|中|?中|中?|??|???|????|*中*|中*|*.中|**/中|中/**|🎉|?🎉|🎉?|é|?é|É|ß|Σ|σ|ς|K|k|ſ|s|
[a]|[ab]|[a-c]|[!a]|[^a]|[!a-c]|[^a-c]|[]a]|[!]]|[^]]|[]]|[]-a]|[a-]|[-a]|[--0]|[a-z-]|[+--]|[a-a]|[z-a]|[a-c-e]|[\]]|[\\]|[\a]|[a\-c]|[!\]]|[[]|[[a]|[a[]|[/]|[!/]|[a/]|[.-0]|a[/]b|a[!x]b|[abc|[|[!|[^|[]|[!]|[a-|[]a|[,]|[{]|[}]|[*]|[?]|[a,b]|{[a,b],c}|[{a,b}]|
[α-ω]|[!α-ω]|[^α-ω]|[中]|[!中]|[^中]|[中文]|[一-龥]|[🎉]|[!🎉]|[😀-🙏]|[é]|[!é]|[a中]|[À-ÿ]|[Α-Ω]|
[[:alpha:]]|[[:digit:]]|[[:alnum:]]|[[:upper:]]|[[:lower:]]|[[:space:]]|[[:punct:]]|[[:xdigit:]]|[[:blank:]]|[[:cntrl:]]|[[:graph:]]|[[:print:]]|[![:alpha:]]|[^[:digit:]]|[[:bogus:]]|[[:alpha:]-z]|[a-[:digit:]]|[[:alpha:|[[:alpha]|[[:]|
{a}|{a,b}|{a,}|{,a}|{,}|{}|{,,}|{a,,b}|{a,{b,c}}|{{a,b},c}|{{a,b},{c,d}}|{a,{b,{c,{d,e}}}}|{a,b}{c,d}|{a,}{b,}|x{a,}|{a,}x|x{,a}y|{{}}|{{},a}|{,{}}|{,{,}}|a{b,c}d|\{a,b\}|\{a\,b\}|{a\,b,c}|{a\},b}|\{|\}|{|}|{{|}}|{a|a}|a,b|,|{*.rs,*.pion}|{*.rs,**/*.pion}|**/*.{rs,pion}|**/{a,b}|{a,b}/**|{a,b}/**/c|{**,a}|{**/a,b}|{a/**,b}|{a,**}|{**}|{**/}|{/**}|x{**,a}|x/{**,a}|x/{**/a,b}|{a/,b}c|{a,b/}c|{[ab],c}|{[!a],b}|{?,ab}|{*,a}|{a,*}b|*{a,b}|?{a,b}|{中,文}|{中,}|*.{中,文}|{a,b}{c,d}{e,f}|
\a|\*|\?|\[|\]|\\|\/|a\/b|\**|\*\*|*\*|\??|?\?|\[a]|[a\]|a\|\|\中|\🎉|\,|\{,|*.\rs|\*.rs|a\ b|a b| |  |*.r?|*.r[s]|*.[ch]|*.py[cod]|**/*.py[cod]|**/*.[ch]|*.[!c]|foo.*|foo.*.bar|*.a.b|foo*bar|foo/*/bar|foo/**/bar/*.rs|src/**/*.rs|src/*|src/**|**/src/**|**/src/*|**/target|**/target/**|target/|**/.git/**|.git|**/.gitignore|*.min.js|Makefile|**/Makefile|a.b.c|**/a.b.c|*a.b|**/*a.b|**/a*.b|**/a?.b|**/[ab].c|**/[!a].c|**/?.c|**/*|*/|*/*/|**/*/|/*|/*/*|/a/*|/a/**
""".replace("\n", "").split("|")
PATTERNS = list(dict.fromkeys(p for p in PATTERNS if p != ""))

PATHS = ["", "a", "b", "c", "ab", "abc", "ac", "ba", "x", "xa", "ax", "xy", "xay", ".", "..", "...", ".a", "a.", "a/", "/a", "//a", "a//", "a//b", "a///b", "/", "//", "///", "a/b", "a/b/", "/a/b", "a/b/c", "a/x/b", "a/x/y/b", "x/a", "x/y/a", "x/a/b", "ab/c", "a/bc", "a/.", "a/..", "../a", "./a", "a/./b", "a/../b", "foo", "foo.rs", "a.rs", "b.pion", "x/a.rs", "x/y/a.rs", ".rs", "x/.rs", "a.rs/", "a.rs/b", "a.tar.gz", "x/a.tar.gz", "tar.gz", ".tar.gz", "a.c", "b.c", "c.c", "ab.c", "x/a.c", "x/b.c", "a.h", "a.py", "a.pyc", "a.pyo", "a.pyd", "x/a.pyc", "foo.bar", "foo.x.bar", "foobar", "fooxbar", "foo/bar", "foo/x/bar", "foo/x/bar/a.rs", "src", "src/", "src/a.rs", "src/x/a.rs", "x/src/a.rs", "x/src", "target", "target/", "x/target", "x/target/a", ".git", ".git/config", "x/.git/config", ".gitignore", "x/.gitignore", "a.min.js", "x/a.min.js", "Makefile", "x/Makefile", "makefile", "a.b.c", "x/a.b.c", "xa.b", "x/xa.b", "A", "B", "AB", "A.RS", "a.RS", "SRC/a.rs", "FOO", "中", "文", "中文", "x中", "中x", "中/a", "a/中", "中.rs", "a.中", "x/a.中", "🎉", "x🎉", "🎉x", "é", "É", "é", "ß", "SS", "ss", "Σ", "σ", "ς", "K", "k", "K", "ſ", "s", "S", "α", "ω", "Α", "Ω", "λ", "ÿ", "À", "一", "龥", "😀", "🙏", "]", "[", "!", "^", "-", "+", ",", "{", "}", "*", "?", "\\", "a-", "-a", "a,b", "{a,b}", "{a", "a}", "[a", "[a]", "a]", "a b", " ", "  ", "a ", " a", "\t", "\n".replace("\n", "\x0b"), "\x7f", "0", "5", "9", "/a/b/c", "xab", "bx", "ad", "abd", "acd", "ce", "de", "bd", "ace", "bdf", "ad/e", "a/c", "b/c", "x/c", "x/b",
         b"\xff", b"a\xff", b"\xffa", b"\xe4\xb8", b"\xe4", b"a/\xff", b"\xff.rs", b"a.\xff", b"\xc0\x80", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"\x80", b"x/\xff/a"]

OPTIONS = [0, 1, 2, 3, 4, 8, 16, 2 | 8, 2 | 16, 1 | 8]

GITIGNORES = [
    "foo", "foo/", "/foo", "/foo/", "foo/bar", "/foo/bar", "foo/bar/", "**/foo", "**/foo/", "**/foo/bar", "foo/**", "foo/**/", "foo/**/bar", "/foo/**", "**", "**/", "/**", "/**/", "*", "*/", "/*", "/*/", "*.log", "/*.log", "**/*.log", "foo/*.log", "foo/*", "foo/*/", "*/bar", "*/*", "*/*/*", "?", "??o", "f?o", "[fb]oo", "[!f]oo", "[^f]oo", "[a-z]oo", "[z-a]oo\nfoo", "foo\n[z-a]", "bar\n[z-a]oo\nfoo", "{foo,bar}", "{foo", "foo}", "[foo", "[", "[]", "\\", "foo\\", "\\foo", "fo\\o", "f\\oo/",
    "#foo", "\\#hash", "#hash", " #hash", "!bang", "\\!bang", "\\\\!bang", "!", "!!bang", "!/", "/", "//", "///", "//foo", "foo//", "foo//bar", "./foo", "foo/.", "foo/..", "../foo", ".", "..", "\n", "\n\n\nfoo\n\n", "   ", "foo   ", "foo \t", "foo\\ ", "foo\\  ", "foo\\   ", "foo\\ bar", "foo bar", "foo bar   ", "foo\\ bar  ", "trail\\ ", "trail ", "trail\\  ", "trail  ", " sp", "\\ sp", "\ttab", "foo\t", "foo\r\nbar\r\n", "foo\r", "foo \r\n", "foo\\ \r\n", "\r\n", "﻿foo", "﻿#c\nfoo", "bar\n﻿foo",
    "foo\n!foo", "!foo\nfoo", "foo/\n!foo/", "foo/\n!foo/bar", "foo/*\n!foo/bar", "foo/**\n!foo/bar", "/foo/*\n!/foo/bar", "/*\n!/foo", "/*\n!/foo/\n/foo/*\n!/foo/bar", "*\n!foo", "*\n!foo/", "*\n!*/", "*\n!*/\n!*.log", "*\n!foo/\n!foo/bar", "*\n!foo/\n!foo/**", "*.log\n!a.log", "*.log\n!/a.log", "*.log\n!foo/*.log", "build\n!build/keep", "build/\n!build/keep", "build/*\n!build/keep", "build/**\n!build/keep", "src/build\n!src/build/x", "**/build\n!src/build", "a/b\n!a/b/c", "a/\n!a/b/\n!a/b/c", "a/*\n!a/b/\na/b/*\n!a/b/c", "!a/b/c\na/", "a/b/c\n!a/b", "foo/bar\n!foo",
    "a/b", "/a/b", "**/a/b", "a/**/c", "a/*/c", "a/b/*", "a/b/**", "b", "b/", "c", "/b", "**/b", "**/c", "b/c", "*/c", "**/b/c", "**b", "a**", "a**/c", "**/", "a/**b", "a/b**", "中文", "中?", "?文", "[中]文", "*.中", "é*", "🎉", "?", "??", "???", "????", "中文/", "!中文", "*.LOG", "FOO",
    "[[:alpha:]]oo", "[[:digit:]]oo", "[[:lower:]]oo", "[![:digit:]]oo", "[[:bogus:]]oo", "{**/}", "{**/,x}", "x\n{**/}", "foo\n{bad", "foo\n\\", "*.log\n[z-a]\n!a.log",
]
TREE = ["foo/", "foo/bar/", "foo/bar/baz", "foo/a.log", "foo/x/", "foo/x/bar", "foo/x/a.log", "bar/", "bar/foo", "bar/foo2", "boo", "zoo", "a.log", "b.log", "x.log/", "x.log/inner", "build/", "build/keep", "build/out", "src/", "src/build/", "src/build/x", "src/foo", "src/bar/", "src/bar/foo/", "src/bar/foo/z", "a/", "a/b/", "a/b/c", "a/b/d", "a/x/", "a/x/c", "a/x/y/", "a/x/y/c", "b/", "b/c", "c", "#hash", "!bang", "\\back", " sp", "\ttab", "trail ", "trail  ", "foo bar", "foo bar2", "中文", "中x", "x文", "a.中", "é1", "🎉", "ab", "{foo,bar}"]


def hx(v):
    if isinstance(v, str):
        v = v.encode()
    return v.hex()


def show(b):
    if isinstance(b, bytes):
        try:
            return b.decode()
        except UnicodeDecodeError:
            return repr(b)
    return b


def gen_cases(path):
    """Returns meta rows parallel to oracle output lines."""
    meta, out = [], []
    for o in OPTIONS:
        for pat in PATTERNS:
            out.append(f"G {o} {hx(pat)}")
            for p in PATHS:
                out.append(f"Q {hx(p)}")
                meta.append(("glob", o, pat, p))
    rnd = random.Random(20261122)
    pool = [p for p in PATTERNS]
    for s in range(400):
        o = rnd.choice([0, 0, 0, 1, 2, 3, 8])
        pats = rnd.sample(pool, rnd.randint(2, 16))
        out.append(f"M {o} " + ",".join(hx(x) for x in pats))
        for p in rnd.sample(PATHS, 60):
            out.append(f"Q {hx(p)}")
            meta.append(("set", o, tuple(pats), p))
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    return meta


def gen_ignore_cases(path):
    meta, out = [], []
    for gi in GITIGNORES:
        out.append(f"I {hx(gi)}")
        for t in TREE:
            d = t.endswith("/")
            p = t[:-1] if d else t
            out.append(f"D {hx(p)} {int(d)}")
            meta.append((gi, p, d))
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    return meta


def git_truth(root):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
    repo = os.path.join(root, "repo")
    shutil.rmtree(repo, ignore_errors=True)
    os.makedirs(repo)
    subprocess.run(["git", "init", "-q", repo], check=True, env=env)
    for t in TREE:
        fp = os.path.join(repo, t)
        if t.endswith("/"):
            os.makedirs(fp, exist_ok=True)
        else:
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            open(fp, "w").close()
    names = [t.rstrip("/") for t in TREE]
    stdin = b"".join(n.encode() + b"\0" for n in names)
    res = {}
    for gi in GITIGNORES:
        with open(os.path.join(repo, ".gitignore"), "wb") as f:
            f.write(gi.encode())
        r = subprocess.run(["git", "-c", "core.ignorecase=false", "-c", "core.quotepath=off", "-c", "core.excludesFile=/dev/null", "-C", repo, "check-ignore", "--no-index", "-v", "-n", "-z", "--stdin"], input=stdin, capture_output=True, env=env)
        if r.returncode not in (0, 1):
            raise SystemExit("git check-ignore failed: " + r.stderr.decode())
        f = r.stdout.split(b"\0")
        for i in range(0, len(f) - 1, 4):
            src, _ln, pat, p = f[i:i + 4]
            res[(gi, p.decode())] = bool(src) and not pat.startswith(b"!")
    return res


def run(cmd, out):
    with open(out, "wb") as f:
        r = subprocess.run(cmd, stdout=f, stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise SystemExit(f"{cmd} exit {r.returncode}: {r.stderr[-2000:].decode(errors='replace')}")
    return open(out, encoding="latin-1").read().split("\n")[:-1]


def main():
    pion, rust, od = sys.argv[1:4]
    os.makedirs(od, exist_ok=True)
    cf, gf = os.path.join(od, "cases.txt"), os.path.join(od, "ignore_cases.txt")
    meta = gen_cases(cf)
    gmeta = gen_ignore_cases(gf)
    ro = run([rust, "diff", cf], os.path.join(od, "r.out"))
    po = run([pion, "diff", cf], os.path.join(od, "p.out"))
    assert len(ro) == len(po) == len(meta), (len(ro), len(po), len(meta))
    cat, roots = collections.Counter(), collections.Counter()
    groups = collections.defaultdict(list)
    total = collections.Counter()

    def non_ascii(v):
        v = v.encode() if isinstance(v, str) else v
        return any(c >= 128 for c in v)

    def root_cause(kind, o, pat, path, r, p):
        pats = pat if isinstance(pat, tuple) else (pat,)
        if kind == "glob" and r != "E" and p != "E" and p[0] != p[1] and r[0] == r[1]:
            return "R1_globset_diverges_from_own_glob"
        if any("{**/" in x for x in pats):
            return "R1_globset_diverges_from_own_glob"
        if pats == ("*.",):
            return "R5_star_dot_on_dotdot"
        if any("[:" in x for x in pats):
            return "R3_posix_class_extension"
        if non_ascii(path) or any(non_ascii(x) for x in pats):
            return "R2_codepoint_vs_byte_semantics"
        if o & 2 and any("[" in x for x in pats):
            return "R4_class_cannot_match_slash_under_literal_separator"
        return "R9_residual"

    for m, r, p in zip(meta, ro, po):
        kind, o, pat, path = m
        total[kind] += 1
        if r == p:
            continue
        if kind == "glob":
            if r == "E" or p == "E":
                c = "compile_accept_reject"
            elif p[0] != r[0] and p[1] != r[1]:
                c = "glob+set_wrong"
            elif p[0] != r[0]:
                c = "glob_only_wrong"
            else:
                c = "set_only_wrong"
            key = (c, o, pat)
        else:
            c = "multi_set_wrong" if r != "E" and p != "E" else "multi_set_compile"
            key = (c, o, "<set>")
        cat[c] += 1
        rc = root_cause(kind, o, pat, path, r, p)
        roots[rc] += 1
        groups[(rc,) + key].append((pat, path, r, p))

    rg = run([rust, "diff", gf], os.path.join(od, "rg.out"))
    pg = run([pion, "diff", gf], os.path.join(od, "pg.out"))
    assert len(rg) == len(pg) == len(gmeta)
    truth = git_truth(od)
    gi_cat = collections.Counter()
    gi_groups = collections.defaultdict(list)
    missing = 0
    for (gi, p, d), r, q in zip(gmeta, rg, pg):
        rm, rp = r.split(" ")
        qm, qp, qw = q.split(" ")
        if (gi, p) not in truth:
            missing += 1
            continue
        git, rust_ign = truth[(gi, p)], rp == "I"
        if qm == "E":
            gi_cat["G1_pion_rejects_whole_file"] += 1
            gi_groups[("G1_pion_rejects_whole_file", gi)].append((p, d, f"git={git} rust={rust_ign}", "Err"))
            continue
        pion = qw == "1"
        if pion == git:
            if rust_ign != git:
                gi_cat["info_rust_wrong_pion_matches_git"] += 1
        elif rust_ign == git:
            gi_cat["G2_pion_only_wrong_vs_git_and_rust"] += 1
            gi_groups[("G2_pion_only_wrong_vs_git_and_rust", gi)].append((p, d, f"git={git} rust={rust_ign}", pion))
        else:
            gi_cat["info_both_differ_from_git_inherited"] += 1
            gi_groups[("info_both_differ_from_git_inherited", gi)].append((p, d, f"git={git} rust={rust_ign}", pion))
        if rm != qm:
            gi_cat["info_tristate_matched_differs_from_ignore"] += 1

    with open(os.path.join(od, "diff_divergences.txt"), "w") as f:
        for k, v in sorted(groups.items(), key=lambda kv: (kv[0][0], kv[0][1], str(kv[0][2:]))):
            f.write(f"{k[0]} {k[1]} opts={k[2]} pattern={k[3]!r} n={len(v)}\n")
            for pat, path, r, p in v[:6]:
                f.write(f"    pat={pat!r} path={show(path)!r} rust={r} pion={p}\n")
        for k, v in sorted(gi_groups.items()):
            f.write(f"GITIGNORE {k[0]} content={k[1]!r} n={len(v)}\n")
            for x in v[:6]:
                f.write(f"    path={x[0]!r} is_dir={x[1]} expected={x[2]} pion={x[3]}\n")
    summary = dict(patterns=len(PATTERNS), paths=len(PATHS), options=len(OPTIONS), checks=dict(total), glob_divergences=dict(cat), glob_root_causes=dict(roots), gitignores=len(GITIGNORES), tree=len(TREE), gitignore_checks=len(gmeta), gitignore_divergences=dict(gi_cat), git_missing=missing)
    json.dump(summary, open(os.path.join(od, "diff_summary.json"), "w"), indent=1, ensure_ascii=False)
    print(json.dumps(summary, indent=1, ensure_ascii=False))
    bad = sum(cat.values()) + sum(v for k, v in gi_cat.items() if k.startswith("G"))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
