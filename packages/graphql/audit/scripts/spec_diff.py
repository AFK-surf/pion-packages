"""Hand-written GraphQL October 2021 differential corpus: Pion vs graphql-js@16.10.0 (AST) vs apollo-parser 0.8.4 (accept/reject).

Every case is run through `parse` (canonical AST dump), and lexer-only cases additionally through `tok`.
A row is a DIFF when Pion's accept/reject or AST differs from graphql-js. Rust is reported alongside.
Usage: spec_diff.py [--json out.json] [--show N]
"""
import json, sys
from common import run, is_err, short

Q = lambda body: "{ f(x: " + body + ") }"          # wrap a value
S = lambda body: "{ f(x: \"" + body + "\") }"       # wrap a string body
B = lambda body: "{ f(x: \"\"\"" + body + "\"\"\") }"  # wrap a block-string body

CASES = [
    # --- 1. SourceCharacter / control chars / BOM ------------------------------------------------
    ("src", "ctrl BEL in comment", "# a\x07b\n{ a }"),
    ("src", "ctrl VT in comment", "# \x0b\n{ a }"),
    ("src", "ctrl FF in comment", "# \x0c\n{ a }"),
    ("src", "DEL in comment", "# \x7f\n{ a }"),
    ("src", "NUL in comment", "# \x00\n{ a }"),
    ("src", "ctrl BEL in string", S("a\x07b")),
    ("src", "DEL in string", S("\x7f")),
    ("src", "NUL in string", S("\x00")),
    ("src", "ctrl US in string", S("\x1f")),
    ("src", "ctrl BEL in block string", B("a\x07b")),
    ("src", "DEL in block string", B("\x7f")),
    ("src", "BEL as whitespace", "{ a\x07 }"),
    ("src", "VT as whitespace", "{ a\x0b }"),
    ("src", "FF as whitespace", "{ a\x0c }"),
    ("src", "DEL as whitespace", "{ a\x7f }"),
    ("src", "BOM at start", "﻿{ a }"),
    ("src", "BOM mid-document", "{ a ﻿ b }"),
    ("src", "BOM between name chars", "{ a﻿b }"),
    ("src", "BOM in string", S("﻿")),
    ("src", "BOM in block string", B("﻿x")),
    ("src", "BOM in comment", "# ﻿\n{ a }"),
    ("src", "NBSP as whitespace", "{ a b }"),
    ("src", "non-ASCII name", "{ café }"),
    ("src", "CR only line endings", "{\ra\rb\r}"),
    ("src", "CRLF", "{\r\na\r\n}"),
    ("src", "U+2028 as whitespace", "{ a b }"),
    ("src", "astral in string", S("\U0001F600")),
    # --- 1b. String escapes -----------------------------------------------------------------------
    ("esc", r"\u{0}", S(r"\u{0}")),
    ("esc", r"\u{10FFFF}", S(r"\u{10FFFF}")),
    ("esc", r"\u{110000}", S(r"\u{110000}")),
    ("esc", r"\u{00000041} (8 digits)", S(r"\u{00000041}")),
    ("esc", r"\u{000000041} (9 digits)", S(r"\u{000000041}")),
    ("esc", r"\u{0000000000000041} (16 digits)", S(r"\u{0000000000000041}")),
    ("esc", r"\u{FFFFFFFF0041} overflowing hex", S(r"\u{FFFFFFFF0041}")),
    ("esc", r"\u{}", S(r"\u{}")),
    ("esc", r"\u{ 41}", S(r"\u{ 41}")),
    ("esc", r"\u{41", S(r"\u{41")),
    ("esc", r"\u{D800}", S(r"\u{D800}")),
    ("esc", r"\u{DFFF}", S(r"\u{DFFF}")),
    ("esc", r"\uD800 lone", S(r"\uD800")),
    ("esc", r"\uDC00 lone", S(r"\uDC00")),
    ("esc", r"\uD800A", S(r"\uD800A")),
    ("esc", r"😀 pair", S(r"😀")),
    ("esc", r"\uD83D\u{DE00} mixed", S(r"\uD83D\u{DE00}")),
    ("esc", r"\u{D83D}\u{DE00} var-width pair", S(r"\u{D83D}\u{DE00}")),
    ("esc", r"\uD83D😀", S(r"\uD83D😀")),
    ("esc", r"\uDE00\uD83D reversed", S(r"\uDE00\uD83D")),
    ("esc", r"\u0000", S(r"\u0000")),
    ("esc", r"é lower hex", S(r"é")),
    ("esc", r"\uXYZW", S(r"\uXYZW")),
    ("esc", r"\u12", S(r"\u12")),
    ("esc", r"\a", S(r"\a")),
    ("esc", r"\'", S(r"\'")),
    ("esc", r"\/", S(r"\/")),
    ("esc", r"\x41", S(r"\x41")),
    ("esc", "unescaped LF", S("a\nb")),
    ("esc", "unescaped CR", S("a\rb")),
    ("esc", "escape at EOF", '{ f(x: "\\'),
    ("esc", "all simple escapes", S(r"\"\\\/\b\f\n\r\t")),
    # --- 1c. Block strings ------------------------------------------------------------------------
    ("block", "empty", B("")),
    ("block", "four quotes", '{ f(x: """"""") }'),
    ("block", r'\""" escape', B(r'a\"""b')),
    ("block", r'\"""" escape+quote', B(r'a\""""b')),
    ("block", r'trailing \"""', '{ f(x: """abc\\""""") }'),
    ("block", r'abc\""" unterminated', '{ f(x: """abc\\""") }'),
    ("block", "quote before close", '{ f(x: """a"""") }'),
    ("block", "mixed tab/space indent", B("\n\t  a\n  \tb\n")),
    ("block", "tab indent", B("\n\t\ta\n\t\tb\n")),
    ("block", "whitespace-only lines", B("  \n    a\n   \n    b\n  \t ")),
    ("block", "CRLF normalised", B("\r\n  a\r\n  b\r\n")),
    ("block", "CR normalised", B("\r  a\r  b\r")),
    ("block", "first line keeps indent", B("   first\n     second\n   third")),
    ("block", "only whitespace", B("   \n \t \n ")),
    ("block", "backslashes kept", B(r"\n\tA")),
    ("block", "single line with lead space", B("  a")),
    ("block", "unterminated", '{ f(x: """abc'),
    # --- 1d. Numbers --------------------------------------------------------------------------------
    ("num", "123a", Q("123a")), ("num", "123_a", Q("123_a")), ("num", "1.0e+1a", Q("1.0e+1a")),
    ("num", "1.0.2", Q("1.0.2")), ("num", "-0", Q("-0")), ("num", "-00", Q("-00")), ("num", "-0.0", Q("-0.0")),
    ("num", "00", Q("00")), ("num", "0x10", Q("0x10")), ("num", "1e", Q("1e")), ("num", "1e+", Q("1e+")),
    ("num", "1.e1", Q("1.e1")), ("num", ".5", Q(".5")), ("num", "-.5", Q("-.5")), ("num", "- 1", Q("- 1")),
    ("num", "1..2", Q("1..2")), ("num", "1...", "{ f(x: [1...]) }"), ("num", "123...", "{ ...F @d(x: 123...) }"),
    ("num", "1E10", Q("1E10")), ("num", "1e-10", Q("1e-10")), ("num", "0.0e0", Q("0.0e0")),
    ("num", "9999999999999999999999 big int", Q("9999999999999999999999")),
    ("num", "1 (NameStart after space)", Q("1 a")), ("num", "1,2", Q("[1,2]")),
    ("num", "-", Q("-")), ("num", "+1", Q("+1")), ("num", "1-1", Q("[1-1]")),
    # --- 2. Keywords in name positions -----------------------------------------------------------
    *[("kw", f"field named {k}", "{ %s }" % k) for k in
      ["query", "mutation", "subscription", "fragment", "on", "true", "false", "null", "type", "interface",
       "union", "enum", "input", "scalar", "schema", "directive", "repeatable", "extend", "implements"]],
    *[("kw", f"alias {k}", "{ %s: a }" % k) for k in ["on", "true", "null", "fragment"]],
    *[("kw", f"arg {k}", "{ a(%s: 1) }" % k) for k in ["on", "true", "null", "query"]],
    *[("kw", f"op name {k}", "query %s { a }" % k) for k in ["on", "true", "null", "query", "fragment"]],
    *[("kw", f"fragment name {k}", "fragment %s on T { a } { ...%s }" % (k, k)) for k in ["on", "true", "null", "query", "fragment"]],
    *[("kw", f"type name {k}", "type %s { a: Int }" % k) for k in ["on", "true", "null", "query", "type"]],
    *[("kw", f"enum value {k}", "enum E { %s }" % k) for k in ["true", "false", "null", "on", "query", "TRUE"]],
    *[("kw", f"variable ${k}", "query Q($%s: Int) { a }" % k) for k in ["on", "true", "null"]],
    ("kw", "spread ...on (inline w/o type)", "{ ...on { a } }"),
    ("kw", "spread ...on T", "{ ...on T { a } }"),
    ("kw", "type condition named on", "{ ... on on { a } }"),
    ("kw", "directive named on", "{ a @on }"),
    ("kw", "directive named skip-like true", "{ a @true }"),
    ("kw", "enum value true in arg", Q("true")), ("kw", "enum value TRUE in arg", Q("TRUE")),
    ("kw", "QUERY keyword uppercase", "QUERY { a }"),
    # --- 2b. SDL syntax ------------------------------------------------------------------------------
    ("sdl", "type T (no body)", "type T"), ("sdl", "type T {}", "type T {}"),
    ("sdl", "interface I {}", "interface I {}"), ("sdl", "input I {}", "input I {}"), ("sdl", "enum E {}", "enum E {}"),
    ("sdl", "implements & A & B", "type T implements & A & B { a: Int }"),
    ("sdl", "implements A, B (legacy comma)", "type T implements A, B { a: Int }"),
    ("sdl", "implements A B (legacy space)", "type T implements A B { a: Int }"),
    ("sdl", "implements & only", "type T implements & { a: Int }"),
    ("sdl", "implements A &", "type T implements A & { a: Int }"),
    ("sdl", "union U = | A | B", "union U = | A | B"), ("sdl", "union U = A |", "union U = A |"),
    ("sdl", "union U =", "union U ="), ("sdl", "union U (no members)", "union U"),
    ("sdl", "union U = || A", "union U = || A"),
    ("sdl", "extend type T @dir", "extend type T @dir"), ("sdl", "extend schema @dir", "extend schema @dir"),
    ("sdl", "extend schema {}", "extend schema {}"), ("sdl", "extend schema", "extend schema"),
    ("sdl", "extend type T (empty)", "extend type T"), ("sdl", "extend type T {}", "extend type T {}"),
    ("sdl", "extend scalar S", "extend scalar S"), ("sdl", "extend union U = A", "extend union U = A"),
    ("sdl", "extend enum E { A }", "extend enum E { A }"), ("sdl", "extend input I { a: Int }", "extend input I { a: Int }"),
    ("sdl", "description on extend", '"d" extend type T @x'),
    ("sdl", "block description on extend", '"""d""" extend schema @x'),
    ("sdl", "description on schema", '"d" schema { query: Q }'),
    ("sdl", "description on query", '"d" query { a }'), ("sdl", "description on fragment", '"d" fragment F on T { a }'),
    ("sdl", "description on anonymous query", '"d" { a }'),
    ("sdl", "schema duplicate root fields", "schema { query: Q query: R }"),
    ("sdl", "schema {}", "schema {}"), ("sdl", "schema (no body)", "schema @d"),
    ("sdl", "schema { foo: Q }", "schema { foo: Q }"),
    ("sdl", "directive def basic", "directive @d on FIELD"),
    ("sdl", "directive def | leading", "directive @d on | FIELD | QUERY"),
    ("sdl", "directive def repeatable", "directive @d repeatable on FIELD"),
    ("sdl", "directive def bad location", "directive @d on FOO"),
    ("sdl", "directive def lower location", "directive @d on field"),
    ("sdl", "directive def no locations", "directive @d on"),
    ("sdl", "directive def args()", "directive @d() on FIELD"),
    ("sdl", "directive with args + desc", 'directive @d("arg desc" a: Int = 1 @x) on FIELD'),
    ("sdl", "field args()", "type T { f(): Int }"),
    ("sdl", "field arg desc", 'type T { f("desc" a: Int, """block""" b: [Int!]! = [1]): Int }'),
    ("sdl", "input default variable", "input I { a: Int = $x }"),
    ("sdl", "field arg default variable", "type T { f(a: Int = $x): Int }"),
    ("sdl", "type directive variable arg", "type T @d(a: $x) { a: Int }"),
    ("sdl", "schema directive variable", "schema @d(a: $x) { query: Q }"),
    ("sdl", "enum value directive variable", "enum E { A @d(a: $x) }"),
    ("sdl", "scalar with desc", '"""\n  The scalar\n"""\nscalar S @d'),
    ("sdl", "interface implements interface", "interface I implements J & K { a: Int }"),
    ("sdl", "repeatable as directive name", "directive @repeatable on FIELD"),
    ("sdl", "directive def without @", "directive d on FIELD"),
    ("sdl", "field type missing", "type T { a }"), ("sdl", "field without colon", "type T { a Int }"),
    ("sdl", "type with variable-def style", "type T { a: Int! ! }"),
    ("sdl", "nested non-null !!", "type T { a: Int!! }"),
    ("sdl", "list type [Int!]!", "type T { a: [[Int!]!]! }"),
    ("sdl", "mixed exec + sdl", "type T { a: Int } query Q { a } fragment F on T { a }"),
    # --- 2c. Executable syntax ----------------------------------------------------------------------
    ("exec", "f()", "{ f() }"), ("exec", "@d()", "{ f @d() }"), ("exec", "query Q()", "query Q() { a }"),
    ("exec", "{ a {} }", "{ a {} }"), ("exec", "{}", "{}"), ("exec", "empty doc", ""), ("exec", "comment-only doc", "# x\n"),
    ("exec", "whitespace-only doc", " \n\t,"),
    ("exec", "var default $y", "query Q($x: Int = $y) { a }"),
    ("exec", "var default nested $y", "query Q($x: [I] = [{a: $y}]) { a }"),
    ("exec", "var directive with $y", "query Q($x: Int @d(a: $y)) { a }"),
    ("exec", "var default w/ directive", "query Q($x: Int = 1 @d) { a }"),
    ("exec", "var without $", "query Q(x: Int) { a }"),
    ("exec", "var type missing", "query Q($x) { a }"),
    ("exec", "op directives with $var", "query Q($x: Boolean) @d(if: $x) { a }"),
    ("exec", "fragment variables (legacy)", "fragment F($x: Int) on T { a }"),
    ("exec", "fragment without on", "fragment F T { a }"),
    ("exec", "inline fragment no type", "{ ... { a } }"), ("exec", "inline fragment @d only", "{ ... @include(if: true) { a } }"),
    ("exec", "spread with args", "{ ...F(a: 1) }"),
    ("exec", "alias chain a: b: c", "{ a: b: c }"),
    ("exec", "object value trailing comma", Q("{a: 1,}")), ("exec", "list trailing comma", Q("[1,]")),
    ("exec", "object key repeated", Q("{a: 1, a: 2}")),
    ("exec", "object key missing colon", Q("{a 1}")),
    ("exec", "empty list/object", Q("[{} []]")),
    ("exec", "subscription", "subscription S { a }"),
    ("exec", "two anonymous ops", "{ a } { b }"),
    ("exec", "selection after shorthand name", "query { a } query Q { b }"),
    ("exec", "dollar space name", "query Q($ x: Int) { a(x: $ x) }"),
    ("exec", "spread space name", "{ ... F }"),
    ("exec", "spread no name", "{ ... }"),
    ("exec", "unbalanced }", "{ a } }"), ("exec", "stray token after doc", "{ a } 1"),
    ("exec", "string as definition", '"just a string"'),
    ("exec", "directive on shorthand", "@d { a }"),
    ("exec", "top-level spread", "...F"),
]


def main():
    js_out = None
    show = 999
    if "--json" in sys.argv:
        js_out = sys.argv[sys.argv.index("--json") + 1]
    recs = [c[2] for c in CASES]
    p = run("pion", "parse", recs)
    n = run("node", "parse", recs)
    r = run("rust", "parse", recs)
    pt = run("pion", "tok", recs)
    nt = run("node", "tok", recs)
    rows = []
    for (cat, name, src), a, b, c, ta, tb in zip(CASES, p, n, r, pt, nt):
        acc_p, acc_n, acc_r = not is_err(a), not is_err(b), not is_err(c)
        tok_diff = is_err(ta) != is_err(tb) or (not is_err(ta) and ta != tb)
        status = "same"
        if acc_p != acc_n:
            status = "ACCEPT-DIFF"
        elif acc_p and a != b:
            status = "AST-DIFF"
        elif tok_diff:
            status = "TOK-DIFF"
        rows.append(dict(cat=cat, name=name, src=src, pion=a, node=b, rust=c, pion_tok=ta, node_tok=tb, status=status,
                         rust_agrees_node=(acc_r == acc_n)))
    diffs = [x for x in rows if x["status"] != "same"]
    print(f"spec_diff: {len(rows)} cases, {len(diffs)} differ from graphql-js@16.10.0")
    for x in diffs[:show]:
        print(f"  [{x['status']:11s}] {x['cat']:5s} {x['name']}")
        print(f"      src  : {short(x['src'])}")
        print(f"      pion : {short(x['pion'] if x['status'] != 'TOK-DIFF' else x['pion_tok'])}")
        print(f"      node : {short(x['node'] if x['status'] != 'TOK-DIFF' else x['node_tok'])}")
        print(f"      rust : {short(x['rust'])}")
    if js_out:
        json.dump(rows, open(js_out, "w"), indent=1)


if __name__ == "__main__":
    main()
