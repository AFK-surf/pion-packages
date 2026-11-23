#!/usr/bin/env python3
"""Curated adversarial differential corpus for packages/jsonschema (red-team W10).

usage: gen_redteam.py > redteam.jsonl
Each case: {"id","draft","fmt","schema","instance","expect"?,"desc"}.
"expect" is set only where the JSON Schema spec (or RFC for formats) fixes the verdict; cases without it are
implementation-defined (e.g. >2^53 integers) and are reported as pure Pion-vs-Rust/ajv differentials.
Raw lines (duplicate JSON keys) are written verbatim.
"""
import json
import sys

out = []


def case(cid, schema, instance, expect=None, desc="", draft="2020-12", fmt=False):
    c = {"id": cid, "draft": draft, "fmt": fmt, "schema": schema, "instance": instance, "desc": desc}
    if expect is not None:
        c["expect"] = expect
    out.append(json.dumps(c, ensure_ascii=False))


def raw(cid, schema_json, instance_json, expect, desc, draft="2020-12"):
    out.append('{"id": %s, "draft": "%s", "fmt": false, "schema": %s, "instance": %s, "expect": "%s", "desc": %s}'
               % (json.dumps(cid), draft, schema_json, instance_json, expect, json.dumps(desc)))


def nest_arr(d):
    v = []
    for _ in range(d - 1):
        v = [v]
    return v


def nest_obj(d, key="c"):
    v = {}
    for _ in range(d - 1):
        v = {key: v}
    return v


# ---------------------------------------------------------------- numbers / multipleOf / integer
case("num/multipleOf1-1e9+0.0005", {"multipleOf": 1}, 1000000000.0005, "I",
     "multipleOf:1 (the classic 'integer' idiom) must reject a non-integer")
case("num/multipleOf1-1e6+1e-6", {"multipleOf": 1}, 1000000.000001, "I", "multipleOf:1 rejects 1000000.000001")
case("num/multipleOf0.01-1e10+0.005", {"multipleOf": 0.01}, 10000000000.005, "I",
     "money amount with half a cent")
case("num/multipleOf0.01-1e8+0.001", {"multipleOf": 0.01}, 100000000.001, "I", "money amount with 0.1 cent")
case("num/multipleOf0.5-1e9+0.25", {"multipleOf": 0.5}, 1000000000.25, "I", "0.25 off a multiple of 0.5")
case("num/multipleOf2-1e15+1", {"multipleOf": 2}, 1000000000000001, "I", "odd integer below 2^53")
case("num/multipleOf0.0001-ok", {"multipleOf": 0.0001}, 0.0075, "V", "0.0075 = 75 * 0.0001")
case("num/multipleOf0.0001-bad", {"multipleOf": 0.0001}, 0.00751, "I", "0.00751 not a multiple of 0.0001")
case("num/multipleOf0.1-0.3", {"multipleOf": 0.1}, 0.3, "V", "0.3 is a multiple of 0.1 (binary FP trap)")
case("num/multipleOf0.01-19.99", {"multipleOf": 0.01}, 19.99, "V", "19.99 is a multiple of 0.01")
case("num/multipleOf1e-10", {"multipleOf": 1e-10}, 1e-05, "V", "1e-5 multiple of 1e-10")
case("num/multipleOf1e308-ok", {"multipleOf": 1e308}, 1e308, "V", "huge divisor, equal")
case("num/multipleOf1e308-bad", {"multipleOf": 1e308}, 5e307, "I", "huge divisor, half")
case("num/float-overflow-0.5", {"type": "integer", "multipleOf": 0.5}, 1e308, "V",
     "suite optional/float-overflow: every integer is a multiple of 0.5 (README claims overflow-safe)")
case("num/multipleOf-2^-1000", {"multipleOf": 2.0 ** -1000}, 2.0 ** 30, "V",
     "exactly representable: 2^30 = 2^1030 * 2^-1000 (quotient overflows double)")
case("num/integer-1.0", {"type": "integer"}, 1.0, "V", "1.0 is an integer")
case("num/integer-1e20", {"type": "integer"}, 1e20, "V", "1e20 is an integer")
case("num/integer--0.0", {"type": "integer"}, -0.0, "V", "-0.0 is an integer")
case("num/integer-1.5", {"type": "integer"}, 1.5, "I", "1.5 is not an integer")
case("num/exclMin-0--0", {"exclusiveMinimum": 0}, -0.0, "I", "-0.0 is not > 0")
case("num/exclMax-d7", {"exclusiveMaximum": 3}, 3, "I", "draft-07 numeric exclusiveMaximum", draft="7")
case("num/draft4-bool-exclusiveMinimum", {"$schema": "http://json-schema.org/draft-04/schema#", "minimum": 0,
                                          "exclusiveMinimum": True}, 0, "I",
     "draft-04 boolean exclusiveMinimum with $schema auto-detection", draft="auto")
case("num/2^53+1-const", {"const": 9007199254740992}, 9007199254740993, None,
     "integers beyond 2^53: Pion/ajv collapse to f64, Rust keeps u64")
case("num/2^53+1-maximum", {"maximum": 9007199254740992}, 9007199254740993, None, "maximum beyond 2^53")
case("num/2^53+1-multipleOf2", {"multipleOf": 2}, 9007199254740993, None, "odd integer beyond 2^53")
case("num/u64max-integer", {"type": "integer"}, 18446744073709551615, "V", "u64::MAX is an integer")

# ---------------------------------------------------------------- equality / enum / const / uniqueItems
case("eq/enum-1.0", {"enum": [1]}, 1.0, "V", "1 == 1.0")
case("eq/const-0--0", {"const": 0}, -0.0, "V", "0 == -0.0")
case("eq/const-true-1", {"const": True}, 1, "I", "true != 1")
case("eq/const-false-0", {"const": False}, 0, "I", "false != 0")
case("eq/const-null-false", {"const": None}, False, "I", "null != false")
case("eq/const-keyorder", {"const": {"a": 1, "b": {"x": [1, {"y": 2, "z": 3}]}}},
     {"b": {"x": [1, {"z": 3, "y": 2}]}, "a": 1}, "V", "key order is irrelevant")
case("eq/enum-arrorder", {"enum": [[1, 2]]}, [2, 1], "I", "array order matters")
case("eq/unique-1-1.0", {"uniqueItems": True}, [1, 1.0], "I", "[1, 1.0] has duplicates")
case("eq/unique-0--0", {"uniqueItems": True}, [0, -0.0], "I", "[0, -0.0] has duplicates")
case("eq/unique-obj-order", {"uniqueItems": True}, [{"a": 1, "b": 2}, {"b": 2, "a": 1}], "I", "objects equal")
case("eq/unique-true-1", {"uniqueItems": True}, [True, 1], "V", "true and 1 differ")
case("eq/unique-null-false-0-empty", {"uniqueItems": True}, [None, False, 0, "", [], {}], "V", "all distinct")
case("eq/unique-9-items-hash", {"uniqueItems": True}, [1, 2, 3, 4, 5, 6, 7, 8, 9.0, 1.0], "I",
     "hash path (n > 8): 1 == 1.0")
case("eq/unique-9-deep-distinct", {"uniqueItems": True},
     [nest_arr(70) + [i] for i in range(10)], "V", "hash path: 10 distinct arrays that differ below depth 64")
raw("eq/dupkey-maxProperties", '{"maxProperties": 1}', '{"a": 1, "a": 2}', "V",
    "duplicate instance key: last wins -> one property")
raw("eq/dupkey-properties", '{"properties": {"a": {"type": "integer"}}}', '{"a": "x", "a": 1}', "V",
    "duplicate instance key: only the last value is the property value")
raw("eq/dupkey-const", '{"const": {"a": 1}}', '{"a": 2, "a": 1}', "V", "duplicate key: last wins")

# ---------------------------------------------------------------- strings / regex
case("str/maxLength-emoji", {"maxLength": 1}, "\U0001F600", "V", "one astral code point")
case("str/minLength-emoji", {"minLength": 2}, "\U0001F600", "I", "one astral code point < 2")
case("str/maxLength-combining", {"maxLength": 1}, "é", "I", "combining sequence = 2 code points")
case("str/maxLength-cjk", {"maxLength": 2}, "中文", "V", "2 code points")
case("re/lookahead-neg-ok", {"pattern": "^(?!admin$).*$"}, "user", "V", "ECMA-262 negative lookahead")
case("re/lookahead-neg-bad", {"pattern": "^(?!admin$).*$"}, "admin", "I", "ECMA-262 negative lookahead")
case("re/lookahead-pos", {"pattern": "^(?=.*[0-9])(?=.*[a-z]).{8,}$"}, "password1", "V",
     "password-policy lookaheads (very common in real schemas)")
case("re/lookbehind", {"pattern": "(?<=\\$)\\d+"}, "$42", "V", "ECMA-2018 lookbehind")
case("re/backref", {"pattern": "^(a+)-\\1$"}, "aa-aa", "V", "ECMA-262 backreference")
case("re/backref-bad", {"pattern": "^(a+)-\\1$"}, "aa-a", "I", "ECMA-262 backreference")
case("re/w-unicode", {"pattern": "^\\w+$"}, "café", "I", "ECMA \\w is ASCII-only")
case("re/d-unicode", {"pattern": "^\\d+$"}, "١٢", "I", "ECMA \\d is ASCII-only")
case("re/dollar-newline", {"pattern": "^abc$"}, "abc\n", "I", "ECMA $ (no m flag) does not match before \\n")
case("re/dot-newline", {"pattern": "^.$"}, "\n", "I", "ECMA . does not match \\n")
case("re/unanchored", {"pattern": "b"}, "abc", "V", "pattern is unanchored")
case("re/pprops-w", {"patternProperties": {"^\\w+$": {"type": "integer"}}, "additionalProperties": False},
     {"café": 1}, "I", "patternProperties \\w ASCII-only -> falls to additionalProperties:false")
case("re/p-letter", {"pattern": "^\\p{L}+$"}, "café", "V", "Unicode property escape (u-mode)")
case("re/invalid", {"pattern": "["}, "x", None, "invalid regex rejected at compile time")
case("re/ctrl-c", {"pattern": "^\\cJ$"}, "\n", "V", "ECMA \\cJ control escape")

# ---------------------------------------------------------------- arrays
case("arr/minContains0-empty", {"contains": {"const": 1}, "minContains": 0}, [], "V", "minContains 0 -> empty ok")
case("arr/minContains0-maxContains", {"contains": {"const": 1}, "minContains": 0, "maxContains": 1}, [1, 1], "I",
     "maxContains still applies when minContains is 0")
case("arr/d7-tuple-additionalItems", {"items": [{"type": "integer"}], "additionalItems": False}, [1, "x"], "I",
     "draft-07 tuple + additionalItems:false", draft="7")
case("arr/d7-additionalItems-no-items", {"additionalItems": False}, [1, 2], "V",
     "draft-07 additionalItems without array items is ignored", draft="7")
case("arr/2020-prefix-items-false", {"prefixItems": [{"type": "integer"}], "items": False}, [1, 2], "I",
     "2020-12 prefixItems + items:false")
case("arr/d7-ignores-prefixItems", {"prefixItems": [{"type": "string"}]}, [1], "V",
     "prefixItems is not a draft-07 keyword", draft="7")
case("arr/d7-ignores-minContains", {"contains": {"const": 1}, "minContains": 0}, [], "I",
     "minContains is not a draft-07 keyword (contains needs >= 1 match)", draft="7")
case("arr/d7-ignores-unevaluatedItems", {"unevaluatedItems": False}, [1], "V",
     "unevaluatedItems is not a draft-07 keyword", draft="7")
case("arr/2020-ignores-additionalItems", {"items": {"type": "integer"}, "additionalItems": False}, [1, 2], "V",
     "additionalItems is ignored when items is a schema")

# ---------------------------------------------------------------- objects
case("obj/pprops-addl-match", {"patternProperties": {"^x": {}}, "additionalProperties": False}, {"xa": 1}, "V",
     "patternProperties match suppresses additionalProperties")
case("obj/pprops-addl-miss", {"patternProperties": {"^x": {}}, "additionalProperties": False}, {"b": 1}, "I",
     "non-matching key hits additionalProperties:false")
case("obj/propertyNames-empty", {"propertyNames": {"maxLength": 2}}, {}, "V", "propertyNames on empty object")
case("obj/propertyNames-bad", {"propertyNames": {"maxLength": 2}}, {"abc": 1}, "I", "propertyNames applies to all")
case("obj/depReq-absent", {"dependentRequired": {"a": ["b"]}}, {"c": 1}, "V", "trigger key absent")
case("obj/depReq-present", {"dependentRequired": {"a": ["b"]}}, {"a": 1}, "I", "trigger key present")
case("obj/depSchemas-absent", {"dependentSchemas": {"a": {"required": ["b"]}}}, {"c": 1}, "V", "trigger absent")
case("obj/d7-ignores-dependentRequired", {"dependentRequired": {"a": ["b"]}}, {"a": 1}, "V",
     "dependentRequired is not a draft-07 keyword", draft="7")
case("obj/d7-ignores-unevaluatedProperties", {"unevaluatedProperties": False}, {"a": 1}, "V",
     "unevaluatedProperties is not a draft-07 keyword", draft="7")
case("obj/d7-dependencies-empty", {"dependencies": {"a": []}}, {"a": 1}, "V", "empty dependency array", draft="7")
case("obj/d7-dependencies-schema", {"dependencies": {"a": {"required": ["b"]}}}, {"a": 1}, "I",
     "schema dependency", draft="7")
case("obj/props-6-map", {"properties": {k: {"type": "integer"} for k in "abcdefgh"}}, {"h": "x"}, "I",
     ">= 6 properties uses StrIndexMap")

# ---------------------------------------------------------------- $ref / $id / $anchor
case("ref/2020-siblings", {"$defs": {"a": {"type": "integer"}}, "$ref": "#/$defs/a", "minimum": 5}, 3, "I",
     "2020-12: $ref siblings apply")
case("ref/d7-siblings-ignored", {"definitions": {"a": {"type": "integer"}}, "$ref": "#/definitions/a",
                                 "minimum": 5}, 3, "V", "draft-07: $ref siblings ignored", draft="7")
case("ref/ptr-~01", {"$defs": {"~1": {"type": "integer"}, "/": {"type": "string"}}, "$ref": "#/$defs/~01"}, 1, "V",
     "~01 decodes to the key '~1', not '/'")
case("ref/ptr-~01-bad", {"$defs": {"~1": {"type": "integer"}, "/": {"type": "string"}}, "$ref": "#/$defs/~01"}, "s",
     "I", "~01 must not be double-unescaped to '/'")
case("ref/ptr-%25", {"$defs": {"a%b": {"type": "integer"}}, "$ref": "#/$defs/a%25b"}, "x", "I", "%25 -> %")
case("ref/ptr-%20", {"$defs": {"a b": {"type": "integer"}}, "$ref": "#/$defs/a%20b"}, "x", "I", "%20 -> space")
case("ref/ptr-array-index", {"allOf": [{"type": "integer"}], "properties": {"a": {"$ref": "#/allOf/0"}}},
     {"a": "x"}, "I", "pointer into an array")
case("ref/ptr-bool-false", {"$defs": {"f": False}, "$ref": "#/$defs/f"}, 1, "I", "ref to boolean schema")
case("ref/ptr-missing", {"$ref": "#/$defs/nope"}, 1, None, "unresolvable pointer")
case("ref/anchor-before-id", {"$id": "http://e.com/root",
                              "$defs": {"A": {"$anchor": "a", "$id": "http://e.com/inner", "type": "integer"}},
                              "$ref": "http://e.com/inner#a"}, 1, "V",
     "$anchor listed before $id in the same object belongs to the $id resource")
case("ref/anchor-before-id-bad", {"$id": "http://e.com/root",
                                  "$defs": {"A": {"$anchor": "a", "$id": "http://e.com/inner", "type": "integer"}},
                                  "$ref": "http://e.com/inner#a"}, "x", "I", "same, invalid instance")
case("ref/anchor-local-scope", {"$id": "http://e.com/root",
                                "$defs": {"A": {"$id": "inner", "$defs": {"B": {"$anchor": "foo", "type": "string"}},
                                                "$ref": "#foo"},
                                          "foo": {"$anchor": "foo", "type": "integer"}},
                                "$ref": "#/$defs/A"}, "x", "V", "#foo inside 'inner' resolves in inner's scope")
case("ref/ptr-through-embedded-resource", {
    "$id": "http://e.com/root.json",
    "$defs": {"inner": {"$id": "http://e.com/sub/inner.json", "$defs": {"x": {"$ref": "y.json"}}},
              "y": {"$id": "http://e.com/sub/y.json", "type": "integer"},
              "y2": {"$id": "http://e.com/y.json", "type": "string"}},
    "$ref": "#/$defs/inner/$defs/x"}, 1, "V",
    "pointer that crosses into an embedded resource must use that resource's base URI for nested $ref")
case("ref/nested-resource-local-ptr", {"$id": "http://e.com/r",
                                       "$defs": {"a": {"type": "integer"},
                                                 "n": {"$id": "http://e.com/n", "$defs": {"a": {"type": "string"}},
                                                       "$ref": "#/$defs/a"}},
                                       "$ref": "#/$defs/n"}, "x", "V", "#/... inside nested resource is local")
case("ref/id-in-const-ignored", {"$defs": {"c": {"const": {"$id": "http://e.com/fake", "type": "string"}}},
                                 "$ref": "http://e.com/fake"}, 1, None, "$id inside const is data, not a resource")
case("ref/relative-no-base", {"$defs": {"a": {"$id": "a.json", "type": "integer"}}, "$ref": "a.json"}, 1, "V",
     "relative $id/$ref with no base URI")
case("ref/d7-sibling-id", {"$id": "http://e.com/root.json",
                           "definitions": {"x": {"$id": "http://e.com/sub/", "$ref": "t.json"},
                                           "t1": {"$id": "http://e.com/t.json", "type": "integer"},
                                           "t2": {"$id": "http://e.com/sub/t.json", "type": "string"}},
                           "allOf": [{"$ref": "#/definitions/x"}]}, 1, "V",
     "draft-07: $id beside $ref is ignored, so t.json resolves against root", draft="7")
case("ref/d7-anchor-keyword-ignored", {"definitions": {"a": {"$anchor": "foo", "type": "integer"}}, "$ref": "#foo"},
     1, None, "$anchor does not exist in draft-07 (plain-name fragments come from $id)", draft="7")
case("ref/dynamicRef-silently-ignored", {"$defs": {"s": {"$dynamicAnchor": "s", "type": "string"}},
                                         "$dynamicRef": "#s"}, 1, "I",
     "$dynamicRef is unsupported: it must not silently accept everything")
case("ref/recursiveRef-2019", {"$schema": "https://json-schema.org/draft/2019-09/schema", "$recursiveAnchor": True,
                               "type": "object", "properties": {"c": {"$recursiveRef": "#"}}},
     {"c": {"c": 1}}, "I", "2019-09 $recursiveRef silently ignored (auto-detected as 2020-12)", draft="auto")

# ---------------------------------------------------------------- unevaluated* annotations
case("ue/anyOf-failed-branch", {"anyOf": [{"properties": {"a": {"type": "integer"}}},
                                          {"properties": {"b": {"type": "integer"}}, "required": ["c"]}],
                                "unevaluatedProperties": False}, {"a": 1, "b": 2}, "I",
     "failed anyOf branch must not leak annotations")
case("ue/oneOf-single", {"oneOf": [{"properties": {"a": {}}, "required": ["a"]},
                                   {"properties": {"b": {}}, "required": ["b"]}],
                         "unevaluatedProperties": False}, {"a": 1}, "V", "oneOf winner annotates")
case("ue/if-failed", {"if": {"properties": {"a": {"const": 1}}, "required": ["a", "z"]},
                      "else": {"properties": {"b": {}}}, "unevaluatedProperties": False}, {"a": 1, "b": 1}, "I",
     "failed if must not leak")
case("ue/if-ok", {"if": {"properties": {"a": {"const": 1}}}, "then": {"properties": {"b": {}}},
                  "unevaluatedProperties": False}, {"a": 1, "b": 1}, "V", "if + then annotations merge")
case("ue/not-not", {"not": {"not": {"properties": {"a": {}}}}, "unevaluatedProperties": False}, {"a": 1}, "I",
     "not never annotates")
case("ue/depSchemas-absent", {"dependentSchemas": {"x": {"properties": {"a": {}}}}, "unevaluatedProperties": False},
     {"a": 1}, "I", "dependentSchemas only annotates when trigger is present")
case("ue/contains-items", {"contains": {"type": "string"}, "unevaluatedItems": False}, ["a", "b"], "V",
     "contains annotates matched indices")
case("ue/contains-items-bad", {"contains": {"type": "string"}, "unevaluatedItems": False}, ["a", 1], "I",
     "unmatched index is unevaluated")
case("ue/nested-uP-true", {"allOf": [{"properties": {"a": {}}, "unevaluatedProperties": True}],
                           "unevaluatedProperties": False}, {"a": 1, "b": 1}, "V", "nested uP:true evaluates all")
case("ue/prefix-in-allOf", {"allOf": [{"prefixItems": [{}]}], "unevaluatedItems": False}, [1, 2], "I",
     "prefixItems annotation only covers index 0")
case("ue/ref-siblings", {"$defs": {"a": {"properties": {"a": {}}}}, "$ref": "#/$defs/a",
                         "unevaluatedProperties": False}, {"a": 1}, "V", "$ref annotations visible to sibling uP")
case("ue/recursive-ref-anyOf-items", {"$defs": {"n": {"anyOf": [{"type": "array", "items": {"$ref": "#/$defs/n"}},
                                                                 {"type": "integer"}]}},
                                       "$ref": "#/$defs/n", "unevaluatedItems": False}, [1], "V",
     "items inside anyOf inside recursive $ref annotates every index (Rust 0.29.1 says I)")
case("ue/addl-in-allOf", {"allOf": [{"additionalProperties": True}], "unevaluatedProperties": False},
     {"a": 1, "b": 2}, "V", "additionalProperties annotates")

# ---------------------------------------------------------------- depth (fail-open / false negatives)
tree = {"type": "object", "properties": {"c": {"$ref": "#"}}}
case("depth/tree-40", tree, nest_obj(40), "V", "recursive tree 40 levels deep")
case("depth/tree-70", tree, nest_obj(70), "V", "recursive tree 70 levels deep (default max_depth=128 counts 2/level)")
case("depth/tree-200", tree, nest_obj(200), "V", "recursive tree 200 levels deep")
t = {"$defs": {"t": {"type": "array", "items": {"$ref": "#/$defs/t"}}}}
case("depth/not-bypass-30", dict(t, **{"not": {"$ref": "#/$defs/t"}}), nest_arr(30), "I",
     "`not` over a nested-array grammar: 30 levels is correctly rejected")
case("depth/not-bypass-70", dict(t, **{"not": {"$ref": "#/$defs/t"}}), nest_arr(70), "I",
     "FAIL-OPEN: depth cut-off inside `not` turns a rejection into acceptance")
case("depth/anyOf-bypass-70", {"$defs": {"t": {"type": "array", "items": {"$ref": "#/$defs/t"}}},
                               "if": {"$ref": "#/$defs/t"}, "then": False}, nest_arr(70), "I",
     "FAIL-OPEN via if/then:false")
chain = {"$defs": {f"d{i}": {"$ref": f"#/$defs/d{i + 1}"} for i in range(200)}, "$ref": "#/$defs/d0"}
chain["$defs"]["d200"] = {"type": "integer"}
case("depth/ref-chain-200-compile", chain, 1, "V", "200-hop non-recursive $ref chain must compile")
deep_props = {"type": "integer"}
for _ in range(70):
    deep_props = {"properties": {"a": deep_props}}
case("depth/props-nesting-70-compile", deep_props, nest_obj(70, "a"), "V", "70-level nested properties schema")

# ---------------------------------------------------------------- formats (fmt=true)
F = [
    ("date", "2024-02-29", "V"), ("date", "2100-02-29", "I"), ("date", "2000-02-29", "V"), ("date", "2024-13-01", "I"),
    ("date-time", "2024-01-01t00:00:00z", "V"), ("date-time", "1998-12-31T23:59:60Z", "V"),
    ("date-time", "1998-12-31T23:59:60+01:00", "I"), ("date-time", "2024-01-01T00:00:00+24:00", "I"),
    ("date-time", "2024-01-01T00:00:00+23:59", "V"), ("date-time", "2024-01-01 00:00:00Z", "I"),
    ("time", "23:59:60Z", "V"), ("time", "12:00:00", "I"), ("time", "12:00:00.Z", "I"),
    ("ipv4", "01.2.3.4", "I"), ("ipv4", "1.2.3", "I"), ("ipv4", "256.1.1.1", "I"), ("ipv4", "0.0.0.0", "V"),
    ("ipv4", "1.2.3.4\n", "I"), ("ipv4", "١.2.3.4", "I"),
    ("ipv6", "::", "V"), ("ipv6", "::ffff:1.2.3.4", "V"), ("ipv6", "fe80::1%eth0", "I"),
    ("ipv6", "1:2:3:4:5:6:7:8:9", "I"), ("ipv6", "1::2::3", "I"), ("ipv6", ":::", "I"),
    ("ipv6", "1:2:3:4:5:6:7::", "V"), ("ipv6", "::1:2:3:4:5:6:7", "V"), ("ipv6", "1:2:3:4:5:6:7:8", "V"),
    ("ipv6", "::ffff:01.2.3.4", "I"), ("ipv6", "12345::", "I"),
    ("hostname", "a" * 63 + ".com", "V"), ("hostname", "a" * 64 + ".com", "I"),
    ("hostname", ".".join(["a" * 63] * 3 + ["a" * 61]), "V"), ("hostname", ".".join(["a" * 63] * 4), "I"),
    ("hostname", "-a.com", "I"), ("hostname", "a-.com", "I"), ("hostname", "a..b", "I"), ("hostname", "a_b.com", "I"),
    ("email", "a@b.com", "V"), ("email", "\"a b\"@example.com", "V"), ("email", "a@[127.0.0.1]", "V"),
    ("email", "a@[IPv6:::1]", "V"), ("email", "a.@b.com", "I"), ("email", "a..b@c.com", "I"), ("email", "@a.com", "I"),
    ("uri", "http://example.com:abc/", "I"), ("uri", "http://[::1/", "I"), ("uri", "http://a/b?c#d#e", "I"),
    ("uri", "http://example.com/%zz", "I"), ("uri", "urn:isbn:0451450523", "V"), ("uri", "http://[1::2]:80/", "V"),
    ("uri", "http://ex ample.com", "I"), ("uri", "http://[zz]/", "I"),
    ("uuid", "00000000-0000-0000-0000-000000000000", "V"), ("uuid", "{00000000-0000-0000-0000-000000000000}", "I"),
    ("uuid", "2EB8AA08-AA98-11EA-B4AA-73B441D16380", "V"),
    ("json-pointer", "/a~2", "I"), ("json-pointer", "a", "I"), ("json-pointer", "", "V"), ("json-pointer", "/a~", "I"),
    ("regex", "^(?!a)", "V"), ("regex", "(?<=a)b", "V"), ("regex", "\\a", "I"), ("regex", "[", "I"),
    ("regex", "^\\cJ$", "V"),
    ("duration", "P1D", "V"), ("duration", "PT", "I"), ("uri-reference", "\\\\WINDOWS\\share", "I"),
    ("relative-json-pointer", "/a", "I"), ("idn-hostname", "〮실례.테스트", "I"),
    ("iri", "http://é.com/", "V"), ("uri-template", "http://e.com/{", "I"),
]
for i, (f, v, e) in enumerate(F):
    case(f"fmt/{f}/{i}", {"format": f}, v, e, f"format {f}: {v!r}", fmt=True)

sys.stdout.write("\n".join(out) + "\n")
