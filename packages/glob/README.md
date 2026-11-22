# `glob` — Pure Pion Glob, GlobSet & `.gitignore` Matcher

Pure Pion, zero-`World`, `Send`-safe high-performance glob, multi-pattern `GlobSet`, and `.gitignore` path matching library ported from Rust [`BurntSushi/globset`](https://github.com/BurntSushi/ripgrep/tree/master/crates/globset) and [`BurntSushi/ignore`](https://github.com/BurntSushi/ripgrep/blob/master/crates/ignore/src/gitignore.rs).

## Features

- **Full `BurntSushi/globset` syntax & options**:
  - `*`, `?`, recursive `**` (`**/foo`, `foo/**`, `a/**/b`, `**`), character classes `[a-z]` / `[!a-z]` / `[^a-z]`, all 12 ASCII POSIX classes (`[[:digit:]]`, `[[:alpha:]]`, `[[:space:]]`, etc.), backslash escapes (`\*`, `\?`, `\[`), nested brace alternations (`{*.rs,*.pion}`, `{a,{b,c}}`), and `escape()`.
  - Full `GlobOptions`: `case_insensitive`, `literal_separator`, `backslash_escape`, `empty_alternates`, `allow_unclosed_class`.
  - Strict compile-time `Result[T, GlobError]` errors for unclosed `[`, invalid ranges `[z-a]`, unclosed/unopened `{}`/`}`, nesting depth > 100, and dangling `\`.
- **Strategic `GlobSet` multi-pattern acceleration**:
  - Single-pass backward basename scan (`make_candidate`) computing both `last_slash` and `last_dot` in one pass.
  - Unified zero-allocation `ExtTable` (single FNV-1a hash & probe per path serving both pure `*.ext` and `RequiredExtension` multi-DFAs) + `StrTable` with `min_len`/`max_len`, 64-bit length bitmask, and stored hash prefilters for `BasenameLiteral` and `Literal`.
  - Flat pre-multiplied 128-entry-per-state ASCII `ByteTrie` for zero-pointer-chase `Prefix` and reversed `Suffix` matching.
  - Controlled brace & small character-class expansion (≤ 16 branches, e.g., `**/*.{js,jsx,mjs}`, `**/*.py[cod]`, `{target,dist,build}/**`) routing directly into O(1) tables.
  - Precompiled ASCII DFA with pre-multiplied state offsets (O(1) array load per byte, dead-state early exit) backed by a linear-time bit-parallel Thompson NFA (O(States × PathLen), zero backtracking, immune to ReDoS).
- **Complete `.gitignore` semantics**:
  - Comments (`#`), blank lines, UTF-8 BOM, CRLF/LF, trailing unescaped space trimming (`foo\   ` → `foo `), escaped leading `\#` / `\!`, bare `!` no-op, anchoring (`/foo`, `dir/file`), directory-only rules (`build/`), negation override (`!important.log`), root prefix stripping, and case-insensitive mode.
  - `matched(path, is_dir) -> MatchResult` (`None` / `Ignore(line)` / `Whitelist(line)`), `is_ignored(path, is_dir)`, `matched_path_or_any_parents`, top-down git parent-directory exclusion (`is_ignored_with_parents`), and multi-level nested `.gitignore` priority (`GitignoreStack`).
- **Dual target**: Native + `wasm32` (`packages/glob/wasm_smoke`).

## API Overview

```pion
// Single glob
let g = glob::compile("src/**/*.pion")?
g.is_match("src/pkg/main.pion") // true

// Multi-pattern GlobSet
let set = glob::compile_set(["*.rs", "src/**", "**/Cargo.toml"])?
set.is_match("src/lib.rs")      // true
set.matches("src/lib.rs")       // [0, 1]
set.matches_into("src/lib.rs", buf)

// .gitignore
let gi = glob::parse_gitignore("*.log\n!important.log\nbuild/\n")?
gi.is_ignored("app.log", false)              // true
gi.is_ignored("important.log", false)        // false
gi.is_ignored("build", true)                 // true
gi.is_ignored("build", false)                // false
gi.matched("important.log", false)           // MatchResult::Whitelist(2)
gi.is_ignored_with_parents("build/a.txt", false) // true
```

## Verification

```sh
pionc fmt --check packages/glob
pionc check --json packages/glob
pionc test --json packages/glob
pionc build --target wasm32 -o /tmp/glob_wasm_smoke.wasm packages/glob/wasm_smoke
```

## Head-to-Head Benchmark (`Darwin arm64`, `--warmup 1 --rounds 5`)

Run via:

```sh
sh packages/glob/bench/run_bench.sh
```

### Workload: 50,000 Monorepo Paths × 80 `GlobSet` Rules × 20 iters (1,000,000 `matches_into` calls)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_globset`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 123.861 | 119.863 | 136.977 | 230.83 | 123.86 | 8.23 MiB | **2.48x** |
| `rust_globset` | 307.405 | 290.437 | 438.753 | 93.01 | 307.40 | 5.86 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `2d9a2ef2bb80d5efd6926bf1bd5024be7f929dd793d5d4ce76a90316496fe91f`._
