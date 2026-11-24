"""Corpus generator for packages/cookie/audit (stdlib only, deterministic: fixed seeds).

    python3 -I gen.py <out_dir> [fuzz_n]

Writes parse.cases, date.cases, psl.cases, testpsl.cases (+ testpsl.expect), match.cases and jar.cases.
Inputs that are not printable ASCII (or contain a TAB inside a jar field) are written in the `hex:` form.
"""

import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import spec_ref  # noqa: E402


def enc(s):
    b = s.encode("utf-8", "surrogateescape") if isinstance(s, str) else s
    if all(0x20 <= c < 0x7F for c in b) and not b.startswith(b"hex:"):
        return b.decode("ascii")
    return "hex:" + b.hex()


def jenc(s):
    """A jar protocol field: hex when it holds a TAB / non-printable byte."""
    return enc(s)


def rcase(r, s):
    return "".join(ch.upper() if r.random() < 0.5 else ch.lower() for ch in s)


# ---------------------------------------------------------------------------------------------------------------
# dates
# ---------------------------------------------------------------------------------------------------------------

WD = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun", "Monday", "Sunday"]
MO = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec", "January", "sept", "DEC"]


def gen_date(r):
    y = r.choice([r.randint(1601, 2100), r.randint(0, 99), r.choice([1600, 1601, 1900, 2000, 2024, 9999, 10000, 69, 70,
                                                                     100, 999, 0])])
    d = r.choice([r.randint(1, 28), r.choice([0, 1, 29, 30, 31, 32, 99])])
    hh, mm, ss = (r.choice([r.randint(0, 23), 24, 99]), r.choice([r.randint(0, 59), 60]),
                  r.choice([r.randint(0, 59), 60]))
    mon = r.choice(MO)
    k = r.randrange(9)
    ys = str(y) if r.random() < 0.8 else "%02d" % (y % 100)
    t = "%02d:%02d:%02d" % (hh, mm, ss) if r.random() < 0.8 else "%d:%d:%d" % (hh, mm, ss)
    if k == 0:
        s = "%s, %02d %s %s %s GMT" % (r.choice(WD), d, mon, ys, t)
    elif k == 1:
        s = "%s, %02d-%s-%s %s GMT" % (r.choice(WD), d, mon, ys, t)
    elif k == 2:
        s = "%s %s %2d %s %s" % (r.choice(WD), mon, d, t, ys)
    elif k == 3:
        parts = [str(d), mon, ys, t]
        r.shuffle(parts)
        s = r.choice([" ", "-", "/", ",", "  ", "\t"]).join(parts)
    elif k == 4:
        s = "%d %s %s %s%s" % (d, mon, ys, t, r.choice(["junk", ".5", "Z", "+0100", "1", ""]))
    elif k == 5:
        s = "%s %s %s %s" % (r.choice(["", "noise ", "1st "]), mon.lower(), d, t) + " " + ys
    elif k == 6:
        s = "%d%s %s %s" % (d, r.choice(["", "th", "x"]), mon, ys) + " " + r.choice([t, t + ":00", "1" + t, t[:5]])
    elif k == 7:
        s = "".join(r.choice("0123456789 :-,/JanFebMarDec\t;=") for _ in range(r.randint(0, 30)))
    else:
        s = "%s %s %s %s" % (ys, mon, d, t)
    if r.random() < 0.03:
        s = s.replace(" ", chr(r.choice([0, 1, 0x1F, 0x7F, 0x80, 0xC3])), 1)
    return s


def date_cases(r, n):
    fixed = [
        "Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994",
        "Thu, 01 Jan 1970 00:00:00 GMT", "01 Jan 1601 00:00:00", "31 Dec 1600 23:59:59", "31 Dec 9999 23:59:59",
        "29 Feb 1900 00:00:00", "29 Feb 2000 00:00:00", "29 Feb 2024 00:00:00", "30 Feb 2024 00:00:00",
        "01 Jan 2024 24:00:00", "01 Jan 2024 23:59:60", "1 jan 69 0:0:0", "1 jan 70 0:0:0", "1 jan 0 0:0:0",
        "1 jan 00 0:0:0", "1 jan 0000 0:0:0", "1 jan 0001 0:0:0", "123:00:00 1 jan 2000", "00:00:00 1 2000 jan",
        "1 2 3 4:5:6 jan", "jan", "", " ", "01:02:03", "Wed, 09 Jun 2021 10:18:14 GMT-0000",
    ]
    return fixed + [gen_date(r) for _ in range(n)]


# ---------------------------------------------------------------------------------------------------------------
# Set-Cookie headers
# ---------------------------------------------------------------------------------------------------------------

NAMES = ["a", "sid", "SID", "__Secure-s", "__Host-h", "__HOST-x", "__secure-y", "__Http-t", "__Host-Http-u", "",
         "n m", "\"q\"", "名", "a\tb", "x.y", "__Host", "__Host-", "_Host-z"]
VALUES = ["1", "v", "x y", "\"q v\"", "__Host-z=1", "__secure-w", "=", "", "a=b=c", "值č", " pad ", "%20", "\t1\t"]
DOMAINS = ["example.com", ".example.com", "..example.com", "EXAMPLE.COM", "www.example.com", "co.uk", "github.io",
           "a.github.io", "example.co.uk", "127.0.0.1", "0.0.1", "", " example.com ", "ex ample.com", "xn--85x722f.cn",
           "com.", "example.com."]
PATHS = ["/", "/a", "/a/b", "/a/", "", "foo", "/admin", "/ä", " /x ", "/x;", "//", "/a b"]


def attr(r):
    k = r.randrange(13)
    if k == 0:
        return rcase(r, "Expires") + "=" + gen_date(r)
    if k == 1:
        return rcase(r, "Max-Age") + "=" + r.choice(["0", "-1", "60", "+60", "6O", "", "-", "99999999999999999999",
                                                    "-0", " 7", "007", "1.5"])
    if k == 2:
        return rcase(r, "Domain") + "=" + r.choice(DOMAINS)
    if k == 3:
        return rcase(r, "Path") + "=" + r.choice(PATHS)
    if k == 4:
        return rcase(r, "Secure") + r.choice(["", "", "=1", "=false"])
    if k == 5:
        return rcase(r, "HttpOnly") + r.choice(["", "", "=0"])
    if k == 6:
        return rcase(r, "SameSite") + "=" + r.choice(["Strict", "lax", "NONE", "Bogus", "", "None ", "Lax\t"])
    if k == 7:
        return rcase(r, "Partitioned") + r.choice(["", "", "=no"])
    if k == 8:
        return r.choice(["", " ", "=", "=x", "Comment=hi", "Version=1", "Priority=High", "secure ", " domain"])
    if k == 9:
        return rcase(r, "Path") + "=/" + "p" * r.choice([1022, 1023, 1024, 1025])
    if k == 10:
        return rcase(r, "Domain") + "=" + "d" * r.choice([1023, 1024, 1025])
    if k == 11:
        return rcase(r, "SameSite") + "=" + r.choice(["Strict", "Lax", "None"]) + "; SameSite=" + r.choice(
            ["Bogus", "", "Lax"])
    return rcase(r, "Path") + "=" + r.choice(["/x", "/"]) + "; Path=" + r.choice(["y", "", "/z"])


def gen_header(r):
    name = r.choice(NAMES)
    value = r.choice(VALUES)
    if r.random() < 0.05:
        value = "v" * r.choice([4094, 4095, 4096])
    if name == "" and r.random() < 0.5:
        nvp = value
    else:
        nvp = r.choice(["", " ", "\t"]) + name + r.choice(["", " "]) + "=" + r.choice(["", " "]) + value
    attrs = [attr(r) for _ in range(r.randint(0, 6))]
    s = nvp + "".join(r.choice([";", "; ", " ;", ";\t", ";;"]) + a for a in attrs)
    if r.random() < 0.04:
        pos = r.randint(0, len(s))
        s = s[:pos] + chr(r.choice([0, 9, 10, 13, 0x7F, 1, 0x1F])) + s[pos:]
    return s


def parse_cases(r, n):
    fixed = [
        "a=b", "a=b; Path=/", "=b", "b", "=", "; Secure", " ; Path=/", "a=", "=a=b", "__Host-x", "=__Host-x=1",
        "a=b; Max-Age=+5", "a=b; Max-Age=-5", "a=b; Max-Age=99999999999999999999", "a=b; Max-Age=", "a=b; Max-Age=-",
        "a=b; SameSite=None; SameSite=Bogus", "a=b; Path=/; Path=foo", "a=b; Domain=..example.com",
        "a=b; Domain=.", "a=b; Domain=", "a=\"x\"", "a=b; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=1",
        "a=b;Secure;HttpOnly;Partitioned;SameSite=Strict", "a=b\tc", "a=b\r\nc=d", "a=b\x00", "a=b; Path=/\x7f",
    ]
    out = fixed + [gen_header(r) for _ in range(n)]
    # "Domain=." is left to the implementation (see spec_ref.parse_set_cookie); keep it out of the random part
    return [h for i, h in enumerate(out) if i < len(fixed) or ("omain=." not in h.lower() and "omain= ." not in h.lower())
            and not any(x in h.lower() for x in ("domain=.;", "domain=. "))]


# ---------------------------------------------------------------------------------------------------------------
# PSL
# ---------------------------------------------------------------------------------------------------------------

def psl_cases(r):
    out = []
    for rule in sorted(spec_ref.rules()):
        if rule.startswith("!"):
            base = rule[1:]
            out += [base, "x." + base]
        elif rule.startswith("*."):
            base = rule[2:]
            out += [base, "w." + base, "x.w." + base]
        else:
            out += [rule, "x." + rule, "y.x." + rule]
    extra = [
        "", ".", "..", "com", "COM", "example.COM", ".example.com", "example.com.", "example..com", "a.b.example.com",
        "co.uk.", "CO.UK", "www.co.uk.", "127.0.0.1", "127.0.0.1.", "[::1]", "::1", "1.2.3", "1.2.3.4.5", "01.2.3.4",
        "256.1.1.1", "食狮.com.cn", "食狮.公司.cn", "www.食狮.公司.cn", "shishi.中国", "中国", "xn--55qx5d.cn",
        "www.Éxample.com", "WWW.ÉXAMPLE.COM", "www.example\u3002com", "x.ПР.СРБ", "x.пр.срб", "www.ＥＸＡＭＰＬＥ.com",
        "www.ΕΛ", "x.ČÁHCESUOLO.NO", "x.c\u030ca\u0301hcesuolo.no", "x.a\u030alesund.no", "x.\U0001d41example.com",
        "x.\ufb01.com", "x.ҚАЗ", "ร้าน.ไทย", "www.ร้าน.ไทย", "x.ธุรกิจ.ไทย", "Ünïcödé.de", "ab\u00df.de", "xn--zz.com",
        "a" * 63 + ".com", ".".join(["a"] * 200) + ".com", "x" * 300 + ".co.uk", "s3.amazonaws.com",
        "bucket.s3.amazonaws.com", "kawasaki.jp", "city.kawasaki.jp", "www.city.kawasaki.jp", "x.kawasaki.jp",
        "a.x.kawasaki.jp", "ck", "www.ck", "test.ck", "b.test.ck", "github.io", "a.github.io", "a.b.github.io",
        "\udcff.com", "a.\udcc3.com", "com\x00.evil", "ex ample.com", "-x.com", "x-.com", "_x.com",
        # binary-search boundaries: before the first rule, after the last, between neighbours, prefixes of rules
        "!", "*", "0", "!a", "*.a", "a", "zw", "zx", "zz", "zzzzzz", "~", "a.~", "zw.zw", "z", "zuerich.zw", "co",
        "c", "uk", "k12", "ac.a", "!www.ck.x",
    ]
    out += extra
    return out


def testpsl_cases():
    """Mozilla tests/test_psl.txt -> (input, expected registrable domain or '-'); null inputs are skipped."""
    cases = []
    for line in open(os.path.join(HERE, "..", "psl", "test_psl.txt"), encoding="utf-8"):
        line = line.strip()
        if not line.startswith("checkPublicSuffix("):
            continue
        args = line[len("checkPublicSuffix("):line.rindex(")")]
        a, b = [x.strip() for x in args.split(",", 1)]
        if a == "null":
            continue
        cases.append((a.strip("'"), "-" if b == "null" else b.strip("'")))
    return cases


# ---------------------------------------------------------------------------------------------------------------
# match: domain-match / path-match / URL split / Cookie header
# ---------------------------------------------------------------------------------------------------------------

def match_cases(r, n):
    hosts = ["example.com", "www.example.com", "EXAMPLE.com", "xexample.com", "example.com.", "127.0.0.1",
             "1.127.0.0.1", "0.0.1", "[::1]", "a.b.c", "b.c", "c", ""]
    paths = ["/", "/a", "/a/", "/a/b", "/ab", "/A", "", "a", "/a/b/c", "//", "/a%2Fb"]
    out = []
    for _ in range(n):
        out.append("dm\t%s\t%s" % (r.choice(hosts), r.choice(hosts)))
        out.append("pm\t%s\t%s" % (r.choice(paths), r.choice(paths)))
    urls = [
        "https://example.com", "https://example.com/", "HTTPS://EXAMPLE.COM:443/A/b?x=1#f", "http://user:pw@example.com/",
        "https://a@b@example.com/x", "https://[::1]:8443/p", "https://example.com./a/b/c", "wss://example.com/s",
        "ftp://example.com/", "https://evil.com\\@good.com/", "https://good.com\\evil", "https://example.com\\a\\b",
        "http://example.com?q", "http://example.com#x", "https:///x", "https://", "example.com/x", "://x",
        "javascript:x://y", "https://example.com:/", "https://@example.com/", "https://example.com/\\x",
    ]
    for u in urls:
        out.append("url\t" + jenc(u))
    for h in ["a=1; b=2", "a=1;b=2;", " a = 1 ;; b", "=x", "a", "a=1\r\nX: y", "a=\"q\"; b=c=d", "", ";", "a=b\tc"]:
        out.append("chdr\t" + jenc(h))
    return out


# ---------------------------------------------------------------------------------------------------------------
# jar scenarios
# ---------------------------------------------------------------------------------------------------------------

HOSTS = ["example.com", "www.example.com", "a.example.com", "b.a.example.com", "evil.example.com", "example.co.uk",
         "www.example.co.uk", "co.uk", "a.github.io", "b.github.io", "github.io", "www.ck", "a.www.ck", "a.foo.ck",
         "city.kawasaki.jp", "a.city.kawasaki.jp", "x.kawasaki.jp", "127.0.0.1", "[::1]", "other.org",
         "xn--85x722f.xn--55qx5d.cn"]
RPATHS = ["/", "/a", "/a/b", "/a/b/c", "/admin", "/admin/x", "/ab", ""]
TOPS = ["-", "-", "-", "https://example.com", "https://a.example.com:8443/x", "http://example.com", "https://other.org",
        "https://www.example.co.uk", "https://github.io", "https://a.github.io"]
UNPART = ["a", "b", "sid", "__Secure-s", "__Host-h", "__hOsT-x", "__Http-t", "__Host-Http-u", ""]
PART = ["pa", "pb", "__Host-pc"]


def url(r, host=None):
    host = host or r.choice(HOSTS)
    if r.random() < 0.02:
        return "https://other.org\\@" + host + "/"
    scheme = "https" if r.random() < 0.7 else "http"
    port = ":8443" if r.random() < 0.1 else ""
    return "%s://%s%s%s" % (scheme, host, port, r.choice(RPATHS))


def ctx_fields(r, now, u=None):
    return [str(now), jenc(u or url(r)), r.choice(TOPS), "1" if r.random() < 0.85 else "0",
            "1" if r.random() < 0.7 else "0", "1" if r.random() < 0.5 else "0", "1" if r.random() < 0.7 else "0"]


def jar_header(r):
    partitioned = r.random() < 0.15
    name = r.choice(PART if partitioned else UNPART)
    value = r.choice(["1", "2", "v", "x y", "\"q\"", "__Host-z=1", "__secure-w", "z=9"]) if name == "" else \
        r.choice(["1", "2", "v", "x y", ""])
    nvp = value if (name == "" and r.random() < 0.5) else name + "=" + value
    prefixed = name.lower().startswith("__host")
    attrs = []
    for _ in range(r.randint(0, 5)):
        k = r.randrange(9)
        if k == 0:
            d = r.choice(["example.com", ".example.com", "..example.com", "EXAMPLE.com", "a.example.com", "co.uk",
                          "example.co.uk", "github.io", "a.github.io", "www.ck", "foo.ck", "kawasaki.jp",
                          "city.kawasaki.jp", "127.0.0.1", "0.0.1", "other.org", "ample.com", ""])
            attrs.append("Domain=" + d)
        elif k == 1:
            attrs.append("Path=" + (r.choice(["/", "/a", "/a/b", "/admin"]) if prefixed else
                                    r.choice(["/", "/a", "/a/b", "/admin", "/ab", "foo", ""])))
        elif k == 2:
            attrs.append("Secure")
        elif k == 3:
            attrs.append("HttpOnly")
        elif k == 4:
            attrs.append("SameSite=" + r.choice(["Strict", "Lax", "None", "Bogus"]))
        elif k == 5:
            attrs.append("Max-Age=" + r.choice(["-1", "0", "60", "100000000"]))
        elif k == 6:
            attrs.append("Expires=" + r.choice(["Thu, 01 Jan 1970 00:00:00 GMT", "Fri, 31 Dec 9999 23:59:59 GMT",
                                                "Tue, 14 Nov 2023 22:15:00 GMT"]))
        elif k == 7 and r.random() < 0.3:
            attrs.append("SameSite=None; Secure")
        else:
            attrs.append("Secure")
    if partitioned:
        attrs.append("Partitioned")
        if r.random() < 0.85:
            attrs += ["Secure", "SameSite=None"]
    r.shuffle(attrs)
    return "; ".join([nvp] + attrs)


def jar_block(r, k):
    lines = ["=== random %d" % k]
    now = 1700000000
    for _ in range(r.randint(8, 30)):
        now += r.randint(1, 4)
        x = r.random()
        if x < 0.6:
            lines.append("\t".join(["set"] + ctx_fields(r, now) + [jenc(jar_header(r))]))
        elif x < 0.95:
            lines.append("\t".join(["get"] + ctx_fields(r, now)))
        elif x < 0.97:
            lines.append("dump")
        elif x < 0.985:
            lines.append("purge\t%d" % (now + r.choice([0, 60, 100000000])))
        else:
            lines.append("cleardom\t" + r.choice(["example.com", "EXAMPLE.COM", "a.example.com", "other.org"]))
    lines += ["dump", "rt"]
    return lines


def eviction_block(r, k):
    """Eviction under a per-domain limit (one host, host-only cookies) or the global limit (one host per site)."""
    lines = ["=== eviction %d" % k]
    now = 1700000000
    if k % 2 == 0:
        lines.append("limits\t50\t%d\t-\t1" % r.randint(2, 5))
        hosts = ["e.example"]
    else:
        lines.append("limits\t%d\t50\t-\t1" % r.randint(2, 6))
        hosts = ["s%d.example" % i for i in range(6)]
    for _ in range(r.randint(10, 30)):
        now += r.randint(1, 3)
        h = r.choice(hosts)
        if r.random() < 0.7:
            hdr = "%s=%d%s%s" % (r.choice("abcdefgh"), r.randint(0, 9), "; Secure" if r.random() < 0.4 else "",
                                 "; Max-Age=%d" % r.choice([1, 2, 1000]) if r.random() < 0.3 else "")
            lines.append("\t".join(["set", str(now), "https://%s/" % h, "-", "1", "1", "1", "1", hdr]))
        else:
            lines.append("\t".join(["get", str(now), "https://%s/" % h, "-", "1", "1", "1", "1"]))
    lines.append("dump")
    return lines


def curated_blocks():
    t = 1700000000
    S = lambda n, u, h, top="-", http="1", same="1", nav="1", safe="1": "\t".join(
        ["set", str(t + n), jenc(u), top, http, same, nav, safe, jenc(h)])
    G = lambda n, u, top="-", http="1", same="1", nav="1", safe="1": "\t".join(
        ["get", str(t + n), jenc(u), top, http, same, nav, safe])
    return [
        ["=== nameless prefix (P1-1)", S(0, "http://example.com/", "=__Host-sid=evil"), S(1, "http://example.com/", "__Secure-x"),
         G(2, "https://example.com/"), "dump"],
        ["=== leave secure alone (P1-2)", S(0, "https://example.com/", "sid=good; Secure; Path=/"),
         S(1, "http://example.com/", "sid=evil; Path=/app"), S(2, "http://a.example.com/", "sid=evil"),
         S(3, "https://example.com/", "a=1; Secure; Path=/login"), S(4, "http://example.com/", "a=2; Path=/foo"),
         G(5, "https://example.com/app/x"), "dump"],
        ["=== host-only identity (P1-3)", S(0, "https://example.com/", "sid=victim; HttpOnly; Path=/"),
         S(1, "https://evil.example.com/", "sid=attacker; Domain=example.com; Path=/"), G(2, "https://example.com/"),
         S(3, "https://evil.example.com/", "sid=; Domain=example.com; Path=/; Max-Age=0"), G(4, "https://example.com/"), "dump"],
        ["=== cross-site set (P1-4)", S(0, "https://example.com/api", "csrf=x; Path=/", "https://other.org", "1", "0", "0"),
         S(1, "https://example.com/", "s=x; SameSite=Strict", "https://other.org", "1", "0", "1"),
         S(2, "https://example.com/", "n=x; SameSite=None; Secure", "https://other.org", "1", "0", "0"),
         S(3, "https://example.com/", "d=x", "https://other.org", "0", "0", "0"), G(4, "https://example.com/"), "dump"],
        ["=== backslash host (P1-6)", S(0, "https://example.com/", "sid=secret; Secure; Path=/"),
         G(1, "https://other.org\\@example.com/"), S(2, "https://other.org\\@example.com/", "fix=1; Path=/"),
         G(3, "https://example.com/"), "dump"],
        ["=== samesite default (P2-1)", S(0, "https://example.com/", "l=1; SameSite=None; SameSite=Bogus; Secure"),
         G(1, "https://example.com/", "https://other.org", "1", "0", "0"), S(2, "https://example.com/", "x=1; SameSite=Lax"),
         G(3, "https://example.com/", "https://other.org", "0", "0", "1", "1"), "dump"],
        ["=== path override (P2-2)", S(0, "https://example.com/a/b", "p=1; Path=/; Path=foo"), G(1, "https://example.com/"), "dump"],
        ["=== multidot domain (P2-3)", S(0, "https://www.example.com/", "a=1; Domain=..example.com"),
         G(1, "https://other.example.com/"), "dump"],
        ["=== chips", S(0, "https://embed.example/", "p=1; Secure; Partitioned; SameSite=None; Path=/", "https://a.com", "1", "0", "0"),
         G(1, "https://embed.example/", "https://www.a.com:8443/x", "1", "0", "0"),
         G(2, "https://embed.example/", "https://b.com", "1", "0", "0"), G(3, "https://embed.example/", "http://a.com", "1", "0", "0"),
         "dump", "rt"],
        ["=== psl", S(0, "https://example.co.uk/", "a=1; Domain=co.uk"), S(1, "https://co.uk/", "b=1; Domain=co.uk"),
         S(2, "https://a.github.io/", "c=1; Domain=github.io"), S(3, "https://a.www.ck/", "d=1; Domain=www.ck"),
         S(4, "https://a.foo.ck/", "e=1; Domain=foo.ck"), G(5, "https://www.co.uk/"), G(6, "https://b.www.ck/"), "dump"],
    ]


def main():
    out = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 4000
    os.makedirs(out, exist_ok=True)
    r = random.Random(6265)
    w = lambda name, lines: open(os.path.join(out, name), "w", encoding="ascii").write(
        "".join(l + "\n" for l in lines))
    w("parse.cases", [enc(x) for x in parse_cases(r, n)])
    w("date.cases", [enc(x) for x in date_cases(r, n)])
    w("psl.cases", [enc(x) for x in psl_cases(r)])
    tp = testpsl_cases()
    w("testpsl.cases", [enc(a) for a, _ in tp])
    w("testpsl.expect", [enc(b) for _, b in tp])
    w("match.cases", match_cases(r, n // 4))
    blocks = curated_blocks() + [jar_block(r, k) for k in range(n // 10)] + [eviction_block(r, k) for k in range(40)]
    w("jar.cases", [l for b in blocks for l in b])
    for f in sorted(os.listdir(out)):
        if f.endswith(".cases"):
            print("%s=%d" % (f[:-6], sum(1 for _ in open(os.path.join(out, f)))))


if __name__ == "__main__":
    main()
