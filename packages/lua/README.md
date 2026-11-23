# `lua` — Pure-Pion Lua 5.4 Bytecode Compiler & Sandboxed Register VM

Pure-Pion, zero-C-dependency, `World`-free **Lua 5.4** bytecode compiler and sandboxed register virtual machine (`Native` + `wasm32`). Immune to C `setjmp`/`longjmp` crashes and equipped with deterministic per-instruction fuel, call-depth, stack-slot, heap-memory, and output-buffer budgets (`LuaLimits`), making it directly suitable for game scripting, Redis-style request scripting, API gateway plugins, AI sandboxes, and Wasm32 runtimes.

## Features

- **Zero External Dependencies / Dual-Target**: Pure Pion standard library only (`Native` + `wasm32`), no `World` dependency.
- **Full Lua 5.4 Lexer & Parser (`src/lexer.pion`, `src/parser.pion`)**:
  - Short & long strings (`[[...]]`, `[=[...]=]`, CRLF→LF normalization), all Lua 5.4 escapes (`\a \b \f \n \r \t \v \\ \" \' \z \xHH \ddd \u{XXXX}` up to `0x7FFFFFFF`), line & block comments;
  - Exact 0-ULP decimal & hex integers/floats (`0xff`, `0x1p-2`, `0x1.8p1`, subnormals down to `5e-324`);
  - Full operator precedence & associativity, `goto` / `::label::`, `<const>` / `<close>` variable attributes, lexical `_ENV`, `repeat..until` inner-local visibility, numeric (unsigned-counter overflow-safe) & generic `for`, multi-return & vararg `...` expansion, parallel assignment;
  - Iterative left-associative binary & suffix chain compilation (O(1) host stack for 100k-term chains on both Native and Wasm32).
- **Compact 64-bit Register Bytecode, Mark-and-Sweep GC & VM (`src/opcode.pion`, `src/compiler.pion`, `src/vm.pion`, `src/table.pion`)**:
  - Flat 64-bit register bytecode with O(1) deduplicated constant pool + `OP_LOADKX`/`OP_EXTRAARG` (>65,535 constants), nested prototypes (`Proto`), and lexical `_ENV`;
  - **Arena Mark-and-Sweep GC**: automatic & `collectgarbage()` reclamation of unreachable tables, closures, and upvalues with freelist slot reuse;
  - **Host-Safe Sandboxing**: unbypassable `FuelLimit` / `StackLimit` / `MemoryLimit` / `OutputLimit`, bounded host re-entry depth (`<= 40`) for native callbacks, caller-frame register protection, and validated arena handles;
  - **Open/Closed Upvalues & `<close>`**: full lexical closures and `__close` finalization on scope exit, `break`, `goto`, `return`, and error unwind;
  - **True Tail-Call Optimization (`OP_TAILCALL`)**: including through `__call` metamethod chains;
  - **Hybrid `LuaTable`**: 1-based contiguous array + open-addressing hash segment with O(1) sampled string hashing, deterministic `next`/`pairs` (supporting `t[k] = nil` during traversal), and integer/float key normalization;
  - **All Core Metamethods**: `__index`/`__newindex` (2000-deep chains), `__call`, `__close`, `__metatable`, `__name`, `__tostring`, arithmetic, bitwise, comparison, `__concat`, `__len`, `__pairs`;
  - **Protected Calls & Coroutines**: `pcall`, `xpcall`, `error(msg, level)` with `chunk:line:` locations, plus cooperative `coroutine` (`create`, `resume`, `yield`, `status`, `wrap`, `isyieldable`, `running`).
- **Standard Libraries & Lua Pattern Engine (`src/stdlib.pion`, `src/stdlib_extra.pion`, `src/pattern.pion`, `src/math_util.pion`, `src/float_fmt.pion`)**:
  - `base`: `type`, `tonumber` (base 2..36), `tostring` (`"%.14g"`), `pairs`, `ipairs`, `next`, `select`, `rawget`, `rawset`, `rawequal`, `rawlen`, `setmetatable`, `getmetatable`, `assert`, `error`, `pcall`, `xpcall`, `load`, `collectgarbage`, `print` (captured to VM output buffer);
  - `coroutine`: `create`, `resume`, `yield`, `status`, `wrap`, `isyieldable`, `running`;
  - `table`: `insert`, `remove`, `concat`, `sort`, `move`, `pack`, `unpack`;
  - `string` (with per-VM string metatable): `len`, `sub`, `byte` (O(1)), `char`, `rep`, `reverse`, `lower`, `upper`, `find`, `match`, `gmatch` (with 5.4 `init`), `gsub`, `format` (exact BigInt `%f`/`%e`/`%g`/`%a`/`%q` & flags), `pack`, `unpack`, `packsize` + full fuel-bounded Lua pattern engine;
  - `math`: `abs`, `floor`, `ceil`, `min`, `max`, `sqrt`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `deg`, `rad`, `log`, `exp`, `fmod`, `modf`, `random`, `randomseed` (xoshiro256**), `type`, `tointeger`, `ult`, `pi`, `huge`, `maxinteger`, `mininteger` (with Payne-Hanek trig range reduction and exact IEEE-754 `fmod`);
  - `utf8`: `len`, `codepoint`, `char`, `codes`, `offset`, `charpattern` (strict + lax modes).
- **Sandbox Boundaries vs PUC-Rio Lua 5.4**:
  - Deliberately omitted for `World`-free sandbox isolation: `io`, `os`, `package`, `debug`, `dofile`, `loadfile`, `require`, and `string.dump` (binary chunk serialization).
  - Default `LuaLimits` cap call depth at `200`, stack slots at `16384`, heap memory at `32 MiB`, fuel at `5e7`, output at `1 MiB`, and native-callback host re-entry depth at `40` (for Wasm32 stack safety).
- **Host Interop**: `compile` / `exec_chunk` reuse, `set_global` / `get_global`, `new_table` / `table_get` / `table_set` / `table_len`, `register_fn(name, callback)`, `output()` / `clear_output()`, `fuel_used()`, `memory_used()`.

## Quick Example

```pion
import "lua"

let vm = lua::LuaVm::new()
vm.set_global("scale", lua::LuaValue::int(10L))
vm.register_fn("host_add", fn(_v, args) {
  let a = args[0].as_int().unwrap_or(0L)
  let b = args[1].as_int().unwrap_or(0L)
  Ok([lua::LuaValue::int(a + b)])
})
let chunk = lua::compile("print('sum', host_add(scale, 32)); return host_add(scale, 32)").unwrap()
let res = vm.exec_chunk(chunk).unwrap() // [LuaValue::Int(42L)]
let out = vm.output()                   // "sum\t42\n"
```

## Verification

```sh
sh scripts/verify.sh packages/lua
```

- **Unit & Compliance Tests**: **19 / 19 PASS** (`0 failed`).
- **4-Mode `wasm_smoke`** (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`, clean `PION_CACHE_DIR`): all 4 modes exit `0` with byte-identical stdout:
  - Output: `lua_wasm_smoke: OK checks=4`
  - SHA-256: `75c475f39ccea35d83ead27a6758becaecd379ef9fe4325cfeb6c8ef018b6440`

## Head-to-Head Benchmarks (`packages/lua` vs Go `github.com/yuin/gopher-lua` v1.1.1)

Measured on `Darwin arm64` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, `-mod=readonly`, mandatory stdout SHA-256 byte-for-byte verification across all rounds):

| Workload | `pion` Median (ms) | `gopher_lua` Median (ms) | Speedup (vs `gopher_lua`) | `pion` Peak RSS | `gopher_lua` Peak RSS | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| **W1**: Sieve(4000)x20 + Fib(24) + Table Sort/Aggregate | 124.518 | 28.668 | **0.23x** | **4.47 MiB** | 11.27 MiB | `d7cc60262c67e477...` |
| **W2**: Closures + Metatable OOP + Pattern `gsub`/`gmatch`/`format` (1500 iters) | 50.590 | 33.985 | **0.67x** | **6.56 MiB** | 12.41 MiB | `1491a40b15329ee8...` |
| **W3 (Fair)**: Compile + Fresh Sandbox VM Exec (2000 scripts, Go `SkipOpenLibs` + `base/table/string/math`) | **43.806** | 103.180 | **2.36x** | **2.78 MiB** | 19.97 MiB | `364896bb37ecca3a...` |
| **W3 (Full Go `NewState`)**: Compile + Fresh Sandbox VM Exec (2000 scripts, Go all libs) | **46.906** | 165.528 | **3.53x** | **2.78 MiB** | 13.56 MiB | `364896bb37ecca3a...` |

### Honest Performance Analysis

- **Strengths**:
  - **Fresh sandbox startup (W3)**: **~1.4–2.4x faster** against a fair `gopher-lua` configuration opening only the matched `base/table/string/math` library subset (**2.5–3.5x** vs default `lua.NewState()` opening `os`/`io`/`channel`/`debug`/`package`), with **5–7x lower Peak RSS** (2.78 MiB vs 13.6–20.0 MiB).
  - **Low Peak RSS & Bounded Memory**: Arena Mark-and-Sweep GC keeps allocation-heavy workloads (1M short-lived tables, 200k OOP method calls) within default `32 MiB` budgets at ~20 MiB host RSS instead of growing unboundedly.
  - **O(1) `string.byte` & O(1) sampled string hashing**: Eliminated the O(len) string-copy cliffs (`s:byte(i)` 200k-byte scan dropped from 16.6s to ~66ms; 60k-constant compile dropped from 7.5s to ~25ms).
- **Current Gaps**:
  - **W1 (0.23x)** and **W2 (0.67x)** trail `gopher-lua` on sustained tight bytecode loops because every instruction charges fuel (`fuel_used_count + 1L`), boxes values in a tagged `LuaValue` enum, and checks stack/table handle bounds per access. Future optimizations include batching fuel checks at loop back-edges/calls, NaN-boxed 64-bit value representation, and specialized `OP_ADDI`/`OP_LTI` immediate integer opcodes.
