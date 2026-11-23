#!/usr/bin/env python3
"""Deterministic benchmark corpus generator for packages/jsonschema.

Generates 3 Draft 2020-12 benchmark workloads in OUT_DIR:
  1. w1_schema.json + w1_instances.jsonl : OpenAPI / MCP Tool Call (500 distinct instances, x100 = 50k)
  2. w2_schema.json + w2_instances.jsonl : GitHub Workflow / Package Manifest ($ref/oneOf/pattern/uniqueItems, 200 distinct, x100 = 20k)
  3. w3_pairs.jsonl                      : 200 distinct (schema, instance) pairs for compile+validate e2e (x10 = 2,000 schemas)
"""

import json
import os
import sys


def gen_w1(out_dir: str, count: int) -> None:
    schema = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "required": ["jsonrpc", "id", "method", "params"],
        "additionalProperties": False,
        "properties": {
            "jsonrpc": {"const": "2.0"},
            "id": {"type": ["integer", "string"]},
            "method": {
                "enum": [
                    "tools/call",
                    "tools/list",
                    "resources/read",
                    "prompts/get",
                ]
            },
            "params": {
                "type": "object",
                "required": ["name", "arguments"],
                "additionalProperties": False,
                "properties": {
                    "name": {
                        "type": "string",
                        "minLength": 2,
                        "maxLength": 64,
                        "pattern": "^[a-z][a-z0-9_.-]*$",
                    },
                    "arguments": {
                        "type": "object",
                        "required": ["path", "limit"],
                        "properties": {
                            "path": {"type": "string", "minLength": 1},
                            "limit": {"type": "integer", "minimum": 1, "maximum": 1000},
                            "recursive": {"type": "boolean"},
                            "tags": {
                                "type": "array",
                                "maxItems": 8,
                                "items": {"type": "string", "minLength": 1},
                            },
                        },
                        "additionalProperties": False,
                    },
                },
            },
        },
    }
    with open(os.path.join(out_dir, "w1_schema.json"), "w", encoding="utf-8") as f:
        json.dump(schema, f, separators=(",", ":"))

    methods = ["tools/call", "tools/list", "resources/read", "prompts/get"]
    tools = ["read_file", "search_code", "run_query", "fetch_doc", "list_dir"]
    lines = []
    for i in range(count):
        inst = {
            "jsonrpc": "2.0",
            "id": i if (i % 2 == 0) else f"req-{i}",
            "method": methods[i % len(methods)],
            "params": {
                "name": tools[i % len(tools)],
                "arguments": {
                    "path": f"/workspace/src/mod_{i % 37}.pion",
                    "limit": (i % 500) + 1,
                    "recursive": (i % 3 == 0),
                    "tags": [f"t{i % 5}", f"g{i % 7}"],
                },
            },
        }
        # Inject deterministic invalid cases (~25%)
        rem = i % 16
        if rem == 3:
            inst["params"]["arguments"]["limit"] = 0  # fails minimum: 1
        elif rem == 7:
            inst["params"]["name"] = "INVALID_UPPER"  # fails pattern
        elif rem == 11:
            inst["method"] = "unknown/method"  # fails enum
        elif rem == 15:
            inst["extra_field"] = True  # fails additionalProperties: false
        lines.append(json.dumps(inst, separators=(",", ":")))

    with open(os.path.join(out_dir, "w1_instances.jsonl"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def gen_w2(out_dir: str, count: int) -> None:
    schema = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$defs": {
            "semver": {
                "type": "string",
                "pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+$",
            },
            "depSpec": {
                "oneOf": [
                    {
                        "type": "object",
                        "required": ["version"],
                        "additionalProperties": False,
                        "properties": {
                            "version": {"$ref": "#/$defs/semver"},
                            "optional": {"type": "boolean"},
                        },
                    },
                    {
                        "type": "object",
                        "required": ["git", "rev"],
                        "additionalProperties": False,
                        "properties": {
                            "git": {"type": "string", "minLength": 8},
                            "rev": {"type": "string", "pattern": "^[0-9a-f]{7,40}$"},
                        },
                    },
                    {
                        "type": "object",
                        "required": ["path"],
                        "additionalProperties": False,
                        "properties": {
                            "path": {"type": "string", "minLength": 1},
                        },
                    },
                ]
            },
        },
        "type": "object",
        "required": ["name", "version", "targets", "dependencies", "features"],
        "additionalProperties": False,
        "properties": {
            "name": {"type": "string", "pattern": "^[a-z][a-z0-9_-]{1,31}$"},
            "version": {"$ref": "#/$defs/semver"},
            "targets": {
                "type": "array",
                "minItems": 1,
                "uniqueItems": True,
                "items": {"enum": ["native", "wasm32", "linux-x64", "macos-arm64"]},
            },
            "features": {
                "type": "array",
                "uniqueItems": True,
                "items": {"type": "string", "minLength": 2, "maxLength": 24},
            },
            "dependencies": {
                "type": "object",
                "additionalProperties": {"$ref": "#/$defs/depSpec"},
            },
            "ci": {
                "type": "object",
                "properties": {
                    "timeout_min": {"type": "integer", "minimum": 1, "maximum": 60},
                    "fail_fast": {"type": "boolean"},
                },
                "additionalProperties": False,
            },
        },
    }
    with open(os.path.join(out_dir, "w2_schema.json"), "w", encoding="utf-8") as f:
        json.dump(schema, f, separators=(",", ":"))

    lines = []
    for i in range(count):
        dep_kind = i % 3
        if dep_kind == 0:
            dep_a = {"version": f"1.{i % 10}.{i % 5}", "optional": (i % 2 == 0)}
        elif dep_kind == 1:
            dep_a = {"git": "https://github.com/AFK-surf/pion-packages.git", "rev": "14ba293abcdef0"}
        else:
            dep_a = {"path": f"../pkg_{i % 11}"}

        inst = {
            "name": f"pkg-mod-{i % 50}",
            "version": f"0.{(i % 9) + 1}.{i % 20}",
            "targets": ["native", "wasm32", "macos-arm64"],
            "features": [f"feat-{k}" for k in range((i % 6) + 2)],
            "dependencies": {
                "core": dep_a,
                "json5": {"path": "../json5"},
                "regex": {"version": "0.1.0"},
            },
            "ci": {"timeout_min": (i % 30) + 5, "fail_fast": True},
        }
        rem = i % 10
        if rem == 2:
            # duplicate in uniqueItems features
            inst["features"].append("feat-0")
        elif rem == 5:
            # fails oneOf (matches none: missing rev)
            inst["dependencies"]["core"] = {"git": "https://example.com/repo.git"}
        elif rem == 8:
            # fails semver pattern
            inst["version"] = "v1.0-beta"
        lines.append(json.dumps(inst, separators=(",", ":")))

    with open(os.path.join(out_dir, "w2_instances.jsonl"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def gen_w3(out_dir: str, count: int) -> None:
    lines = []
    for i in range(count):
        min_v = (i % 10) + 1
        max_v = min_v + 100
        schema = {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$defs": {
                "item": {
                    "type": "object",
                    "required": ["k", "v"],
                    "properties": {
                        "k": {"type": "string", "minLength": 2, "pattern": "^[a-z0-9_]+$"},
                        "v": {"type": "integer", "minimum": min_v, "maximum": max_v},
                    },
                    "additionalProperties": False,
                }
            },
            "type": "object",
            "required": ["id", "items"],
            "properties": {
                "id": {"type": "string", "minLength": 3},
                "items": {
                    "type": "array",
                    "minItems": 1,
                    "uniqueItems": True,
                    "items": {"$ref": "#/$defs/item"},
                },
            },
            "additionalProperties": False,
        }
        bad = (i % 4 == 3)
        inst = {
            "id": f"sch_{i}",
            "items": [
                {"k": f"key_{i}_a", "v": min_v + 5},
                {"k": f"key_{i}_b", "v": (max_v + 10) if bad else (min_v + 10)},
            ],
        }
        lines.append(json.dumps({"schema": schema, "instance": inst}, separators=(",", ":")))

    with open(os.path.join(out_dir, "w3_pairs.jsonl"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: gen_data.py OUT_DIR [W1_N] [W2_N] [W3_N]", file=sys.stderr)
        return 1
    out_dir = sys.argv[1]
    w1_n = int(sys.argv[2]) if len(sys.argv) > 2 else 500
    w2_n = int(sys.argv[3]) if len(sys.argv) > 3 else 200
    w3_n = int(sys.argv[4]) if len(sys.argv) > 4 else 200
    os.makedirs(out_dir, exist_ok=True)
    gen_w1(out_dir, w1_n)
    gen_w2(out_dir, w2_n)
    gen_w3(out_dir, w3_n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
