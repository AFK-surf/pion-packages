#!/usr/bin/env python3
"""Generate realistic JSON5 config corpus and RFC 6901/6902 patch workload inputs."""
import json
import sys


def gen_tsconfig_json5(path: str, packages: int = 180) -> None:
    lines = []
    lines.append("// Monorepo TypeScript + Editor Workspace Configuration (JSON5)")
    lines.append("/* Auto-generated realistic benchmark corpus with comments,")
    lines.append(" * unquoted identifier keys, single-quoted strings, hex flags,")
    lines.append(" * floats, and trailing commas. */")
    lines.append("{")
    lines.append("  $schema: 'https://json.schemastore.org/tsconfig',")
    lines.append("  display: 'Pion Monorepo Strict Config',")
    lines.append("  compilerOptions: {")
    lines.append("    target: 'ES2024',")
    lines.append("    module: 'ESNext',")
    lines.append("    moduleResolution: 'bundler',")
    lines.append("    strict: true,")
    lines.append("    noUncheckedIndexedAccess: true,")
    lines.append("    exactOptionalPropertyTypes: false,")
    lines.append("    incremental: true,")
    lines.append("    maxNodeModuleJsDepth: 4,")
    lines.append("    featureMask: 0x1F3A, // bitmask flags in hex")
    lines.append("    sampleRate: .75,")
    lines.append("    timeoutSec: 30.5,")
    lines.append("    retries: +3,")
    lines.append("    experimental: null,")
    lines.append("    lib: ['ES2024', 'DOM', 'DOM.Iterable',],")
    lines.append("  },")
    lines.append("  workspaces: [")
    for i in range(packages):
        lines.append(f"    // Package #{i} workspace entry")
        lines.append("    {")
        lines.append(f"      name: '@afk/pkg-{i:04d}',")
        lines.append(f"      root: 'packages/pkg-{i:04d}',")
        lines.append(f"      entry: 'src/index.ts',")
        lines.append(f"      flags: 0x{(0x100 + (i * 17) % 0xE00):X},")
        lines.append(f"      weight: {((i % 97) + 1) / 100.0:.2f},")
        lines.append(f"      enabled: {'true' if i % 3 != 0 else 'false'},")
        lines.append(f"      owner: {'null' if i % 7 == 0 else chr(39) + f'team-{i % 11}' + chr(39)},")
        lines.append("      /* Dependencies & lint overrides */")
        lines.append(f"      deps: ['@afk/core', '@afk/util-{i % 13}', '@afk/rt-{i % 7}',],")
        lines.append("      lint: {")
        lines.append(f"        maxLineLength: {80 + (i % 5) * 10},")
        lines.append(f"        indentSize: {2 if i % 2 == 0 else 4},")
        lines.append("        rules: {")
        lines.append("          'no-console': 'warn',")
        lines.append("          'no-unused-vars': 'error',")
        lines.append("          'prefer-const': 'error',")
        lines.append("        },")
        lines.append("      },")
        lines.append("    },")
    lines.append("  ],")
    lines.append("}")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def gen_patch_inputs(doc_path: str, patch_path: str) -> None:
    doc = {
        "service": "pion-gateway",
        "version": 1,
        "a/b": {"m~n": "escaped-target"},
        "config": {
            "host": "127.0.0.1",
            "port": 8080,
            "tls": True,
            "retries": 3,
            "tags": ["edge", "wasm", "native", "fast"],
            "limits": {"max_conn": 1024, "timeout_ms": 5000},
        },
        "routes": [
            {"path": "/health", "method": "GET", "enabled": True},
            {"path": "/api/v1/query", "method": "POST", "enabled": True},
            {"path": "/api/v1/admin", "method": "POST", "enabled": False},
        ],
    }
    patch = [
        {"op": "test", "path": "/service", "value": "pion-gateway"},
        {"op": "replace", "path": "/version", "value": 2},
        {"op": "add", "path": "/config/tags/-", "value": "json5"},
        {"op": "remove", "path": "/config/tags/1"},
        {"op": "move", "from": "/config/retries", "path": "/config/limits/retries"},
        {"op": "copy", "from": "/a~1b/m~0n", "path": "/copied_label"},
        {"op": "replace", "path": "/routes/2/enabled", "value": True},
    ]
    with open(doc_path, "w", encoding="utf-8") as f:
        json.dump(doc, f, separators=(",", ":"))
    with open(patch_path, "w", encoding="utf-8") as f:
        json.dump(patch, f, separators=(",", ":"))


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "corpus":
        gen_tsconfig_json5(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 180)
    elif mode == "patch":
        gen_patch_inputs(sys.argv[2], sys.argv[3])
    else:
        raise SystemExit(f"unknown mode: {mode}")
