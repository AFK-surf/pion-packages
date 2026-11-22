#!/usr/bin/env python3
"""Deterministic realistic monorepo path & 80-rule GlobSet corpus generator."""

import os
import random
import sys

RULES = [
    # 1. Pure extensions (16)
    "*.rs",
    "*.pion",
    "*.ts",
    "*.tsx",
    "*.mbt",
    "*.json",
    "*.toml",
    "*.md",
    "*.lock",
    "*.log",
    "*.tmp",
    "*.bak",
    "*.wasm",
    "*.map",
    "*.d.ts",
    "**/*.c",
    # 2. Basename literals (12)
    "**/Cargo.toml",
    "**/Cargo.lock",
    "**/package.json",
    "**/tsconfig.json",
    "**/pion.toml",
    "**/README.md",
    "**/Makefile",
    "**/Dockerfile",
    "**/.gitignore",
    "**/LICENSE",
    "**/index.ts",
    "**/lib.rs",
    # 3. Exact literal paths (8)
    "Cargo.toml",
    "Cargo.lock",
    "pion.toml",
    "README.md",
    "BENCHMARKS.md",
    "src/lib.rs",
    "src/main.rs",
    "scripts/verify.sh",
    # 4. Prefix rules (10)
    "target/**",
    "dist/**",
    "build/**",
    "node_modules/**",
    ".git/**",
    "vendor/**",
    "packages/core/**",
    "packages/glob/**",
    "apps/desktop/**",
    "crates/engine/**",
    # 5. Suffix / component suffix rules (8)
    "**/node_modules/lodash",
    "**/src/main.rs",
    "**/src/lib.rs",
    "**/src/mod.rs",
    "**/tests/common.rs",
    "*_test.pion",
    "*_bench.rs",
    "*.min.js",
    # 6. Required-extension complex globs (10)
    "packages/*/src/*.pion",
    "crates/*/src/*.rs",
    "apps/*/src/*.tsx",
    "src/**/*.rs",
    "libs/**/*.mbt",
    "packages/**/bench/**/*.rs",
    "packages/**/wasm_smoke/*.pion",
    "**/test_*.rs",
    "**/spec_*.pion",
    "docs/**/*.md",
    # 7. Character classes (8)
    "**/*.py[cod]",
    "**/test_[0-9][0-9].rs",
    "**/shard_[a-f][0-9].json",
    "**/log_[0-9].log",
    "packages/[a-m]*/pion.toml",
    "crates/[n-z]*/Cargo.toml",
    "**/file_[!0-9].txt",
    "**/v[0-9]*.toml",
    # 8. Brace alternations (8)
    "**/*.{js,jsx,mjs}",
    "**/*.{h,hpp,cc,cpp}",
    "{target,dist,build}/**/*.o",
    "packages/{glob,time,markdown}/**",
    "**/src/{main,lib,types}.pion",
    "**/config.{dev,prod,staging}.json",
    "apps/{web,mobile,desktop}/src/*.ts",
    "docs/{en,zh}/*.md",
]

assert len(RULES) == 80, f"expected 80 rules, got {len(RULES)}"

TOP_DIRS = [
    "packages",
    "crates",
    "apps",
    "libs",
    "src",
    "docs",
    "scripts",
    "target",
    "dist",
    "build",
    "node_modules",
    "vendor",
    ".git",
]

PKG_NAMES = [
    "core",
    "glob",
    "time",
    "markdown",
    "mermaid",
    "texmath",
    "json",
    "http",
    "crypto",
    "regex",
    "sqlite",
    "ui",
    "web",
    "mobile",
    "desktop",
    "engine",
    "runtime",
    "parser",
    "lexer",
    "codegen",
    "alpha",
    "beta",
    "net",
    "storage",
]

SUBDIRS = [
    "src",
    "src/internal",
    "src/util",
    "src/net/http",
    "tests",
    "bench",
    "bench/rust",
    "wasm_smoke",
    "debug/deps",
    "release/build",
    "lodash/fp",
    "en",
    "zh",
    "objects/pack",
]

STEMS = [
    "main",
    "lib",
    "types",
    "mod",
    "parser",
    "nfa",
    "globset",
    "gitignore",
    "common",
    "index",
    "app",
    "utils",
    "helper",
    "client",
    "server",
    "worker",
    "config.dev",
    "config.prod",
    "test_01",
    "test_42",
    "test_alpha",
    "spec_core",
    "shard_a3",
    "shard_f9",
    "log_5",
    "file_x",
    "v2_schema",
    "bundle.min",
    "foo_test",
    "bar_bench",
]

EXTS = [
    ".rs",
    ".pion",
    ".ts",
    ".tsx",
    ".mbt",
    ".json",
    ".toml",
    ".md",
    ".lock",
    ".log",
    ".tmp",
    ".js",
    ".jsx",
    ".py",
    ".pyc",
    ".pyo",
    ".c",
    ".h",
    ".o",
    ".txt",
    ".wasm",
    ".map",
    ".d.ts",
    ".sh",
]

EXACT_FILES = [
    "Cargo.toml",
    "Cargo.lock",
    "pion.toml",
    "README.md",
    "BENCHMARKS.md",
    "LICENSE",
    ".gitignore",
    "Makefile",
    "Dockerfile",
    "src/lib.rs",
    "src/main.rs",
    "scripts/verify.sh",
    "node_modules/lodash",
    "packages/web/node_modules/lodash",
]


def generate(paths_out: str, rules_out: str, count: int) -> None:
    rng = random.Random(20261123)
    paths = []
    for i in range(count):
        r = rng.random()
        if r < 0.04:
            paths.append(rng.choice(EXACT_FILES))
        elif r < 0.14:
            top = rng.choice(["target", "dist", "build", "node_modules", "vendor", ".git"])
            sub = rng.choice(SUBDIRS)
            stem = rng.choice(STEMS)
            ext = rng.choice(EXTS)
            paths.append(f"{top}/{sub}/{stem}{ext}")
        elif r < 0.78:
            top = rng.choice(["packages", "crates", "apps", "libs"])
            pkg = rng.choice(PKG_NAMES)
            if rng.random() < 0.12:
                fname = rng.choice(["Cargo.toml", "pion.toml", "package.json", "README.md", "tsconfig.json"])
                paths.append(f"{top}/{pkg}/{fname}")
            else:
                sub = rng.choice(SUBDIRS)
                stem = rng.choice(STEMS)
                ext = rng.choice(EXTS)
                paths.append(f"{top}/{pkg}/{sub}/{stem}{ext}")
        else:
            top = rng.choice(["src", "docs", "scripts"])
            sub = rng.choice(["", "en/", "zh/", "internal/", "a/b/c/"])
            stem = rng.choice(STEMS)
            ext = rng.choice(EXTS)
            paths.append(f"{top}/{sub}{stem}{ext}")

    os.makedirs(os.path.dirname(os.path.abspath(paths_out)), exist_ok=True)
    with open(paths_out, "w", encoding="utf-8") as f:
        f.write("\n".join(paths) + "\n")
    with open(rules_out, "w", encoding="utf-8") as f:
        f.write("\n".join(RULES) + "\n")


if __name__ == "__main__":
    paths_out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-glob-bench/paths_50k.txt"
    rules_out = sys.argv[2] if len(sys.argv) > 2 else "/tmp/pion-glob-bench/rules_80.txt"
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 50000
    generate(paths_out, rules_out, count)
