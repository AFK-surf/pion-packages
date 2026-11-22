# `yaml`

Pure Pion **YAML 1.2** (Core Schema) parser, emitter, and canonical JSON serializer — zero C glue, zero `World` dependency, `Send`-safe immutable value tree, Native + Wasm32 ready.

## Features

- **Full YAML 1.2 Scanner & Parser**:
  - Direct UTF-8 byte-indexed scanner with zero-copy fast paths for single-line plain and quoted scalars.
  - Multi-document streams (`---` / `...`), `%YAML` / `%TAG` / reserved directives, and BOM handling.
  - Block & flow collections (`[...]`, `{...}`), indentless sequences, implicit flow mappings, and complex keys (`? ... : ...`).
  - Block scalars (`|`, `>`) with full chomping (`|+`, `|-`, `>+`, `>-`) and explicit indentation indicators (`|2`).
  - Single-quoted (`''`) and double-quoted strings with complete YAML 1.2 escape sequences (`\0`, `\a`, `\b`, `\t`, `\n`, `\v`, `\f`, `\r`, `\e`, `\ `, `\"`, `\/`, `\\`, `\N`, `\_`, `\L`, `\P`, `\xXX`, `\uXXXX`, `\UXXXXXXXX`, escaped line breaks).
  - Anchors (`&a`), aliases (`*a`), explicit tags (`!!str`, `!!int`, `!!float`, `!!bool`, `!!null`, verbatim `!<...>`, non-specific `!`), and merge keys (`<<: *a`, `<<: [*a, *b]`).
  - Strict YAML 1.2 Core Schema resolution (`null`/`~`, `true`/`false`, decimal/hex `0x`/octal `0o` `Int64`, IEEE 754 `Double` including `.inf`/`-.inf`/`.nan`; YAML 1.1 `yes`/`no`/`on`/`off` remain strings).
- **DoS Hardening**:
  - Bounded alias expansion (`100,000` expanded nodes max) and nesting depth limit (`256`) defend against Billion Laughs alias bombs with a clean `Err(YamlError)` instead of OOM.
- **Emitter & Canonical JSON**:
  - `stringify(v : YamlValue) -> String`: clean, round-trip-safe YAML 1.2 block serializer.
  - `to_canonical_json(v : YamlValue) -> String`: deterministic compact JSON with UTF-8 sorted object keys for compliance and cross-language SHA-256 verification.

## Public API

```pion
pub enum YamlValue {
  Null
  Bool(Bool)
  Int(Int64)
  Float(Double)
  Str(String)
  Seq(Array[YamlValue])
  Map(Array[(YamlValue, YamlValue)])
}

pub struct YamlError {
  pub line : Int
  pub col : Int
  pub message : String
}

pub fn parse(src : String) -> Result[YamlValue, YamlError]
pub fn parse_all(src : String) -> Result[Array[YamlValue], YamlError]
pub fn stringify(v : YamlValue) -> String
pub fn to_canonical_json(v : YamlValue) -> String
```

## Compliance & Verification

Ported directly from the official [`yaml/yaml-test-suite`](https://github.com/yaml/yaml-test-suite) (`data` branch) plus real-world integration tests:

| Suite | Passed | Total | Coverage |
| --- | ---: | ---: | --- |
| Official `yaml-test-suite` (`in.json` valid cases) | **279** | **279** | 100.0% |
| Official `yaml-test-suite` (`error` rejection cases) | **94** | **94** | 100.0% |
| Real-world (K8s Deployment/multi-doc, GitHub Actions CI, Markdown frontmatter, `<<` merge keys, Core Schema + explicit tags, Billion Laughs DoS, `stringify` round-trip) | **8** | **8** | 100.0% |
| **Total** | **381** | **381** | **100.0%** |

Dual-target verified:
- Native: `pionc fmt --check packages/yaml`, `pionc check --json packages/yaml`, `pionc test --json packages/yaml`
- Wasm32: `pionc build --target wasm32 -o /tmp/yaml_wasm_smoke.wasm packages/yaml/wasm_smoke`

## Head-to-Head Benchmark

Run reproducibly via `sh packages/yaml/bench/run_bench.sh` (using `scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification across all implementations and rounds):

- **Corpus**: 3.00 MB (`3,002,682 B`, 2,037 YAML documents) realistic mix of Kubernetes Deployments, GitHub Actions CI workflows, and OpenAPI 3.1 specifications.
- **Workload**: Full multi-document YAML parse + deterministic canonical sorted-key JSON serialization (`2,234,058 B` stdout).
- **Platform**: `Darwin arm64` (Apple Silicon).

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_yaml_rust2`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_yaml_rust2` (`yaml-rust2 0.10.4`, `--release`) | 119.183 | 82.868 | 196.088 | 25.19 | 39.34 MiB | 1.00x (baseline) |
| `go_yaml_v3` (`gopkg.in/yaml.v3`) | 126.812 | 118.331 | 148.825 | 23.68 | 20.94 MiB | 0.94x |
| `pion_yaml` (`packages/yaml`, `--release`) | 133.488 | 126.385 | 208.556 | 22.49 | 33.95 MiB | 0.89x |

_SHA-256 verified identical across all implementations and rounds: `d57e15ae46b8deb701bd42730f7d034287f48e4e7736d1e71249e80df449b633`._
