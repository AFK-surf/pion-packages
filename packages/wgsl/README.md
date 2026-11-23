# `wgsl` (v0.1.0)

100% pure Pion W3C WGSL frontend (lexer, recursive-descent parser, AST, static semantic validator, module reflection) and deterministic dual-backend transpiler (**WGSL → Metal Shading Language 2.x** & **WGSL → GLSL ES 3.00 / GLSL 450 Compute**).

- **Zero `extern "C"`**, **zero `World`**, **zero external dependencies**, **zero module-level mutable globals** in `src/`.
- **DoS-hardened** via `ParseLimits` (`max_source_bytes`, `max_tokens`, `max_nesting_depth`) with structured `WgslError` diagnostics carrying 1-based `(line, col)`.
- **Zero-string-allocation flat token stream** (`val struct WgslToken`) and direct `StringBuilder` codegen for high throughput and minimal RSS.

## Public API

```pion
import "wgsl"

// Parse only -> Result[WgslModule, WgslError]
wgsl::parse(source, wgsl::ParseLimits::default())

// Parse + static validation + reflection -> Result[ModuleReflection, WgslError]
wgsl::validate(source, wgsl::ParseLimits::default())
wgsl::reflect(source)

// Transpile to Metal Shading Language (MSL 2.x) -> Result[CompiledModule, WgslError]
wgsl::compile_to_msl(source, wgsl::CompileOptions::default())

// Transpile to GLSL ES 3.00 (vertex/fragment) or GLSL 450 (compute)
wgsl::compile_to_glsl(source, wgsl::CompileOptions::with_entry_point("vs_main"))

// Entry point lookup
wgsl::find_entry_point(compiled.reflection, "vs_main")
```

## Verification

- **Unit & compliance tests**: `sh scripts/verify.sh packages/wgsl` (20/20 passing).
- **4-mode Wasm32 + Native determinism** (`packages/wgsl/wasm_smoke`): `native_dbg`, `native_rel`, `wasm_dbg`, and `wasm_rel` produce byte-identical stdout (`sha256: 2a4018786372cfad...`).
- **Apple Metal compiler validation**: Generated MSL 2.x for PBR Render (Vertex + Fragment), Compute Reduction, and Particle Physics Compute shaders all compile cleanly with `xcrun -sdk macosx metal -x metal -std=macos-metal2.4`.

## Head-to-Head Benchmark vs Rust `naga` (`=24.0.0`, `--release`)

Run via `sh packages/wgsl/bench/run_bench.sh` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, mandatory SHA-256 stdout match):

Workload: 200 iterations × 3 realistic shaders (PBR Render + Compute Reduction + Particle Simulation = `1,014,000 B` input, `1,400` full parse + validate + MSL/GLSL emit passes).

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_naga`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_wgsl` | 93.374 | 86.112 | 101.014 | 10.86 | 66695.60 | 2.50 MiB | **1.88x** |
| `rust_naga` | 175.349 | 170.247 | 185.433 | 5.78 | 125249.11 | 4.47 MiB | 1.00x (baseline) |

> Note: `rust_naga` performs full WGSL type inference/checking and IR lowering in addition to syntax/structural validation and backend emission, whereas `pion_wgsl` performs lightweight static semantic validation + AST-to-MSL/GLSL emission. Both compile the exact same 3-shader corpus through parse + validate + MSL + GLSL emit with byte-identical reflection & header verification stdout (`sha256: 6e66de24898b48469f8f2344442668fc1e35ede7ba40009fe3d884c55b0d03f1`).
