"""Hand-written adversarial semantic corpus.

Every case has an expectation decided from the references (ref):
  hbs  = Handlebars.js 4.7.8 (the reference implementation of Handlebars 4.x)
  rust = Rust `handlebars` =6.4.4 (the benchmark baseline)
  spec = Mustache Spec v1.4.2
expect: {"out": s} | {"err": [ErrorKind, ...]} ([] = any error kind) | {"graceful": true} (any result
        that is not a crash or timeout) | {"one_of": [expect, ...]}.
finding: REPORT.md id the case demonstrates; "" = control (Pion passes today and must keep passing).
Cases with expect None are documented divergences (REPORT.md "Accepted divergences"): reported with all
three engines' outputs but never graded, so a future change either way does not break the audit.
Helpers on every engine: `wrap` (block, returns "<b>" + fn(this) + "</b>"), `echo` (returns its first
argument), `safe` (SafeString of its first argument)."""
import json

ANY_ERR = []


def C(id, tmpl, data=None, expect=None, finding="", ref="hbs", **kw):
    c = {"id": "sem/" + id, "tmpl": tmpl,
         "data": data if isinstance(data, str) else json.dumps({} if data is None else data, ensure_ascii=False),
         "expect": expect, "finding": finding, "ref": ref}
    c.update(kw)
    return c


def out(s):
    return {"out": s}


def err(*kinds):
    return {"err": list(kinds)}


GRACEFUL = {"graceful": True}


X7 = "&<>\"'`= é\u0000\u0001日"
E7 = "&amp;&lt;&gt;&quot;&#x27;&#x60;&#x3D; é\u0000\u0001日"


def cases():
    L = []
    # ---- 1. XSS / escaping ------------------------------------------------------------------------
    L += [
        C("esc/seven_chars_utf8_nul", "{{x}}", {"x": X7}, out(E7), ref="hbs+rust"),
        C("esc/unquoted_attribute", "<a title={{x}}>", {"x": "a onmouseover=alert(1)"},
          out("<a title=a onmouseover&#x3D;alert(1)>"), ref="hbs+rust"),
        C("esc/backtick_ie_attr", "<a title=`{{x}}`>", {"x": "` onclick=x"}, out("<a title=`&#x60; onclick&#x3D;x`>"),
          ref="hbs+rust"),
        C("esc/script_close", "<script>var s='{{x}}'</script>", {"x": "'</script><script>alert(1)//"},
          out("<script>var s='&#x27;&lt;/script&gt;&lt;script&gt;alert(1)//'</script>"), ref="hbs+rust"),
        C("esc/triple_and_amp_raw", "{{{x}}}|{{&x}}|{{& x}}", {"x": "<i>"}, out("<i>|<i>|<i>"), ref="hbs+rust"),
        C("esc/helper_result", "{{echo x}}|{{{echo x}}}", {"x": "<i>"}, out("&lt;i&gt;|<i>"), ref="hbs+rust"),
        C("esc/subexpression", "{{echo (echo x)}}", {"x": "<i>"}, out("&lt;i&gt;"), ref="hbs+rust"),
        C("esc/safestring_helper", "{{safe x}}|{{echo (safe x)}}", {"x": "<i>"}, out("<i>|<i>")),
        C("esc/lookup", "{{lookup . 'x'}}|{{lookup a 0}}", {"x": "<i>", "a": ["<u>"]}, out("&lt;i&gt;|&lt;u&gt;")),
        C("esc/partial_hash_param", "{{> p v=x}}", {"x": "<i>"}, out("&lt;i&gt;|<i>"), ref="hbs+rust",
          partials={"p": "{{v}}|{{{v}}}"}),
        C("esc/partial_ctx_param", "{{> p o}}", {"o": {"v": "<i>"}}, out("&lt;i&gt;"), ref="hbs+rust",
          partials={"p": "{{v}}"}),
        C("esc/each_key_and_block_param", "{{#each o as |v k|}}{{k}}={{v}};{{@key}}{{/each}}", {"o": {"<k>": "<v>"}},
          out("&lt;k&gt;=&lt;v&gt;;&lt;k&gt;"), ref="hbs+rust"),
        C("esc/array_tostring", "{{a}}", {"a": ["<i>", 1]}, out("&lt;i&gt;,1")),
        C("esc/no_escape_mode", "{{x}}", {"x": "<i>"}, out("<i>"), ref="hbs+rust", no_escape=True),
        C("esc/escaped_mustache_is_text", "\\{{x}}|\\\\{{x}}", {"x": "<i>"}, out("{{x}}|\\&lt;i&gt;"), ref="hbs+rust"),
        C("esc/raw_block_body_is_literal", "{{{{raw}}}}{{x}}<b>{{{{/raw}}}}", {"x": "<i>"}, None,
          note="hbs: '' (blockHelperMissing on a raw block); rust and pion: '{{x}}<b>'"),
        C("esc/block_helper_not_double_escaped", "{{#wrap}}{{x}}{{/wrap}}", {"x": "<i>"}, out("<b>&lt;i&gt;</b>"),
          finding="P1-1", ref="hbs+rust"),
        C("esc/block_helper_in_each", "{{#each a}}{{#wrap}}{{this}}{{/wrap}}{{/each}}", {"a": ["&", "'"]},
          out("<b>&amp;</b><b>&#x27;</b>"), finding="P1-1", ref="hbs+rust"),
        C("esc/tilde_triple_stash", "a {{~{x}~}} b", {"x": "<i>"}, out("a<i>b"), finding="P1-2", ref="hbs+rust"),
        C("esc/tilde_triple_stash_left", "a {{~{x}}} b", {"x": "<i>"}, out("a<i> b"), finding="P1-2",
          ref="hbs+rust"),
        C("esc/triple_tilde_inside", "a {{{~x~}}} b", {"x": "<i>"}, None,
          note="README spelling: rust and pion 'a<i>b', hbs parse error"),
    ]
    # ---- 2. helpers --------------------------------------------------------------------------------
    L += [
        C("helper/missing_with_param", "{{nohelper 1}}", {"nohelper": "LEAK"}, err("HelperNotFound"),
          finding="P1-3", ref="hbs+rust"),
        C("helper/missing_with_hash", "{{nohelper k=1}}", {"nohelper": "LEAK"}, err("HelperNotFound"),
          finding="P1-3", ref="hbs+rust"),
        C("helper/missing_in_unless_fail_open", "{{#unless (isBanned u)}}secret{{/unless}}", {"u": "mallory"},
          err("HelperNotFound"), finding="P1-3", ref="hbs+rust"),
        C("helper/missing_block_with_param", "{{#nohelper 1}}x{{/nohelper}}", {"nohelper": True},
          err("HelperNotFound"), finding="P1-3", ref="hbs+rust"),
        C("helper/raw_block_calls_helper", "{{{{wrap}}}}{{x}}{{{{/wrap}}}}", {"x": "V"}, out("<b>{{x}}</b>"),
          finding="P2-5", ref="hbs+rust"),
        C("helper/lookup_bounds", "[{{lookup a 5}}][{{lookup a -1}}][{{lookup o 'z'}}][{{lookup a 1}}][{{lookup n 'x'}}]",
          {"a": [1, 2], "o": {}, "n": None}, out("[][][][2][]"), ref="hbs+rust"),
        C("helper/lookup_index_wraparound",
          "[{{lookup a '4294967296'}}][{{lookup a '18446744073709551617'}}][{{lookup a 4294967297}}][{{a.[4294967296]}}]",
          {"a": ["SECRET0", "S1"]}, out("[][][][]"), finding="P2-8", ref="hbs+rust"),
        C("helper/int_literal_overflow", "{{echo 99999999999999999999}}", None, None,
          note="pion wraps to 7766279631452241919; hbs 100000000000000000000; rust 1e20"),
        C("helper/nested_subexpr", "{{echo (echo (echo x))}}", {"x": "v"}, out("v"), ref="hbs+rust"),
        C("helper/log_is_silent", "[{{log 'x'}}]", None, out("[]"), ref="hbs+rust"),
        C("helper/literals", "{{> p k=true n=null s='a\"b'}}|{{echo -1}}|{{echo 1.50}}", None,
          out("true||a&quot;b|-1|1.5"), ref="hbs+rust", partials={"p": "{{k}}|{{n}}|{{s}}"}),
    ]
    # ---- 3. truthiness / sections -------------------------------------------------------------------
    L += [
        C("truth/if_values",
          "{{#if a}}1{{/if}}{{#if b}}2{{/if}}{{#if c}}3{{/if}}{{#if d}}4{{/if}}{{#if e}}5{{/if}}{{#if f}}6{{/if}}"
          "{{#if b includeZero=true}}7{{/if}}{{#unless b}}8{{/unless}}",
          {"a": False, "b": 0, "c": "", "d": [], "e": None, "f": {}}, out("678"),
          note="rust prints 78: it treats {} as falsy"),
        C("truth/include_zero_float", "{{#if z includeZero=true}}Y{{else}}N{{/if}}", '{"z":0.0}', out("Y"),
          ref="hbs+rust"),
        C("truth/else_if_chain", "{{#if a}}A{{else if b}}B{{else if c}}C{{else}}D{{/if}}", {"b": 0, "c": 1}, out("C"),
          ref="hbs+rust"),
        C("truth/unless_else", "{{#unless a}}U{{else}}E{{/unless}}", {"a": 0}, out("U"), ref="hbs+rust"),
        C("truth/with_empty", "{{#with a}}Y{{else}}N{{/with}}{{#with o}}Y{{else}}N{{/with}}", {"a": [], "o": {}},
          out("NY"), note="rust: NN"),
        C("sect/true_keeps_context", "{{#b}}[{{x}}]{{/b}}", {"b": True, "x": 1}, out("[1]")),
        C("sect/empty_object_truthy", "{{#o}}Y{{else}}N{{/o}}", {"o": {}}, out("Y")),
        C("sect/string_pushes_context", "{{#name}}[{{.}}]{{/name}}", {"name": "hello"}, out("[hello]"),
          finding="P1-4", ref="hbs+spec"),
        C("sect/number_pushes_context", "{{#n}}[{{this}}]{{/n}}", {"n": 5}, out("[5]"), finding="P1-4",
          ref="hbs+spec"),
        C("sect/empty_string", "{{#s}}[{{.}}]{{else}}E{{/s}}", {"s": ""}, None,
          note="hbs '[]' (pushes ''); pion 'E' (Mustache falsey)"),
        C("sect/with_zero", "{{#with z}}Y{{this}}{{else}}N{{/with}}", {"z": 0}, None,
          note="hbs 'Y0' (isEmpty(0) is false); pion and rust 'N'"),
    ]
    # ---- 4. iteration -------------------------------------------------------------------------------
    L += [
        C("each/object_meta", "{{#each o}}{{@key}}={{this}}{{@index}}{{@first}}{{@last}};{{/each}}", {"o": {"x": 1, "y": 2}},
          out("x=10truefalse;y=21falsetrue;"), ref="hbs+rust"),
        C("each/array_meta", "{{#each a}}{{@index}}{{@first}}{{@last}};{{/each}}", {"a": [1, 2, 3]},
          out("0truefalse;1falsefalse;2falsetrue;"), ref="hbs+rust"),
        C("each/array_key", "{{#each a}}[{{@key}}]{{/each}}", {"a": [1, 2]}, None,
          note="hbs '[0][1]' (@key is the index for arrays); rust and pion '[][]'"),
        C("each/else_and_non_iterables", "{{#each a}}x{{else}}E{{/each}}{{#each s}}x{{else}}S{{/each}}",
          {"a": [], "s": "ab"}, out("ES"), ref="hbs+rust"),
        C("each/parent_data_frame", "{{#each a}}{{#each this}}{{@../index}}.{{@index}} {{/each}}{{/each}}",
          {"a": [[1, 2], [3]]}, out("0.0 0.1 1.0 "), ref="hbs+rust"),
        C("each/this_scalars", "{{#each a}}[{{this}}|{{.}}]{{/each}}", {"a": [None, 1, "s", True]},
          out("[|][1|1][s|s][true|true]")),
        C("each/root", "{{#each a}}{{@root.t}}{{@root/t}}{{../t}}{{/each}}", {"a": [1], "t": "T"}, out("TTT"),
          ref="hbs+rust"),
        C("each/block_params_shadow_and_release", "{{#each a as |x i|}}{{x}}{{i}}{{/each}}{{x}}",
          {"a": ["p", "q"], "x": "OUT"}, out("p0q1OUT"), ref="hbs+rust"),
        C("each/block_params_nested", "{{#each a as |x|}}{{#each ../b as |y|}}{{x}}{{y}}{{/each}}{{/each}}",
          {"a": [1, 2], "b": [3]}, out("1323"), ref="hbs+rust"),
        C("each/block_params_in_partial", "{{#each a as |x|}}{{> p}}{{/each}}", {"a": ["v"]}, None,
          partials={"p": "[{{x}}]"}, note="hbs '[]' (block params do not reach partials); rust and pion '[v]'"),
        C("each/int_like_key_order", "{{#each o}}{{@key}}{{/each}}", '{"o":{"b":1,"2":2,"1":3}}', None,
          note="hbs '12b' (JS property order); pion 'b21' (insertion order)"),
        C("each/duplicate_keys_last_wins", "{{a}}", '{"a":1,"a":2}', out("2"), ref="hbs+rust"),
    ]
    # ---- 5. paths and scope -------------------------------------------------------------------------
    L += [
        C("path/parents", "{{#with a}}{{#with b}}{{../../t}}|{{../x}}{{/with}}{{/with}}", {"a": {"x": "AX", "b": {}}, "t": "T"},
          out("T|AX")),
        C("path/parent_skips_if", "{{#with a}}{{#if 1}}{{../t}}{{/if}}{{/with}}", {"a": {}, "t": "T"}, out("T")),
        C("path/local_only_blocks_walk", "{{#with a}}[{{./t}}][{{this.t}}]{{/with}}", {"a": {}, "t": "T"},
          out("[][]"), ref="hbs+rust"),
        C("path/implicit_walk", "{{#with a}}[{{t}}]{{/with}}", {"a": {}, "t": "T"}, None,
          note="pion '[T]' (Mustache context-stack walk); hbs and rust '[]' (no walk without compat mode)"),
        C("path/bracket_literal", "{{[a.b]}}|{{a.b}}|{{a/b}}", {"a.b": "LIT", "a": {"b": "NEST"}}, out("LIT|NEST|NEST"),
          ref="hbs+rust"),
        C("path/this_slash", "{{#with a}}{{this/b}}{{/with}}", {"a": {"b": "AB"}}, out("AB"), ref="hbs+rust"),
        C("path/array_numeric_segment", "{{a.0}}|{{a.[1]}}|{{a.length}}", {"a": ["x", "y"]}, None,
          note="pion 'x|y|2'; hbs parse error; rust error"),
        C("path/utf8_literals", "{{echo '日本é'}}|{{lookup m 'ü'}}|{{[日本]}}",
          {"m": {"ü": "U"}, "日本": "J"}, out("日本é|U|J"), ref="hbs+rust"),
        C("path/strict_undefined", "{{nope}}", None, err("StrictUndefined"), ref="hbs+rust", strict=True),
        C("path/strict_if_guard", "{{#if nope}}x{{/if}}|{{#unless nope}}u{{/unless}}", None, out("|u"),
          finding="P2-4", ref="hbs+rust", strict=True),
    ]
    # ---- 6. whitespace control / standalone ---------------------------------------------------------
    L += [
        C("ws/standalone_crlf", "{{#a}}\r\nX\r\n{{/a}}\r\n", {"a": True}, out("X\r\n"), ref="hbs+spec"),
        C("ws/standalone_with_tilde", "a\n  {{~#if t~}}  \n  b\n{{/if}}\n", {"t": True}, out("ab\n"), ref="hbs+rust"),
        C("ws/tilde_comment", "a  {{~!c~}}  b", None, out("ab")),
        C("ws/tilde_else", "{{#if t}} a {{~else~}} b {{/if}}", {"t": False}, out("b "), ref="hbs+rust"),
        C("ws/block_comment_with_mustaches", "{{!-- a }} {{#if}} b --}}X", None, out("X"), ref="hbs+rust"),
        C("ws/text_nul_bytes", "a\u0000b{{x}}", {"x": "\u0000"}, out("a\u0000b\u0000"), ref="rust",
          note="hbs rejects NUL in template text (lexer)"),
        C("ws/partial_indent_lines", "  {{> p}}\n", {"c": "a"}, out("  x\n  a\n  y\n"), ref="hbs+rust",
          partials={"p": "x\n{{c}}\ny\n"}),
        C("ws/partial_indent_nested", "  {{> p}}\n", None, out("  x\n    q1\n    q2\n"), ref="hbs+rust",
          partials={"p": "x\n  {{> q}}\n", "q": "q1\nq2\n"}),
        C("ws/partial_indent_utf8", "  {{> p}}\n", None, out("  日本\n  é\n"), ref="hbs+rust",
          partials={"p": "日本\né\n"}),
        C("ws/partial_indent_empty_line", "  {{> p}}\n", None, out("  x\n  \n  y\n"), finding="P2-1",
          ref="hbs+rust", partials={"p": "x\n\ny\n"}),
        C("ws/partial_indent_data_newlines", "  {{> p}}\n", {"c": "a\nb"}, None, partials={"p": "x\n{{c}}\n"},
          note="spec: indent template lines only ('  x\\n  a\\nb\\n', see spec/partials/Standalone Indentation); "
               "hbs and rust indent rendered output like pion"),
    ]
    # ---- 7. partials --------------------------------------------------------------------------------
    L += [
        C("partial/ctx_and_hash", "{{> p c k=1}}", {"c": {"a": "A"}, "a": "OUT"}, out("A1"), ref="hbs+rust",
          partials={"p": "{{a}}{{k}}"}),
        C("partial/dynamic_name", "{{> (echo n)}}", {"n": "p"}, out("P"), ref="hbs+rust", partials={"p": "P"}),
        C("partial/missing", "[{{> nope}}]", None, None,
          note="pion '[]' (Mustache Failed Lookup); hbs and rust raise partial-not-found"),
        C("partial/block_basic", "{{#> layout}}B{{x}}{{/layout}}", {"x": 1}, out("<B1>"), ref="hbs+rust",
          partials={"layout": "<{{> @partial-block}}>"}),
        C("partial/block_fallback", "{{#> nope}}F{{/nope}}", None, out("F"), ref="hbs+rust"),
        C("partial/block_context", "{{#> layout}}[{{v}}]{{/layout}}", {"v": "OUT", "o": {"v": "IN"}}, None,
          partials={"layout": "{{#with o}}{{> @partial-block}}{{/with}}"},
          note="hbs '[IN]' (block runs in the context at the call site); rust and pion '[OUT]'"),
        # hbs and rust raise "partial block not found"; Pion renders a missing @partial-block as empty, so an
        # empty rendering is as acceptable as an error: only the crash is graded.
        C("partial/block_self_reference", "{{#> layout}}{{> @partial-block}}{{/layout}}", None, GRACEFUL,
          finding="P0-1", ref="hbs+rust", partials={"layout": "{{> @partial-block}}"}),
        C("partial/block_self_reference_inline",
          "{{#*inline \"l\"}}<{{> @partial-block}}>{{/inline}}{{#> l}}{{> @partial-block}}{{/l}}", None, GRACEFUL,
          finding="P0-1", ref="hbs+rust"),
        C("partial/block_in_nested_partial", "{{#> layout}}PB{{/layout}}", None, out("[PB]"), finding="P2-3",
          partials={"layout": "{{> inner}}", "inner": "[{{> @partial-block}}]"},
          note="rust raises 'Partial block not found'"),
        C("partial/inline_in_partial_block", "{{#> layout}}{{#*inline \"slot\"}}S{{/inline}}{{/layout}}", None,
          out("[S]"), finding="P1-6", ref="hbs+rust", partials={"layout": "[{{> slot}}]"}),
        C("partial/inline_scoped_to_block", "{{#if t}}{{#*inline \"p\"}}IN{{/inline}}{{/if}}[{{> p}}]", {"t": True},
          {"one_of": [err(), out("[]")]}, finding="P2-2",
          note="hbs: partial not found (Pion renders missing partials as empty, so '[]' is accepted); rust '[IN]'"),
        C("partial/inline_hoisted", "[{{> p}}]{{#*inline \"p\"}}IN{{/inline}}", None, out("[IN]"), finding="P2-2",
          note="rust: partial not found"),
        C("partial/delimiters_do_not_leak", "{{=<% %>=}}<%> p%>|<%x%>", {"x": "V"}, out("V|V"), ref="spec",
          partials={"p": "{{x}}"}),
    ]
    # ---- 8. numbers ---------------------------------------------------------------------------------
    L += [
        C("num/shortest_round_trip", "{{a}} {{b}} {{c}} {{d}}", '{"a":1.5,"b":0.30000000000000004,"c":1e-7,"d":5e-324}',
          out("1.5 0.30000000000000004 1e-7 5e-324"), finding="P2-6", ref="hbs+rust"),
        C("num/large_and_small", "{{a}} {{b}} {{c}} {{d}} {{e}}", '{"a":1e21,"b":1.0,"c":1e-6,"d":123456789012345678901,"e":2.5e-5}',
          None, note="hbs '1e+21 1 0.000001 123456789012345680000 0.000025'; "
                     "rust '1e21 1.0 1e-6 1.2345678901234567e20 0.000025'; pion '1e+21 1 1e-06 1.2345678901234568e+20 2.5e-05'"),
        C("num/beyond_2^53", "{{a}}", '{"a":9007199254740993}', None,
          note="pion and hbs '9007199254740992' (binary64); rust '9007199254740993' (serde_json u64)"),
        C("num/negative_zero_and_bools", "{{z}}|{{t}}{{f}}{{n}}", '{"z":-0.0,"t":true,"f":false,"n":null}', out("0|truefalse")),
        C("num/object_tostring", "{{o}}|{{a}}", {"o": {"a": 1}, "a": [1, [2, 3], {"b": 1}]},
          out("[object Object]|1,2,3,[object Object]"), note="rust '[object]|[1, [2, 3], [object]]'"),
    ]
    # ---- 9. syntax errors ---------------------------------------------------------------------------
    L += [
        C("syntax/mismatched_close", "{{#if a}}x{{/each}}", None, err(), ref="hbs+rust"),
        C("syntax/unclosed_block", "{{#if a}}x", None, err(), ref="hbs+rust"),
        C("syntax/else_outside_block", "x{{else}}y", None, err(), ref="hbs+rust"),
        C("syntax/whitespace_in_tags", "{{  x  }}|{{# if  a }}y{{/ if }}", {"x": "X", "a": 1}, out("X|y"), ref="hbs+rust"),
    ]
    return L
