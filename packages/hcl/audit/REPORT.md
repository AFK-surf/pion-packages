# Red-team audit: `packages/hcl` (`feat/pkg-hcl` @ `2d86c20`)

Target: pure-Pion `packages/hcl` (HCL2 lexer/parser, evaluator, built-ins, JSON syntax,
`format_hcl`). Reference: official Go **`github.com/hashicorp/hcl/v2 v2.23.0`** with
**`github.com/zclconf/go-cty v1.16.2`** (the versions `bench/go_bench` pins), Go 1.27.
Platform: Darwin arm64, `pionc 0.1.0`, node 24 + `pion_wasm_rt.mjs` for wasm32.

`src/`, `tests`, `bench/`, `pion.toml` and `README.md` were only read. Everything here lives in
`packages/hcl/audit/` and runs with one command:

```sh
sh packages/hcl/audit/run_audit.sh     # ~35 s; exit 0 only when every check below PASSes
```

Artefacts go to `$AUDIT_OUT` (default `${TMPDIR:-/tmp}/pion-hcl-audit`); the worktree stays clean.

| Piece | What it is |
| --- | --- |
| `cases.py` | 472 differential cases (`id`, mode, source): lexer, bodies, templates, heredocs, expressions, traversal/splat, `for`, functions, numbers, JSON syntax, formatter, formatter idempotency, Double→Int conversions. |
| `go_oracle/` | Go oracle on hcl/v2 v2.23.0 (`go.mod` + `go.sum`, built `-mod=readonly`). Prints `id OK <json>` / `id ERR -` per case. |
| `pion_driver/` | The same CLI on `packages/hcl` (`cases <file>`), plus `probe <kind> <n> [max_depth]` DoS probes that build hostile input in-process. Built in **native_rel, native_dbg, wasm_rel, wasm_dbg**. |
| `run_cases.py` | Runs a driver over a case file in chunks; a crashing chunk is bisected until each crashing case is isolated and recorded as `CRASH` (so one trap cannot hide the other cases). |
| `compare.py` | Verdict + value diff vs Go (numbers compared as exact decimals, so `1e+21` == `1000…0` but `…992` != `…993`); 4-mode byte identity; `--robust` fuzz gate. |
| `fuzz.py` | Deterministic mutation fuzzer (seed `20261123`, 4000 inputs derived from `cases.py`). |
| `probes.py` | 31 DoS probes × 4 modes, with exit-code, output-budget and peak-RSS (≤ 256 MiB) criteria. |

Mode mapping for the Go oracle: `expr` = `hclsyntax.ParseExpression`+`Value`, `tmpl` =
`ParseTemplate`, `body` = `ParseConfig` mapped to the same `{type: {label: [body…]}}` shape that
`eval_body_to_json` documents, `json` = `hcl/json.Parse` + `JustAttributes`, `fmt` =
`ParseConfig` must succeed then `hclwrite.Format`, `fmt2` = `Format(Format(x)) == Format(x)`.
Both sides use one fixed `EvalContext` (`s n f t nul l e o objs nested`). Functions are cty
`stdlib` (what Terraform uses) except `length`, which is Terraform's
(`internal/lang/funcs.LengthFunc`: graphemes for strings, attribute count for objects).

## Verdict

**3 P0, 9 P1, 24 P2.** The parser/evaluator recursion guards hold under default limits on all
four modes (31 nesting/unclosed/long-token probes, all clean `LimitExceeded`/`SyntaxError`),
`try`/`can`, `&&`/`||` and `?:` short-circuit exactly like hcl/v2 2.23, and the formatter is
idempotent on every input where Go's is. But: a 13-byte expression traps the wasm32 instance, a
20-byte `substr` call aborts the native process, `HclLimits.max_output_bytes` does not bound
`eval_body_to_json`, and there are many silent value/format divergences from hcl/v2.

`run_audit.sh` at `2d86c20`:

```
control  PASS      control: 262/262 PASS, 0 FAIL      (pionc test packages/hcl)
diff     FAIL      differential: 402/472 PASS, 70 FAIL
                   4-mode: native_dbg 472/472, wasm_rel 456/472, wasm_dbg 456/472 identical to native_rel
fuzz     FAIL      fuzz: 3994/4000 PASS, 6 FAIL (no crash, 4 modes identical)
probe    FAIL      probes: 96/124 PASS, 28 FAIL
AUDIT: FAIL (open defects, see REPORT.md)     exit 1
```

Each defect below lists the case/probe ids that gate it; a fix is complete when those turn PASS.

## P0 — crash or unbounded resource use from a tiny input, default limits

### P0-1 wasm32 trap on Double→Int conversion of large numbers

`l[4294967296]` (13 bytes), `"x${1e20}"`, `element(l, 4294967297)`, `substr(s, 4294967296, 1)`,
`1e300 % 7`, `floor(1e300)`, `format("%d", 1e300)`, `l.4294967296`, `tostring(1e20)` …

* Go: clean diagnostic (`l[4294967296]` → "Invalid index") or exact value (`"x${1e20}"` →
  `"x100000000000000000000"`).
* Pion wasm32 (rel and dbg): `RuntimeError: float unrepresentable in integer range` — the
  whole instance dies. Native saturates instead and returns **wrong values**:
  `floor(1e300)` = `9223372036854776000`, `1e300 % 7` = `1e300`, `format("%d", 1e300)` =
  `"9223372036854775807"`, `element(l, 4294967297)` = `"b"` (Go `"c"`).
* Root cause: `Double::to_int()` / `to_int64()` are lowered to trapping
  `i32/i64.trunc_f64_s` on wasm32 and are called on unchecked user numbers:
  `eval.pion:489` (index), `funcs.pion:213` (`hcl_number_to_string`, every template / string
  conversion of a number ≥ 2^63), `:524` (`%d`), `:586`/`:596` (`floor_double`/`ceil_double`,
  also used by `%`), `:829`/`:833` (`substr`), `:1303` (`element`), `:1344`/`:1348` (`slice`).
  Range-check (and reject non-integers) before converting; format large numbers without `Int64`.
* Gates: `trav/index_huge`, `trav/index_huge_neg`, `conv/*`, `crash/*` (4-mode identity);
  `fuzz/00120 00253 01829 02898 03771` (`substr(s, 4294967296, 1)`, `l[1e300]`, `l.4294967296`, `9007…993 % 2194`, `"nul${1e300}"`).

### P0-2 native abort in `substr` (Int overflow → out-of-bounds slice)

`substr("hello", 1, 2147483647)`

* Go: `"ello"`.
* Pion native (rel and dbg): `pion panic … string slice out of bounds`, SIGABRT (rc 134).
  wasm32 returns `""` (different again).
* Root cause: `funcs.pion:845-851` computes `start + length` in `Int`; `1 + 2147483647`
  wraps negative, so `end < start` and `s.slice(start, end)` panics. Reached also via the
  saturating conversion of P0-1 (`substr(s, 1, 4294967296)`).
* Gates: `conv/substr_int_overflow`, `conv/substr_huge_len`; `fuzz/02200`.

### P0-3 `max_output_bytes` does not bound `eval_body_to_json` / `jsonencode`

`a = [for b in [join("", [for i in range(100000) : "xxxxxxxxxx"])] : [for i in range(N) : b]][0]`
(98-byte body). One 1 MB string referenced N times costs ~N+100k steps, far below `max_steps`.

* With `N = 200`: `eval_body_to_json` returns **200 MB** of JSON (budget 16 MiB); peak RSS
  405 MiB native, 713 MiB wasm32. Output and memory grow linearly with N, so N = 10 000 (one
  more digit) is a ~10 GB allocation: OOM natively, out-of-memory trap on wasm32.
* `jsonencode(...)` of the same value does return `LimitExceeded`, but only after building the
  full string (`funcs.pion:1375` checks `js.length()` post hoc): 405/713 MiB peak.
* Go hcl/v2 has no budgets at all, but this package advertises `HclLimits.max_output_bytes`
  as DoS protection; only templates are charged (`eval.pion:39`, `:850`).
* Root cause: `lib.pion:76-83` → `value_to_json_impl` (`funcs.pion:65`) serializes without a
  budget; `jsonencode` encodes then measures. Charge serialized bytes incrementally (and count
  shared values once per reference).
* Gates: `probe/amp/eval_body_to_json_200MB`, `probe/amp/jsonencode_200MB` (4 modes each).

## P1 — silent wrong result, or rejection of common valid configuration

| id | Input | Go hcl/v2 | Pion | Root cause | Gates |
| --- | --- | --- | --- | --- | --- |
| P1-1 newlines inside `(…)`, `[…]`, call args | `count = (t &&\n  n > 2) ? 1 : 0`, `(1 +\n 2)`, `[1 +\n 2]`, `max(1 +\n 2, 0)` | accepted (newlines are insignificant inside brackets) | `SyntaxError` | `parser.pion:786-797` only skips newlines right after `(` and before `)`; the binary/conditional parsers (`:351-536`) never skip them inside a bracket | `expr/paren_newline*`, `expr/tuple_newline_in_binop`, `expr/call_newline_in_binop`, `body/paren_newline_attr` |
| P1-2 `~` strip markers eat every adjacent line | `"a\n\n${~ s ~}\n\nb"` | `"a\nhello\nb"` | `"ahellob"` | hcl/v2 trims only the adjacent literal *token* (up to and including one newline); `eval.pion:833-848` `trim_*_ws` strip all whitespace of the whole chunk, and `:907-1027` apply it across parts | `tmpl/strip_newlines`, `tmpl/strip_for`, `tmpl/strip_if` |
| P1-3 `%` uses floored modulo | `-7 % 3`, `7 % -3` | `-1`, `1` (truncated, like cty/Go) | `2`, `-2` | `eval.pion:330-335` `a - floor(a/b)*b` | `expr/mod_neg`, `expr/mod_neg_r` |
| P1-4 numbers are IEEE `Double` | `9007199254740993`, `9007199254740993 == 9007199254740992`, `l[9007199254740993 - 9007199254740992]`, `0.1 + 0.2`, `{"a": 9007199254740993}` (JSON) | exact: `…993`, `false`, `"b"`, `0.3` | `…992`, **`true`**, **`"a"`**, `0.30000000000000004` | `HclValue::Number(Double)` (`types.pion:145`), `parse_number_double` (`parser.pion:81`); README calls it a trade-off, but comparisons, equality, `%` and indexing silently change | `num/*`, `json/big_int` |
| P1-5 UTF-8 BOM not skipped | `﻿a = 1` | `{"a":1}` | `{"﻿a":1}` (first attribute renamed) | lexer never skips a leading BOM (`lexer.pion:75-100`, `:219`) | `lex/bom_attr` |
| P1-6 JSON duplicate keys silently last-wins | `{"a": 1, "a": 2}`, `{"a": {"b": 1, "b": 2}}` | error "Duplicate argument" / duplicate property | `{"a":2}` — two readers of one `.tf.json` disagree | `parser.pion:2042` `DuplicateKeyPolicy::LastWins` | `json/dup_key`, `json/dup_nested_key` |
| P1-7 JSON object keys are not templates | `{"a": {"${s}": 1}}` | `{"a":{"hello":1}}` | `{"a":{"${s}":1}}` | `parser.pion:1893` pushes keys as plain `LitString` | `json/key_template` |
| P1-8 formatter aligns multi-line values into the `=` group | `tags = {…}` after `ami = …` in a resource (the most common Terraform shape) | `tags = {` keeps single-space `=`; group breaks | `tags          = {` | `format.pion:402-420` grouping ignores that the line opens a multi-line value | `fmt/tf_resource`, `fmt/obj_align_nested` |
| P1-9 `"${~ x ~}"` loses its type | `"${~ n ~}"`, `"${~n}"` | `4` (number; strip markers do not prevent unwrap) | `"4"` | `eval.pion:857-861` unwraps only without strip markers | `tmpl/unwrap_strip*` |

## P2 — edge-case divergences from hcl/v2 (accepting invalid input, rejecting valid input, library/format details)

| id | Input → Go vs Pion | Root cause / location | Gates |
| --- | --- | --- | --- |
| P2-1 lone `CR` is a newline | `a = 1\rb = 2\r` → Go error vs Pion `{"a":1,"b":2}` | `lexer.pion:243` | `lex/cr_only` |
| P2-2 one-line block rules not enforced | `b { x = 1\n y = 2 }`, `b { c { x = 1 } }`, `b {\n x = 1 }` → Go error vs Pion OK | `parser.pion:177-190` accepts `}` after any attribute | `body/oneline_block_*`, `body/block_no_newline_close` |
| P2-3 heredoc whitespace | `<<-EOF` whitespace-only line `"  "` kept by Go, emptied by Pion; plain `<<EOF` closed by `  EOF` accepted by Go, rejected by Pion; CRLF body kept by Go, normalized to LF by Pion | `parser.pion:1343-1430`, `lexer.pion:695-726`, `:823` | `heredoc/indented_ws_only_line`, `heredoc/marker_leading_ws_plain`, `heredoc/crlf` |
| P2-4 `x % 0` | Go `1 % 0` = `1` (cty), Pion `DivisionByZero` | `eval.pion:330-333` | `expr/mod_zero` |
| P2-5 operand types not checked when short-circuited | `false && "x"` → Go type error, Pion `false` | `eval.pion:246-290` | `expr/and_short_type` |
| P2-6 conditional result types not unified | `t ? 1 : "x"` → Go `"1"`, Pion `1`; `t ? 1 : [1]` → Go error, Pion `1` | `eval.pion:160-175` | `expr/cond_type_*` |
| P2-7 traversal accepted as object key | `{o.b = 1}` → Go error (needs parens), Pion `{"x":1}` | `parser.pion:1099-1127` | `expr/obj_traversal_key` |
| P2-8 non-integer index truncated | `l[1.5]` → Go error, Pion `"b"`; `nested.0.1` (lexed as number `0.1`) → Go error, Pion `nested[0]` | `eval.pion:489` `to_int()`, `parser.pion:592-600` | `trav/index_frac`, `trav/legacy_index_2` |
| P2-9 splat after splat flattens | `objs[*].id[*]` → Go `[["x"],["y"]]`, Pion `["x","y"]` | `parser.pion:640-721` folds the second `[*]` into the first's sub-steps | `splat/chain` |
| P2-10 `lower`/`upper` ASCII only | `lower("ÄBİ")` → Go `"äbi"`, Pion `"Äbİ"` | `funcs.pion:281-311` | `func/lower_unicode`, `func/upper_unicode` |
| P2-11 `trimspace` ASCII only | `trimspace("  x 　")` → Go `"x"` | `funcs.pion:313-352` | `func/trimspace_unicode` |
| P2-12 `length` counts code points | `length("éx")` → Terraform `2` (graphemes), Pion `3` | `funcs.pion:266` | `func/length_grapheme` |
| P2-13 `substr` is byte-based | `substr("héllo", 1, 2)` → Go `"él"`, Pion `"é"`; `substr("héllo", 0, 2)` → Pion splits a UTF-8 sequence (native emits invalid UTF-8 `"h\xc3"`, wasm32 `"h�"`: a 4-mode divergence) | `funcs.pion:836-852` uses `String::length`/`slice` | `func/substr_unicode`, `conv/substr_utf8_split` |
| P2-14 `format` verbs | `%-3d` rejected (Go `"7  "`); `%.2f` ignores precision (`"1.256"` vs `"1.26"`); `%d` of `1.5` gives `"1"` (Go error) | `funcs.pion:458-563` | `func/format_flag_minus`, `func/format_precision`, `func/format_d_frac` |
| P2-15 `merge` rejects `null` arguments | Go skips them | `funcs.pion:996` | `func/merge_null` |
| P2-16 `tostring(null)` | Go `null`, Pion error | `funcs.pion:1402` | `func/tostring_null` |
| P2-17 `coalesce` does not unify types | `coalesce(nul, 1, "x")` → Go `"1"`, Pion `1` | `funcs.pion:1088` | `func/coalesce_num` |
| P2-18 `jsonencode` HTML escaping | Go (and Terraform) escape `<`,`>`,`&` as `<…`; Pion emits them raw | `funcs.pion:1367` | `func/jsonencode` |
| P2-19 JSON lone surrogate escape rejected | `{"a": "\ud83d"}` → Go `"�"`, Pion error | json5 strict decoding (`parser.pion:2038-2050`) | `json/lone_surrogate` |
| P2-20 formatter collapses blank lines | `a = 1\n\n\n\nb = 2` → hclwrite keeps them, Pion keeps one | `format.pion:447-460` | `fmt/blank_lines`, `fmt/two_blank_after_block` |
| P2-21 formatter changes line endings / final newline | CRLF→LF; adds a final `\n` that hclwrite does not add (`a = 1`, `# end`) | `format.pion:61-131`, `:437-474` | `fmt/crlf`, `fmt/no_trailing_nl`, `fmt/comment_end` |
| P2-22 alignment counts bytes, not characters | `éé = 1\nb = 2` → Pion pads `b` by 4 | `format.pion:184-192` | `fmt/align_unicode` |
| P2-23 trailing comments not aligned | `a = 1 # x\nbbbb = 22 # y` → hclwrite aligns `#` columns | `format.pion:194-288` | `fmt/attr_comment_align` |
| P2-24 recursion has no hard cap below the caller's `max_depth` | `HclLimits::new(1000000, …)` + 100 000-deep `[`, `(`, blocks, templates, `for` → native SIGSEGV (rc -11), wasm32 `RangeError: Maximum call stack size exceeded`; 5 000 deep already crashes wasm32 while native survives (mode-dependent safe depth). Go's growable stacks just work. | recursive descent in `parser.pion` / `eval.pion` with only the configurable counter; clamp to a stack-safe ceiling or go iterative | `probe/raised_depth/*` (4 modes) |

Several rows bundle closely related behaviours (P2-3, P2-6, P2-8, P2-14, P2-21); each has its own gating case.

## 4-mode consistency (native_rel / native_dbg / wasm_rel / wasm_dbg)

* All 472 differential lines are byte-identical between native_rel and native_dbg, and
  between wasm_rel and wasm_dbg. **No `native_dbg`-only compiler anomaly was observed.**
* native vs wasm32 differ on exactly 16 lines, all explained by P0-1 (trap vs saturation),
  P0-2 (native panic vs wasm `""`) and P2-13 (invalid UTF-8 vs U+FFFD).
* DoS probes: same verdict in all 4 modes except the raised-depth crashes (P2-24) and the
  RSS of P0-3; wasm32 peaks are ~2x native because of node's baseline.
* The fuzz run (4000 mutants) finds only P0-1/P0-2 instances (6 cases), no other crash.

## Benchmark fairness (`bench/`, `README.md`)

`sh packages/hcl/bench/run_bench.sh` reproduces the README on this machine (W1 1.19x, W2 2.74x,
W3 1.23x; SHA-256 identical across implementations and rounds). Review:

* **Equal work, mostly yes.** W1 both parse the same 140 KB generated config fully into an AST
  and walk it; the Go walker additionally sorts each body's attribute map by offset (measured:
  ~3% of Go's W1 time, not material). W2 both re-parse per iteration, evaluate every attribute
  and serialize sorted JSON; results are hashed, so no dead-code elimination. W3 both format the
  same bytes. Process-level timing, `--warmup 1 --rounds 5`, interleaved, release builds on both
  sides: fair.
* **Not equal semantics.** Go evaluates with cty's arbitrary-precision numbers, type unification
  and unknown/mark tracking; Pion evaluates `Double` without unification (P1-4, P2-6/17). W2's
  inputs avoid every construct where that changes output, so its 2.75x measures a cheaper,
  non-equivalent evaluator.
* **W3 input is unrepresentative and hides the formatter's divergences.** It is ~400 bytes,
  without a multi-line attribute value, blank-line runs, trailing comments, CRLF or non-ASCII.
  The very next realistic resource (`fmt/tf_resource`: a `tags = {…}` map) makes the two
  formatters' outputs differ (P1-8), i.e. the README claims ("verified byte-for-byte identical
  to `hclwrite.Format`", "aligned with `hclwrite.Format` / `terraform fmt`") hold only for that
  input. With the strict SHA rule of `AGENTS.md` §1.3 a W3 on a real Terraform file would be
  invalid today.
* README omissions: no mention that `max_output_bytes` does not cover JSON serialization
  (P0-3) or that wasm32 traps on large numbers (P0-1); W1–W3 are small-input, process-level
  numbers (W2 per-op ~43 µs), not a throughput claim for large configs beyond W1.

## What held up (no finding)

Parser/evaluator/formatter/JSON nesting under default limits (`probe/nest/*`, `probe/fmt/*`,
`probe/unclosed/*`, `probe/long/identifier`, `probe/amp/for_product`, `probe/amp/range`,
`probe/amp/template_200MB` → clean `LimitExceeded`/`SyntaxError` in all modes); escapes
`\n \r \t \" \\ \uXXXX \UXXXXXXXX`, surrogate pairs and invalid escapes; `$${`/`%%{`; keywords as
attribute names and object keys; labels; duplicate attributes; `%{if}`/`%{for}` incl. most strip
placements on one line; heredoc indentation with tabs/mixed/interpolation; precedence and
associativity; `&&`/`||`/`?:` short-circuit (hcl/v2 2.23 short-circuits too); null semantics;
attr vs full splat on null/scalar/empty/nested; `for` filtering, grouping, duplicate keys,
scoping; `try`/`can`; formatter idempotency on every input (`fmt2/*`).
