# `cel` — Pure-Pion Google Common Expression Language (CEL)

Pure-Pion implementation of the **Google Common Expression Language (CEL)** specification (`cel-spec`), featuring a hand-written lexer, depth-bounded recursive-descent parser with standard macro expansion, static type checker, arena-indexed AST evaluator with pre-compiled regex caching, and Day-1 safety budgets (`max_depth`, `max_cost`, `max_output_bytes`).

- **Zero C dependencies / No `World`**: Pure Pion (`packages/time` + `packages/regex`), runs identically on Native and `wasm32`.
- **Reusable Compiled `Program`**: Parse and statically type-check once against an `Env`, then evaluate repeatedly across `Activation`s with constant `matches(...)` regexes pre-compiled in the program cache.
- **CEL Semantics**:
  - Full literal & escape support (decimal/hex `int64`/`uint64`, IEEE 754 `double`, single/double/triple-quoted & raw strings, byte literals, `\xHH`/`\uHHHH`/`\UHHHHHHHH`/`\OOO` escapes, line comments).
  - Exact heterogeneous numeric comparisons across `int64`, `uint64`, and `double` (including `2^53+1`, `i64::MAX`, `u64::MAX`, and IEEE 754 `NaN` semantics).
  - Checked `int64`/`uint64` arithmetic with explicit `Overflow` and `DivisionByZero` errors.
  - Kleene 3-valued short-circuit logic (`true || err == true`, `err || true == true`, `false && err == false`, `err && false == false`, and error absorption in `all()` / `exists()`).
  - Standard macros: `has()`, `all()`, `exists()`, `exists_one()`, `map()` (2-arg & 3-arg), `filter()`.
  - Built-ins: UTF-8 codepoint `size()`, `contains()`, `startsWith()`, `endsWith()`, `matches()`, `in`, `type()`, `int()`, `uint()`, `double()`, `string()`, `bytes()`, `bool()`, `dyn()`, `timestamp()`, `duration()`, and full `Timestamp` / `Duration` arithmetic and accessors (with timezone offset support).
  - Safety limits (`EvalLimits`): `max_depth`, `max_cost` (fuel budget), and `max_output_bytes`.

## Quick Start

```pion
import "cel"

let env = cel::Env::new()
  .with_var("role", cel::CelType::String)
  .with_var("env", cel::CelType::String)
  .with_var("replicas", cel::CelType::Int)

let prog = match cel::compile("role == 'admin' || (env == 'staging' && replicas <= 5)", env) {
  Ok(p) => p
  Err(e) => panic(e.to_string())
}

let act = cel::Activation::from_pairs([
  ("role", cel::Value::string("dev")),
  ("env", cel::Value::string("staging")),
  ("replicas", cel::Value::int(3L)),
])

let allowed = prog.eval(act) // Ok(Value::bool(true))
```

## Verification

```sh
sh scripts/verify.sh packages/cel
```

4-mode `wasm_smoke` (each with a clean `PION_CACHE_DIR`):

```sh
PION_CACHE_DIR=/tmp/cel-nd pionc run packages/cel/wasm_smoke
PION_CACHE_DIR=/tmp/cel-nr pionc run --release packages/cel/wasm_smoke
PION_CACHE_DIR=/tmp/cel-wd pionc run --target wasm32 packages/cel/wasm_smoke
PION_CACHE_DIR=/tmp/cel-wr pionc run --target wasm32 --release packages/cel/wasm_smoke
```

All 4 modes exit `0` with byte-identical stdout:
`cel_wasm_smoke: OK checks=4` (`sha256:c6923538414ee8cc83e46933e831644f48812012b47856491c800117de8d8deb`).

## Head-to-Head Benchmarks vs Go `google/cel-go` (`v0.24.1`)

Run with:

```sh
sh packages/cel/bench/run_bench.sh
```

Measured on `Darwin arm64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification across all rounds and implementations):

### W1: Compiled IAM / K8s Admission Batch Eval (`80,000` ops)

4 compiled admission/IAM rules evaluated across 20,000 request contexts.
SHA-256: `498de4922d90154685f14f7b684226753e498d7dc6893fece00a7404445b4ad6`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_cel`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 49.032 | 42.373 | 73.006 | 612.91 | 2.62 MiB | **1.11x** |
| `go_cel` | 54.412 | 32.954 | 62.618 | 680.15 | 13.69 MiB | 1.00x (baseline) |

### W2: Macros + Regex `matches` + Timestamp Batch Eval (`20,000` ops)

2 compiled policies using `all`, `exists`, `filter`, regex `matches`, and `Timestamp`/`Duration` comparisons across 10,000 request contexts.
SHA-256: `8e806c8d63c22d1ada9bb33ec83a9f8dfd6e808b2a02c938f2ce29d6bdf77843`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_cel`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 47.052 | 23.161 | 57.390 | 2352.58 | 3.05 MiB | **2.50x** |
| `go_cel` | 117.495 | 104.578 | 131.388 | 5874.76 | 17.80 MiB | 1.00x (baseline) |

### W3: End-to-End Compile + Eval (`2,000` ops)

Parse + Static TypeCheck + Compile + Eval across 10 dynamic policies x 200 iterations.
SHA-256: `c32a199ce35392357704573f60522fa4622d48e8f7b5233158a7730a62a58030`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_cel`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 29.883 | 21.148 | 40.546 | 14941.25 | 3.02 MiB | **5.14x** |
| `go_cel` | 153.618 | 133.295 | 160.798 | 76809.06 | 18.34 MiB | 1.00x (baseline) |

### Objective Performance Analysis

- **End-to-End Compile + Eval (W3, 5.14x faster)**: `google/cel-go` uses an ANTLR4-generated parser, protobuf `CheckedExpr` construction, and reflection-heavy type checking. `packages/cel` uses a single-pass hand-written lexer + recursive-descent parser writing into a flat `Array[ExprNode]` arena with zero protobuf overhead.
- **Macros + Regex + Timestamp (W2, 2.50x faster)**: `packages/cel` evaluates `all`/`exists`/`filter`/`map` via dedicated `Comprehension` AST nodes (avoiding Go `ref.Val` interface boxing and GC pressure) and caches pre-compiled `packages/regex` automata per constant `matches()` call site.
- **Tiny Compiled Rules (W1, 1.11x median, higher min than Go)**: On very short steady-state rules, Go's `cel-go` planner compiles expressions into specialized closure trees with Go hash-map lookup (giving `go_cel` a lower min of `32.954 ms` vs `pion`'s `42.373 ms`). `packages/cel` currently walks the `ExprNode` arena with linear `Activation` lookup (`Array[(String, Value)]`). For activations with many (>20) variables, replacing linear lookup with indexed variable slots at compile time would further improve W1.
- **Memory Footprint**: `pion` runs in **2.62–3.05 MiB** Peak RSS vs Go's **13.69–18.34 MiB** (~5–6x lower memory, zero GC overhead, Wasm32-ready).
