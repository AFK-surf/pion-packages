#!/usr/bin/env python3
"""Generate the differential corpora for the packages/template red-team audit.

    python3 gen_corpus.py <out_dir>

Writes:
  <out_dir>/corpus.txt  semantic/XSS cases, rendered in one process by both engines
  <out_dir>/dos.txt     DoS / stack / memory cases, each run in its own process
  <out_dir>/bench.txt   adversarial benchmark workloads (one case per bench_compare run)

Record format: fields joined by 0x1F, records by 0x1E:
  name, flags (comma list: html|json|strict|trim|lstrip|keepnl|nolimits), main source,
  then (template name, template source) pairs for extends/include/import.
The fixed render context lives in audit/probe/src/main.pion and audit/diff/rust/src/main.rs.
"""
import os
import sys

CASES = []
DOS = []


def c(name, src, flags="", **tpls):
    CASES.append((name, flags, src, tpls))


def d(name, src, flags="", **tpls):
    DOS.append((name, flags, src, tpls))


# ---------------------------------------------------------------------------
# 1. XSS / auto-escape / |tojson / safe taint
# ---------------------------------------------------------------------------
H = "html"
c("xss_basic", "{{ xss }}", H)
c("xss_attr", '<a title="{{ attr }}">', H)
c("xss_amp", "{{ amp }}", H)
c("xss_safe_ctx", "{{ safe_html }}", H)
c("xss_tojson_script", "<script>var x = {{ close|tojson }};</script>", H)
c("xss_tojson_xss", "{{ xss|tojson }}", H)
c("xss_tojson_noescape_mode", "{{ xss|tojson }}")
c("xss_tojson_map", "{{ {'k': close, 'q': \"it's\"}|tojson }}", H)
c("xss_tojson_list", "{{ [close, amp]|tojson }}", H)
c("xss_tojson_indent", "{{ {'a': [1, close]}|tojson(indent=2) }}", H)
c("xss_tojson_compact_default", "{{ {'a': 1, 'b': [1, 2]}|tojson }}")
c("xss_tojson_attr", "<div data-x='{{ users|tojson }}'>", H)
c("xss_tojson_unicode", "{{ uni|tojson }}")
c("xss_tojson_ctrl", "{{ '\\x01\\x7f'|tojson }}")
c("xss_tojson_float", "{{ [f, 1.0, 0.1, 1e20, -0.0]|tojson }}")
c("xss_upper", "{{ xss|upper }}", H)
c("xss_lower", "{{ xss|lower }}", H)
c("xss_trim", "{{ xss|trim }}", H)
c("xss_replace", "{{ xss|replace('alert', 'x') }}", H)
c("xss_replace_safe", "{{ safe_html|replace('ok', '<i>') }}", H)
c("xss_default_undef", "{{ nope|default(xss) }}", H)
c("xss_default_lit", "{{ nope|default('<b>') }}", H)
c("xss_join", "{{ [xss, amp]|join(', ') }}", H)
c("xss_join_safe_sep", "{{ [amp]|join(safe_html) }}", H)
c("xss_join_safe_items", "{{ [safe_html, amp]|join('<br>') }}", H)
c("xss_indent", "{{ xss|indent(2) }}", H)
c("xss_capitalize", "{{ xss|capitalize }}", H)
c("xss_title", "{{ xss|title }}", H)
c("xss_first", "{{ [xss]|first }}", H)
c("xss_string", "{{ xss|string }}", H)
c("xss_list_repr", "{{ [xss] }}", H)
c("xss_map_repr", "{{ {'a': close} }}", H)
c("xss_safe_upper", "{{ safe_html|upper }}", H)
c("xss_safe_concat", "{{ safe_html ~ xss }}", H)
c("xss_safe_plus", "{{ safe_html + amp }}", H)
c("xss_set_concat", "{% set x = safe_html ~ close %}{{ x }}", H)
c("xss_set_block", "{% set x %}{{ close }}{% endset %}{{ x }}", H)
c("xss_set_block_then_upper", "{% set x %}<i>{{ close }}{% endset %}{{ x|upper }}", H)
c("xss_filter_block", "{% filter upper %}{{ close }}{% endfilter %}", H)
c("xss_filter_block_lit", "{% filter upper %}<b>{{ amp }}</b>{% endfilter %}", H)
c("xss_macro_return", "{% macro m(v) %}<p>{{ v }}</p>{% endmacro %}{{ m(close) }}", H)
c("xss_macro_upper", "{% macro m(v) %}<p>{{ v }}</p>{% endmacro %}{{ m(close)|upper }}", H)
c("xss_caller", "{% macro w() %}<div>{{ caller() }}</div>{% endmacro %}{% call w() %}{{ close }}{% endcall %}", H)
c("xss_escape_twice", "{{ xss|e|e }}", H)
c("xss_escape_none_mode", "{{ xss|e }}")
c("xss_safe_filter", "{{ close|safe }}", H)
c("xss_autoescape_false", "{% autoescape false %}{{ close }}{% endautoescape %}{{ close }}", H)
c("xss_autoescape_true", "{% autoescape true %}{{ close }}{% endautoescape %}{{ close }}")
c("xss_urlencode", "{{ xss|urlencode }}", H)
c("xss_urlencode_map", "{{ {'a b': '&x', 'c': 1}|urlencode }}", H)
c("xss_format_int", "{{ n }}{{ neg }}{{ f }}{{ t }}{{ nil }}", H)
c("xss_none_html", "[{{ nil }}][{{ none }}]", H)
c("xss_include_ctx", "{% include 'p.html' %}", H, **{"p.html": "{{ close }}"})
c("xss_safe_in_list", "{% for x in [safe_html, close] %}{{ x }}{% endfor %}", H)
c("xss_ternary", "{{ safe_html if t else close }}{{ close if t else safe_html }}", H)
c("xss_or", "{{ nope or close }}{{ safe_html or close }}", H)
c("xss_slice_safe", "{{ safe_html[0:3] }}", H)
c("xss_safe_reverse", "{{ safe_html|reverse }}", H)
c("xss_json_mode", "{{ xss }}|{{ n }}|{{ items }}", "json")
c("xss_json_mode_safe", "{{ safe_html }}", "json")
c("xss_items_attr_name", "{% for u in users %}<li>{{ u.name }}</li>{% endfor %}", H)
c("xss_format_filter", "{{ '%s-%d'|format(close, 3) }}", H)
c("xss_dictsort", "{% for k, v in m|dictsort %}{{ k }}={{ v }};{% endfor %}", H)

# ---------------------------------------------------------------------------
# 2. Arithmetic / logic / comparison semantics
# ---------------------------------------------------------------------------
c("arith_floordiv_neg", "{{ (-7) // 2 }} {{ 7 // -2 }} {{ -7 // -2 }} {{ neg // 2 }}")
c("arith_mod_neg", "{{ (-7) % 2 }} {{ 7 % -2 }} {{ -7 % -2 }} {{ neg % 3 }}")
c("arith_float_floordiv", "{{ 7.5 // 2 }} {{ -7.5 // 2 }} {{ 7.5 % 2 }} {{ -7.5 % 2 }}")
c("arith_div", "{{ 1 / 2 }} {{ 4 / 2 }} {{ -1 / 3 }} {{ 10 / 4 }}")
c("arith_pow", "{{ 2 ** 10 }} {{ 2 ** 0 }} {{ 2 ** 62 }} {{ (-2) ** 3 }} {{ 2.0 ** 0.5 }}")
c("arith_pow_neg", "{{ 2 ** -1 }}")
c("arith_pow_big", "{{ 2 ** 63 }}")
c("arith_pow_1000", "{{ 2 ** 1000 }}")
c("arith_div_zero", "{{ 1 / 0 }}")
c("arith_div_zero_zero", "{{ 0 / 0 }}")
c("arith_floordiv_zero", "{{ 1 // 0 }}")
c("arith_mod_zero", "{{ 1 % 0 }}")
c("arith_float_div_zero", "{{ 1.0 / 0 }}")
c("arith_add_overflow", "{{ imax + 1 }}")
c("arith_sub_overflow", "{{ imin - 1 }}")
c("arith_mul_overflow", "{{ imax * 2 }}")
c("arith_neg_overflow", "{{ -imin }}")
c("arith_min_div_neg1", "{{ imin // -1 }}")
c("arith_min_div_literal", "{{ (-9223372036854775807 - 1) // -1 }}")
c("arith_round_huge_digits", "{{ 1.5|round(1000000) }}")
c("arith_min_mod_neg1", "{{ imin % -1 }}")
c("arith_min_truediv", "{{ imin / -1 }}")
c("arith_int_float_mix", "{{ 1 + 1.5 }} {{ 3 * 0.5 }} {{ 10 - 0.25 }} {{ 1.0 }} {{ 3.0 * 2 }}")
c("arith_float_fmt", "{{ 0.1 + 0.2 }} {{ 1e20 }} {{ 1.5e-7 }} {{ 100.0 }} {{ -0.0 }} {{ 1e16 }} {{ 123456789.125 }}")
c("arith_string_concat_plus", "{{ 'a' + 'b' }}")
c("arith_string_plus_int", "{{ 'a' + 1 }}")
c("arith_str_mul_neg", "[{{ 'ab' * -2 }}][{{ 'ab' * 0 }}]")
c("arith_list_mul", "{{ [1, 2] * 2 }} {{ [1] * 0 }}")
c("arith_bool_arith", "{{ true + 1 }} {{ true * 3 }}")
c("logic_or_value", "{{ 'a' or 'b' }}|{{ 0 or 'fallback' }}|{{ '' or 0 }}|{{ none or [] }}")
c("logic_and_value", "{{ 'a' and 'b' }}|{{ 0 and 'x' }}|{{ [] and 1 }}")
c("logic_short_div", "{{ true or 1 / 0 }}|{{ false and 1 // 0 }}|{{ 1 or undefined_fn() }}")
c("logic_not_prec", "{{ not 1 == 2 }} {{ not true and false }} {{ not (true and false) }}")
c("cmp_chain", "{{ 1 < 2 < 3 }} {{ 3 > 2 > 1 }} {{ 1 < 3 < 2 }} {{ 1 == 1 == 1 }}")
c("cmp_mixed_types", "{{ 1 == '1' }} {{ none == none }} {{ [1, 2] == [1, 2] }} {{ {'a': 1} == {'a': 1} }}")
c("cmp_order_mixed", "{{ 1 < 'a' }}")
c("cmp_list_order", "{{ [1, 2] < [1, 3] }}")
c("cmp_float_int", "{{ 1 == 1.0 }} {{ 2 > 1.5 }} {{ 0.1 + 0.2 == 0.3 }}")
c("cmp_in_variants", "{{ 'b' in m }} {{ 1 in items }} {{ 'ell' in plain }} {{ 'x' in none }}")
c("idx_neg", "{{ items[-1] }} {{ words[-2] }} {{ plain[-1] }}")
c("idx_oob", "[{{ items[10] }}][{{ items[-10] }}]")
c("slice_neg_step", "{{ items[::-1] }} {{ plain[::-1] }} {{ items[::2] }} {{ items[1:-1] }}")
c("slice_edges", "{{ items[-2:] }} {{ items[:-2] }} {{ items[5:] }} {{ items[::-2] }} {{ items[3:0:-1] }}")
c("slice_step_zero", "{{ items[::0] }}")
c("slice_unicode", "{{ uni[0:2] }}|{{ uni[::-1] }}|{{ uni|length }}|{{ uni[1] }}")
c("upper_unicode", "{{ uni|upper }}|{{ uni|title }}|{{ uni|capitalize }}")
c("lit_ints", "{{ 0x1F }} {{ 0o17 }} {{ 0b101 }} {{ 1_000_000 }} {{ 007 }}")
c("lit_big_int", "{{ 99999999999999999999 }}")
c("lit_floats", "{{ 1.5 }} {{ .5 }} {{ 1. }} {{ 1e3 }} {{ 1_0.5 }}")
c("lit_str_esc", "{{ 'a\\nb\\tc\\\\d\\'e\\\"f' }}|{{ \"\\u00e9\\u2713\" }}|{{ '\\x41' }}")
c("lit_str_bad_esc", "{{ '\\q' }}")
c("lit_none_bool", "{{ none }} {{ None }} {{ True }} {{ false }} {{ FALSE }}")
c("unary_minus_pow", "{{ -2 ** 2 }} {{ (-2) ** 2 }} {{ 2 ** 3 ** 2 }}")
c("tilde_prec", "{{ 1 + 2 ~ 3 }} {{ 'a' ~ 1 + 2 }}")
c("str_repr_in_list", "{{ ['a', \"b'c\", 1.0, none, true] }}")
c("map_repr", "{{ {'a': 1, 'b': 'x'} }} {{ m }}")
c("float_repr_list", "{{ [1.0, 2.5, -0.0] }}")

# ---------------------------------------------------------------------------
# 3. Scope / control flow / loop
# ---------------------------------------------------------------------------
c("scope_for_set_leak", "{% set x = 1 %}{% for i in [1, 2] %}{% set x = i %}{% endfor %}{{ x }}")
c("scope_if_set", "{% if true %}{% set x = 5 %}{% endif %}{{ x }}")
c("scope_with", "{% set x = 1 %}{% with x = 2 %}{{ x }}{% endwith %}{{ x }}")
c("scope_with_set", "{% with %}{% set y = 2 %}{% endwith %}[{{ y }}]")
c("scope_loop_var_after", "{% for i in [1, 2] %}{% endfor %}[{{ i }}][{{ loop }}]")
c("scope_ns", "{% set ns = namespace(c=0) %}{% for i in items %}{% set ns.c = ns.c + i %}{% endfor %}{{ ns.c }}")
c("loop_basic", "{% for x in words %}{{ loop.index }}{{ loop.index0 }}{{ loop.revindex }}{{ loop.revindex0 }}{{ loop.first }}{{ loop.last }}{{ loop.length }};{% endfor %}")
c("loop_prev_next", "{% for x in items %}{{ loop.previtem }}-{{ x }}-{{ loop.nextitem }}|{% endfor %}")
c("loop_changed", "{% for x in items %}{{ loop.changed(x) }}{% endfor %}")
c("loop_changed_seq", "{% for x in [1, 1, 2, 2, 1] %}{% if loop.changed(x) %}{{ x }}{% endif %}{% endfor %}")
c("loop_cycle", "{% for x in items %}{{ loop.cycle('a', 'b', 'c') }}{% endfor %}")
c("loop_depth_nested", "{% for a in [1, 2] %}{% for b in [1] %}{{ loop.depth }}{{ loop.index }}{% endfor %}{{ loop.depth }}{{ loop.index }}|{% endfor %}")
c("loop_recursive", "{% for x in [{'n': 'a', 'c': [{'n': 'b', 'c': [{'n': 'c', 'c': []}]}]}] recursive %}{{ x.n }}{{ loop.depth }}({{ loop(x.c) }}){% endfor %}")
c("loop_recursive_restore", "{% for x in [{'n': 1, 'c': [{'n': 2, 'c': []}, {'n': 3, 'c': []}]}, {'n': 4, 'c': []}] recursive %}[{{ x.n }}:{{ loop.index }}/{{ loop.length }}{{ loop(x.c) }}{{ loop.index }}]{% endfor %}")
c("loop_filter_if", "{% for x in items if x > 1 %}{{ x }}{{ loop.index }}{{ loop.length }};{% endfor %}")
c("loop_else", "{% for x in empty %}x{% else %}none{% endfor %}{% for x in items if x > 100 %}y{% else %}filtered{% endfor %}")
c("loop_unpack", "{% for k, v in m|items %}{{ k }}{{ v }}{% endfor %}")
c("loop_unpack_mismatch", "{% for a, b in [[1, 2, 3]] %}{{ a }}{% endfor %}")
c("loop_over_map", "{% for k in m %}{{ k }}{% endfor %}")
c("loop_over_string", "{% for ch in 'abc' %}{{ ch }}-{% endfor %}")
c("loop_over_int", "{% for x in 3 %}{{ x }}{% endfor %}")
c("loop_over_none", "{% for x in nil %}{{ x }}{% endfor %}")
c("loop_break_continue", "{% for x in items %}{% if x == 2 %}{% break %}{% endif %}{{ x }}{% endfor %}")
c("loop_range", "{{ range(5)|list }} {{ range(1, 10, 3)|list }} {{ range(5, 0, -2)|list }} {{ range(0)|list }}")
c("loop_range_step0", "{{ range(0, 5, 0)|list }}")
c("loop_outer_ref", "{% for a in [1, 2] %}{% set outer = loop %}{% for b in [1] %}{{ outer.index }}{% endfor %}{% endfor %}")
c("if_elif", "{% if n < 10 %}a{% elif n < 50 %}b{% else %}c{% endif %}")
c("strict_undef_print", "{{ nope }}", "strict")
c("strict_undef_if", "{% if nope %}y{% else %}n{% endif %}", "strict")
c("strict_undef_defined", "{{ nope is defined }}", "strict")
c("strict_undef_default", "{{ nope|default('d') }}", "strict")
c("strict_undef_attr", "{{ users[0].nope }}", "strict")
c("strict_undef_or", "{{ nope or 'x' }}", "strict")
c("strict_undef_for", "{% for x in nope %}{{ x }}{% endfor %}", "strict")
c("lenient_undef_attr_chain", "[{{ nope.a.b }}]")
c("lenient_undef_ops", "[{{ nope ~ 'x' }}][{{ nope|length }}][{{ nope|upper }}]")
c("lenient_undef_arith", "{{ nope + 1 }}")
c("lenient_none_attr", "{{ nil.x }}")
c("attr_vs_item", "{{ m.a }} {{ m['b'] }} {{ users[0]['name'] }} {{ users.0.name }}")
c("set_tuple", "{% set a, b = [1, 2] %}{{ a }}{{ b }}")
c("set_ns_undefined", "{% set x.y = 1 %}")
c("do_tag", "{% set l = [] %}{% do l.append(1) %}{{ l }}")

# ---------------------------------------------------------------------------
# 4. Whitespace control / lexer
# ---------------------------------------------------------------------------
c("ws_minus", "a  {{- 'b' -}}  c\n  {%- if true -%}  d  {%- endif -%}  e")
c("ws_comment_minus", "a  {#- c -#}  b")
c("ws_trim_blocks", "{% if true %}\nyes\n{% endif %}\nend", "trim")
c("ws_lstrip_blocks", "x\n    {% if true %}\n    yes\n    {% endif %}\n", "lstrip")
c("ws_both", "<ul>\n  {% for x in items %}\n  <li>{{ x }}</li>\n  {% endfor %}\n</ul>\n", "trim,lstrip")
c("ws_plus_disable", "  {%+ if true %}x{% endif +%}\ny", "trim,lstrip")
c("ws_trailing_nl", "a\n")
c("ws_trailing_nl_keep", "a\n", "keepnl")
c("ws_trailing_crlf", "a\r\n")
c("ws_comment_trim_blocks", "{# c #}\nx", "trim")
c("ws_expr_trim_blocks_untouched", "{{ 'a' }}\nb", "trim")
c("ws_lstrip_comment", "  {# c #}x", "lstrip")
c("ws_lstrip_not_expr", "  {{ 'x' }}", "lstrip")
c("ws_raw", "{% raw %}{{ a }}{% b %}{# c #}{% endraw %}")
c("ws_raw_minus", "x {%- raw -%} {{ y }} {%- endraw -%} z")
c("ws_raw_trim", "{% raw %}\n{{ a }}\n{% endraw %}\nb", "trim")
c("lex_unclosed_var", "line1\nline2 {{ x")
c("lex_unclosed_block", "a\n{% if true %}b")
c("lex_unclosed_comment", "a {# b")
c("lex_unclosed_string", "{{ 'abc }}")
c("lex_stray_end", "{% endif %}")
c("lex_bad_tag", "{% foo %}")
c("lex_mismatch_end", "{% if true %}{% endfor %}")
c("lex_brace_in_string", "{{ '}}' }}{{ \"{%\" }}")
c("lex_bracket_tokens", "{{ {'a': [1, {'b': 2}]}['a'][1]['b'] }}")
c("lex_expr_whitespace", "{{\n1\n+\n2\n}}")
c("lex_lone_brace", "{ } {x} {{ '{' }}")
c("lex_hash_in_text", "# not a comment\n## also")
c("lex_ident_unicode", "{{ héllo }}")
c("lex_trailing_comma", "{{ [1, 2,] }} {{ {'a': 1,} }} {{ (1,) }}")
c("lex_tuple", "{{ (1, 2) }} {{ () }}")

# ---------------------------------------------------------------------------
# 5. Inheritance / include / macros / imports
# ---------------------------------------------------------------------------
c("inh_3level", "{% extends 'mid' %}{% block b %}C[{{ super() }}]{% endblock %}",
  mid="{% extends 'base' %}{% block b %}M[{{ super() }}]{% endblock %}",
  base="<{% block b %}B{% endblock %}>")
c("inh_nested_blocks", "{% extends 'base' %}{% block inner %}I2{% endblock %}",
  base="[{% block outer %}O({% block inner %}I{% endblock %}){% endblock %}]")
c("inh_self_block", "{% block t %}T{% endblock %}|{{ self.t() }}")
c("inh_cond_extends", "{% if t %}{% extends 'a' %}{% else %}{% extends 'b' %}{% endif %}{% block x %}X{% endblock %}",
  a="A{% block x %}{% endblock %}", b="B{% block x %}{% endblock %}")
c("inh_dynamic_extends", "{% extends name_tpl %}", a="A")
c("inh_content_outside_block", "{% extends 'base' %}IGNORED{% block b %}X{% endblock %}TAIL",
  base="[{% block b %}{% endblock %}]")
c("inh_super_outside", "{{ super() }}")
c("inh_block_scoped_loop", "{% for x in items %}{% block b %}{{ x }}{% endblock %}{% endfor %}")
c("inh_block_twice", "{% block a %}1{% endblock %}{% block a %}2{% endblock %}")
c("inh_set_in_child_top", "{% extends 'base' %}{% set g = 'G' %}{% block b %}{{ g }}{% endblock %}",
  base="[{% block b %}{% endblock %}]")
c("inh_super_twice", "{% extends 'base' %}{% block b %}{{ super() }}{{ super() }}{% endblock %}", base="{% block b %}B{% endblock %}")
c("inc_ctx", "{% set v = 'local' %}{% include 'p' %}", p="[{{ v }}][{{ n }}]")
c("inc_loop_ctx", "{% for x in [1, 2] %}{% include 'p' %}{% endfor %}", p="{{ x }}{{ loop.index }}")
c("inc_set_isolated", "{% include 'p' %}[{{ leaked }}]", p="{% set leaked = 1 %}")
c("inc_missing", "{% include 'nope' %}")
c("inc_ignore_missing", "a{% include 'nope' ignore missing %}b")
c("inc_list", "{% include ['nope', 'p'] %}", p="P")
c("inc_with_ctx_var", "{% with v = 5 %}{% include 'p' %}{% endwith %}", p="{{ v }}")
c("macro_defaults", "{% macro m(a, b=2, c=a) %}{{ a }}{{ b }}{{ c }}{% endmacro %}{{ m(1) }}|{{ m(1, c=9) }}|{{ m(b=3, a=4) }}")
c("macro_too_many", "{% macro m(a) %}{{ a }}{% endmacro %}{{ m(1, 2) }}")
c("macro_unknown_kw", "{% macro m(a) %}{{ a }}{% endmacro %}{{ m(1, z=2) }}")
c("macro_varargs", "{% macro m(a) %}{{ varargs }}{{ kwargs }}{% endmacro %}{{ m(1) }}")
c("macro_caller_nested", "{% macro o() %}O({{ caller() }}){% endmacro %}{% macro i() %}I({{ caller() }}){% endmacro %}{% call o() %}{% call i() %}x{% endcall %}{% endcall %}")
c("macro_caller_args", "{% macro l(items) %}{% for x in items %}{{ caller(x) }}{% endfor %}{% endmacro %}{% call(v) l([1, 2]) %}<{{ v }}>{% endcall %}")
c("macro_closure_scope", "{% set g = 'outer' %}{% macro m() %}{{ g }}{% endmacro %}{% set g = 'changed' %}{{ m() }}")
c("macro_ctx_access", "{% macro m() %}{{ n }}{% endmacro %}{{ m() }}")
c("macro_recursive_ok", "{% macro f(n) %}{% if n > 0 %}{{ n }}{{ f(n - 1) }}{% endif %}{% endmacro %}{{ f(5) }}")
c("macro_name_attr", "{% macro m(a, b) %}{% endmacro %}{{ m.name }}|{{ m.arguments }}")
c("import_as", "{% import 'lib' as l %}{{ l.hi('x') }}", lib="{% macro hi(n) %}hi {{ n }}{% endmacro %}")
c("import_from", "{% from 'lib' import hi as h, bye %}{{ h(1) }}{{ bye() }}", lib="{% macro hi(n) %}hi{{ n }}{% endmacro %}{% macro bye() %}B{% endmacro %}")
c("import_var", "{% import 'lib' as l %}{{ l.x }}", lib="{% set x = 42 %}")
c("import_ctx", "{% import 'lib' as l %}{{ l.f() }}", lib="{% macro f() %}[{{ n }}]{% endmacro %}")

# ---------------------------------------------------------------------------
# 6. Filters / tests edge inputs
# ---------------------------------------------------------------------------
c("flt_sort", "{{ items|sort }} {{ words|sort }} {{ words|sort(case_sensitive=true) }} {{ items|sort(reverse=true) }}")
c("flt_sort_attr", "{{ users|sort(attribute='age')|map(attribute='name')|join(',') }}")
c("flt_sort_mixed", "{{ [3, 'a', 1.5, none, true]|sort }}")
c("flt_unique", "{{ items|unique|list }} {{ words|unique|list }} {{ words|unique(case_sensitive=true)|list }}")
c("flt_unique_attr", "{{ users|unique(attribute='group')|map(attribute='name')|join(',') }}")
c("flt_map", "{{ users|map(attribute='name')|join(',') }} {{ words|map('upper')|join }}")
c("flt_map_default", "{{ users|map(attribute='nick', default='?')|join(',') }}")
c("flt_select", "{{ items|select('odd')|list }} {{ items|reject('odd')|list }} {{ [0, 1, '', 'a', none]|select|list }}")
c("flt_select_arg", "{{ items|select('gt', 1)|list }} {{ items|select('divisibleby', 3)|list }}")
c("flt_selectattr", "{{ users|selectattr('active')|map(attribute='name')|join(',') }} {{ users|rejectattr('active')|map(attribute='name')|join(',') }}")
c("flt_selectattr_test", "{{ users|selectattr('age', '>', 28)|map(attribute='name')|join(',') }} {{ users|selectattr('group', 'eq', 'dev')|list|length }}")
c("flt_slice", "{{ range(10)|slice(3)|list }} {{ range(10)|slice(3, 'x')|list }} {{ [1]|slice(3)|list }}")
c("flt_batch", "{{ range(7)|batch(3)|list }} {{ range(7)|batch(3, 0)|list }}")
c("flt_round", "{{ 2.5|round }} {{ 3.5|round }} {{ -2.5|round }} {{ 2.675|round(2) }} {{ 42|round }} {{ 1.55|round(1) }}")
c("flt_round_method", "{{ 2.7|round(method='floor') }} {{ 2.1|round(method='ceil') }}")
c("flt_int", "{{ '42'|int }} {{ '3.9'|int }} {{ 'x'|int }} {{ 3.9|int }} {{ -3.9|int }} {{ '0x1F'|int(base=16) }} {{ ' 7 '|int }}")
c("flt_int_default", "{{ 'x'|int(5) }} {{ 'x'|int(default=6) }}")
c("flt_float", "{{ '3.5'|float }} {{ 'x'|float }} {{ 2|float }} {{ '1e3'|float }} {{ 'nan'|float }} {{ 'inf'|float }}")
c("flt_abs", "{{ neg|abs }} {{ -2.5|abs }} {{ imin|abs }}")
c("flt_urlencode", "{{ 'a b&c=d/é?'|urlencode }} {{ {'k': 'v w', 'x': 1}|urlencode }} {{ ['a b']|urlencode }}")
c("flt_replace", "{{ 'aaa'|replace('a', 'b', 2) }} {{ 'abc'|replace('', '-') }} {{ 'abc'|replace('x', 'y') }}")
c("flt_indent", "{{ multi|indent(2) }}|{{ multi|indent(2, true) }}|{{ multi|indent(2, true, true) }}|{{ multi|indent(first=true) }}")
c("flt_indent_str", "{{ multi|indent('> ') }}")
c("flt_trim_chars", "{{ 'xxhixx'|trim('x') }} [{{ padded|trim }}]")
c("flt_title", "{{ \"hello world-foo bar's\"|title }} {{ 'aBC dEF'|title }}")
c("flt_capitalize", "{{ 'hELLO World'|capitalize }}")
c("flt_wordcount", "{{ 'a b  c\n d'|wordcount }} {{ ''|wordcount }}")
c("flt_join_attr", "{{ users|join(', ', attribute='name') }}")
c("flt_join_nonstr", "{{ [1, none, true, 1.5]|join('-') }}")
c("flt_length", "{{ plain|length }} {{ m|length }} {{ range(5)|length }} {{ uni|count }}")
c("flt_first_last", "{{ items|first }} {{ items|last }} {{ plain|first }} {{ plain|last }} [{{ empty|first }}]")
c("flt_reverse", "{{ items|reverse|list }} {{ plain|reverse }} {{ range(3)|reverse|list }}")
c("flt_list", "{{ 'abc'|list }} {{ m|list }} {{ range(3)|list }}")
c("flt_items", "{{ m|items|list }}")
c("flt_dictsort", "{{ m|dictsort }} {{ m|dictsort(by='value') }} {{ m|dictsort(reverse=true) }}")
c("flt_default_bool", "{{ ''|default('x') }} {{ ''|default('x', true) }} {{ nil|default('x') }} {{ nope|d('y') }}")
c("flt_string", "{{ 1|string }} {{ none|string }} {{ [1]|string }} {{ 1.0|string }}")
c("flt_bool", "{{ 0|bool }} {{ 'x'|bool }} {{ []|bool }}")
c("flt_sum", "{{ items|sum }} {{ items|sum(start=10) }} {{ users|sum(attribute='age') }} {{ [1.5, 2]|sum }}")
c("flt_min_max", "{{ items|min }} {{ items|max }} {{ users|max(attribute='age')|attr('name') }}")
c("flt_attr", "{{ users[0]|attr('name') }}")
c("flt_split", "{{ 'a,b,,c'|split(',')|list }} {{ ' a  b '|split|list }} {{ 'a,b,c'|split(',', 1)|list }}")
c("flt_lower_upper", "{{ 'ÀÉ'|lower }} {{ 'straße'|upper }}")
c("flt_center", "[{{ 'x'|center(5) }}]")
c("flt_pprint", "{{ m|pprint }}")
c("flt_unknown", "{{ x|nonexistent_filter }}")
c("flt_chain_args", "{{ users|selectattr('active')|sort(attribute='age', reverse=true)|map(attribute='age')|list }}")
c("tests_basic", "{{ 3 is odd }} {{ 4 is even }} {{ 9 is divisibleby 3 }} {{ none is none }} {{ 'a' is string }} {{ 1 is number }} {{ 1.0 is float }} {{ 1 is integer }}")
c("tests_more", "{{ items is sequence }} {{ m is mapping }} {{ 'x' is iterable }} {{ 'abc' is startingwith 'a' }} {{ 'abc' is endingwith 'c' }} {{ 2 is in items }} {{ 'ABC' is upper }}")
c("tests_cmp", "{{ 2 is gt 1 }} {{ 2 is lt 1 }} {{ 2 is eq 2 }} {{ 2 is ne 2 }} {{ 1 is ge 1 }} {{ 1 is le 0 }} {{ 1 is sameas 1 }}")
c("tests_safe", "{{ safe_html is safe }} {{ plain is safe }} {{ (plain|e) is escaped }}")
c("tests_true_false", "{{ true is true }} {{ 1 is true }} {{ false is false }} {{ 0 is false }} {{ t is boolean }}")
c("tests_filter_test", "{{ 'upper' is filter }} {{ 'odd' is test }}")
c("tests_not", "{{ 1 is not odd }} {{ nope is not defined }}")
c("fn_dict", "{{ dict(a=1, b=2) }} {{ dict(m, c=3) }}")
c("fn_range_neg", "{{ range(-3)|list }} {{ range(3, -3, -1)|list }}")
c("fn_namespace_repr", "{{ namespace(a=1).a }}")
c("fn_lipsum_undef", "{{ debug is defined }}")


# ---------------------------------------------------------------------------
# DoS / stack / memory (each case runs in its own process, under timeout)
# ---------------------------------------------------------------------------
d("dos_parens_10000", "{{ " + "(" * 10000 + "1" + ")" * 10000 + " }}")
d("dos_parens_1000", "{{ " + "(" * 1000 + "1" + ")" * 1000 + " }}")
d("dos_parens_200", "{{ " + "(" * 200 + "1" + ")" * 200 + " }}")
d("dos_lists_5000", "{{ " + "[" * 5000 + "]" * 5000 + " }}")
d("dos_dicts_2000", "{{ " + "{'a': " * 2000 + "1" + "}" * 2000 + " }}")
d("dos_if_5000", "{% if true %}" * 5000 + "x" + "{% endif %}" * 5000)
d("dos_for_3000", "{% for i in [1] %}" * 3000 + "x" + "{% endfor %}" * 3000)
d("dos_add_chain_10000", "{{ " + " + ".join(["1"] * 10000) + " }}")
d("dos_add_chain_100000", "{{ " + " + ".join(["1"] * 100000) + " }}")
d("dos_tilde_chain_10000", "{{ " + " ~ ".join(["'a'"] * 10000) + " }}")
d("dos_and_chain_10000", "{{ " + " and ".join(["true"] * 10000) + " }}")
d("dos_not_10000", "{{ " + "not " * 10000 + "true }}")
d("dos_neg_10000", "{{ " + "-" * 10000 + "1 }}")
d("dos_filter_chain_10000", "{{ 'a'" + "|upper" * 10000 + " }}")
d("dos_attr_chain_10000", "{{ m" + ".a" * 10000 + " }}")
d("dos_pow_chain_5000", "{{ " + " ** ".join(["1"] * 5000) + " }}")
d("dos_ternary_5000", "{{ " + "1 if true else (" * 5000 + "0" + ")" * 5000 + " }}")
d("dos_str_mul_1e8", "{{ 'a' * 100000000 }}")
d("dos_str_mul_1e12", "{{ 'a' * 1000000000000 }}")
d("dos_list_mul_1e8", "{{ ([1] * 100000000)|length }}")
d("dos_list_mul_print", "{{ [1] * 100000000 }}")
d("dos_list_mul_nested", "{% set a = [1] * 10000 %}{% set b = [a] * 10000 %}{{ b|length }}")
d("dos_list_add_doubling", "{% set ns = namespace(l=[1]) %}{% for i in range(40) %}{% set ns.l = ns.l + ns.l %}{% endfor %}{{ ns.l|length }}")
d("dos_str_doubling", "{% set ns = namespace(s='a') %}{% for i in range(40) %}{% set ns.s = ns.s ~ ns.s %}{% endfor %}{{ ns.s|length }}")
d("dos_replace_empty", "{{ ('a' * 1000000)|replace('', 'xxxxxxxxxx')|length }}")
d("dos_replace_chain", "{{ 'aaaaaaaaaa'" + "|replace('a', 'aaaaaaaaaa')" * 9 + "|length }}")
d("dos_range_list_1e8", "{{ range(100000000)|list|length }}")
d("dos_range_sum_1e8", "{{ range(100000000)|sum }}")
d("dos_range_length_1e18", "{{ range(1000000000000000000)|length }}")
d("dos_pow_1e6", "{{ 2 ** 1000000 }}")
d("dos_pow_float_big", "{{ 10.0 ** 400 }}")
d("dos_indent_huge", "{{ multi|indent(100000000) }}")
d("dos_center_huge", "{{ 'x'|center(1000000000) }}")
d("dos_join_big", "{{ (range(10000000)|list)|join(',')|length }}")
d("dos_sort_1e6", "{{ (range(1000000)|reverse|list)|sort|first }}")
d("dos_sort_1e5_rev", "{{ (range(100000)|reverse|list)|sort|first }}")
d("dos_sort_attr_2e4", "{% set ns = namespace(l=[]) %}{% for i in range(20000) %}{% set ns.l = ns.l + [{'k': 20000 - i}] %}{% endfor %}{{ (ns.l|sort(attribute='k')|first).k }}")
d("dos_batch_fill_huge", "{{ [1, 2]|batch(1000000000, 0)|list|length }}")
d("dos_unique_1e5", "{{ (range(100000)|list)|unique|list|length }}")
d("dos_unique_strs_1e5", "{% set ns = namespace(l=[]) %}{% for i in range(100000) %}{% set ns.l = ns.l + [i ~ ''] %}{% endfor %}{{ ns.l|unique|list|length }}")
d("dos_list_append_quadratic", "{% set ns = namespace(l=[]) %}{% for i in range(20000) %}{% set ns.l = ns.l + [i] %}{% endfor %}{{ ns.l|length }}")
d("dos_nested_loops_1e8", "{% for a in range(10000) %}{% for b in range(10000) %}{% endfor %}{% endfor %}ok")
d("dos_while_like_recursion", "{% macro f(n) %}{{ f(n + 1) }}{% endmacro %}{{ f(0) }}")
d("dos_macro_recursion_wide", "{% macro f(n) %}{% if n < 30 %}{{ f(n + 1) }}{{ f(n + 1) }}{% endif %}{% endmacro %}{{ f(0)|length }}")
d("dos_extends_cycle", "{% extends 'a' %}", a="{% extends 'b' %}", b="{% extends 'a' %}")
d("dos_extends_self", "{% extends 'main' %}")
d("dos_include_cycle", "{% include 'a' %}", a="A{% include 'b' %}", b="B{% include 'a' %}")
d("dos_include_self", "x{% include 'main' %}")
d("dos_import_cycle", "{% import 'a' as a %}ok", a="{% import 'b' as b %}", b="{% import 'a' as a %}")
d("dos_include_fanout", "{% include 'a' %}",
  a="{% include 'b' %}" * 10, b="{% include 'c' %}" * 10, c="{% include 'd' %}" * 10,
  d="{% include 'e' %}" * 10, e="{% include 'f' %}" * 10, f="{% include 'g' %}" * 10,
  g="xxxxxxxxxx")
d("dos_recursive_loop", "{% set n = [{'c': []}] %}{% for x in [1] recursive %}{{ loop([1]) }}{% endfor %}")
d("dos_tojson_deep", "{% set ns = namespace(v=1) %}{% for i in range(200) %}{% set ns.v = [ns.v] %}{% endfor %}{{ ns.v|tojson|length }}")
d("dos_deep_list_print", "{% set ns = namespace(v=1) %}{% for i in range(5000) %}{% set ns.v = [ns.v] %}{% endfor %}{{ ns.v|length }}{{ ns.v }}")
d("dos_deep_list_eq", "{% set ns = namespace(v=1, w=1) %}{% for i in range(5000) %}{% set ns.v = [ns.v] %}{% set ns.w = [ns.w] %}{% endfor %}{{ ns.v == ns.w }}")
d("dos_deep_list_sort", "{% set ns = namespace(v=1) %}{% for i in range(5000) %}{% set ns.v = [ns.v] %}{% endfor %}{{ [ns.v, ns.v]|sort|length }}")
d("dos_long_text_10mb", "x" * 10_000_000)
d("dos_many_vars", "{{ n }}" * 200000)
d("dos_slice_huge_step", "{{ range(1000000000000000000)[::100000000000000000]|list }}")
d("dos_batch_huge", "{{ [1, 2]|batch(1000000000)|list|length }}")
d("dos_slice_filter_huge", "{{ [1, 2]|slice(1000000000)|list|length }}")
d("dos_round_huge", "{{ 1.5|round(1000000) }}")
d("dos_wordcount_big", "{{ ('a ' * 5000000)|wordcount }}")


# ---------------------------------------------------------------------------
# Adversarial benchmarks (identical stdout required; run via scripts/bench_compare.py)
# ---------------------------------------------------------------------------
BENCH = []


def b(name, src, flags="nolimits"):
    BENCH.append((name, flags, src, {}))


b("bench_loop_200k", "{% for i in range(400) %}<tr>{% for j in range(500) %}<td>{{ j }}</td>{% endfor %}</tr>{% endfor %}")
b("bench_html_escape_50k", "{% for i in range(50000) %}<p>{{ xss }}|{{ attr }}</p>{% endfor %}", "html,nolimits")
b("bench_macro_50k", "{% macro cell(v, cls='c') %}<td class=\"{{ cls }}\">{{ v }}</td>{% endmacro %}{% for i in range(50000) %}{{ cell(i) }}{% endfor %}", "html,nolimits")
b("bench_filters_50k", "{% for i in range(50000) %}{{ plain|upper|replace('O', '0')|trim|title }}{{ words|join(',') }}{% endfor %}")
b("bench_attr_lookup_100k", "{% for i in range(100000) %}{{ users[i % 3].name }}{{ m.a }}{% endfor %}", "html,nolimits")
b("bench_sort_20k", "{{ (range(20000)|reverse|list)|sort|first }}")
b("bench_unique_20k", "{{ (range(20000)|list)|unique|list|length }}")
b("bench_set_concat_20k", "{% set ns = namespace(s='') %}{% for i in range(20000) %}{% set ns.s = ns.s ~ 'x' %}{% endfor %}{{ ns.s|length }}")


def write(path, rows):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        for name, flags, src, tpls in rows:
            fields = [name, flags, src]
            for k, v in tpls.items():
                fields += [k, v]
            for f in fields:
                assert "\x1e" not in f and "\x1f" not in f, name
            fh.write("\x1f".join(fields) + "\x1e")


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    names = [r[0] for r in CASES + DOS + BENCH]
    assert len(names) == len(set(names)), "duplicate case names"
    write(os.path.join(out, "corpus.txt"), CASES)
    write(os.path.join(out, "dos.txt"), DOS)
    write(os.path.join(out, "bench.txt"), BENCH)
    print(f"corpus: {len(CASES)} cases, dos: {len(DOS)} cases, bench: {len(BENCH)} -> {out}")


if __name__ == "__main__":
    main()
