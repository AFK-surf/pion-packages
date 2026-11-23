# `hyphenation` (`packages/hyphenation` v0.1.0)

Pure-Pion Knuth-Liang automatic hyphenation engine backed by a compact Double-Array Trie (DAT).

- **Zero dependencies / zero `World` / zero `extern "C"`** — runs identically on **Native** and **`wasm32`**.
- **Pluggable TeX dictionaries** via `Dictionary::from_tex` / `Dictionary::from_tex_with_limits` with explicit `Limits` DoS protection (`max_input_bytes`, `max_patterns`, `max_exceptions`, `max_pattern_len`, `max_exception_len`, `max_trie_nodes`).
- **Built-in US English (`Dictionary::en_us()`)** embedding the standard `hyph-utf8` `hyph-en-us` table (4,938 Knuth-Liang patterns + 14 TeXbook exceptions, `left_min = 2`, `right_min = 3`).
- **Zero-allocation hot path** (`opportunities_into`) with ASCII case-folding in the alphabet map, inline single-value bit-packing in the DAT, and UTF-8 scalar boundary safety for multi-byte inputs and dictionaries.

## API Overview

```pion
import "hyphenation"

let dict = hyphenation::Dictionary::en_us()

// UTF-8 byte offsets where hyphenation is permitted (strictly ascending)
let pts : Array[Int] = dict.opportunities("hyphenation")       // [2, 6]

// Zero-allocation reusable-buffer hot path
let buf : Array[Int] = Array::new()
dict.opportunities_into("algorithm", buf)                      // [2, 4]

// Word splitting & formatting
let parts = dict.split_word("algorithm")                       // ["al", "go", "rithm"]
let hyph  = dict.hyphenate("algorithm", "\u{00AD}")            // "al\u{00AD}go\u{00AD}rithm"
let text  = dict.hyphenate_text("Typography, algorithm!", "-") // "Ty-pog-ra-phy, al-go-rithm!"

// Custom TeX .pat.txt / .hyp.txt dictionary with explicit DoS limits
let custom = hyphenation::Dictionary::from_tex_with_limits(
  "ü1be be1ra",
  "",
  2,
  2,
  hyphenation::Limits::default(),
)
```

## Verification

```sh
sh scripts/verify.sh packages/hyphenation

# Four-mode smoke (Native/Wasm32 x debug/--release)
pionc run packages/hyphenation/wasm_smoke
pionc run --release packages/hyphenation/wasm_smoke
pionc run --target wasm32 packages/hyphenation/wasm_smoke
pionc run --release --target wasm32 packages/hyphenation/wasm_smoke
```

## Head-to-Head Benchmark (`Darwin arm64`)

Run via `sh packages/hyphenation/bench/run_bench.sh` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification). Both Pion and Rust `hyphenation v0.8.4` (`--release`, `lto = true`) execute on the identical `hyph-en-us` pattern (4,938) + exception (1,441) tables.

### 1. Batch Hyphenation (100,000 English words × 10 iters = 1,000,000 ops, 11.28 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_hyphenation`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 185.204 | 178.574 | 239.433 | 60.93 | 185.20 | 9.42 MiB | **3.38x** |
| `rust_hyphenation` | 625.071 | 565.817 | 787.238 | 18.05 | 625.07 | 4.95 MiB | 1.00x (baseline) |

Stdout SHA-256 verified identical: `f22b3487bf11537f355c73ec4915801d94c131afafea7151b1d6a42f7ba2ee7d`.

### 2. Dictionary Load (4,938 patterns + 1,441 exceptions × 20 loads)

Pion compiles raw TeX text (`from_tex`) into a Double-Array Trie at runtime (~3.28 ms/load), compared against Rust `hyphenation`'s pre-compiled `bincode` deserialization (`Standard::from_embedded`, ~0.65 ms/load):

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_hyphenation`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`from_tex`) | 65.601 | 60.840 | 66.893 | 3280035.40 | 3.95 MiB | 0.20x |
| `rust_hyphenation` (`bincode`) | 13.019 | 11.842 | 13.865 | 650964.55 | 2.22 MiB | 1.00x (baseline) |

Stdout SHA-256 verified identical: `cdeab529fc362287b4d90e9b7c588ba08067e86108ee3cad67a76b1dd8c52f32`.
