# RT-lua red-team audit — `packages/lua` v0.1.0 (`origin/feat/pkg-lua` @ `89f41b6`)

Auditor: RT-lua (independent, adversarial). Toolchain: `AFK-surf/pion@66d2b4b` (`pionc 0.1.0`), Darwin arm64.
Oracles: **PUC-Rio Lua 5.4.7** built from the official tarball (sha256 `9fbf5e28…1e30`) — the semantic
reference; **Go `github.com/yuin/gopher-lua` v1.1.1** — the benchmark baseline (it implements Lua 5.1
semantics: no integer subtype, no bitwise operators, so it is not used as a 5.4 correctness oracle).
Everything below is reproduced by `sh packages/lua/audit/run_audit.sh` (artefacts in `/private/tmp/rt-lua-audit`).

## Verdict

`packages/lua` is **not** safe to run untrusted scripts as shipped, and it is **not** a faithful Lua 5.4.
The README's central claims — "immune to crashes", "unbypassable fuel / memory budgets", "full Lua 5.4" —
are each contradicted by one-line scripts:

| claim | counter-evidence (one line of Lua, default `LuaLimits`) |
| --- | --- |
| crash-immune | `return 1 << math.mininteger` → native **SIGSEGV**, wasm32 `RangeError` (P0-1) |
| crash-immune on wasm32 | `return 1 + 1 + … (400 terms, 1.6 KB)` → wasm32 `RangeError` (P0-3) |
| deterministic fuel | `table.move({}, 1, math.maxinteger, 2)` never returns under fuel 1e5 (P0-8) |
| memory budget | `('b'):rep(2148, ('a'):rep(1e6))` returns a **2.1 GB** string under a 32 MiB budget (P0-7) |
| correct register VM | a `__tostring` callback silently **overwrites the caller's local variables** (P0-5) |
| correct compiler | constant #65536 aliases constant #0: `local s = "EVIL"` evaluates to `"print"` (P0-6) |

Totals: **11 P0**, **21 P1**, **10 P2**. Differential corpus: 434 cases, **250 byte-identical** to Lua 5.4.7,
15 identical except the missing `chunk:line:` error prefix (P2-1), **164 divergent**, 5 crash/hang; across the
4 build modes the corpus never split (0 `MODE_SPLIT`) — all non-crash behaviour is identical on native
debug/release and wasm32 debug/release. Red-team unit tests: `redteam_test.pion` **45 tests: 35 findings
FAIL as expected, 10 controls PASS**.

Run modes used throughout: `rel` = native `--release`, `dbg` = native debug, `wrel`/`wdbg` = wasm32
release/debug under `node --stack-size=984 pion_wasm_rt.mjs`. Exit `-11` = SIGSEGV, `-6` = SIGABRT,
wasm `rc=1` = uncaught `RangeError` (stack or `Memory.grow`).

---

## P0 — host crash, sandbox-limit bypass, silent miscompilation

### P0-1 `1 << math.mininteger` / `1 >> math.mininteger` crash the host
`src/math_util.pion:331-352`: `lua_shl_i64(a, b)` with `b < 0` calls `lua_shr_i64(a, -b)`, which for
`b == math.mininteger` calls `lua_shl_i64(a, -(-b))` with the same negative value → unbounded mutual recursion.
Lua 5.4.7: `0`. Probe `shl_minint`/`shr_minint`: `rel -11 | dbg -11 | wrel RangeError | wdbg RangeError`.
Not catchable by `pcall` (the process dies). Fix: treat `b <= -64 || b >= 64` as 0 before negating.

### P0-2 `__call` chains recurse on the host stack, uncounted by `max_call_depth`
`LuaVm::call_value` (`src/vm.pion:631-643`) resolves a non-function callee by calling itself on `__call`
without pushing a frame or checking any limit. `local t = setmetatable({}, {}); getmetatable(t).__call = t; pcall(t)`
→ native grows to **13.4 GB RSS** and SIGSEGVs after ~6 s; a 1e5-long `__call` chain does the same;
wasm32 `RangeError` (probes `call_self_loop`, `call_chain_long`). Lua 5.4.7 bounds this with its stack limit.

### P0-3 Compiler recursion on left-assoc / suffix chains is unguarded (native and **400-term** wasm32 crash)
The parser's nesting guard ("syntax nesting depth exceeded") covers `(`, `{`, blocks, functions, `not`, `..`,
`^` — all rejected cleanly up to 1e5 (control). It does **not** cover binary left-assoc chains, field chains or
call chains, which the compiler then walks recursively:

| probe | rel | dbg | wrel | wdbg |
| --- | --- | --- | --- | --- |
| `return 1 + 1 + …` ×300 | OK | OK | OK | OK |
| `return 1 + 1 + …` ×**400** | OK | OK | **RangeError** | **RangeError** |
| `… + 1` ×1000, `a.b.b…` ×1000, `f()()…` ×1000 | OK | OK | RangeError | RangeError |
| same ×100 000 | **SIGSEGV** | **SIGSEGV** | RangeError | RangeError |

A 1.6 KB generated expression kills a wasm32 host; `compile()` is reachable by any script source.

### P0-4 `max_call_depth` is not a host-stack bound (native callbacks re-enter `run_loop`)
Every native→Lua callback (`table.sort` comparator, `gsub` function, `__index`/`__eq`/`__lt`/`__tostring`…)
nests a full `run_loop` on the host stack. With the **default** depth 200, `local function cmp(a,b)
table.sort({3,2,1}, cmp) return a<b end table.sort({3,2,1}, cmp)` gives native `StackLimit` (good) but
**wasm32 `RangeError`** (probe `sort_cmp_recursion`). With a host-raised depth (10 000, documented as a
tunable), an `__index` function recursion SIGSEGVs native (`deep_depth_10000_index_fn`). The limit is counted
in frames, but the host cost per frame differs by 10–100× depending on how the frame was entered.

### P0-5 Native callbacks run their Lua frame on top of the caller's live registers (silent local-variable corruption)
`LuaVm::call_value` places the callee at `base = self.top`. `self.top` is only meaningful right after a
multret instruction (`OP_CALL`/`OP_VARARG`/`RETURN` set it to the end of the results, `src/vm.pion:832,884,1467`)
and is **never restored** to the frame top before `op_call_slow` invokes a native function (`src/vm.pion:845-866`).
After any multret use (e.g. `{f()}`), a native that calls back into Lua overwrites the caller's registers:

```lua
local t = setmetatable({}, {__tostring = function() local a,b,c,d,e,f = 1,2,3,4,5,6 return 'T' end})
local function multi() return 1, 2, 3 end
local r = {multi()}
local secret, keep = 'secret', 'keep'
print(secret, keep, tostring(t), keep)
-- Lua 5.4.7: secret  keep  T  keep
-- Pion     : T       2     T  keep        (both locals overwritten by the callee's frame)
```
Variant: `local r = {tostring(t)} local keep = 'keep' print(keep, tostring(t))` → `TypeError: attempt to call a
number value` (the staged `print` register was overwritten). Same with `table.sort` comparators and
`pcall(error, obj)` + `tostring(e)` (the `ok` result became `"EOBJ"`). Tests `p0_5_*`. This is the most
dangerous finding for real scripts: wrong values, no error.

### P0-6 16-bit operand wrap → silent miscompilation; O(n²) constant pool → unmetered compile DoS
`enc_abc` masks A/B/C with `& 0xFFFF` (`src/opcode.pion:63-69`) and nothing checks the constant count,
so constant index 65 536 aliases 0:
```lua
local p = print local s0 = 'SAFE' local t = {'x1', …, 'x65534'} local s = 'EVIL' p(s, #t)
-- Lua 5.4.7: EVIL 65534        Pion: print 65534
```
With 65 536+ constants in a chunk whose first constant is `print`, the call itself goes to `nil`
(`raw_many_constants`). `FuncCompiler::add_const` (`src/compiler.pion:100-111`) dedupes by linear scan, so a
600 KB table literal with 60 000 distinct strings takes **7.5 s native / 9.8 s wasm32 to compile vs 13 ms in
Lua 5.4.7** (probe `const_pool_60k_compile_time`); `compile()` is not fuel-metered, so this is an
unbounded-CPU primitive for the W3-style "compile per request" deployment the README advertises.

### P0-7 `string.rep` 32-bit overflow bypasses `max_memory_bytes` (2–4 GB allocations, SIGABRT)
`src/stdlib.pion:963-978`: `count = k.to_int()` truncates Int64 → 32-bit `Int`, and
`total = count * s.length() + (count - 1) * sep.length()` overflows 32-bit; `charge_mem` returns `Ok` for
`bytes <= 0` (`src/vm.pion:18-21`).

| probe (default limits, 32 MiB) | rel | dbg | wrel | wdbg |
| --- | --- | --- | --- | --- |
| `s = ('a'):rep(1e6); s:rep(2148)` | **SIGABRT, 2.05 GB RSS** | SIGABRT | Memory.grow trap (2.0 GB) | trap |
| `s:rep(4295)` (wraps to +32 704) | **SIGABRT, 2.05 GB** | SIGABRT | trap | trap |
| `('b'):rep(2148, s)` (sep) | **OK — returns a 2 147 002 148-byte string, 4.1 GB RSS** | same | trap | trap |
| `#('x'):rep(2^32 + 3)` | `3` (Lua: memory error) | 3 | 3 | 3 |

### P0-8 `table.move` charges no fuel
`table.move({}, 1, 1e9, 2)` completes in 23–24 s native under `max_fuel = 1e5` (`move_1e9_tight`) and times out
on wasm32; `table.move({1}, 1, math.maxinteger, 2)` never returns in any mode (Lua 5.4.7: "too many elements to
move"). Test `p0_8_*`: 1e7 elements under fuel 1e4 → `OK` instead of `FuelLimit`.

### P0-9 plain `string.find` is O(n·m) with no fuel
`s = ('a'):rep(2e6); s:find(('a'):rep(1e6) .. 'b', 1, true)` → > 30 s in all 4 modes (probe `find_plain_long`);
test `p0_9_*` (20 000 × 10 000 under fuel 1e5 → `OK`).

### P0-10 `%b` balance matching is not fuelled
`string.find(('('):rep(1e6), '%b()')` → > 30 s in all 4 modes (probe `balance_long`; Lua 5.4.7 is also
quadratic here, but Lua does not claim a fuel budget). Test `p0_10_*`. Backtracking patterns (`a*a*…c`) are
correctly fuel-bounded (control).

### P0-11 Allocate-then-check: `table.unpack` / `gsub` / `table.concat` / `string.format` build the result before any limit check
| probe | native | wasm32 |
| --- | --- | --- |
| `pcall(table.unpack, {}, 1, 1e8)` | 1.5 GB RSS, then `StackLimit` | **Memory.grow RangeError (crash)** |
| `s=('a'):rep(2e4); s:gsub('a', s)` | 768 MB RSS, then `MemoryLimit` | 1.14 GB, then `MemoryLimit` |
| `table.concat` of 2000×1 MB | builds before `charge_mem` (`src/stdlib.pion:680-705`) | — |
| `string.format('%099999999d', 1)` | 291 MB RSS, reports **`OutputLimit`** (nothing was printed) | 410 MB |

The 32 MiB budget therefore bounds the *bookkeeping*, not the host allocation; on wasm32 a one-liner kills the
instance.

---

## P1 — Lua 5.4 semantic divergences (wrong results without error) and sandbox-semantics gaps

| id | finding | minimal repro → Pion vs Lua 5.4.7 |
| --- | --- | --- |
| P1-1 | `tostring`/`print`/`..` of floats use shortest round-trip, not `"%.14g"` | `print(0.1+0.2, 2^53)` → `0.30000000000000004 9007199254740992.0` vs `0.3 9.007199254741e+15` (any generated text/JSON differs) |
| P1-2 | decimal literals / `tonumber` not correctly rounded; denormals flushed | `1e100 == 0x1.249ad2594c37dp+332` false; `9223372036854775808 == 0x1p63` false; `5e-324 > 0` false |
| P1-3 | `local _ENV` / `_ENV` parameters ignored | `local function f() local _ENV = {} y = 2 end f() print(y)` → `2` vs `nil`; `local _ENV = {v=…}` reads `nil` (scripts that sandbox via `_ENV` leak into `_G`) |
| P1-4 | clearing fields during `pairs` (allowed by the manual) errors | `for k in pairs(t) do t[k] = nil end` → `invalid key to 'next'` |
| P1-5 | `goto` / `::label::` not parsed | `goto continue` → `SyntaxError` |
| P1-6 | integer `for` overflows at `maxinteger` | `for i = math.maxinteger-2, math.maxinteger` → infinite loop (`FuelLimit`) vs 3 iterations; same for large steps |
| P1-7 | int/float comparisons go through float | `math.maxinteger < 2^63` → `false` vs `true`; `2^53+1 > 2^53+0.0` → `false` |
| P1-8 | float `%` = `a - floor(a/b)*b` | `5 % math.huge` → `nan` vs `5.0`; `1e308 % 3` → `0.0` vs `2.0` |
| P1-9 | `%f` goes through Int64 and prints garbage | `format('%.0f', 2^63)` → `9223372036854775807`; `format('%.20f', 0.1)` → `0.09223372036854775807`; `format('%f', 1e20)` → `9223372036854775807.9223372036854775807`; `%.2f` of 2.675 → `2.68` vs `2.67` |
| P1-10 | `%e`, `%g`, `%a`, `%q`, `#`/space flags wrong or missing | `%e` of 12345.678 → `12345.678`; `%g` of 123456789 → `123456789` vs `1.23457e+08`; `%q` does not escape `\n " \0` (generated code is not re-loadable); `%#x` → `ff` |
| P1-11 | `gsub` with empty frontier match duplicates the subject | `('aXb'):gsub('%f[%u]','|')` → `a|aXb` vs `a|Xb` |
| P1-12 | string index args truncated Int64 → Int32 | `('abc'):byte(math.maxinteger)` → `99` vs `nil`; `('abc'):sub(2^62)` → `abc` vs `""` |
| P1-13 | `__metatable` ignored | `getmetatable(protected)` returns the real metatable; `setmetatable` succeeds |
| P1-14 | `<close>` never calls `__close`; `<const>` reassignment and unknown attributes accepted | |
| P1-15 | no GC / no reclamation: `memory_used` only grows and arenas (`tables`, `closures`, `upvalues`) never shrink | `for i=1,1e6 do local t={} end` → `MemoryLimit` under the default budget; 2e6 throw-away closures → 378 MB host RSS; `s == s .. ''` ×2000 on a 200 KB string → `MemoryLimit` |
| P1-16 | custom libm without range reduction | `math.sin(1e22)` → `0.0` vs `-0.8522`; `math.sin(1e10)` off at the 7th digit |
| P1-17 | stdlib gaps vs README | no `coroutine`, `load`, `collectgarbage`, `math.random`/`tan`/`asin`/`atan`, `string.pack`/`unpack`/`dump`, `utf8.charpattern` |
| P1-18 | `table.unpack({}, mininteger, maxinteger)` returns nothing | Lua: "too many results to unpack" |
| P1-19 | `__index` chain limit 100 (Lua 2000) | 100-level prototype chain → `RuntimeError` |
| P1-20 | `#("x"):rep(n)`-style fuel ≠ CPU: per-call O(len) copies are free | `s:byte(i)` copies the whole string (`string_to_bytes`): 200 000-byte scan = **16.6 s native / 20.3 s wasm32** (Lua: ms); a 1 MB string key is re-hashed per access: 2 000 lookups = 2.7 s (Lua 0.01 s) |
| P1-21 | non-tail recursion depth and `__call` depth far below Lua by default | `f(10000)` non-tail recursion → `StackLimit` (Lua OK); 500-deep `__call` recursion → `StackLimit` |

## P2 — compatibility / diagnostics / host-API robustness

| id | finding |
| --- | --- |
| P2-1 | runtime errors and `error()` carry no `chunk:line:` prefix; `error(msg, 2)` blames nobody; no variable names in messages |
| P2-2 | argument checks missing: `type()`, `tostring()`, `tonumber('10', 1)`, `table.insert(t, 1, 2, 3)`, `utf8.codepoint('abc', 4)`, `utf8.len('abc', 5)` all succeed |
| P2-3 | bitwise operators accept strings (`'3' | 0`), Lua 5.4 raises |
| P2-4 | `gmatch` ignores the 5.4 `init` argument and treats `^` as an anchor |
| P2-5 | utf8 strictness: surrogates accepted by `len`/`codepoint`, `offset` accepts continuation bytes, `"\u{7FFFFFFF}"` rejected (Lua accepts up to 2^31) , `utf8.char(0x7FFFFFFF)` errors |
| P2-6 | `\r\n` in long strings not normalised (`#[[\r\nab\r\ncd]]` = 6 vs 5); `#!` first line silently skipped by `exec` |
| P2-7 | `math.abs(-0.0)` → `-0.0`; `for i = 1, 3.7` yields floats (Lua: integers) |
| P2-8 | `__name` ignored by `tostring`; `__tostring` returning a number rejected (5.4.7 accepts) |
| P2-9 | host API: a `LuaValue::Table` handle from another VM or out of range panics the host (`index 99999 out of bounds`) or silently aliases a different table — handles are bare arena indices |
| P2-10 | limits below Lua's are silently *extended* elsewhere: >200 locals, >255 upvalues, >32 pattern captures, `%100d` widths are all accepted (harmless, but differs) |

---

## Benchmark fairness audit (`packages/lua/bench`, Go gopher-lua v1.1.1)

`bench/run_bench.sh` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved), SHA-256 of stdout
verified identical for every pair and round; Pion `--release`, Go `-mod=readonly`. Same machine, run while idle.

| workload | Pion median (min / p95) ms | gopher-lua median ms | Pion speed vs Go | Pion peak RSS | Go peak RSS | stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| W3 as shipped (Go `NewState()` = all libs: os/io/channel/coroutine/debug/package…) | 40.7 (37.8 / 44.3) | 104.1 | **2.56x** | 2.5 MiB | 14.3 MiB | `4ca1abc0c6fb1a09…` |
| **W3 fair**: Go `SkipOpenLibs` + base/table/string/math (= Pion's library set) | 40.7 (38.4 / 41.2) | 71.7 | **1.76x** | 2.5 MiB | 13.3 MiB | `4ca1abc0c6fb1a09…` |
| W3 floor: Go `SkipOpenLibs` + base only | 40.3 (38.8 / 41.1) | 54.6 | **1.36x** | 2.5 MiB | 12.7 MiB | `4ca1abc0c6fb1a09…` |
| W3 precompiled: Pion `compile` once + `exec_chunk` vs Go `Compile` once + `NewFunctionFromProto` | 29.7 (29.4 / 31.4) | 52.8 | **1.78x** | 2.5 MiB | 12.8 MiB | `4ca1abc0c6fb1a09…` |
| W3-heavier per request (200-iter loop + `format`/`concat`), fair lean Go | 79.5 (78.9 / 90.2) | 50.2 | 0.63x | 2.8 MiB | 12.8 MiB | `3bdcd3b8a24d3e52…` |
| A1 200k string keys insert/lookup/pairs | 189.6 (171.9 / 194.6) | 150.4 | 0.79x | 44.4 MiB | 53.9 MiB | `01b1dd8624f0d65f…` |
| A2 200k int keys with stride 1024 (sparse) | 139.7 (137.6 / 152.0) | 1571.5 | **11.25x** | 36.4 MiB | 4561.6 MiB | `40859fddbc15dbb4…` |
| A3 closure calls + 150-deep non-tail recursion | 231.7 (228.6 / 236.5) | 56.7 | 0.24x | 2.8 MiB | 10.3 MiB | `801dbc4161b1f997…` |
| A4 `gsub`/`gmatch` over a 108 KB line ×10 | 5566.4 (5465.9 / 5646.3) | 3190.0 | 0.57x | 3.3 MiB | 132.8 MiB | `deb6465fbd97bcd8…` |
| A5 `table.sort` asc/desc/equal/sawtooth 50k + Lua comparator 20k | 208.7 (207.4 / 212.5) | 50.5 | 0.24x | 14.0 MiB | 18.7 MiB | `f2fdaa7f569a5bc6…` |
| A6 `table.concat` 100×1000 parts + 3000 `..` appends | 40.5 (39.3 / 42.2) | 25.6 | 0.63x | 11.3 MiB | 12.1 MiB | `72885efe86bade26…` |
| A7 `s:byte(i)` scan of a 50 KB string | 1053.9 (1026.2 / 1087.2) | 13.5 | 0.01x | 2.8 MiB | 7.1 MiB | `e9d0508853d49c32…` |
| A8 200k metatable method calls + allocations | 631.6 (616.4 / 653.0) | 275.0 | 0.44x | 205.2 MiB | 13.4 MiB | `93fdf2bfc210928d…` |

Findings on fairness:

- **W3's published 2.81x is inflated by library loading, not VM work.** `lua.NewState()` opens every gopher-lua
  library (os, io, channel, coroutine, debug, package, …) per request, while `LuaVm::new()` registers a much smaller
  set. Opening only the same subset (base/table/string/math) drops the margin to **1.76x**; base-only gives **1.36x**.
  The honest headline for "fresh sandbox per request" is ~1.4–1.8x, still a real Pion win (plus 5x lower RSS).
- Pre-compiled reuse keeps the win (1.78x): Pion's `Chunk` reuse is legitimately cheap.
- As soon as a request does real work (W3-heavier: a 200-iteration loop plus `format`/`concat`), Pion is **0.63x**:
  the W3 script is so small that interpreter speed does not matter there.
- Adversarial workloads: Pion loses on calls/closures (0.24x), sort (0.24x), OOP method calls (0.44x, and **205 MiB
  RSS vs 13 MiB** because nothing is reclaimed, P1-15), pattern work (0.57x) and `s:byte(i)` scans (**0.01x**, P1-20).
  Pion wins big on sparse integer keys (**11.25x**; gopher-lua grows its array part to 4.5 GiB RSS on that input) and
  on start-up / RSS everywhere.
- Shipped W1/W2 run Pion with raised limits (`max_fuel 5e8`, 64 MiB) — fair for a throughput test, but note that the
  default 32 MiB budget is exhausted by allocation churn alone (P1-15), so W1/W2-style scripts at production
  defaults may fail rather than run slower.

## What `packages/lua` gets right (honest credit)

- **Limits are not catchable**: `pcall`/`xpcall`/sort comparators/`gsub` callbacks/`xpcall` handlers that loop or
  allocate all surface `FuelLimit`/`MemoryLimit`/`StackLimit` to the host (control tests, probes `*_swallow_*`).
- **TCO** is real: 100 000-deep tail recursion under `max_call_depth = 64`; 300 000-deep in the corpus.
- **Parser nesting guard** for parens, table constructors, blocks, functions, `if`, `not`, `..`, `^`:
  1e5-deep inputs are rejected with `StackLimit` in all 4 modes.
- **Metamethod recursion through tables** (`__index = t`, `__newindex` cycles) and through functions
  (`__index`/`__eq`/`__lt`/`__concat`/`__tostring` recursion) ends with a clean error under default limits on native.
- **Integer edge arithmetic**: `mininteger // -1`, `mininteger % -1`, `-mininteger`, `1 << 64`, `1 << 63`,
  `-1 >> 63`, `x // 0` error, `x // 0.0`, NaN/nil table keys — all match Lua 5.4.7 with no SIGFPE/trap.
- **Closures/upvalues**: per-iteration `for` upvalues, close on `break`/error/return, stack reuse after `pcall`,
  top-level error then re-`exec` on the same VM — all correct.
- **Isolation**: string metatable is per-VM (poisoning it in one VM does not affect another); a `Chunk` is safely
  reusable across VMs.
- **`table.sort`** (merge sort) never crashes or loops with inconsistent / random / erroring / mutating comparators.
- **Hash tables** handle stride/collision-prone int, float and string keys in linear time.
- **4-mode determinism**: every non-crashing case of the 434-case corpus is byte-identical across native
  debug/release and wasm32 debug/release.

## Reproduction

```sh
sh packages/lua/audit/run_audit.sh            # build + tests + diff + dos + bench
sh packages/lua/audit/run_audit.sh tests      # 45 red-team/control tests
sh packages/lua/audit/run_audit.sh diff       # 434-case differential vs Lua 5.4.7 (4 modes)
sh packages/lua/audit/run_audit.sh dos        # crash / DoS / limit-bypass probes (4 modes, RSS + time)
sh packages/lua/audit/run_audit.sh bench      # fairness + adversarial benchmarks
```

Layout: `driver/` (Pion protocol driver for diff + probes), `diff/` (`cases.py` corpus, `oracle.lua`,
`compare.py`), `dos/probes.py`, `bench/` (`pion/`, `go/` with locked `go.mod`/`go.sum`, `scripts/*.lua`,
`run_bench.sh`), `redteam_test.pion`.
