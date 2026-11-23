# `glsl` (`v0.1.0`)

Pure Pion implementation of a **GLSL ES 1.00 (WebGL 1.0)** and **GLSL ES 3.00 (WebGL 2.0)** lexer, validator, reflector, and **OpenGL 4.10 Core** translator, with zero `extern "C"` and no `World` requirement.

Designed for real-world WebGL shaders (Three.js, Shadertoy, Framer, Figma, Spline) targeting macOS OpenGL 4.1 Core Profile and Linux OpenGL/Mesa.

## Features

- **Version-Aware Lexer & Safe Preprocessor**:
  - Handles `//` and `/* ... */` comment stripping, ES 3.00 physical `\` line-continuation splicing (across numbers, operators, and identifiers) while preserving ES 1.00 `//` comment-end semantics, and rejects null bytes and non-ASCII characters (including UTF-8 BOM) outside comments.
  - Validates `#version` placement (must be the first non-whitespace/non-comment token; defaults to `Es100` when absent; supports `#version 100` and `#version 300 es`; rejects unsupported versions).
  - Parses and records `#extension <name> : enable|require|warn|disable` directives, stripping ES/WebGL-only extensions (`GL_OES_*`, `GL_EXT_*`, `GL_WEBGL_*`, `GL_ANGLE_*`, `GL_NV_shadow_samplers_*`) in GLSL 410 Core output.
  - Preserves conditional compilation structure (`#define` / `#undef` / `#ifdef` / `#ifndef` / `#if` / `#elif` / `#else` / `#endif`), tracks per-branch bracket balance across `#if`/`#else`/`#elif`/`#endif`, uses O(1) `Map` macro tables, and supports Three.js WebGL2 compatibility preludes (`#define attribute in`, `#define varying out|in`, `#define gl_FragColor pc_fragColor`, `#define texture2D texture`).
  - Emits `#line <n>` directives so OpenGL 4.10 Core driver diagnostics map back to the original ES source lines.
- **GLSL ES 1.00 → OpenGL 4.10 Core Translation**:
  - Emits `#version 410 core`.
  - Strips `precision lowp|mediump|highp <type>;` statements and `lowp`/`mediump`/`highp` qualifiers across declarations, parameters, locals, structs, and `#define` bodies.
  - Flat token-level ES 1.00 rewrite pass (decoupled from declaration parsing so macro-qualified function signatures and macro-generated functions are always rewritten):
    - Rewrites top-level & macro-body `attribute` → `in` and `varying` → `out|in` by stage.
    - Detects `gl_FragColor` and `gl_FragData` in both code and `#define` bodies, injecting `out vec4 _fv_gl_FragColor;` and/or `out vec4 _fv_gl_FragData[N];` (`N = 8` for dynamic/expression/out-of-range indices, `max_idx + 1` for small literals), without touching struct member accesses (`.gl_FragColor`, `.texture2D`).
    - Rewrites all ES 1.00 built-in texture & depth symbols: `texture2D`/`textureCube`/`texture3D`/`shadow2D`/`shadow2DEXT` → `texture`, `texture2DProj`/`texture3DProj`/`shadow2DProj`/`shadow2DProjEXT` → `textureProj`, `texture2DLod`/`texture2DLodEXT`/`textureCubeLod`/`textureCubeLodEXT`/`texture3DLod` → `textureLod`, `texture2DGradEXT`/`textureCubeGradEXT` → `textureGrad`, `texture2DProjLod`/`texture2DProjLodEXT`/`texture3DProjLod` → `textureProjLod`, `texture2DProjGradEXT` → `textureProjGrad`, `gl_FragDepthEXT` → `gl_FragDepth`.
    - Safely renames ES 1.00 identifiers that are GLSL 4.10 keywords/reserved words (`sample`, `smooth`, `layout`, `uint`, `case`, `precise`, `common`, `partition`, `active`, `filter`, etc.), user identifiers shadowing rewritten 4.10 builtins (`texture`, `textureLod`, `textureProj`, `textureGrad`, `textureProjLod`, `textureProjGrad`), and user `_fv_*` identifiers to `_fv_u_<orig>` consistently across stages.
- **GLSL ES 3.00 (`#version 300 es`) → OpenGL 4.10 Core Translation**:
  - Upgrades `#version 300 es` → `#version 410 core` and strips precision statements/qualifiers.
  - Preserves `layout(location = N) in/out`, `layout(std140) uniform Block { ... }`, `flat`/`smooth`/`centroid`/`invariant`, `uint` literals, `texelFetch`, `textureLod`, `sampler2DArray`, `sampler3D`, `isampler2D`, `usampler2D`, etc.
  - Rejects removed ES 1.00 built-ins (`gl_FragColor`, `gl_FragData`, `texture2D`, etc.) unless redefined via `#define`.
  - Automatically injects pure GLSL 4.10 Core polyfills when `packHalf2x16`, `unpackHalf2x16`, `packSnorm2x16`, or `unpackSnorm2x16` are referenced (macOS OpenGL 4.1 Core lacks `GL_ARB_shading_language_packing`).
  - Safely renames GLSL 4.10-only keywords (`precise`, `sample`, `noperspective`, `patch`, `subroutine`, etc.) and user `_fv_*` identifiers to `_fv_u_<orig>`.
- **Stage, Overflow & DoS Safety (`ParseLimits`)**:
  - Overflow-safe `Int64` integer parsing for array sizes, `layout(location = N)`, and `gl_FragData` indices (returns `-1` instead of wrapping 32-bit `Int`).
  - Rejects unconditional stage mismatches while permitting `#ifdef VERTEX ... #else ... #endif` single-source uber shaders.
  - Enforces `max_source_bytes` (default 4 MiB), `max_tokens` (500,000), `max_nesting_depth` (128), `max_preprocessor_depth` (64), and `max_defines` (4,096). Values `<= 0` mean unlimited.
- **Known Reflection Limitations (Non-Preprocessing Frontend)**:
  - Because conditional `#if`/`#ifdef` blocks are preserved verbatim for the downstream GLSL 4.10 Core preprocessor, static reflection visits both arms of `#ifdef A uniform vec3 c; #else uniform vec4 c; #endif` and reports macro-typed declarations (`uniform TYPE x;`) using the unexpanded macro token (`"TYPE"`).

## Public API

```pion
pub enum ShaderStage {
  Vertex
  Fragment
}

pub enum GlslVersion {
  Es100
  Es300
}

pub val struct ParseLimits {
  pub max_source_bytes : Int
  pub max_tokens : Int
  pub max_nesting_depth : Int
  pub max_preprocessor_depth : Int
  pub max_defines : Int
}

pub struct VarInfo {
  pub name : String
  pub glsl_type : String
  pub array_size : Int
  pub location : Int
  pub precision : String
}

pub struct Reflection {
  pub version : GlslVersion
  pub stage : ShaderStage
  pub attributes : Array[VarInfo]
  pub uniforms : Array[VarInfo]
  pub varyings : Array[VarInfo]
  pub outputs : Array[VarInfo]
  pub extensions : Array[String]
  pub uses_frag_color : Bool
  pub uses_frag_data : Bool
  pub max_frag_data_index : Int
}

pub struct TranslatedShader {
  pub glsl410 : String
  pub reflection : Reflection
}

pub enum GlslError {
  EmptySource
  LimitExceeded(String)
  LexError(Int, String)
  PreprocessorError(Int, String)
  ParseError(Int, String)
  UnsupportedVersion(String)
  StageMismatch(String)
}

pub fn parse_and_reflect(source : String, stage : ShaderStage) -> Result[Reflection, GlslError]
pub fn parse_and_reflect_with_limits(source : String, stage : ShaderStage, limits : ParseLimits) -> Result[Reflection, GlslError]
pub fn translate_to_glsl410(source : String, stage : ShaderStage) -> Result[TranslatedShader, GlslError]
pub fn translate_to_glsl410_with_limits(source : String, stage : ShaderStage, limits : ParseLimits) -> Result[TranslatedShader, GlslError]
pub fn glsl_error_message(e : GlslError) -> String
```

## Verification

```sh
sh scripts/verify.sh packages/glsl
sh packages/glsl/audit/run_audit.sh all
```

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`ff7966c2ed555c87e9113c2010201f137efdf6c55e3d9d7f67b9b3c241ce4e83`):

```sh
pionc run packages/glsl/wasm_smoke
pionc run --release packages/glsl/wasm_smoke
pionc run --target wasm32 packages/glsl/wasm_smoke
pionc run --target wasm32 --release packages/glsl/wasm_smoke
```

### Real macOS OpenGL 4.1 Core Compilation & Linkage Verification

- **Red-team OpenGL 4.1 Core ground-truth judge (`sh packages/glsl/audit/run_audit.sh judge`)**: **75 / 75 PASS** (74/74 valid WebGL1/WebGL2 shader pairs compile & link on `4.1 Metal - 91.7 | GLSL: 4.10`, plus 1/1 invalid UTF-8 BOM control rejected).
- **Benchmark corpus (`packages/glsl/bench/verify_gl41.c`)**: **5 / 5 PASS** on `4.1 Metal - 91.7 | GLSL: 4.10`, with deterministic GLSL 410 Core output SHA-256:
  - `threejs_pbr_es100.vert` → `3b364e64dd417387...` (`glCompileShader` PASS)
  - `threejs_pbr_es100.frag` → `c7665e0292231374...` (`glCompileShader` PASS)
  - `shadertoy_es300.vert` → `4919d75f41c7810c...` (`glCompileShader` PASS)
  - `shadertoy_es300.frag` → `352746bb46231aa2...` (`glCompileShader` PASS)
  - `postprocess_2d_es100.frag` → `759174813b31928f...` (`glCompileShader` PASS)

## Head-to-Head Parse + Reflect Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/glsl/bench/run_bench.sh` against Rust **`glsl 7.0.0` (`--release`, LTO)** on real Three.js PBR (ES 1.00), WebGL2 Shadertoy raymarching (ES 3.00), and 2D post-process (ES 1.00) fragment shaders. Both implementations emit canonical reflection summaries (stage, version, attributes, uniforms, varyings, outputs, samplers, extensions, `gl_FragColor`/`gl_FragData`) verified **100% byte-for-byte identical via SHA-256**.

> **Scope & methodology**: This benchmark compares **parse + reflect** throughput (plus Pion's ES→410 token translation, validated separately via `glCompileShader`). Rust `glsl 7.0.0` constructs a full recursive-descent expression AST via `nom` and pretty-prints the original ES dialect without performing ES→410 translation; `packages/glsl` uses a single-pass lexer + top-level declaration parser + flat token-level GLSL 410 Core translator (and additionally supports `#ifdef`/`#if` inside function bodies, which `glsl 7.0.0` does not).

| Workload | `pion` Median (Throughput) | `rust_glsl` Median (Throughput) | `pion` Peak RSS | `rust_glsl` Peak RSS | `pion` vs `rust_glsl` | Reflection SHA-256 (identical) |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Three.js PBR ES 1.00 Frag (`4.77 KB × 500`) | 63.358 ms (37.61 MB/s) | 1505.716 ms (1.58 MB/s) | 2.25 MiB | 2.75 MiB | **23.77x** | `a1a0175c13201ce9...` |
| WebGL2 Shadertoy ES 3.00 Frag (`2.88 KB × 500`) | 38.506 ms (37.33 MB/s) | 1502.805 ms (0.96 MB/s) | 2.12 MiB | 2.67 MiB | **39.03x** | `f848fbeb2be7e14d...` |
| 2D Post-Process ES 1.00 Frag (`1.44 KB × 500`) | 35.911 ms (20.08 MB/s) | 910.515 ms (0.79 MB/s) | 2.05 MiB | 2.56 MiB | **25.35x** | `6afda6cb4886d4b6...` |
