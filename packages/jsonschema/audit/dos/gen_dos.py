#!/usr/bin/env python3
"""Adversarial complexity / DoS probes (one case per file).

usage: gen_dos.py <out_dir> [scale]
Writes <out_dir>/<probe>.jsonl, each a single differential case (same contract as diff/run_diff.py).
`scale` (default 1) multiplies the input sizes.
"""
import json
import os
import sys

out_dir = sys.argv[1]
scale = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
os.makedirs(out_dir, exist_ok=True)
probes = []


def probe(name, schema, instance, desc):
    c = {"id": name, "draft": "2020-12", "fmt": False, "schema": schema, "instance": instance, "desc": desc}
    with open(os.path.join(out_dir, name + ".jsonl"), "w") as f:
        f.write(json.dumps(c, separators=(",", ":")) + "\n")
    probes.append((name, desc))


def S(n):
    return max(1, int(n * scale))


def nest_arr(d, leaf):
    v = leaf
    for _ in range(d):
        v = [v]
    return v


# --- quadratic annotation bookkeeping (EvalAnn.add_prop / add_item are linear scans)
for n in (5000, 20000, 50000):
    N = S(n)
    probe(f"ue_props_{n}", {"unevaluatedProperties": {"type": "integer"}},
          {f"k{i}": i for i in range(N)}, f"unevaluatedProperties over {N} keys")
    probe(f"ue_addl_{n}", {"additionalProperties": True, "unevaluatedProperties": False},
          {f"k{i}": i for i in range(N)}, f"additionalProperties + unevaluatedProperties:false, {N} keys")
    probe(f"ue_contains_{n}", {"contains": {"type": "integer"}, "unevaluatedItems": False},
          list(range(N)), f"contains + unevaluatedItems:false, {N} items")
    probe(f"ctl_props_{n}", {"additionalProperties": {"type": "integer"}},
          {f"k{i}": i for i in range(N)}, f"control: additionalProperties over {N} keys (fast path)")

# --- required x keys: object_has_key is a linear scan per required name
R, N = S(2000), S(50000)
keys = [f"k{i}" for i in range(N)]
probe("required_2000x50000", {"required": keys[-R:]}, {k: 0 for k in keys},
      f"{R} required names against a {N}-key object (names at the end)")
probe("depreq_2000x50000", {"dependentRequired": {"k0": keys[-R:]}}, {k: 0 for k in keys},
      f"dependentRequired with {R} names, {N}-key object")

# --- uniqueItems: structural hash saturates at depth 64 -> constant hash -> O(N^2) value_eq
for n in (1000, 4000):
    N = S(n)
    probe(f"unique_deep_collide_{n}", {"uniqueItems": True}, [nest_arr(66, i) for i in range(N)],
          f"{N} distinct arrays that differ only below depth 64 (hash saturation)")
probe("unique_strings_100000", {"uniqueItems": True}, [f"s{i}" for i in range(S(100000))],
      "control: 100k distinct strings")
probe("unique_numbers_100000", {"uniqueItems": True}, [i * 0.5 for i in range(S(100000))],
      "control: 100k distinct numbers")

# --- $ref DAG fan-out: d_i = allOf[d_{i+1}, d_{i+1}] -> 2^depth evaluations (all impls lack memoisation?)
for d in (16, 22):
    defs = {f"d{i}": {"allOf": [{"$ref": f"#/$defs/d{i + 1}"}, {"$ref": f"#/$defs/d{i + 1}"}]} for i in range(d)}
    defs[f"d{d}"] = {"type": "integer"}
    probe(f"ref_dag_{d}", {"$defs": defs, "$ref": "#/$defs/d0"}, 1, f"$ref DAG fan-out 2^{d}")

# --- anyOf + unevaluatedItems over nested arrays: annotation path cannot short-circuit anyOf
for d in (12, 18):
    probe(f"anyof_ue_{d}", {"$defs": {"n": {"anyOf": [{"type": "array", "items": {"$ref": "#/$defs/n"}},
                                                     {"type": "array", "items": {"$ref": "#/$defs/n"}},
                                                     {"type": "integer"}]}},
                            "$ref": "#/$defs/n", "unevaluatedItems": False},
          nest_arr(d, 1), f"2-way anyOf recursion, depth {d}, annotation path")
    probe(f"anyof_fast_{d}", {"$defs": {"n": {"anyOf": [{"type": "array", "items": {"$ref": "#/$defs/n"}},
                                                       {"type": "array", "items": {"$ref": "#/$defs/n"}},
                                                       {"type": "integer"}]}},
                              "$ref": "#/$defs/n"},
          nest_arr(d, "x"), f"2-way anyOf recursion, depth {d}, invalid leaf (no short-circuit possible)")

# --- compile-time: linear scope / anchor / memo tables -> O(R^2) compile
for r in (2000, 8000):
    R = S(r)
    probe(f"compile_refs_{r}", {"$defs": {f"d{i}": {"type": "integer"} for i in range(R)},
                                "properties": {f"p{i}": {"$ref": f"#/$defs/d{i}"} for i in range(R)}},
          {}, f"compile {R} distinct $ref targets")
    probe(f"compile_anchors_{r}", {"$defs": {f"d{i}": {"$anchor": f"a{i}", "type": "integer"} for i in range(R)},
                                   "properties": {f"p{i}": {"$ref": f"#a{i}"} for i in range(R)}},
          {}, f"compile {R} $anchor refs")

# --- deep nesting (stack safety)
def probe_raw(name, schema_json, instance_json, desc):
    with open(os.path.join(out_dir, name + ".jsonl"), "w") as f:
        f.write('{"id":%s,"draft":"2020-12","fmt":false,"schema":%s,"instance":%s}\n'
                % (json.dumps(name), schema_json, instance_json))
    probes.append((name, desc))


def deep_arr_json(d):
    return "[" * d + "1" + "]" * d


probe_raw("deep_instance_100000", '{"items":{"$ref":"#"}}', deep_arr_json(100000),
          "100k-deep array vs recursive schema")
probe_raw("deep_const_20000", '{"const":%s}' % deep_arr_json(20000), deep_arr_json(20000), "20k-deep const equality")
probe_raw("deep_schema_40000", '{"not":' * 40000 + '{"type":"integer"}' + "}" * 40000, "1",
          "40k-deep not/not schema")

# --- big enum / many patterns (controls)
probe("enum_50000_miss", {"enum": list(range(S(50000)))}, -1, "control: 50k enum miss")
probe("pprops_50x20000", {"patternProperties": {f"^k{i}[0-9]*$": {"type": "integer"} for i in range(50)}},
      {f"k{i}": i for i in range(S(20000))}, "control: 50 patternProperties x 20k keys")

with open(os.path.join(out_dir, "INDEX.tsv"), "w") as f:
    for n, d in probes:
        f.write(f"{n}\t{d}\n")
print(f"  {len(probes)} probes -> {out_dir}")
