# `hyphenation` (`packages/hyphenation` v0.1.0)

Pure-Pion Knuth-Liang automatic hyphenation engine backed by a compact Double-Array Trie (DAT).

- **Zero dependencies / zero `World` / zero `extern "C"`** — runs identically on **Native** and **`wasm32`** (4-mode SHA-256 verified).
- **Pluggable TeX dictionaries** via `Dictionary::from_tex` / `Dictionary::from_tex_with_limits` with explicit overflow-safe `Limits` DoS protection (`max_input_bytes`, `max_patterns`, `max_exceptions`, `max_pattern_len`, `max_exception_len`, `max_trie_nodes`).
- **Built-in US English (`Dictionary::en_us()`)** embedding the complete `hyph-utf8` `hyph-en-us` table (**4,938** Knuth-Liang patterns + **1,441** exceptions, `left_min = 2`, `right_min = 3`), matching Rust `hyphenation =0.8.4` (`Language::EnglishUS`).
- **Compact Double-Array Trie hot path** (`opportunities_into`) with reusable output buffer (allocates one compact per-word scratch `FixedArray` of length `2 * word_bytes + 5`), zero `String` allocations on ASCII words, inline single-value bit-packing, and full Unicode simple lowercase folding (including Turkish `İ -> i`, Greek final `Σ -> ς`, Cyrillic, Greek, Armenian, Georgian, and Latin extensions) + UTF-8 scalar boundary safety.
- **TeX & Unicode text fidelity**: honours existing soft hyphens (`U+00AD`), supports dictionaries whose patterns include `-` (e.g. `hyph-ru`/`uk`/`be`/`pt`/`tk`/`af`), keeps first pattern on duplicate keys (matching Rust `hyphenation =0.8.4`), and classifies Unicode punctuation/whitespace boundaries cleanly in `hyphenate_text`.

## API Overview

```pion
import "hyphenation"

let dict = hyphenation::Dictionary::en_us()

// UTF-8 byte offsets where hyphenation is permitted (strictly ascending)
let pts : Array[Int] = dict.opportunities("hyphenation")       // [2, 6, 7]

// Reusable-output-buffer hot path
let buf : Array[Int] = Array::new()
dict.opportunities_into("algorithm", buf)                      // [2, 4]

// Word splitting & formatting
let parts = dict.split_word("algorithm")                       // ["al", "go", "rithm"]
let hyph  = dict.hyphenate("algorithm", "\u{00AD}")            // "al\u{00AD}go\u{00AD}rithm"
let text  = dict.hyphenate_text("computer\u{2014}typography", "-") // "com-puter\u{2014}ty-pog-ra-phy"

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

Run via `packages/hyphenation/audit/scripts/bench_fair.py` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification). Both Pion (`--release`) and Rust `hyphenation =0.8.4` (`--release`, `lto = true`) execute on the identical `hyph-en-us` 4,938-pattern + 1,441-exception tables.

### 1. Batch Hyphenation — `bench100k` (100,000 draws × 10 iters = 1,000,000 ops, 10.28 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_hyph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_into` | **144.435** | 142.740 | 155.014 | **71.21** | **144.44** | 10.02 MiB | **3.38x** |
| `pion_alloc` | 145.391 | 143.380 | 149.541 | 70.74 | 145.39 | 10.02 MiB | 3.35x |
| `rust_hyph` | 487.704 | 472.676 | 509.784 | 21.09 | 487.70 | 9.06 MiB | 1.00x (baseline) |
| `rust_opp` | 475.928 | 448.806 | 499.748 | 21.61 | 475.93 | 12.94 MiB | 1.02x |

Stdout SHA-256 verified identical: `569e94245a2ebfa02b5152c63d86f731704a7cc8b5cadbe4a0cf98f0f34254c5`.

### 2. Batch Hyphenation — Full Distinct Dictionary (`235,915` distinct words × 10 iters = 2,359,150 ops, 22.57 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_hyph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_into` | **457.358** | 450.269 | 729.512 | **49.36** | **193.87** | 18.58 MiB | **2.53x** |
| `pion_alloc` | 466.959 | 464.261 | 633.838 | 48.34 | 197.94 | 18.58 MiB | 2.47x |
| `rust_hyph` | 1154.906 | 1126.700 | 1227.287 | 19.55 | 489.54 | 15.56 MiB | 1.00x (baseline) |
| `rust_opp` | 1156.373 | 1093.154 | 2045.208 | 19.52 | 490.17 | 21.98 MiB | 1.00x |

Stdout SHA-256 verified identical: `9a65ebd3301a0401dfa90968e96d0a34ad36bc8ed6a15952b2a0476fc2f78b26`.

### 3. Dictionary Load (4,938 patterns + 1,441 exceptions × 20 loads)

Fair text-to-trie comparison (`pion_from_tex` vs `rust_from_text` via `Parse::pair` + `fst::Builder`), alongside Rust's pre-compiled `bincode` deserialization (`rust_bincode`):

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_from_text`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_from_tex` | **33.691** | 32.945 | 34.960 | **1,684,545.80** | 4.72 MiB | **1.02x** |
| `rust_from_text` | 34.398 | 32.425 | 40.342 | 1,719,883.35 | 4.48 MiB | 1.00x (baseline) |
| `rust_bincode` (pre-compiled) | 10.458 | 10.082 | 11.593 | 522,904.20 | 2.23 MiB | 3.29x |

Stdout SHA-256 verified identical: `bd519a5b90095c9523b1d7ca8d114f327f4b87d62b2eec8f11c1560c84c5ca6b`.
