# `lua` — Pure-Pion Lua 5.4 Bytecode Compiler & Sandboxed Register VM

Pure-Pion, zero-C-dependency, `World`-free **Lua 5.4** bytecode compiler and sandboxed register virtual machine (`Native` + `wasm32`). Immune to C `setjmp`/`longjmp` crashes and equipped with deterministic per-instruction fuel, call-depth, stack-slot, heap-memory, and output-buffer budgets (`LuaLimits`), making it directly suitable for game scripting, Redis-style request scripting, API gateway plugins, AI sandboxes, and Wasm32 runtimes.

## Features

- **Zero External Dependencies / Dual-Target**: Pure Pion standard library only (`Native` + `wasm32`), no `World` dependency.
- **Full Lua 5.4 Lexer & Parser (`src/lexer.pion`, `src/parser.pion`)**:
  - Short & long strings (`[[...]]`, `[=[...]=]`), all Lua 5.4 escapes (`\a \b \f \n \r \t \v \\ \" \' \z \xHH \ddd \u{XXXX}`), line & block comments;
  - Decimal & hex integers (`0xff`), decimal & hex floats (`0x1p-2`, `0x1.8p1`);
  - Full operator precedence & associativity (including right-associative `^` tighter than unary `-` and right-associative `..`), `repeat..until` inner-local visibility, numeric & generic `for`, multi-return & vararg `...` expansion rules, parallel assignment.
- **Compact 64-bit Register Bytecode & VM (`src/opcode.pion`, `src/compiler.pion`, `src/vm.pion`, `src/table.pion`)**:
  - Flat 64-bit register bytecode with constant pool, nested prototypes (`Proto`), and `_ENV` upvalue 0;
  - **Open/Closed Upvalues**: full lexical closures sharing mutable captured locals across arbitrary nesting depths and per-iteration `for` loops;
  - **True Tail-Call Optimization (`OP_TAILCALL`)**: 100,000-deep tail recursion runs in O(1) call stack even under `max_call_depth = 64`;
  - **Hybrid `LuaTable`**: 1-based contiguous array segment + open-addressing hash segment with O(1) access, deterministic insertion-ordered `next`/`pairs`, and integer/float key normalization;
  - **All 17 Core Metamethods**: `__index`, `__newindex`, `__call`, `__add`, `__sub`, `__mul`, `__div`, `__idiv`, `__mod`, `__pow`, `__unm`, `__concat`, `__len`, `__eq`, `__lt`, `__le`, `__tostring` (plus bitwise `__band`/`__bor`/`__bxor`/`__bnot`/`__shl`/`__shr` and `__pairs`);
  - **Protected Calls**: `pcall`, `xpcall`, `error` — with sandbox limit errors (`FuelLimit`, `StackLimit`, `MemoryLimit`, `OutputLimit`) strictly **unbypassable** by `pcall`/`xpcall`.
- **Standard Libraries & Lua Pattern Engine (`src/stdlib.pion`, `src/pattern.pion`, `src/math_util.pion`)**:
  - `base`: `type`, `tonumber` (with base 2..36), `tostring`, `pairs`, `ipairs`, `next`, `select`, `rawget`, `rawset`, `rawequal`, `rawlen`, `setmetatable`, `getmetatable`, `assert`, `error`, `pcall`, `xpcall`, `print` (captured to VM output buffer);
  - `table`: `insert`, `remove`, `concat`, `sort`, `move`, `pack`, `unpack`;
  - `string` (with string metatable): `len`, `sub`, `byte`, `char`, `rep`, `reverse`, `lower`, `upper`, `find`, `match`, `gmatch`, `gsub`, `format` + full Lua pattern engine (`%a%c%d%g%l%p%s%u%w%x`, `[set]`, `* + - ?`, `%bxy`, `%f[set]`, captures, backreferences) with fuel-bounded backtracking;
  - `math`: `abs`, `floor`, `ceil`, `min`, `max`, `sqrt`, `sin`, `cos`, `log`, `exp`, `fmod`, `modf`, `type`, `tointeger`, `ult`, `pi`, `huge`, `maxinteger`, `mininteger`;
  - `utf8`: `len`, `codepoint`, `char`, `codes`, `offset`.
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
| **W1**: Sieve(4000)x20 + Fib(24) + Table Sort/Aggregate | 77.246 | 22.510 | **0.29x** | **4.17 MiB** | 11.53 MiB | `d7cc60262c67e477...` |
| **W2**: Closures + Metatable OOP + Pattern `gsub`/`gmatch`/`format` (1500 iters) | 37.025 | 26.282 | **0.71x** | **6.16 MiB** | 12.52 MiB | `1491a40b15329ee8...` |
| **W3**: High-Frequency Compile + Fresh Sandbox VM Exec (2000 scripts) | **41.264** | 115.927 | **2.81x** | **2.48 MiB** | 14.41 MiB | `364896bb37ecca3a...` |

### Honest Performance Analysis

- **Strengths**:
  - **2.81x faster & 5.81x lower Peak RSS** on **W3** (per-request script compilation + fresh sandbox VM instantiation, typical of Redis/gateway/plugin workloads), due to lightweight arena initialization and zero GC runtime overhead.
  - **2.0x–5.8x lower Peak RSS** across all three workloads while enforcing per-instruction fuel, stack-depth, memory, and output-buffer DoS limits.
- **Current Gaps**:
  - **W1 (0.29x)** and **W2 (0.71x)** trail `gopher-lua` on sustained tight bytecode loops because every instruction currently charges fuel (`fuel_used_count + 1L`), boxes values in a tagged `LuaValue` enum, and checks stack/array bounds per access. Future optimizations include batching fuel checks at loop back-edges/calls, NaN-boxed 64-bit value representation, and specialized `OP_ADDI`/`OP_LTI` immediate integer opcodes.
