# `hcl` — Pure-Pion HashiCorp HCL2 Parser, Evaluator & Formatter

Pure-Pion implementation of **HashiCorp HCL2** (the configuration language powering Terraform, Packer, Nomad, and Vault), aligned with official Go **`github.com/hashicorp/hcl/v2`** (`hclsyntax`, `hclwrite`, and `cty`), featuring a mode-stack lexer, depth-bounded recursive-descent parser with flat AST arena, `EvalContext` expression & template evaluator, 40+ built-in functions, JSON configuration syntax equivalence, and a canonical `hclwrite.Format`-compatible formatter (`format_hcl`).

- **Zero C dependencies / No `World`**: Pure Pion, runs identically on Native and `wasm32` (4-mode byte-identical across `native_rel`, `native_dbg`, `wasm_rel`, `wasm_dbg`).
- **Complete HCL2 Syntax (`src/lexer.pion`, `src/parser.pion`, `src/ast.pion`, `src/json_syntax.pion`)**:
  - Bodies, attributes, nested blocks with string & identifier labels, strict one-line block rules, duplicate attribute rejection, UTF-8 BOM skipping, `#` / `//` / `/* */` comments, and exact 1-based line/column `Span` diagnostics.
  - Quoted strings with `\n`/`\r`/`\t`/`\"`/`\\`/`\uXXXX`/`\UXXXXXXXX`, `$$`/`%%` template escapes, nested `${...}` interpolations, `%{if}`/`%{else}`/`%{endif}` and `%{for}`/`%{endfor}` control directives, and spec-accurate line-scoped `~` whitespace chomping.
  - Plain heredocs (`<<EOF`) and indented heredocs (`<<-EOF`) with CRLF preservation and common leading whitespace stripping.
  - Full expression grammar: exact arbitrary-precision decimal numbers (`BigDec`), booleans, `null`, tuples, objects (including `(expr) = v` dynamic keys and newline-insensitive bracketed expressions), traversals (`a.b[0]`, legacy `a.0`), full splat `[*]` (including chained splats), legacy attr-only splat `.*`, unary `-`/`!`, binary operators with exact HCL2 precedence (Pratt precedence climbing), ternary `cond ? a : b` with `cty`-compatible type unification, function calls with `...` argument expansion, and `for` tuple/object comprehensions (with `if` filtering and `...` grouping).
  - Strict RFC 8259 JSON configuration syntax equivalence (`parse_json`, `eval_json_body`, `eval_json_body_to_json`) with duplicate-key rejection, template evaluation in object keys, exact `BigDec` numbers, and Go-compatible lone-surrogate replacement (`U+FFFD`).
- **Evaluator & Built-in Function Library (`src/eval.pion`, `src/funcs.pion`, `src/bigdec.pion`, `src/unicode_util.pion`)**:
  - `EvalContext` supporting variables, user-registered custom functions, and `HclLimits` (`max_depth` with stack-safe hard ceiling, `max_steps`, and streaming `max_output_bytes` covering templates, `join`, `format`, `jsonencode`, and `eval_body_to_json`).
  - HCL2 single-interpolation unwrap rule (`"${expr}"` and `"${~ expr ~}"` preserve raw typed values).
  - Lazy short-circuiting for `&&`, `||`, ternary `?:`, `try(...)`, and `can(...)`.
  - 40+ built-in functions with Unicode-aware `lower`/`upper`/`trimspace`, extended grapheme-cluster `length` and overflow-safe `substr`, `format` (`-` flag, `.precision`, strict `%d`), `merge`/`tostring` null handling, `coalesce` type unification, and HTML-escaped `jsonencode`.
  - Streaming, output-budgeted deterministic `eval_body_to_json` (sorted object keys) for cross-runtime verification.
- **Canonical Formatter (`src/format.pion`)**:
  - `format_hcl` aligned with `hclwrite.Format` / `terraform fmt`: 2-space indentation, vertical `=` alignment across contiguous single-line attribute groups (breaking on multi-line value openers like `tags = {`), aligned trailing comments, Unicode codepoint width alignment, blank-line and CRLF/EOF-newline preservation, heredoc preservation, and strict idempotency (`format_hcl(format_hcl(s)) == format_hcl(s)`).

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
| `pion` | 590.412 | 556.260 | 636.540 | 39360769.47 | 24.05 MiB | 0.71x |
| `go_hcl` | 420.075 | 402.781 | 431.032 | 28004966.67 | 59.62 MiB | 1.00x (baseline) |

### W2: Batch Parse + `EvalContext` Full Expressions / `for` / Templates / Built-ins (`1,000x`)

End-to-end parse + `EvalContext` evaluation of templates (`${...}`, `%{for}`, `%{if}`, `~`), `for` tuple & object (`...` grouping) comprehensions, full splat `[*]`, ternary with type unification, arbitrary-precision `BigDec` arithmetic (with exact small-integer fast path), and built-ins (`lower`, `upper`, `join`, `concat`, `merge`, `length`, `min`, `max`), serialized via streaming budgeted canonical JSON.
SHA-256: `93ab6ab3ed8ffd56375ac5bbd2ac59a08af2db8f8e0bfbda4ae50e6034cc2b8b`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_hcl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 42.036 | 41.320 | 42.280 | 42036.46 | 3.00 MiB | **3.08x** |
| `go_hcl` | 129.594 | 126.871 | 131.298 | 129593.58 | 15.12 MiB | 1.00x (baseline) |

### W3: Batch Canonical Formatting `format_hcl` vs `hclwrite.Format` (`3,000x`)

Realistic Terraform configuration featuring multi-line `tags = { ... }` attribute blocks (breaking `=` alignment groups), multi-line lists, aligned trailing `#`/`//` comments, nested `versioning`/`lifecycle` blocks, `locals` with `for` comprehension, blank lines, and heredoc preservation — verified byte-for-byte identical to `hclwrite.Format`.
SHA-256: `7a4ec307b3a987955ac58fb6a748b43c0242950e35c5a4b48480c14a7de98224`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_hcl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 123.722 | 122.713 | 126.061 | 41240.79 | 2.56 MiB | **1.37x** |
| `go_hcl` | 169.535 | 165.330 | 172.597 | 56511.75 | 18.41 MiB | 1.00x (baseline) |

### Objective Performance & Tradeoff Notes

- **Expression & Template Evaluation (W2, 3.08x faster, 5.0x lower RSS)**: `packages/hcl` evaluates a flat `Array[ExprNode]` arena directly over `HclValue`, combining an exact small-integer fast path with pure-Pion arbitrary-precision `BigDec` arithmetic and a streaming `max_output_bytes`-budgeted JSON encoder, avoiding `go-cty`'s reflection/type-descriptor boxing while preserving `go-cty` precision and safety budgets.
- **Canonical Formatting (W3, 1.37x faster, 7.2x lower RSS)**: Even with a full syntax validation pass (`parse_file_impl`) and full multi-line value group breaking + trailing comment alignment, `format_hcl` outperforms `hclwrite.Format` on realistic Terraform configurations with 7.2x lower peak RSS.
- **Large Config Parsing (W1, 0.71x speed, 2.5x lower RSS)**: After upgrading `ExprNode::LitNumber` to carry full `HclValue` (supporting exact `BigDec` literals) and adding full bracket-newline tracking, single-pass parsing on 2,111-block files is currently ~0.71x of Go's `hclsyntax.ParseConfig` while maintaining 2.5x lower peak RSS (24.05 MiB vs 59.62 MiB).
- **Safety & Cross-Runtime Guarantees**: All recursion paths clamp `max_depth` to a stack-safe ceiling (`160`) to prevent native stack overflow (`SIGSEGV`) and Wasm32 `RangeError`; all number-to-integer conversions are range-checked to avoid Wasm32 `f64→i32/i64` traps; `max_output_bytes` bounds templates, `join`, `format`, `jsonencode`, and `eval_body_to_json` incrementally.

## Formal Verification (Lean 4)

The core HCL2 stack-safety depth clamper, `HclLimits`/`Pos`/`Span` constructors, lexer identifier/hex predicates, and Go-compatible Unicode whitespace & case-folding kernels (`src/types.pion`, `src/lexer.pion`, `src/unicode_util.pion`) are annotated with `#verify`, extracted directly via `pionc extract-lean` (`3` types, `14` functions, `0` externals), and formally verified in Lean 4 with **24 theorems**, **0 `sorry`**, **0 `admit`**, **0 custom `axiom`**, **0 `bv_decide`**, **0 `native_decide`**, and **44/44** native-vs-Lean differential cross-checks:

- `proofs/HclProofs/LimitsAndLexer.lean` (12 theorems): `hcl_effective_max_depth` exact `[1, 160]` clamping, bounds, monotonicity, and idempotency across all `Int32`; `HclLimits::default` and `Pos::zero`/`Span::zero` invariants; `is_hcl_ident_start ⊆ is_hcl_ident_cont`, strict disjointness from `is_hcl_digit`, digit/hyphen continuation inclusion, and `hcl_hex_val` `[0, 15]` / `-1` bounds, digit exactness, and `'A'..'F'` case-insensitivity.
- `proofs/HclProofs/UnicodeCore.lean` (12 theorems): `is_unicode_space` exact ASCII characterization, all Go `unicode.IsSpace` non-ASCII whitespace codepoints (`U+0085`, `U+00A0`, `U+1680`, `U+2000..U+200A`, `U+2028/2029/202F/205F`, `U+3000`), and strict disjointness from ASCII identifiers; `unicode_cp_to_lower` / `unicode_cp_to_upper` ASCII exactness, bidirectional roundtrips, ASCII idempotency, Latin-1 `À..Ö` and Fullwidth `Ａ..Ｚ` roundtrips, and special Go mappings (`İ→i`, `ı→I`, `ÿ↔Ÿ`, `ς→Σ`, `µ→Μ`).
- `proofs/CheckAxioms.lean`: verifies all 24 theorems depend only on Lean's standard axioms (`propext`, `Classical.choice`, `Quot.sound`).
- `proofs/EvalDiff.lean`: 44-case Lean vs native Pion differential cross-check (`diff -u` zero differences).

```sh
LEAN_NUM_THREADS=2 LEAN_MEM_LIMIT=8192 bash packages/hcl/proofs/run_proofs.sh
```
