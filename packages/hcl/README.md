# `hcl` — Pure-Pion HashiCorp HCL2 Parser, Evaluator & Formatter

Pure-Pion implementation of **HashiCorp HCL2** (the configuration language powering Terraform, Packer, Nomad, and Vault), aligned with official Go **`github.com/hashicorp/hcl/v2`** (`hclsyntax`, `hclwrite`, and `cty`), featuring a mode-stack lexer, depth-bounded recursive-descent parser with flat AST arena, `EvalContext` expression & template evaluator, 40+ built-in functions, JSON configuration syntax equivalence, and a canonical `hclwrite.Format`-compatible formatter (`format_hcl`).

- **Zero C dependencies / No `World`**: Pure Pion (reuses `packages/json5` for strict RFC 8259 JSON parsing/encoding), runs identically on Native and `wasm32`.
- **Complete HCL2 Syntax (`src/lexer.pion`, `src/parser.pion`, `src/ast.pion`)**:
  - Bodies, attributes, nested blocks with string & identifier labels, one-line blocks, duplicate attribute rejection, `#` / `//` / `/* */` comments, and exact 1-based line/column `Span` diagnostics.
  - Quoted strings with `\n`/`\r`/`\t`/`\"`/`\\`/`\uXXXX`/`\UXXXXXXXX`, `$$`/`%%` template escapes, nested `${...}` interpolations, `%{if}`/`%{else}`/`%{endif}` and `%{for}`/`%{endfor}` control directives, and `~` adjacent-literal whitespace chomping.
  - Plain heredocs (`<<EOF`) and indented heredocs (`<<-EOF`) with automatic common leading whitespace stripping.
  - Full expression grammar: numbers (int/float/scientific), booleans, `null`, tuples, objects (including `(expr) = v` dynamic keys), traversals (`a.b[0]`, legacy `a.0`), full splat `[*]`, legacy attr-only splat `.*`, unary `-`/`!`, binary operators with exact HCL2 precedence, ternary `cond ? a : b`, function calls with `...` argument expansion, and `for` tuple/object comprehensions (with `if` filtering and `...` grouping).
  - JSON configuration syntax equivalence (`parse_json`, `eval_json_body`, `eval_json_body_to_json`).
- **Evaluator & Built-in Function Library (`src/eval.pion`, `src/funcs.pion`)**:
  - `EvalContext` supporting variables, user-registered custom functions, and `HclLimits` (`max_depth`, `max_steps`, `max_output_bytes`) DoS protection.
  - HCL2 single-interpolation unwrap rule (`"${expr}"` preserves the raw typed value when no strip markers or surrounding literals are present).
  - Lazy short-circuiting for `&&`, `||`, ternary `?:`, `try(...)`, and `can(...)`.
  - 40+ built-in functions: `lower`, `upper`, `trim`, `trimspace`, `trimprefix`, `trimsuffix`, `startswith`, `endswith`, `split`, `join`, `replace`, `format`, `substr`, `length`, `concat`, `flatten`, `distinct`, `compact`, `reverse`, `sort`, `merge`, `keys`, `values`, `lookup`, `coalesce`, `coalescelist`, `try`, `can`, `min`, `max`, `abs`, `ceil`, `floor`, `range`, `zipmap`, `contains`, `element`, `index`, `slice`, `jsonencode`, `jsondecode`, `tostring`, `tonumber`, `tobool`, `tolist`, `tomap`.
  - One-shot deterministic `eval_body_to_json` (sorted object keys) for cross-runtime verification.
- **Canonical Formatter (`src/format.pion`)**:
  - `format_hcl` aligned with `hclwrite.Format` / `terraform fmt`: 2-space indentation, vertical `=` alignment across contiguous attribute groups, canonical operator spacing, comment & heredoc preservation, and strict idempotency (`format_hcl(format_hcl(s)) == format_hcl(s)`).

## Quick Start

```pion
import "hcl"

let ctx = hcl::EvalContext::from_vars([
  ("env", hcl::HclValue::str("prod")),
  ("replicas", hcl::HclValue::int(3)),
])

let cfg =
  "service = \"api-${env}\"\n" +
  "count   = \"${replicas}\"\n" +
  "ports   = [for i in range(replicas) : 8080 + i]\n"

let json_out = hcl::eval_body_to_json(cfg, ctx)
// Ok("{\"count\":3,\"ports\":[8080,8081,8082],\"service\":\"api-prod\"}")
```

## Verification

```sh
sh scripts/verify.sh packages/hcl
```

4-mode `wasm_smoke` (each with a clean `PION_CACHE_DIR`):

```sh
PION_CACHE_DIR=/tmp/w13-hcl-nd pionc run packages/hcl/wasm_smoke
PION_CACHE_DIR=/tmp/w13-hcl-nr pionc run --release packages/hcl/wasm_smoke
PION_CACHE_DIR=/tmp/w13-hcl-wd pionc run --target wasm32 packages/hcl/wasm_smoke
PION_CACHE_DIR=/tmp/w13-hcl-wr pionc run --target wasm32 --release packages/hcl/wasm_smoke
```

All 4 modes exit `0` with byte-identical stdout:
`hcl_wasm_smoke: OK checks=4` (`sha256:9682c0a70046561b0e96e7ae47d26889f8f555020f5ad388a99a3758027fe611`).

## Head-to-Head Benchmarks vs Official Go `github.com/hashicorp/hcl/v2` (`v2.23.0`)

Run with:

```sh
sh packages/hcl/bench/run_bench.sh
```

Measured on `Darwin arm64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification across all rounds and implementations):

### W1: Large Terraform Infra Config (`1,111` top-level / `2,111` total blocks) Parse + AST Walk (`15x`)

10 `variable` blocks, 1 `locals` block, 1,000 `resource "aws_instance"` blocks (each with tags, `<<-EOF` heredoc with template interpolation, and nested `root_block_device` block), and 100 `module` blocks.
SHA-256: `e436af329e7f4df18a33834d963893262b40bfbdefe75b17231a2a508bb06e5f`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_hcl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 309.427 | 295.549 | 327.472 | 20628450.00 | 23.95 MiB | **1.21x** |
| `go_hcl` | 374.089 | 366.058 | 394.481 | 24939255.53 | 60.86 MiB | 1.00x (baseline) |

### W2: Batch Parse + `EvalContext` Full Expressions / `for` / Templates / Built-ins (`1,000x`)

End-to-end parse + `EvalContext` evaluation of templates (`${...}`, `%{for}`, `%{if}`, `~`), `for` tuple & object (`...` grouping) comprehensions, full splat `[*]`, ternary, and built-ins (`lower`, `upper`, `join`, `concat`, `merge`, `length`, `min`, `max`), serialized to canonical JSON.
SHA-256: `93ab6ab3ed8ffd56375ac5bbd2ac59a08af2db8f8e0bfbda4ae50e6034cc2b8b`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_hcl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 43.005 | 42.308 | 43.733 | 43004.50 | 2.95 MiB | **2.75x** |
| `go_hcl` | 118.410 | 112.580 | 131.411 | 118410.08 | 15.11 MiB | 1.00x (baseline) |

### W3: Batch Canonical Formatting `format_hcl` vs `hclwrite.Format` (`3,000x`)

Canonical 2-space indentation, vertical `=` alignment across attribute groups, operator spacing, comments, and heredoc preservation, verified byte-for-byte identical to `hclwrite.Format`.
SHA-256: `ea58c2b61ae6f1acaa6b08f3c2d55855641e9e93b2c7c7e94803abf25365c512`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_hcl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 59.577 | 57.973 | 65.159 | 19859.04 | 2.39 MiB | **1.15x** |
| `go_hcl` | 68.371 | 65.278 | 71.496 | 22790.46 | 16.03 MiB | 1.00x (baseline) |

### Objective Performance & Tradeoff Notes

- **Expression & Template Evaluation (W2, 2.75x faster, 5.1x lower RSS)**: `packages/hcl` evaluates a flat `Array[ExprNode]` arena directly over `HclValue` without `go-cty`'s reflection/type-descriptor boxing or `math/big.Float` heap allocations, while enforcing explicit `HclLimits` depth/step/output budgets.
- **Large Config Parsing (W1, 1.21x faster, 2.5x lower RSS)**: The hand-written mode-stack lexer and flat arena parser avoid Go interface allocations per AST node and GC pauses on 2,111-block files.
- **Canonical Formatting (W3, 1.15x faster, 6.7x lower RSS)**: `format_hcl` currently runs a full syntax validation pass (`parse_file_impl`) before token-level formatting so malformed or deeply nested inputs fail cleanly with structured diagnostics; this trades some extra work on huge files for strict syntax validation compared to `hclwrite.Format`'s token-only pass.
- **Numeric Precision Tradeoff**: `packages/hcl` represents numbers as IEEE 754 `Double` (matching JSON/JSON5 and Wasm32 f64) rather than `go-cty`'s arbitrary-precision `big.Float`; integers up to `2^53` are exact.
