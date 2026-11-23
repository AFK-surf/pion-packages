#!/usr/bin/env python3
"""Generate differential cases for packages/regex vs Rust `regex =1.11.1`.

Usage:
  gen_cases.py curated            > curated.cases
  gen_cases.py fuzz <seed> <n>    > fuzz.cases
  gen_cases.py capfuzz <seed> <n> > capfuzz.cases
  gen_cases.py sets <seed> <n>    > sets.cases

Case line formats (tab separated, hex-encoded UTF-8 fields):
  R <pattern> <haystack> <replacement>
  S <haystack> <pat1>,<pat2>,...
"""
import random
import sys


def h(s: str) -> str:
    return s.encode("utf-8").hex()


HAYS = [
    "", "a", "aa", "aaa", "ab", "aab", "abab", "baaac", "aaab", "abcabc", "xyz",
    "a中🚀b", "中文", "🚀🚀", "中a文", "é", "aé", "a\u0301",
    "foo bar\nbaz", "a\r\nb\r\n", "\n", "\r\n", "\n\n", "x\ny\n", "\nab\n",
    "ß SS ss ſ K k \u212a İ i ı", "Привет мир", "αβγ ΑΒΓ ς σ Σ", "ab123 4٣5 ①",
    "café naïve", "a_b-c d", " \t\n\x0b\x0c\r\u0085\u00a0\u2028", "word wörd 中a 1x",
    "]a-b^c\\d", "aaa\nbbb\nccc", "abbb abb ab", "aaaaaaaaaaaaaaaaaaaa",
    "\u0000a\u0000", "\U0010FFFF\U0001F600", "ǅǆǄ", "ﬀ ﬃ",
]

PATS = [
    # empty matches & UTF-8 boundaries
    "", "a*", "a?", "^", "$", r"\b", r"\B", "(a|)", "(|a)", "()", "(?:)", "x*", r"\A", r"\z",
    "(?m)^", "(?m)$", "(?m)^$", "^$", r"(?m)\B", "a*?", "(a*)*", "(a*)+", "(a?)*", "(|a)*", "(a|)+",
    # leftmost-first / laziness
    "(a|ab)", "(ab|a)", "a+?", "a??", "a{1,3}?", "(a*?)(a*)", "(a|aa)+?b", "((a)*b)*",
    "(a(b)?)+", "(a|ab)(c|bcd)?", "(a+)(b+)?", "(a*)(b*)(c*)", "(?:(a)|b)+", "(?:(a)|(b))+",
    "(a)|b", "((a)|b)+", "(a?)((ab)?)(b?)", "(.*?)(b?)", "(?U)a+", "(?U)a+?", "(?U:a*)a",
    "a{2}", "a{2,}", "a{0,2}", "a{0}", "(a){0}", "(?:a{0}|b)", "a{2,3}?b", "(ab)*?b",
    # one-pass vs non-one-pass capture boundaries
    "(a|b)*a", "(?:(a)|(b))c", "(a+)?(a+)", "(中)(文)?", "(a|)(b)", "(a)(b)?(c)?", "(a|b)(b)",
    "([a-z]+)([0-9]*)", r"(\w+)\s(\w+)", "([^ ]*) ([^ ]*)", "(a*)b|(a*)c", "(?:a(b)|ac)", "(x)?y?(x)?",
    "(🚀+)(b?)", "(.)(.)", "(.)?(.)?(.)?", "(?P<n>a)(?P<name>b)?", "(?<w>\\w)+",
    # anchors & word boundaries
    "^a", "a$", "^a$", "(?m)^a", "(?m)a$", "(?m)^b", r"(?m)c$", r"\Aa", r"a\z", r"(?m)\Ab", r"(?m)^\w+$",
    r"\bab\b", r"\Bb", r"\b\w+\b", r"\b.", r".\b", r"(?-u:\b)\w", r"(?-u:\b).", r"\b中",
    r"\bwörd\b", r"(?-u:\bw)", r"\B.", r"\b\B", r"^\b", r"\b$", r"(?m)$\n", r"(?m)\r$", "$\n",
    # flags & Unicode
    "(?i)ss", "(?i)ß", "(?i)k", "(?i)K", "(?i)\u212a", "(?i)i", "(?i)İ", "(?i)ı", "(?i)σ", "(?i)Σ",
    "(?i)привет", "(?i)αβγ", "(?i)[a-z]+", "(?i)[k]", "(?i:a)A", "a(?i:b)c", "(?i)a(?-i)b", "(?i)ǅ",
    "(?s).", ".", "(?s:.)\n", "(?-s).", "(?x) a b # c", "(?x)a\\ b", "(?x)[ ]", "(?x:a b)c",
    r"\p{L}+", r"\P{L}+", r"\p{Nd}", r"\p{Greek}+", r"\p{Han}", r"\p{Lu}", r"\p{Ll}+", r"\pL", r"\pN+",
    r"\w+", r"\W", r"\d+", r"\D", r"\s+", r"\S+", "[^a]", "[^a]+", "[^\n]+", "[^中]",
    r"(?-u)\w+", r"(?-u)\d", r"(?-u)\s", r"(?-u:\W)", "[]a]", "[a-]", "[-a]", r"[\w-a]", r"[a\-z]",
    r"[\d\s]+", r"[^\w\s]", "[[:alpha:]]+", "[[:^alpha:]]", "[[:word:]]+", "[a-c&&b]", "[a-z--b]",
    "[a-z~~c]", "[\\[\\]]", r"[\p{Greek}a]+", r"[^\p{L}]", "[中-文]", "[🚀]", "[^🚀]", r"\x{1F680}",
    r"\u4e2d", r"\x61", r"\U0001F680", r"[\x00-\x{10FFFF}]", r"(?i)[^k]", "(?i)[ss]",
    # misc / errors
    "a|b|c", "abc|abd", "(a|b|c)+", "a.c", "a.*c", ".*", ".+", ".*?", "(.*)(.*)",
    "a{", "a{,2}", "a{2,1}", "(", ")", "[", "[a", "*", "a**", "a{1001}", "(?P<n>a)(?P<n>b)",
    r"\1", "(?=a)", "(?!a)", "(?<=a)", "a++", "\\", "[z-a]", r"\p{Foo}", "(?z)", "(?i", r"\Q",
    r"\pX", "x{2}{3}", "(?:a|b)*?c", "(?m)(?:^|a)+", r"(?:\b|a)+",
]

REPS = [
    "[$0]", "<$1>", "${1}x", "$1x", "$10", "$name", "${name}", "$name_x", "$$", "a$",
    "$99", "${", "${}", "$ {1}", "${1", "$-1", "${0}${1}${2}", "$2$1", "${n}", "$n", "", "-",
]


def curated(out):
    k = 0
    for p in PATS:
        for hy in HAYS:
            out.write(f"R\t{h(p)}\t{h(hy)}\t{h(REPS[k % len(REPS)])}\n")
            k += 1
    # every replacement template on a few meaningful pairs
    for p, hy in [("(?P<name>a)(b)?", "abaab"), ("(a)?", "ba"), ("(?P<n>\\w)(?P<name_x>\\w)?", "a中🚀b"),
                  ("", "a中🚀b"), ("a*", "baaac"), ("(a)|(b)", "ab")]:
        for r in REPS:
            out.write(f"R\t{h(p)}\t{h(hy)}\t{h(r)}\n")


ATOMS = ["a", "b", "中", "🚀", ".", r"\w", r"\W", r"\d", r"\s", r"\S", "[ab]", "[^a]", "[a-c中]",
         r"\p{L}", r"\b", r"\B", "^", "$", r"\A", r"\z", "(?m:^)", "(?m:$)", "ß", "k", "\n", "[^\n]", "x"]
QUANTS = ["", "", "", "*", "+", "?", "*?", "+?", "??", "{2}", "{0,2}", "{1,3}?", "{2,}"]
# `(?-u)` is excluded from fuzzing: Rust rejects `(?-u)` classes that may match invalid
# UTF-8 on `&str` (covered separately by curated cases).
FLAGS = ["", "", "", "(?i)", "(?s)", "(?U)", "(?m)", "(?is)", "(?mU)"]
LOOKS = {r"\b", r"\B", "^", "$", r"\A", r"\z", "(?m:^)", "(?m:$)"}
GROUPS = ["(", "(?:", "(?P<g>", "(?i:", "(?U:", "(?s:"]
ALPHA = ["a", "a", "b", "b", "中", "🚀", " ", "\n", "\r", "_", "1", "ß", "S", "k", "K", "x", "é"]


def rand_re(rng, depth):
    n = rng.randint(1, 3)
    parts = []
    for _ in range(n):
        if depth > 0 and rng.random() < 0.35:
            g = rng.choice(GROUPS)
            inner = rand_re(rng, depth - 1)
            if rng.random() < 0.4:
                inner = inner + "|" + rand_re(rng, depth - 1)
            atom = g + inner + ")"
        else:
            atom = rng.choice(ATOMS)
        # repeating a bare assertion (`^*`, `\b{2}`) is a known, separately-reported
        # acceptance gap; keep it out of the fuzzer to surface other classes of bugs.
        parts.append(atom + ("" if atom in LOOKS else rng.choice(QUANTS)))
    s = "".join(parts)
    if rng.random() < 0.15:
        s = s + "|" + rand_re(rng, depth - 1 if depth > 0 else 0)
    return s


def fuzz(out, seed, n):
    rng = random.Random(seed)
    for _ in range(n):
        p = rng.choice(FLAGS) + rand_re(rng, 3)
        p = p.replace("(?P<g>", "(", p.count("(?P<g>") - 1) if p.count("(?P<g>") > 1 else p
        hy = "".join(rng.choice(ALPHA) for _ in range(rng.randint(0, 12)))
        r = rng.choice(REPS[:10] + ["$g", "${g}"])
        out.write(f"R\t{h(p)}\t{h(hy)}\t{h(r)}\n")


CAP_ATOMS = ["a", "b", "ab", "[ab]", ".", "中", "🚀", "(?:a|b)", "(?:)"]
CAP_Q = ["", "", "*", "+", "?", "*?", "+?", "??", "{1,2}", "{0,2}?"]


def rand_cap(rng, depth):
    parts = []
    for _ in range(rng.randint(1, 3)):
        if depth > 0 and rng.random() < 0.6:
            inner = rand_cap(rng, depth - 1)
            if rng.random() < 0.5:
                inner += "|" + rand_cap(rng, depth - 1)
            atom = rng.choice(["(", "(", "(?:"]) + inner + ")"
        else:
            atom = rng.choice(CAP_ATOMS)
        parts.append(atom + rng.choice(CAP_Q))
    return "".join(parts)


def capfuzz(out, seed, n):
    """Capture-heavy fuzz over a tiny alphabet: stresses One-Pass DFA vs PikeVM slot logic."""
    rng = random.Random(seed)
    for _ in range(n):
        p = rng.choice(["", "", "^", "(?U)"]) + rand_cap(rng, 3) + rng.choice(["", "", "$"])
        hy = "".join(rng.choice(["a", "b", "a", "b", "中", "🚀", "c"]) for _ in range(rng.randint(0, 8)))
        out.write(f"R\t{h(p)}\t{h(hy)}\t{h('<$1|$2|$3>')}\n")


SET_POOL = ["a", "b+", "^a", "a$", r"\bfoo\b", "foo", "(?i)FOO", r"\d{3}", "[^a]", "", "x*", "^$",
            "(?m)^bar", "中", r"\p{Greek}", "a.*b", r"\s", "(?s).", "z", r"\Bo", "$", r"\w+\z"]
SET_HAYS = ["", "a", "foo bar", "afoob", "xyz 123", "bar\nfoo", "中文α", "FOO", "b", "\n", "aab"]


def sets(out, seed, n):
    rng = random.Random(seed)
    for hy in SET_HAYS:
        out.write(f"S\t{h(hy)}\t{','.join(h(p) for p in SET_POOL)}\n")
        out.write(f"S\t{h(hy)}\t\n")
    for _ in range(n):
        pats = [rng.choice(SET_POOL + [rand_re(rng, 1)]) for _ in range(rng.randint(1, 8))]
        hy = rng.choice(SET_HAYS) if rng.random() < 0.5 else "".join(rng.choice(ALPHA + ["f", "o"]) for _ in range(rng.randint(0, 10)))
        out.write(f"S\t{h(hy)}\t{','.join(h(p) for p in pats)}\n")


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "curated":
        curated(sys.stdout)
    elif mode == "fuzz":
        fuzz(sys.stdout, int(sys.argv[2]), int(sys.argv[3]))
    elif mode == "capfuzz":
        capfuzz(sys.stdout, int(sys.argv[2]), int(sys.argv[3]))
    elif mode == "sets":
        sets(sys.stdout, int(sys.argv[2]), int(sys.argv[3]))
    else:
        sys.exit("unknown mode")
