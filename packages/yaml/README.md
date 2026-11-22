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
- **Security & DoS Hardening**:
  - Strict RFC 3629 UTF-8 and YAML 1.2 §5.1 `c-printable` validation (rejects invalid/overlong UTF-8 and raw C0 control characters).
  - YAML 1.2.2 §3.2.1.1 unique mapping key enforcement (zero-alloc linear scan for maps `<= 8` entries, O(1) hash table for larger maps; rejects duplicate keys and duplicate/non-mapping `<<` merges).
  - Recursive alias detection and per-document dual-dimension alias expansion budgets (`100,000` container nodes & `64 MiB` output bytes per document, scalar aliases exempt from node quota) + O(n) hash-indexed merge keys + `1,024` nesting depth limit.
- **Emitter & Canonical JSON**:
  - Pure Pion IEEE-754 binary64 shortest round-trip decimal formatter (`float_fmt.pion`, Dragon4) — bit-exact round-trip for `DBL_MAX`, subnormals, and 17-digit doubles.
  - `stringify(v : YamlValue) -> String`: round-trip-safe YAML 1.2 serializer (preserves `Float` vs `Int`, quotes `"..."`, `"<<"`, and BOM-prefixed strings, uses explicit `? ` keys for `>1024`-byte keys, and switches to compact flow style at deep nesting to prevent O(depth²) amplification).
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
pub fn write_canonical_json_to(sb : StringBuilder, v : YamlValue) -> Unit
```

## Compliance & Verification

Ported directly from the official [`yaml/yaml-test-suite`](https://github.com/yaml/yaml-test-suite) (`data` branch) plus real-world integration tests:

| Suite | Passed | Total | Coverage |
| --- | ---: | ---: | --- |
| Official `yaml-test-suite` (`in.json` valid cases) | **279** | **279** | 100.0% |
| Official `yaml-test-suite` (`error` rejection cases) | **94** | **94** | 100.0% |
| Real-world & Red-Team Unit Tests (K8s, CI, frontmatter, `<<` merges, Core Schema, Dragon4 IEEE-754 round-trip, duplicate-key & DoS guards) | **11** | **11** | 100.0% |
| **Total (`packages/yaml`)** | **384** | **384** | **100.0%** |
| Red-Team Audit Suite (`packages/yaml/audit`) | **26** | **26** | **100.0%** |

Dual-target verified:
- Native: `pionc fmt --check packages/yaml`, `pionc check --json packages/yaml`, `pionc test --json packages/yaml`, `pionc test --json packages/yaml/audit`
- Wasm32: `pionc build --target wasm32 -o /tmp/yaml_wasm_smoke.wasm packages/yaml/wasm_smoke`

## Head-to-Head Benchmark

Run reproducibly via `sh packages/yaml/bench/run_bench.sh` (using `scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification across all implementations and rounds):

- **Corpus**: 3.00 MB (`3,002,682 B`, 2,037 YAML documents) realistic mix of Kubernetes Deployments, GitHub Actions CI workflows, and OpenAPI 3.1 specifications.
- **Workload**: Full multi-document YAML parse (with strict UTF-8/C0 validation & duplicate-key enforcement) + deterministic canonical sorted-key JSON serialization (`2,234,058 B` stdout).
- **Platform**: `Darwin arm64` (Apple Silicon).

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_yaml_rust2`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_yaml` (`packages/yaml`, `--release`) | **58.561** | **57.310** | **61.059** | **51.27** | 33.91 MiB | **1.27x** |
| `rust_yaml_rust2` (`yaml-rust2 0.10.4`, `--release`) | 74.506 | 72.146 | 77.285 | 40.30 | 39.33 MiB | 1.00x (baseline) |
| `go_yaml_v3` (`gopkg.in/yaml.v3`) | 117.757 | 115.343 | 118.489 | 25.50 | 20.67 MiB | 0.63x |

_SHA-256 verified identical across all implementations and rounds: `d57e15ae46b8deb701bd42730f7d034287f48e4e7736d1e71249e80df449b633`._

Pion is **2.01x** faster than Go `yaml.v3` on this workload (117.757 / 58.561 ms).

### v0.2.0 Adversarial Benchmarks (`sh packages/yaml/audit/run_audit.sh`, SHA-256 identical)

Measured after red-team remediation (26/26 red-team tests pass; 400/402 `yaml-test-suite` cases on the audit oracle, matching `yaml-rust2`):

| Workload | `pion_yaml` | `rust_yaml_rust2` | Speedup (vs Rust) |
| --- | ---: | ---: | ---: |
| `wide_map` (one map, 101k keys) | 73.8 ms | 107.3 ms | **1.45x** |
| emit round-trip: `block_scalars` | 34.4 ms | 37.2 ms | **1.08x** |
| `dq_escapes` | 76.4 ms | 53.2 ms | 0.70x |

- Lagging item: `dq_escapes` is 0.70x of `yaml-rust2` (it is 44x faster than Go `yaml.v3` on the same input).
- DoS: the merge-key amplification probe dropped from 17.8 s to 0.11 s.
