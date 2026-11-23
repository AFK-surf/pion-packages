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

- **Compliance & Adversarial Test Suite**: `pionc test --json packages/wasm` — **13 / 13 passing** (covering LEB128 u32/u64/i32/i64/s33, all 12 sections + Custom/`name`, streaming `Parser`, all instruction families including SIMD `0xFD`, 36 Node.js v24 V8 `WebAssembly.validate` cross-verified valid/invalid vectors, complex recursive/loop/indirect-call modules, and `ValidateLimits` DoS bombs).
- **Self-Hosting Real-World Binary Validation**: Decoded, validated, re-encoded, and disassembled `packages/wasm/wasm_smoke` compiled with `pionc build --target wasm32 --release` (**295,229 B**, 157 functions, 4,264 locals, 128,427 instructions), matching both Node.js `WebAssembly.validate` and Rust `wasmparser 0.221.3` identically.
- **Dual-Target Wasm32 Smoke (`packages/wasm/wasm_smoke`)**: All 4 build modes (Native debug/release + Wasm32 debug/release) exit `0` with byte-identical stdout (`sha256:317ffbc8f75a2ad22c2fe64217674c198a7b9d3a4a20efa7cd432856e77514e5`).
- **Formatting & Typecheck**: `sh scripts/verify.sh packages/wasm` passes with 0 diagnostics and a clean worktree.

## Head-to-Head Benchmarks

Measured on `Darwin arm64` via `sh packages/wasm/bench/run_bench.sh` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) on a real **295,229 B (288 KiB)** compiler-generated `.wasm` corpus (`wasm_smoke` compiled with `pionc --target wasm32 --release`: 30 types, 17 imports, 157 functions, 4,264 locals, 128,427 instructions), comparing:
- **`pion`**: `packages/wasm` (`pionc 0.1.0 --release`)
- **`rust_wasmparser` / `rust_wasmtools`**: Rust (`wasmparser 0.221.3`, `wasm-encoder 0.221.3`, `wasmprinter 0.221.3`, `--release --locked`)

### W1. Full Binary Decode + Instruction Traversal (20 × 295,229 B = 5,904,580 B; 2,568,540 instructions)

_SHA-256 verified identical across all implementations and rounds: `50a0c1dd425cc955e9afd2a02644b7849658c5ffa3a878186809ac62efe273a7`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_wasmparser`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 108.210 | 107.186 | 114.771 | 54.57 | 5410506.25 | 8.12 MiB | 0.28x |
| `rust_wasmparser` | 29.889 | 29.401 | 31.449 | 197.55 | 1494468.75 | 2.56 MiB | 1.00x (baseline) |

### W2. Full WebAssembly Spec Validation (20 × 295,229 B = 5,904,580 B)

_SHA-256 verified identical across all implementations and rounds: `097653bf210a6585add32de2fc30efaa54938c515f1288e55eedf27e2e42c5f0`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_wasmparser`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 205.000 | 202.994 | 222.167 | 28.80 | 10250020.85 | 8.69 MiB | 0.16x |
| `rust_wasmparser` | 32.166 | 29.080 | 36.796 | 183.57 | 1608285.40 | 3.67 MiB | 1.00x (baseline) |

### W3. Decode → Re-encode + WAT Disassembly (5 × 295,229 B = 1,476,145 B)

_SHA-256 verified identical across all implementations and rounds: `42866e81e2dcbe4d0d33cb3e9de83cd6eac493a5fef1915733111a05e1b6f159`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_wasmtools`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 209.035 | 189.675 | 211.922 | 7.06 | 41807016.80 | 93.00 MiB | 0.45x |
| `rust_wasmtools` | 94.846 | 91.846 | 101.842 | 15.56 | 18969150.00 | 16.36 MiB | 1.00x (baseline) |

### Analysis

- **W1 (Decode, 54.6 MB/s, 0.28× Rust)**: `packages/wasm` materializes the full `Module` and `Array[Instr]` AST for all 128,427 instructions in each round, whereas `wasmparser::Parser` streams zero-copy `Operator` values without allocating an AST.
- **W2 (Validate, 28.8 MB/s, 0.16× Rust)**: `validate_bytes` currently runs a two-pass pipeline (full AST decode + AST walk with multi-stage instruction dispatch), whereas `wasmparser::Validator` validates in a single streaming pass over raw bytes. Adding a direct streaming validator pass is the clearest future optimization.
- **W3 (Roundtrip + WAT, 7.06 MB/s, 0.45× Rust)**: Once full materialization, re-encoding, and text formatting are included on both sides, Pion reaches **0.45×** of Rust `wasm-encoder` + `wasmprinter`. Peak RSS in W3 (`93.00 MiB` vs `16.36 MiB`) comes from per-instruction temporary `String` allocations (`i.to_string()`, `byte_hex`) during WAT formatting of 128k instructions.
