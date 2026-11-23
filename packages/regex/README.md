# `regex` — Pure Pion Linear-Time Regular Expression Engine

Pure Pion, zero-C-dependency, zero-`World`, Native + `wasm32` compatible linear-time regular expression engine aligned with Rust [`BurntSushi/regex`](https://github.com/rust-lang/regex) (`regex =1.11.1` / `regex-automata`) and Go `regexp` (RE2).

**Linear-time matching guarantee**: all matching runs via finite automata (Hybrid Lazy DFA, One-Pass DFA, and Thompson/Cox PikeVM). Exponential backtracking (ReDoS) is structurally impossible; non-regular features (backreferences `\1`, look-around `(?=...)`/`(?<=...)`) are explicitly rejected at compile time with `RegexErrorKind::UnsupportedFeature`. Character class normalization runs in worst-case `O(N log N)` time, and nesting/size limits (`nest_limit`, `size_limit`) guard compile-time resource usage.

## Features

- **Rust `regex =1.11.1` / RE2-aligned syntax & semantics**:
  - Literals & escapes (`\n`, `\r`, `\t`, `\f`, `\v`, `\a`, `\xHH`, `\uHHHH`, `\u{...}`, `\UHHHHHHHH`, metacharacter escapes; invalid ASCII alphanumeric escapes such as `\Q` are rejected) and `escape()`.
  - Character classes (`[...]`, `[^...]`, `[]a]`, `[-a]`, `[a-]`), nested classes (`[[a]]`, `[^[a]]`), set operations (`&&` intersection, `--` difference, `~~` symmetric difference), POSIX classes (`[[:digit:]]`, `[[:xdigit:]]`, `[[:alpha:]]`, `[[:^digit:]]`, etc.), and shorthand classes (`\d`/`\D`, `\w`/`\W`, `\s`/`\S`).
  - Quantifiers (`*`, `+`, `?`, `{m}`, `{m,}`, `{m,n}`) with greedy/lazy (`*?`, `+?`, `??`, `{m,n}?`) semantics, `(?U)` greed swapping, leftmost-first nullable loop handling, and repetition of empty/assertion-only expressions (`^*`, `\b{2}`, `(?:)*`).
  - Groups: capturing `(...)`, non-capturing `(?:...)`, named `(?P<name>...)` / `(?<name>...)`, inline & scoped flags `(?i)` / `(?m)` / `(?s)` / `(?U)` / `(?u)` / `(?x)` and `(?-...)`.
  - Anchors: `^`, `$`, `\A`, `\z`, `\b`, `\B` (ASCII & Unicode word boundaries, multiline `(?m)`), strictly enforcing UTF-8 codepoint boundaries on empty matches.
  - **Unicode 16.0.0 support** (matching `regex-syntax 0.8.12`): compact prefix-shared `Sparse` UTF-8 byte-automaton tries, full UCD 16.0.0 General Categories (`L`/`Lu`/`Ll`/`Lt`/`Lm`/`Lo`/`LC`, `M`/`Mn`/`Mc`/`Me`, `N`/`Nd`/`Nl`/`No`, `P`/`Pc`..`Po`, `S`/`Sm`..`So`, `Z`/`Zs`..`Zp`, `C`/`Cc`..`Cn`), major Scripts (`Latin`, `Greek`, `Cyrillic`, `Han`, `Hiragana`, `Katakana`, `Arabic`, `Hebrew`, `Hangul`, `Common`, `Inherited`, `Devanagari`, `Thai`, `ASCII`), full UCD 16.0.0 Simple Case Folding (`(?i)`), and compile-time rejection of `(?-u)` patterns that can match invalid UTF-8 bytes on `String` haystacks.
  - Strict compile-time limits: `nest_limit` (covering both `(` and `[`, default `250`, returning `NestLimitExceeded`) and `size_limit` (`CompiledTooBig`).
- **Multi-tier linear-time execution architecture**:
  - **Prefilter**: exact-literal fast path, required literal-prefix & leading-look-prefix byte scan (`\bword\b`), and 256-entry `FirstBytes` skip table.
  - **ByteClassSet**: `O(N + 256)` byte equivalence-class compression (`stride <= 256`).
  - **Hybrid Lazy DFA**: on-demand memory-bounded (~16 MiB cap) forward & reverse Lazy DFA with priority-ordered break-on-match (including conditional `(?m)$` and ASCII `\b`/`\B`, cleanly falling back to PikeVM on non-ASCII bytes under Unicode `\b`/`\B`), plus hybrid `RegexSet` splitting non-`\b` and `\b` rules so non-`\b` rules always stay on the single-pass DFA fast path.
  - **One-Pass DFA**: compiles unambiguous capture-group NFAs into a single-pass table-driven DFA with 64-bit capture slot masks (zero allocations per match).
  - **Thompson / Cox PikeVM**: flat parallel-array `O(N × M)` fallback with reusable generation-stamped `PikeVmCache` (zero per-call state-array allocations) and compact `Sparse` UTF-8 trie states.
- **Rich API**: `is_match`, `is_match_at`, `find`, `find_at`, `find_span_at`, `find_spans_into`, `find_iter`, `captures`, `captures_at`, `captures_slots_at`, `captures_iter`, `replace`, `replace_all`, `replacen` (`$0`, `$1`, `${1}`, `$name`, `${name}`, `${}`, `$$`), `split`, `splitn` (all following Rust/Go abutting empty-match skipping), and multi-pattern `RegexSet`.
- **Dual target**: Native + `wasm32` (`packages/regex/wasm_smoke` and `packages/regex/audit/release_probe` verified across all 4 build modes: Native/Wasm32 × debug/`--release`, 100% byte-identical transcripts across 28,783 differential cases).

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
pionc test --json -p regex_audit packages/regex/audit
pionc run packages/regex/wasm_smoke
pionc run --release packages/regex/wasm_smoke
pionc run --target wasm32 packages/regex/wasm_smoke
pionc run --release --target wasm32 packages/regex/wasm_smoke
sh packages/regex/audit/run_audit.sh
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
| `pion` | 43.756 | 41.373 | 92.132 | 614.61 | 7.42 MiB | 0.43x (**16.2× vs Go**) |
| `rust_regex` | 18.969 | 17.993 | 20.177 | 1417.70 | 5.61 MiB | 1.00x (baseline) |
| `go_regexp` | 709.004 | 688.301 | 760.101 | 37.93 | 16.52 MiB | 0.03x |

_SHA-256 verified identical across all implementations and rounds: `16f877f2f550dcee8b3b644bec3df2cd1c489cdcf2617060714905b6ffcb24ab`._

### 2. Structured Log Capture Extraction (`captures_iter`, 20,000 log lines × 6 groups × 5 iters, 13.45 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_regex`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 113.792 | 109.889 | 115.274 | 118.17 | 7.42 MiB | 0.50x (**3.4× vs Go**) |
| `rust_regex` | 56.727 | 55.498 | 57.115 | 237.04 | 6.38 MiB | 1.00x (baseline) |
| `go_regexp` | 383.411 | 379.410 | 391.140 | 35.07 | 17.66 MiB | 0.15x |

_SHA-256 verified identical across all implementations and rounds: `8c769e6c2061bea100886a29e886c793b6abcc3a50e8190cad21a812c03403da`._

### 3. `RegexSet` Multi-Rule Parallel Matching (20,000 log lines × 16 rules × 5 iters = 100,000 ops, 13.45 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_regex`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 55.119 | 54.412 | 58.088 | 243.95 | 551.19 | 9.31 MiB | 0.64x (**2.0× vs Go**) |
| `rust_regex` | 35.282 | 34.192 | 36.363 | 381.11 | 352.82 | 6.55 MiB | 1.00x (baseline) |
| `go_regexp` | 111.581 | 110.640 | 116.796 | 120.51 | 1115.81 | 11.30 MiB | 0.32x |

_SHA-256 verified identical across all implementations and rounds: `a7e10eb653fdc30d7425bdfbe7d3d939ce4c6640f75fda1b09bc3b8a3446d48d`._

### 4. ReDoS Linear-Time Verification (`a?^40 a^40` + 4,000-byte pathological inputs × 50 iters = 250 ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_regex`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 11.109 | 9.629 | 11.322 | 44436.00 | 2.73 MiB | 0.88x (**2.3× vs Go**) |
| `rust_regex` | 9.788 | 8.958 | 15.514 | 39153.33 | 3.28 MiB | 1.00x (baseline) |
| `go_regexp` | 26.023 | 24.664 | 27.858 | 104090.00 | 5.50 MiB | 0.38x |

_SHA-256 verified identical across all implementations and rounds: `9f98f5bc3836fb96f47a290a7ceca716b26d89b668b1d60d532d91301c7a0e8d`._

## Adversarial & Stress Benchmarks (`audit/stress/run_stress.py`, Pion `--release` vs Rust `regex =1.11.1`)

All scenarios below verified 100% stdout byte-identical against Rust `regex =1.11.1` on `Darwin arm64`:

| Scenario | Pion (ms) | Pion RSS | Rust (ms) | Rust RSS | Pion / Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| Compile `[a × 40,000]` (duplicate class items) | 9.5 | 5.5 MiB | 8.8 | 16.2 MiB | 1.09× |
| Compile `[` × 200,000 (rejected by `nest_limit`) | 5.9 | 3.2 MiB | 44.1 | 102.6 MiB | **0.13×** |
| `\bword\b` on 2.8 MB mixed Unicode/ASCII × 3 | 21.1 | 7.0 MiB | 21.3 | 5.4 MiB | **0.99×** |
| `\b\w+\b` on 2.8 MB mixed Unicode/ASCII | 260.7 | 18.5 MiB | 65.9 | 6.2 MiB | 3.96× |
| Non-one-pass captures `(\w+?)(o\|ox)( ?)` on 2.8 MB | 162.6 | 7.0 MiB | 24.4 | 6.0 MiB | 6.67× |
| Captures with `\b`: `\b(\w+)@?(\d*)\b` on 2.8 MB | 916.5 | 7.0 MiB | 102.0 | 6.0 MiB | 8.99× |
| `RegexSet` 16 rules (incl. `\b`) × 40k lines | 387.3 | 9.8 MiB | 107.2 | 7.3 MiB | 3.61× |
| `RegexSet` 200 rules (incl. `\b`) × 40k lines | 3703.4 | 28.5 MiB | 2009.8 | 13.8 MiB | 1.84× |
| `RegexSet` 500 rules (incl. `\b`) × 40k lines | 16987.0 | 47.9 MiB | 6809.3 | 23.4 MiB | 2.49× |
| `(?s).*1[01]{12}$` (tail-anchored DFA thrash) | 114.6 | 12.0 MiB | 6.7 | 4.1 MiB | 17.10× |

## Honest Strengths, Limitations & Known Gaps

- **Strengths**:
  - Beats Go stdlib `regexp` across all 4 standard log/ReDoS workloads by **2.0×–16.2×** with lower peak RSS.
  - Matches Rust `regex 1.11.1` on `\bword\b` (**0.99×**), `[a × 40k]` compilation (**1.09×**, 3× lower RSS), ReDoS (**0.88×**), and `[` nesting bomb rejection (**0.13×**, 32× lower RSS).
  - Differential suite (51,805 cases vs Rust `regex =1.11.1`): 0 crashes/hangs; `sets` 3,022/3,022 exact; `curated` 8,742/8,783 exact (remaining 41 are `(a){0}` capture count); `fuzz` 19,986/20,000 exact (99.93%); `capfuzz` 19,892/20,000 exact (99.46%); Native vs Wasm32 debug/`--release` 100% byte-identical.
- **Lagging areas vs Rust `regex 1.11.1`**:
  - **No SIMD prefilters**: On literal-heavy `find_iter` (0.43×) and `captures_iter` (0.50×), Rust uses NEON/AVX2 `memchr` and Teddy multi-literal prefilters, while Pion uses scalar scanning.
  - **No bounded backtracker**: Ambiguous non-one-pass captures (`(\w+?)(o|ox)( ?)`, 6.67×) and captures with Unicode `\b` (`\b(\w+)@?(\d*)\b`, 8.99×) use PikeVM rather than Rust's `BoundedBacktracker` on short match spans.
  - **No reverse-suffix optimization**: End-anchored patterns like `(?s).*1[01]{12}$` run forward Lazy DFA without reverse-suffix scanning (~17× slower than Rust).
  - **Known semantic / limit edges**:
    - `(a){0}` reports 2 capture groups (matching RE2) whereas Rust `regex 1.11.1` drops groups inside `{0}` and reports 1.
    - ~0.24% of random fuzz/capfuzz patterns with deeply nested nullable capture loops still show sub-match group tie-breaking differences vs Rust.
    - The parser is recursive-descent: default `nest_limit = 250` is safe on both Native and Wasm32, but raising `nest_limit` above ~400 on Wasm32 can overflow the Wasm call stack.

## Formal Verification (Lean 4)

**9** machine-checked, `0-sorry` Lean 4 theorems (strict standard-axiom whitelist `[propext, Classical.choice, Quot.sound]`, verified via `pionc extract-lean` + Aeneas) cover `CharRange` and 8 production `#verify` kernels in `packages/regex/src/`:
- **Automata & Captures (`proofs/RegexProofs/AutomataAndCaptures.lean`, 2 theorems)**: One-Pass DFA 64-bit capture slot bitmask idempotence and `Captures` slot index memory-safety bounds (`2*idx+1 < slots_len`).
- **Character Ranges & Syntax (`proofs/RegexProofs/RangesAndSyntax.lean`, 7 theorems)**: `CharRange` lexicographic total order (antisymmetric, transitive, total), `char_range_intersect` exact point-membership semantics, UTF-8 continuation byte mask semantics, `hex_val` bounds `[-1, 15]`, and `(?x)` whitespace vs `escape()` metacharacter disjointness.
- **Differential Cross-Check**: `proofs/EvalDiff.lean` + native Pion value-comparing harness (`diff -u`, including `INT32_MIN`/`INT32_MAX` and out-of-precondition cases).

```sh
LEAN_NUM_THREADS=2 LEAN_MEM_LIMIT=8192 bash packages/regex/proofs/run_proofs.sh
```
