# `jsonpath` (`v0.1.0`)

Pure Pion **RFC 9535 JSONPath + RFC 6901 JSON Pointer + RFC 6902 JSON Patch + RFC 7396 JSON Merge Patch** engine — zero C dependencies, zero `World` dependencies, stack-safe iterative evaluation, and verified on both **Native** and **WebAssembly (`wasm32`)**.

Reuses this monorepo's [`regex`](../regex) (linear-time LazyDFA/PikeVM) to back RFC 9485 I-Regexp (`match()` / `search()`).

## Features

- **Exact JSON DOM & Codec (`src/value.pion`)**:
  - `JsonValue` with exact `Int(Int64)` (lossless beyond `2^53`), lossless arbitrary-precision `BigInt(String)` for integers outside `Int64`, and `Float(Double)`; iterative RFC 8259 parser with `max_depth` protection and last-wins object key deduplication; iterative canonical serializer (`to_json_string`); and O(n) mathematical structural equality (`json_value_eq`: `1 == 1.0`, `0 == -0.0`, exact `Int`/`BigInt`/`Double` comparison, order-independent objects).
- **Full RFC 9535 JSONPath (`src/lexer.pion`, `src/parser.pion`, `src/eval.pion`, `src/iregexp.pion`)**:
  - Pre-compiled `JsonPath::parse(query)` AST with strict ABNF validation (exact RFC 9535 whitespace, single/double-quoted escapes with `\uXXXX` surrogate pair decoding, I-JSON safe integer bounds `[-(2^53)+1, (2^53)-1]`, `-0` and leading-zero rejection in index/slice selectors).
  - **Static Type Checking (RFC 9535 §2.4)**: strictly enforces `ValueType`, `LogicalType`, and `NodesType` for all built-in functions, comparisons, and test expressions at parse time.
  - **All Selectors & Segments**: Name, Wildcard `*`, Index (positive & negative), Slice `start:end:step` (negative steps, `step == 0` empty set, bounds clamping), Filter `?expr` (`&&`, `||`, `!`, parentheses, `==`/`!=`/`<`/`<=`/`>`/`>=`, `Nothing` semantics), Child `[...]` / `.`, and stack-safe iterative pre-order Descendant `..`.
  - **All 5 Built-in Function Extensions**: `length()` (UTF-8 Unicode scalar value count), `count()`, `value()`, `match()` (implicitly anchored RFC 9485 I-Regexp), and `search()` (unanchored RFC 9485 I-Regexp, `.` excludes `\r`/`\n`, `^`/`$` anchored per RFC 9535 CTS, `\p{...}` Unicode General Categories, compile-time precompilation for constant patterns).
  - **Normalized Paths (RFC 9535 §2.7)**: `query_with_paths` uses a shared parent-pointer path chain during traversal (O(depth) memory) and materializes canonical `$['k'][0]` paths with spec-exact escaping and a 64 MiB materialized byte budget.
- **RFC 6901 JSON Pointer (`src/pointer.pion`)**:
  - `JsonPointer::parse`, `to_string`, `escape_token`, `unescape_token` (`~1` / `~0` order-safe), `resolve`, and iterative stack-safe Copy-on-Write `resolve_mut`, with strict array index validation (rejects leading zeros and `-` on resolve).
- **RFC 6902 JSON Patch & RFC 7396 Merge Patch (`src/patch.pion`)**:
  - `parse_patch`, `patch_from_value`, `patch_to_value`, atomic O(N) clone-on-touch `apply_patch` / `apply_patch_with_limits` (`add`, `remove`, `replace`, `move` with self-prefix rejection, `copy` with logical node budget against exponential amplification, `test`), and O(n) minimal `diff_patch(before, after)` round-trip generator.
  - 100% iterative `merge_patch` (no artificial depth truncation) and `merge_patch_with_limits` compliant with all 15 RFC 7396 Appendix A test cases.
- **Security & DoS Limits (`JsonPathLimits`)**:
  - Configurable `max_depth`, `max_nodes_visited`, `max_results`, and `max_patch_ops` preventing stack overflow, `copy` amplification bombs, quadratic wide-object CPU DoS, and exponential `$..*..*` query amplification on Native and Wasm32.

## Quick Start

```pion
import "jsonpath"

pub fn run_example() -> Result[Array[jsonpath::NodeMatch], jsonpath::JsonPathError] {
  let doc = match jsonpath::parse_json("{\"items\":[{\"name\":\"api-gw\",\"replicas\":3}]}") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let q = match jsonpath::JsonPath::parse("$.items[?@.replicas >= 2 && match(@.name, \"[a-z]+-[a-z]+\")].name") {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  q.query_with_paths(doc)
}
```

## Verification

```sh
sh scripts/verify.sh packages/jsonpath

# 4-mode Native + Wasm32 smoke (all exit 0, identical stdout SHA-256)
pionc run packages/jsonpath/wasm_smoke
pionc run --release packages/jsonpath/wasm_smoke
pionc run --target wasm32 packages/jsonpath/wasm_smoke
pionc run --target wasm32 --release packages/jsonpath/wasm_smoke
```

- **Unit & Compliance Tests**: `14 / 14` `jsonpath` test suites (`37 / 37` including `regex` dependency tests) covering RFC 9535 CTS core matrix, static type checking, I-Regexp, RFC 6901, RFC 6902 atomic + `diff_patch`, RFC 7396 Appendix A, Int64/BigInt exactness, and DoS limits; official RFC 9535 CTS **715 / 715 (100.0%)** and red-team audit `sh packages/jsonpath/audit/run_audit.sh` **301 PASS / 0 FAIL**.
- **4-Mode `wasm_smoke`**: Native debug, Native release, Wasm32 debug, and Wasm32 release all exit `0` with identical stdout (`jsonpath_wasm_smoke: OK score=5`, SHA-256: `cee830958081bc7540cf16697b96594e2e35f7e789611df3dad0fb225f51aba9`).

## Head-to-Head Benchmarks

Measured on `Darwin arm64` using `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, mandatory byte-for-byte stdout SHA-256 verification).

- **Pion**: `packages/jsonpath` compiled with `pionc build --release`
- **Rust**: `serde_json_path = 0.7.2` + `json-patch = 4.2.0` + `serde_json = 1.0.154` (`Cargo.lock` locked, `cargo build --locked --release`)

Reproduce via:
```sh
sh packages/jsonpath/bench/run_bench.sh
```

| Workload | Ops | Pion Median (ms) | Rust Median (ms) | Pion ns/op | Rust ns/op | Pion RSS | Rust RSS | Pion vs Rust | Verified SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| **W1**: Complex K8s/OpenAPI JSONPath compile + query + Normalized Path | 120 | **47.282** | 185.938 | **394,018** | 1,549,480 | **4.67 MiB** | 5.95 MiB | **3.93x** | `c7c81662...` |
| **W2**: Precompiled JSONPath hot-path throughput | 50,000 | 67.176 | **37.848** | 1,344 | **757** | 2.62 MiB | 2.59 MiB | 0.56x | `7cca3a68...` |
| **W3**: RFC 6902 `diff_patch` + `apply_patch` + RFC 7396 `merge_patch` roundtrip | 5,000 | 32.687 | **24.468** | 6,537 | **4,894** | 3.03 MiB | 2.92 MiB | 0.75x | `3a784896...` |

Notes on benchmark results:
- **W1 (3.93x overall vs Rust — attribution breakdown)**: `serde_json_path 0.7.2` calls `regex::Regex::new` inside `match()` / `search()` **for every evaluated node** (rather than once per parse), whereas Pion precompiles constant I-Regexp patterns at query parse time. In the isolated query-class split (`audit/REPORT.md` §7), Pion is **3.25–6.08x faster** on the 2 queries using `match()`/`search()` and **1.12–1.16x faster** on the 4 non-regex queries.
- **W2 (0.56x vs Rust) & W3 (0.75x vs Rust)**: On pure precompiled hot-path queries and small-document patch roundtrips, Rust's zero-copy borrowed `&Value` slices (`serde_json_path`) and in-place `&mut Value` mutation (`json-patch`) remain ahead, while Pion achieves comparable peak RSS (~2.6–3.0 MiB), O(N) linear scaling on 100k-key wide objects, and 100% byte-for-byte identical outputs.

## Formal Verification (Lean 4)

The RFC 9535 lexical/I-JSON/slice-bound kernels and RFC 6901 JSON Pointer escape kernels (`JsonPathLimits`, `is_rfc9535_ws`, `is_name_first`, `is_name_char`, `rfc9535_ijson_step_overflow`, `norm_name_byte_len`, `rfc9535_normalize_index`, `rfc9535_default_slice_start`, `rfc9535_default_slice_end`, `rfc9535_clamp_pos_slice`, `rfc9535_clamp_neg_slice`, `pointer_needs_escape`, `pointer_unescape_tilde`) are annotated with `#verify` and formally verified in Lean 4 under `proofs/` (24 `0-sorry` theorems, standard axioms only, 44-case native-vs-Lean differential cross-check):

```bash
bash packages/jsonpath/proofs/run_proofs.sh
```
