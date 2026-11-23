"""Hand-written red-team cases for packages/jsonpath (RFC 9535 / 9485 / 6901 / 6902 / 7396 / 8259).

Every case carries an `expect` derived from the RFC text (not from either implementation).
`finding` links a case to a REPORT.md finding id; cases with finding=None are regression
guards that currently pass. `gate=False` marks informational divergences that never fail the run.

Expectation keys (checked by audit.py):
  query   : {"invalid": True} | {"values": [...], "paths": [...]}
  parse   : {"error": True} | {"ok": True} | {"value": v} | {"floats": [...]} (bit-exact)
            | {"text_unique_keys": True}
  pointer : {"error": True} | {"found": False} | {"value": v}
  patch   : {"error": True} (also requires doc_unchanged) | {"value": v}
  merge   : {"value": v}
  diff    : {"roundtrip": True}  (Pion applies its own diff, and Rust json-patch applies Pion's diff)
  eq      : {"equal": bool}
"""
import random
import struct

CASES = []


def case(cid, op, expect, finding=None, gate=True, note="", **fields):
    c = {"id": cid, "op": op}
    c.update(fields)
    CASES.append({"case": c, "expect": expect, "finding": finding, "gate": gate, "note": note})


# ---------------------------------------------------------------------------------------------
# RFC 9535 JSONPath beyond the CTS
# ---------------------------------------------------------------------------------------------
# Duplicate member names: a Normalized Path identifies exactly one node (RFC 9535 §2.7), and
# `$.a` already applies last-wins (json_object_get). Wildcard / descendant / filter / length()
# must agree with that, otherwise one query yields two distinct nodes with the *same* path.
case("jp.dupkey.wildcard", "query", {"values": [2], "paths": ["$['a']"]}, finding="P2-2",
     selector="$.*", document_text='{"a":1,"a":2}')
case("jp.dupkey.descendant", "query", {"values": [{"a": 1, "a": 2}, 2], "paths": ["$['x']", "$['x']['a']"]},
     finding="P2-2", note="document member x contains duplicate key a",
     selector="$..*", document_text='{"x":{"a":1,"a":2}}')
case("jp.dupkey.filter", "query", {"values": [], "paths": []}, finding="P2-2",
     selector="$[?@ == 1]", document_text='{"a":1,"a":2}')
case("jp.dupkey.length", "query", {"values": [{"a": 2}], "paths": ["$[0]"]}, finding="P2-2",
     selector="$[?length(@) == 1]", document_text='[{"a":1,"a":2}]')
case("jp.dupkey.name", "query", {"values": [2], "paths": ["$['a']"]},
     selector="$.a", document_text='{"a":1,"a":2}')

# Normalized Path escaping (RFC 9535 §2.7: normal-escapable / normal-hexchar, lowercase hex)
case("jp.np.escapes", "query",
     {"values": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
      "paths": ["$['\\b']", "$['\\f']", "$['\\n']", "$['\\r']", "$['\\t']", "$['\\'']", "$['\\\\']",
                "$['\\u0000']", "$['\\u001f']", "$['\\u000b']"]},
     selector="$.*",
     document={"\b": 1, "\f": 2, "\n": 3, "\r": 4, "\t": 5, "'": 6, "\\": 7, "\u0000": 8, "\u001f": 9, "\u000b": 10})
case("jp.np.unescaped", "query",
     {"values": [1, 2, 3, 4, 5],
      "paths": ["$['\"']", "$['/']", "$['\u007f']", "$[' ']", "$['\U0001F600']"]},
     selector="$.*", document={"\"": 1, "/": 2, "\u007f": 3, " ": 4, "\U0001F600": 5})

# Strings & escapes in selectors
case("jp.str.surrogate_pair", "query", {"values": [1], "paths": ["$['\U0001F600']"]},
     selector="$['\\uD83D\\uDE00']", document={"\U0001F600": 1})
case("jp.str.lone_high", "query", {"invalid": True}, selector="$['\\uD83D']", document={})
case("jp.str.lone_low", "query", {"invalid": True}, selector="$['\\uDE00']", document={})
case("jp.str.high_then_nonlow", "query", {"invalid": True}, selector="$['\\uD83D\\u0041']", document={})
case("jp.str.solidus", "query", {"values": [1], "paths": ["$['/']"]}, selector="$['\\/']", document={"/": 1})
case("jp.str.dq_in_sq_escaped", "query", {"invalid": True}, selector="$['\\\"']", document={})
case("jp.str.raw_del", "query", {"values": [1], "paths": ["$['\u007f']"]}, selector="$['\u007f']",
     document={"\u007f": 1})

# Integers: I-JSON range, -0, leading zeros
case("jp.int.max_safe", "query", {"values": [], "paths": []}, selector="$[9007199254740991]", document=[1])
case("jp.int.min_safe", "query", {"values": [], "paths": []}, selector="$[-9007199254740991]", document=[1])
case("jp.int.over", "query", {"invalid": True}, selector="$[9007199254740992]", document=[1])
case("jp.int.int64_min", "query", {"invalid": True}, selector="$[-9223372036854775808:0:-1]", document=[1])
case("jp.int.neg_zero_step", "query", {"invalid": True}, selector="$[::-0]", document=[1])
case("jp.slice.extreme_neg_step", "query", {"values": [9], "paths": ["$[9]"]},
     selector="$[9007199254740991:-9007199254740991:-9007199254740991]", document=list(range(10)))
case("jp.slice.extreme_pos", "query", {"values": [0, 1, 2], "paths": ["$[0]", "$[1]", "$[2]"]},
     selector="$[-9007199254740991:9007199254740991]", document=[0, 1, 2])
case("jp.slice.big_step", "query", {"values": [0], "paths": ["$[0]"]},
     selector="$[0:3:9007199254740991]", document=[0, 1, 2])

# Filter comparisons: Nothing / null / deep equality / numbers
case("jp.cmp.nothing_eq_nothing", "query", {"values": [{}], "paths": ["$[0]"]},
     selector="$[?@.x == @.y]", document=[{}])
case("jp.cmp.nothing_ne_null", "query", {"values": [], "paths": []},
     selector="$[?@.x == null]", document=[{}])
case("jp.cmp.nothing_le_nothing", "query", {"values": [{}], "paths": ["$[0]"]},
     selector="$[?@.x <= @.y]", document=[{}])
case("jp.cmp.deep_obj_eq", "query", {"values": [{"a": {"b": [1, {"c": 2}]}, "k": {"b": [1, {"c": 2}]}}], "paths": ["$[0]"]},
     selector="$[?@.a == @.k]", document=[{"a": {"b": [1, {"c": 2}]}, "k": {"b": [1, {"c": 2}]}}])
case("jp.cmp.obj_order_free", "query", {"values": [{"a": {"x": 1, "y": 2}, "b": {"y": 2, "x": 1}}], "paths": ["$[0]"]},
     selector="$[?@.a == @.b]", document=[{"a": {"x": 1, "y": 2}, "b": {"y": 2, "x": 1}}])
case("jp.cmp.arr_order_matters", "query", {"values": [], "paths": []},
     selector="$[?@.a == @.b]", document=[{"a": [1, 2], "b": [2, 1]}])
case("jp.cmp.int_float", "query", {"values": [1], "paths": ["$[0]"]}, selector="$[?@ == 1.0]", document=[1])
case("jp.cmp.neg_zero", "query", {"values": [0], "paths": ["$[0]"]}, selector="$[?@ == -0]", document=[0])
case("jp.cmp.big_int_exact", "query", {"values": [], "paths": []},
     selector="$[?@ == 9007199254740992]", document_text="[9007199254740993]")
case("jp.cmp.big_int_lt", "query", {"values": [9007199254740993], "paths": ["$[0]"]},
     selector="$[?@ > 9007199254740992]", document_text="[9007199254740993]")
case("jp.cmp.int_vs_frac", "query", {"values": [2], "paths": ["$[0]"]}, selector="$[?@ > 1.5]", document=[2])
case("jp.cmp.neg_frac", "query", {"values": [-2], "paths": ["$[0]"]}, selector="$[?@ < -1.5]", document=[-2])
case("jp.cmp.str_unicode_order", "query", {"values": ["\U0001F600"], "paths": ["$[0]"]},
     selector="$[?@ > '￿']", document=["\U0001F600"])
case("jp.cmp.bool_lt", "query", {"values": [], "paths": []}, selector="$[?@ < true]", document=[False])

# length(): Unicode scalar values
case("jp.fn.length_scalars", "query", {"values": ["aé中\U0001F600"], "paths": ["$[0]"]},
     selector="$[?length(@) == 4]", document=["aé中\U0001F600"])
case("jp.fn.value_multi", "query", {"values": [], "paths": []},
     selector="$[?value(@..x) == 1]", document=[{"x": 1, "y": {"x": 1}}])
case("jp.fn.count_desc", "query", {"values": [{"a": [1, 2]}], "paths": ["$[0]"]},
     selector="$[?count(@..*) == 3]", document=[{"a": [1, 2]}])

# RFC 9485 I-Regexp
case("ire.dot_cr", "query", {"values": [], "paths": []}, selector="$[?match(@, '.')]", document=["\r"])
case("ire.dot_lf", "query", {"values": [], "paths": []}, selector="$[?match(@, '.')]", document=["\n"])
case("ire.dot_astral", "query", {"values": ["\U0001F600"], "paths": ["$[0]"]},
     selector="$[?match(@, '.')]", document=["\U0001F600"])
case("ire.dot_u2028", "query", {"values": [" "], "paths": ["$[0]"]},
     selector="$[?match(@, '.')]", document=[" "])
case("ire.multibyte_quant", "query", {"values": ["éé"], "paths": ["$[0]"]},
     selector="$[?match(@, 'é+')]", document=["éé", "é©"])
case("ire.multibyte_class", "query", {"values": ["é"], "paths": ["$[0]"]},
     selector="$[?match(@, '[à-ü]')]", document=["é", "a"])
case("ire.neg_class_multibyte", "query", {"values": ["é"], "paths": ["$[0]"]},
     selector="$[?match(@, '[^a]')]", document=["é", "a"])
case("ire.p_Lu", "query", {"values": ["É"], "paths": ["$[0]"]},
     selector="$[?match(@, '\\\\p{Lu}')]", document=["É", "é"])
case("ire.P_L", "query", {"values": ["1"], "paths": ["$[0]"]},
     selector="$[?match(@, '\\\\P{L}')]", document=["1", "x"])
case("ire.p_in_class", "query", {"values": ["5", "x"], "paths": ["$[0]", "$[1]"]},
     selector="$[?match(@, '[\\\\p{Nd}x]')]", document=["5", "x", "-"])
case("ire.invalid_cat", "query", {"values": [], "paths": []},
     selector="$[?match(@, '\\\\p{IsGreek}')]", document=["α"])
case("ire.invalid_Cs", "query", {"values": [], "paths": []},
     selector="$[?match(@, '\\\\p{Cs}')]", document=["a"])
case("ire.invalid_d", "query", {"values": [], "paths": []},
     selector="$[?match(@, '\\\\d')]", document=["1"])
case("ire.invalid_backref", "query", {"values": [], "paths": []},
     selector="$[?match(@, '(a)\\\\1')]", document=["aa"])
case("ire.invalid_lazy", "query", {"values": [], "paths": []},
     selector="$[?match(@, 'a*?')]", document=["a"])
case("ire.invalid_lookahead", "query", {"values": [], "paths": []},
     selector="$[?search(@, '(?=a)')]", document=["a"])
case("ire.invalid_range_rev", "query", {"values": [], "paths": []},
     selector="$[?match(@, 'a{2,1}')]", document=["a"])
case("ire.dynamic_invalid", "query", {"values": [], "paths": []},
     selector="$[?match(@.s, @.p)]", document=[{"s": "a", "p": "("}])
case("ire.dynamic_valid", "query", {"values": [{"s": "ab", "p": "a."}], "paths": ["$[0]"]},
     selector="$[?match(@.s, @.p)]", document=[{"s": "ab", "p": "a."}])
case("ire.search_unanchored", "query", {"values": ["xaby"], "paths": ["$[0]"]},
     selector="$[?search(@, 'ab')]", document=["xaby"])

# Whitespace grammar
case("jp.ws.between_segments", "query", {"values": [1], "paths": ["$['a']"]}, selector="$ .a", document={"a": 1})
case("jp.ws.after_dot", "query", {"invalid": True}, selector="$. a", document={"a": 1})
case("jp.ws.trailing", "query", {"invalid": True}, selector="$.a ", document={"a": 1})
case("jp.ws.fn_name_paren", "query", {"invalid": True}, selector="$[?length (@) == 1]", document=["a"])

# ---------------------------------------------------------------------------------------------
# RFC 8259 parse / serialize / number fidelity
# ---------------------------------------------------------------------------------------------
case("json.int64_max", "parse", {"value": 9223372036854775807}, text="9223372036854775807")
case("json.int64_min", "parse", {"value": -9223372036854775808}, text="-9223372036854775808")
case("json.u64_max", "parse", {"value": 18446744073709551615}, finding="P2-3",
     note="integers beyond Int64 silently collapse to Double", text="18446744073709551615")
case("json.int64_max_plus1", "parse", {"value": 9223372036854775808}, finding="P2-3",
     text="9223372036854775808")
case("json.float_special", "parse",
     {"floats": [0.30000000000000004, 1.7976931348623157e308, 5e-324, 2.2250738585072014e-308,
                 2.225073858507201e-308, 0.1, 1e21, 1e-7, 123456789.123456789]},
     text="[0.30000000000000004,1.7976931348623157e308,5e-324,2.2250738585072014e-308,"
          "2.225073858507201e-308,0.1,1e21,1e-7,123456789.123456789]")
_HALFWAY = ["1.00000000000000011102230246251565404236316680908203125",
            "1.00000000000000011102230246251565404236316680908203126",
            "9007199254740993.0", "9007199254740995.0", "2.4703282292062327e-324", "2.4703282292062328e-324"]
case("json.float_halfway", "parse", {"floats": [float(x) for x in _HALFWAY]},
     note="correct rounding (ties-to-even) of exact halfway decimal inputs", text="[" + ",".join(_HALFWAY) + "]")
case("json.neg_zero", "parse", {"floats": [-0.0, -0.0]}, text="[-0,-0.0]")
case("json.overflow", "parse", {"error": True}, text="1e400")
case("json.lone_high", "parse", {"error": True}, text='"\\ud800"')
case("json.lone_low", "parse", {"error": True}, text='"\\udc00"')
case("json.pair", "parse", {"value": "\U0001F600"}, text='"\\ud83d\\ude00"')
case("json.ctrl_raw", "parse", {"error": True}, text='"a\tb"')
case("json.trailing_garbage", "parse", {"error": True}, text="[1] x")
case("json.trailing_comma", "parse", {"error": True}, text="[1,]")
case("json.leading_zero", "parse", {"error": True}, text="012")
case("json.bare_dot", "parse", {"error": True}, text="1.")
case("json.plus", "parse", {"error": True}, text="+1")
case("json.nbsp_ws", "parse", {"error": True}, text=" 1")
case("json.bom", "parse", {"error": True}, text="﻿1")
case("json.nul_escape", "parse", {"value": "a\u0000b"}, text='"a\\u0000b"')
case("json.depth128_ok", "parse", {"ok": True}, text="[" * 128 + "]" * 128)
case("json.depth129_limit", "parse", {"error": True}, text="[" * 129 + "]" * 129)
case("json.dupkey_serialize", "parse", {"text_unique_keys": True}, finding="P2-2", gate=True,
     note="to_json_string emits duplicate member names", text='{"a":1,"a":2}')

# deterministic random double round-trip (parse is correctly rounded + serializer is lossless)
_rng = random.Random(9535)
_floats = []
for _ in range(1500):
    bits = _rng.getrandbits(64)
    f = struct.unpack("<d", struct.pack("<Q", bits))[0]
    if f != f or f in (float("inf"), float("-inf")):
        continue
    _floats.append(f)
for _ in range(500):
    _floats.append(_rng.uniform(-1e6, 1e6))
case("json.random_doubles", "parse", {"floats": _floats},
     text="[" + ",".join(repr(f) for f in _floats) + "]")

# ---------------------------------------------------------------------------------------------
# RFC 6901 JSON Pointer
# ---------------------------------------------------------------------------------------------
PDOC = {"foo": ["bar", "baz"], "": 0, "a/b": 1, "c%d": 2, "e^f": 3, "g|h": 4, "i\\j": 5,
        "k\"l": 6, " ": 7, "m~n": 8, "~1": 9, "01": 10, "-": 11}
for ptr, val in [("", PDOC), ("/foo", ["bar", "baz"]), ("/foo/0", "bar"), ("/", 0), ("/a~1b", 1),
                 ("/c%d", 2), ("/e^f", 3), ("/g|h", 4), ("/i\\j", 5), ("/k\"l", 6), ("/ ", 7),
                 ("/m~0n", 8), ("/~01", 9), ("/01", 10), ("/-", 11)]:
    case("ptr.rfc6901." + ptr, "pointer", {"value": val}, pointer=ptr, document=PDOC)
for ptr in ["/foo/01", "/foo/-", "/foo/-0", "/foo/+1", "/foo/2", "/foo/ 1", "/foo/1e0",
            "/foo/18446744073709551616", "/foo/4294967296", "/foo/2147483648", "/foo/-1", "/nope"]:
    case("ptr.missing." + ptr, "pointer", {"found": False}, pointer=ptr, document=PDOC)
for ptr in ["foo", "/~2", "/a~", "/~", "#/foo"]:
    case("ptr.invalid." + ptr, "pointer", {"error": True}, pointer=ptr, document=PDOC)

# ---------------------------------------------------------------------------------------------
# RFC 6902 JSON Patch
# ---------------------------------------------------------------------------------------------
def patch(cid, doc, ops, expect, **kw):
    case("patch." + cid, "patch", expect, document=doc, patch=ops, **kw)


patch("add_obj", {"a": 1}, [{"op": "add", "path": "/b", "value": 2}], {"value": {"a": 1, "b": 2}})
patch("add_replaces", {"a": 1}, [{"op": "add", "path": "/a", "value": 2}], {"value": {"a": 2}})
patch("add_arr_insert", [1, 3], [{"op": "add", "path": "/1", "value": 2}], {"value": [1, 2, 3]})
patch("add_arr_end", [1], [{"op": "add", "path": "/1", "value": 2}], {"value": [1, 2]})
patch("add_arr_dash", [1], [{"op": "add", "path": "/-", "value": 2}], {"value": [1, 2]})
patch("add_arr_oob", [1], [{"op": "add", "path": "/2", "value": 2}], {"error": True})
patch("add_arr_leading_zero", [1, 2], [{"op": "add", "path": "/01", "value": 9}], {"error": True})
patch("add_root", {"a": 1}, [{"op": "add", "path": "", "value": [9]}], {"value": [9]})
patch("add_missing_parent", {}, [{"op": "add", "path": "/a/b", "value": 1}], {"error": True})
patch("add_null_value", {}, [{"op": "add", "path": "/a", "value": None}], {"value": {"a": None}})
patch("add_missing_value", {}, [{"op": "add", "path": "/a"}], {"error": True})
patch("add_dash_nonlast", [[1]], [{"op": "add", "path": "/-/0", "value": 2}], {"error": True})
patch("remove_obj", {"a": 1, "b": 2}, [{"op": "remove", "path": "/a"}], {"value": {"b": 2}})
patch("remove_arr", [1, 2, 3], [{"op": "remove", "path": "/1"}], {"value": [1, 3]})
patch("remove_missing", {"a": 1}, [{"op": "remove", "path": "/b"}], {"error": True})
patch("remove_dash", [1], [{"op": "remove", "path": "/-"}], {"error": True})
patch("replace_root", {"a": 1}, [{"op": "replace", "path": "", "value": 7}], {"value": 7})
patch("replace_missing", {"a": 1}, [{"op": "replace", "path": "/b", "value": 7}], {"error": True})
patch("move_into_child", {"a": {"b": 1}}, [{"op": "move", "from": "/a", "path": "/a/b/c"}], {"error": True})
patch("move_into_child2", {"a": {"b": 1}}, [{"op": "move", "from": "/a", "path": "/a/x"}], {"error": True})
patch("move_root_into_child", {"a": 1}, [{"op": "move", "from": "", "path": "/a"}], {"error": True})
patch("move_same", {"a": 1}, [{"op": "move", "from": "/a", "path": "/a"}], {"value": {"a": 1}})
patch("move_sibling_prefix", {"a": 1, "ab": 2}, [{"op": "move", "from": "/a", "path": "/ab"}], {"value": {"ab": 1}})
patch("move_arr", [1, 2, 3], [{"op": "move", "from": "/0", "path": "/2"}], {"value": [2, 3, 1]})
patch("move_missing", {"a": 1}, [{"op": "move", "from": "/x", "path": "/y"}], {"error": True})
patch("copy_into_self_child", {"a": {"b": 1}}, [{"op": "copy", "from": "/a", "path": "/a/c"}],
      {"value": {"a": {"b": 1, "c": {"b": 1}}}})
patch("copy_missing", {"a": 1}, [{"op": "copy", "from": "/x", "path": "/y"}], {"error": True})
patch("test_ok", {"a": [1, {"b": "c"}]}, [{"op": "test", "path": "/a", "value": [1, {"b": "c"}]}],
      {"value": {"a": [1, {"b": "c"}]}})
patch("test_int_float", {"a": 1}, [{"op": "test", "path": "/a", "value": 1.0}], {"value": {"a": 1}},
      note="RFC 6902 §4.6: numbers are equal if their values are numerically equal")
patch("test_neg_zero", {"a": 0}, [{"op": "test", "path": "/a", "value": -0.0}], {"value": {"a": 0}})
patch("test_2p53", {}, [{"op": "test", "path": "/a", "value": 0}], {"error": True},
      document_text='{"a":9007199254740993}', patch_text='[{"op":"test","path":"/a","value":9007199254740992}]')
patch("test_u64_distinct", {}, [], {"error": True}, finding="P2-3",
      note="18446744073709551615 and 18446744073709551614 are distinct numbers",
      document_text='{"a":18446744073709551615}',
      patch_text='[{"op":"test","path":"/a","value":18446744073709551614}]')
patch("test_obj_order", {"a": {"x": 1, "y": 2}}, [{"op": "test", "path": "/a", "value": {"y": 2, "x": 1}}],
      {"value": {"a": {"x": 1, "y": 2}}})
patch("test_arr_order", {"a": [1, 2]}, [{"op": "test", "path": "/a", "value": [2, 1]}], {"error": True})
patch("test_type", {"a": "1"}, [{"op": "test", "path": "/a", "value": 1}], {"error": True})
patch("test_missing", {"a": 1}, [{"op": "test", "path": "/b", "value": None}], {"error": True})
patch("atomic_rollback", {"a": 1},
      [{"op": "add", "path": "/b", "value": 2}, {"op": "remove", "path": "/a"},
       {"op": "test", "path": "/b", "value": 3}], {"error": True})
patch("unknown_op", {}, [{"op": "frob", "path": "/a"}], {"error": True})
patch("bad_path", {}, [{"op": "add", "path": "a", "value": 1}], {"error": True})
patch("not_array", {}, {"op": "add", "path": "/a", "value": 1}, {"error": True})
patch("special_keys", {"a/b": {"~": {"": 1}}},
      [{"op": "replace", "path": "/a~1b/~0/", "value": 2}], {"value": {"a/b": {"~": {"": 2}}}})

# diff_patch round trips (Pion apply of its own diff, and Rust json-patch apply of Pion's diff)
DIFFS = [
    ("special_keys", {"a/b": 1, "~": 2, "": 3, "~1": 4, "x": {"/": [1]}},
     {"a/b": 2, "": {"~0": 5}, "~1": 4, "x": {"/": [1, 2]}, "new/~": None}),
    ("array_insert_mid", [1, 2, 3, 4], [1, 9, 8, 2, 3, 4]),
    ("array_remove_mid", [1, 2, 3, 4, 5], [1, 5]),
    ("array_mixed", [{"a": 1}, [1, 2], "x", 3], [[1], {"a": 2}, "x", 3, 4]),
    ("array_nested", [[1, [2, [3, [4]]]]], [[1, [2, [3, [4, 5]], 6]]]),
    ("type_change", {"a": [1]}, {"a": {"0": 1}}),
    ("root_scalar", 1, "x"),
    ("root_array_to_obj", [1], {"a": 1}),
    ("empty_to_full", {}, {"a": [], "b": {}, "c": None}),
    ("rotate", [1, 2, 3, 4, 5], [5, 1, 2, 3, 4]),
    ("unicode_keys", {"é": 1, "\U0001F600": [1]}, {"é": 2, "\U0001F600": [1, {"中": 3}]}),
]
for cid, b, a in DIFFS:
    case("diff." + cid, "diff", {"roundtrip": True}, before=b, after=a)

# ---------------------------------------------------------------------------------------------
# RFC 7396 JSON Merge Patch (Appendix A + adversarial)
# ---------------------------------------------------------------------------------------------
MERGES = [
    ({"a": "b"}, {"a": "c"}, {"a": "c"}),
    ({"a": "b"}, {"b": "c"}, {"a": "b", "b": "c"}),
    ({"a": "b"}, {"a": None}, {}),
    ({"a": "b", "b": "c"}, {"a": None}, {"b": "c"}),
    ({"a": ["b"]}, {"a": "c"}, {"a": "c"}),
    ({"a": "c"}, {"a": ["b"]}, {"a": ["b"]}),
    ({"a": {"b": "c"}}, {"a": {"b": "d", "c": None}}, {"a": {"b": "d"}}),
    ({"a": [{"b": "c"}]}, {"a": [1]}, {"a": [1]}),
    (["a", "b"], ["c", "d"], ["c", "d"]),
    ({"a": "b"}, ["c"], ["c"]),
    ({"a": "foo"}, None, None),
    ({"a": "foo"}, "bar", "bar"),
    ({"e": None}, {"a": 1}, {"e": None, "a": 1}),
    ([1, 2], {"a": "b", "c": None}, {"a": "b"}),
    ({}, {"a": {"bb": {"ccc": None}}}, {"a": {"bb": {}}}),
    ("scalar", {"a": {"b": None, "c": [None]}}, {"a": {"c": [None]}}),
    ({"a": [1, {"x": 1}]}, {"a": [{"x": None}]}, {"a": [{"x": None}]}),
    ({"a": {"b": 1}}, {"a": {"b": {"c": None}}}, {"a": {"b": {}}}),
]
for i, (t, p, r) in enumerate(MERGES):
    case("merge.%02d" % i, "merge", {"value": r}, target=t, patch=p)

# Structural equality (json_value_eq)
case("eq.int_float", "eq", {"equal": True}, a=1, b=1.0)
case("eq.zero_negzero", "eq", {"equal": True}, a=0, b=-0.0)
case("eq.obj_order", "eq", {"equal": True}, a={"x": 1, "y": [1]}, b={"y": [1], "x": 1})
case("eq.int64_vs_double_edge", "eq", {"equal": False}, a_text="9223372036854775807", b_text="9223372036854775808.0")
case("eq.u64_distinct", "eq", {"equal": False}, finding="P2-3",
     a_text="18446744073709551615", b_text="18446744073709551614")
