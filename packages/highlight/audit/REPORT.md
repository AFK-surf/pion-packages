# Red-team audit: `packages/highlight` vs prismjs / shiki

Target: `AFK-surf/pion-packages` `origin/main` `7a40e8f`, `packages/highlight` (untouched). Machine: Apple M5 Max (Darwin arm64), `pionc 0.1.0`, Node v24.22.2, reference engines **prismjs 1.30.0** and **shiki 3.23.0** (TextMate grammars, the same ones VS Code uses). Rust `syntect` / tree-sitter were not run: this machine has no `cargo`.

## Reproduce

```sh
export PATH="$HOME/.pion/bin:$PATH"
pionc test --json packages/highlight/audit         # 35 red-team tests, all 35 FAIL (the shipped 204 still pass)
sh packages/highlight/audit/run_audit.sh            # everything below (~4 min); AUDIT_QUICK=1 skips the 1 MiB sweep
```

`run_audit.sh` installs prismjs and shiki once into `~/.cache/hl-audit-ref` (override with `HL_AUDIT_REF`) and writes its build and inputs to a temp dir, so the worktree stays clean.

Layout: `redteam_test.pion` holds the failing tests. `probe/` is a CLI that dumps spans, incremental spans, HTML and timed loops. `bench/` holds the differential, incremental, UTF-8/XSS and benchmark drivers. `cases/` holds the tricky fixtures. The test file is at `audit/redteam_test.pion` rather than `audit/tests/`, because `pionc test` only finds `*_test.pion` at the package root and under `src/`. A file in `tests/` is silently never run.

## Verdict

| Attack surface | Result |
| --- | --- |
| 1. Token correctness | **Lost.** 35 reproduced defects: 12 P0, 14 P1, 9 P2. The shipped benchmark only checks that the spans rebuild the source, so it could not see any of them. |
| 2. HTML escaping / XSS / UTF-8 | **XSS: nothing found.** UTF-8: **1 P1.** `cpp` cuts a code point in half and `highlight_html` then emits invalid UTF-8. |
| 3. Performance / memory / pathological input | **Nothing found against us.** Linear on every adversarial input. 6–34× faster than prism end-to-end and far lower RSS. prism times out on 4 inputs where pion does not. |
| 4. Language coverage / extensibility | **Lost** (feature gaps, listed under P2-G below). |

The incremental check also found nothing: `highlight_line` and `highlight` agree byte-for-byte on all 17 languages, including editor-style lines fed without `\n` and CRLF input. The README's equivalence claim holds. The problem is that both paths are wrong in the same places.

## Token-class differential (run_audit §2)

Every non-whitespace byte gets one coarse class: C = comment, S = string/char/regex literal, O = code. "pion≡shiki" is the share of bytes where pion and shiki give the same class. Keys (JSON/YAML/TOML) and YAML plain scalars count as O for every engine, so naming choices do not count as disagreements.

| input | bytes | pion≡shiki | pion≡prism | prism≡shiki | pion wrong C/S bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| shipped corpus: rust / ts / go / json / css | 22 859 | 99.7–100% | 100% | 99.7–100% | 16 |
| shipped corpus: python | 5 107 | 96.0% | 86.0% | 90.0% | 144 (f-string fields) |
| shipped corpus: c | 4 039 | 96.1% | 96.1% | 100% | 116 (`#include <…>`) |
| shipped corpus: html | 2 852 | 97.4% | 96.3% | 98.9% | 56 |
| shipped corpus: yaml | 2 943 | 84.5% | 84.5% | **100%** | 304 |
| `cases/javascript.js` | 273 | **32.0%** | 31.6% | **99.5%** | 140 |
| `cases/shell.sh` | 159 | 60.0% | 66.2% | 76.9% | 52 |
| `cases/cpp.cpp` | 130 | 76.0% | 76.0% | **100%** | 25 |
| `cases/html.html` | 107 | 75.0% | 73.9% | **98.9%** | 22 |
| `cases/tsx.tsx` | 149 | 76.2% | 75.4% | **99.2%** | 30 |
| `cases/c.c` | 123 | 79.6% | 80.6% | **98.9%** | 19 |
| `cases/python.py` | 152 | 76.5% | 62.2% | 75.6% | 28 |
| `cases/markdown.md` | 88 | 54.3% | 88.6% | 54.3% | 32 |
| `cases/rust.rs`, `go.go`, `css.css`, `toml.toml` | 539 | 99.6–100% | 99.6–100% | 100% | 1 |

Reading the table:
- **On the shipped benchmark corpus pion agrees with shiki 96–100%.** The shipped corpus has no regex literals, JSX, raw strings, heredocs or multi-line `<script>`.
- **On real but tricky code it drops to 32–80%, while prism and shiki still agree with each other 99–100%** (js, tsx, cpp, c, html). So the difference is pion's error, not a matter of taste.
- I do not use the rows where the two references disagree (`sql`, `markdown`, `python` rb-strings) as evidence.

## P0: lexer state corruption (following code is mis-highlighted)

| # | Test (`redteam_test.pion`) | Input | What pion does | Real lexer / prism / shiki |
| --- | --- | --- | --- | --- |
| 1 | `P0 js: regex … double quote` | ``const re = /a"b/g; const n = 1;`` | No regex literal at all. The `"` opens a string, so `"b/g; const n = 1;` becomes one String | `/a"b/g` is a regex; `const`, `1` are code |
| 2 | `P0 js: regex … single quote` | `if (/'/.test(s)) x = 42;` | `'/.test(s)) x = 42;` becomes String | regex, then code |
| 3 | `P0 ts: two-level nested template` | ``const t = `a ${ `b ${1}` } d`;⏎const after = 2;`` | ` d` comes out plain. The closing `` ` `` opens a new template that **eats line 2** | one template; line 2 is code. (The shipped tests only nest one level.) |
| 4 | `P0 tsx: apostrophe in JSX text` | `<div>it's {name}</div>; const k = 1;` | `'s {name}</div>; const k = 1;` becomes String. `tsx`/`jsx` are advertised aliases but have no JSX support | JSX text |
| 5 | `P0 html: block comment in <script>` | `<script>⏎/* a⏎b */ let x = 1;` | Line 3 `b` is plain and `*/` is an operator. The JS state is not carried across lines inside `<script>` | comment |
| 6 | `P0 html: template in <script>` | ``let t = `a⏎b`; let y = 2;`` | `b` is plain, and ``; let y = 2;`` is String (inverted) | string, then code |
| 7 | `P0 cpp: raw string` | `R"d(say "hi")d"; int z = 1;` | `R"…"` is not supported, so `"; int z = 1;` becomes String | one raw string |
| 8 | `P0 c: string line continuation` | `"a\⏎b"; int y = 2;` | Line 2 inverts: `b` is code and `"; int y = 2;` is String | C11 phase-2 splice |
| 9 | `P0 shell: heredoc` | `cat <<EOF⏎it's $HOME "x⏎EOF` | The body is lexed as code: `'s $HOME "x` becomes a stray string | heredoc body |
| 10 | `P0 shell: escaped quote` | `echo don\'t; ls # real comment` | `'t; ls # real comment` becomes String | `\'` is a literal quote |
| 11 | `P0 shell: multi-line '…'` | `echo 'a⏎b # still string'` | The string ends at the newline and `# still string'` becomes a Comment | POSIX quotes span lines |
| 12 | `P0 shell: multi-line "…"` | `msg="line one⏎line # two"` | Same as #11 | same |
| — | (P1 tests in the same groups) `regex not highlighted`, `$(…)` nested quotes | `/^\d+$/`, `"$(echo "inner") done"` | regex is plain; `inner` is plain | literal / string |

## P1: encoding defect and wrong class for common constructs

| Test | Input | Defect |
| --- | --- | --- |
| `P1 cpp: unclosed [[ splits a UTF-8 character` | `[[é` | The attribute scan stops at `end-1` (`src/lang_code.pion:352`, `while p + 1 < end`), so the span ends **inside** `é`. |
| `P1 cpp: highlight_html emits invalid UTF-8` | `x [[😀` | Output is `…[[\xf0\x9f\x98</span>\x80`: invalid UTF-8 / mojibake. The test runner's own JSON output became undecodable because of it. |
| `P1 c: #include <header>` | `#include <stdio.h>` | path is plain (prism `string`, shiki `string.quoted.other.lt-gt.include`) |
| `P1 markdown: fenced code not highlighted` | ```` ```rust ```` block | the whole body is one String; shiki highlights the embedded language |
| `P1 css: negative numbers` | `margin: -1.5em -2px` | `-1` is plain and `.5em` is a Number; `-2px` is entirely plain |
| `P1 css: selectors inside @media` | `@media screen { .m { … } }` | `.m` is plain (top-level `.m` is a Tag) |
| `P1 scss: advertised alias` | `$main: #333; // it's a note` | `//` is not a comment: `it` is a Tag and `'s a note` is a String; `$var` is a Tag |
| `P1 toml: offset datetime` | `1979-05-27T07:32:00Z` | split into `1979-05-27` / plain `T07:` / `32` / `00` |
| `P1 toml: inline table keys` | `{ a = 1, b.c = "d" }` | keys are plain |
| `P1 python: f-string fields` | `f"total={x + 1}"` | the expression is String (prism `string-interpolation`, shiki `meta.fstring`); 144 B on the shipped corpus |
| `P1 js: CR line terminator` | `// c\rlet x = 1;` | `let …` is swallowed into the comment (ECMAScript LineTerminator includes CR) |
| `P1 jsx: tags` | `<Button onClick={go}>` | `Button` is plain |

## P2: granularity gaps vs prism / shiki

- **Rust:** `b'x'` and `c"hi"` prefixes sit outside the literal. Generic definitions (`fn parse<T>`, TS `function comp<T>`) are not marked Function. Lifetimes and labels use `hl-attribute` (no Lifetime kind).
- **HTML:** `&amp;` is plain (prism `entity`). An unquoted attribute value is classed as an attribute name. The XML `<?xml ?>` prolog is plain. Format placeholders `{}` in Rust strings are not split out (16 B in the corpus).
- **Markdown:** `**bold**`, `_it_`, list markers and link text are plain.
- **SQL:** `$$…$$` bodies are not strings; `FUNCTION`/`RETURNS`/`LANGUAGE` are not keywords.
- **Shell:** in `$((1 + 2))` the operators are plain; command names are plain.
- **C:** `#define` continuation lines leave the directive.
- **P2-G, coverage and extensibility:** the API is a closed `enum Language`. There is no way to register a language or grammar and no theme or scope mapping (fixed 18 classes, CSS classes only). There is no ANSI/terminal output, no line-number or line-wrapped HTML, no per-line `highlight_html`, and no "diff with language" mode. Missing high-frequency languages that prism and shiki both ship include Java, Kotlin, Swift, C#, PHP, Ruby, Lua, Dockerfile, Makefile, GraphQL, Vue/Svelte, Zig, Haskell, Scala, INI, PowerShell and Nix. `scss`/`xml`/`svg`/`mysql` resolve to the CSS/HTML/SQL lexers with none of the dialect features. The briefing listed Java as "already supported"; it is not (`resolve_language("java")` returns `None`).

## Attack surfaces with no finding (stated so the tally is fair)

- **XSS / escaping:** 17 languages × 67 inputs (`</span><script>`, `"><svg/onload>`, entity look-alikes, NUL/DEL/CR, random 300-byte strings). Results: **0** raw `<>"'&` outside the emitted span markup, and **0** round-trip mismatches.
- **Incremental consistency:** 17 languages, multi-line state (nested comments, raw strings, templates, triple quotes, block scalars, fences, `<script>`/`<style>`). **0** differing bytes for full vs editor lines without terminators, and **0** for full vs CRLF.
- **Performance:** no super-linear input found. Doubling `[[`×N from 256 K to 4 M bytes took 5→9 ms.

### End-to-end HTML benchmark (`scripts/bench_compare.py`, warmup 1, 5 interleaved rounds)

Stdout is the FNV-1a of each engine's HTML after stripping tags and decoding entities. SHA-256 was identical across all three engines, which shows each one rendered losslessly. Node times include process start, the same as the shipped benchmark.

| Input | Implementation | Median ms | Min | P95 | MB/s | Peak RSS | vs prism |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| shipped corpus × 20 (756 000 B) | node-prismjs | 164.2 | 155.4 | 165.6 | 4.61 | 88.3 MiB | 1.00× |
| | node-shiki | 2705.1 | 2297.8 | 2777.0 | 0.28 | 272.9 MiB | 0.06× |
| | **pion-highlight** | **26.2** | 22.4 | 28.2 | **28.80** | **2.45 MiB** | **6.25×** |
| 1 MiB minified JS, 1 line | node-prismjs | 1804.0 | 910.4 | 2008.2 | 0.58 | 485.0 MiB | 1.00× |
| | node-shiki | 909.5 | 805.2 | 1063.2 | 1.15 | 124.1 MiB | 1.98× |
| | **pion-highlight** | **52.7** | 49.2 | 56.5 | **19.90** | 34.6 MiB | **34.2×** |

SHA-256: corpus `7af41383…7cc9`, minified `966d646a…c633`.

### Adversarial 1 MiB sweep (single run each, 15 s timeout, all outputs lossless)

| input | pion ms / RSS | prism ms / RSS | shiki ms / RSS |
| --- | ---: | ---: | ---: |
| javascript.escaped_quotes | 21 / 13 MiB | **TIMEOUT** | 648 / 108 MiB |
| javascript.template_nesting | 49 / 54 MiB | **TIMEOUT** | 992 / 112 MiB |
| markdown.backticks | 13 / 5 MiB | **TIMEOUT** | 356 / 268 MiB |
| shell.dollar_brace | 11 / 5 MiB | **TIMEOUT** | 688 / 175 MiB |
| rust.raw_lines | 18 / 6 MiB | 4713 / 67 MiB | 236 / 128 MiB |
| html.lt | 30 / 14 MiB | 302 / 362 MiB | 2727 / 401 MiB |
| javascript.dense_tokens | 53 / 51 MiB | 966 / 458 MiB | 718 / 112 MiB |
| (12 more in the `run_audit.sh` §5c output) | 11–40 ms | 60–1639 ms | 162–1115 ms |

Caveats on these numbers:
- pion's peak RSS scales with span count, at about 50 bytes per span. For example, 1 MiB of `a;` is 1 M spans and 50 MiB.
- The comparison is speed against a far richer tokenizer. shiki/TextMate does much more per byte, and prism's backtracking regexes are what time out. Speed here does not offset the correctness findings above.

## Suggested fix order (proposal; this audit changes nothing in `src/`)

1. JS/TS regex-literal detection (prev-token rule) and template-nesting stack. This fixes P0 #1–3 and the largest share of bytes in the differential.
2. Carry the embedded JS/CSS sub-state inside `LineState` for HTML `<script>`/`<style>` (P0 #5–6).
3. Shell quoting and heredoc state (P0 #9–12), C++ `R"d(…)d"` and C line splice (P0 #7–8).
4. The one-line `[[` bound fix (P1 UTF-8), plus a property test that "every span boundary falls on a UTF-8 char boundary" in the shipped suite.
5. Add the `cases/` fixtures and `bench/token_diff.mjs` to the package benchmark, so the published accuracy figure covers token classes and not just lossless reconstruction.
