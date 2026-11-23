# `regex` — Pure Pion Linear-Time Regular Expression Engine

Pure Pion, zero-C-dependency, zero-`World`, Native + `wasm32` compatible linear-time regular expression engine inspired by Rust [`BurntSushi/regex`](https://github.com/rust-lang/regex) (`regex-automata`) and Go `regexp` (RE2).

**100% O(N) linear-time guarantee**: all matching runs via finite automata (Hybrid Lazy DFA, One-Pass DFA, and Thompson/Cox PikeVM). Exponential backtracking (ReDoS) is structurally impossible; non-regular features (backreferences `\1`, look-around `(?=...)`/`(?<=...)`) are explicitly rejected at compile time with `RegexErrorKind::UnsupportedFeature`.

## Features

- **Full Rust `regex` / RE2 syntax**:
  - Literals & escapes (`\n`, `\r`, `\t`, `\f`, `\v`, `\a`, `\xHH`, `\uHHHH`, `\u{...}`, `\UHHHHHHHH`, metacharacter escapes) and `escape()`.
  - Character classes (`[...]`, `[^...]`, `[]a]`, `[-a]`, `[a-]`), POSIX classes (`[[:digit:]]`, `[[:xdigit:]]`, `[[:alpha:]]`, `[[:^digit:]]`, etc.), shorthand classes (`\d`/`\D`, `\w`/`\W`, `\s`/`\S`).
  - Quantifiers (`*`, `+`, `?`, `{m}`, `{m,}`, `{m,n}`) with both greedy and lazy (`*?`, `+?`, `??`, `{m,n}?`) semantics, plus `(?U)` greed swapping.
  - Groups: capturing `(...)`, non-capturing `(?:...)`, named `(?P<name>...)` / `(?<name>...)`, inline & scoped flags `(?i)` / `(?m)` / `(?s)` / `(?U)` / `(?u)` / `(?x)` and `(?-...)`.
  - Anchors: `^`, `$`, `\A`, `\z`, `\b`, `\B` (ASCII & Unicode word boundaries, multiline `(?m)`).
  - Unicode support: UTF-8 byte-automaton range compiler (`utf8_sequences`), `\p{...}` / `\P{...}` General Categories (`L`, `Lu`, `Ll`, `Nd`, `N`, `P`, `S`, `Z`, `C`) and Scripts (`Han`, `Hiragana`, `Katakana`, `Greek`, `Cyrillic`, `Latin`, `Arabic`, `Hebrew`, `Hangul`, `ASCII`), `(?u)` vs `(?-u)` mode switching, and Unicode simple case folding.
  - Strict compile-time limits: `nest_limit` (`NestLimitExceeded`) and `size_limit` (`CompiledTooBig`).
- **Multi-tier linear-time execution architecture**:
  - **Prefilter**: exact-literal fast path, required literal-prefix byte scan (avoiding reverse DFA when prefix is anchored), and 256-entry `FirstBytes` skip table.
  - **ByteClassSet**: O(N + 256) byte equivalence-class compression (`stride <= 256`).
  - **Hybrid Lazy DFA**: on-demand memory-bounded (~16 MiB cap) forward & reverse Lazy DFA with priority-ordered break-on-match for exact Perl leftmost-first semantics, plus single-pass all-matches `RegexSet` DFA with zero-allocation generation-counter deduplication.
  - **One-Pass DFA**: compiles unambiguous capture-group NFAs into a single-pass table-driven DFA with 64-bit capture slot masks (zero allocations per match).
  - **Thompson / Cox PikeVM**: flat parallel-array O(N × M) fallback for ambiguous captures and `\b`/`\B` word-boundary assertions (only runs anchored on the tiny `[start, end]` span when preceded by Lazy DFA).
- **Rich API**: `is_match`, `is_match_at`, `find`, `find_at`, `find_span_at`, `find_spans_into`, `find_iter`, `captures`, `captures_at`, `captures_slots_at`, `captures_iter`, `replace`, `replace_all`, `replacen` (`$0`, `$1`, `${1}`, `$name`, `${name}`, `$$`), `split`, `splitn`, and multi-pattern `RegexSet`.
- **Dual target**: Native + `wasm32` (`packages/regex/wasm_smoke`, verified in both debug and `--release`).

## API Overview

```pion
// Single regex with named captures & replacement
let re = regex::compile("(?P<year>\\d{4})-(?P<month>\\d{2})-(?P<day>\\d{2})")?
re.is_match("date: 2026-11-23")                        // true
re.replace_all("2026-11-23", "$day/$month/$year")      // "23/11/2026"

// Multi-pattern RegexSet (single O(N) pass)
let set = regex::compile_set(["ERROR", "status=50[0-9]", "^2026-"])?
set.matches("2026-11-23 ERROR status=503")             // [0, 1, 2]
```

## Verification

```sh
sh scripts/verify.sh packages/regex
pionc run packages/regex/wasm_smoke
pionc run --release packages/regex/wasm_smoke
pionc run --target wasm32 packages/regex/wasm_smoke
pionc run --release --target wasm32 packages/regex/wasm_smoke
```

## Head-to-Head Benchmark (`Darwin arm64`, `--warmup 1 --rounds 5`)

3-way comparison against Rust `regex 1.11.1` (`--release`, baseline `1.00x`) and Go `go1.27.3` stdlib `regexp` (RE2), strictly interleaved via `scripts/bench_compare.py` with mandatory stdout SHA-256 byte-for-byte verification.

Run via:

```sh
sh packages/regex/bench/run_bench.sh
```

### 1. Mixed Log Multi-Pattern Search (`find_iter`, 20,000 log lines × 10 iters, 26.89 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_regex`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 37.458 | 35.508 | 38.318 | 717.94 | 6.91 MiB | 0.54x (**19.3× vs Go**) |
| `rust_regex` | 20.197 | 19.282 | 22.217 | 1331.49 | 5.62 MiB | 1.00x (baseline) |
| `go_regexp` | 721.398 | 706.010 | 775.186 | 37.28 | 16.36 MiB | 0.03x |

_SHA-256 verified identical across all implementations and rounds: `16f877f2f550dcee8b3b644bec3df2cd1c489cdcf2617060714905b6ffcb24ab`._

### 2. Structured Log Capture Extraction (`captures_iter`, 20,000 log lines × 6 groups × 5 iters, 13.45 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_regex`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 90.472 | 87.521 | 93.748 | 148.62 | 6.91 MiB | 0.60x (**4.2× vs Go**) |
| `rust_regex` | 54.709 | 52.930 | 57.680 | 245.78 | 6.36 MiB | 1.00x (baseline) |
| `go_regexp` | 380.429 | 368.061 | 384.337 | 35.35 | 17.56 MiB | 0.14x |

_SHA-256 verified identical across all implementations and rounds: `8c769e6c2061bea100886a29e886c793b6abcc3a50e8190cad21a812c03403da`._

### 3. `RegexSet` Multi-Rule Parallel Matching (20,000 log lines × 16 rules × 5 iters = 100,000 ops, 13.45 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_regex`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 38.483 | 36.010 | 39.455 | 349.41 | 384.83 | 8.73 MiB | 0.89x (**2.9× vs Go**) |
| `rust_regex` | 34.392 | 32.682 | 35.254 | 390.97 | 343.92 | 6.53 MiB | 1.00x (baseline) |
| `go_regexp` | 110.904 | 106.617 | 114.631 | 121.24 | 1109.04 | 11.19 MiB | 0.31x |

_SHA-256 verified identical across all implementations and rounds: `a7e10eb653fdc30d7425bdfbe7d3d939ce4c6640f75fda1b09bc3b8a3446d48d`._

### 4. ReDoS Linear-Time Verification (`a?^40 a^40` + 4,000-byte pathological inputs × 50 iters = 250 ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_regex`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 10.978 | 9.930 | 11.304 | 43911.00 | 2.12 MiB | 0.95x (**2.4× vs Go**) |
| `rust_regex` | 10.424 | 9.708 | 11.470 | 41696.50 | 3.27 MiB | 1.00x (baseline) |
| `go_regexp` | 26.186 | 24.870 | 27.023 | 104744.16 | 5.48 MiB | 0.40x |

_SHA-256 verified identical across all implementations and rounds: `9f98f5bc3836fb96f47a290a7ceca716b26d89b668b1d60d532d91301c7a0e8d`._

### Honest Strengths & Gaps

- **Strengths**: Beats Go stdlib `regexp` across all 4 workloads by **2.4×–19.3×** with **1.3×–2.5× lower peak RSS**; reaches **0.89×–0.95×** of Rust `regex 1.11.1` on `RegexSet` and ReDoS workloads (with lower peak RSS on ReDoS: 2.12 vs 3.27 MiB).
- **Lagging areas vs Rust `regex 1.11.1`**:
  - On `find_iter` (0.54×) and `captures_iter` (0.60×), Rust `regex` uses hand-tuned NEON/AVX2 SIMD Teddy / `memchr` multi-literal prefilters (`aho-corasick` + `memchr`), whereas Pion uses scalar byte scanning and scalar Lazy DFA / One-Pass DFA loops.
  - Peak RSS on `RegexSet` is 8.73 MiB vs 6.53 MiB due to Lazy DFA transition table sizing.
  - Non-one-pass ambiguous capture patterns and `\b`/`\B` word-boundary patterns fall back to `PikeVM`, which is O(N × M) linear-time but slower than DFA-accelerated paths.
