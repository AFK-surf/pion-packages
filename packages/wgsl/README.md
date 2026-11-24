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

Measured at release (Wave 21, `tokyo-mac-studio-0`, Apple M5 Max, Darwin arm64, `pionc 0.1.0` self-hosted, warm `PION_CACHE_DIR`):

- **Unit & compliance tests**: `sh scripts/verify.sh packages/wgsl` (20/20 passing).
- **4-mode Wasm32 + Native determinism** (`packages/wgsl/wasm_smoke`): `native_dbg`, `native_rel`, `wasm_dbg` and `wasm_rel` each print `5,312 B` of byte-identical stdout (`sha256: e6cfe5f0fefe1503c736e7a303b5cf6e436b95d55e603f71bfacfe7a38ff9455`).
- **Red-team audit** (`sh packages/wgsl/audit/run_audit.sh`, `audit/` unchanged since the independent Opus audit): **exit 0, `AUDIT RESULT: PASS`**. All 4 P0 + 7 P1 + 5 P2 findings in [`audit/AUDIT_REPORT.md`](audit/AUDIT_REPORT.md) are fixed:
  - `build` / `portability`: 0 `extern "C"`, 0 `World`, 0 module-level mutable state in `src/`;
  - `selftest`: 56 cases (7 controls + 49 red-team) × 4 modes; `unit`: package 20/20, audit `control_*` 7/7 and `redteam_*` 49/49;
  - `judge`: **47/47** valid corpus shaders (naga `=24.0.0` accepts) return `Ok` and the emitted MSL compiles with `xcrun -sdk macosx metal -std=macos-metal2.4` and the emitted GLSL passes `glslangValidator` 16.6.0 (including the three bench shaders); **49/49** invalid shaders (naga rejects) are rejected with `line:col`;
  - `gpu`: **10/10** compute kernels run on the local Apple Silicon Metal GPU match the WGSL-specified result (`- -x`, `arrayLength`, `continue` → `continuing`, `vec3` / `@size` struct layout, `round` half-to-even, zero-initialised function / private / workgroup memory, plus 3 controls);
  - `dos`: **104/104** hostile inputs (26 inputs × 4 modes, up to 2 MB: nesting / chain / token / identifier bombs, including limits set to 0 or negative) end in ≤ 0.23 s with a structured error or bounded output, 0 crashes;
  - `fuzz`: **5,000 mutants × 4 modes** (seed `20261124`), 0 crash / 0 hang, byte-identical verdicts across all 4 modes. Agreement with naga (information only): both accept 62, both reject 4,741, pion accepts / naga rejects 13, pion rejects / naga accepts 184 (174 of them are mutants truncated to comments or whitespace, which naga accepts as an empty module and `wgsl` rejects with `EmptySource`; 10 are parse rejections).

## Head-to-Head Benchmark vs Rust `naga` (`=24.0.0`, `--release`)

Run via `sh packages/wgsl/bench/run_bench.sh` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, mandatory SHA-256 stdout match):

Workload: 200 iterations × 3 realistic shaders (PBR Render + Compute Reduction + Particle Simulation = `1,014,000 B` input, `1,400` full parse + validate + MSL/GLSL emit passes).

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_naga`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_wgsl` | **121.677** | 118.496 | 125.682 | 8.33 | 86911.79 | **3.19 MiB** | **1.36x** |
| `rust_naga` | 165.073 | 154.963 | 218.984 | 6.14 | 117909.02 | 4.47 MiB | 1.00x (baseline) |

Both sides print the same `74 B` stdout (`sha256: 6e66de24898b48469f8f2344442668fc1e35ede7ba40009fe3d884c55b0d03f1`). The bench section of `audit/run_audit.sh`, run on the same machine minutes earlier, measured 119.795 ms vs 160.174 ms (**1.34x**, 3.19 vs 4.47 MiB). The pre-fix headline (`93.374 ms`, `1.88x`) no longer applies: the red-team fixes added name resolution, typing and control-flow checks to the validator and made the emitted MSL / GLSL compile.

**What the two pipelines do (red-team P2-5).** The numbers compare different amounts of work and should be read that way:

- `pion_wgsl` lexes and parses to an AST, runs its static validator (name resolution, type checking, attribute / layout / entry-point and control-flow rules that the judge and red-team gates exercise) and emits MSL and GLSL directly from the AST.
- `rust_naga` parses and lowers to naga IR (name resolution, full type inference) and runs `naga::valid::Validator` with `ValidationFlags::all()` (including uniformity and control-flow analysis) before the MSL and GLSL backends.
- Stage split on the same corpus (200 × 3 shaders, one pass each, `run_audit.sh bench`): `pion_wgsl` parse 26 ms, parse + validate 41 ms; `naga` parse (includes lowering) 45.6 ms, parse + validate 49.7 ms. Most of the end-to-end gap is therefore parsing and emission, not validation.
- The bench stdout is six counters (entries, bindings, workgroup size sum, MSL / GLSL ok counts), so the SHA-256 gate proves both sides processed the same corpus, not that the generated code is equal; and `glsl_ok` only checks the `#version ` prefix. Whether that code actually compiles is checked separately by the audit `judge` gate (Metal + glslang accept `wgsl`'s output for all three bench shaders).
