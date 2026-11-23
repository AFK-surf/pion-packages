#!/usr/bin/env python3
"""Adversarial head-to-head benchmark corpora (fed to the UNMODIFIED package bench drivers in `batch` mode).

usage: gen_adv.py <out_dir>
  a1  wide objects: 1000-key objects, additionalProperties schema           (is_valid fast path)
  a2  unevaluatedProperties: 300-key objects, properties + uP:false         (annotation path)
  a3  uniqueItems: 2000-element arrays of small objects                     (structural hashing)
  a4  recursive $ref tree: depth-40 trees, fan-out 1                        (ref + depth budget)
  a5  W1 schema, 5000 distinct instances (startup/parse amortised)          (steady state)
All instances are VALID so no implementation can short-circuit early and every byte is checked.
"""
import json
import os
import sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)


def write(name, schema, instances):
    with open(os.path.join(out, f"{name}_schema.json"), "w") as f:
        json.dump(schema, f, separators=(",", ":"))
    with open(os.path.join(out, f"{name}_instances.jsonl"), "w") as f:
        for inst in instances:
            f.write(json.dumps(inst, separators=(",", ":")) + "\n")


write("a1", {"type": "object", "additionalProperties": {"type": "integer", "minimum": 0}},
      [{f"key_{j}_{i}": j for j in range(1000)} for i in range(50)])

write("a2", {"type": "object", "properties": {f"p{j}": {"type": "integer"} for j in range(50)},
             "patternProperties": {"^q": {"type": "integer"}}, "unevaluatedProperties": False},
      [dict({f"p{j}": j for j in range(50)}, **{f"q{j}_{i}": j for j in range(250)}) for i in range(50)])

write("a3", {"type": "array", "uniqueItems": True, "items": {"type": "object"}},
      [[{"id": i * 10000 + j, "tag": f"t{j % 7}"} for j in range(2000)] for i in range(20)])


def tree(d, i):
    v = {"v": i}
    for k in range(d):
        v = {"v": k, "c": v}
    return v


write("a4", {"$defs": {"t": {"type": "object", "required": ["v"],
                             "properties": {"v": {"type": "integer"}, "c": {"$ref": "#/$defs/t"}}}},
             "$ref": "#/$defs/t"},
      [tree(40, i) for i in range(200)])

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bench"))
from gen_data import gen_w1  # noqa: E402  (reuse the package's own W1 schema/instance generator)

gen_w1(out, 5000)
os.replace(os.path.join(out, "w1_schema.json"), os.path.join(out, "a5_schema.json"))
os.replace(os.path.join(out, "w1_instances.jsonl"), os.path.join(out, "a5_instances.jsonl"))
print(f"  adversarial corpora -> {out}")
