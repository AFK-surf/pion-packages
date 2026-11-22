# `diff` — Pure Pion Myers & Histogram Diff, Unified Patch, and 3-Way Merge

A pure Pion, zero-`World`, zero-C-glue high-performance diff, unified patch, and three-way merge library ported from Rust [`pascalkuthe/imara-diff`](https://github.com/pascalkuthe/imara-diff).

## Features

- **Two Core Algorithms** operating on dense integer token IDs (`Array[Int]`):
  - **`Algorithm::Histogram`**: Git's recommended high-readability diff algorithm with pooled occurrence lists (`ListPool`), O(1) generation-based clearing, and automatic Myers fallback on highly repetitive sequences (>63 occurrences).
  - **`Algorithm::Myers`**: Linear-space `O((N+M)D)` divide-and-conquer Myers with unmatched/common-line preprocessing and middle-snake heuristics.
- **Indentation Slider Postprocessing (`IndentHeuristic`)**: Ported from `imara-diff` / Git `xdiff` to align ambiguous insertion/deletion hunks cleanly on blank-line and indentation/brace boundaries.
- **Single-Pass Zero-Substring Line Interning**: `intern_lines` splits and hashes lines in a single pass over the input without allocating per-line `String` objects on the hot path.
- **Standard Unified Diff & Patch**:
  - `unified_diff(before, after, before_name, after_name, context, algo)` with configurable context lines and `\ No newline at end of file` markers.
  - `parse_unified_patch`, `apply_unified_patch`, and `apply_unified_patch_reverse` with strict hunk/context validation and structured `Result[T, DiffError]` errors.
- **Three-Way Merge (`merge3`)**:
  - Cleanly merges disjoint edits and convergent identical edits.
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

- `pub enum Algorithm { Myers, Histogram }`
- `pub val struct Hunk { pub before_start : Int, pub before_end : Int, pub after_start : Int, pub after_end : Int }`
- `pub struct DiffResult { pub hunks : Array[Hunk], pub before_len : Int, pub after_len : Int }`
- `pub fn diff_lines(before : String, after : String, algo : Algorithm) -> DiffResult`
- `pub fn diff_lines_raw(before : String, after : String, algo : Algorithm) -> DiffResult`
- `pub fn diff_slices(before : Array[String], after : Array[String], algo : Algorithm) -> DiffResult`
- `pub fn diff_tokens(before : Array[Int], after : Array[Int], num_tokens : Int, algo : Algorithm) -> DiffResult`
- `pub fn unified_diff(before : String, after : String, before_name : String, after_name : String, context : Int, algo : Algorithm) -> String`
- `pub fn parse_unified_patch(patch : String) -> Result[UnifiedPatch, DiffError]`
- `pub fn apply_unified_patch(original : String, patch : String) -> Result[String, DiffError]`
- `pub fn apply_unified_patch_reverse(modified : String, patch : String) -> Result[String, DiffError]`
- `pub enum MergeChunk { Clean(Array[String]), Conflict(Array[String], Array[String], Array[String]) }`
- `pub struct MergeResult { pub chunks : Array[MergeChunk], pub has_conflicts : Bool }`
- `pub fn merge3(base : String, ours : String, theirs : String) -> MergeResult`

## Verification

```sh
# Format, typecheck, and run all 136 tests
sh scripts/verify.sh packages/diff

# Wasm32 smoke build
pionc build --target wasm32 packages/diff/wasm_smoke -o /tmp/diff_wasm_smoke.wasm
```

## Head-to-Head Benchmark (Pion Native vs Rust `imara-diff v0.2.0 --release`)

Run via `sh packages/diff/bench/run_bench.sh` (`scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification). Measured on `Darwin arm64` (Apple Silicon):

### 1. Histogram Diff + Indent Slider + Unified Diff (10,029-line refactor × 50 iterations, 32.4 MB input)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs rust-imara-diff) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 115.493 | 113.648 | 121.808 | 280.40 | 4.44 MiB | 0.26x |
| `rust-imara-diff` | 30.316 | 30.020 | 32.131 | 1068.23 | 3.39 MiB | 1.00x (baseline) |

_Stdout (`67,406 B`) SHA-256 verified byte-for-byte identical: `fe0936eaa06404b6d49c707348a6790ff1234d4d3e27f14cc86d325d45a7b906`._

### 2. Myers Diff + Indent Slider + Unified Diff (10,029-line refactor × 30 iterations, 19.4 MB input)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs rust-imara-diff) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 174.831 | 164.568 | 203.590 | 111.14 | 5.00 MiB | 0.55x |
| `rust-imara-diff` | 96.955 | 82.300 | 108.232 | 200.41 | 4.03 MiB | 1.00x (baseline) |

_Stdout (`238,918 B`) SHA-256 verified byte-for-byte identical: `a61a0400fdf2028988aac61e9e10d5ee97136d733d2dcb02bbd6a572c1a2f038`._

### 3. Real-World `helix_syntax.rs` Histogram + Unified Diff (2,200-line file × 200 iterations, 32.2 MB input)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs rust-imara-diff) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 83.214 | 83.037 | 87.081 | 386.59 | 2.73 MiB | 0.32x |
| `rust-imara-diff` | 26.269 | 24.617 | 27.731 | 1224.62 | 2.39 MiB | 1.00x (baseline) |

_Stdout (`7,131 B`) SHA-256 verified byte-for-byte identical: `586c482f0fd9d4a787fbc561f69095e8395a2990128debd8d13230fcc70e33f8`._

**Notes**:
- Rust `imara-diff` benefits from SIMD `memchr`, `foldhash`, and LLVM `-O3` + LTO; Pion Native reaches **280–387 MB/s** on Histogram Diff (0.26x–0.32x of Rust) and **111 MB/s** on Myers Diff (**0.55x of Rust**) with ~2.7–5.0 MiB peak RSS and **100% byte-for-byte identical unified diff output**.
- Consistent with `imara-diff`, Histogram Diff in Pion is **~2.5x faster** than Myers on large refactors while producing 3.5x smaller, more readable diffs.
