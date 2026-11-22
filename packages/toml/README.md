# `toml`

Pure Pion TOML v1.0.0 parser, serializer, and `toml-test` tagged JSON encoder.

- **Zero C glue / zero `World` dependency** — works identically on Native and `wasm32`.
- **100% TOML v1.0.0 compliant** — passes all **717 / 717** official `toml-lang/toml-test` v1.0.0 test cases (208 valid + 509 invalid, including strict UTF-8 / UTF-16 BOM validation) plus roundtrip and accessor tests (**722 / 722** total).
- **Deterministic insertion-order tables** — preserves key order for stable `stringify` output while using internal `Map[String, Int]` indexing for O(1) duplicate/conflict checks during parsing.
- **Bit-exact IEEE 754 float formatting** — preserves full 17-digit double precision on roundtrip.

## API

```pion
pub struct TomlError {
  pub line : Int
  pub col : Int
  pub offset : Int
  pub message : String
}

pub enum TomlValue {
  Str(String)
  Int(Int64)
  Float(Double)
  Bool(Bool)
  OffsetDateTime(String)
  LocalDateTime(String)
  LocalDate(String)
  LocalTime(String)
  Array(Array[TomlValue])
  Table(Array[(String, TomlValue)])
}

pub fn parse(src : String) -> Result[TomlValue, TomlError]
pub fn parse_bytes(src : Bytes) -> Result[TomlValue, TomlError]
pub fn stringify(value : TomlValue) -> Result[String, TomlError]
pub fn to_toml_test_json(value : TomlValue) -> String

// Convenience accessors
pub fn get(value : TomlValue, key : String) -> Option[TomlValue]
pub fn get_index(value : TomlValue, index : Int) -> Option[TomlValue]
pub fn as_str(value : TomlValue) -> Option[String]
pub fn as_int(value : TomlValue) -> Option[Int64]
pub fn as_float(value : TomlValue) -> Option[Double]
pub fn as_bool(value : TomlValue) -> Option[Bool]
pub fn as_datetime(value : TomlValue) -> Option[String]
pub fn as_local_datetime(value : TomlValue) -> Option[String]
pub fn as_local_date(value : TomlValue) -> Option[String]
pub fn as_local_time(value : TomlValue) -> Option[String]
pub fn as_array(value : TomlValue) -> Option[Array[TomlValue]]
pub fn as_table(value : TomlValue) -> Option[Array[(String, TomlValue)]]
pub fn value_len(value : TomlValue) -> Int
pub fn is_empty(value : TomlValue) -> Bool
```

## Example

```pion
import "toml"

let doc = "title = \"Pion\"\n[server]\nport = 8080\n"
match toml::parse(doc) {
  Ok(root) => {
    let encoded = toml::stringify(root)
    let tagged = toml::to_toml_test_json(root)
    let _ = (encoded, tagged)
  }
  Err(e) => {
    // e.line, e.col, e.offset, e.message
    let _ = e
  }
}
```

## Verification

```sh
pionc fmt --check packages/toml
pionc check --json packages/toml
pionc test --json packages/toml
pionc build --target wasm32 -o /tmp/toml_wasm_smoke.wasm packages/toml/wasm_smoke
```

## Head-to-Head Benchmark

Steady-state parsing of a realistic 150.5 KB TOML v1.0.0 workspace & service configuration corpus (50 iterations = 7.53 MB total input) via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification):

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `203 B` (`sha256:96cf0bf395d107be...`) | Input: `7526500 B` | Ops: `50`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_toml) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 119.644 | 102.283 | 130.105 | 62.91 | 2392885.00 | 4.56 MiB | 1.49x |
| `rust_toml` | 178.392 | 158.839 | 184.359 | 42.19 | 3567831.66 | 7.45 MiB | 1.00x (baseline) |
| `go_burntsushi` | 288.358 | 273.687 | 299.497 | 26.10 | 5767160.84 | 13.50 MiB | 0.62x |

Reproduce:

```sh
sh packages/toml/bench/run_bench.sh
```
