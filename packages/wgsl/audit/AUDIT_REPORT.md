# `packages/wgsl` red-team audit (RT-wgsl)

Target: `origin/feat/pkg-wgsl` @ `f1bb2c4` (pure Pion WGSL lexer / parser / validator / reflection, MSL 2.x and GLSL ES 3.00 / 450 backends, `v0.1.0`): `src/{types,lexer,parser,validate,msl,glsl,lib}.pion`, `bench/`, `wasm_smoke/`.
Judges: Rust `naga =24.0.0` (`diff/naga`, same version the package bench pins) for WGSL validity; Apple `xcrun -sdk macosx metal -std=macos-metal2.4` (metalfe-32023.921.6) for MSL; `glslangValidator` 16.6.0 for GLSL; and the **local Metal GPU** (Apple M5 Max, `gpu/gpurun.swift`) for runtime semantics, where every compute case runs twice, once from packages/wgsl's MSL and once from naga's MSL with the same slot map, against the result the WGSL spec requires.
Machine: Apple M5 Max (Darwin arm64), `pionc 0.1.0`, node v24.22.2, cargo 1.100.0.

Reproduce: `sh packages/wgsl/audit/run_audit.sh` (about 25 s hot, first run adds the cargo build and the glslang download; sections `build portability selftest unit judge gpu dos fuzz bench`, e.g. `run_audit.sh gpu` after one `build`). Artifacts go to `$AUDIT_OUT` (default `/private/tmp/pion-wgsl-audit`); nothing is written inside the repository. **The script exits non-zero while any finding below is open.** A fix is complete when `run_audit.sh` prints `AUDIT RESULT: PASS` with `audit/` byte-for-byte unchanged.

## Verdict

| Severity | Count | Summary |
| --- | ---: | --- |
| **P0** | **4** | **P0-1** nested index expressions bypass `max_nesting_depth`: a **1.6 KB** shader kills wasm32 (`RangeError`), a 30 KB one SIGSEGVs native, under default `ParseLimits`. **P0-2** binary / postfix chains are parsed iteratively but emitted recursively: **4 KB** (2,000 terms) kills wasm32, 220 KB kills native. **P0-3** host-shareable struct layout is wrong (`vec3` + scalar, `@size` ignored): on the GPU the kernel writes fields at the wrong offsets and **past the end of the buffer**. **P0-4** `continue` inside `loop` skips the `continuing` block: the canonical counter loop never terminates (GPU hang); GPU run shows the wrong trip count. |
| **P1** | **7** | **P1-1** the validator does no name resolution, typing or control-flow checking: it accepts **41 of 49** programs naga rejects, and undeclared names fall through to Metal/GLSL (`M_PI_F`, `simd_sum`, `__VERSION__` compile). **P1-2** integer literals in attributes / array lengths wrap at 2^32 (`@binding(4294967296)` = binding 0). **P1-3** reflection: `group * 8 + binding` slots collide and exceed Metal's limits; `texture_depth_cube_array` is reflected as `TextureStorage3d`. **P1-4** MSL: 15 of 44 valid corpus shaders return `Ok` and Metal rejects them (helpers cannot see module-scope resources, no forward declarations, `1f`, f32 `%`, MSL keywords, atomics, textures, builtins). **P1-5** MSL silent miscompiles, run on the GPU: `- -x` becomes `--x`, `arrayLength` returns 1 or 2, `round` is not half-to-even, workgroup memory not zeroed; `frag_depth` / `@location(1)` returns go to color 0. **P1-6** GLSL: 22 of 44 valid corpus shaders and **all three bench shaders** produce GLSL that glslang rejects while naga's GLSL for the same entry passes. **P1-7** GLSL silent miscompiles: `1f / 2f` emits `1 / 2` (= 0), `var x : T;` is uninitialised. |
| **P2** | **5** | False rejections (Unicode identifiers, const-expression `@workgroup_size`, function-scope `const_assert`, `@group(8)`, comment-only modules); `ParseLimits` 0/negative silently mean "unlimited"; `override` default dropped with `@id`; error columns are byte offsets; benchmark fairness (stdout carries only counters; GLSL counted ok by `#version` prefix; packages/wgsl does a small fraction of naga's front-end work). |

What held: 0 `extern "C"`, 0 `World`, 0 module-level mutable state in `src/` (49 immutable `tk_*` token constants); 0 crash / 0 hang / byte-identical verdicts in native debug/release and wasm32 debug/release over 5,000 mutants (seed 20261124) and every malformed-input control (truncations, NUL, non-ASCII, `/* /* */`, lone exponents, `0x`); every limit that *is* wired (`max_source_bytes`, `max_tokens`, paren / block / template / call / unary / `else if` nesting) answers in milliseconds; nested comments, `>>` template splitting, `>>=`, `a < b && c > d`, `switch`/`case x, default`, `loop`/`continuing`/`break if`, `for (var i = 0u; ...; i++)` all parse; duplicate struct / field / fn / global / binding, `@workgroup_size(0|-1|missing|>1024)`, `break` outside loops and `discard` in vertex/compute entries are rejected with line:col; reflection of a 3-stage / 3-group module (uniform, storage read vs read_write, texture, sampler, `const` workgroup size) is exact; `select(f, t, c)` argument order is correct in MSL (GPU) and GLSL (scalar); pointer parameters and column-major matrices are correct on the GPU; the package's own 20 tests and `wasm_smoke` (4 modes, `sha256 2a4018786372cfad`) pass. No *lexical* code injection is possible: identifiers are `[A-Za-z0-9_]`, attribute arguments are identifiers or integers, and there are no strings or `#` tokens; the remaining injection channel is semantic (P1-1).

Gate results on `f1bb2c4`:

| Section | Result |
| --- | --- |
| portability | PASS |
| selftest (56 cases, 4 modes, outputs byte-identical) | 7 controls PASS, **49 red-team FAIL** |
| unit (`pionc test`) | packages/wgsl 20/20; audit controls 7/7; **red-team 0/49** |
| judge, valid corpus (44 + 3 bench shaders, naga accepts all) | **8/47 PASS** (4 rejected by packages/wgsl, 15 rejected by Metal, 25 by glslang) |
| judge, invalid corpus (49 shaders, naga rejects all) | **8/49 PASS** (packages/wgsl accepts 41) |
| gpu (Metal runtime) | 3 controls PASS, **7 FAIL** |
| dos (26 probe rows x 4 modes) | **26 crash cells** (8 rows) |
| fuzz (5,000 mutants x 4 modes) | PASS (0 crash, 0 hang, identical verdicts) |

---

## P0-1 Index nesting is not depth-limited → stack exhaustion (native SIGSEGV, wasm32 RangeError)

* **Where.** `parser.pion:1657-1667`: `parse_postfix` handles `[` by calling `parse_expr` directly; unlike parens (`:1765`), calls (`:1696`, `:1747`), unary (`:1604`), blocks (`:912`) and templates (`:339`) it never calls `enter_depth`, so `max_nesting_depth` does not apply. Each level is ~13 Pion frames (`parse_expr → parse_or → … → parse_postfix`), and `validate` / `wgsl_emit_msl` / `wgsl_emit_glsl` recurse over the resulting tree again.
* **Trigger.** Untrusted WGSL only, default `ParseLimits`: `o[o[o[…0…]]]`.

  | Probe (`run_audit.sh dos`) | Size | native dbg / rel | wasm32 dbg / rel |
  | --- | ---: | --- | --- |
  | `index_nest_500` | 1,632 B | OK | **RangeError: Maximum call stack size exceeded** |
  | `index_nest_10k` | 30,132 B | **SIGSEGV (rc -11)** | **RangeError** |

* **Impact.** Any host that compiles user-supplied WGSL (browser engine, playground, asset pipeline) can be crashed by a 1.6 KB file in wasm32 or a 30 KB file natively; `ParseLimits` gives no protection. Red test `redteam_p0_index_nesting_ignores_depth_limit` (100 nested indexes pass `max_nesting_depth = 64`).
* **Fix.** `enter_depth`/`leave_depth` around the index sub-expression, and see P0-2 for the tree depth.

## P0-2 Expression trees are unbounded in depth; emitters recurse → stack exhaustion

* **Where.** The binary-operator levels (`parser.pion:1414-1585`) and the postfix loop (`:1649-1671`) build left-deep trees in a `while` loop without depth accounting, so `a+a+…+a` or `a.x.x.x…` produce a tree of depth *n* that passes every limit. `MslCtx::emit_expr` (`msl.pion:282-303`) and `GlslCtx::emit_expr` (`glsl.pion:239-267`) then recurse once per level.
* **Trigger.** Untrusted WGSL, default limits:

  | Probe | Size | native | wasm32 |
  | --- | ---: | --- | --- |
  | `binary_chain_2k` (`a+a+…`, 2,001 terms) | 4,132 B | OK | **RangeError** |
  | `field_chain_2k` (`a.x.x…`, 2,000 levels) | 4,132 B | OK | **RangeError** |
  | `binary_chain_110k` / `field_chain_110k` | 220 KB | **SIGSEGV** | **RangeError** |

  Long sums are ordinary in generated shaders (unrolled filters, polynomial evaluation), so the wasm32 crash point of ~1.7k terms is reachable without malice.
* **Red tests.** `redteam_p0_binary_chain_unbounded_tree_depth` (a 501-term chain reaches recursive codegen with `max_nesting_depth = 64`), `redteam_p0_field_chain_unbounded_tree_depth`.
* **Fix.** Either count tree depth (charge each binary/postfix level against `max_nesting_depth`, or a separate expression-depth limit) or make every tree walk iterative. Whatever is chosen must keep the `dos` section green in all four modes.

## P0-3 Host-shareable layout mismatch: GPU writes at wrong offsets and past the buffer end

* **Where.** `msl_emit_type` (`msl.pion:45-48`) maps `vec3<f32>` to `float3` (16 bytes, 16-aligned) in storage/uniform structs; WGSL `vec3<f32>` is 12 bytes, so a following scalar sits at offset 12. `msl_emit_struct` (`msl.pion:775-841`) honours `@align` but ignores `@size`.
* **Evidence (GPU, `run_audit.sh gpu`).** Same buffers, slot `group*8+binding` for both compilers:

  | Case | WGSL / naga result | packages/wgsl result |
  | --- | --- | --- |
  | `vec3_struct_layout`: `struct S { a: vec3<f32>, b: f32 }`, `buf[0].b = 7; buf[1].a = (1,2,3)` on a 32-byte buffer | `[0,0,0,7, 1,2,3,0]` | `[0,0,0,0, 7,0,0,0]`: `b` written at byte 16 (= `buf[1].a.x`), `buf[1].a` written at bytes 32..44, **beyond the 32-byte buffer** |
  | `size_attribute_layout`: `struct S { @size(20) a: f32, b: f32 }` | `b` at byte 20 | `b` at byte 4 |

* **Impact.** Every storage/uniform struct with a `vec3` followed by a scalar (vertex data, lights, particles) or with `@size` is read and written at the wrong offsets; the last element of an array of such structs is written out of bounds (GPU memory corruption of the neighbouring allocation). naga emits `packed_float3` / explicit padding.

## P0-4 `continue` inside `loop` skips `continuing` → non-terminating loops

* **Where.** `msl.pion:732-750` and `glsl.pion:758-776` lower `loop { body; continuing { cont; break if c; } }` to `while (true) { body; cont; if (c) break; }`. A `continue` in `body` jumps to the top of the `while`, skipping `cont` and the `break if` (WGSL §9.4.6 requires `continue` to transfer to the `continuing` block).
* **Evidence.** `corpus/valid/v41_loop_continue_hang.wgsl` is the canonical pattern `loop { if i % 2u == 0u { continue; } …; continuing { i = i + 1u; break if i >= 10u; } }`: it terminates in WGSL; the emitted MSL/GLSL spins forever at `i = 0` (not run on the GPU on purpose: it would hang until the watchdog). The terminating variant `v18` is run: WGSL/naga give `hits = 3, i = 4`, packages/wgsl gives `i = 3` (`gpu: loop_continue_runs_continuing`).
* **Impact.** GPU hang / device loss from valid input; wrong iteration counts otherwise. Fix: emit `continuing` as a `for(;;){...}` update or a `bool` guard / label as naga does.

## P1-1 The validator does not check names, types or control flow; target namespaces leak through

* **Where.** `wgsl_validate_stmts` (`validate.pion:131-227`) only looks at declarations, `break` / `continue` / `discard` placement and named types; no expression is ever visited. `wgsl_validate_type_refs` (`:113-129`) checks only `Named`, `Array` and `Ptr` element types (`vec3<not_a_type>` is emitted as `not_a_type3`). The reserved-word list (`:33-70`) misses `fallthrough`, `nointerpolation`, `precision` and all WGSL keywords (`fn`, `loop`, …), which the parser accepts as identifiers. Module-scope `const_assert` and `diagnostic` are skipped token-by-token (`parser.pion:686-691`); function `var<workgroup>` drops its template (`parser.pion:979-988`); unknown attributes, builtins, address spaces, access modes and texel formats pass through; `__` identifiers and leading-zero literals are lexed (`lexer.pion:108-114`, `:319-322`); module-scope names share no namespace check across structs / functions / globals; recursion, missing returns, `continue`/`return` inside `continuing`, writes to `var<storage, read>` and `let`, duplicate `@location`, entry I/O without bindings, vertex without `position`, `discard` reached from a vertex helper (`allow_discard`, `:611`, is per function, not per call graph) are all accepted.
* **Evidence.** `judge` invalid corpus: naga rejects all 49, packages/wgsl rejects 8 (`i42 i43 i44 i46 i47 i48 i49 i50`) and returns `Ok` + MSL + GLSL for the other 41. 26 selftest red tests (`redteam_p1_*` validator group) pin individual rules.
* **Security angle (injection).** Because names are not resolved, an undeclared identifier is emitted verbatim and bound by the *target* language: `o[0] = M_PI_F + simd_sum(o[1]);` (`i51`, `redteam_p1_target_builtin_passthrough`) compiles to a Metal kernel that uses the Metal macro and a SIMD-group intrinsic WGSL does not have; `__VERSION__` becomes 300/450 in GLSL; `discard_fragment()` reaches Metal. Untrusted WGSL can therefore call any Metal/GLSL builtin and observe target-specific macros, and portability checks done on the WGSL side are meaningless.

## P1-2 Integer literals wrap at 2^32

* **Where.** `wgsl_parse_int_str` (`parser.pion:144-197`) accumulates `acc * 10 + d` / `acc * 16 + d` in 32-bit `Int` with no overflow check; it feeds `@group`, `@binding`, `@location`, `@id`, `@align`, `@size`, `@workgroup_size` and array lengths.
* **Evidence.** `@binding(4294967296)` → binding 0, slot 0 (`redteam_p1_binding_literal_wraps`); `array<f32, 4294967297>` → length 1; `@workgroup_size(4294967297)` → x = 1 (`redteam_p1_workgroup_size_literal_wraps`). naga: "numeric literal not representable".
* **Impact.** A binding that looks out of range silently aliases binding 0; reflection lies to the host.

## P1-3 Reflection: slot collisions, out-of-range Metal slots, wrong texture kind

* **Where.** `validate.pion:485-499,555`: `@group` 0..7 and `@binding` 0..31 are accepted, and `msl_slot = group * 8 + binding`. `wgsl_classify_texture_binding` (`:262-292`) has no `texture_depth_cube_array` branch and falls through to `TextureStorage3d` (`:290`).
* **Evidence.** `(0, 8)` and `(1, 0)` both reflect `msl_slot = 8` and Metal rejects the module: `cannot reserve 'buffer' resource location at index 8` (`v43`). `@group(3) @binding(31)` → `[[buffer(55)]]`, a sampler in group 2 → `[[sampler(16)]]`: `'buffer' attribute parameter is out of bounds: must be between 0 and 30`, `'sampler' … between 0 and 15` (`v33`). Red tests `redteam_p1_msl_slot_collision`, `redteam_p1_msl_slot_out_of_metal_range`, `redteam_p1_depth_cube_array_misclassified`, `redteam_p1_private_texture_accepted` (`var<private> t : texture_depth_cube_array` is accepted).
* **Impact.** The `BindingInfo.msl_slot` contract cannot be used to build Metal argument tables for valid layouts; with only `binding < 8` per group it works by accident.

## P1-4 MSL backend: `Ok` output that Apple's Metal compiler rejects

`judge` runs `xcrun -sdk macosx metal -std=macos-metal2.4` on every `Ok` result of the valid corpus (naga accepts all of them):

| Corpus file | Metal error | Root cause |
| --- | --- | --- |
| `v01_helper_uses_uniform`, `v04_helper_samples_texture`, `v23_private_in_helper` | `use of undeclared identifier 'cam' / 't' / 'seed'` | module-scope bindings and `var<private>`/`var<workgroup>` exist only as entry parameters / entry locals (`msl.pion:1045-1118`); helpers cannot see them |
| `v02_forward_call` | `use of undeclared identifier 'helper'` | functions emitted in source order, no prototypes (`msl.pion:1245-1250`) |
| `v03_struct_order` | `unknown type name 'Outer'` | aliases, consts and structs emitted in source order (`msl.pion:1157-1243`) |
| `v05_float_suffix_f` | `invalid digit 'f' in decimal constant` | `1f` copied verbatim (`msl_emit_float_lit`, `msl.pion:260-269`) |
| `v06_float_remainder` | `invalid operands to binary expression` | f32 `%` emitted as C `%` (naga: `fmod`) |
| `v08_msl_keyword_idents` | `declaration of anonymous struct must be a definition` | identifiers (`device`, `constant`, `thread`, `half`, `kernel`, `float`, …) emitted verbatim (`msl.pion:284`) |
| `v15_override_default_id` | `reference to 'bias' is ambiguous` | `using namespace metal;` (`msl.pion:1155`) + verbatim names collide with `metal::bias` |
| `v31_target_macro_names` | `expected unqualified-id` | declared `M_PI_F` / `FLT_MAX` expand as Metal macros |
| `v11_atomics` | `use of undeclared identifier 'atomicSub'` | only `atomicLoad/Store/Add` mapped (`msl.pion:418-439`) |
| `v12_textures` | `cannot initialize … 'const uint3' with … 'uint2'` | `textureDimensions` always `uint2`, `textureLoad` always `uint2` coords (`msl.pion:358-383`); array/cube/gather/grad/compare-level forms unmapped |
| `v13_math_builtins` | `use of undeclared identifier 'degrees'` | `msl_remap_builtin` (`msl.pion:527-563`) lacks `degrees`, `radians`, `modf`, `frexp`, `extractBits`, `insertBits`, `firstLeadingBit`, `quantizeToF16`, … |
| `v33_binding_slots`, `v43_binding_slot_alias` | slot out of bounds / cannot reserve | P1-3 |

The three bench shaders compile (the README's Metal claim covers only those).

## P1-5 MSL silent miscompiles (compile fine, wrong on the GPU)

| `gpu` case | Spec / naga on the GPU | packages/wgsl on the GPU | Where |
| --- | --- | --- | --- |
| `double_negation`: `let y = - -x;` | `y = x`, `x` unchanged (5, 5) | `const auto y = --x;` → (4, 4): **mutates `x`** | `msl.pion:293-296` (also `glsl.pion:254-260`) concatenates unary operators without separator / parens |
| `array_length`: 16-element tail array, 8-element array | 16, 8 | **1, 2** | `msl.pion:384-397` uses `sizeof(ptr)/sizeof(elem)`; the struct tail is emitted as `values[1]` (`:816-822`). Bounds checks written against `arrayLength` stop after 1 element |
| `round_half_to_even`: `round(2.5)`, `round(0.5)` | 2, 0 | **3, 1** | `round` passed through (Metal rounds half away from zero; naga uses `rint`) |
| `workgroup_zero_init`: `var<workgroup> wv : u32;` read before write | 0 | store elided (`threadgroup uint wv;` is uninitialised, `msl.pion:1105-1115`) | WGSL zero-initialises workgroup memory |

Text-level (selftest): a fragment entry returning `@builtin(frag_depth) f32` is emitted as `fragment float fs(...)`, i.e. **color 0**, and `-> @location(1) vec4<f32>` is emitted without `[[color(1)]]`, i.e. color 0 (`msl.pion:969-985`; `redteam_p1_msl_frag_depth_return_becomes_color`, `redteam_p1_msl_location1_return_becomes_color0`).

## P1-6 GLSL backend: invalid GLSL for most valid input, including every bench shader

`judge` runs glslangValidator on packages/wgsl's GLSL for every entry point, and counts a failure only when naga's GLSL for the same entry passes glslang (otherwise `N/A`). 22 of 44 valid corpus files and **`pbr`, `compute_reduce`, `particles` (the bench corpus)** fail. Causes:

* **Varyings never link** (`glsl.pion:1045-1144`): vertex outputs are `layout(location = N) out T _vs_out_<field>`, fragment inputs `layout(location = N) in T _in_<field>`; GLSL ES 3.00 forbids `location` on VS outputs / FS inputs (`'location qualifier on output' : not supported in this stage: vertex`) and links by *name*, which differs (`redteam_p1_glsl_varyings_do_not_link`).
* `@builtin(position)` read in a fragment shader becomes `gl_Position` (`glsl.pion:102-103`; `redteam_p1_glsl_fragment_position_is_gl_position`).
* `let` without a type is declared `float` unless the initializer is a literal or one of a few calls (`glsl_infer_expr_type`, `glsl.pion:460-520`): `let idx = gid.x; buf[idx]` → `'[]' : scalar integer expression required` (compute_reduce), `>>` on float (particles), `float v = vec3(...)` (`redteam_p1_glsl_let_type_inference_defaults_to_float`).
* WGSL identifiers that are GLSL keywords (`in`, `uniform`, `sample`, `half`) are emitted verbatim (`fn fs_main(in : VsOut)`, the most common WGSL signature, fails).
* `select` with a vector condition becomes `?:` (`glsl.pion:281-290`), runtime-sized arrays inside structs, non-struct `var<uniform>` (wrapped as `.value` but read without it, `:983-991`), storage buffers / `std430` / `binding=` in ES 3.00 vertex/fragment shaders of mixed modules, f32 `%`, hex floats, vector `bitcast` (emitted as a value conversion), integer varyings without `flat`, non-zero-location fragment returns (`_fs_out_0` vs `_fs_out_1`).

The bench counts each of these as `glsl_ok` because it only checks for a `#version ` prefix (see P2-5).

## P1-7 GLSL silent miscompiles

* `1f / 2f` → `1 / 2` (`glsl_emit_float_lit` strips the suffix, `glsl.pion:178-188`): integer division, so `o[0] = 1f / 2f;` stores **0.0** in GLSL 450 where implicit int→float conversion makes it compile (`v05` passes glslang; `redteam_p1_glsl_float_suffix_becomes_int`).
* `var x : T;` without initializer → `T x;` (`glsl.pion:524-545`), private globals likewise and `shared` workgroup variables are never zeroed: WGSL zero-initialises all three (`redteam_p1_glsl_var_not_zero_initialized`).
* `- -x` → `--x` and the `continuing` lowering are shared with MSL (P1-5, P0-4).

## P2 findings

* **P2-1 False rejections of valid WGSL** (all accepted by naga): Unicode XID identifiers (`lexer.pion:96-114` ASCII only; `v30`), `@workgroup_size(WG)` where `WG` is a const *expression* (`wgsl_resolve_wg_dim`, `validate.pion:822-827`; `v16`), function-scope `const_assert` (parse error; `v17`), `@group(8)` / `@binding(32+)` (`validate.pion:485-499`; WGSL has no such bound, device limits are a pipeline concern; `v44`), and empty / comment-only modules (`EmptySource`; 174 of the 191 fuzz mutants naga accepts and packages/wgsl rejects). Red tests `redteam_p2_*`.
* **P2-2 `ParseLimits` 0 / negative silently mean "unlimited"** (`lexer.pion:128`, `:240`; depth falls back to 64, `parser.pion:19`). A caller that "tightens" limits to 0 or passes `-1` disables the byte and token caps; with P0-1 that turns the default-limit `ERR Limit` on `tokens_250k_plus` into a SIGSEGV / RangeError (`dos`: `limits -1,-1,-1`). Undocumented in `types.pion:4-31`.
* **P2-3 `override`.** With `@id`, the default value is dropped (`constant float scale [[function_constant(0)]];`, `msl.pion:1202-1210`; `redteam_p2_msl_override_default_dropped`); in GLSL overrides become non-overridable `const`, and an override without initializer is never declared.
* **P2-4 Diagnostics.** Columns count UTF-8 bytes; several parse errors at EOF print `got ''`.
* **P2-5 Benchmark fairness** (`bench/`). Reproduced as shipped (`run_audit.sh bench`): pion 83.9 ms vs naga 167.0 ms median, SHA-256 equal. But: (a) the compared stdout is six counters (`entries`, `bindings`, `wg_x_sum`, `msl_ok`, `glsl_ok`), so the SHA gate proves nothing about the generated code; (b) `glsl_ok` is "starts with `#version `" (`pion_bench/src/main.pion`), and glslang rejects packages/wgsl's GLSL for all three bench shaders (P1-6), whereas naga's passes; (c) the two pipelines do different work: naga resolves names, infers and checks types, lowers to IR and runs uniformity/control-flow validation (`ValidationFlags::all()`); packages/wgsl does none of that (P1-1). Stage split on the same corpus, 200 x 3 shaders: packages/wgsl parse 27 ms, parse+validate 33 ms; naga parse (includes name resolution and lowering) 49.9 ms, parse+validate 50.4 ms. The `1.88x` headline therefore compares a syntax-directed transpiler with a full compiler and should say so next to the number; a fair gate would hash the emitted MSL/GLSL after checking it compiles.
* **Info.** Integer `/` and `%` by zero and `INT_MIN / -1` are UB in the emitted MSL (`v40`), where WGSL defines them; naga 24 behaves the same (−1 and 7 on the M5 Max), so it is not counted.

## Corpus and tools (`audit/`)

| Path | What |
| --- | --- |
| `run_audit.sh` | one-shot runner; exit 1 while any gate fails |
| `src/main.pion`, `src/cases.pion`, `src/dos.pion`, `redteam_test.pion` | Pion driver (`selftest`, `digest`, `msl`, `glsl`, `reflect`, `time`, `stages`, `gen_dos`), 56 cases (7 controls + 49 red), 22 DoS generators |
| `corpus/valid/*.wgsl` (44) | valid WGSL, each pinning one feature; naga accepts all |
| `corpus/invalid/*.wgsl` (49) | invalid WGSL, each pinning one rule; naga rejects all |
| `diff/naga/` | Rust `naga =24.0.0` oracle: `classify`, `msl` (slot map `group*8+binding`, sizes buffer 30), `glsl`, `stages` |
| `diff/judge.py` | corpus differential with Metal + glslang verdicts |
| `diff/fuzz.py` | deterministic mutation fuzz, 4 modes, naga agreement |
| `diff/dos.py` | per-process DoS probes with a 2 s budget |
| `gpu/gpurun.swift`, `gpu/gpu_judge.py` | Metal runtime judge (packages/wgsl vs naga vs spec) |
