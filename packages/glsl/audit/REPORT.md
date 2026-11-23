# Red-team audit: `packages/glsl` v0.1.0

- Target: `origin/feat/pkg-glsl` @ `b9d10d7ab5946fa7a0d0b0c64a37ef3d54e536d0` (`src/{types,lexer,glsl}.pion`, 1,720 lines, read in full)
- Ground truth: macOS `OpenGL.framework`, CGL 4.1 Core profile (`4.1 Metal - 91.7`, GLSL 4.10, Apple M5 Max, `GL_MAX_DRAW_BUFFERS` 8), real `glCompileShader` on both stages plus `glLinkProgram` of the vertex/fragment pair
- Reproduce everything: `sh packages/glsl/audit/run_audit.sh all` (about 25 s; all artifacts go to `/private/tmp/pion-glsl-audit`)
- Only `packages/glsl/audit/` is added. `src/`, `glsl_test.pion` and the rest of the repository are untouched.

## Verdict

| Area | Result |
| --- | --- |
| Memory safety / crashes | **0** panic, trap, SIGSEGV or hang across 52,000 fuzz cases (208,000 API calls per target) and 41 DoS probes, native and wasm32 |
| Native vs wasm32 | **0** disagreements (verdict kind, error message hash, GLSL 410 output hash and reflection hash compared per case) |
| `parse_and_reflect` vs `translate_to_glsl410(...).reflection` | **0** disagreements |
| Limits (`ParseLimits`) | All five limits enforced at the exact boundary (exact passes, exact-1 fails). `0` and `-1` both mean unlimited, as documented |
| **OpenGL 4.1 Core correctness** | **37 / 75** corpus cases correct. 74 are valid WebGL shader pairs; 38 of them are mistranslated (4 rejected by the translator, 34 accepted but failing `glCompileShader` or `glLinkProgram`) |
| Performance | Linear in input size (89 to 97 MB/s from 6.5 KB to 905 KB). No O(n²) path within default limits. One quadratic path only when `max_defines` is unlimited |
| Benchmark honesty | Reproducible and SHA-verified, but it compares unequal work, and the README speed-ups are not reproduced (P2-8) |

No memory-safety or DoS defect was found. The open defects are about **translation correctness**: the translator scans tokens and never builds a syntax tree. As a result, macros, preprocessor branches, identifiers that are keywords in GLSL 4.10, and ES built-ins it does not list all produce GLSL 410 that the driver rejects. The worst case is the headline use case. **Every Three.js WebGL2 material shader is rejected** (P0-1).

## Severity summary

| ID | Sev | Finding | Corpus cases failing |
| --- | --- | --- | --- |
| P0-1 | P0 | Three.js WebGL2 prelude (`#define attribute in`, `#define varying out/in`) rejected with `ParseError` | `link_es300_threejs_webgl2_prelude` |
| P1-1 | P1 | ES identifiers that are GLSL 4.10 keywords or reserved words are emitted verbatim (`sample`, `smooth`, `layout`, `uint`, `case`, `precise`, `filter`, `active`, …) | 21 `es100_ident_*` cases + `es300_ident_precise` |
| P1-2 | P1 | `uniform sampler2D texture;` hides the 4.10 `texture()` built-in after `texture2D` is rewritten | `es100_uniform_named_texture` |
| P1-3 | P1 | `gl_FragColor` / `gl_FragData` used only through a macro: the body is rewritten but the output is never declared | 3 `frag_es100_*_in_macro*` cases |
| P1-4 | P1 | A macro in a function signature, or a macro-generated function, desynchronises the scanner, so the body is never rewritten | `frag_es100_macro_type_in_signature`, `frag_es100_macro_declared_function` |
| P1-5 | P1 | ES 1.00 built-ins missing from the rewrite table: `texture2DProjLod` (vertex), `texture3D*` (OES_texture_3D), `gl_FragDepthEXT` (EXT_frag_depth), `shadow2DProjEXT` | `tex_es100_vertex_lod_builtins`, `tex_es100_texture3D_oes`, `frag_es100_frag_depth_ext` |
| P1-6 | P1 | `attribute` / `varying` inside a `#define` body survive into `#version 410 core` | `link_es100_varying_via_define` |
| P1-7 | P1 | `gl_FragData` array sized from the largest literal index only; a non-literal index is ignored | `frag_es100_fragdata_const_expr_index` |
| P1-8 | P1 | ES 3.00 `packHalf2x16` / `packSnorm2x16` / `unpack*` are GLSL 4.20; macOS has no `GL_ARB_shading_language_packing` | `es300_pack_half` |
| P2-1 | P2 | Internal `_fv_` prefix is not reserved, so a user identifier collides with it | `frag_es100_user_ident_prefix_collision` |
| P2-2 | P2 | Stage check ignores `#if` branches (single-source uber shaders rejected) | `pp_es100_single_source_uber_shader` |
| P2-3 | P2 | Bracket balance is checked across `#if`/`#else` branches (valid split-brace code rejected) | `pp_es100_ifdef_split_braces` |
| P2-4 | P2 | 32-bit silent wrap in `parse_nonneg_int`: wrong reflection and `out vec4 _fv_gl_FragData[-2147483648]` | DoS probes |
| P2-5 | P2 | Line continuation splits number and operator tokens (`1\⏎0.0` → `1 0.0`, `+\⏎=` → `+ =`), and splices inside ES 1.00 `//` comments | unit tests |
| P2-6 | P2 | ES 3.00 accepts `gl_FragColor` / `texture2D` (removed in 3.00) and passes them to the 410 driver | unit test |
| P2-7 | P2 | O(D²) `#define` table and O(D × lookups) array-size resolution | DoS probes |
| P2-8 | P2 | Benchmark compares a token scanner with a full AST parser and pretty-printer; README speed-ups not reproduced; no `BENCHMARKS.md` entry | — |
| P2-9 | P2 | Output drops all line structure and emits no `#line`, so driver diagnostics point at the wrong lines; reflection duplicates `#ifdef`-alternative declarations and reports unexpanded macro types | — |

All OpenGL logs below are verbatim from `gl_judge.py`. All failing unit tests are in `redteam_test.pion`.

---

## P0

### P0-1 Three.js WebGL2 shaders are rejected (`glsl.pion:703-718`)

Three.js `WebGLProgram` prepends `#define attribute in`, `#define varying out` (vertex) and `#define varying in`, `#define gl_FragColor pc_fragColor`, `#define texture2D texture` (fragment) to every built-in material when it renders on WebGL2. The shader bodies (ShaderChunk) still say `attribute vec3 position;` and `varying vec2 vUv;`. Pass 2 treats those words as keywords and hard-fails on ES 3.00:

```glsl
#version 300 es
#define attribute in
#define varying out
precision highp float;
attribute vec3 position;          // <- ERR Parse "'attribute' is not valid in GLSL ES 3.00"
varying vec2 vUv;
void main() { vUv = position.xy; gl_Position = vec4(position, 1.0); }
```

- Translator: `ERR Parse parse error at line 6: 'attribute' is not valid in GLSL ES 3.00` (fragment: `line 8: 'varying' ...`).
- Ground truth: the same body with the macros applied (`in` / `out`) compiles and links on 4.1 Core. The control case `link_es300_interp_qualifiers` passes.
- README line 5 names Three.js as the first design target. This blocks every WebGL2 Three.js scene.
- Fix: track which identifiers are object-like `#define` names. When `attribute` / `varying` is a defined macro in ES 3.00, treat it as an identifier: no error, no rewrite. Keep the `#define`; the 410 preprocessor expands it to `in` / `out`. More generally, a translator that does not preprocess must never hard-fail on a keyword that a `#define` may have redefined.
- Tests: `redteam_p0_threejs_webgl2_prelude_vertex`, `redteam_p0_threejs_webgl2_prelude_fragment`.

## P1

### P1-1 ES identifiers that are GLSL 4.10 keywords are emitted verbatim (no rename pass; emitter `glsl.pion:1072-1109`)

Minimal input: `precision mediump float; uniform float u; void main(){ float sample = u; gl_FragColor = vec4(sample); }`

| Identifier (legal in ES 1.00) | OpenGL 4.1 Core `glCompileShader` |
| --- | --- |
| `sample`, `smooth`, `noperspective`, `patch`, `subroutine`, `layout`, `centroid`, `uint`, `case`, `precise`, `isampler2D`, `usampler2D`, `sampler2DArray`, `samplerBuffer`, `mat2x3`, `uvec2`, `dmat2` | `ERROR: 0:5: '<id>' : syntax error: syntax error` |
| `common`, `partition`, `active`, `filter` | `ERROR: 0:5: '<id>' : Reserved word.` |
| `resource`, `buffer`, `shared`, `coherent`, `readonly`, `row_major`, `texture`, `round`, `inverse`, `transpose` (as locals) | compile OK (controls) |

ES 3.00: `float precise = u;` is legal in ES 3.00 (`precise` is a keyword only from GLSL 4.00 and ES 3.20) and fails the same way. `sample`, `smooth` and `case` are very common variable names in WebGL1 post-processing and noise code.

Fix: after lexing, rename every `Ident` token (declarations and uses alike, except after `.`) in the set "GLSL 4.10 keyword or reserved word, minus ES keywords of the source version". Use a reserved prefix, for example `_fv_sample`. Apply the same rename inside `#define` bodies. Test: `redteam_p1_es100_identifiers_that_are_glsl410_keywords`, `redteam_p1_es300_identifier_precise`.

### P1-2 A user symbol named `texture` hides the rewrite target (`glsl.pion:117-134`, `900-905`)

```glsl
precision mediump float;
uniform sampler2D texture;            // classic WebGL1 tutorial / regl code
varying vec2 v;
void main() { gl_FragColor = texture2D(texture, v); }
```

- Output: `_fv_gl_FragColor = texture(texture, v);`
- OpenGL 4.1: `ERROR: 0:6: Invalid call of 'texture' (not a function or subroutine uniform)`.
- Fix: include `texture`, `textureLod`, `textureProj`, `textureGrad` and `textureProjLod` (the rewrite targets) in the P1-1 rename set whenever the source declares them as non-functions. Simplest correct rule: in ES 1.00, rename every user declaration of any 4.10-only built-in function name that the translator itself emits. Test: `redteam_p1_uniform_named_texture`.

### P1-3 Output variable missing when `gl_FragColor` / `gl_FragData` appear only in a macro (`glsl.pion:486-499`, `1057-1065`)

Pass 1 sets `uses_frag_color` only when a whitespace-separated word of the `#define` line equals `gl_FragColor`. `rewrite_define_line_es100` rewrites every identifier occurrence. So `gl_FragColor=(c)`, `(gl_FragColor)` and `gl_FragData[0]` are rewritten but never declared:

| Input | OpenGL 4.1 Core |
| --- | --- |
| `#define OUTPUT(c) gl_FragColor=(c)` + `OUTPUT(vec4(1.0));` | `ERROR: 0:4: Use of undeclared identifier '_fv_gl_FragColor'` |
| `#define FRAG (gl_FragColor)` + `FRAG = vec4(1.0);` | `ERROR: 0:4: Use of undeclared identifier '_fv_gl_FragColor'` |
| `#define OUT0 gl_FragData[0]` / `OUT1 gl_FragData[1]` | `ERROR: 0:5: Use of undeclared identifier '_fv_gl_FragData'`; reflection also reports `uses_frag_data=false` |

Fix: compute `uses_frag_color` / `uses_frag_data` (and `max_frag_data_index`) from the identifier scan inside `rewrite_define_line_es100`, the same tokenisation that performs the rewrite, not from `split_directive_words`. Tests: `redteam_p1_fragcolor_in_macro_not_declared`, `redteam_p1_fragdata_in_macro_not_declared`.

### P1-4 Macros in function headers skip the whole body rewrite (`glsl.pion:811-823`, `855-857`, `1023-1031`)

Function bodies are rewritten only when pass 2 recognises `<type> <name> (`. With `PREC vec4 f(...)` (`#define PREC highp`), `PREC` is taken as the type and `vec4` as a variable name. The declarator fallback then skips to the next `;`, which lies inside the body. The rest of the body is parsed as top-level declarations and never rewritten.

| Input | OpenGL 4.1 Core |
| --- | --- |
| `#define PREC highp` … `PREC vec4 sampleIt(vec2 uv) { return texture2D(s, uv); }` | `ERROR: 0:7: Invalid call of undeclared identifier 'texture2D'` |
| `#define DECL_GETTER(name, val) vec4 name() { return val; }` … `DECL_GETTER(white, vec4(1.0))` then `void main(){ gl_FragColor = white(); }` | `ERROR: 0:6: Use of undeclared identifier 'gl_FragColor'` (all of `main` skipped) |

Fix: do not gate the ES 1.00 rewrites on declaration parsing. Rewriting `texture2D(`, `gl_FragColor` and `gl_FragData` is valid at any brace depth that is not after `.`, so run it as a flat token pass over all non-directive tokens. Pass 2 then only needs to be right for reflection. Test: `redteam_p1_macro_in_function_signature_skips_body_rewrite`.

### P1-5 ES 1.00 built-ins missing from the rewrite tables (`glsl.pion:117-134`, `136-151`)

| Built-in (valid ES 1.00) | OpenGL 4.1 Core |
| --- | --- |
| `texture2DProjLod` (core ES 1.00 vertex built-in, vec3 and vec4 forms) | `ERROR: 0:7: Invalid call of undeclared identifier 'texture2DProjLod'` |
| `texture3D` / `texture3DLod` / `texture3DProj` (`GL_OES_texture_3D`, which is stripped) | `ERROR: 0:6: Invalid call of undeclared identifier 'texture3D'` |
| `gl_FragDepthEXT` (`GL_EXT_frag_depth`, which is stripped) | `ERROR: 0:5: Use of undeclared identifier 'gl_FragDepthEXT'` |
| `shadow2DProjEXT` (`GL_EXT_shadow_samplers`) | not in the rewrite table (code inspection; not exercised by the judge) |

Fix: add `texture2DProjLod → textureProjLod`, `texture3D → texture`, `texture3DLod → textureLod`, `texture3DProj → textureProj`, `shadow2DProjEXT → textureProj`, `texture2DProjGradEXT → textureProjGrad` and `gl_FragDepthEXT → gl_FragDepth`. Also add `gl_FragDepthEXT` to `is_fragment_only_builtin`. Test: `redteam_p1_missing_es100_builtin_rewrites`.

### P1-6 `attribute` / `varying` inside `#define` bodies reach the 410 compiler (`glsl.pion:200-284`)

`#define VARYING varying` in both stages, then `VARYING vec2 vUv;`. The storage keyword is rewritten only at top-level declaration starts, not in macro bodies. OpenGL 4.1 Core: `ERROR: 0:4: 'varying' : syntax error: syntax error` (vertex and fragment). Fix: in `rewrite_define_line_es100`, map `attribute → in` and `varying → out|in` by stage. Test: `redteam_p1_storage_keyword_inside_define`.

### P1-7 `gl_FragData` undersized when one index is not a literal (`glsl.pion:580-590`, `1061-1063`)

`gl_FragData[0] = …; gl_FragData[1 + 1] = …;`: the `[1 + 1]` use does not match the `[ tok ]` pattern and is ignored. `max_frag_data_index` stays 0, and the output declares `out vec4 _fv_gl_FragData[1];`. OpenGL 4.1 Core: `ERROR: 0:5: Index 2 beyond bounds (size 1)`. The same happens for any index that is an expression, a loop variable or an unresolved macro whenever another literal index exists. (When *no* index is a literal, the code correctly falls back to 8.)

Fix: if any `gl_FragData` use has an index that is not a resolved constant, size the array as `gl_MaxDrawBuffers` (8), regardless of the literal maximum. Test: `redteam_p1_fragdata_const_expr_index_undersized`.

### P1-8 ES 3.00 packing built-ins do not exist in GLSL 4.10 on macOS (no handling; header `glsl.pion:1056`)

`packHalf2x16`, `unpackHalf2x16`, `packSnorm2x16` and `unpackSnorm2x16` are ES 3.00 core but desktop GLSL 4.20 (or `GL_ARB_shading_language_packing`).

- OpenGL 4.1 Core: `ERROR: 0:5: Invalid call of undeclared identifier 'packHalf2x16'`.
- With `#extension GL_ARB_shading_language_packing : require`, macOS answers `extension 'GL_ARB_shading_language_packing' is not supported`.
- `packUnorm2x16` / `unpackUnorm2x16` (GLSL 4.00) work (control `es300_pack_unorm` passes).

These functions are common in WebGL2 deferred and GPGPU code. Fix: emit GLSL polyfills when the source references them. `floatBitsToUint` + manual binary16 conversion for half; `round(clamp(v,-1,1)*32767)` packing for snorm. Alternatively, return an explicit unsupported-feature error. Test: `redteam_p1_es300_pack_half_snorm_need_polyfill`.

## P2

- **P2-1 Internal prefix collision** (`glsl.pion:259-261`, `894-899`, `1059-1063`). `uniform vec4 _fv_gl_FragColor;` plus a use of `gl_FragColor` gives OpenGL `ERROR: 0:3: Regular non-array variable '_fv_gl_FragColor' may not be redeclared`. A user identifier that already carries the prefix can also be silently aliased to the output. Fix: reject or rename user identifiers that start with the internal prefix (the P1-1 rename pass can do this). Test: `redteam_p2_internal_prefix_collision`.
- **P2-2 Stage check ignores preprocessor branches** (`glsl.pion:556-575`). A single-source uber shader (`#define VERTEX` / `#ifdef VERTEX … #else … gl_FragColor … #endif`) compiled as the vertex stage fails with `StageMismatch: fragment-only symbol 'gl_FragColor'`, although the browser never sees that branch. Fix: without `#if` evaluation, downgrade the check to a warning when the symbol is inside any conditional block, or evaluate simple `#ifdef` / `#if 0|1` / `defined()` conditions. Test: `redteam_p2_stage_check_ignores_preprocessor_branches`.
- **P2-3 Bracket balance across `#if` / `#else`** (`glsl.pion:510-555`, `609-611`). `#ifdef FLIP void main(){ gl_Position=-p; #else void main(){ gl_Position=p; #endif }` is valid after preprocessing but fails with `ParseError: unclosed bracket or brace`. Fix: snapshot `bstack` at `#if`, restore it at `#else` / `#elif`, and require equal depth at `#endif` per branch (or skip the balance check inside conditionals). Test: `redteam_p2_brace_balance_across_if_else`.
- **P2-4 Silent 32-bit wrap** (`glsl.pion:22-68`, `1062`). Pion `Int` wraps on overflow. Each case below is reproduced in `dos/`; the GLSL text gives the driver a loud error, but the reflection given to the embedder is silently wrong. Fix: saturate in `parse_nonneg_int` (return -1 above 2^31-1), and cap `count` at 8 / `gl_MaxDrawBuffers`. Test: `redteam_p2_int_overflow_in_sizes_and_indices`.
  - `uniform vec4 a[99999999999999999999];` is reflected as `array_size = 1661992959`.
  - `gl_FragData[4294967296]` is reflected as index 0, and `out vec4 _fv_gl_FragData[1]` is emitted.
  - `gl_FragData[2147483647]` emits `out vec4 _fv_gl_FragData[-2147483648];`.
  - `layout(location = 999999999999999)` silently drops the location (reported as -1).
- **P2-5 Line-continuation semantics** (`lexer.pion:86-91`, `118-137`, `329-427`).
  - ES 3.00 splices `\`+newline before tokenisation. The lexer splices only between tokens and inside identifiers, so `float x = 1\⏎0.0;` becomes `float x = 1 0.0;` and `i +\⏎= 2;` becomes `i+ = 2;`, a 410 syntax error instead of `10.0` / `+=`.
  - ES 1.00 has no line continuation at all (§3.1), yet `// C:\path\⏎uniform float eaten;` swallows the declaration. Output then references the undeclared `eaten`.
  - Fix: do a physical-line splicing pre-pass for ES 3.00 only. Test: `redteam_p2_line_continuation_splits_tokens`.
- **P2-6 Invalid ES 3.00 accepted** (`glsl.pion:576-591`). `#version 300 es` with `gl_FragColor = texture2D(s, v);` translates OK with `uses_frag_color=true`, and the 4.1 driver fails later. Meanwhile `attribute` in ES 3.00 is a hard error (and over-strict, see P0-1). The validator is inconsistent. Fix: in ES 3.00, report `gl_FragColor`, `gl_FragData` and the ES 1.00 texture functions as errors unless they are `#define`d names. Test: `redteam_p2_es300_accepts_removed_es100_builtins`.
- **P2-7 Quadratic preprocessor tables** (`glsl.pion:153-175`). `set_int_define` scans the whole table before appending, and `find_int_define` is a linear scan per array size or `gl_FragData` index.

  | Probe | Native | wasm32 |
  | --- | --- | --- |
  | 50,000 `#define`, `max_defines` unlimited (20,000 → 50,000: ×6.8 time for ×2.5 input) | 1.7–2.2 s | 1.5 s |
  | 4,096 defines × 60,000 array declarations within *default* limits | 0.28 s | 0.40 s |
  | 1,000 defines × 60,000 array declarations within default limits | 0.09 s | 0.15 s |

  Bounded by the default limits, so P2. Fix: a `Map[String, Int]`.
- **P2-8 Benchmark honesty** (`bench/rust/src/main.rs:146`, `289-290`; `bench/pion_bench/src/main.pion`; `README.md:120-130`).
  - (a) The Rust side does a full nom AST parse plus `show_translation_unit` (pretty-printing the *same* ES dialect). It performs no ES→410 translation. The Pion side is a token scanner with no AST. The ratio measures "token scan vs full parse", not two translators.
  - (b) The SHA-256 gate covers only the reflection summary. The translated GLSL is never hashed or compared (Rust does not produce it), and Rust's `uses_frag_color` is `out_glsl.contains("gl_FragColor")`.
  - (c) Re-running `bench/run_bench.sh` on the same machine gives **37.99× / 49.57× / 32.01×**. The README states 71.61× / 60.12× / 41.40× (Rust median 1,526 ms vs README 3,787 ms on the Three.js input).
  - (d) No `glsl` section in root `BENCHMARKS.md`, which AGENTS.md §1.3 requires.
  - The audit's own perf section shows linear scaling (89–97 MB/s from 6.5 KB to 905 KB). Reflection-only costs 66–72 % of a translation. wasm32 is 1.3–1.7× native.
  - Fix: label the comparison "parse + reflect" in the README, quote the reproduced numbers, add the BENCHMARKS.md row, and add a translation-output hash to the Pion bench (validated by `glCompileShader`, not by Rust).
- **P2-9 Diagnostics and reflection fidelity** (`glsl.pion:1054-1113`, pass 2).
  - The emitter re-flows tokens one statement per line and emits no `#line`. Driver errors (for example `ERROR: 0:7:` above) therefore do not map back to the user's source lines; `Token.line` is already available, so `#line` can be emitted.
  - Reflection walks both arms of `#ifdef A uniform vec3 c; #else uniform vec4 c; #endif` (duplicate `c`).
  - Reflection reports macro-typed declarations by the macro name (`uniform TYPE x;` gives `glsl_type = "TYPE"`).
  - Document these limits, or evaluate simple conditionals.

## Controls that hold (no finding)

- **Lexer hostility**, all rejected cleanly with line numbers, native and wasm32 identical:
  - NUL anywhere, including comments.
  - Invalid UTF-8 or non-ASCII outside comments, and the UTF-8 BOM (WebGL rejects it too).
  - Unterminated `/*` and `/*/`, a 4 MiB unterminated comment, unbalanced `#if` / `#endif`.
  - `//*`, CR-only and mixed CRLF sources are accepted correctly. UTF-8 inside comments is tolerated.
- **Bombs**, rejected in ≤ 60 ms at default limits:
  - 2 M tokens, 1 M nested parentheses, 100 k nested `#ifdef`, more than 4 MiB of source.
  - Unlimited (`0`) limits stay linear: 2 M tokens take 0.12 s and 168 MiB RSS.
  - A 2^60 `#define` expansion bomb is passed through untouched; the translator never expands macros, and the 4.1 driver links it.
- **Correct translations confirmed by OpenGL 4.1 Core compile + link** (37 cases), including:
  - the whole ES 1.00 texture family except P1-5, multi-line and nested `texture2D(` calls, and function-like macros wrapping `texture2D`;
  - `invariant` / `centroid` / precision-qualified `varying mat4` and `varying vec3[4]` pairs;
  - `gl_FragData` + `gl_FragColor` in `#ifdef` / `#else` (location 0 binding verified with `glGetFragDataLocation`);
  - ES 3.00 `layout(location)`, `std140` blocks, `flat`, `smooth`, `centroid` and `invariant` linkage;
  - `precision` for `sampler2DArray` / `isampler2D` / `usampler3D` and multi-line precision statements;
  - `#version` after comments, `#ver\⏎sion 300 es`, `frag\⏎Color`, and both array spellings.
- **Reflection**: `uniform vec3 a, b[2], c;`, `uniform struct M {…} mat;`, blocks, `layout(location = 3)`, and function-local variables (not reflected) are all correct.

## How the evidence is produced

| File | Role |
| --- | --- |
| `src/main.pion` + `pion.toml` | audit driver (`tr`, `batch`, `time`, `rtime`), built for native `--release` and wasm32 `--release` from the same source |
| `oracle/gl41_oracle.c` | CGL 4.1 Core judge: compile both stages, link, report `glGetFragDataLocation("_fv_gl_FragColor")` |
| `corpus.py` | 75 cases: 74 valid WebGL1/WebGL2 pairs (Three.js, Shadertoy-style, post-processing, MRT, glslify-style polyfills) + 1 must-reject control. Fragment-only ES 1.00 cases get an auto-generated vertex partner that writes every varying |
| `gl_judge.py` | ES → Pion → `glCompileShader` + `glLinkProgram`, per-case verdict |
| `dos_gen.py` | 41 DoS, limit, overflow and hostile-byte probes (`run_audit.sh dos` / `wasm_dos`) |
| `fuzz.py` | structure-aware mutation fuzzer (GLSL token, directive, continuation, NUL and UTF-8 insertion; line ops; cross-seed splice; truncation; raw random), native vs wasm32 |
| `redteam_test.pion` | 18 `redteam_*` (fail until fixed) + 8 `control_*` (pass) |

Last full run (`run_audit.sh all`, FUZZ_N=12000) plus an extra `fuzz.py 40000 7`:

- 52,000 fuzz cases, 0 crash, 0 hang, 0 native/wasm32 difference, 0 reflect/translate difference. 15,927 of the 104,000 per-stage translations were accepted, so the accepting paths are exercised too.
- `glsl_test.pion` 16/16 pass.
- `git status --ignored` clean.
