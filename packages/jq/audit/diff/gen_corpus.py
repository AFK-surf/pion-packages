#!/usr/bin/env python3
"""Deterministic red-team corpus generator for packages/jq.

usage: gen_corpus.py [--yaml gojq_suite.json] > corpus.json

Emits a JSON array of [query, input_json, tag]. Sources:
  * hand-written attack vectors per surface (lexer, streams, paths, builtins, regex, fmt, numbers)
  * builtin x input cross product over every builtin the package README claims
  * seeded grammar fuzzer (random well-typed-ish jq programs)
  * optional: gojq v0.12.17 cli/test.yaml single-query cases (extracted by `oracle yaml`),
    minus the 50k-element update-performance cases (those live in audit/dos).
"""
import json, random, sys

C = []


def add(tag, q, inp="null"):
    C.append([q, inp, tag])


# ---------------------------------------------------------------- inputs
INPUTS = [
    "null", "true", "false", "0", "-0", "1", "-1.5", "3.7", "1e300", "12345678901234567890",
    "\"\"", "\"abc\"", "\"a,b, c\"", "\"h\u00e9llo\U0001F600\"", "\"AbC xyZ\"",
    "[]", "[1,2,3]", "[3,1,2,1]", "[null,true,false,1,\"a\",[1],{\"a\":1}]",
    "[[1,2],[3,[4,[5]]]]", "[\"a,b\",\"c d\",\"e'f\"]", "[{\"a\":2,\"b\":1},{\"a\":1,\"b\":2},{\"a\":1,\"b\":1}]",
    "{}", "{\"a\":1,\"b\":[1,2]}", "{\"b\":2,\"a\":1}", "{\"a\":{\"b\":{\"c\":null}},\"d\":[{\"e\":1}]}",
]

# ---------------------------------------------------------------- builtin x input cross product
B0 = """length utf8bytelength keys keys_unsorted values type not add any all flatten floor ceil trunc fabs
sqrt tostring tonumber tojson ascii_downcase ascii_upcase explode reverse sort unique min max
to_entries from_entries [paths] [leaf_paths] [..] [arrays] [objects] [iterables] [booleans] [numbers]
[strings] [nulls] [scalars] @text @json @html @uri @csv @tsv @sh @base64 @base64d first last
isnan isinfinite isfinite isnormal combinations transpose [recurse] [.[]?] .[0]? .a? [.[]?|numbers]
isempty(.[]?) [splits(\",\")?] implode? fromjson? tojson|fromjson [limit(2;.[]?)] [first(.[]?)]""".split()
B1 = [
    'has("a")', "has(0)", 'contains("b")', "contains([1])", 'contains({"a":1})', "inside([1,2,3,4])",
    'inside({"a":1,"b":[1,2,3],"c":0})', "indices(1)", 'indices(",")', "indices([1,2])", 'index(",")',
    'rindex(",")', "index(1)", 'split(",")', 'join(",")', "join(\"-\")", "flatten(1)", "flatten(0)",
    "flatten(-1)", "sort_by(.a)", "sort_by(.a,.b)", "group_by(.a)", "unique_by(.a)", "min_by(.a)",
    "max_by(.b)", "map(.+1)", "map_values(.+1)", "map(type)", "with_entries(.value|=tostring)",
    'test("a")', 'test("A";"i")', '[match("a";"g").offset]', 'capture("(?<x>[a-z]+)")', '[scan("[a-z]")]',
    'sub("a";"X")', 'gsub("[aeiou]";"_")', 'gsub("";"-")', 'startswith("a")', 'endswith("c")',
    'ltrimstr("a")', 'rtrimstr("c")', "nth(1)", "[range(.)]?", "[range(0;.;2)]?", "getpath([\"a\",\"b\"])",
    'setpath(["a"];1)', "setpath([0];1)", 'delpaths([["a"],[0]])', "del(.a)", "del(.[0])", "del(.[1:])",
    "to_entries|from_entries", "[paths(type==\"number\")]", "any(.>1)", "all(.>1)", "[.[]?|tostring]",
    "tostring|length", ". as [$a,$b] | [$b,$a]", ". as {a:$x} | $x", "[.[]?] | sort", "unique|length",
    "[.. | numbers] | add", "path(..)", "[path(..)]", "[paths]|length", "tojson|length", "@json \"v=\\(.)\"",
    "@html \"<\\(.)>\"", "@uri \"q=\\(.)\"", "[.[]?|@base64]", "add?", "(.. | numbers) |= .+1",
    "(.. | strings) |= ascii_upcase", ".[]? |= empty", "to_entries", "[to_entries[]|.key]",
    "getpath([0,0])", "[getpath([\"a\"],[\"b\"])]", "try error catch .", "try error(\"x\") catch .",
    "[.[]?|select(type==\"number\")]", "first(range(10;0;-3))", "[limit(3;repeat(1))]",
]
for f in B0:
    for inp in INPUTS:
        add("builtin0", f, inp)
for f in B1:
    for inp in INPUTS:
        add("builtin1", f, inp)

# ---------------------------------------------------------------- lexer / syntax
for q in [
    "# only comment\n.", ". # trailing", "1 # c\n+ 2", "\"\\u00e9\\u4e2d\\ud83d\\ude00\"", "\"\\ud83d\"", "\"\\ude00\"",
    "\"\\ud83d\\u0041\"", "\"\\/\\b\\f\\n\\r\\t\"", "\"\\(1+2)\\(\"x\")\"", "\"a\\(\"b\\(\"c\")\")\"", "@base64 \"\\(.)!\"",
    "1.0", "1.5e3", "1E-2", ".5", "5.", "0x10", "1e1000", "-1e1000", "100000000000000000000", "-0", "[-0]", "-(0)",
    "0.1+0.2", "1/3", "3.0", "1.000", "[1e17,1e16,123456789012345678]", "9007199254740993", "[9007199254740993]",
    "13911860366432393", "-9007199254740993", "1.7976931348623157e308", "5e-324", "2.2250738585072014e-308",
    ".foo.bar", ".[\"foo\"]", ".foo[\"bar\"]", ".\"foo\".bar", ".foo?.bar?", ".[]?.a", "..|numbers", ".. == .",
    "$__loc__", "{a:1} | .a as $a | $a", "{$__loc__}", "{\"a\":1,\"b\":2} | {a,b}", "{(\"a\",\"b\"):1}",
    "{a:(1,2),b:(3,4)}", "{\"x\":1} as {x:$v} | $v", "[.[]?] as [$a] | $a", ". as [$a,[$b]] | $b",
    "1 as $x | 2 as $y | [$x,$y,$__loc__.line]", "if true then 1 end", "if . then 1 elif . == null then 2 else 3 end",
    "if (true,false) then 1 else 2 end", "if empty then 1 else 2 end", "[.[]?] | if length > 0 then .[0] else null end",
    "reduce range(5) as $i (0; . + $i)", "reduce empty as $i (0; . + 1)", "reduce range(3) as $i (0; empty)",
    "foreach range(5) as $i (0; . + $i)", "foreach range(5) as $i (0; . + $i; [$i, .])",
    "[foreach range(5) as $i (0; if $i == 2 then empty else . + $i end)]",
    "[foreach (1,2) as $x ((10,20); . + $x)]", "[reduce (1,2) as $x ((10,20); . + $x)]",
    "reduce range(3) as $x (0; ., 10)", "[limit(3; foreach range(10) as $x (0; .+$x))]",
    "def f: 1; def f(x): 2; [f, f(.)]", "def f(x): x * 2; f(3)", "def f($a; $b): $a + $b; f(1;2)",
    "def f(g): [g, g]; f(1,2)", "def f: def g: 3; g * 2; f", "def f(x): x | x; 2 | f(. * 3)",
    "def x: 1; def y: x; def x: 2; y", "def f($x): $x | . + 1; [f(1,2)]", "def fac: if . <= 1 then 1 else . * (. - 1 | fac) end; [range(8) | fac]",
    "def rec(f): def r: ., (f | r); r; [3 | rec(if . > 0 then . - 1 else empty end)]",
    "1 as $x | def f: $x; 2 as $x | f", "def f(a; b): a + b; f(1; 2)",
    "label $f | 1, break $f, 2", "[label $f | range(10) | ., (select(. == 3) | break $f)]",
    "[label $a | label $b | 1, break $b, 2], 3", "label $a | [label $b | 1, break $a, 2]",
    "[range(5) | label $x | if . > 2 then break $x else . end]",
    "first(range(10;0;-1))", "[limit(0; 1,2)]", "[limit(1; 1, error(\"x\"))]", "[first(empty)]",
    "[.[]?] | first", "try error(\"x\") catch .", "try error({a:1}) catch .a", "[.[]? | try error catch .]",
    "try (1, error(\"x\"), 3) catch .", "[(1,2) | try (if . == 1 then error(\"e\") else . end) catch \"c\"]",
    "[.a?, .b?]", "[1?, (error(\"x\"))?]", "(error(\"x\"))? // 5", "try error(null) catch .", "error(null)?",
    "[.[] | (1 / .)?]", "try (1/0) catch .", "1 / 0", "0 / 0", "[1 % 0]?", "5 % 3, -5 % 3, 5 % -3, 5.5 % 2",
    "-1 % 5", "[1,2] - [2]", "{a:1} + {b:2}", "{a:{b:1}} * {a:{c:2}}", "null + 1", "1 + null", "\"a\" + \"b\"",
    "[1] + null", "{} + null", "null - 1", "\"abc\" / \"b\"", "\"a\" * 0", "\"a\" * -1", "\"a\" * 0.5",
    "\"ab\" * 2.7", "{a:1} * {a:{b:2}}", "[] - []", "\"x\" - \"y\"", "{} - {}", "4 - .5", "[1,[2]] | . == [1,[2]]",
    "1 == 1.0", "[1,2] < [1,3]", "{} < []", "{a:1} < {b:0}", "{a:2} < {a:1,b:0}", "[null, false, true, 0, \"\", [], {}] | sort",
    "[{b:1},{a:2},{a:1,b:0},{a:1}] | sort", "[\"b\",\"a\",\"B\",\"\u00e9\",\"e\"] | sort", "[[2],[1,2],[1],[]] | sort",
    "nan < nan, nan == nan, nan > nan, [nan] == [nan], nan < 1", "[nan, 1, null] | sort", "[nan] | sort | .[0] | isnan",
    "infinite, -infinite, nan | tostring", "[infinite, -infinite] | tojson", "[nan] | tojson", "nan | tojson",
    "[1,nan] | min, max", "[.[]?] | add", "true and (true, false)", "(true, false) and true", "(true,false) or (true,false)",
    "false and error(\"x\")", "true or error(\"x\")", "null // 1", "false // 1", "empty // 1", "(false, null, 1) // 2",
    "(false, null) // (3, 4)", "[.[]? // \"d\"]", "1 // error(\"x\")", "[(null, 2, false, 3) // 9]",
    "[[1,2],[3]] | .[] as [$a, $b] | {a: $a, b: $b}", ". as [$a] ?// $a | $a", "[[1,2]] | .[] as [$a] ?// $a | $a",
    "{\"a\":[1,{\"b\":2}]} | . as {a:[$x, {b:$y}]} | [$x,$y]", "{\"k\":\"a\",\"a\":5} | . as {k:$k} | .[$k]",
    ". as {$a, b:[$c]} | [$a,$c]", "{\"a\":1} as {(\"a\",\"b\"):$v} | $v", "[1,2,3] | .[1:]", "[1,2,3] | .[:-1]",
    "[1,2,3] | .[-2:]", "\"abcdef\" | .[2:4]", "\"abc\" | .[5:]", "[1,2,3] | .[1.5:2.7]", "[1,2,3] | .[null:2]",
    "[1,2,3][1]", "[1,2,3][-1]", "[1,2,3][-4]", "[1,2,3][1.7]", "[1,2,3][nan]", "{\"a\":1}[\"a\"]", "null[0]",
    "null[\"a\"]", "null[1:2]", "[1,2,3] | .[[2]]", "[1,2,1] | .[[1]]", ".a.b.c", "[.[]?.a?]", ".[\"a\",\"b\"]?",
    "[\"\\(1,2)-\\(3,4)\"]", "\"\\([1,{a:\"x\"}])\"", "@csv \"\\([1,\"a\"])\"", "@sh \"echo \\(\"it's\")\"",
    "@json \"\\(\"q\\\"\")\"", "@text \"\\([1])\"", "[.[]?] | @json", "@base64d \"\\(\"YWJj\")\"",
    "\"x\" as $x | \"a\\($x)b\"", "[limit(5; repeat(.*2; . < 100))]?", "[range(0;10;3)]", "[range(10;0;-3)]",
    "[range(0;1;0.3)]", "[range(1;0)]", "[range(0; 3; 0)] | length", "[range(-3)]", "[range(2.5)]",
    "[range(1,2;3,4)]", "range(3) as $x | $x * 2", "[.[]?] | length as $n | $n", "input_line_number",
    "[splits(\"a\")]", "ascii", "@base32", "@base32d", "ltrimstr(1)", "tostream", "fromstream(tostream)",
    "[1,[2]] | tostream", "walk(if type == \"number\" then . + 1 else . end)", "env | type", "$ENV | type",
    "builtins | length > 10", "getpath([\"a\",0,\"b\"])", "pick(.a)", "debug", "stderr", "input", "splits(\", \")",
    "[1,2] | IN(1)", "IN(1,2; 2,3)", "INDEX(.a)", "[1,2] | until(length > 4; . + .)", "[while(. < 10; . + 3)]?",
    "[1,[2,[3]]] | getpath([1,1,0])", "limit(1; 1, 2)", "significand", "logb", "gamma", "frexp", "ldexp(1;2)",
    "pow(2;10)", "log", "exp10", "round", "toarray", "have_decnum", "abs", "trim", "ltrim", "@urid",
    "getpath([\"x\"]) = 1", "splits(1)", "test(\"a\"; \"gx\")", "tojson | fromjson", "now | type", "todate",
    "\"2015-03-05T23:51:47Z\" | fromdate", "1425599507 | todate", "mktime", "gmtime", "strftime(\"%Y\")",
    "[paths(..)]", "[leaf_paths]", "any", "all", "[[1,2],[3,4]] | transpose", "[[1],[2,3]] | transpose",
    "[1,2] | combinations", "[[1,2],[3,4]] | [combinations]", "[[1,2],[]] | [combinations]", "[combinations(2)]",
    "[1,2] | [combinations(2)]", "tojson | . == tojson", "getpath([])", "[paths] == [paths(true)]",
    "{} | .a.b.c = 1", "null | .[2] = 1", "[1] | .[-1] = 5", "[1] | .[-2] = 5", "null | .a[1].b = 1",
    "{} | .[\"x\"] |= 3", "{\"a\":[1,2,3]} | .a[1:] = [\"x\"]", "[1,2,3,4] | .[1:3] |= map(. * 10)",
    "[1,2,3,4] | .[1:3] = [\"a\"]", "[1,2,3] | .[5:] = [9]", "[1,2,3] | .[-1:] |= [0]",
    "[1,2,3] | (.[] | select(. > 1)) |= empty", "[1,2,3,4,5] | (.[] | select(. % 2 == 0)) |= empty",
    "{a:1,b:2} | (.a, .b) |= empty", "{a:1,b:2} | .[] |= empty", "[1,2,3] | .[] |= (., 10)",
    "[1,2,3] | .[0] = (10, 20)", "[1,2,3] | .[0] |= (10, 20)", "{a:1} | .a += (1,2)", "{a:1} | .a //= 3",
    "{a:null} | .a //= 3", "{a:false} | .a //= (3,4)", "{a:[1,2]} | .a[] += 10", "{a:1} | .b -= 1",
    "{a:2} | .a *= 3 | .a /= 2 | .a %= 2", "[1,2] | .[] *= 2", "{a:{b:1}} | .a.b |= . + 1",
    "{a:1} | .a = .a + 1", "{a:1,b:2} | .a = .b", "{a:1,b:2} | .a |= .b", "[[1]] | .[0][0] |= . + 1",
    "{a:[{b:1},{b:2}]} | .a[].b |= . * 10", "{a:[{b:1},{b:2}]} | (.a[] | select(.b == 2) | .b) = 0",
    "(..|numbers) |= . + 1", "[1,[2]] | (.. | arrays) |= length", "{a:1} | to_entries | map(.value += 1) | from_entries",
    "{} | .a += 1", "null | . += 1", "null | .[0] += 1", "[3] | .[0] -= 1", "{} | .a.b |= 3", "{} | .a[0] |= 3",
    "path(.a[0].b)", "[path(..)]", "path(.a | .b)", "[path(.a, .b)]", "path(.[1:2])", "[path(.[]?)]",
    "path(first(.a,.b))", "path(if .a then .b else .c end)", "path(.a // .b)", "path(1)", "path(. + 1)",
    "path(getpath([\"a\",\"b\"]))", "[paths(type == \"number\")]", "path(select(.a))", "path(empty)",
    "path(.a | select(. == null))", "[path(recurse)]", "path(.a?)", "path(..|select(type==\"null\"))",
    "try path(tojson) catch .", "path(.[\"a\"] | .[0])", "path(last(.a,.b))", "path(limit(1; .a,.b))",
    "path(reduce (\"a\",\"b\") as $k (.; .[$k]))", "path(foreach (\"a\",\"b\") as $k (.; .[$k]))",
    "path(def f: .a; f)", "path(.a as $x | .b)", "path(label $x | .a, break $x)", "path(try .a catch .b)",
    "path(.a[1:3][0])", "[path(.a[]?)]", "path(input)?", "path(getpath([\"a\"]) | getpath([\"b\"]))",
    "del(.a, .b)", "del(.[1, 0])", "[1,2,3,4] | del(.[0, 2])", "[1,2,3,4] | del(.[-1])", "[1,2,3] | del(.[5])",
    "{a:[1,2]} | del(.a[0])", "del(..)", "del(.)", "[1,2,3] | del(.[] | select(. == 2))", "[1,2,3] | del(.[1:])",
    "[1,2,3,4,5] | del(.[1:3], .[0])", "{a:1} | del(.b)", "null | del(.a)", "[[1,2]] | del(.[0][0])",
    "[1,2,3] | delpaths([[0],[1]])", "[1,2,3] | delpaths([[5]])", "{a:{b:1}} | delpaths([[\"a\",\"b\"],[\"a\"]])",
    "delpaths([[]])", "[1] | delpaths([[-1]])", "[1,2,3] | delpaths([[-5]])", "{a:1} | delpaths([[0]])",
    "[1,2] | setpath([-1]; 9)", "[1,2] | setpath([-3]; 9)", "null | setpath([2]; 1)", "null | setpath([\"a\",1]; 1)",
    "{} | setpath([]; 1)", "[1] | setpath([0,\"a\"]; 1)", "1 | setpath([\"a\"]; 1)", "[] | setpath([1.5]; 1)",
    "[1,2,3] | getpath([-1])", "[1,2,3] | getpath([9])", "1 | getpath([\"a\"])", "{a:1} | getpath([\"a\",\"b\"])",
    "null | getpath([1,\"a\"])", "[1,2,3] | to_entries", "{\"a\":1} | with_entries(.key |= ascii_upcase)",
    "[{\"name\":\"a\",\"value\":1},{\"k\":\"b\",\"v\":2},{\"key\":null,\"value\":3},{\"key\":false},{\"key\":1,\"value\":2}] | from_entries",
    "[[\"a\",1]] | from_entries", "{} | from_entries", "[1,2] | from_entries",
]:
    for inp in ["null", "{\"a\":{\"b\":1},\"b\":[1,2],\"c\":\"x\"}", "[1,[2,3],{\"a\":4}]"]:
        add("syntax_stream_path", q, inp)

# ---------------------------------------------------------------- strings / regex / fmt
STRS = ["\"\"", "\"abc\"", "\"aAbB\"", "\"a.b*c\"", "\"foo bar  baz\"", "\"\\u00e9t\\u00e9 \\ud83d\\ude00!\"",
        "\"line1\\nline2\\nline3\"", "\"aaaa\"", "\"<a href='x'>&\\\"</a>\"", "\"\\u0000\\u001f\\u007f\"",
        "\"a,b,,c,\"", "\"\\t tab\\r\\n\"", "\"\\ud800\"", "\"10.50\"", "\"+1\"", "\" 42 \""]
REGEX = [
    'test("")', 'test("^$")', 'test("b"; "x")', 'test("A"; "i")', 'test("a.c"; "s")', 'test("^line2"; "")',
    '[match("a"; "g") | .offset]', '[match(""; "g") | .offset]', '[match("(a)(x)?"; "g") | .captures | map(.string)]',
    '[match("(?<n>[a-z])"; "g") | .captures[0].name]', 'capture("(?<w>\\\\w+)")', '[capture("(?<w>\\\\w)"; "g")]',
    '[scan("a+")]', '[scan("(a)(b)?")]', '[scan("")]', 'sub(""; "X")', 'gsub(""; "X")', 'gsub("a*"; "-")',
    'gsub("(?<x>.)"; "\\(.x)\\(.x)")', 'sub("(?<x>a)|(?<y>b)"; "[\\(.x)|\\(.y)]")', 'gsub("\\\\s+"; " ")',
    'gsub("A"; "x"; "i")', 'sub("a"; "1", "2")', 'gsub("a"; "1", "2")', '[splits(", *")]', 'split(", *"; null)',
    'split("a"; "g")', '[match("\\\\p{L}+"; "g").string]', '[match("."; "g").length]', '[match("\\ud83d\\ude00").offset]',
    'test("\\\\d")', 'test("[[:alpha:]]")', 'ascii_downcase', 'ascii_upcase', 'explode', 'explode | implode',
    'split("")', 'split(",")', 'split("aa")', '[indices("a")]', 'indices("aa")', 'index("b"), rindex("b")',
    'ltrimstr("a")', 'rtrimstr("c")', 'startswith("")', 'length', 'utf8bytelength', '.[1:3]', '.[-2:]',
    '@html', '@uri', '@csv?', '[.] | @csv', '[.] | @tsv', '@sh', '[., .] | @sh', '@base64', '@base64 | @base64d',
    '@base64d', '@json', '@text', 'tojson', 'tojson | fromjson', 'fromjson?', 'tonumber?', 'ascii?',
    'test("(a"; "")?', 'try test("(a") catch "bad"', 'test("a{2,1}")?', '[match("(?i)A"; "g").offset]',
    'test("\\\\bbar\\\\b")', 'gsub("(?<l>[a-z])(?<r>[a-z])"; "\\(.r)\\(.l)")', 'gsub("$"; "!")', 'gsub("^"; ">"; "g")',
    'sub("(?<x>z)?"; "<\\(.x)>")', '[match("a|"; "g") | [.offset, .length]]', 'splits("a")', '[splits("")]',
    'test("\\\\u00e9")', '[match("(?<a>.)(?<a>.)").captures[].name]?', 'gsub("\\\\p{So}"; "?")', 'gsub("(?m)^"; "#")',
]
for f in REGEX:
    for s in STRS:
        add("string_regex_fmt", f, s)

# ---------------------------------------------------------------- numbers & to_json
NUMS = ["0", "-0", "1", "-1", "0.1", "1e-7", "1e-6", "123456.789", "1e15", "1e16", "1e17", "1.5e300",
        "9007199254740993", "12345678901234567890", "-12345678901234567890", "100000000000000000000000",
        "1.7976931348623157e308", "5e-324", "3.141592653589793", "0.30000000000000004", "1e100", "2e-5", "123e-20"]
for f in [".", "tostring", "tojson", ". + 0", ". * 1", "-.", ". == 1e17", "floor", "[.]", "{a:.}", ". / 3",
          "[., 1] | max", "tostring | tonumber", "@text", "\"\\(.)\"", ". % 7", "sqrt", "[.] | sort | .[0]",
          ". as $x | $x", "length", "trunc", ". < 1e16", "[.] | tojson | fromjson", "fabs", "ceil", "isnormal"]:
    for n in NUMS:
        add("numbers_tojson", f, n)

# ---------------------------------------------------------------- seeded grammar fuzzer
rng = random.Random(0x6A71)
ATOMS = [".", ".a", ".b", ".[0]", ".[]?", "1", "0", "-2", "\"s\"", "null", "true", "false", "[]", "{}", "$x",
         ".[1:]", "..", "empty", "(1,2)", "length?", "keys?", "add?", "tostring", "type", "not", "[.[]?]",
         "first(.[]?)", "(.a // 3)", "@json"]
UN = ["[%s]", "{a: (%s)}", "(%s)?", "try (%s) catch \"E\"", "if (%s) then 1 else 2 end", "[limit(3; %s)]",
      "reduce (%s) as $y (0; . + 1)", "[foreach (%s) as $y (0; . + 1)]", "(%s) as $x | $x", "[(%s) | select(. != null)]",
      "first(%s)", "isempty(%s)", "[%s] | length", "path(%s)?", "(%s) |= 1", "del(%s)?", "[paths(%s)]?",
      "label $l | (%s)", "[%s] | sort", "[%s] | unique", "[%s] | group_by(type)", "any(%s; .)", "all(%s; .)",
      "[%s] | tojson", "[.[]? | %s]", "def f: %s; [f]", "[%s][1:]", "(%s) // \"alt\""]
BIN = ["%s | %s", "%s , %s", "%s + %s", "%s - %s", "%s * %s", "%s == %s", "%s < %s", "%s and %s", "%s or %s",
       "%s // %s", "[%s] + [%s]", "{a: %s} * {a: %s}", "(%s) as $x | %s", "if %s then %s else . end"]


def gen(d):
    if d <= 0 or rng.random() < 0.25:
        return rng.choice(ATOMS)
    r = rng.random()
    if r < 0.4:
        return rng.choice(UN) % gen(d - 1)
    return rng.choice(BIN) % ("(" + gen(d - 1) + ")", "(" + gen(d - 1) + ")")


FUZZ_INPUTS = ["null", "1", "\"ab\"", "[1,2,null]", "{\"a\":1,\"b\":[1,\"x\"]}", "[{\"a\":2},{\"a\":1}]", "[[1],[2,3]]"]
for _ in range(1500):
    q = "1 as $x | " + gen(4)
    add("fuzz", q, rng.choice(FUZZ_INPUTS))

# ---------------------------------------------------------------- gojq own test-suite
if "--yaml" in sys.argv:
    yp = sys.argv[sys.argv.index("--yaml") + 1]
    for q, inp in json.load(open(yp)):
        if inp.strip() == "50000" or "range(50000)" in q:
            continue  # update-perf cases -> audit/dos
        add("gojq_suite", q, inp)

json.dump(C, sys.stdout, ensure_ascii=False)
print(f"{len(C)} cases", file=sys.stderr)
