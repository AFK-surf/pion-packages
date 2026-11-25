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

- **Compliance & Adversarial Test Suite**: `pionc test --json packages/wasm` — **15 / 15 passing** (covering LEB128 u32/u64/i32/i64/s33, all 12 sections + Custom/`name`, streaming `Parser`, all instruction families including SIMD `0xFD`, 36 Node.js v24 V8 `WebAssembly.validate` cross-verified valid/invalid vectors, complex recursive/loop/indirect-call modules, `ValidateLimits` DoS bombs, and red-team P0/P1/P2 regressions).
- **Red-Team Audit (`packages/wasm/audit`)**:
  - `pionc test --json --only-pkg packages/wasm/audit` — **63 / 63 PASS** (27/27 red-team defect tests + 36/36 control tests, 0 FAIL).
  - `STRICT=1 sh packages/wasm/audit/run_audit.sh` — **20,335 modules** (335 hand-written + 20,000 fuzz) three-way differential against Rust `wasmparser 0.221.3 (WASM2)` and Node v24 V8: **0 `ACCEPTS_INVALID`, 0 `ACCEPTS_NON_WASM2`, 0 `REJECTS_VALID`, 0 aborts**; **5,565 / 5,565 (100%)** WASM2-valid fuzz modules disassemble via `print_wat` to valid WAT verified `EQ` by `wat::parse_str` + `wasmprinter` (**0 `PARSE_FAIL`, 0 `SEM_DIFF`**); Native vs Wasm32 4-mode **0 diffs, 0 traps**.
  - DoS probes: `straight_line_900k_instrs` in **10 ms** (`0.9x` Rust `wasmparser`'s 12 ms); `funcs_200k_tiny` in **31 ms / 11.4 MiB** (`0.7x` `wasmparser`'s 42 ms / 17.1 MiB); `locals_50k_x2000funcs` in **11 ms** (`1.0x` `wasmparser`).
- **Dual-Target Wasm32 Smoke (`packages/wasm/wasm_smoke`)**: All 4 build modes (Native debug/release + Wasm32 debug `409,519 B` / release `401,175 B`) exit `0` with byte-identical stdout (`sha256:317ffbc8f75a2ad22c2fe64217674c198a7b9d3a4a20efa7cd432856e77514e5`).
- **Formatting & Typecheck**: `sh scripts/verify.sh packages/wasm` passes with 0 diagnostics and a clean worktree.

## Formal Verification (Lean 4)

The core WebAssembly 2.0 type codec, canonical section ordering, polymorphic stack type matcher, limits validator, and strict LEB128 terminal-byte checks in `packages/wasm/src/` (`ValType`, `val_type_code`, `val_type_from_code`, `val_type_equals`, `RefType`, `ref_type_code`, `ref_type_from_code`, `ref_type_to_val_type`, `ExportKind`, `export_kind_code`, `Limits`, `Limits::new`, `section_order_rank`, `val_type_to_id`, `ref_type_to_id`, `is_ref_id`, `stack_type_compat`, `limits_err_code`, `leb128_i32_single_byte`, `leb128_u32_5th_valid`, `leb128_u64_10th_valid`, `leb128_i32_5th_valid`, `leb128_i64_10th_valid`, `leb128_s33_5th_valid`) are annotated with `#verify`, extracted directly into Lean 4 via `pionc extract-lean`, and mechanically proved in `packages/wasm/proofs/` (**24 theorems, 0 `sorry` / `admit` / `bv_decide` / `native_decide`, standard axioms only**):

- **`WasmProofs/CodecAndTypes.lean` (12 theorems)**: Exact lossless encode/decode round-trip and injectivity for `ValType` and `RefType`, reference-to-value type embedding compatibility, `ExportKind` injectivity, abstract stack ID range `[0, 6]` & reference-type equivalence, and WebAssembly 2.0 canonical section ordering (`DataCount = 12` ranked `10` strictly between `Element = 9` and `Code = 10` / `Data = 11`, injective on all 12 standard sections).
- **`WasmProofs/ValidateAndLeb128.lean` (12 theorems)**: Polymorphic stack type compatibility (reflexive, symmetric, universal `vt_unknown = -1`, exact equality on concrete types), complete WebAssembly 2.0 §3.2.5 `Limits` validity characterization (`limits_err_code` and `Limits::new`), single-byte signed LEB128 range `[-64, 63]`, and exact Wasm 2.0 §5.2.2 terminal-byte acceptance sets for `u32`, `u64`, `i32` (`0x00..0x07 ∪ 0x78..0x7F`), `i64` (`{0x00, 0x7F}`), and `s33` (`0x00..0x0F ∪ 0x70..0x7F`).
- **Differential Cross-Check**: `packages/wasm/proofs/EvalDiff.lean` cross-checks 44 cases between Native Pion execution and Lean 4 `#eval` (`diff -u` exit `0`). Run `sh packages/wasm/proofs/run_proofs.sh` to reproduce end-to-end.

## Head-to-Head Benchmarks

Measured on `Linux x86_64` via `sh packages/wasm/bench/run_bench.sh` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) on a real **401,175 B (392 KiB)** compiler-generated `.wasm` corpus (`wasm_smoke` compiled with `pionc --target wasm32 --release`), comparing:
- **`pion`**: `packages/wasm` (`pionc 0.1.0 --release`, zero-`Result`-boxing `ByteReader`/`ValState` raw primitives, table-driven numeric/memory opcode dispatch, cached top control frame, reused flat locals & `CtrlFrame` pool, single-pass streaming `validate_bytes`, pre-allocated `decode_expr` + `ByteWriter` reuse, and 50-level capped zero-alloc `print_wat`)
- **`rust_wasmparser` / `rust_wasmtools`**: Rust (`wasmparser 0.221.3`, `wasm-encoder 0.221.3`, `wasmprinter 0.221.3`, `--release --locked`)

### W1. Full Binary Decode + Instruction Traversal (20 × 401,175 B = 8,023,500 B)

_SHA-256 verified identical across all implementations and rounds: `929b78dd2a3576b3a3123b4422ac83693069c0489a477e7838559a5f2149e44f`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Speedup (vs `rust_wasmparser`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 91.758 | 62.879 | 109.392 | 87.44 | 4587903.95 | 0.66x (min 0.91x) |
| `rust_wasmparser` | 60.182 | 57.441 | 76.737 | 133.32 | 3009077.85 | 1.00x (baseline) |

### W2. Full WebAssembly Spec Validation (20 × 401,175 B = 8,023,500 B)

_SHA-256 verified identical across all implementations and rounds: `eb39b84fe2a0d6b85a52e783bb843cca287918a5d22b8a0b810cb081ab164b44`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Speedup (vs `rust_wasmparser`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **54.803** | **41.726** | 111.011 | **146.41** | 2740155.65 | **1.09x** |
| `rust_wasmparser` | 59.629 | 44.378 | 83.210 | 134.56 | 2981451.60 | 1.00x (baseline) |

### W3. Decode → Re-encode + WAT Disassembly (5 × 401,175 B = 2,005,875 B)

_SHA-256 verified identical across all implementations and rounds: `f5e8458c37e1d5f6851650bf8986008b687c851277be5cade3246903f205db59`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Speedup (vs `rust_wasmtools`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **139.996** | **108.634** | **153.895** | **14.33** | 27999139.80 | **2.38x** |
| `rust_wasmtools` | 333.410 | 200.889 | 433.426 | 6.02 | 66682006.40 | 1.00x (baseline) |

### Before / After Optimization Summary (Same-Machine Fixed 396,823 B Corpus)

| Workload | Before (`f66e02f5`) | After (Zero-Boxing + Tables + Flat Locals) | Speedup vs Before |
| --- | --- | --- | --- |
| W1 Decode | 201.98–300.31 ms (`0.21x–0.26x` Rust) | **58.14–91.12 ms (`0.70x–0.91x` Rust)** | **3.3×–3.5× faster** |
| W2 Validate | 153.67–240.22 ms (`0.19x–0.23x` Rust) | **37.71–54.80 ms (`1.00x–1.09x` Rust)** | **3.7×–4.1× faster (beats Rust)** |
| W3 Roundtrip + WAT | 495.63 ms (`1.01x` Rust) | **140.00–320.84 ms (`1.56x–2.38x` Rust)** | **1.5×–2.4× faster** |

### Analysis

- **W1 (Decode, 87.4 MB/s, 0.66× median / 0.91× min Rust)**: Eliminating per-byte/per-LEB128 `Result` boxing in `ByteReader`, replacing the 128-arm numeric opcode `match` with an O(1) `decode_num_instr_table` lookup, pre-allocating `instrs` via `Array::with_capacity`, and splitting `decode_expr` into compact helpers accelerated `decode_module` **3.3×–3.5×**. The remaining gap vs `wasmparser::Parser` is structural: `decode_module` heap-materializes every payload-bearing `Instr` enum variant into `Array[Instr]` (`pion_alloc_uninit` + `pion_arr_push_owned`), whereas `wasmparser::Parser` streams stack-only `Operator` values without building an AST.
- **W2 (Validate, 146.4 MB/s, 1.09× Rust)**: Replacing per-instruction `Result`-boxed `ValState`/`ByteReader` calls with error-slot `*_raw` primitives, caching `top_height`/`top_unreachable`, reusing `CtrlFrame` slots and a flat `local_types` buffer (`<= 256` locals, RLE `LocalTable` fallback for DoS bombs), and dispatching `0x45..0xC4` / `0x28..0x3E` via compact lookup tables eliminated 5–7 heap allocations per instruction, accelerating validation **3.7×–4.1×** to **1.09×** of Rust `wasmparser`.
- **W3 (Roundtrip + WAT, 14.3 MB/s, 2.38× Rust)**: Eliminating per-instruction `Result` boxing in `encode_instr_raw`, reusing a single `ByteWriter` across function bodies, and adding single-byte LEB128 fast paths in `ByteWriter` pushed W3 to **2.38×** of Rust `wasm-encoder` + `wasmprinter`.
