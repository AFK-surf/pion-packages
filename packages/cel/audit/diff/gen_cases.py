#!/usr/bin/env python3
"""Case generator for the packages/cel differential audit.

  gen_cases.py curated          -> hand-picked red-team expressions (each in E and C mode)
  gen_cases.py fuzz SEED N      -> N random well-formed expressions (E and C mode)

Line format: <mode>\t<hex(expr)>\t<tag>   (mode E = parse+eval, C = parse+check+eval)
"""
import random
import sys

CURATED = {
    "logic_absorb": [
        "true || (1/0 == 0)", "(1/0 == 0) || true", "false && (1/0 == 0)", "(1/0 == 0) && false",
        "(1/0 == 0) || false", "(1/0 == 0) && true", "false || (1/0 == 0)", "true && (1/0 == 0)",
        "[1, 0, 2].exists(x, 10/x == 5)", "[0, 1].all(x, x > 0 && 10/x > 0)", "[0, 1].all(x, 10/x > 0)",
        "[1, 0].all(x, 10/x > 5)", "[0, 5].exists(x, 10/x == 2)", "[0, 2].exists_one(x, 10/x == 5)",
        "[1, 0].exists_one(x, 10/x == 10)", "dyn('a') || true", "true || dyn('a')", "dyn(1) && false",
        "false && dyn(1)", "dyn('x') || dyn('y')", "(1/0 == 0) ? 1 : 2", "[1,0].map(x, 10/x)",
        "[1,0].filter(x, 10/x > 0)", "{'a': 1/0}.size()", "[1/0].size() == 1 || true",
    ],
    "int_overflow": [
        "-9223372036854775808", "-9223372036854775808 / -1", "-9223372036854775808 % -1",
        "-(-9223372036854775808)", "9223372036854775807 + 1", "-9223372036854775808 - 1",
        "9223372036854775807 * 2", "-9223372036854775808 * -1", "-1 * -9223372036854775808",
        "18446744073709551615u + 1u", "0u - 1u", "18446744073709551615u * 2u", "5 / 0", "5 % 0",
        "5u / 0u", "5u % 0u", "-7 / 2", "-7 % 2", "7 % -2", "9223372036854775808", "18446744073709551616u",
        "0x7fffffffffffffff", "0x8000000000000000", "-0x8000000000000000", "0xffffffffffffffffu",
        "--1", "---1", "-(-1)", "!!true", "!!!false", "- -9223372036854775807", "-9223372036854775807 - 1",
        "int(-9223372036854775808.0)", "int(9223372036854775807.0)", "int(9223372036854775808.0)",
        "int(-9223372036854775809.0)", "int(1e19)", "int(-1e19)", "int(0.0/0.0)", "int(1.0/0.0)",
        "int(-1.0/0.0)", "int(1.9)", "int(-1.9)", "uint(-1.0)", "uint(-0.5)", "uint(1e20)",
        "uint(18446744073709551615.0)", "uint(18446744073709549568.0)", "uint(0.0/0.0)", "uint(-1)",
        "int(18446744073709551615u)", "int(9223372036854775807u)", "uint('18446744073709551616')",
        "int('9223372036854775808')", "int('-9223372036854775808')", "int('+5')", "int(' 5')",
        "uint('+5')", "uint('-0')", "int('0x10')", "int('1e3')", "int('')", "int('-')",
    ],
    "numeric_cross": [
        "1 == 1u", "1 == 1.0", "1u == 1.0", "-1 < 0u", "-1 == 18446744073709551615u", "1u < 2",
        "dyn(1) == dyn(1u)", "dyn(1) == dyn(1.0)", "dyn(1u) == dyn(1.0)", "dyn(-1) < dyn(0u)",
        "dyn(9007199254740993) == dyn(9007199254740992.0)", "dyn(9007199254740993) > dyn(9007199254740992.0)",
        "dyn(9223372036854775807) == dyn(9223372036854775808.0)",
        "dyn(9223372036854775807) < dyn(9223372036854775808.0)",
        "dyn(18446744073709551615u) == dyn(18446744073709551616.0)",
        "dyn(18446744073709551615u) < dyn(18446744073709551616.0)", "dyn(1) < dyn(1.5)", "dyn(2) > dyn(1.5)",
        "dyn(-2) < dyn(-1.5)", "dyn(1u) < dyn(-1.5)", "dyn(1) == dyn(0.0/0.0)", "dyn(1) < dyn(0.0/0.0)",
        "dyn(1) > dyn(0.0/0.0)", "dyn(1u) >= dyn(0.0/0.0)", "0.0/0.0 == 0.0/0.0", "0.0/0.0 != 0.0/0.0",
        "0.0/0.0 < 1.0", "0.0/0.0 >= 1.0", "1.0/0.0 > 1.7976931348623157e308", "-0.0 == 0.0",
        "[1] == [1u]", "[1] == [1.0]", "[[1]] == [[1u]]", "{1: 'a'} == {1u: 'a'}", "{1: 'a'}[1u]",
        "{1: 'a'}[1.0]", "{1u: 'a'}[1]", "{1: 'a'}[1.5]", "1u in [1, 2]", "1.0 in [1, 2]",
        "2 in {2u: true}", "2.0 in {2: true}", "dyn(1) == dyn('1')", "dyn(1) != dyn('1')",
        "dyn(null) == dyn(0)", "dyn([]) == dyn({})", "dyn(true) == dyn(1)", "[1, 'a'] == [1, 'a']",
        "dyn([1, 2]) == dyn([1, 'a'])", "{'a': 1} == {'a': 1u}", "1 == 'a'", "1 != 'a'", "null == null",
        "[1,2][1u]", "[1,2][1.0]", "[1,2][-1]", "[1,2][2]", "[1,2][18446744073709551615u]",
        "1 < 1u", "1.5 > 1", "1u <= 1.0",
    ],
    "doubles": [
        "0.1 + 0.2", "0.3", "1e23", "100000000000000000000000.0", "1.7976931348623157e308",
        "1.7976931348623159e308", "2.2250738585072014e-308", "4.9e-324", "5e-324", "2e-324",
        "1e-400", "1e400", "123456789012345678901234567890.0", "0.1e1", ".5", "1e5", "1E5", "1e+5",
        "9007199254740993.0", "9007199254740995.0", "0.30000000000000004", "3.141592653589793238462643",
        "double('0.1')", "double('1e23')", "double('2.2250738585072014e-308')", "double('4.9e-324')",
        "double('9007199254740993')", "double('NaN')", "double('nan')", "double('inf')", "double('-Inf')",
        "double('Infinity')", "double('infinity')", "double('INF')", "double('1_000')", "double('0x10')",
        "double('0x1p-2')", "double(' 1')", "double('1.')", "double('.')", "double('')", "double('e5')",
        "double('1e')", "double(9223372036854775807)", "double(18446744073709551615u)",
        "string(1.0)", "string(0.1)", "string(1e100)", "string(1e21)", "string(1e20)", "string(-0.0)",
        "string(123456789.0)", "string(1.5e-7)", "string(0.000001)", "string(1.0/0.0)", "string(0.0/0.0)",
        "string(-1.0/0.0)", "string(100.0)", "string(1e6)", "string(1.0e15)", "string(2.5)",
        "1.0 % 2.0", "1.0 / 0.0", "-1.0 / 0.0", "0.0 / 0.0 == 0.0 / 0.0",
    ],
    "strings_lex": [
        "'''a'b''c'''", '"""a"b""c"""', "'\\U0001F600'", "'\\uD800'", "'\\uDFFF'", "'\\U00110000'",
        "'\\377'", "'\\400'", "'\\x80'", "b'\\x80'", "b'\\377'", "b'\\u0041'", "b'ÿ'", "b'😀'", "'😀'.size()",
        "b'😀'.size()", "'a\nb'", "'''a\nb'''", "r'\\n'", "R'\\n'", "rb'\\x80'", "br'\\x80'", "'\\a\\b\\f\\n\\r\\t\\v'",
        "'\\''", '"\\""', "'\\?'", "'\\`'", "'\\q'", "'\\x4'", "'\\X41'", "'\\u004'", "'\\0'", "'\\08'",
        "'\\101'", "'abc' + 'def'", "'abc' < 'abd'", "'a' < 'B'", "'é' > 'z'", "'\\u00e9' == 'é'",
        "b'abc' < b'abd'", "b'\\xff' > b'\\x00'", "'' == ''", "size('')", "size(b'')",
        "'hello'.contains('ell')", "'hello'.startsWith('he')", "'hello'.endsWith('lo')",
        "'hello'.contains('')", "''.contains('')", "'abc'.matches('^a')", "matches('abc', 'c$')",
        "'abc'.matches('(')", "'aaa'.matches('a{2}')", "'\\u0663'.matches('^\\\\d$')",
        "'é'.matches('^\\\\w$')", "'\\u00a0'.matches('^\\\\s$')", "'&'.matches('^[a&&b]$')",
        "'a'.matches('^[a&&b]$')", "'é'.matches('^\\\\b')", "'ab'.matches('(?i)AB')", "'K'.matches('(?i)\\u212a')",
        "'x'.matches('\\\\pL')", "'a1'.matches('[[:alpha:]][[:digit:]]')", "'a'.matches('a{1001}')",
        "'a'.matches('(?P<n>a)')", "'a'.matches('(?<n>a)')", "'ab'.matches('a(?=b)')", "'aa'.matches('(a)\\\\1')",
        "'a~'.matches('[a~~b]')", "'-'.matches('[a--b]')", "'\\n'.matches('.')", "'\\n'.matches('(?s).')",
        "'abc'.matches('\\\\Aabc\\\\z')", "'x'.matches('\\\\Q')", "'a'.matches('\\\\p{Greek}')",
        "string(b'\\xff')", "string(b'abc')", "bytes('é')", "bytes('é').size()", "string(true)",
        "string(18446744073709551615u)", "string(-5)", "bool('true')", "bool('TRUE')", "bool('True')",
        "bool('tRue')", "bool('1')", "bool('t')", "bool('yes')", "bool('')",
    ],
    "reserved_parse": [
        "as", "break", "const", "continue", "else", "for", "function", "if", "import", "let", "loop",
        "package", "namespace", "return", "var", "void", "while", "in", "[1].map(let, let)",
        "true ? 1 : false ? 2 : 3", "false ? 1 : false ? 2 : 3", "true ? false ? 1 : 2 : 3",
        "-1.0 < 0.0", "-[1][0]", "-'a'.size()", "!true || true", "!(true || true)", "1 + 2 * 3",
        "(1 + 2) * 3", "10 - 2 - 3", "100 / 10 / 2", "7 % 4 % 2", "1 < 2 == true", "1 < 2 < 3",
        "1 == 1 == true", "[1,2,3,]", "{'a':1,}", "[,]", "f(1,)", "1 +", "(1", "1)", "", "  ",
        "// c\n1", "1 // c", "1.e5", "1e", "0x", "0xg", "1u2", "1.0u", "01", "007", "0b1", "1__0",
        "a.b.c", "has(x)", "has({'a':1}.a)", "has({'a':1}.b)", "has({'a':{'b':1}}.a.b)",
        "has({'a':{'b':1}}.c.b)", "has({'a':1}.a.b)", "has([1].a)", "has({'a':1}['a'])", "has(1)",
        "{'a':1}.a", "{'a':1}.b", "{1:1}.a", "[1,2].map(x, x + 1)", "[1,2].all(x, [3,4].all(x, x > 0))",
        "[1,2].map(x, [x].map(x, x * 10))", "[1,2].exists(x, x == 2) && [3].all(y, y == 3)",
        "{'a': 1, 'b': 2}.all(k, k.size() == 1)", "{'a': 1}.map(k, k)", "[1,2].map(x, x > 1, x * 2)",
        "[1,2,3].filter(x, x % 2 == 1)", "[1,2].all(1, true)", "[1,2].all(x.y, true)",
        "[1,2].exists_one(x, x > 0)", "[].all(x, x)", "[].exists(x, x)", "size([1,2,3])", "[1,2].size()",
        "{'a':1}.size()", "size({})", "size(1)", "type(1)", "type(1u)", "type(1.0)", "type('a')",
        "type(b'a')", "type(null)", "type([])", "type({})", "type(type(1))", "type(1) == int",
        "type(duration('1s'))", "type(timestamp('2020-01-01T00:00:00Z'))", "int", "dyn(1)", "dyn",
        "type(dyn(1))", "x", "foo(1)", "1.foo()", "'a'.foo()", "[1].contains(1)",
        "{'a':1, 'a':2}", "{1:'a', 1u:'b'}", "{1:'a', 1.0:'b'}", "{1.0: 'a'}", "{[1]: 'a'}", "{{}: 'a'}",
        "{b'a': 1}", "{null: 1}", "{true: 1, false: 2}[true]", "{dyn(1.5): 1}", "{'a': 1}['b']",
        "{} == {}", "[] == []", "[] + []", "[1] + [2]", "[1] + ['a']", "{'a': 1} + {'b': 2}",
        "1 + 1.0", "1 + 1u", "1.0 + 1u", "'a' + 1", "dyn(1) + 1.0", "dyn(1) + dyn(1u)", "1 < 'a'",
        "true < false", "false < true", "null < null", "[1] < [2]", "{1:1}[1] + 1", "{'a':1}['a'] + 'x'",
        "true ? 1 : 'a'", "[1, 'a']", "[1, 1u]", "{1: 1, 'a': 'a'}", "[1,2][0] + 'a'",
        "(true ? 1 : 2) + 1", "1 in 1", "1 in 'abc'", "'a' in {'a':1}", "[1,2] in [[1,2]]",
    ],
    "time": [
        "timestamp('0001-01-01T00:00:00Z')", "timestamp('9999-12-31T23:59:59.999999999Z')",
        "timestamp('0000-12-31T23:59:59Z')", "timestamp('10000-01-01T00:00:00Z')",
        "timestamp('9999-12-31T23:59:59Z') + duration('1s')", "timestamp('0001-01-01T00:00:00Z') - duration('1s')",
        "timestamp('9999-12-31T23:59:59Z') - timestamp('0001-01-01T00:00:00Z')",
        "timestamp('2020-01-01T00:00:00Z') - timestamp('1700-01-01T00:00:00Z')",
        "timestamp(253402300799)", "timestamp(253402300800)", "timestamp(-62135596800)",
        "timestamp(-62135596801)", "timestamp(0)", "int(timestamp('2020-01-01T00:00:00.9Z'))",
        "int(timestamp('1969-12-31T23:59:59.5Z'))", "timestamp('2020-01-01T00:00:00+05:30')",
        "timestamp('2020-01-01T00:00:00-08:00')", "timestamp('2020-01-01t00:00:00z')",
        "timestamp('2020-01-01 00:00:00Z')", "timestamp('2020-01-01T00:00:00')", "timestamp('2020-02-30T00:00:00Z')",
        "timestamp('2020-12-31T23:59:60Z')", "timestamp('2020-01-01T24:00:00Z')", "timestamp('2020-01-01T00:00:00+24:00')",
        "timestamp('2020-01-01T00:00:00.1234567891Z')", "timestamp('2020-01-01T00:00:00.Z')",
        "timestamp('2020-1-01T00:00:00Z')", "string(timestamp('2020-01-01T00:00:00.5Z'))",
        "string(timestamp('2020-01-01T00:00:00Z'))", "string(timestamp('2020-01-01T00:00:00.123Z'))",
        "string(timestamp('2020-01-01T08:00:00+08:00'))",
        "duration('1h30m')", "duration('1h30m-5s')", "duration('-1h30m')", "duration('1.5h')", "duration('1.5s')",
        "duration('0')", "duration('-0')", "duration('+0')", "duration('0s')", "duration('')", "duration('1')",
        "duration('1d')", "duration('1us')", "duration('1µs')", "duration('1μs')", "duration('1ns')", "duration('1.s')",
        "duration('.5s')", "duration('1.0000000001s')", "duration('2562047h')", "duration('2562048h')",
        "duration('2562047h47m16.854775807s')", "duration('2562047h47m16.854775808s')",
        "duration('-2562047h47m16.854775808s')", "duration('9223372036854775807ns')", "duration('9223372036854775808ns')",
        "duration('9223372036854775807s')", "duration('9223372036854775807s1000000000ns')",
        "duration('9223372036854775807.5s0.5s')", "duration('315576000000s')", "duration('315576000001s')",
        "duration('100000h')", "duration('1000000h')", "duration('3000000h')", "duration('1h1h')",
        "duration('1H')", "duration(' 1s')", "string(duration('1h30m'))", "string(duration('-1.5s'))",
        "string(duration('1ns'))", "string(duration('0s'))", "string(duration('-1ns'))",
        "duration('1h') + duration('1h')", "duration('2562047h') + duration('2562047h')", "-duration('1s')",
        "duration('1s') < duration('2s')", "duration('1h').getHours()", "duration('90m').getHours()",
        "duration('90m').getMinutes()", "duration('90s').getSeconds()", "duration('1.5s').getMilliseconds()",
        "duration('61.5s').getMilliseconds()", "duration('-1.5s').getMilliseconds()", "duration('-90m').getHours()",
        "timestamp('2020-03-01T00:00:00Z').getFullYear()", "timestamp('2020-03-01T00:00:00Z').getMonth()",
        "timestamp('2020-03-01T00:00:00Z').getDate()", "timestamp('2020-03-01T00:00:00Z').getDayOfMonth()",
        "timestamp('2020-03-01T00:00:00Z').getDayOfWeek()", "timestamp('2020-03-01T00:00:00Z').getDayOfYear()",
        "timestamp('2020-12-31T00:00:00Z').getDayOfYear()", "timestamp('2020-03-01T00:30:00Z').getHours('-08:00')",
        "timestamp('2020-03-01T00:30:00Z').getHours('+05:30')", "timestamp('2020-03-01T00:30:00Z').getMinutes('+05:30')",
        "timestamp('2020-03-01T00:30:00Z').getHours('America/New_York')", "timestamp('2020-07-01T00:30:00Z').getHours('America/New_York')",
        "timestamp('2020-03-01T00:30:00Z').getHours('Asia/Kolkata')", "timestamp('2020-03-01T00:30:00Z').getHours('UTC')",
        "timestamp('2020-03-01T00:30:00Z').getHours('05:30')", "timestamp('2020-03-01T00:30:00Z').getHours('+5:30')",
        "timestamp('2020-03-01T00:30:00Z').getHours('+0530')", "timestamp('2020-03-01T00:30:00Z').getHours('+24:00')",
        "timestamp('2020-03-01T00:30:00Z').getHours('nowhere')", "timestamp('2020-03-01T00:30:00Z').getFullYear('-08:00')",
        "timestamp('2020-01-01T00:00:00.123456789Z').getMilliseconds()", "timestamp('2020-01-01T00:00:59Z').getSeconds()",
        "timestamp('0001-01-01T00:00:00Z').getDayOfWeek()", "timestamp('9999-12-31T00:00:00Z').getDayOfWeek()",
        "timestamp('2020-01-01T00:00:00Z') < timestamp('2020-01-01T00:00:01Z')",
        "timestamp('2020-01-01T00:00:00Z') == timestamp('2020-01-01T05:30:00+05:30')",
        "timestamp('2020-01-01T00:00:00Z') + duration('-1ns')", "timestamp(timestamp('2020-01-01T00:00:00Z'))",
        "duration(duration('1s'))", "int(duration('1s'))", "timestamp(1.5)", "timestamp('2020-01-01T00:00:00Z') + 1",
    ],
}


def emit(expr, tag, out):
    h = expr.encode("utf-8").hex()
    for mode in ("E", "C"):
        out.append("%s\t%s\t%s" % (mode, h, tag))


def curated():
    out = []
    for tag, exprs in CURATED.items():
        for e in exprs:
            emit(e, tag, out)
    return out


# ---------------------------------------------------------------- fuzz
INTS = ["0", "1", "-1", "2", "7", "-7", "9223372036854775807", "-9223372036854775808", "4611686018427387904",
        "3037000500", "-3037000500", "0x7fffffffffffffff", "1000000007"]
UINTS = ["0u", "1u", "2u", "18446744073709551615u", "9223372036854775808u", "4294967296u", "7u"]
DBLS = ["0.0", "-0.0", "1.0", "-1.5", "0.1", "1e308", "-1e308", "1e-308", "5e-324", "2.5", "1e19",
        "9.223372036854776e18", "1.8446744073709552e19", "9007199254740993.0", "(0.0/0.0)", "(1.0/0.0)",
        "(-1.0/0.0)", "123.456e7", "0.3333333333333333"]
STRS = ["''", "'a'", "'abc'", "'é'", "'😀'", "'\\u0000'", "'A'", "'zz'"]


def g_num(r, d):
    k = r.random()
    if d <= 0 or k < 0.35:
        c = r.random()
        if c < 0.45:
            return r.choice(INTS)
        if c < 0.7:
            return r.choice(UINTS)
        if c < 0.95:
            return r.choice(DBLS)
        return "dyn(%s)" % r.choice(INTS + UINTS + DBLS)
    if k < 0.75:
        a, b = g_num(r, d - 1), g_num(r, d - 1)
        return "(%s %s %s)" % (a, r.choice(["+", "-", "*", "/", "%"]), b)
    if k < 0.85:
        return "-(%s)" % g_num(r, d - 1)
    f = r.choice(["int", "uint", "double", "dyn"])
    return "%s(%s)" % (f, g_num(r, d - 1))


def g_bool(r, d):
    k = r.random()
    if d <= 0 or k < 0.15:
        return r.choice(["true", "false", "(1/0 == 0)", "dyn('s') == 's'"])
    if k < 0.55:
        return "(%s %s %s)" % (g_num(r, d - 1), r.choice(["==", "!=", "<", "<=", ">", ">="]), g_num(r, d - 1))
    if k < 0.75:
        return "(%s %s %s)" % (g_bool(r, d - 1), r.choice(["&&", "||"]), g_bool(r, d - 1))
    if k < 0.8:
        return "!%s" % g_bool(r, d - 1)
    if k < 0.9:
        lst = ", ".join(g_num(r, 1) for _ in range(r.randint(0, 4)))
        m = r.choice(["all", "exists", "exists_one"])
        return "[%s].%s(x, %s)" % (lst, m, r.choice(["x > 0", "10 / x > 1", "x == x", "dyn(x) < 1u", "int(x) != 0"]))
    if k < 0.95:
        return "(%s %s %s)" % (r.choice(STRS), r.choice(["<", "==", ">="]), r.choice(STRS))
    return "(%s in [%s])" % (g_num(r, 1), ", ".join(g_num(r, 1) for _ in range(r.randint(0, 3))))


def g_str(r, d):
    k = r.random()
    if d <= 0 or k < 0.4:
        return r.choice(STRS)
    if k < 0.7:
        return "string(%s)" % g_num(r, d - 1)
    if k < 0.85:
        return "(%s + %s)" % (g_str(r, d - 1), g_str(r, d - 1))
    return "(%s ? %s : %s)" % (g_bool(r, d - 1), g_str(r, d - 1), g_str(r, d - 1))


def fuzz(seed, n):
    r = random.Random(seed)
    out = []
    for _ in range(n):
        k = r.random()
        if k < 0.45:
            e = g_num(r, r.randint(1, 4))
        elif k < 0.85:
            e = g_bool(r, r.randint(1, 4))
        else:
            e = g_str(r, r.randint(1, 3))
        emit(e, "fuzz", out)
    return out


if __name__ == "__main__":
    if sys.argv[1] == "curated":
        lines = curated()
    else:
        lines = fuzz(int(sys.argv[2]), int(sys.argv[3]))
    sys.stdout.write("\n".join(lines) + "\n")
