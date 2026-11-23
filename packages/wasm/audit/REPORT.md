# Red-team audit — `packages/wasm` @ `origin/feat/pkg-wasm` `34c0e6e`

Auditor: `RT-wasm` · Date: 2026-11-23 · Host: Darwin arm64 (`pionc 0.1.0`, `cargo 1.100.0`, `node v24.22.2`)

References (the "original"): Rust `wasmparser 0.221.3` with `WasmFeatures::WASM2` (strict 2.0 baseline) and
with crate-default features, `wasmprinter 0.221.3`, `wat 1.221.3`, Node v24 V8 `WebAssembly.validate`, and the
WebAssembly 2.0 specification. Every source file under `packages/wasm/src/**` (decode, validate, encode, wat,
leb128, types — 6,824 lines) was read in full before the attack vectors were written.

Reproduce everything (nothing is written inside the repository; artifacts go to `/tmp/rt-wasm-*`):

```sh
sh packages/wasm/audit/run_audit.sh          # unit tests + 3-way diff + 20k fuzz + 4-mode Wasm32 + DoS
pionc test --json --only-pkg packages/wasm/audit
sh packages/wasm/bench/run_bench.sh          # W1-W3 (existing harness)
```

## Summary

| | count | evidence |
|---|---:|---|
| **P0** validator accepts modules that wasmparser(WASM2) **and** V8 reject | **7** | 8 failing `p0_*` tests; 910 fuzz modules, every one traced to these 7 root causes |
| **P1** rejects valid / aborts on malformed input / invalid or lossy WAT / ungated proposals / quadratic check | **12** | 12 failing `p1_*` tests; 33 fuzz modules rejected-valid; 2,716 / 5,565 valid fuzz modules print WAT that `wat::parse_str` rejects; quadratic export check measured |
| **P2** implementation limits & fidelity | **8** | 7 failing `p2_*` tests + W3 profile |
| Red-team unit tests | 63 | **27 FAIL** (p0 8 · p1 12 · p2 7) · **36 / 36 control PASS** · 0 unexpected |
| Hand-written vectors (`targeted.py`) | 335 | 0 disagreements between my spec expectation and wasmparser(WASM2) |
| Fuzz corpus (seed 20261123) | 20,000 | 8,000 typed · 4,000 raw · 4,000 mutate · 4,000 struct |
| Native vs Wasm32, 4 modes | 20,335 files | 0 line diffs (verdict + FNV-1a of re-encoding + FNV-1a of WAT); the 3 aborts reproduce in all 4 modes |
| `packages/wasm` own suite | 13 / 13 | unchanged |

### Differential totals

Classes in `diff.py`: `PION_ACCEPTS_INVALID` = Pion `Ok`, wasmparser(WASM2) `Err` **and** V8 `false`;
`PION_ACCEPTS_NON_WASM2` = Pion `Ok`, wasmparser(WASM2) `Err`, V8 `true` (V8 ships the post-2.0 proposal);
`PION_REJECTS_VALID` = Pion `Err`, wasmparser(WASM2) and V8 accept.

| corpus | files | agree valid | agree invalid | ACCEPTS_INVALID | ACCEPTS_NON_WASM2 | REJECTS_VALID | aborts |
|---|---:|---:|---:|---:|---:|---:|---:|
| targeted | 335 | 248 | 24 | 48 | 4 | 8 | 3 |
| fuzz | 20,000 | 5,532 | 13,515 | 910 | 10 | 33 | 0 |

Root cause of every fuzz disagreement (no unexplained residue):

| fuzz class | root cause | modules |
|---|---|---:|
| ACCEPTS_INVALID | unassigned `0xFD` sub-opcodes (P0-5) | 546 |
| ACCEPTS_INVALID | `table.init` element/table type not compared (P0-2) | 338 |
| ACCEPTS_INVALID | undeclared `ref.func` (P0-1) | 18 |
| ACCEPTS_INVALID | memory64 / shared table / shared memory that V8 also rejects (P0-6, P0-7) | 7 |
| ACCEPTS_INVALID | `i8x16.avgr_u` arity (P0-3) | 1 |
| ACCEPTS_NON_WASM2 | memory64 flag, multi-memory memarg bit (P1-8, P1-10) | 10 |
| REJECTS_VALID | `i8x16.avgr_u` (P1-2) / `f64x2.nearest` (P1-3) | 17 / 16 |

Re-encoding (`decode_module` → `encode_module`) of all 5,565 WASM2-valid fuzz modules: 5,524 byte-identical,
41 semantically identical (non-minimal LEB canonicalised), **0** semantic differences, **0** invalid outputs.

## P0 — sandbox soundness (Pion `Ok`; wasmparser WASM2 and V8 both reject)

| id | finding | where | test |
|---|---|---|---|
| P0-1 | **`ref.func x` is never checked against the declared-function set** (spec C.refs: functions referenced by elem segments, globals or exports). Any function index is accepted. | `validate.pion:899-907` (`RefFunc` checks only the bound) | `p0_ref_func_undeclared_function_reference` |
| P0-2 | **`table.init x y` never compares `elem_type(elem y)` with `elem_type(table x)`**: funcref segments can be written into an externref table (reference-type confusion). `table.copy` does compare (`:966`). | `validate.pion:947-955` | `p0_table_init_funcref_elem_into_externref_table` |
| P0-3 | **`i8x16.avgr_u` (0xFD 0x7B) is typed as unary** — sub 123 is in the unary list. A module with one v128 operand validates. | `validate.pion:412` | `p0_simd_i8x16_avgr_u_single_operand` |
| P0-4 | **`f64x2.nearest` (0xFD 0x94) is missing from the unary list** and falls through to the binary default: two operands validate. | `validate.pion:393-430` | `p0_simd_f64x2_nearest_two_operands` |
| P0-5 | **All 20 unassigned SIMD sub-opcodes validate** (`0x9A 0xA2 0xA5 0xA6 0xAF 0xB0 0xB2 0xB3 0xB4 0xBB 0xC2 0xC5 0xC6 0xCF 0xD0 0xD2 0xD3 0xD4 0xE2 0xEE`): `decode_fd_instr` turns every sub ≤ 255 into `SimdOp(sub)` and the validator's default arm types it as a binary v128 op. Confirmed by a per-opcode sweep of all 256 sub-opcodes (`simd_sweep_*` vectors). | `decode.pion:337-339`, `validate.pion:430` | `p0_simd_unassigned_subopcodes_accepted` (20 / 20 accepted) |
| P0-6 | **Shared tables** (limits flag `0x02` on a table, defined or imported) are accepted — `decode_table_type` forwards `shared`; no shipped proposal has shared tables. | `decode.pion:79-136` | `p0_shared_table_accepted`, `p0_imported_shared_table_accepted` |
| P0-7 | **memory64 limits bypass the page-count limit**: `validate_limits_obj` only checks pages when `!is_memory64`, so `min = 2^40` pages validates (V8 rejects the size, wasmparser(WASM2) rejects memory64). | `validate.pion:261, 269` | `p0_memory64_unbounded_pages_accepted` |

## P1

| id | finding | where | evidence |
|---|---|---|---|
| P1-1 | **Official spec test `unreached-valid.wast` "meet-bottom" is rejected.** `pop_val_expect` returns `expect` instead of `Unknown` for a bottom operand (spec appendix returns the *actual* value), so the `br_table` loop re-pushes a concrete `f32` and fails against the `f64` default label. | `validate.pion:111-115`, `:1253-1269` | `p1_br_table_meet_bottom_spec_test` |
| P1-2 / P1-3 | Correct uses of `i8x16.avgr_u` / `f64x2.nearest` are rejected (same table bug as P0-3/P0-4). | `validate.pion:393-430` | `p1_simd_*_valid_rejected`; 33 fuzz modules |
| P1-4 | **Process abort on an 18-byte input**: export/import name length `2^31-16` → `start + n` overflows `Int` (32-bit on native *and* wasm32) in `read_name`, the bounds check passes, then `index -2147483648 out of bounds` panics. A library that advertises `DecodeLimits` against malicious binaries must return `Err`. | `leb128.pion:405-410` | `p1_export_name_length_overflow_aborts`, `p1_import_name_length_overflow_aborts`; aborts in all 4 build modes |
| P1-5 | **Process abort** via `ByteReader::read_bytes`: `self.pos + n > self.end` overflows for a data segment of length `2^31-1`; `pos` becomes negative and the next read panics (first hit by the fuzzer, minimised to 17 bytes). The same unchecked `start + size` arithmetic in `Parser::next_section` and `decode_code_section` currently degrades to an `Err` instead of an abort. | `leb128.pion:41-48` | `p1_passive_data_length_overflow_aborts` |
| P1-6 | **`print_wat` emits invalid WAT for 165 of the 198 plain SIMD operators** (`simd.op_<n>`; only 33 have mnemonics). `wat::parse_str` fails on 2,716 of 5,565 WASM2-valid fuzz modules and on 165 of the 234 valid per-opcode sweep modules (all 2,716 fuzz parse failures are on a `simd.op_<n>` line). README claims "valid WAT text". | `wat.pion:721-756` | `p1_wat_simd_mnemonics_missing` (165 / 165) |
| P1-7 | **`print_wat` changes semantics for `v128.loadN_lane` / `storeN_lane`**: natural alignment is hard-coded to 0, so an explicit 1-byte alignment is omitted and re-assembles as the natural 2/4/8 bytes (oracle `SEM_DIFF`). | `wat.pion:695` | `p1_wat_simd_lane_alignment_lost` |
| P1-8..11 | **Post-2.0 proposals accepted with no feature gate**: memory64 limits flag `0x04`, threads `shared` memory, multi-memory memarg bit 6 (`align\|0x40` decodes as `align=2, mem 0` instead of "alignment too large"), and a LEB-encoded `memory.size`/`memory.grow` reserved byte. V8 ships these proposals and accepts; wasmparser(WASM2) rejects. The package is documented as a 1.0/2.0 validator and exposes no switch. | `decode.pion:79-124, 162-187, 614-623` | `p1_*_accepted_as_wasm2` (4 tests) |
| P1-12 | **Quadratic duplicate-export check** (linear scan of all previous names): 100,000 exports (the default `max_exports`, 1 MB file) take **7.3 s** vs wasmparser **90 ms** (81×); 2× exports ⇒ ~4× time. | `validate.pion:1639-1650` | `run_dos.py` table below |

## P2

| id | finding | where | test / evidence |
|---|---|---|---|
| P2-1 | 5,000 nested blocks (valid; wasmparser and V8 accept) rejected by the fixed `max_control_depth = 4096`; `validate_bytes` gives no way to raise it. | `types.pion:634` | `p2_limit_nesting_5000_rejected` |
| P2-2 | 70,000 live operands rejected (`max_stack_height = 65536`). | `types.pion:669` | `p2_limit_operand_stack_70000_rejected` |
| P2-3 | 1.2 M-instruction body (1.2 MB, under wasmparser's 7,654,321-byte function limit) rejected (`max_instructions_per_func = 1,000,000`). | `types.pion:635` | `p2_limit_instructions_1_2m_rejected` |
| P2-4 | params + locals = 50,005 accepted (wasmparser and V8 cap the sum at 50,000; Pion counts declared locals only). Implementation limit, not a spec rule. | `validate.pion:1419-1437` | `p2_limit_params_plus_locals_50005_accepted` |
| P2-5 | `encode_module` always appends custom sections after Data, ignoring the recorded `order_after`: decode → encode is not byte-identical when a custom section precedes others. | `encode.pion:835` | `p2_encode_custom_section_position_lost` |
| P2-6 | `print_wat` drops all custom sections (wasmprinter emits `(@custom …)` and uses the `name` section). | `wat.pion` | `p2_wat_drops_custom_sections` |
| P2-7 | The Int32 overflow of P1-5 also leaks into error offsets (`section size mismatch at -2147483624`). | `leb128.pion:41-48` | `p2_data_length_overflow_negative_offset` |
| P2-8 | Locals are materialised one by one (`locals.push` per declared local) — 2,000 functions × 50,000 locals (16 KB file) validate in 256 ms vs 28 ms (9.3×); wasmparser keeps run-length groups. | `validate.pion:1430-1435` | DoS table |

## Fairness — what Pion gets right

- 36 / 36 control tests pass, including: `ref.func` declared by elem / export, typed and untyped `select` on bottom
  stacks, untyped `select` on references rejected, `if` without `else` with block params, `br_if` to loop params,
  const-expression rules (only immutable *imported* globals; wasmparser's default/GC feature set is *more*
  permissive here and Pion matches the 2.0 rule), single memory, 65,536-page limit, `min ≤ max`, DataCount
  consistency and requirement, duplicate exports, overlong / surrogate UTF-8, `start` signature, lane indices,
  alignment, function/code count, trailing body bytes, 0xFFFFFFFF local-count bomb rejected without allocation,
  2 GiB section / code-body / custom-name lengths rejected without abort.
- **Decoder + encoder are lossless**: 0 semantic differences and 0 invalid re-encodings across 5,565 valid fuzz
  modules and every targeted vector; NaN payloads, `-0`, subnormals, every elem segment form 0–7, passive data,
  multi-value block types round-trip byte-identically.
- **`print_wat` is correct outside SIMD**: 2,849 / 2,849 valid fuzz modules without unnamed SIMD ops re-assemble with
  `wat::parse_str` to the identical module, as do names with quotes / backslashes / control bytes / NUL / non-ASCII,
  f32/f64 NaN payloads, ±inf, subnormals, i32/i64 extremes and all 256 data byte values.
- Pion accepts the LEB-encoded memory index on `memory.fill` exactly like wasmparser and V8.
- Native and Wasm32 builds (debug and release) are byte-for-byte identical over 20,335 inputs — no Int-width
  divergence, no wasm32-only trap.
- `br_table` with 100,000 targets × arity 8 and 900k-instruction straight-line bodies are within ~1–1.2× of wasmparser
  wall time on this host (RSS is not; see below).

## Performance & RSS

### W1–W3 re-measured (`sh packages/wasm/bench/run_bench.sh`, same 294,885 B corpus)

| workload | Pion median | Rust median | ratio | Pion RSS | Rust RSS |
|---|---:|---:|---:|---:|---:|
| W1 decode + traversal ×20 | 144.6 ms | 45.2 ms | 0.31× | 8.20 MiB | 2.55 MiB |
| W2 validate ×20 | 252.4 ms | 63.1 ms | 0.25× | 8.73 MiB | 3.64 MiB |
| W3 decode → encode → WAT ×5 | 525.2 ms | 205.6 ms | 0.39× | **93.05 MiB** | 16.31 MiB |

(Run-to-run noise on this shared host is ±15 %; the earlier published 0.28× / 0.16× / 0.45× are in the same band.)

### Phase split (`harness time`, one process each, in-process clock)

| phase | Pion | note |
|---|---:|---|
| decode ×20 | 99 ms (4.9 ms/round) | builds a full `Array[Instr]` AST; RSS 8.0 MiB after one round |
| validate ×20 | 184 ms | = decode 99 ms + abstract-stack pass ~85 ms |
| encode only ×20 (decoded once) | 100 ms | |
| `print_wat` only ×5 | 172 ms (34 ms/round) | **≈ 80 % of W3**; RSS 92.2 MiB |

**W3 hotspot, exact:** `print_wat` produces **42,942,969 characters** for this module; wasmprinter produces
10,790,493. **41,419,258 of Pion's characters (96.5 %) are indentation spaces**: `write_indent` is uncapped and the
corpus nests up to 1,244 levels (max indent 2,488 spaces), whereas wasmprinter caps indentation at 50 levels
(max 100 spaces). Same line count (128,697) in both. The 43 M-char `StringBuilder` is the 93 MiB peak RSS
(single round: 92.6 MiB). Capping the indent (or emitting `(;depth;)`) removes ~75 % of the output and of the
RSS; the remaining gap is decode-AST allocation (W1) and the separate decode pass in validation (W2), which
wasmparser fuses into one streaming pass.

### DoS / complexity probes (`gen_dos.py` + `run_dos.py`, validate_bytes vs wasmparser WASM2)

| probe | size | Pion | Pion RSS | wasmparser | wasmparser RSS | ratio |
|---|---:|---:|---:|---:|---:|---:|
| `exports_10000` | 100,030 B | 90 ms | 3.2 MiB | 49 ms | 3.6 MiB | 1.8× |
| `exports_25000` | 250,031 B | 489 ms | 4.6 MiB | 40 ms | 5.1 MiB | 12.4× |
| `exports_50000` | 500,031 B | 1,795 ms | 6.7 MiB | 84 ms | 7.7 MiB | 21.3× |
| `exports_100000` | 1,000,031 B | **7,291 ms** | 10.9 MiB | 90 ms | 12.9 MiB | **81×** |
| `locals_50k_x2000funcs` | 16,024 B | 256 ms | 3.1 MiB | 28 ms | 2.7 MiB | 9.3× |
| `br_table_100k_arity8` | 100,073 B | 100 ms | 3.2 MiB | 83 ms | 2.6 MiB | 1.2× |
| `straight_line_900k_instrs` | 1,350,028 B | 85 ms | 27.8 MiB | 88 ms | 3.8 MiB | 1.0× (7.3× RSS) |
| `funcs_200k_tiny` | 800,028 B | 117 ms | 37.9 MiB | 52 ms | 18.1 MiB | 2.2× |
| `nesting_4095_x200funcs` | 2,458,026 B | 171 ms | 49.1 MiB | 15 ms | 5.1 MiB | 11.6× (9.6× RSS) |

Wall times include process start (~15–50 ms on this host). No probe exhausted memory or exceeded the 300 s timeout;
the export probe is the only super-linear one.

## Files

| file | purpose |
|---|---|
| `redteam_test.pion`, `pion.toml` | 63 tests (27 defect FAIL, 36 control PASS); regenerated by `gen_redteam_test.py` |
| `targeted.py`, `wasmgen.py`, `gen_targeted.py` | 335 hand-written vectors incl. the 256-entry SIMD sweep; zero-dependency binary builder |
| `gen_fuzz.py` | deterministic fuzz generator (typed / raw / mutate / struct) |
| `diff.py`, `v8_validate.mjs`, `oracle/` | three-way differential driver; V8 oracle; Rust oracle (`wasmparser`/`wasmprinter`/`wat`, `Cargo.lock` pinned) |
| `harness/` | Pion harness: `check` (verdict, re-encode, WAT + FNV-1a hashes) and `time` modes |
| `wasm32_modes.py` | native-debug / native-release / wasm32-debug / wasm32-release consistency |
| `gen_dos.py`, `run_dos.py` | DoS / complexity probes with peak RSS |
| `run_audit.sh` | runs all of the above |
