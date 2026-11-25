# `graphql`

Pure Pion **GraphQL (October 2021)** lexer, 100% iterative AST parser (Executable Query + Schema SDL + Extensions), canonical formatter (`print_document`), single-pass streaming minifier (`minify_query`), and O(N) static validation engine (`validate_executable`).

- **Zero external / C / `World` dependencies** — pure Pion, `Send`-safe immutable AST types, verified across **Native** and **`wasm32`** (`debug` & `release`, 4/4 `wasm_smoke` modes exit 0).
- **GraphQL October 2021 Lexer** — 256-byte ASCII classification LUT, zero-copy fast paths for `Name`, `Int`, `Float`, and unescaped `StringValue`; Unicode BOM (`U+FEFF`), whitespace, `\n`/`\r\n`/`\r`, commas `,`, and `#` comments treated as ignored tokens; `U+007F` (DEL) accepted per October 2021 `SourceCharacter` while C0 controls other than `\t`/`\n`/`\r` are rejected; strict number lookahead rules (rejects leading zeros `01`/`-01`, `.5`, `1.`, `1e`, `123abc`, `1.2.3`); full string escape decoding (`\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`, `\uXXXX` with UTF-16 surrogate-pair combining, and variable-length `\u{...}` capped at 8 hex digits with lone-surrogate rejection); exact §2.9.4 `BlockStringValue` indentation stripping and `\"""` unescaping; 1-based Unicode scalar error columns; strict RFC 3629 UTF-8 byte validation (`tokenize_bytes` / `parse_bytes`).
- **100% iterative explicit-stack AST Parser, Printer & Validator** — explicit heap stacks for `SelectionSet`, `Value` (nested lists/objects), and `TypeRef` (`[[T!]!]!`); streaming single-pass parsing directly from `Lexer` without materializing an intermediate `Array[Token]`; full Executable + Type System SDL (`schema`, `scalar`, `type`, `interface` with `implements`, `union`, `enum`, `input`, `directive ... repeatable on ...`, `extend ...`, descriptions).
- **Formatter & Streaming Minifier** — `print_document` implements `graphql-js`'s `printBlockString` rules (preserving single-line leading whitespace, trailing quotes/backslashes, and all field/directive argument descriptions) so `parse(print(parse(x))) == parse(x)` and `print(parse(print(x))) == print(x)` are 100% lossless and idempotent; `minify_query` streams directly over the lexer and minimizes block strings via `printBlockString(..., { minimize: true })`, matching `graphql-js` `stripIgnoredCharacters` byte-for-byte.
- **Static Validator & Day-1 DoS Protection** — `ParseOptions { max_depth, max_tokens, max_nodes }` defaults to `max_depth = 128`, `max_tokens = 2_000_000`, `max_nodes = 2_000_000` (sufficient for multi-MB production Schema SDL without manual overrides). Because Pion's runtime reference-count teardown of recursive AST structures uses native/Wasm stack frames, `parse_with_options` enforces a hard safety ceiling of `max_depth <= 500` (returning `ErrorKind::LimitExceeded` above 500) so neither Native nor Wasm32 debug/release can SIGSEGV or stack-overflow trap even when callers raise `max_depth`. `validate_executable` implements all 13 schema-free `graphql-js` executable rules (`ExecutableDefinitions`, `UniqueOperationNames`, `LoneAnonymousOperation`, `UniqueFragmentNames`, `KnownFragmentNames`, `NoUnusedFragments`, `NoFragmentCycles`, `UniqueVariableNames`, `NoUndefinedVariables`, `NoUnusedVariables`, `UniqueArgumentNames`, `UniqueInputFieldNames`, `UniqueDirectivesPerLocation`), walks duplicate fragment bodies, and enforces configurable `ValidationOptions { max_depth, max_aliases, max_fields }` in O(V + E).

## API

```pion
// Errors & limits
pub enum ErrorKind { InvalidSyntax, InvalidUtf8, UnexpectedToken, UnexpectedEof, LimitExceeded, Unimplemented }
pub struct GraphqlError { pub kind : ErrorKind, pub line : Int, pub col : Int, pub offset : Int, pub message : String }
pub val struct ParseOptions { pub max_depth : Int, pub max_tokens : Int, pub max_nodes : Int }
pub val struct ValidationOptions { pub max_depth : Int, pub max_aliases : Int, pub max_fields : Int }

// Lexer
pub fn tokenize(src : String) -> Result[Array[Token], GraphqlError]
pub fn tokenize_with_options(src : String, opts : ParseOptions) -> Result[Array[Token], GraphqlError]
pub fn tokenize_bytes(src : Bytes) -> Result[Array[Token], GraphqlError]
pub fn tokenize_bytes_with_options(src : Bytes, opts : ParseOptions) -> Result[Array[Token], GraphqlError]
pub fn count_tokens(src : String) -> Result[Int, GraphqlError]

// Parser (Executable + Schema SDL)
pub fn parse(src : String) -> Result[Document, GraphqlError]
pub fn parse_with_options(src : String, opts : ParseOptions) -> Result[Document, GraphqlError]
pub fn parse_bytes(src : Bytes) -> Result[Document, GraphqlError]
pub fn parse_bytes_with_options(src : Bytes, opts : ParseOptions) -> Result[Document, GraphqlError]
pub fn parse_value(src : String) -> Result[Value, GraphqlError]
pub fn parse_type(src : String) -> Result[TypeRef, GraphqlError]

// Formatter & Minifier
pub fn print_document(doc : Document) -> String
pub fn minify_query(src : String) -> Result[String, GraphqlError]
pub fn minify_query_with_options(src : String, opts : ParseOptions) -> Result[String, GraphqlError]

// Core Static Validator (all 13 schema-free executable rules + DoS budgets)
pub fn validate_executable(doc : Document) -> Array[ValidationError]
pub fn validate_executable_with_options(doc : Document, opts : ValidationOptions) -> Array[ValidationError]
```

## Example

```pion
import "graphql"

let query = "query GetUser($id: ID!) { user(id: $id) { id ...UserFields } } fragment UserFields on User { name }"
match graphql::parse(query) {
  Ok(doc) => {
    let errs = graphql::validate_executable(doc)
    let formatted = graphql::print_document(doc)
    let minified = graphql::minify_query(query)
    let _ = (errs, formatted, minified)
  }
  Err(e) => {
    let _ = e.to_string()
  }
}
```

## Verification

```sh
pionc fmt --check packages/graphql
pionc check --json packages/graphql
pionc test --json packages/graphql
pionc test --json -p graphql_audit packages/graphql/audit
pionc run packages/graphql/wasm_smoke
pionc run --release packages/graphql/wasm_smoke
pionc run --target wasm32 packages/graphql/wasm_smoke
pionc run --target wasm32 --release packages/graphql/wasm_smoke
```

## Head-to-Head Benchmarks

Measured on `Linux x86_64` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification across all implementations and rounds):

- **Pion**: `packages/graphql` (`pionc build --release`, default `ParseOptions`)
- **Rust**: `apollo-parser =0.8.4` (`cargo build --release`, baseline `1.00x`)
- **Node.js**: `graphql@16.10.0` (`graphql-js`, `parse({ noLocation: true })`, `stripIgnoredCharacters`, `print`)

Reproduce with:

```sh
sh packages/graphql/bench/run_bench.sh
```

### Workload 1: Large Schema SDL Parse (`3 × 2,040,452 B = 6.12 MB`)

GitHub/Linear-style Schema SDL (`1,400` domain modules: object types, interfaces, `implements`, connections, inputs, unions, directives, extensions, block-string descriptions), parsed with Pion's default `ParseOptions`.
SHA-256 verified identical: `9cf6ac8cb35d6b5a2847afd15996381ee68691f265eee7c2e3dc3401a35483db`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_apollo`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **79.636** | 76.594 | 107.410 | **76.87** | **17.19 MiB** | **2.74x** |
| `rust_apollo` (`apollo-parser 0.8.4`) | 218.189 | 189.312 | 249.891 | 28.06 | 22.35 MiB | 1.00x (baseline) |
| `node_graphqljs` (`graphql 16.10.0`) | 429.212 | 314.333 | 487.927 | 14.26 | 344.79 MiB | 0.51x |

### Workload 2: Complex Executable Query Parse + Static Validation (`20,000` queries)

200 distinct executable queries (variables, aliases, directives, inline fragments, fragment spreads, block strings, nested selections, plus deterministic invalid queries) × 100 iterations, each parsed and statically validated.
SHA-256 verified identical: `ca78a77d644df2524fee093c942d54d21c1bc4c6a44e1b05955b1867f111c59b`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_apollo`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **323.920** | 182.617 | 421.836 | **16,196.01** | 2.68 MiB | **2.51x** |
| `rust_apollo` (`apollo-parser 0.8.4`) | 812.970 | 584.763 | 1,015.885 | 40,648.52 | **2.43 MiB** | 1.00x (baseline) |
| `node_graphqljs` (`graphql 16.10.0`) | 619.146 | 329.696 | 771.452 | 30,957.31 | 76.54 MiB | 1.31x |

### Workload 3: Query Minify + Re-parse + Print Round-trip (`10,000` queries / `7.25 MB`)

Minify (`minify_query` / `stripIgnoredCharacters` / lexer minify with block-string minimization), re-parse minified GraphQL, print/serialize, and re-minify the printed output so SHA-256 covers both minified text and `print_document` semantic output (including multi-line and leading-whitespace block strings) across 200 queries × 50 iterations.
SHA-256 verified identical: `9f372181ffe8ee0370889ed579980875ba0659e7998ff79667b3ef6c5c275c22`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_apollo`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **281.650** | 230.136 | 311.966 | **25.74** | **28,164.98** | 2.61 MiB | **1.54x** |
| `rust_apollo` (`apollo-parser 0.8.4`) | 434.745 | 382.037 | 567.588 | 16.67 | 43,474.50 | **2.41 MiB** | 1.00x (baseline) |
| `node_graphqljs` (`graphql 16.10.0`) | 2,614.550 | 2,179.822 | 3,241.288 | 2.77 | 261,455.02 | 88.84 MiB | 0.17x |

### Honest Assessment (Strengths, Caveats & Trade-offs)
- **Where Pion Native leads**: Pion Native outperforms both Rust `apollo-parser` and Node `graphql-js` across all 3 workloads (**2.74x** vs Rust / **5.39x** vs Node on large SDL parse with **17.19 MiB** Peak RSS — lower than Rust's `22.35 MiB`; **2.51x** vs Rust / **1.91x** vs Node on 20k query parse + static validation; **1.54x** vs Rust / **9.28x** vs Node on minify+parse+print round-trip) while using **20x–35x less Peak RSS** than Node.
- **Methodology caveats**:
  - `apollo-parser` constructs a lossless Rowan CST (retaining every whitespace/comment trivia node for IDE error recovery) rather than a compact AST, and its W3 "print" step is `doc.syntax().to_string()` (lossless CST text, not a pretty-printer); conversely, W2's Rust validator allocates `name.text().to_string()` per identifier.
  - All `node` timings include process start-up and V8 JIT warm-up per round.
- **Depth hard cap & validation scope**: `parse_with_options` caps effective `max_depth` at `500` to prevent recursive runtime RC teardown stack overflow in Native/Wasm32. `validate_executable` covers all 13 schema-free executable rules plus depth/alias/field security budgets; schema-aware type-checking rules (e.g. `FieldsOnCorrectType`, `VariablesInAllowedPosition`) are not yet included in `v0.1.0`.
