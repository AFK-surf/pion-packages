# `graphql`

Pure Pion **GraphQL (October 2021)** lexer, 100% iterative AST parser (Executable Query + Schema SDL + Extensions), canonical formatter (`print_document`), single-pass streaming minifier (`minify_query`), and core O(N) static validation engine (`validate_executable`).

- **Zero external / C / `World` dependencies** — pure Pion, `Send`-safe immutable AST types, verified across **Native** and **`wasm32`** (`debug` & `release`, 4/4 `wasm_smoke` modes exit 0).
- **GraphQL October 2021 Lexer** — 256-byte ASCII classification LUT, zero-copy fast paths for `Name`, `Int`, `Float`, and unescaped `StringValue`; Unicode BOM (`U+FEFF`), whitespace, `\n`/`\r\n`/`\r`, commas `,`, and `#` comments treated as ignored tokens; strict number lookahead rules (rejects leading zeros `01`/`-01`, `.5`, `1.`, `1e`, `123abc`, `1.2.3`); full string escape decoding (`\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`, `\uXXXX` with UTF-16 surrogate-pair combining, and October 2021 variable-length `\u{...}` with lone-surrogate and control-character rejection); exact §2.9.4 `BlockStringValue` indentation stripping and `\"""` unescaping; strict RFC 3629 UTF-8 byte validation (`tokenize_bytes` / `parse_bytes`).
- **100% iterative explicit-stack AST Parser, Printer & Validator (0 recursion)** — explicit heap stacks for `SelectionSet`, `Value` (nested lists/objects), and `TypeRef` (`[[T!]!]!`); streaming single-pass parsing directly from `Lexer` without materializing an intermediate `Array[Token]`; full Executable + Type System SDL (`schema`, `scalar`, `type`, `interface` with `implements`, `union`, `enum`, `input`, `directive ... repeatable on ...`, `extend ...`, descriptions).
- **Formatter & Streaming Minifier** — `print_document` produces canonical, idempotent 2-space indented GraphQL; `minify_query` streams directly over the lexer, stripping comments/commas/redundant whitespace while matching `graphql-js`'s `stripIgnoredCharacters` token-separation rules byte-for-byte.
- **Core Static Validator & Day-1 DoS Protection** — `ParseOptions { max_depth, max_tokens, max_nodes }` (default `max_depth = 128`, `max_tokens = 500_000`, `max_nodes = 500_000`) cleanly rejects 50,000-level nested `{ a {`, `[ [ [`, `{ a: { a:`, and `[[[Int]]]` with `ErrorKind::LimitExceeded` (0 SIGSEGV, 0 Wasm32 trap); `validate_executable` checks unique operation names, lone anonymous operation, unique variable/argument/input-field/fragment names, known fragment names, O(V + E) 3-color DFS fragment cycle detection (allowing diamond DAGs), and configurable `ValidationOptions { max_depth, max_aliases, max_fields }`.

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

// Core Static Validator
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
pionc run packages/graphql/wasm_smoke
pionc run --release packages/graphql/wasm_smoke
pionc run --target wasm32 packages/graphql/wasm_smoke
pionc run --target wasm32 --release packages/graphql/wasm_smoke
```

## Head-to-Head Benchmarks

Measured on `Darwin arm64` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification across all implementations and rounds):

- **Pion**: `packages/graphql` (`pionc build --release`)
- **Rust**: `apollo-parser =0.8.4` (`cargo build --release`, baseline `1.00x`)
- **Node.js**: `graphql@16.10.0` (`graphql-js`, `parse({ noLocation: true })`, `stripIgnoredCharacters`, `print`)

Reproduce with:

```sh
sh packages/graphql/bench/run_bench.sh
```

### Workload 1: Large Schema SDL Parse (`3 × 2,040,452 B = 6.12 MB`)

GitHub/Linear-style Schema SDL (`1,400` domain modules: object types, interfaces, `implements`, connections, inputs, unions, directives, extensions, block-string descriptions).
SHA-256 verified identical: `9cf6ac8cb35d6b5a2847afd15996381ee68691f265eee7c2e3dc3401a35483db`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_apollo`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **86.331** | 83.739 | 87.093 | **70.91** | 31.19 MiB | **1.41x** |
| `rust_apollo` (`apollo-parser 0.8.4`) | 122.071 | 117.413 | 125.141 | 50.15 | **23.19 MiB** | 1.00x (baseline) |
| `node_graphqljs` (`graphql 16.10.0`) | 169.300 | 166.841 | 189.050 | 36.16 | 343.55 MiB | 0.72x |

### Workload 2: Complex Executable Query Parse + Static Validation (`20,000` queries)

200 distinct executable queries (variables, aliases, directives, inline fragments, fragment spreads, nested selections, plus deterministic invalid queries) × 100 iterations, each parsed and statically validated.
SHA-256 verified identical: `ca78a77d644df2524fee093c942d54d21c1bc4c6a44e1b05955b1867f111c59b`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_apollo`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 191.819 | 186.596 | 207.005 | 9,590.97 | **2.66 MiB** | **2.08x** |
| `rust_apollo` (`apollo-parser 0.8.4`) | 398.804 | 387.807 | 408.601 | 19,940.21 | 2.77 MiB | 1.00x (baseline) |
| `node_graphqljs` (`graphql 16.10.0`) | **170.645** | 163.916 | 174.836 | **8,532.27** | 66.16 MiB | **2.34x** |

### Workload 3: Query Minify + Re-parse + Print Round-trip (`10,000` queries / `6.57 MB`)

Minify (`minify_query` / `stripIgnoredCharacters` / lexer minify), re-parse minified GraphQL, and print/serialize across 200 queries × 50 iterations.
SHA-256 verified identical: `417b2a3714ec9d75806e235209cde9025ee6421d6f8880a332693daa98a0be21`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_apollo`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **156.638** | 148.356 | 175.074 | **41.96** | **15,663.81** | **2.75 MiB** | **1.59x** |
| `rust_apollo` (`apollo-parser 0.8.4`) | 249.016 | 244.984 | 278.984 | 26.39 | 24,901.56 | 2.81 MiB | 1.00x (baseline) |
| `node_graphqljs` (`graphql 16.10.0`) | 998.532 | 968.812 | 1042.801 | 6.58 | 99,853.23 | 78.12 MiB | 0.25x |

### Honest Assessment (Strengths & Trade-offs)
- **Where Pion leads**: Pion outperforms Rust `apollo-parser` across all 3 workloads (**1.41x** on large SDL parse, **2.08x** on 20k query parse + validation, **1.59x** on minify+parse+print round-trip), because Pion's streaming parser constructs a compact typed AST directly without building a lossless Rowan CST, and outperforms Node `graphql-js` by **1.96x** on large SDL and **6.37x** on minify+parse+print round-trip while using **11x–28x less Peak RSS**.
- **Where baselines lead**: On Workload 2 (20k small repeated queries), V8's warm JIT in `node_graphqljs` (`170.6 ms`) is **1.12x faster** than Pion (`191.8 ms`) at the cost of `66.16 MiB` vs `2.66 MiB` Peak RSS; on Workload 1 (large SDL), `rust_apollo` uses less Peak RSS (`23.19 MiB` vs Pion's `31.19 MiB`).
- **Scope note**: `validate_executable` covers document-level executable static rules (operation/variable/argument/input-field/fragment uniqueness, lone anonymous operation, known fragments, fragment cycles, and depth/alias/field security budgets); schema-aware type-checking rules (e.g. `FieldsOnCorrectType`, `VariablesInAllowedPosition`) are not yet included in `v0.1.0`.
