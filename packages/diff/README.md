# `diff` — Pure Pion Myers & Histogram Diff, Unified Patch, and 3-Way Merge

A pure Pion, zero-`World`, zero-C-glue high-performance diff, unified patch, and three-way merge library ported from Rust [`pascalkuthe/imara-diff`](https://github.com/pascalkuthe/imara-diff).

## Features

- **Three Core Algorithms** operating on dense integer token IDs (`Array[Int]`):
  - **`Algorithm::Histogram`**: Git's recommended high-readability diff algorithm with pooled occurrence lists (`ListPool`), O(1) generation-based clearing, and automatic Myers fallback on highly repetitive sequences (>63 occurrences).
  - **`Algorithm::Myers`**: Linear-space `O((N+M)D)` divide-and-conquer Myers with unmatched/common-line preprocessing and middle-snake heuristics.
  - **`Algorithm::MyersMinimal`**: Guaranteed minimal edit-script Myers (disables heuristic early-exit and common-line pruning).
- **Indentation Slider Postprocessing (`IndentHeuristic`)**: Ported from `imara-diff` / Git `xdiff` to align ambiguous insertion/deletion hunks cleanly on blank-line and indentation/brace boundaries, with exact cross-window boundary blank/indent propagation.
- **Single-Pass Zero-Substring Line Interning & Reuse**:
  - `intern_lines` splits and hashes lines in a single pass with per-input SplitMix64-seeded 64-bit keyed hashing (HashDoS-resistant) without allocating per-line `String` objects on the hot path.
  - `BeforeInterner` (`intern_before` / `diff_against_interned` / `unified_diff_against_interned`) pre-interns `before` once and reuses its token table, hash table, and cached indentation levels across repeated diffs against multiple `after` strings.
- **Standard GNU Unified Diff & Patch**:
  - `unified_diff(before, after, before_name, after_name, context, algo)` emits standard GNU unified diff format (including `@@ -N,0` empty-range headers and lossless `\ No newline at end of file` markers).
  - `parse_unified_patch`, `apply_unified_patch`, and `apply_unified_patch_reverse` with strict hunk/context validation and structured `Result[T, DiffError]` errors.
- **Three-Way Merge (`merge3`)**:
  - Cleanly merges disjoint edits and convergent identical edits; reports conflicts on both overlapping and adjacent edits (matching `git merge-file` / diff3 semantics).
  - Emits both structured `MergeChunk::Clean` / `MergeChunk::Conflict(base, ours, theirs)` chunks and standard `<<<<<<<` / `=======` / `>>>>>>>` conflict markers.
- **Native + Wasm32 Verified**: Zero `World` dependencies; compiles cleanly to both native targets and `wasm32`.

## Quick Start

```pion
import "diff"

pub fn example() -> Unit {
  let before = "fn foo() {\n    let a = 1;\n}\n"
  let after = "fn foo() {\n    let a = 2;\n    let b = 3;\n}\n"

  // 1. Line diff (Histogram or Myers)
  let res = diff::diff_lines(before, after, diff::Algorithm::Histogram)

  // 2. Unified diff & patch round-trip
  let patch = diff::unified_diff(
    before,
    after,
    "a/foo.pion",
    "b/foo.pion",
    3,
    diff::Algorithm::Histogram,
  )
  let _applied = diff::apply_unified_patch(before, patch)

  // 3. Three-way merge
  let merged = diff::merge3(before, after, before)
  let _text = merged.to_string()
}
```

## Public API

- `pub enum Algorithm { Myers, MyersMinimal, Histogram }`
- `pub val struct Hunk { pub before_start : Int, pub before_end : Int, pub after_start : Int, pub after_end : Int }`
- `pub struct DiffResult { pub hunks : Array[Hunk], pub before_len : Int, pub after_len : Int }`
- `pub struct BeforeInterner` (`intern_before`, `BeforeInterner::new`, `.diff`, `.diff_raw`, `.unified_diff`)
- `pub fn diff_lines(before : String, after : String, algo : Algorithm) -> DiffResult`
- `pub fn diff_lines_raw(before : String, after : String, algo : Algorithm) -> DiffResult`
- `pub fn diff_against_interned(interned : BeforeInterner, after : String, algo : Algorithm) -> DiffResult`
- `pub fn diff_raw_against_interned(interned : BeforeInterner, after : String, algo : Algorithm) -> DiffResult`
- `pub fn diff_slices(before : Array[String], after : Array[String], algo : Algorithm) -> DiffResult`
- `pub fn diff_tokens(before : Array[Int], after : Array[Int], num_tokens : Int, algo : Algorithm) -> DiffResult`
- `pub fn unified_diff(before : String, after : String, before_name : String, after_name : String, context : Int, algo : Algorithm) -> String`
- `pub fn unified_diff_against_interned(interned : BeforeInterner, after : String, before_name : String, after_name : String, context : Int, algo : Algorithm) -> String`
- `pub fn parse_unified_patch(patch : String) -> Result[UnifiedPatch, DiffError]`
- `pub fn apply_unified_patch(original : String, patch : String) -> Result[String, DiffError]`
- `pub fn apply_unified_patch_reverse(modified : String, patch : String) -> Result[String, DiffError]`
- `pub enum MergeChunk { Clean(Array[String]), Conflict(Array[String], Array[String], Array[String]) }`
- `pub struct MergeResult { pub chunks : Array[MergeChunk], pub has_conflicts : Bool }`
- `pub fn merge3(base : String, ours : String, theirs : String) -> MergeResult`

## Verification

```sh
# Format, typecheck, and run all 143 tests
sh scripts/verify.sh packages/diff

# Wasm32 smoke build
pionc build --target wasm32 packages/diff/wasm_smoke -o /tmp/diff_wasm_smoke.wasm
```

Red-team audit (`packages/diff/audit`, v0.2.0): 5/5 P0 red-team tests pass and the 5,000-case differential fuzz shows 0 window regressions. Reproduce with `sh packages/diff/audit/run_audit.sh`.

## v0.2.0 Head-to-Head Benchmark (Pion Native vs Rust `imara-diff v0.2.0 --release`)

Measured after red-team remediation on Apple M5 Max (Darwin arm64) via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, stdout SHA-256 byte-for-byte identical).

### Standard workloads (`sh packages/diff/bench/run_bench.sh`)

| Workload | `pion` Median | `rust-imara-diff` Median | Pion Throughput | Speedup (vs `rust-imara-diff`) |
| --- | ---: | ---: | ---: | ---: |
| Histogram + indent slider + unified diff (10,029 lines × 50, 32.4 MB) | 40.770 ms | 27.525 ms | 794 MB/s | 0.68x |
| Myers + indent slider + unified diff (10,029 lines × 30, 19.4 MB) | 95.474 ms | 83.445 ms | 204 MB/s | 0.87x |
| `helix_syntax.rs` Histogram + unified diff (2,200 lines × 200, 32.2 MB) | 26.469 ms | 23.935 ms | 1215 MB/s | 0.90x |

Peak RSS on `helix_syntax.rs`: 2.31 MiB (Pion) vs 2.39 MiB (`imara-diff`).

### Adversarial workloads (`sh packages/diff/audit/run_audit.sh`)

| Workload | v0.1.0 Pion | v0.2.0 Pion | `rust-imara-diff` | Speedup (vs `rust-imara-diff`) |
| --- | ---: | ---: | ---: | ---: |
| `hashflood` (80k colliding lines, 1.44 MB) | 2,458.9 ms | 10.870 ms (**226x faster**) | 10.629 ms | 0.98x |
| `edge_fallback` (200k lines, first line changed + 1 line added in a `}` block) | 71.9 ms | 37.615 ms (19.11 MiB) | 45.222 ms (21.16 MiB) | **1.20x** |
| `million` (1M lines, 1 line changed) | — | 44.373 ms | 237.054 ms | **5.34x** |
| `multi` (reused `BeforeInterner`) | — | 50.924 ms | 42.594 ms | 0.84x |

## v0.1.0 Head-to-Head Benchmark (historical, before red-team remediation)

Run via `sh packages/diff/bench/run_bench.sh` (`scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification). Measured on `Darwin arm64` (Apple Silicon):

### 1. Histogram Diff + Indent Slider + Unified Diff (10,029-line refactor × 50 iterations, 32.4 MB input)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs rust-imara-diff) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 43.250 | 40.681 | 44.360 | 748.77 | 3.39 MiB | 0.69x |
| `rust-imara-diff` | 29.832 | 27.861 | 30.330 | 1085.57 | 3.39 MiB | 1.00x (baseline) |

_Stdout (`67,406 B`) SHA-256 verified byte-for-byte identical: `fe0936eaa06404b6d49c707348a6790ff1234d4d3e27f14cc86d325d45a7b906`._

### 2. Myers Diff + Indent Slider + Unified Diff (10,029-line refactor × 30 iterations, 19.4 MB input)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs rust-imara-diff) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 100.018 | 94.026 | 119.974 | 194.27 | 4.09 MiB | 0.87x |
| `rust-imara-diff` | 86.980 | 83.921 | 89.967 | 223.39 | 4.03 MiB | 1.00x (baseline) |

_Stdout (`238,918 B`) SHA-256 verified byte-for-byte identical: `a61a0400fdf2028988aac61e9e10d5ee97136d733d2dcb02bbd6a572c1a2f038`._

### 3. Real-World `helix_syntax.rs` Histogram + Unified Diff (2,200-line file × 200 iterations, 32.2 MB input)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs rust-imara-diff) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 23.744 | 22.126 | 25.425 | 1354.85 | 2.31 MiB | **1.01x** |
| `rust-imara-diff` | 24.025 | 22.184 | 24.582 | 1338.98 | 2.39 MiB | 1.00x (baseline) |

_Stdout (`7,131 B`) SHA-256 verified byte-for-byte identical: `586c482f0fd9d4a787fbc561f69095e8395a2990128debd8d13230fcc70e33f8`._

**Notes**:
- Key optimizations: byte-level 4×/8× unrolled common prefix/suffix trimming (with exact slider-boundary fallback), lockstep predictive line matching in `after` interning, L1-sized packed `Int64` hash table `(hash32 << 32) | (tid + 1)` & packed `tok_span`, packed `Int64` `HistogramState.occ` with cursor-allocated pool and `cur_occ == 1` fast-path LCS extension, hoisted `is_odd` / `right = left` / zero-snake fast-path in `myers_split`, and direct single-`StringBuilder` unified diff emission without temporary hunk buffers.
- On real-world `helix_syntax.rs`, Pion Native reaches **1,215 MB/s (0.90x of Rust `imara-diff --release`)** in v0.2.0 (v0.1.0: 1,355 MB/s, 1.01x) with lower peak RSS (`2.31 MiB` vs `2.39 MiB`) and **byte-for-byte identical unified diff output** on the benchmark corpus (note: for empty-side headers and missing trailing newlines, Pion follows standard GNU `diff -u` conventions: `@@ -N,0` and `\ No newline at end of file`).
- On the 10K-line synthetic refactor (~90% middle window), Pion Native reaches **794 MB/s (0.68x)** on Histogram Diff and **204 MB/s (0.87x)** on Myers Diff in v0.2.0, where the remaining gap reflects QBE's scalar bounds-checked `code_unit_at` / `Array[Int]` accesses vs Rust's NEON SIMD `memchr`/`memcmp`, 64-bit `foldhash`, and unchecked `NonNull<i32>` pointers.
