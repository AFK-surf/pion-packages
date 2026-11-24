# `texmath`

Pure Pion TeX math parser, MathML serializer, and TeXbook Box Metrics Layout IR engine, ported from upstream [`KaTeX/KaTeX`](https://github.com/KaTeX/KaTeX) (MIT).

Zero JavaScript, zero C glue, zero `World` dependency, `Send`-safe value types, and dual-target verified on **Native (`arm64_apple`)** and **WebAssembly (`wasm32`)**.

## Architecture

1. **Lexer & MacroExpander (`src/lexer.pion`, `src/macros.pion`)**
   - Pure byte-scanning TeX tokenizer (no regex overhead) with UTF-8 support, `%` comment stripping, control words/symbols, and lexically scoped macro namespaces (`\def`, `\gdef`, `\edef`, `\xdef`, `\global`, `\let`, `\newcommand`, `\renewcommand`, `\providecommand`, `\begingroup...\endgroup`) guarded by `max_expand` and token-stack limits (`65,536` tokens) to prevent exponential memory-exhaustion bombs.
2. **Parser (`src/parser.pion`, `src/symbols.pion`)**
   - Recursive-descent parser with explicit nesting-depth guard (`max_depth = 1200`) preventing stack-overflow crashes on deeply nested inputs, backed by KaTeX's full symbol tables (1,488 math symbols + 750 text symbols, O(1) ASCII + first-character bucketed dispatch).
   - Supports groups, super/subscripts, primes, fractions (`\frac`, `\dfrac`, `\tfrac`, `\cfrac`, `\binom`, `\genfrac`, infix `\over`/`\choose`/`\atop`/`\brace`/`\brack`/`\above`), roots (`\sqrt[n]{x}`), large operators (`\sum`, `\int`, `\prod`, `\lim`, `\limsup`, `\injlim`, `\varliminf`, `\operatorname`, `\operatornamewithlimits`, `\argmax`, `\limits`/`\nolimits`), delimiters (`\left...\right`, `\middle`, `\big`..`\Bigg`), non-stretchy & stretchy over/under accents, `\overline`/`\underline`/`\underbar`/`\overbrace`/`\underbrace`/`\overset`/`\underset`/`\stackrel`, extensible arrows (`\xrightarrow`..`\xmapsto`..`\xlongequal`), matrices & alignment environments (`matrix`, `pmatrix`, `bmatrix`, `Bmatrix`, `vmatrix`, `Vmatrix`, `*`-variants with alignment, `smallmatrix`, `cases`, `rcases`, `dcases`, `aligned`, `align`, `alignat`, `alignedat`, `gathered`, `gather`, `split`, `equation`, `array`, `darray`, `subarray`, `\substack`, `CD`, `\tag`/`\notag`), boxes & annotations (`\colorbox`, `\fcolorbox`, `\boxed`, `\cancel`/`\bcancel`/`\xcancel`/`\sout`, `\phase`, `\angl`, `\smash`, `\rlap`/`\llap`/`\clap`/`\mathrlap`, `\raisebox`, `\pmb`), bra-ket (`\bra`, `\ket`, `\braket`, `\set`, `\Set`, `\Braket`), `\mathchoice`, `\verb`, `\char`, fonts, sizing switches (`\tiny`..`\Huge`), text mode (with accents, combining marks, nested braces, and `$...$`), colors, spacing, phantoms, rules, and `ParseOptions.throw_on_error`.
3. **TeX Box Metrics Layout IR (`src/layout.pion`, `src/metrics_data.pion`)**
   - Real CM/KaTeX font metrics across 12 font tables (`Main-Regular`, `Math-Italic`, `Main-Bold`, `Size1..4-Regular`, `AMS-Regular`, `Caligraphic-Regular`, `Fraktur-Regular`, `SansSerif-Regular`, `Typewriter-Regular`) plus TeXbook `sigmasAndXis`.
   - Implements TeXbook Rules 11 (roots with Size1–Size4 surd depths), 12 (accents), 13 (large operators & display limits), 15 (fractions), 18 (scripts with character-box & script-style drop rules), 19 (axis-centered delimiters), and p. 170 inter-atom spacing with binary-operator cancellation. Verified against KaTeX `__renderToHTMLTree` across 60 formulas (0 / 60 mismatches within 0.005em).
   - Emits positioned `LayoutBox` trees (`Glyph`, `HBox`, `VBox`, `Rule`, `Kern`, `Delim`, `Radical`, `ColorBox`, `ShiftBox`) with `(x, y, width, height, depth, font_style, scale)` ready for native GPU UI rendering.
4. **KaTeX-Compatible MathML Serializer (`src/mathml.pion`)**
   - Byte-for-byte compatible with `katex.renderToString(tex, { output: "mathml", displayMode })` across 55 unit vectors, 100/100 red-team differential cases, 500 benchmark formulas (SHA-256 verified), and 108/127 (85.0%, 0 valid rejections) of KaTeX v0.19.1's own screenshotter corpus.

## Public API

```pion
pub val struct ParseOptions { pub display_mode : Bool, pub throw_on_error : Bool, pub max_expand : Int }
pub val struct TexError { pub message : String, pub position : Int }
pub val struct Metrics { pub width : Double, pub height : Double, pub depth : Double, pub italic : Double }
pub val struct BoxGeom { pub x : Double, pub y : Double, pub width : Double, pub height : Double, pub depth : Double, pub font_style : String, pub scale : Double }

pub fn parse(tex : String, opts : ParseOptions) -> Result[Array[MathNode], TexError]
pub fn layout(nodes : Array[MathNode], display_mode : Bool) -> LayoutBox
pub fn to_mathml(tex : String, display_mode : Bool) -> Result[String, TexError]
pub fn render_layout(tex : String, display_mode : Bool) -> Result[LayoutBox, TexError]
pub fn box_geom(b : LayoutBox) -> BoxGeom
pub fn box_metrics(b : LayoutBox) -> Metrics
```

## Verification & Benchmark

- **Tests**: 185 tests across `parser_test.pion` (65), `errors_test.pion` (35), `mathml_test.pion` (55 exact KaTeX v0.19.1 vectors), `layout_test.pion` (25 TeXbook box invariants), and `security_test.pion` (5).
- **Red-Team Audit (`packages/texmath/audit`, v0.2.0)**: 168/168 red-team tests, 60/60 layout formulas with 0 mismatches, 108/127 KaTeX screenshotter formulas (0 valid rejections), 31 DoS probes with 0 SIGSEGV / 0 OOM (`def_arg_growth`: 0.08 s / 5.8 MiB). Reproduce with `sh packages/texmath/audit/run_audit.sh`.
- **Wasm32**: `pionc build --target wasm32 packages/texmath/wasm_smoke -o /tmp/texmath_smoke.wasm`

### v0.2.0 Head-to-Head (after red-team remediation)

Measured on Apple M5 Max (Darwin arm64) with `bench/corpus.txt` × 20, `scripts/bench_compare.py` strictly interleaved, stdout SHA-256 identical across implementations:

| Target | `pion-texmath` Median | `pion-texmath` Peak RSS | `node-katex` Median | `node-katex` Peak RSS | Speedup (vs `node-katex`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Native (`--release`) | 122.69 ms | 3.44 MiB | 282.46 ms | 68.86 MiB | **2.30x** |
| Wasm32 (`AFK-surf/pion@69a0189d`) | 343.3 ms | 274.8 MiB | — | — | 0.78x |

Lagging item: Wasm32 is still 0.78x of Node.js KaTeX. Re-measured on `AFK-surf/pion@69a0189d`: median 343.3 ms and 274.8 MiB peak RSS, down from 654.94 ms / 837.92 MiB / 0.43x on the earlier `pionc 0.1.0` Wasm runtime (−67% peak RSS). Piped stdout is the full 314,336 B with no truncation and its SHA-256 matches Native and Node.js KaTeX.

### v0.1.0 Head-to-Head (historical, before red-team remediation)

Apple M5 Max (`Darwin arm64`), 500 diverse formulas × 20 = 10,000 ops, `--warmup 1 --rounds 5`:

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `node-katex`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `node-katex` (v0.19.1, Node v24.22.2) | 227.652 | 209.684 | 385.077 | 22765.18 | 68.84 MiB | 1.00x (baseline) |
| `pion-texmath` (Native `--release`) | 101.844 | 87.906 | 103.650 | 10184.45 | 3.27 MiB | **2.24x** |

_SHA-256 verified identical across all implementations and rounds: `7c3c83901ff427fecac643e702c47cb71e546e8ef1641c429a7b11a57db2e9fa` (314,336 B)._
