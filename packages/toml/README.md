# `toml`

Pure Pion TOML v1.0.0 parser, serializer, and `toml-test` tagged JSON encoder.

- **Zero C glue / zero `World` dependency** — works identically on Native and `wasm32`.
- **100% TOML v1.0.0 compliant** — passes all official `toml-lang/toml-test` v2.2.0 TOML 1.0.0 test cases (**205/205** valid, **474/474** invalid, **205/205** encoder) plus in-repo compliance, roundtrip, accessor, and red-team regression tests (**729 / 729** total).
- **Bit-exact IEEE-754 shortest roundtrip float formatting (Ryu)** — pure Pion 128-bit integer arithmetic guarantees `strtod(fmt(x)) == x` for 100% of finite binary64 doubles (including `DBL_MAX`, `DBL_MIN`, subnormals, `-0.0`, `inf`, `nan`).
- **Hardened against adversarial inputs** — explicit recursion depth guard (`128` levels for arrays, inline tables, dotted headers/keys), O(1)-amortized inline table sealing, seeded open-addressing hash index (HashDoS-resistant), strict `stringify` validation (duplicate keys & datetime injection rejection), float overflow rejection (`1e400`), UTF-8 BOM support, and character-accurate error locations.
- **Fast O(1) `toml::get` & direct `TomlValue` construction** — preserves insertion order for deterministic serialization while caching a seeded hash index for wide tables and avoiding intermediate tree copies.

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

Steady-state parsing of a realistic 150.5 KB TOML v1.0.0 workspace & service configuration corpus (50 iterations = 7.53 MB total input) via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) against **Rust `toml 1.2.2`** (`--release`, LTO) and **Go `BurntSushi/toml`**:

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `203 B` (`sha256:96cf0bf395d107be...`) | Input: `7526500 B` | Ops: `50`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_toml 1.2.2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 100.995 | 86.022 | 113.517 | 74.52 | 2019898.34 | 3.50 MiB | 0.93x |
| `rust_toml` | 93.422 | 91.795 | 98.200 | 80.56 | 1868440.00 | 6.92 MiB | 1.00x (baseline) |
| `go_burntsushi` | 262.027 | 257.532 | 369.302 | 28.72 | 5240550.00 | 15.62 MiB | 0.36x |

Reproduce:

```sh
sh packages/toml/bench/run_bench.sh
```
