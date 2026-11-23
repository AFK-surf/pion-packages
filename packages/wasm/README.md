# `wasm` — Pure Pion WebAssembly 1.0/2.0 Binary Codec, Validator & WAT Disassembler

A pure Pion, zero-dependency, Native + Wasm32 compatible implementation of a **WebAssembly 1.0/2.0 binary decoder**, **streaming section parser**, **specification abstract-stack validator**, **canonical binary encoder / `ModuleBuilder`**, and **WAT text disassembler**, modeled on Rust `wasmparser` + `wasm-encoder` + `wasmprinter` and cross-verified against Node.js V8 `WebAssembly.validate`.

Designed with a **Sans-IO** architecture: zero `World` dependency, 100% iterative decoding and validation (no recursion), flat integer-coded abstract value stack in the validator hot loop, exact IEEE 754 bit-pattern preservation for `f32.const` / `f64.const`, and configurable `DecodeLimits` / `ValidateLimits` to defend against malicious binaries.

## Features

- **Strict LEB128 & UTF-8 (`ByteReader`, `ByteWriter`)**:
  - `u32`, `u64`, `i32`, `i64`, and `s33` (for `BlockType`) with fast 1-byte paths and strict WebAssembly bit-width & sign-extension validation (accepts valid non-minimal encodings within max byte length; rejects overlong sequences and invalid unused high bits).
  - Strict RFC 3629 UTF-8 validation on all WebAssembly names.
- **Full Binary Decoder & Streaming `Parser` (`decode_module`, `Parser`, `decode_name_section`)**:
  - Parses all 12 standard sections (`Type`, `Import`, `Function`, `Table`, `Memory`, `Global`, `Export`, `Start`, `Element`, `DataCount`, `Code`, `Data`) plus `Custom` sections and the `name` custom section (module, function, local, type, table, memory, global, elem, and data names).
  - Enforces strict section ordering (including `DataCount=12` between `Element=9` and `Code=10`) and rejects duplicate standard sections.
  - Full instruction decoding across **MVP**, **Sign-Extension (`0xC0..0xC4`)**, **Non-Trapping Float-to-Int (`0xFC 0..7`)**, **Bulk-Memory & Table (`0xFC 8..17`)**, **Multi-Value**, **Reference Types (`0xD0..0xD2`, `0x1C`, `0x25..0x26`)**, and **SIMD (`0xFD`)**.
- **WebAssembly 1.0/2.0 Abstract Stack Validator (`validate_module`, `validate_bytes`, `ValidateLimits`)**:
  - Full index-space validation (types, imported + defined functions, tables, memories, globals, elements, data, unique export names, `start` signature `() -> ()`).
  - Constant expression validation for global initializers, active element/data offsets, and element item expressions.
  - Full polymorphic abstract stack & control-flow validation (`block`, `loop`, `if`, `else`, `end`, `br`, `br_if`, `br_table`, `return`, `unreachable`, `call`, `call_indirect`, `select` / typed `select`, `local.*`, `global.*`, `table.*`, memory `align <= natural_align`, bulk memory `DataCount` requirement, reference types, and SIMD lane/alignment checks).
  - Configurable `ValidateLimits` protecting against control-depth bombs, stack-height bombs, and excessive locals/tables/memories.
- **Canonical Binary Encoder & `ModuleBuilder` (`encode_module`, `ModuleBuilder`)**:
  - Lossless roundtrip encoding back to spec-compliant `.wasm` binaries (preserving exact `f32`/`f64` bit patterns, `v128` 16-byte payloads, and auto-emitting `DataCount` when bulk-memory instructions are present).
- **WAT Disassembler (`print_wat`)**:
  - Emits readable, indented WebAssembly Text Format `(module ...)` with types, imports, functions, locals, control-flow indentation, `memarg`, `br_table`, hex-float / `inf` / `nan:0x...` literals, escaped strings, exports, start, elements, and data segments.

## Quick Start

```pion
import "wasm"

// Build a module programmatically
let b = wasm::ModuleBuilder::new()
let t0 = b.add_type([wasm::ValType::I32, wasm::ValType::I32], [wasm::ValType::I32])
let f0 = b.add_func(t0, [], [
  wasm::Instr::LocalGet(0),
  wasm::Instr::LocalGet(1),
  wasm::Instr::I32Add,
  wasm::Instr::End,
])
b.add_export("add", wasm::ExportKind::Func, f0)

// Encode -> Decode -> Validate -> Disassemble
match b.encode() {
  Ok(bytes) => {
    match wasm::validate_bytes(bytes) {
      Ok(_) => {
        match wasm::decode_module(bytes) {
          Ok(m) => {
            let wat = wasm::print_wat(m)
            let _ = wat
          }
          Err(_) => ()
        }
      }
      Err(_) => ()
    }
  }
  Err(_) => ()
}
```

## Verification

- **Compliance & Adversarial Test Suite**: `pionc test --json packages/wasm` — **14 / 14 passing** (covering LEB128 u32/u64/i32/i64/s33, all 12 sections + Custom/`name`, streaming `Parser`, all instruction families including SIMD `0xFD`, 36 Node.js v24 V8 `WebAssembly.validate` cross-verified valid/invalid vectors, complex recursive/loop/indirect-call modules, `ValidateLimits` DoS bombs, and red-team P0/P1/P2 regressions).
- **Red-Team Audit (`packages/wasm/audit`)**:
  - `pionc test --json --only-pkg packages/wasm/audit` — **63 / 63 PASS** (27/27 red-team defect tests + 36/36 control tests, 0 FAIL).
  - `sh packages/wasm/audit/run_audit.sh` — **20,335 modules** (335 hand-written + 20,000 fuzz) three-way differential against Rust `wasmparser 0.221.3 (WASM2)` and Node v24 V8: **0 `ACCEPTS_INVALID`, 0 `ACCEPTS_NON_WASM2`, 0 `REJECTS_VALID`, 0 aborts**; **5,565 / 5,565 (100%)** WASM2-valid fuzz modules disassemble via `print_wat` to valid WAT verified `EQ` by `wat::parse_str` + `wasmprinter` (**0 `PARSE_FAIL`, 0 `SEM_DIFF`**); Native vs Wasm32 4-mode **0 diffs, 0 traps**.
  - DoS probes: 100,000 exports validate in **90 ms** (down from 7,291 ms, **81×** faster); `locals_50k_x2000funcs` in **12 ms / 2.0 MiB** (faster than `wasmparser`'s 16 ms / 2.7 MiB).
- **Dual-Target Wasm32 Smoke (`packages/wasm/wasm_smoke`)**: All 4 build modes (Native debug/release + Wasm32 debug/release) exit `0` with byte-identical stdout (`sha256:317ffbc8f75a2ad22c2fe64217674c198a7b9d3a4a20efa7cd432856e77514e5`).
- **Formatting & Typecheck**: `sh scripts/verify.sh packages/wasm` passes with 0 diagnostics and a clean worktree.

## Formal Verification (Lean 4)

The core WebAssembly 2.0 type codec, canonical section ordering, polymorphic stack type matcher, limits validator, and strict LEB128 terminal-byte checks in `packages/wasm/src/` (`ValType`, `val_type_code`, `val_type_from_code`, `val_type_equals`, `RefType`, `ref_type_code`, `ref_type_from_code`, `ref_type_to_val_type`, `ExportKind`, `export_kind_code`, `Limits`, `Limits::new`, `section_order_rank`, `val_type_to_id`, `ref_type_to_id`, `is_ref_id`, `stack_type_compat`, `limits_err_code`, `leb128_i32_single_byte`, `leb128_u32_5th_valid`, `leb128_u64_10th_valid`, `leb128_i32_5th_valid`, `leb128_i64_10th_valid`, `leb128_s33_5th_valid`) are annotated with `#verify`, extracted directly into Lean 4 via `pionc extract-lean`, and mechanically proved in `packages/wasm/proofs/` (**24 theorems, 0 `sorry` / `admit` / `bv_decide` / `native_decide`, standard axioms only**):

- **`WasmProofs/CodecAndTypes.lean` (12 theorems)**: Exact lossless encode/decode round-trip and injectivity for `ValType` and `RefType`, reference-to-value type embedding compatibility, `ExportKind` injectivity, abstract stack ID range `[0, 6]` & reference-type equivalence, and WebAssembly 2.0 canonical section ordering (`DataCount = 12` ranked `10` strictly between `Element = 9` and `Code = 10` / `Data = 11`, injective on all 12 standard sections).
- **`WasmProofs/ValidateAndLeb128.lean` (12 theorems)**: Polymorphic stack type compatibility (reflexive, symmetric, universal `vt_unknown = -1`, exact equality on concrete types), complete WebAssembly 2.0 §3.2.5 `Limits` validity characterization (`limits_err_code` and `Limits::new`), single-byte signed LEB128 range `[-64, 63]`, and exact Wasm 2.0 §5.2.2 terminal-byte acceptance sets for `u32`, `u64`, `i32` (`0x00..0x07 ∪ 0x78..0x7F`), `i64` (`{0x00, 0x7F}`), and `s33` (`0x00..0x0F ∪ 0x70..0x7F`).
- **Differential Cross-Check**: `packages/wasm/proofs/EvalDiff.lean` cross-checks 44 cases between Native Pion execution and Lean 4 `#eval` (`diff -u` exit `0`). Run `sh packages/wasm/proofs/run_proofs.sh` to reproduce end-to-end.

## Head-to-Head Benchmarks

Measured on `Darwin arm64` via `sh packages/wasm/bench/run_bench.sh` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) on a real **395,839 B (387 KiB)** compiler-generated `.wasm` corpus (`wasm_smoke` compiled with `pionc --target wasm32 --release`), comparing:
- **`pion`**: `packages/wasm` (`pionc 0.1.0 --release`, single-pass streaming `validate_bytes` + 50-level capped zero-alloc `print_wat`)
- **`rust_wasmparser` / `rust_wasmtools`**: Rust (`wasmparser 0.221.3`, `wasm-encoder 0.221.3`, `wasmprinter 0.221.3`, `--release --locked`)

### W1. Full Binary Decode + Instruction Traversal (20 × 395,839 B = 7,916,780 B)

_SHA-256 verified identical across all implementations and rounds: `6b66e630579352fa769e377b3a245b568e7e56e941fa2c6c3042a8c0308edf7c`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_wasmparser`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 127.484 | 127.245 | 127.900 | 62.10 | 6374222.95 | 10.36 MiB | 0.25x |
| `rust_wasmparser` | 31.710 | 30.928 | 32.015 | 249.66 | 1585485.45 | 2.66 MiB | 1.00x (baseline) |

### W2. Full WebAssembly Spec Validation (20 × 395,839 B = 7,916,780 B)

_SHA-256 verified identical across all implementations and rounds: `287af374249e47090d6b0852050f1282b3514eb61a076e5bc4b17a60db1ad8f5`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_wasmparser`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 105.034 | 104.840 | 106.352 | 75.37 | 5251722.90 | **3.06 MiB** | 0.28x |
| `rust_wasmparser` | 29.676 | 29.273 | 29.852 | 266.77 | 1483795.85 | 3.77 MiB | 1.00x (baseline) |

### W3. Decode → Re-encode + WAT Disassembly (5 × 395,839 B = 1,979,195 B)

_SHA-256 verified identical across all implementations and rounds: `8963bf896344fc386c8e339173be862d377e30a538dff7d43b5525750dcfd924`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_wasmtools`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **86.426** | 85.767 | 88.055 | **22.90** | 17285250.00 | 41.30 MiB | **1.24x** |
| `rust_wasmtools` | 107.445 | 106.149 | 107.714 | 18.42 | 21489025.00 | 20.50 MiB | 1.00x (baseline) |

### Before / After Optimization Summary

| Workload | Before (295 KiB corpus) | After (396 KiB corpus) | Delta |
| --- | --- | --- | --- |
| W1 Decode | 54.57 MB/s · 8.12 MiB · 0.28x | 62.10 MB/s · 10.36 MiB · 0.25x | +14% throughput |
| W2 Validate | 28.80 MB/s · 8.69 MiB · 0.16x | **75.37 MB/s · 3.06 MiB · 0.28x** | **2.62x throughput, -65% RSS (below Rust 3.77 MiB)** |
| W3 Roundtrip + WAT | 7.06 MB/s · 93.00 MiB · 0.45x | **22.90 MB/s · 41.30 MiB · 1.24x** | **3.24x throughput (1.24x Rust), -56% RSS** |

### Analysis

- **W1 (Decode, 62.1 MB/s, 0.25× Rust)**: `decode_module` materializes the full `Module` and `Array[Instr]` AST for every instruction in each round, whereas `wasmparser::Parser` streams zero-copy `Operator` values without allocating an AST.
- **W2 (Validate, 75.4 MB/s, 0.28× Rust, 3.06 MiB RSS)**: `validate_bytes` now runs a **single-pass streaming validator** directly over raw bytes with zero `Instr` AST allocation, RLE `LocalTable`, pre-converted type tables, and a reused `ValState` — boosting throughput **2.62×** and cutting Peak RSS to **3.06 MiB** (lower than Rust `wasmparser`'s 3.77 MiB).
- **W3 (Roundtrip + WAT, 22.9 MB/s, 1.24× Rust)**: Capping `write_indent` at 50 levels (matching `wasmprinter`) and writing integers/hex/bytes directly to `StringBuilder` without per-instruction temporary `String`/`Bytes` allocations cut W3 RSS from **93.00 MiB → 41.30 MiB** (even on a 34% larger corpus) and accelerated W3 to **1.24×** of Rust `wasm-encoder` + `wasmprinter`.
