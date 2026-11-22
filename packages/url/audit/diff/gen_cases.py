#!/usr/bin/env python3
"""Deterministic differential corpus generator for the `url` red-team audit.

Writes one file per suite into OUT_DIR. Every line is a case in the hex/TAB
protocol shared by audit/diff/pion and audit/diff/rust (see their headers).

Suites:
  idna     IdnaTestV2.txt (Unicode 15.1, shipped with idna 1.1.0) sources run
           through WHATWG domainToASCII / domainToUnicode / `http://<src>/`
  idnareal hand-picked real-world IDN hosts and UTS #46 edge cases
  wpt      every urltestdata.json input (control: upstream suite)
  fuzz     grammar-based + mutation URL fuzz (parse and join), seeded
  fastpath dot-segment look-alikes aimed at the hand-written fast paths
  setters  cross product of base URLs x setters x adversarial values
  random   60,000 random short inputs over every op and setter (crash/hang hunt)
  roundtrip serialization idempotency of every wpt/fuzz parse and join
  pct      percent-decoding of malformed UTF-8
  query    application/x-www-form-urlencoded parsing/serialization
"""

import json
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "data")


def enc(fields):
    out = []
    for f in fields:
        if f is None:
            out.append("~")
        else:
            out.append(f.encode("utf-8").hex())
    return "\t".join(out)


def valid(s):
    try:
        s.encode("utf-8")
        return True
    except UnicodeEncodeError:
        return False


def unescape_idna(s):
    s = re.sub(r"\\u([0-9A-Fa-f]{4})", lambda m: chr(int(m.group(1), 16)), s)
    s = re.sub(r"\\x\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), s)
    return s


def suite_idna():
    cases = []
    seen = set()
    with open(os.path.join(DATA, "IdnaTestV2.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            src = unescape_idna(line.split(";")[0].strip())
            if src == '""':
                src = ""
            if src in seen or not valid(src):
                continue
            seen.add(src)
            cases.append(["A", src])
            cases.append(["U", src])
            cases.append(["P", "http://" + src + "/"])
    return cases


REAL_IDN = [
    # real-world internationalized hosts
    "bücher.de", "BÜCHER.DE", "münchen.de", "straße.de", "faß.de", "παράδειγμα.δοκιμή",
    "ΠΑΡΆΔΕΙΓΜΑ.ΔΟΚΙΜΉ", "пример.испытание", "ПРИМЕР.РФ", "例え.テスト", "中国移动.中国",
    "日本語。ＪＰ", "한국.kr", "مثال.إختبار", "דוגמה.טעסט", "उदाहरण.परीक्षा", "ไทย.ไทย",
    "españa.com", "ESPAÑA.COM", "İstanbul.tr", "istanbul.tr", "Ⅻ.example", "ﬁle.example",
    "ǅ.example", "ẞ.de", "ς.gr", "Σ.gr", "σ.gr", "xn--bcher-kva.de", "XN--BCHER-KVA.DE",
    "xn--zca.de", "xn--4ca.de", "xn--nxasmm1c.com", "ⓐⓑⓒ.com", "㈱.jp", "㍿.jp", "℡.com",
    "½.com", "™.com", "ｅｘａｍｐｌｅ．ｃｏｍ", "example\u3002com", "a\u2024b.com",
    "a\u00ADb.com", "a\u200Bb.com", "a\u200Cb.com", "a\u200Db.com", "\u0915\u094D\u200D\u0937.in",
    "\u0627\u200C\u0628.ir", "a\u0300.com", "e\u0301.com", "\u00e9.com", "\u1E9B\u0323.com",
    "A\u030A.com", "\u212B.com", "\u2126.com", "K.com", "\u212A.com", "\u0130.com",
    "a\u05D0.com", "\u05D0a.com", "\u05D01.com", "1\u05D0.com", "\u0661\u0031.com",
    "\u05D0\u0300.com", "xn--a.com", "xn--.com", "xn---.com", "xn--ls8h.la", "💩.la",
    "-abc.com", "abc-.com", "ab--c.com", "a..b", "a.b..", ".a.b", "a" * 63 + ".com",
    "a" * 64 + ".com", ("a" * 63 + ".") * 4 + "com", "é" * 60 + ".com", "\u0378.com",
    "\U000E0001.com", "\uFFFF.com", "\U0010FFFF.com", "\U0001F1FA\U0001F1F8.com",
    "a\u3000b.com", "a\u00A0b.com", "a\u2028b.com", "a\u202Eb.com", "a\u0600b.com",
    "\u1100\u1161.kr", "\u0BB8\u0BCD.in", "xn--ab-7ka.com", "xn--abc.com", "xn--0.com",
    "xn--99999999999.com", "xn--zzzzzzzzzzzz.com", "xn--a-ecp.ru", "xn--d1acpjx3f.xn--p1ai",
    "xn--80akhbyknj4f.xn--p1ai", "xn--mgbh0fb.xn--kgbechtv", "xn--fiqs8s", "xn--fiqz9s",
    "xn--ngbrx.com", "xn--j6w193g", "xn--55qx5d.cn", "xn--IDNA.com", "xn--a-ecp.xn--a-ecp",
    "\u00DF\u00DF\u00DF.com", "\u03C2\u03C2.com", "\u0DCA\u200D.lk", "a\u094D\u200Cb.in",
    "\u30FB.jp", "a\u30FB.jp", "\u30A2\u30FB.jp", "\u00B7.ca", "l\u00B7l.ca", "\u0375.gr",
    "\u0375\u03B1.gr", "\u05F3.il", "\u05D0\u05F3.il", "\u0660\u06F0.eg",
]


def suite_idnareal():
    cases = []
    for h in REAL_IDN:
        cases.append(["A", h])
        cases.append(["U", h])
        cases.append(["P", "https://" + h + "/p"])
        cases.append(["P", "ws://user@" + h + ":8080/"])
    return cases


def suite_wpt():
    cases = []
    with open(os.path.join(DATA, "urltestdata.json"), encoding="utf-8") as f:
        data = json.load(f)
    for t in data:
        if not isinstance(t, dict):
            continue
        inp, base = t["input"], t.get("base")
        if not valid(inp) or (base is not None and not valid(base)):
            continue
        if base is None:
            cases.append(["P", inp])
        else:
            cases.append(["J", base, inp])
    with open(os.path.join(DATA, "setters_tests.json"), encoding="utf-8") as f:
        data = json.load(f)
    for setter, tests in data.items():
        if setter == "comment":
            continue
        for t in tests:
            if not valid(t["href"]) or not valid(t["new_value"]):
                continue
            cases.append(["S", t["href"], setter, t["new_value"]])
    return cases


SCHEMES = ["http", "https", "ws", "wss", "ftp", "file", "foo", "blob", "data", "javascript",
           "mailto", "HTTP", "sc", "a+b-c.d", "urn", "git+ssh", "h\ttp"]
USERINFO = ["", "u@", "u:p@", ":p@", "u:@", "@", "a@b@", "%40@", "u%3Ap@", "\u00e9:\u00e9@",
            "u:p:q@", "u p@", "[@", "u\\@"]
HOSTS = ["example.com", "EXAMPLE.com", "127.0.0.1", "0x7f.1", "0177.0.0.1", "2130706433",
         "4294967296", "4294967295", "0x100000000", "1.2.3.4.", "1.2.3.4..", "1.256.3.4",
         "09.1", "0x", "1.2.3.09", "999999999999999999999", "[::1]", "[::]", "[1:2:3:4:5:6:7:8]",
         "[::ffff:1.2.3.4]", "[0:0:0:0:0:ffff:7f00:1]", "[1::2:3:4:5:6:7]", "[::1.2.3]",
         "[::1:2::3]", "[fe80::1%25eth0]", "[1:2:3:4:5:6:7:8:9]", "[1:2:3:4:5:6:1.2.3.4]",
         "[:1]", "[1::]", "[0:0::0:0:8]", "localhost", "LOCALHOST", "local%68ost", "",
         "xn--bcher-kva.de", "bücher.de", "a%2eb", "%41.com", "%zz.com", "a b", "a<b",
         "a^b", "a|b", "a%00b", "%ef%bc%85", "\u0130", "ﬀ.com", "[v1.x]", "a..b", "foo.09",
         "foo.0x4", "1.0x", "0..0x300", "abc.123", "abc.0x10", "x.1.2.3.4"]
PORTS = ["", ":", ":80", ":443", ":21", ":0", ":65535", ":65536", ":99999999999", ":8a",
         ":-1", ": 80", ":0080", ":\t80"]
PATHS = ["", "/", "/a/b", "/a/../b", "/a/./b", "/%2e%2E/x", "/.%2e/x", "/a/%2e./b", "/..",
         "/../../..", "/a//b", "\\a\\b", "/a b", "/é", "/%zz", "/a?b", "/C:/x", "/C|/x",
         "/c:/../..", "//x", "/a/;b", "/%2f/", "/\u0000", "/a\nb", "/a\tb", "/~user",
         "/<>\"`{}", "/^|", "/[]", "/%", "/%e2%82", "/a/..%2f..", "/x\u00a0y", "/.//p"]
QUERIES = ["", "?", "?a=b", "?a=b&c", "? '\"<>", "?é", "?%zz", "?a#b", "?\u0000", "?%",
           "?{}`|"]
FRAGS = ["", "#", "#f", "#a b", "#é", "#%zz", "#\u0000", "#`<>\"", "##", "#{}"]
RELATIVE = ["", ".", "..", "./", "../", "../..", "a", "a/b", "/a", "//h/p", "//h", "///p",
            "\\\\h\\p", "?q", "#f", "../?q#f", "%2e%2e/x", ".%2E/x", "c:", "C:/x", "C|", "/C:",
            "//C:/x", "file:x", "http:x", "http:/x", "http://x", "https:x", "foo:x", "foo:/x",
            "//", "///", "////x", "\\x", "/\\x", "\\/x", "#", "?", "?#", "..\\..\\x", ";x",
            "  /x  ", "\t/x\n", "//[::1]:8080/p", "//user:pw@h:1/p", "//:80/", "/./..",
            "a/./../b/../../c", "../../../../..", "//h/../p", "#\u00e9", "?\u00e9"]
BASES = ["http://h/a/b/c?q#f", "https://u:p@h:8443/a/b", "file:///C:/a/b", "file://host/s/p",
         "file:///", "foo://h/a/b", "foo:/a/b", "foo:opaque", "mailto:x@y", "data:text/plain,x",
         "ws://h/", "http://[::1]/a/", "sc://h", "sc:", "file:///a/b/c", "blob:https://a/b",
         "http://h", "foo://", "foo:///x"]


def suite_fuzz(seed=0x5EED, n_parse=6000, n_mut=4000):
    rnd = random.Random(seed)
    cases = []
    # 1. grammar: scheme + authority + path + query + fragment
    for _ in range(n_parse):
        s = rnd.choice(SCHEMES)
        slashes = rnd.choice(["://", "://", ":", ":/", ":///", ":\\\\", ":////"])
        u = s + slashes + rnd.choice(USERINFO) + rnd.choice(HOSTS) + rnd.choice(PORTS) + \
            rnd.choice(PATHS) + rnd.choice(QUERIES) + rnd.choice(FRAGS)
        cases.append(["P", u])
    # 2. relative resolution
    for b in BASES:
        for r in RELATIVE:
            cases.append(["J", b, r])
    # 3. byte-level mutation of WPT/grammar inputs
    seeds = [c[1] for c in cases[:2000]]
    alphabet = list(":/\\?#@[]%.\t\n \u0000\u007f\u00e9\u3002\uff0e\ufffdabc012XYZ-_~+")
    for _ in range(n_mut):
        s = list(rnd.choice(seeds))
        for _ in range(rnd.randint(1, 4)):
            op = rnd.randint(0, 2)
            pos = rnd.randint(0, len(s))
            if op == 0:
                s.insert(pos, rnd.choice(alphabet))
            elif op == 1 and s:
                del s[min(pos, len(s) - 1)]
            elif s:
                s[min(pos, len(s) - 1)] = rnd.choice(alphabet)
        u = "".join(s)
        if rnd.random() < 0.3:
            cases.append(["J", rnd.choice(BASES), u])
        else:
            cases.append(["P", u])
    return cases


SETTER_BASES = ["http://u:p@h.com:8080/a/b?q#f", "https://h.com/", "http://h.com", "file:///C:/x",
                "file://host/p", "file:///", "foo://u@h:1/p?q#f", "foo://h", "foo:///p",
                "foo:/p", "foo:opaque?q#f", "mailto:a@b", "data:x,y", "sc://h/", "sc:",
                "http://[::1]:81/", "http://1.2.3.4/", "ws://h/p", "blob:https://a/b",
                "javascript:alert(1)", "foo://", "foo://@h/", "http://h/%2e/"]
SETTER_VALUES = {
    "protocol": ["http", "https:", "file", "foo", "FOO", "ws", "h:ttp", "http:foo", "", "1x",
                 "a+b", "mailto", "javascript", "blob", " http", "http\t", "sc", "https:x"],
    "username": ["", "user", "us:er", "u@x", "é", "%41", " ", "a/b", "a\u0000b"],
    "password": ["", "pw", "p:w", "p@w", "é", "%zz", "a#b"],
    "host": ["", "h2", "h2:9", "h2:", "h2:99999", "h2:8a", "[::1]", "[::1]:9", "1.2.3.4:80",
             "ex%41mple", "a b", "a/b", "a?b", "a#b", "a\\b", "bücher.de", "xn--a", "x:y:z",
             "@h", "u@h", "localhost", "[::1", "0x7f.1", "h:0", "h:65535", "h:-1", "\u3002",
             "a\u0000b", "h:80", "h:443"],
    "hostname": ["", "h2", "h2:9", "[::1]", "a b", "bücher.de", "xn--a", "localhost",
                 "0x7f.1", "a%00", "a/b", "h#x", "ex\tample"],
    "port": ["", "0", "80", "443", "8080", "65535", "65536", "8a", "a8", " 8", "8 ", "-1",
             "08", "99999999999999999999", "\t81", "1:2"],
    "pathname": ["", "/", "a", "/a/../b", "\\x", "//x", "/%2e", "%2e%2e", "/é", "?x", "#x",
                 "/C:/x", "C|/x", "a b", "/../..", "/\u0000"],
    "search": ["", "?", "a=b", "?a=b", "??", "a#b", "é", "'\"<>", "%zz", "a\u0000"],
    "hash": ["", "#", "f", "#f", "##", "a b", "é", "`<>", "%zz"],
    "href": ["", "http://x/", "relative", "foo:bar", "https://bücher.de/"],
    "set_scheme": ["http", "https", "file", "foo", "FOO", "h:ttp", "http:", "", "1x", "ws",
                   "mailto", "sc", "a+b"],
    "set_username": ["", "user", "a:b", "é"],
    "set_password": [None, "", "pw", "p:w"],
    "set_host": [None, "", "h2", "[::1]", "1.2.3.4", "a b", "bücher.de", "h2:9", "xn--a"],
    "set_port": [None, "0", "80", "443", "8080", "65535"],
    "set_path": ["", "/", "a", "/a/../b", "\\x", "//x", "a b", "/é", "?x", "#x", "../x"],
    "set_query": [None, "", "a=b", "a b", "#x", "é"],
    "set_fragment": [None, "", "f", "a b", "#x", "é"],
}


DOTSEG = [".", "..", "%2e", "%2E", ".%2e", ".%2E", "%2e.", "%2E%2e", "%2e%2e", "a", "", "b.",
          ".a", "...", "%2e%2e%2e", "%2f", "a%2e", "%252e"]


def suite_fastpath(seed=0xFA57, n=4000):
    """Target the hand-written fast paths (`try_fast_parse_absolute`, `try_fast_join`):
    common special-scheme URLs whose path is built from dot-segment look-alikes."""
    rnd = random.Random(seed)
    cases = []
    for _ in range(n):
        segs = "/".join(rnd.choice(DOTSEG) for _ in range(rnd.randint(1, 6)))
        tail = rnd.choice(["", "?q", "#f", "?q#f", "/"])
        sch = rnd.choice(["http", "https", "ws", "wss", "ftp", "HTTP", "foo"])
        host = rnd.choice(["h", "example.com", "1.2.3.4", "[::1]", "u:p@h:8080", "H.COM"])
        cases.append(["P", "%s://%s/%s%s" % (sch, host, segs, tail)])
        base = rnd.choice(["https://h/a/b/c", "http://h/", "https://u:p@h:81/a/b?q#f", "ws://h/x/"])
        rel = rnd.choice(["", "/", "./", "../", "//h2/"]) + segs + tail
        cases.append(["J", base, rel])
    return cases


def suite_setters():
    cases = []
    for b in SETTER_BASES:
        for name, vals in SETTER_VALUES.items():
            for v in vals:
                cases.append(["S", b, name, v])
    # chained mutations
    rnd = random.Random(0xC4A1)
    names = list(SETTER_VALUES.keys())
    for _ in range(3000):
        b = rnd.choice(SETTER_BASES)
        f = ["S", b]
        for _ in range(rnd.randint(2, 4)):
            nm = rnd.choice(names)
            f.append(nm)
            f.append(rnd.choice(SETTER_VALUES[nm]))
        cases.append(f)
    return cases


PCT = ["%", "%%", "%4", "%41", "%zz", "%C3%A9", "%C3", "%C3%", "%C3%41", "%E2%82", "%E2%82%AC",
       "%F0%9F%92%A9", "%F0%9F%92", "%ED%A0%80", "%ED%BF%BF", "%C0%AF", "%C1%BF", "%E0%80%AF",
       "%F0%80%80%AF", "%F4%90%80%80", "%F5%80%80%80", "%FF", "%FE%FF", "%80", "%BF%BF",
       "%E0%A0", "%F0%9F", "a%2", "%00", "%C2%A0", "%EF%BB%BF", "%F8%88%80%80%80",
       "%C3%A9%C3", "%E2%28%A1", "%F0%28%8C%BC", "%F0%90%28%BC", "%E1%80%E2%80"]


def suite_pct():
    cases = [["D", p] for p in PCT]
    rnd = random.Random(7)
    for _ in range(500):
        s = "".join("%%%02X" % rnd.randint(0x80, 0xFF) if rnd.random() < 0.7 else rnd.choice("a%")
                    for _ in range(rnd.randint(1, 6)))
        cases.append(["D", s])
    return cases


QUERY = ["", "a", "a=", "=b", "=", "&", "&&", "a=b&a=c", "a+b=c+d", "a%20b=%2B", "%zz=%",
         "a=%C3", "a=%ED%A0%80", "é=ü", "a=b=c", "?a=b", "a=b;c=d", "a\u0000=b", "%26=%3D",
         "a=1&&b=2&", "~*-._=!'()", "a=%E2%82%AC", "\uFFFD=1", "k=v#f", " = "]


def suite_random(seed=1, n=60000):
    """Crash/hang hunt: random short inputs over every op and every setter."""
    r = random.Random(seed)
    alpha = list(":/\\?#@[]%.\t\n \x00\x7f\u00e9\u3002\uff0e\ufffdabcxn-0123456789XYZ_~+=&;|^<>\"'`{}") + \
        ["\U0001F600", "\u200d", "\u0308", "\u05d0", "\u0130", "\ufb00"]
    sch = ["http://", "https://", "file:", "file:///", "foo://", "foo:", "ws://", "blob:", "", "//",
           "\\\\", "data:", "javascript:"]
    names = list(SETTER_VALUES.keys())

    def rs():
        return "".join(r.choice(alpha) for _ in range(r.randint(0, 30)))
    cases = []
    for _ in range(n):
        u = r.choice(sch) + rs()
        k = r.random()
        if k < 0.5:
            f = ["P", u]
        elif k < 0.75:
            f = ["J", r.choice(sch) + rs(), rs()]
        else:
            f = ["S", r.choice(["http://u:p@h:1/p?q#f", "foo://h/p", "file:///C:/x", "foo:op", "sc:", u])]
            for _ in range(r.randint(1, 3)):
                f += [r.choice(names), None if r.random() < 0.1 else rs()]
        cases.append(f)
    return cases


def suite_roundtrip():
    """Serialization idempotency: parse(serialize(parse(x))) must equal parse(x)."""
    cases = []
    for c in suite_wpt() + suite_fuzz() + suite_fastpath():
        if c[0] == "P":
            cases.append(["R", None, c[1]])
        elif c[0] == "J":
            cases.append(["R", c[1], c[2]])
    return cases


QKEYS = ["a", "b", "A", "", "é", "\uFFFD", "\U0001F600", "\uE000", "\uFF5E", "\U00010000", "a b",
         "a+b", "%", "z", "aa", "a\u0000", "\u00e9t\u00e9", "\u4f60", "~", "Z"]


def suite_query(seed=0x9A9A, n=3000):
    cases = [["Q", q] for q in QUERY]
    rnd = random.Random(seed)
    enc_q = lambda k, v: "%s=%s" % ("".join("%%%02X" % b for b in k.encode()),
                                   "".join("%%%02X" % b for b in v.encode()))
    for _ in range(n):
        size = rnd.choice([0, 1, 3, 8, 20, 24, 25, 31, 32, 33, 40, 70])
        q = "&".join(enc_q(rnd.choice(QKEYS), rnd.choice(QKEYS + ["v", "1"])) for _ in range(size))
        f = ["M", q]
        for _ in range(rnd.randint(1, 6)):
            o = rnd.choice(["d", "s", "a", "sort", "sort", "g", "h"])
            f.append(o)
            if o in ("d", "g", "h"):
                f.append(rnd.choice(QKEYS))
            elif o in ("s", "a"):
                f += [rnd.choice(QKEYS), rnd.choice(QKEYS)]
        cases.append(f)
    return cases


SUITES = {
    "idna": suite_idna,
    "idnareal": suite_idnareal,
    "wpt": suite_wpt,
    "fuzz": suite_fuzz,
    "fastpath": suite_fastpath,
    "setters": suite_setters,
    "pct": suite_pct,
    "query": suite_query,
    "random": suite_random,
    "roundtrip": suite_roundtrip,
}


def main():
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    for name, fn in SUITES.items():
        cases = fn()
        with open(os.path.join(out_dir, name + ".in"), "w", encoding="ascii") as f:
            for c in cases:
                f.write(enc(c) + "\n")
        print(f"{name}: {len(cases)} cases")


if __name__ == "__main__":
    main()
