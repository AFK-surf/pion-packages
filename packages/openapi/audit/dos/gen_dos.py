#!/usr/bin/env python3
"""Generate DoS probe specs for packages/openapi (default OpenApiLimits) into <out_dir>.

Writes <name>.json|.yaml and INDEX.tsv: name \t file \t stages(comma) \t opId \t path \t description
usage: gen_dos.py <out_dir>
"""
import json
import os
import sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
INDEX = []


def doc(paths, schemas, version="3.0.3"):
    return {"openapi": version, "info": {"title": "dos", "version": "1"}, "paths": paths,
            "components": {"schemas": schemas}}


def post_body(ref, op_id="op0"):
    return {"post": {"operationId": op_id,
                     "requestBody": {"required": True, "content": {"application/json": {"schema": {"$ref": ref}}}},
                     "responses": {"200": {"description": "ok"}}}}


def emit(name, obj_or_text, stages, desc, op_id="op0", path="/", ext="json"):
    fn = f"{name}.{ext}"
    with open(os.path.join(out, fn), "w", encoding="utf-8") as f:
        if isinstance(obj_or_text, str):
            f.write(obj_or_text)
        else:
            json.dump(obj_or_text, f, separators=(",", ":"))
    INDEX.append((name, fn, ",".join(stages), op_id, path, desc))


ALL = ["parse", "validate", "from_doc", "export"]

# 1. exponential DAG bomb: A_i = {x: A_{i+1}, y: A_{i+1}}, 2^25 leaves when expanded
for depth in (18, 25):
    s = {f"A{i}": {"type": "object", "properties": {"x": {"$ref": f"#/components/schemas/A{i+1}"},
                                                    "y": {"$ref": f"#/components/schemas/A{i+1}"}}} for i in range(depth)}
    s[f"A{depth}"] = {"type": "string"}
    emit(f"dag_bomb_{depth}", doc({"/b": post_body("#/components/schemas/A0")}, s), ALL,
         f"2^{depth} DAG $ref bomb (Billion Laughs)")

# 2. quadratic fan-out bomb: A0 has K props -> A1; A1 has M plain props. K <= max_ref_expansions (4096)
#    so the expansion budget never trips, but the expanded schema has K*M nodes.
for k, m in ((4000, 50), (4000, 200)):
    s = {"A0": {"type": "object", "properties": {f"p{i}": {"$ref": "#/components/schemas/A1"} for i in range(k)}},
         "A1": {"type": "object", "properties": {f"q{j}": {"type": "string", "maxLength": 3} for j in range(m)}}}
    emit(f"fanout_{k}x{m}", doc({"/b": post_body("#/components/schemas/A0")}, s), ALL,
         f"{k} refs to a {m}-prop schema: {k*m*3//1000}k expanded nodes under the 4096-expansion budget")

# 3. fan-out x many operations: every operation's body expands the same bomb separately (no sharing)
for ops in (20,):
    k, m = 2000, 50
    s = {"A0": {"type": "object", "properties": {f"p{i}": {"$ref": "#/components/schemas/A1"} for i in range(k)}},
         "A1": {"type": "object", "properties": {f"q{j}": {"type": "string"} for j in range(m)}}}
    paths = {f"/b{i}": post_body("#/components/schemas/A0", f"op{i}") for i in range(ops)}
    emit(f"fanout_ops_{ops}", doc(paths, s), ["parse", "validate", "from_doc", "export_all"],
         f"{ops} operations x ({k} refs -> {m} props) = {ops*k*m*2//1000000}M retained nodes")

# 3b. wasm32 trap probe (4 GiB linear memory): 30 operations x (2000 refs -> 50 props); native ~4.3 GB, so it is
#     only run by run_audit.sh `modes` on wasm32 (stage suffix @wasm is skipped by run_dos.py)
k, m, ops = 2000, 50, 30
s = {"A0": {"type": "object", "properties": {f"p{i}": {"$ref": "#/components/schemas/A1"} for i in range(k)}},
     "A1": {"type": "object", "properties": {f"q{j}": {"type": "string"} for j in range(m)}}}
emit("fanout_ops_30", doc({f"/b{i}": post_body("#/components/schemas/A0", f"op{i}") for i in range(ops)}, s),
     ["from_doc@wasm"], "92 KB spec: 30 operations x (2000 refs -> 50 props), traps wasm32 Memory.grow")

# 4. many distinct $refs: validate() keeps a linear `checked` list and resolves by linear key scan
for n in (5000, 20000, 40000):
    s = {f"S{i}": {"type": "string"} for i in range(n)}
    s["Root"] = {"type": "object", "properties": {f"f{i}": {"$ref": f"#/components/schemas/S{i}"} for i in range(n)}}
    emit(f"many_refs_{n}", doc({"/b": post_body("#/components/schemas/Root")}, s), ["parse", "validate", "from_doc"],
         f"{n} distinct component refs (O(n^2) checked-list + key scan)")

# 5. long alias chain A0 -> A1 -> ... -> A200 (max_ref_depth 64)
n = 200
s = {f"A{i}": {"$ref": f"#/components/schemas/A{i+1}"} for i in range(n)}
s[f"A{n}"] = {"type": "string"}
emit("ref_chain_200", doc({"/b": post_body("#/components/schemas/A0")}, s), ALL, "200-hop $ref alias chain")

# 6. deep JSON nesting (parser max_depth 64)
emit("json_deep_100k", '{"openapi":"3.0.3","info":{"title":"d","version":"1"},"paths":{},"x":' + "[" * 100000 + "]" * 100000 + "}",
     ["parse"], "100k nested JSON arrays")
# 7. deep YAML nesting: yaml::parse runs before any OpenApiLimits check
emit("yaml_deep_flow_100k", "openapi: 3.0.3\ninfo: {title: d, version: '1'}\npaths: {}\nx: " + "[" * 100000 + "]" * 100000 + "\n",
     ["parse"], "100k nested YAML flow sequences", ext="yaml")
blk = "openapi: 3.0.3\ninfo: {title: d, version: '1'}\npaths: {}\nx:\n" + "".join(" " * i + "- \n" for i in range(1, 3000))
emit("yaml_deep_block_3k", blk, ["parse"], "3k nested YAML block sequences", ext="yaml")
# 8. YAML alias "billion laughs"
lol = ["openapi: 3.0.3", "info: {title: d, version: '1'}", "paths: {}", "l0: &l0 [lol,lol,lol,lol,lol,lol,lol,lol,lol,lol]"]
for i in range(1, 9):
    lol.append(f"l{i}: &l{i} [" + ",".join([f"*l{i-1}"] * 10) + "]")
emit("yaml_laughs_1e9", "\n".join(lol) + "\n", ["parse"], "YAML alias bomb (10^9 leaves)", ext="yaml")
# 9. router: deep request path and many inline edges at one node
paths = {f"/f/{{n}}.e{i}": {"get": {"operationId": f"g{i}", "parameters": [{"name": "n", "in": "path", "required": True, "schema": {"type": "string"}}],
                                    "responses": {"200": {"description": "ok"}}}} for i in range(5000)}
emit("router_inline_5000", {"openapi": "3.0.3", "info": {"title": "r", "version": "1"}, "paths": paths}, ["route"],
     "5000 inline-template edges at one trie node, 1000 misses", path="/f/" + "a" * 2000 + ".zzz")
emit("router_deep_path", {"openapi": "3.0.3", "info": {"title": "r", "version": "1"},
                          "paths": {"/{a}": {"get": {"operationId": "a", "parameters": [{"name": "a", "in": "path", "required": True, "schema": {"type": "string"}}],
                                                     "responses": {"200": {"description": "ok"}}}}}},
     ["route"], "1000 lookups of a 100k-segment path", path="/x" * 100000)
# 10. recursive schema exported: must terminate with $defs
s = {"N": {"type": "object", "properties": {"a": {"$ref": "#/components/schemas/N"}, "b": {"$ref": "#/components/schemas/M"}}},
     "M": {"type": "object", "properties": {"n": {"$ref": "#/components/schemas/N"}, "m": {"$ref": "#/components/schemas/M"}}}}
emit("recursive_mutual", doc({"/b": post_body("#/components/schemas/N")}, s), ALL, "mutually recursive N <-> M")

with open(os.path.join(out, "INDEX.tsv"), "w", encoding="utf-8") as f:
    for row in INDEX:
        f.write("\t".join(row) + "\n")
