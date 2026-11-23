# `glsl` (`v0.1.0`)

Pure Pion implementation of a **GLSL ES 1.00 (WebGL 1.0)** and **GLSL ES 3.00 (WebGL 2.0)** lexer, validator, reflector, and **OpenGL 4.10 Core** translator, with zero `extern "C"` and no `World` requirement.

Designed for real-world WebGL shaders (Three.js, Shadertoy, Framer, Figma, Spline) targeting macOS OpenGL 4.1 Core Profile and Linux OpenGL/Mesa.

## Features

- **Single-Pass Lexer & Safe Preprocessor**:
  - Handles `//` and `/* ... */` comment stripping, `\` line continuation splicing with accurate 1-based line numbers, and rejects null bytes and non-ASCII characters outside comments.
  - Validates `#version` placement (must be the first non-whitespace/non-comment token; defaults to `Es100` when absent; supports `#version 100` and `#version 300 es`; rejects unsupported versions).
  - Parses and records `#extension <name> : enable|require|warn|disable` directives, automatically stripping ES/WebGL-only extensions (`GL_OES_*`, `GL_EXT_*`, `GL_WEBGL_*`, `GL_ANGLE_*`, `GL_NV_shadow_samplers_*`) in GLSL 410 Core output.
  - Preserves conditional compilation structure (`#define` / `#undef` / `#ifdef` / `#ifndef` / `#if` / `#elif` / `#else` / `#endif`), tracks `#if` nesting balance, resolves simple integer `#define` constants for reflected array sizes, and rewrites ES 1.00 texture calls / `gl_FragColor` inside `#define` bodies without breaking `#if` branches.
- **GLSL ES 1.00 → OpenGL 4.10 Core Translation**:
  - Emits `#version 410 core`.
  - Strips `precision lowp|mediump|highp <type>;` statements and `lowp`/`mediump`/`highp` qualifiers across top-level declarations, function parameters, local variables, and struct members.
  - Vertex stage: rewrites top-level `attribute` → `in` and `varying` → `out`.
  - Fragment stage: rewrites top-level `varying` → `in`; injects `out vec4 _fv_gl_FragColor;` when `gl_FragColor` is used and `out vec4 _fv_gl_FragData[N];` when `gl_FragData[i]` is used, replacing standalone references without touching struct member accesses (`.gl_FragColor`, `.texture2D`).
  - Rewrites ES 1.00 built-in texture calls (`texture2D`/`textureCube` → `texture`, `texture2DProj` → `textureProj`, `texture2DLod`/`texture2DLodEXT`/`textureCubeLod`/`textureCubeLodEXT` → `textureLod`, `texture2DGradEXT`/`textureCubeGradEXT` → `textureGrad`, `texture2DProjLodEXT` → `textureProjLod`, `shadow2D`/`shadow2DEXT` → `texture`).
- **GLSL ES 3.00 (`#version 300 es`) → OpenGL 4.10 Core Translation**:
  - Upgrades `#version 300 es` → `#version 410 core` and strips precision statements/qualifiers.
  - Preserves `layout(location = N) in/out`, `layout(std140) uniform Block { ... }`, `flat`/`smooth`/`centroid`/`invariant`, `uint` literals, `texelFetch`, `textureLod`, `sampler2DArray`, `sampler3D`, `isampler2D`, `usampler2D`, etc.
  - Accurately reflects `layout(location = N)`, uniform blocks, multi-declarators (`uniform vec3 a, b[4];`), and ignores function parameters when collecting stage I/O.
- **Stage & DoS Safety (`ParseLimits`)**:
  - Rejects stage mismatches (e.g., `gl_FragColor`/`discard` in vertex shaders; `attribute`/`gl_Position` in fragment shaders).
  - Enforces `max_source_bytes` (default 4 MiB), `max_tokens` (500,000), `max_nesting_depth` (128), `max_preprocessor_depth` (64), and `max_defines` (4,096).
  - **`<= 0` Semantics**: any limit field `<= 0` means unlimited.

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
```

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`4c000f8c1ea6d9732bd461059789eef5b06dee5327bfdf005e9ce70851a05a05`):

```sh
pionc run packages/glsl/wasm_smoke
pionc run --release packages/glsl/wasm_smoke
pionc run --target wasm32 packages/glsl/wasm_smoke
pionc run --target wasm32 --release packages/glsl/wasm_smoke
```

### Real macOS OpenGL 4.1 Core Compilation Verification

Tested via `packages/glsl/bench/verify_gl41.c` against native macOS OpenGL Core (`4.1 Metal - 91.7 | GLSL: 4.10`):

- `threejs_pbr_es100.vert` → GLSL 410 Core: `glCompileShader` **PASS**
- `threejs_pbr_es100.frag` → GLSL 410 Core: `glCompileShader` **PASS**
- `shadertoy_es300.vert` → GLSL 410 Core: `glCompileShader` **PASS**
- `shadertoy_es300.frag` → GLSL 410 Core: `glCompileShader` **PASS**
- `postprocess_2d_es100.frag` → GLSL 410 Core: `glCompileShader` **PASS**

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/glsl/bench/run_bench.sh` against Rust **`glsl 7.0.0` (`--release`, LTO)** on real Three.js PBR (ES 1.00), WebGL2 Shadertoy raymarching (ES 3.00), and 2D post-process (ES 1.00) fragment shaders. Both implementations emit canonical reflection summaries (stage, version, attributes, uniforms, varyings, outputs, samplers, extensions, `gl_FragColor`/`gl_FragData`) verified **100% byte-for-byte identical via SHA-256**.

> **Note on methodology**: Rust `glsl 7.0.0` constructs a full recursive-descent expression AST via `nom` before pretty-printing, whereas `packages/glsl` uses a single-pass lexer + top-level declaration parser + token-level GLSL 410 translator tailored for WebGL-to-OpenGL-4.10-Core frontend pipelines (and also supports `#ifdef`/`#if` inside function bodies, which `glsl 7.0.0` does not).

| Workload | `pion` Median (Throughput) | `rust_glsl` Median (Throughput) | `pion` Peak RSS | `rust_glsl` Peak RSS | `pion` vs `rust_glsl` | SHA-256 (verified identical) |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Three.js PBR ES 1.00 Frag (`4.77 KB × 500`) | 52.891 ms (45.06 MB/s) | 3787.283 ms (0.63 MB/s) | 2.20 MiB | 2.75 MiB | **71.61x** | `a1a0175c13201ce9...` |
| WebGL2 Shadertoy ES 3.00 Frag (`2.88 KB × 500`) | 32.441 ms (44.31 MB/s) | 1950.250 ms (0.74 MB/s) | 2.09 MiB | 2.67 MiB | **60.12x** | `f848fbeb2be7e14d...` |
| 2D Post-Process ES 1.00 Frag (`1.44 KB × 500`) | 25.284 ms (28.52 MB/s) | 1046.631 ms (0.69 MB/s) | 2.02 MiB | 2.56 MiB | **41.40x** | `6afda6cb4886d4b6...` |
