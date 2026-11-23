#!/usr/bin/env python3
"""Targeted differential vectors: Pion packages/protobuf vs Go protobuf v1.36.6 (+ protocompile) vs Rust prost 0.13.5.

usage: diff_vectors.py <pion_probe> <go_oracle> <rust_oracle> <workdir>

Sections
  A. wire: varint / tag / top-level field skipping (3-way)
  B. dyn:  decode_dynamic + to_proto3_json + encode_dynamic vs dynamicpb + protojson + Marshal
           (encoding is compared semantically: Go re-canonicalises Pion's bytes)
  C. schema: .proto accept/reject + field-number summary vs protocompile
Every DIFF row is evidence; the verdict column names the class. Exit code is always 0.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pbvec import *  # noqa: E402,F401,F403

PION = GO = RUST = WORK = None  # set in __main__ (the vector tables are importable by fuzz_diff.py)
H = lambda b: b.hex()  # noqa: E731

# ---------------------------------------------------------------------------------------------
# A. wire
# ---------------------------------------------------------------------------------------------
VARINTS = [
    ("0", "00"), ("1", "01"), ("127", "7f"), ("128", "8001"), ("u32max", H(varint(0xFFFFFFFF))),
    ("i32min_10B", H(varint(-(2**31)))), ("i32min_5B_trunc", "8080808008"), ("i64min", H(varint(-(2**63)))),
    ("i64max", H(varint(2**63 - 1))), ("u64max", H(varint(2**64 - 1))),
    ("10B_last_02", "ffffffffffffffffff02"), ("10B_last_7f", "ffffffffffffffffff7f"),
    ("11B", "ffffffffffffffffff8001"), ("10B_zero_nonminimal", "80808080808080808000"),
    ("nonminimal_1", "8100"), ("trunc_80", "80"), ("trunc_9B", "ffffffffffffffffff"),
]
TAGS = [
    ("f1_varint", "08"), ("f0", "00"), ("f0_wt2", "02"), ("wt6", "0e"), ("wt7", "0f"),
    ("f2^29-1", H(tag(2**29 - 1, 0))), ("f2^29", H(tag(2**29, 0))), ("f19000", H(tag(19000, 2))),
    ("f19999", H(tag(19999, 0))), ("tag_bit35", H(varint(1 << 35))), ("tag_u32max", H(varint(0xFFFFFFFF))),
    ("tag_u32max+8", H(varint(0xFFFFFFFF + 8))), ("tag_endgroup", "0c"), ("tag_nonminimal", "8800"),
    ("tag_10B", "88808080808080808000"),
]


def groups(n, fn=1):
    return tag(fn, 3) * n + tag(fn, 4) * n


WIRE = [
    ("empty_packed", H(ld(1, b""))),
    ("group_simple", H(tag(1, 3) + vi(2, 5) + tag(1, 4))),
    ("group_nested_3", H(groups(3))),
    ("group_depth_99", H(groups(99))), ("group_depth_100", H(groups(100))), ("group_depth_101", H(groups(101))),
    ("group_mismatch_end", H(tag(1, 3) + tag(2, 4))),
    ("orphan_endgroup", H(tag(1, 4))),
    ("unclosed_group", H(tag(1, 3) + vi(2, 1))),
    ("group_in_ld_trunc", H(ld(1, tag(2, 3) + vi(3, 1)) + tag(2, 4))),
    ("len_overflow", "0affffffff0f"), ("len_u64max", "0a" + H(varint(2**64 - 1))),
    ("fixed32_trunc", "0d010203"), ("fixed64_trunc", "0901020304050607"),
    ("field19000_skip", H(vi(19000, 1))),
    ("wt6_in_group", H(tag(1, 3) + "".encode() + bytes([0x16]) + tag(1, 4))),
]


def wire_section():
    rows = []
    for mode, vecs in (("varint", VARINTS), ("tag", TAGS), ("wire", WIRE)):
        hexes = [h for _, h in vecs]
        p, _ = run_lines([PION, mode], hexes, WORK, "w_pion_" + mode)
        g, _ = run_lines([GO, mode], hexes, WORK, "w_go_" + mode)
        r, _ = run_lines([RUST, mode], hexes, WORK, "w_rust_" + mode)
        for i, (name, h) in enumerate(vecs):
            pv, gv, rv = (x[i] if i < len(x) else "<crash>" for x in (p, g, r))
            ok = lambda s: s.split(" ")[0] == "OK"  # noqa: E731
            pk = pv if ok(pv) else "ERR"
            gk = gv if ok(gv) else "ERR"
            rk = rv if ok(rv) else "ERR"
            if pk == gk == rk:
                verdict = "SAME"
            elif pk == gk:
                verdict = "pion=go!=rust"
            elif pk == rk:
                verdict = "pion=rust!=go"
            elif gk == rk:
                verdict = "DIFF pion!=go=rust"
            else:
                verdict = "all differ"
            rows.append((mode + ":" + name, verdict, pv, gv, rv))
    print("## A. Wire format (Pion vs Go protowire vs Rust prost)\n")
    print("| vector | verdict | pion | go | rust |\n|---|---|---|---|---|")
    for name, v, pv, gv, rv in rows:
        print("| `%s` | %s | %s | %s | %s |" % (name, v, pv[:60], gv[:60], rv[:60]))
    print()
    return rows


# ---------------------------------------------------------------------------------------------
# B. dynamic decode / JSON / re-encode
# ---------------------------------------------------------------------------------------------
S_SCALARS = """syntax = "proto3";
message M {
  double d = 1; float f = 2; int32 i32 = 3; int64 i64 = 4; uint32 u32 = 5; uint64 u64 = 6;
  sint32 s32 = 7; sint64 s64 = 8; fixed32 fx32 = 9; fixed64 fx64 = 10; sfixed32 sf32 = 11;
  sfixed64 sf64 = 12; bool b = 13; string s = 14; bytes by = 15; E e = 16;
  repeated int32 ri = 17; repeated string rs = 18; repeated E re = 19; repeated sint64 rs64 = 20;
  repeated float rf = 21; repeated fixed64 rfx = 22;
}
enum E { E_ZERO = 0; E_ONE = 1; E_NEG = -1; }
"""
S_MAPS = """syntax = "proto3";
message V { int32 x = 1; int32 y = 2; }
enum Color { RED = 0; GREEN = 1; }
message M {
  map<string, int32> si = 1; map<int64, string> is = 2; map<bool, bool> bb = 3;
  map<uint64, V> uv = 4; map<sint32, Color> sc = 5; map<fixed32, bytes> fb = 6; map<int32, double> id = 7;
}
"""
S_ONEOF = """syntax = "proto3";
message Sub { int32 x = 1; int32 y = 2; repeated int32 r = 3; }
message M {
  oneof o { int32 a = 1; string b = 2; Sub s = 3; bool c = 4; }
  optional int32 oi = 5; optional string os = 6; optional Sub osub = 7;
  Sub sub = 8; repeated Sub subs = 9;
}
"""
S_P2 = """syntax = "proto2";
enum E { A = 0; B = 1; }
message M {
  optional int32 a = 1 [default = 42]; optional string s = 2; optional E e = 3; optional bool b = 4;
  repeated int32 r = 5; repeated int32 rp = 6 [packed = true]; optional bytes by = 7;
}
message R { required int32 a = 1; optional int32 b = 2; }
"""
S_SCOPE = """syntax = "proto3";
package scope.v1;
message A { message Item { int32 x = 1; } Item a = 1; }
message B { message Item { string name = 1; } message C { Item item = 1; } C c = 1; Item i = 2; }
message Other { enum Status { UNKNOWN = 0; OK = 1; } Status s = 1; }
message Holder { message Status { int32 code = 1; } Status status = 1; }
message Q { .scope.v1.B.Item fq = 1; B.Item rel = 2; }
"""
S_JSONNAME = """syntax = "proto3";
message M { int32 foo_bar_baz = 1; int32 _foo = 2; int32 foo__bar = 3; int32 foo_1bar = 4;
  int32 x = 5 [json_name = "my-X"]; int32 FooBar = 6; int32 a_b_C = 7; }
"""
S_WKT = """syntax = "proto3";
import "google/protobuf/timestamp.proto";
import "google/protobuf/wrappers.proto";
import "google/protobuf/struct.proto";
message M { google.protobuf.Timestamp ts = 1; google.protobuf.Int64Value w = 2; google.protobuf.Struct st = 3; int32 x = 4; }
"""
S_NODE = 'syntax = "proto3"; message Node { Node child = 1; int32 v = 2; }'

DYN = []  # (id, schema, msg, hex)


def d(id_, schema, msg, b):
    DYN.append((id_, schema, msg, b.hex() if isinstance(b, (bytes, bytearray)) else b))


# scalars / varint semantics
d("bool_2", S_SCALARS, "M", vi(13, 2))
d("bool_high_bits", S_SCALARS, "M", vi(13, 1 << 32))
d("int32_from_u64_high", S_SCALARS, "M", vi(3, 1 << 32))
d("int32_neg_10B", S_SCALARS, "M", vi(3, -1))
d("int32_neg_5B", S_SCALARS, "M", "18ffffffff0f")
d("uint32_from_neg", S_SCALARS, "M", vi(5, -1))
d("sint32_high_bits", S_SCALARS, "M", vi(7, (1 << 40) | 3))
d("int64_extremes", S_SCALARS, "M", vi(4, -(2**63)) + vi(6, 2**64 - 1) + vi(8, zz(-(2**63))) + f64bits(10, 2**64 - 1) + f64bits(12, 2**63))
d("enum_negative", S_SCALARS, "M", vi(16, -1))
d("enum_unknown_open", S_SCALARS, "M", vi(16, 77))
d("enum_repeated_unknown", S_SCALARS, "M", ld(19, varint(1) + varint(99) + varint(-1)))
d("double_0.1+0.2", S_SCALARS, "M", f64(1, 0.1 + 0.2))
d("double_1e-300", S_SCALARS, "M", f64(1, 1e-300))
d("double_max", S_SCALARS, "M", f64(1, 1.7976931348623157e308))
d("double_min_subnormal", S_SCALARS, "M", f64bits(1, 1))
d("double_1e20", S_SCALARS, "M", f64(1, 1e20))
d("double_1e21", S_SCALARS, "M", f64(1, 1e21))
d("double_1e-7", S_SCALARS, "M", f64(1, 1e-7))
d("double_123456.789", S_SCALARS, "M", f64(1, 123456.789))
d("double_neg_zero", S_SCALARS, "M", f64bits(1, 1 << 63))
d("double_nan", S_SCALARS, "M", f64bits(1, 0x7FF8000000000000))
d("double_snan", S_SCALARS, "M", f64bits(1, 0x7FF0000000000001))
d("double_neg_inf", S_SCALARS, "M", f64bits(1, 0xFFF0000000000000))
d("float_0.1", S_SCALARS, "M", f32(2, 0.1))
d("float_max", S_SCALARS, "M", f32bits(2, 0x7F7FFFFF))
d("float_min_subnormal", S_SCALARS, "M", f32bits(2, 1))
d("float_neg_zero", S_SCALARS, "M", f32bits(2, 0x80000000))
d("float_snan_bits", S_SCALARS, "M", f32bits(2, 0x7F800001))
d("float_16777217", S_SCALARS, "M", f32(2, 16777216.0))
d("rep_float_bits", S_SCALARS, "M", ld(21, bytes.fromhex("0000008001000000010080 7f0100c07f".replace(" ", ""))))
d("string_ctrl", S_SCALARS, "M", ld(14, bytes(range(0, 32)) + b'"\\/\x7f'))
d("string_u2028_emoji_cjk", S_SCALARS, "M", ld(14, "  <>&\U0001F600中文".encode()))
d("string_bad_utf8", S_SCALARS, "M", ld(14, b"\xe9"))
d("string_surrogate", S_SCALARS, "M", ld(14, b"\xed\xa0\x80"))
d("string_overlong", S_SCALARS, "M", ld(14, b"\xc0\xaf"))
d("bytes_0..4", S_SCALARS, "M", ld(15, b"") )
d("bytes_1", S_SCALARS, "M", ld(15, b"\xff"))
d("bytes_2", S_SCALARS, "M", ld(15, b"\xff\xfe"))
d("bytes_3", S_SCALARS, "M", ld(15, b"\xff\xfe\xfd"))
d("bytes_4", S_SCALARS, "M", ld(15, b"\x00\x01\x02\x03"))
d("implicit_zero_on_wire", S_SCALARS, "M", vi(3, 0) + ld(14, b"") + f64(1, 0.0))
# packed / repeated
d("packed_empty", S_SCALARS, "M", ld(17, b""))
d("packed_trunc_varint", S_SCALARS, "M", ld(17, b"\x01\x80"))
d("packed_fixed64_bad_len", S_SCALARS, "M", ld(22, b"\x01\x02\x03"))
d("packed_float_bad_len", S_SCALARS, "M", ld(21, b"\x01\x02\x03\x04\x05"))
d("packed_unpacked_mix", S_SCALARS, "M", ld(17, b"\x01\x02") + vi(17, 3) + ld(17, b"") + ld(17, b"\x04"))
d("packed_sint64", S_SCALARS, "M", ld(20, varint(zz(-1)) + varint(zz(2**63 - 1)) + varint(zz(-(2**63)))))
d("repeated_string_as_ld", S_SCALARS, "M", ld(18, b"a") + ld(18, b"b"))
d("wt_mismatch_to_unknown", S_SCALARS, "M", f32bits(3, 7) + vi(3, 5))
d("wt_mismatch_string_as_varint", S_SCALARS, "M", vi(14, 1))
d("unknown_all_types", S_SCALARS, "M", vi(100, 1) + f32bits(101, 2) + f64bits(102, 3) + ld(103, b"xyz") + tag(104, 3) + vi(1, 9) + tag(104, 4))
d("unknown_group_mismatch", S_SCALARS, "M", tag(104, 3) + tag(105, 4))
d("unknown_reserved_19000", S_SCALARS, "M", vi(19000, 1))
d("orphan_endgroup_top", S_SCALARS, "M", tag(3, 4))
d("trailing_garbage_len", S_SCALARS, "M", "7a05616263")
# maps
d("map_dup_key", S_MAPS, "M", ld(1, ld(1, "k") + vi(2, 1)) + ld(1, ld(1, "k") + vi(2, 2)))
d("map_empty_entry", S_MAPS, "M", ld(2, b""))
d("map_value_before_key", S_MAPS, "M", ld(2, ld(2, "v") + vi(1, 7)))
d("map_dup_key_inside_entry", S_MAPS, "M", ld(1, ld(1, "a") + ld(1, "b") + vi(2, 5)))
d("map_bool_keys", S_MAPS, "M", ld(3, vi(1, 1) + vi(2, 1)) + ld(3, vi(1, 0) + vi(2, 0)))
d("map_int64_neg_key", S_MAPS, "M", ld(2, vi(1, -5) + ld(2, "x")))
d("map_msg_value_merge?", S_MAPS, "M", ld(4, vi(1, 1) + ld(2, vi(1, 1))) + ld(4, vi(1, 1) + ld(2, vi(2, 2))))
d("map_msg_value_twice_in_entry", S_MAPS, "M", ld(4, vi(1, 1) + ld(2, vi(1, 1)) + ld(2, vi(2, 2))))
d("map_enum_value", S_MAPS, "M", ld(5, vi(1, zz(-3)) + vi(2, 1)) + ld(5, vi(1, 4) + vi(2, 9)))
d("map_fixed32_bytes", S_MAPS, "M", ld(6, f32bits(1, 0xFFFFFFFF) + ld(2, b"\x00")))
d("map_value_wrong_wt", S_MAPS, "M", ld(1, ld(1, "k") + f32bits(2, 7)))
d("map_key_wrong_wt", S_MAPS, "M", ld(1, vi(1, 3) + vi(2, 7)))
d("map_unknown_field_in_entry", S_MAPS, "M", ld(1, ld(1, "k") + vi(3, 1) + vi(2, 7)))
d("map_key_bad_utf8", S_MAPS, "M", ld(1, ld(1, b"\xff") + vi(2, 7)))
d("map_order", S_MAPS, "M", ld(2, vi(1, 3) + ld(2, "c")) + ld(2, vi(1, 1) + ld(2, "a")) + ld(2, vi(1, 2) + ld(2, "b")))
d("map_double_nan_value", S_MAPS, "M", ld(7, vi(1, 1) + f64bits(2, 0x7FF8000000000000)))
# oneof / presence / merge
d("oneof_zero_int", S_ONEOF, "M", vi(1, 0))
d("oneof_empty_string", S_ONEOF, "M", ld(2, b""))
d("oneof_false", S_ONEOF, "M", vi(4, 0))
d("oneof_switch", S_ONEOF, "M", vi(1, 5) + ld(2, b"z"))
d("oneof_msg_merge", S_ONEOF, "M", ld(3, vi(1, 1)) + ld(3, vi(2, 2)))
d("oneof_msg_then_other_then_msg", S_ONEOF, "M", ld(3, vi(1, 1)) + vi(1, 3) + ld(3, vi(2, 2)))
d("opt_zero", S_ONEOF, "M", vi(5, 0) + ld(6, b""))
d("opt_empty_sub", S_ONEOF, "M", ld(7, b""))
d("sub_merge_repeated_concat", S_ONEOF, "M", ld(8, vi(1, 1) + vi(3, 1)) + ld(8, vi(2, 2) + vi(3, 2)))
d("sub_empty", S_ONEOF, "M", ld(8, b""))
d("repeated_sub", S_ONEOF, "M", ld(9, vi(1, 1)) + ld(9, b""))
# proto2
d("p2_optional_zero", S_P2, "M", vi(1, 0) + vi(4, 0))
d("p2_string_latin1", S_P2, "M", ld(2, b"\xe9t\xe9"))
d("p2_closed_enum_unknown", S_P2, "M", vi(3, 5))
d("p2_unpacked_default", S_P2, "M", vi(5, 1) + vi(5, 2) + ld(6, b"\x01\x02"))
d("p2_packed_on_wire_for_unpacked", S_P2, "M", ld(5, b"\x01\x02"))
d("p2_required_missing", S_P2, "R", vi(2, 1))
d("p2_required_present", S_P2, "R", vi(1, 0))
d("p2_empty_bytes_present", S_P2, "M", ld(7, b""))
# name resolution
d("scope_enclosing", S_SCOPE, "scope.v1.B", ld(1, ld(1, ld(1, "hi"))))
d("scope_sibling_item", S_SCOPE, "scope.v1.B", ld(2, ld(1, "yo")))
d("scope_enum_vs_message", S_SCOPE, "scope.v1.Holder", ld(1, vi(1, 7)))
d("scope_fq_and_relative", S_SCOPE, "scope.v1.Q", ld(1, ld(1, "a")) + ld(2, ld(1, "b")))
d("scope_nested_top_level_decode", S_SCOPE, "scope.v1.B.Item", ld(1, "x"))
# json names
d("json_names", S_JSONNAME, "M", vi(1, 1) + vi(2, 1) + vi(3, 1) + vi(4, 1) + vi(5, 1) + vi(6, 1) + vi(7, 1))
d("json_field_order", S_JSONNAME, "M", vi(7, 1) + vi(1, 1))
# well-known types
d("wkt_timestamp", S_WKT, "M", ld(1, vi(1, 1) + vi(2, 5)))
d("wkt_wrapper", S_WKT, "M", ld(2, vi(1, 7)))
d("wkt_absent", S_WKT, "M", vi(4, 1))
# depth
chain = b""
for _ in range(101):
    chain = ld(1, chain)
d("depth_101_default_limit", S_NODE, "Node", chain)
chain = b""
for _ in range(99):
    chain = ld(1, chain)
d("depth_99", S_NODE, "Node", chain)

DYN_ALL = [  # same, but JSON with EmitUnpopulated / emit_defaults
    ("emit_empty_scalars", S_SCALARS, "M", ""),
    ("emit_empty_oneof", S_ONEOF, "M", ""),
    ("emit_p2", S_P2, "M", ""),
]


def dyn_section(mode, vectors, title):
    by_schema = {}
    for i, (id_, sch, msg, h) in enumerate(vectors):
        by_schema.setdefault((sch, msg), []).append((i, id_, h))
    results = {}
    for n, ((sch, msg), items) in enumerate(by_schema.items()):
        sp = write(os.path.join(WORK, "s%d_%s.proto" % (n, mode)), sch)
        hexes = [h if h else "-" for _, _, h in items]  # "-" = empty message (both probes)
        p, prc = run_lines([PION, mode, sp, msg], hexes, WORK, "p%d_%s" % (n, mode))
        g, grc = run_lines([GO, mode, sp, msg], hexes, WORK, "g%d_%s" % (n, mode))
        for k, (i, id_, h) in enumerate(items):
            pv = p[k] if k < len(p) else ("<pion crashed rc=%d>" % prc)
            gv = g[k] if k < len(g) else ("<go crashed rc=%d>" % grc)
            results[i] = (id_, sp, msg, h, pv, gv)
    rows = []
    canon_jobs = []
    for i in sorted(results):
        id_, sp, msg, h, pv, gv = results[i]
        pp, gp = pv.split("\t"), gv.split("\t")
        if pp[0] != "OK" or gp[0] != "OK":
            if pp[0] == gp[0]:
                verdict = "SAME (both reject)" if pp[0] == "ERR" else "SAME?"
            elif gp[0] == "OK":
                verdict = "DIFF pion rejects valid input"
            elif pp[0] == "OK":
                verdict = "DIFF pion accepts invalid input"
            else:
                verdict = "DIFF"
            rows.append([id_, verdict, pv, gv])
            continue
        pj, gj = pp[1], gp[1]
        pc, pd, po = json_norm(pj)
        gc, gd, go_ = json_norm(gj)
        notes = []
        if pc is None:
            notes.append("DIFF pion JSON invalid")
        elif pc != gc:
            notes.append("DIFF JSON value")
        else:
            if pd:
                notes.append("DIFF JSON duplicate keys")
            if pj != gj:
                notes.append("fmt" + ("/order" if po != go_ else ""))
        rows.append([id_, notes, pv, gv])
        canon_jobs.append((len(rows) - 1, sp, msg, pp[2], gp[2]))
    # wire equivalence: Go re-canonicalises Pion's bytes
    for idx, sp, msg, phex, ghex in canon_jobs:
        if phex.startswith("ENCERR"):
            rows[idx][1].append("DIFF pion encode error")
            continue
        out, _ = run_lines([GO, "canon", sp, msg], [phex or "-"], WORK, "canon")
        c = (out[0] if out else "ERR").rstrip()
        if c != ("OK " + ghex).rstrip():
            rows[idx][1].append("DIFF wire (go canon of pion bytes = %s)" % c[:40])
    print("## %s\n" % title)
    print("| vector | verdict | pion | go |\n|---|---|---|---|")
    for r in rows:
        v = r[1] if isinstance(r[1], str) else (", ".join(r[1]) if r[1] else "SAME")
        r[1] = v
        print("| `%s` | %s | `%s` | `%s` |" % (r[0], v, r[2].replace("|", "\\|")[:150], r[3].replace("|", "\\|")[:150]))
    print()
    return rows


# ---------------------------------------------------------------------------------------------
# C. schema
# ---------------------------------------------------------------------------------------------
P3 = 'syntax = "proto3";\n'
SCHEMAS = [
    ("grpc_service", P3 + "package pkg.v1;\nmessage Req { string name = 1; }\nmessage Resp { bytes data = 1; }\n"
     "service Foo {\n  rpc Bar (stream Req) returns (stream Resp) { option deprecated = true; }\n"
     "  rpc Baz(Req) returns (Resp);\n  rpc Qux(.pkg.v1.Req) returns (pkg.v1.Resp) {}\n}\n"),
    ("custom_option_aggregate_with_brace_in_string", P3 + 'import "google/protobuf/descriptor.proto";\n'
     "message Opt { string s = 1; int32 n = 2; }\n"
     "extend google.protobuf.MessageOptions { Opt my_opt = 50001; }\n"
     'message M { option (my_opt) = { s: "}" n: 1 }; int32 a = 1; }\n'),
    ("custom_field_option_aggregate", P3 + 'import "google/protobuf/descriptor.proto";\n'
     "message Opt { string s = 1; }\nextend google.protobuf.FieldOptions { Opt fo = 50002; }\n"
     'message M { int32 a = 1 [(fo) = { s: "a,b]" }]; }\n'),
    ("top_level_extend", 'syntax = "proto2";\nmessage Foo { extensions 100 to max; }\n'
     "extend Foo { optional int32 bar = 100; }\n"),
    ("nested_extend", 'syntax = "proto2";\nmessage Foo { extensions 100 to 199; }\n'
     "message Bar { extend Foo { optional int32 bar = 100; } optional int32 x = 1; }\n"),
    ("extensions_with_options", 'syntax = "proto2";\nmessage Foo { extensions 100 to 199 [declaration = {number: 100, full_name: ".Foo.x", type: "int32"}]; optional int32 a = 1; }\n'),
    ("proto2_group", 'syntax = "proto2";\nmessage M { optional group Result = 1 { optional string url = 2; } }\n'),
    ("proto2_repeated_group", 'syntax = "proto2";\nmessage M { repeated group R = 1 { required int32 a = 2; } optional int32 b = 3; }\n'),
    ("editions_2023", 'edition = "2023";\nmessage M { int32 a = 1; string s = 2 [features.field_presence = IMPLICIT]; }\n'),
    ("enum_alias_negative_hex", P3 + "enum E { option allow_alias = true; Z = 0; ZZ = 0; NEG = -1; HEX = 0x10; OCT = 017; }\n"
     "message M { E e = 1; }\n"),
    ("enum_value_2^31", P3 + "enum E { Z = 0; BIG = 2147483648; }\n"),
    ("enum_value_2^32", P3 + "enum E { Z = 0; BIG = 4294967296; }\n"),
    ("enum_hex_no_digits", P3 + "enum E { Z = 0x; }\n"),
    ("enum_alias_without_allow", P3 + "enum E { A = 0; B = 0; }\n"),
    ("proto3_enum_first_nonzero", P3 + "enum E { ONE = 1; }\n"),
    ("string_concat_and_escapes", P3 + 'option java_package = "com" ".example";\n'
     'message M { int32 a = 1 [json_name = "\\x41\\102"]; }\n'),
    ("octal_field_number", P3 + "message M { int32 a = 017; int32 b = 15; }\n"),
    ("hex_field_number", P3 + "message M { int32 a = 0x10; }\n"),
    ("field_number_2^32+1", P3 + "message M { int32 a = 4294967297; }\n"),
    ("field_number_max", P3 + "message M { int32 a = 536870911; }\n"),
    ("field_number_2^29", P3 + "message M { int32 a = 536870912; }\n"),
    ("field_number_19000", P3 + "message M { int32 a = 19000; }\n"),
    ("field_number_0", P3 + "message M { int32 a = 0; }\n"),
    ("reserved_number_used", P3 + "message M { reserved 5; int32 a = 5; }\n"),
    ("reserved_name_used", P3 + 'message M { reserved "a"; int32 a = 1; }\n'),
    ("reserved_range_max", P3 + "message M { reserved 2, 9 to 11, 100 to max; int32 a = 1; }\n"),
    ("dup_field_name", P3 + "message M { int32 a = 1; string a = 2; }\n"),
    ("dup_field_number", P3 + "message M { int32 a = 1; string b = 1; }\n"),
    ("json_name_conflict", P3 + "message M { int32 foo_bar = 1; int32 fooBar = 2; }\n"),
    ("proto3_required", P3 + "message M { required int32 a = 1; }\n"),
    ("proto3_default", P3 + "message M { int32 a = 1 [default = 5]; }\n"),
    ("proto3_optional", P3 + "message M { optional int32 a = 1; optional M m = 2; }\n"),
    ("unresolved_type", P3 + "message M { Missing m = 1; }\n"),
    ("map_float_key", P3 + "message M { map<float, int32> m = 1; }\n"),
    ("map_enum_key", P3 + "enum E { Z = 0; } message M { map<E, int32> m = 1; }\n"),
    ("map_repeated_label", P3 + "message M { repeated map<string, int32> m = 1; }\n"),
    ("map_nested_value", P3 + "message M { message V { int32 x = 1; } map<string, V> m = 1; map<string, M.V> m2 = 2; }\n"),
    ("trailing_semicolons", P3 + "message M { int32 a = 1;; };;\n;enum E { Z = 0;; };\n"),
    ("block_comment_unclosed", P3 + "message M { int32 a = 1; } /* oops\n"),
    ("nested_block_comment", P3 + "/* a /* b */ c */ message M {}\n"),
    ("line_comment_eof", P3 + "message M {} // eof"),
    ("defaults_numbers", 'syntax = "proto2";\nmessage M { optional int32 a = 1 [default = -0x1F]; optional double d = 2 [default = -1.5e10];\n'
     "optional float f = 3 [default = inf]; optional double n = 4 [default = -nan]; optional uint64 u = 5 [default = 18446744073709551615];\n"
     'optional string s = 6 [default = "a\\"b"]; optional bytes b = 7 [default = "\\001\\x02"]; }\n'),
    ("default_out_of_range", 'syntax = "proto2";\nmessage M { optional int32 a = 1 [default = 2147483648]; }\n'),
    ("missing_syntax_is_proto2", "message M { optional int32 a = 1; }\n"),
    ("unicode_identifier", P3 + "message Mé { int32 a = 1; }\n"),
    ("keyword_named_fields", P3 + "message M { int32 optional = 1; string message = 2; bool enum = 3; int32 map = 4; int32 oneof = 5; int32 reserved = 6; }\n"),
    ("type_named_like_keyword", P3 + "message stream { int32 a = 1; } message M { stream s = 1; }\n"),
    ("oneof_with_option", P3 + "message M { oneof o { option deprecated = true; int32 a = 1; string b = 2; } }\n"),
    ("oneof_repeated_field", P3 + "message M { oneof o { repeated int32 a = 1; } }\n"),
    ("oneof_map_field", P3 + "message M { oneof o { map<string,int32> a = 1; } }\n"),
    ("empty_file", ""),
    ("package_twice", P3 + "package a; package b;\n"),
    ("weak_and_public_import", P3 + 'import public "google/protobuf/empty.proto";\nimport weak "google/protobuf/any.proto";\nmessage M { int32 a = 1; }\n'),
    ("float_field_number", P3 + "message M { int32 a = 1.5; }\n"),
    ("negative_field_number", P3 + "message M { int32 a = -1; }\n"),
]


def deep_schema(n):
    return P3 + "message A { " * n + "} " * n


SCHEMAS += [("nest_32", deep_schema(32)), ("nest_64", deep_schema(64)), ("nest_65", deep_schema(65)),
            ("nest_50000", deep_schema(50000))]


def schema_section():
    rows = []
    for name, src in SCHEMAS:
        sp = write(os.path.join(WORK, "schema_%s.proto" % name.replace("^", "p").replace("+", "_")), src)
        pr = subprocess.run([PION, "schema", sp], capture_output=True, text=True, timeout=120)
        gr = subprocess.run([GO, "schema", sp], capture_output=True, text=True, timeout=120)
        pv = pr.stdout.strip() or ("<pion rc=%d>" % pr.returncode)
        gv = gr.stdout.strip() or ("<go rc=%d %s>" % (gr.returncode, gr.stderr.strip()[:80]))
        pk, gk = pv.split(" ")[0], gv.split(" ")[0]
        if pk == gk == "OK":
            verdict = "SAME" if pv == gv else "DIFF summary"
        elif pk == gk:
            verdict = "SAME (both reject)"
        elif gk == "OK":
            verdict = "DIFF pion rejects valid .proto"
        elif pk == "OK":
            verdict = "DIFF pion accepts invalid .proto"
        else:
            verdict = "DIFF " + pk + "/" + gk
        rows.append((name, verdict, pv, gv))
    print("## C. `.proto` parsing (Pion parse_schema vs protocompile v0.14.1)\n")
    print("| schema | verdict | pion | protocompile |\n|---|---|---|---|")
    for name, v, pv, gv in rows:
        print("| `%s` | %s | `%s` | `%s` |" % (name, v, pv.replace("|", "\\|")[:110], gv.replace("|", "\\|")[:110]))
    print()
    return rows


if __name__ == "__main__":
    PION, GO, RUST, WORK = sys.argv[1:5]
    os.makedirs(WORK, exist_ok=True)
    a = wire_section()
    b = dyn_section("dyn", DYN, "B. DynamicMessage decode / Proto3 JSON / re-encode (Pion vs Go dynamicpb + protojson)")
    b2 = dyn_section("dynall", DYN_ALL, "B2. JSON with emit_defaults / EmitUnpopulated")
    c = schema_section()
    allrows = [r[1] for r in a] + [r[1] for r in b] + [r[1] for r in b2] + [r[1] for r in c]
    ndiff = sum(1 for v in allrows if "DIFF" in v)
    print("**Summary:** %d vectors, %d with a Pion-vs-reference DIFF verdict, %d SAME/benign."
          % (len(allrows), ndiff, len(allrows) - ndiff))
