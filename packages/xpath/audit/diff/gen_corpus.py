#!/usr/bin/env python3
"""RT-xpath differential corpus: hand-written W3C XPath 1.0 edge vectors, an axis x node-test
x predicate cross product over a rich document, and a seeded number-conversion fuzzer.

usage: gen_corpus.py OUT.json        (deterministic; seed fixed below)
Output: JSON list of groups {"xml":..., "ns":[[p,u]...], "vars":[[s|n,name,val]...], "q":[...]}.
"""
import json
import math
import random
import re
import struct
import sys
from decimal import Decimal

SEED = 0x5EED_1A7

RICH = (
    '<?pi-top first data?><!--lead comment-->'
    '<lib xmlns="urn:default" xmlns:bk="urn:book" xml:lang="en-GB" id="L">'
    '<bk:shelf id="s1" bk:code="A1" n="1">'
    '<bk:book id="b1" year="1999" price="10.5"><title>Alpha</title><x xml:lang="de">  Ein  Buch </x></bk:book>'
    '<bk:book id="b2" year="2005" price="20"><title>Beta</title><?note b2 note?></bk:book>'
    '<!--mid--><bk:book id="b3" year="2012" price="-3"><title>Gamma</title></bk:book>'
    '</bk:shelf>'
    '<shelf xmlns="" id="s2" n="2"><book id="b4" year="2020" price="NaN">Delta<!--c-->Tail</book>'
    '<book id="b5" price="1e3">  Epsilon  </book><empty/></shelf>'
    '<bk:shelf xmlns:bk="urn:book2" id="s3"><bk:book id="b6" price=" 7 ">Zeta</bk:book></bk:shelf>'
    '</lib><?pi-end?>'
)
RICH_NS = [["d", "urn:default"], ["bk", "urn:book"], ["b2", "urn:book2"], ["none", ""]]

AXES = [
    "child", "descendant", "parent", "ancestor", "following-sibling", "preceding-sibling",
    "following", "preceding", "attribute", "namespace", "self", "descendant-or-self",
    "ancestor-or-self",
]
TESTS = ["node()", "*", "text()", "comment()", "processing-instruction()",
         "processing-instruction('note')", "bk:*", "bk:book", "d:title", "book", "id", "bk", "xml"]
PREDS = ["", "[1]", "[last()]", "[position() mod 2 = 0]", "[2][1]", "[@id]", "[last()-1]"]
ORIGINS = ["/", "//bk:book[2]", "//book[1]", "//d:title[1]", "//@year[2]/..", "//x",
           "(//@*)[5]", "(//text())[3]", "//comment()[2]", "//processing-instruction()[2]",
           "(//namespace::*)[3]"]

HAND = [
    # ---- §3.7 lexical disambiguation & grammar corners
    ('<r><div><div>3</div></div><and><or>1</or></and><mod>2</mod><a-b>5</a-b><a>7</a><b>2</b>'
     '<node><node/></node><text><text>t</text></text><comment/><processing-instruction/></r>', [], [
        "count(/r/div/div)", "/r/div/div * /r/mod", "/r/div/div div /r/mod", "/r/div/div mod /r/mod",
        "string(/r/and/or)", "count(/r/and/or)", "/r/a-b", "/r/a -/r/b", "/r/a - /r/b", "/r/a-/r/b",
        "count(/r/node/node())", "count(/r/node/node)", "count(/r/text/text())", "count(/r/text/text)",
        "count(/r/comment)", "count(/r/comment())", "count(/r/processing-instruction)",
        "count(child::r/child::div)", "/r/mod mod 3", "/r/mod div 2", "count(//div[1])",
        "count(/descendant::div[1])", "count((//div)[1])", "(/r/a | /r/b)[2]", "(/r/a | /r/b)[2]/text()",
        "---1", "- - -1", ".5 + 5.", "5.", ".5", "1e5", "1E5", "1.e", "'single'", '"double"',
        "count(/r/*[self::div or self::and])", "/r/a*2", "/r/a*/r/b", "count(*/*)", "count(/r/ div)",
        "1 = 1 = 1", "1 < 2 < 3", "3 > 2 > 1", "count(/r/*) * *", "div", "count(div)", "mod mod mod",
        "- /r/a", "2-1", "2 -1", "count(r[.//text = 't'])", "count(/r/*/@*)", "*/@*", "count(*/*/*)",
        "/r/a  *  /r/b", "count(//*[name()='and' or name() = 'or'])", "child :: r", "count(/ r / a)",
        "count(//. )", "count(/r/../r)", "count(.//.)", "@*", "count(/r/a/following-sibling::*[1]/self::b)",
        "//a[1][1]", "count(//a | //b | //a)", "(1)", "((((1))))", "(//a)[1]/..", "string(/r/a/.)",
        "", "/", "//", "/r/", "a/", "1 +", "()", "(1", "1)", "[1]", "@", "child::", "foo::a",
        "count(/r/a[1]", "/r/a[]", "'unterminated", "$", "$1", "a:", ":a", "a::b", "1..2", "1.2.3",
        "a!b", "a!=b", "a = = b", "1 and", "or 1", "a | 1", "1 | a", "-'1'", "--'1'", "- - '2'",
        "number('1e5')", "number('+1')", "number(' 12 ')", "number('')", "number('-')", "number('.')",
        "number('5.')", "number('-.5')", "number('1 2')", "number('- 1')", "number('0x10')",
        "number('\t\n 3 \r')", "number(' 3')", "number('Infinity')", "number('NaN')",
    ]),
    # ---- data model: text merging, CDATA, entities, PIs, comments, namespace nodes
    ('<?pi1 data?><!--top--><r xmlns="urn:d" xmlns:p="urn:p" p:at="1" at2="2">'
     '<x xmlns=""><y/>a<![CDATA[b]]>&amp;c<![CDATA[]]>d</x><p:z xmlns:p="urn:p2"/>'
     '<w>1<!--c-->2</w><v> </v><u><![CDATA[]]></u><t>&#x1F600;&lt;</t></r><?pi2?>',
     [["d", "urn:d"], ["p", "urn:p"], ["q", "urn:p2"]], [
        "count(/node())", "/node()", "count(//namespace::*)", "/*/namespace::*",
        "//*[local-name()='x']/namespace::*", "//*[local-name()='z']/namespace::*",
        "count(/*/@*)", "name(/*/@*[1])", "string(//processing-instruction('pi2'))",
        "local-name(/processing-instruction())", "name(/processing-instruction()[1])",
        "name(/*/namespace::*[last()])", "name(/)", "local-name(/)", "namespace-uri(/)",
        "namespace-uri(/*)", "local-name(//comment())", "name(//comment())", "namespace-uri(/*/namespace::p)",
        "/*/namespace::p/..", "count(/*/@p:at)", "name(/*/@*[1]/..)", "count(//x/text())", "string(//x)",
        "//x/text()", "count(//u/text())", "count(//u/node())", "count(//v/text())", "count(//w/text())",
        "string(//t)", "string-length(//t)", "/d:r/x/y", "count(/r)", "count(/d:r)", "count(//p:z)",
        "count(//q:z)", "count(//p:*)", "count(//q:*)", "count(//d:*)", "count(//*)", "name(//q:z)",
        "local-name(//q:z)", "namespace-uri(//q:z)", "namespace-uri(//y)", "count(//@d:*)",
        "count(//@p:*)", "count(//@*[namespace-uri()=''])", "count(/*/namespace::*/..)",
        "/*/namespace::*/parent::*", "count(//namespace::xml)", "string(/*/namespace::xml)",
        "count(/*/namespace::*[name()=''])", "count(//x/namespace::*[name()=''])",
        "/*/namespace::* | /*/@*", "(/*/@* | /*/namespace::* | /*)[1]", "(/*/@* | /*/namespace::*)[last()]",
        "name(name())", "name(zz)", "local-name(zz)", "namespace-uri(zz)", "name(1)", "string(/)",
        "string(/processing-instruction())", "string(//comment())", "boolean(//namespace::*[.='urn:p'])",
        "count(//*/namespace::*[. = 'urn:p'])", "count(//namespace::*[. = 'urn:p']/..)",
        "unbound:x", "count(//unbound:*)", "count(//xml:*)", "count(//@xml:*)",
        "processing-instruction('pi1')", "count(processing-instruction(pi1))",
        "count(//processing-instruction( 'pi1' ))", "count(//node()[self::processing-instruction()])",
    ]),
    ('<a xmlns:xml="http://www.w3.org/XML/1998/namespace" xmlns:p="u"><b xmlns:p="u2"/></a>', [], [
        "count(/a/namespace::*)", "count(/a/namespace::xml)", "count(/a/b/namespace::xml)",
        "string(/a/b/namespace::p)", "count(/a/b/namespace::*)",
    ]),
    # ---- reverse axes, proximity positions, document order
    ('<r><a id="1"/><a id="2"><b id="b1"><c id="c1" x="y" z="w"/></b><b id="b2"/></a><a id="3"/><a id="4"/></r>',
     [], [
        "string(/r/a[4]/preceding-sibling::*[1]/@id)", "string((/r/a[4]/preceding-sibling::*)[1]/@id)",
        "/r/a[4]/preceding-sibling::*[position()<3]/@id", "string(//c/ancestor::*[1]/@id)",
        "name(//c/ancestor::*[last()])", "name((//c/ancestor::*)[1])", "//c/preceding::*", "//c/following::*",
        "//c/@x/following::*", "//c/@x/preceding::*", "//c/@x/parent::node()", "//c/@x/ancestor::*",
        "//c/@x/ancestor-or-self::node()", "//c/@x/following-sibling::node()", "count(//c/@x/self::*)",
        "count(//c/@x/self::node())", "//c/@x/self::node()", "//b/preceding-sibling::*[1] | //b/following-sibling::*[1]",
        "string(//c/ancestor-or-self::*[2]/@id)", "/r/a[@id=3]/preceding::*[2]",
        "count(//c/@x/descendant-or-self::node())", "//c/@x/following::*[1]", "//c/@z/preceding::node()",
        "//c/@*/following::node()[1]", "count(//c/@x/following::node())", "//a[3]/preceding::node()[1]",
        "//a[3]/preceding::*[last()]", "(//a[3]/preceding::*)[last()]", "//a[2]/descendant::*[last()]",
        "//b[2]/ancestor-or-self::*[last()]", "//b[2]/ancestor-or-self::*[1]", "//c/parent::*/parent::*/@id",
        "//c/../../@id", "//a[2]/b[1]/following-sibling::*[1]/@id", "//a[.//c]/@id", "//a[not(*)]/@id",
        "//*[@id = 'c1']/ancestor::*[2]/following-sibling::*/@id", "//*[@id][3]", "(//*[@id])[3]",
        "count(//*/@*)", "string(id('b1 c1  b2 b1')[last()]/@id)", "count(id('b1 c1  b2 b1'))",
        "count(id(//@id))", "id('nope')", "count(id(' '))", "string(//a[last()]/@id)",
        "//a[position()=last()-1]/@id", "//a[2][@id=2]/@id", "//a[@id>1][2]/@id", "//*[2]", "//a[0]",
        "//a[1.5]", "//a[true()]", "//a['']", "//a[0 div 0]", "//a[-1]", "//a[last() + 1]",
        "//a[position() = 2 or position() = 4]/@id", "//a[@id = (1, 2)]", "count(//a[position()])",
        "//a[1]/following::a[1]/@id", "count(//c/following::*/preceding::*)", "count(//node())",
        "count(/descendant-or-self::node())", "count(//c/ancestor::node())", "count(/self::node())",
        "count(/parent::node())", "count(/ancestor::node())", "count(/..)", "count(/following::node())",
        "count(/preceding::node())", "count(/attribute::node())", "count(/namespace::node())",
    ]),
    # ---- node-set comparisons, conversions
    ('<r><a>1</a><a>2</a><b>2</b><b>3</b><c/><s> 5 </s><n>abc</n><e></e></r>', [], [
        "//a = //b", "//a != //b", "//a < //b", "//a > //b", "//a = 2", "//a != 2", "2 != //a",
        "//a = '2'", "'2' = //a", "//a = true()", "//zz = false()", "//zz != true()", "//zz = //zz",
        "//zz != //zz", "//c = ''", "//c != ''", "//zz = ''", "//a < 3", "3 > //a", "//a >= '2'",
        "//n = 'abc'", "//n < 1", "//n > 1", "//n != 1", "//s = 5", "//s = ' 5 '", "true() = 1",
        "true() = 2", "false() = ''", "'' = 0", "'abc' = 0", "1 = '1.0'", "'1' = '1.0'", "0 = -0",
        "0 div 0 = 0 div 0", "0 div 0 != 0 div 0", "//a = //a", "//e = //c", "//a < true()",
        "//zz < true()", "//zz >= false()", "true() > false()", "'b' > 'a'", "'2' > '10'",
        "1 div 0 > 1e308", "1 div 0 = 2 div 0", "-1 div 0 < 1 div 0", "//a + //b", "//a * 2",
        "//zz + 1", "-//a", "count(//a) = 2.0", "sum(//a | //b)", "sum(//*)", "sum(//zz)", "sum(//s)",
        "boolean(//zz)", "boolean(//c)", "boolean('0')", "boolean('false')", "boolean(0 div 0)",
        "boolean(-0)", "boolean(' ')", "not(//zz)", "string(//a)", "number(//a)", "number(//zz)",
        "string(//zz)", "string(true())", "string(1 = 1)", "number('  -.5  ')", "number(//s)",
    ]),
    # ---- numbers, arithmetic, number<->string
    ('<r/>', [], [
        "string(1000000000000000000000)", "string(100000000000000000000)", "string(0.0000001)",
        "string(0.000001)", "string(1 div 3)", "string(-0)", "string(0 * -1)", "string(-0.0)",
        "string(1152921504606846976)", "string(123456789012345680000)", "string(9007199254740993)",
        "string(0.1 + 0.2)", "string(1 div 0)", "string(-1 div 0)", "string(0 div 0)", "string(12345.678)",
        "string(0.00000000000000000000001)", "string(-1 div 3)", "string(2 div 3 * 3)", "string(1.5)",
        "string(-1.5)", "string(100)", "string(-100)", "string(1e0)", "string(10 div 4)",
        "100000000000000000000 mod 3", "5.5 mod 2", "-5 mod 3", "5 mod -3", "-5 mod -3", "5 mod 0",
        "0 mod 5", "-0 mod 5", "5 mod (1 div 0)", "(1 div 0) mod 5", "5.5 mod 1.1", "1e300 mod 7",
        "9007199254740993 mod 2", "123456789012345678 mod 10", "0.3 mod 0.1", "-0.5 mod 1",
        "round(-0.5)", "round(-1.5)", "round(2.5)", "round(-2.5)", "round(0.5)", "round(-0.4)",
        "round(1 div 0)", "round(0 div 0)", "round(100000000000000000000)", "round(-100000000000000000000)",
        "round(0.49999999999999994)", "round(-0.49999999999999994)", "round(4503599627370495.5)",
        "round(-4503599627370495.5)", "round(4503599627370497)", "round(1.7976931348623157e308)",
        "floor(-1.5)", "floor(-0.5)", "floor(0.5)", "floor(-0)", "floor(1 div 0)", "floor(0 div 0)",
        "floor(100000000000000000000.5)", "ceiling(-0.5)", "ceiling(0.5)", "ceiling(-1.5)", "ceiling(-0)",
        "ceiling(-1 div 0)", "ceiling(100000000000000000000)", "1 div 0", "-1 div 0", "0 div 0", "1 div -0",
        "-0", "- 0", "0 - 0", "-(0)", "1 - 1", "0 * -1", "2 * 3 + 4 div 2 - 1 mod 3", "7 div 2",
        "0.1 * 3", "0.49999999999999994", "123456.7890123456789", "3.141592653589793238462643383279",
        "17976931348623157", "4.9e-324", "0." + "0" * 323 + "5", "1" + "0" * 400,
        "0." + "1" * 330, "number('0." + "1" * 330 + "')", "number('" + "9" * 330 + "')",
        "number('1" + "0" * 22 + "')", "string(number('1" + "0" * 22 + "'))",
    ]),
    # ---- string functions
    ('<r xml:lang="en-US"><a xml:lang="EN">x</a><b xml:lang="">y</b><c>z</c><e>\U0001F600abé</e>'
     '<f lang="fr">w</f><g xml:lang="en-"/><h xml:lang="EN-us-x"/><s>  a \t\n b  c  </s></r>', [], [
        "substring('12345', 1.5, 2.6)", "substring('12345', 0, 3)", "substring('12345', 0 div 0, 3)",
        "substring('12345', 1, 0 div 0)", "substring('12345', -42, 1 div 0)",
        "substring('12345', -1 div 0, 1 div 0)", "substring('12345', 2)", "substring('12345', 1 div 0)",
        "substring('12345', -5, 7)", "substring('12345', 2, -1 div 0)", "substring('12345', 1.5)",
        "substring('12345', 0.5, 1.5)", "substring('12345', -0.5, 2)", "substring('12345', 2.5, 0.5)",
        "substring('12345', 5, 1 div 0)", "substring('12345', 6)", "substring('', 1)", "substring('12345')",
        "substring('12345', 1, 2, 3)", "substring(/r/e, 1, 1)", "substring(/r/e, 2)", "substring(/r/e, 4)",
        "string-length(/r/e)", "string-length('')", "string-length()", "string-length(/r/s)",
        "translate('bar','abc','ABC')", "translate('--aaa--','abc-','ABC')", "translate('aab','aa','xy')",
        "translate(/r/e, '\U0001F600é', 'eE')", "translate('abc', '', 'x')", "translate('abc', 'abc', '')",
        "translate('a', 'a', 'bcd')", "normalize-space('  a  b  ')", "normalize-space(/r/s)",
        "string-length(normalize-space(/r/s))", "normalize-space('')", "normalize-space(' ')",
        "count(//*[lang('en')])", "count(//*[lang('en-us')])", "count(//*[lang('e')])", "//c[lang('EN')]",
        "//b[lang('en')]", "count(//f[lang('fr')])", "count(//g[lang('en')])", "count(//h[lang('en-US')])",
        "count(//h[lang('en-us-x')])", "count(//h[lang('en-')])", "lang('en')", "count(//@*[lang('en')])",
        "count(//text()[lang('en')])", "substring-before('1999/04/01','/')", "substring-after('1999/04/01','/')",
        "substring-after('abc','')", "substring-before('abc','')", "substring-before('abc','c')",
        "substring-after('abc','c')", "substring-after('abcbc','b')", "starts-with('abc','')",
        "starts-with('', 'a')", "contains('','')", "contains('abc', 'bc')", "contains(/r/e, 'bé')",
        "concat('a', 1, true())", "concat('a')", "concat()", "concat('a', 'b', 'c', 'd', 'e')",
        "concat(1 div 0, 0 div 0, -0)", "string()", "string(/r/a, 1)", "count()", "count(1)",
        "sum(1)", "not()", "true(1)", "last(1)", "position(1)", "floor()", "round(1, 2)",
        "boolean()", "number(1, 2)", "unknown()", "p:f()", "id()", "lang()", "name(/r, /r)",
        "string(/r/e)", "count(/r/e/text())",
    ]),
]


def cross_product():
    qs = []
    for o in ORIGINS:
        for ax in AXES:
            for t in TESTS:
                if t in ("bk", "xml") and ax != "namespace":
                    continue
                for p in PREDS:
                    if p and t in ("processing-instruction('note')", "id", "bk", "xml", "d:title"):
                        continue
                    base = "%s/%s::%s%s" % ("" if o == "/" else o, ax, t, p)
                    if o == "/":
                        base = "/" + base.lstrip("/")
                    qs.append(base)
        qs.append("count(%s/following::node() | %s/preceding::node() | %s/ancestor-or-self::node() | "
                  "%s/descendant::node())" % (o, o, o, o))
    return qs


NUM_RE = re.compile(r"^[ \t\r\n]*-?([0-9]+(\.[0-9]*)?|\.[0-9]+)[ \t\r\n]*$")


def xp_number(s):
    """W3C XPath 1.0 string -> number, correctly rounded (Python float() is)."""
    return float(s) if NUM_RE.match(s) else float("nan")


def xp_string(x):
    """W3C XPath 1.0 section 4.2 number -> string: no exponent, shortest round-trip digits."""
    if x != x:
        return "NaN"
    if x == 0:
        return "0"
    if math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    if x == int(x):
        return str(int(x))
    return format(Decimal(repr(x)), "f")


def xp_round(x):
    if x != x or math.isinf(x) or x == 0:
        return x
    if -0.5 <= x < 0:
        return -0.0
    r = float(math.floor(x))
    return r + 1.0 if x - r >= 0.5 else r


def num(x):
    if x != x:
        return "NUM NaN"
    return "NUM %016x" % struct.unpack(">Q", struct.pack(">d", x))[0]


def strnum(x):
    """Any section-4.2 spelling of x is accepted (shortest digits, no exponent; ties either way)."""
    if x != x or math.isinf(x) or x == 0 or x == int(x):
        return "STR " + xp_string(x)
    return "STRNUM %016x %s" % (struct.unpack(">Q", struct.pack(">d", x))[0], xp_string(x))


def spec_eval(q):
    """Expected result for the generated number-fuzz forms (None = not a generated form)."""
    m = re.fullmatch(r"number\('([^']*)'\)", q)
    if m:
        return num(xp_number(m.group(1)))
    if NUM_RE.match(q):
        return num(xp_number(q))
    m = re.fullmatch(r"string\((-?[0-9.]+)\)", q)
    if m:
        return strnum(xp_number(m.group(1)))
    m = re.fullmatch(r"round\((-?[0-9.]+)\)", q)
    if m:
        return num(xp_round(xp_number(m.group(1))))
    m = re.fullmatch(r"floor\((-?[0-9.]+)\) \+ ceiling\((-?[0-9.]+)\)", q)
    if m:
        x = xp_number(m.group(1))
        if x == 0:
            return num(x + x)
        return num(float(math.floor(x)) + (float(math.ceil(x)) if not -1 < x < 0 else -0.0))
    m = re.fullmatch(r"(-?[0-9.]+) mod (-?[0-9.]+)", q)
    if m:
        a, b = xp_number(m.group(1)), xp_number(m.group(2))
        return num(math.fmod(a, b) if b != 0 and not math.isinf(a) else float("nan"))
    m = re.fullmatch(r"string\((-?[0-9.]+) div ([0-9.]+)\)", q)
    if m:
        return strnum(xp_number(m.group(1)) / xp_number(m.group(2)))
    return None


def number_fuzz(rng):
    qs = []
    for _ in range(600):
        k = rng.randrange(6)
        if k == 0:
            s = str(rng.randrange(0, 10 ** rng.randrange(1, 25)))
        elif k == 1:
            s = "%d.%0*d" % (rng.randrange(0, 10 ** rng.randrange(0, 12)), rng.randrange(1, 22),
                             rng.randrange(0, 10 ** 15))
        elif k == 2:
            s = "0." + "".join(rng.choice("0123456789") for _ in range(rng.randrange(1, 40)))
        elif k == 3:
            s = repr(rng.uniform(-1e6, 1e6))
        elif k == 4:
            s = repr(rng.random() * 10 ** rng.randrange(-12, 22))
            if "e" in s:
                s = "%.20f" % float(s)
        else:
            s = "%.17g" % rng.uniform(0, 1)
            if "e" in s:
                continue
        qs.append("number('%s')" % s)
        qs.append(s.lstrip("-") if not s.startswith("-") else "-" + s[1:])
    for _ in range(300):
        a = rng.choice([rng.uniform(-1e3, 1e3), rng.randrange(-10 ** 6, 10 ** 6) / 8.0,
                        rng.uniform(-1, 1) * 10 ** rng.randrange(-8, 25)])
        lit = ("%.17f" % a).rstrip("0").rstrip(".") if abs(a) < 1e17 else "%d" % int(a)
        if lit in ("", "-"):
            lit = "0"
        qs.append("string(%s)" % lit)
        qs.append("round(%s)" % lit)
        qs.append("floor(%s) + ceiling(%s)" % (lit, lit))
        qs.append("%s mod %s" % (lit, rng.choice(["3", "7.5", "0.1", "-2", "1000000"])))
        qs.append("string(%s div %s)" % (lit, rng.choice(["3", "7", "1000", "0.001", "1024"])))
    return qs


def main():
    rng = random.Random(SEED)
    groups = [{"xml": x, "ns": ns, "vars": [], "q": q} for x, ns, q in HAND]
    groups.append({"xml": RICH, "ns": RICH_NS, "vars": [], "q": cross_product()})
    fz = number_fuzz(rng)
    groups.append({"xml": "<r/>", "ns": [], "vars": [], "q": fz, "spec": [spec_eval(q) for q in fz]})
    groups.append({"xml": "<r><a>1</a><a>2</a></r>", "ns": [], "vars": [["s", "s", "hello"], ["n", "n", "2.5"]],
                   "q": ["$s", "$n", "$n * 2", "concat($s, $n)", "//a[$n > .]", "$nope", "$s/a", "$s[1]",
                         "string-length($s)", "$ s"]})
    json.dump(groups, open(sys.argv[1], "w"), ensure_ascii=False)
    print("groups=%d queries=%d" % (len(groups), sum(len(g["q"]) for g in groups)))


if __name__ == "__main__":
    main()
