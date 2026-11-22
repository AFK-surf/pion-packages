# Red-team audit: Pion `texmath` vs real KaTeX

- **Target**: `AFK-surf/pion-packages` `origin/main` `7a40e8f`, `packages/texmath` (`src/**` and the existing tests are unchanged).
- **Reference**: npm `katex@latest` = **0.19.1** (the same version the README names), Node v24.22.2.
- **Host**: `tokyo-mac-studio-0`, Apple M5 Max, Darwin arm64, `pionc 0.1.0 (arm64_apple, self-hosted)`.
- **Scope**: everything below comes from running both implementations on the same input. No claim rests on reading code alone. Where code is quoted, it only explains a behaviour that was already measured.

## How to reproduce

```sh
export PATH="$HOME/.pion/bin:$PATH"
sh packages/texmath/audit/run_audit.sh            # everything; installs katex@latest into a temp dir; exit 1 = defects found
AUDIT_OUT=/tmp/texmath-audit sh packages/texmath/audit/run_audit.sh   # keep raw outputs (per-case diffs, stderr)
pionc test packages/texmath/audit                 # evidence tests only (texmath's own 180 tests run too; filter with -p texmath_redteam)
KATEX_PATH=/path/to/node_modules/katex sh packages/texmath/audit/repro.sh '\overrightarrow{AB}'       # one formula, both engines
KATEX_PATH=/path/to/node_modules/katex sh packages/texmath/audit/repro.sh '\hat{x}' I layout          # one formula, box height/depth
```

| File | Purpose |
| --- | --- |
| `pion.toml`, `tests/pion.toml`, `tests/redteam_test.pion` | Evidence suite: 168 tests. Each one asserts what real KaTeX does, so **a failing test is a defect.** |
| `redteam_prelude.pion.in`, `redteam_cases.tsv`, `cases_layout.txt`, `gen_tests.mjs` | Source of the suite. `KATEX_PATH=… node gen_tests.mjs && pionc fmt tests` regenerates `tests/redteam_test.pion`, using real KaTeX output as the expected values. |
| `diff_driver/` | Pion CLI: one formula per line, `OK <mathml>` / `ERR <msg>`, or `OK <height> <depth>` with `layout`. |
| `katex_diff.mjs`, `katex_layout.mjs` | The same output from real KaTeX (`renderToString(…, {output:"mathml"})` and `__renderToHTMLTree` box height/depth). |
| `diff_compare.py` | Classifies each line: identical / `PION_REJECTS_VALID` / `PION_ACCEPTS_INVALID` / `MATHML_DIFFERS` / error text differs. |
| `cases_targeted.txt` | 285 targeted attack inputs, covering every attack surface in the brief. |
| `corpus_katex_screenshotter.txt` | KaTeX v0.19.1's own `test/screenshotter/ss_data.yaml` (MIT): all 127 entries that need no custom `macros` option, newlines folded. |
| `dos_probe.py` | Runs each pathological input in its own process group under both engines, records peak RSS, and kills the run at a timeout or RSS cap. |

## Headline numbers (from one `run_audit.sh` run)

| Measure | Result |
| --- | --- |
| Evidence suite `pionc test packages/texmath/audit` | **139 of 168 FAIL** (api 2/2, dos 6/6, katex-diff 100/100, katex-layout 31/60) |
| KaTeX's own screenshotter corpus (127 formulas) | Byte-identical MathML on only **31 (24%)**. Pion **rejects 62 (49%)** that KaTeX renders, and **33** give different MathML |
| Targeted corpus (285) | 98 identical, **86 rejected though valid**, **59 MathML differs**, **5 accepted though invalid**, 37 differ only in error text |
| Layout (60 formulas, root box height/depth, tolerance 0.005em) | **31 of 60 differ** from KaTeX, by up to **0.8em** |
| Deep nesting | **Process crash (SIGSEGV)** at about 7.5k `\color`, about 9.4k `\frac`/`\sqrt` and about 15k `{`. KaTeX throws a catchable error |
| 25-byte macro | Pion reaches **>3–4 GiB RSS in 5–10 s** without stopping. KaTeX errors in 0.1 s |
| wasm32 (the browser target), same corpus as the README | **0.67x KaTeX speed** (1.5x slower) and **580–600 MiB peak RSS vs 67 MiB** |

The README says the output is *"Byte-for-byte compatible with `katex.renderToString(tex, { output: "mathml", displayMode })` (verified by SHA-256 across 55 unit vectors and 500 diverse benchmark formulas)"*. That holds only for the hand-picked corpus. On KaTeX's own test corpus, 76% of formulas are rejected or render differently.

---

## P0: crashes, security, silent wrong results

### P0-1 Deep nesting crashes the whole process (stack overflow, SIGSEGV)
`to_mathml` and `render_layout` recurse with no depth limit and never return `Err`, so the host process dies. KaTeX throws an ordinary catchable exception (`RangeError: Maximum call stack size exceeded`) and the caller survives. Any app that renders untrusted TeX (chat, notes, Markdown preview) can be taken down by a single message.

| Input (`dos_probe.py` name) | KaTeX | Pion |
| --- | --- | --- |
| `\frac{` ×10 000 … (`frac_1e4`) | `ERR Maximum call stack size exceeded`, 0.7 s | **CRASH** (`time: command terminated abnormally`) |
| `\sqrt{` ×10 000 (`sqrt_1e4`) | ERR, catchable | **CRASH** |
| `\color{red}{` ×10 000 (`color_1e4`) | ERR, catchable | **CRASH** |
| `{` ×100 000 (`braces_1e5`) | ERR, catchable | **CRASH** |
| `\color{red}{x}` ×32 000, **flat, no explicit nesting** (`color_flat_32000`, 448 KB) | ERR, catchable | **CRASH** |

Bisected crash thresholds (native release build, 8 MiB main stack): about 7.5k nested `\color`, about 9.4k `\frac`/`\sqrt`, about 15k `{`. With a smaller stack, such as a thread or the wasm shadow stack, the threshold is lower.
Tests: `dos: 10000 nested \frac …`, `… \sqrt …`, `… \color …`, `100000 nested braces …`, `32000 flat \color switches …`, `render_layout on 10000 nested \sqrt …`. All 6 fail because the test process is killed.
Reproduce: `python3 packages/texmath/audit/dos_probe.py <diffdrv> packages/texmath/audit/katex_diff.mjs $KATEX_PATH frac_1e4 color_flat_32000`.

### P0-2 Memory-exhaustion DoS from 25 bytes: `\def\a#1{\a{#1#1}}\a{x}`
| | KaTeX | Pion |
| --- | --- | --- |
| `def_arg_growth` | `ERR Maximum call stack size exceeded`, **0.12 s, 63 MiB** | **No result. RSS 3.0 GiB at 10 s** (timeout), **4.1 GiB at 5.5 s** (RSS-cap run). Watched by hand: 1 → 3 → 6 → 8.7 GiB in 10 s, still growing |

Cause, confirmed by the measurement: `max_expand` counts *expansions* (`src/macros.pion` `expander_next_token`), but each expansion doubles the argument it pushes back. Memory therefore grows as 2^n before the counter reaches 1000. There is no limit on token or stack size. The simpler bombs (`\def\a{\a\a}`, billion-laughs through `\def` bodies or arguments) *are* stopped correctly. This argument-doubling form gets through.
Reproduce: `python3 …/dos_probe.py <diffdrv> …/katex_diff.mjs $KATEX_PATH def_arg_growth --timeout 10`.

### P0-3 Macro scoping is wrong: definitions leak out of groups and cells, depending on order
`expander_begin_group` pushes a scope only *if a user macro already exists*. So the first `\def` made inside a group goes into the global scope and survives the closing `}`. KaTeX treats `\def`/`\newcommand` as group-local.

| Input | KaTeX | Pion |
| --- | --- | --- |
| `{\def\a{x}}\a` | `ERR Undefined control sequence: \a` | **OK**, renders `x` |
| `{\newcommand{\a}{x}}\a` | ERR | **OK** `x` |
| `\begin{matrix}\def\a{x} & \a\end{matrix}` | ERR (cells are groups) | **OK**, `x` appears in cell 2 |
| `{\def\a{2}}\def\b{}\a` | ERR | **OK** `2` |
| `\def\b{}{\def\a{x}}\a` | ERR | ERR (so the result depends on whether *any* macro was defined earlier) |

Tests: `katex-diff: def_scope_leak_group`, `newcommand_scope_leak`, `def_scope_leak_matrix_cell`, `def_scope_leak_order`.

### P0-4 Silent wrong output: Pion accepts input KaTeX rejects, or overrides built-ins
| Input | KaTeX | Pion |
| --- | --- | --- |
| `\newcommand{\a}[2][y]{#1+#2}\a[z]{x}` | `ERR Expected '}', got '#'` | **OK**, garbage: `y ] # 1 + # 2 [ ] x` rendered as math |
| `\renewcommand{\a}{x}` | `ERR \renewcommand{\a} when command \a does not yet exist` | OK |
| `\newcommand{\alpha}{x}` | `ERR … attempting to redefine \alpha; use \renewcommand` | OK |
| `\providecommand{\alpha}{x}\alpha` | `α` (providecommand must **not** override) | **`x`** (overrides the built-in) |
| `\strut x` | `ERR Undefined control sequence: \strut` | OK (invented `<mspace height="0.85em"/>`) |
| `#` | `ERR Expected 'EOF', got '#'` | OK `<mi>#</mi>` |

### P0-5 MathML output contains raw TeX control words
Every stretchy over/under accent outside the few that are special-cased writes the TeX command name as the operator text:

```
\overrightarrow{AB}  katex: <mo stretchy="true">→</mo>   pion: <mo>\overrightarrow</mo>
\widehat{AB}         katex: <mo stretchy="true">^</mo>   pion: <mo>\widehat</mo>
\overgroup{AB}       katex: <mo stretchy="true">⏠</mo>   pion: <mo>\overgroup</mo>
```
Browsers render the literal text `\overrightarrow` above the formula. Tests: `overrightarrow_literal`, `widehat_literal`, `overgroup_literal`.

---

## P1: missing core capabilities, spec divergences, API contract

### P1-1 Large parts of KaTeX's supported command set are missing (`Undefined control sequence` / `No such environment`)
Each item below was verified to render in KaTeX 0.19.1 and to be rejected by Pion. Each has a failing `katex-diff:` test.

- **Line breaks**: `\\` at top level, `\newline`, `\cr`. 3 of KaTeX's screenshot formulas fail on `\\` alone.
- **Dots**: `\vdots`, `\dotsb` (`\ddots` exists, but `\vdots` does not, so a standard ⋮ matrix fails).
- **Overlap and smash** (named in the brief): `\smash`, `\smash[b]`, `\rlap`, `\llap`, `\clap`, `\mathrlap`, `\mathllap`.
- **Stacking and arrows** (named in the brief): `\stackrel`, the whole `\x…arrow` family (`\xrightarrow`, `\xleftarrow[…]{…}`, `\xRightarrow`, `\xmapsto`, `\xrightleftarrows`, …), `\mapsfrom`, `\Overrightarrow`, `\utilde`, `\underleftarrow`.
- **Color and boxes** (named in the brief): `\colorbox`, `\fcolorbox`, `\boxed`, and the color macros `\red`, `\blue`, … (12 screenshot formulas use them).
- **Environments**: `alignat`, `alignedat`, `CD` (named in the brief), `matrix*`/`pmatrix*`…, `dcases`, `darray`, plus `\substack`, `\tag`, `\notag`.
- **Macros** (named in the brief): `\let` (both `\let\b=\alpha` and `\let\b\alpha`), `\gdef`, `\global\def`, `\edef`, `\xdef`, `\char`, `\TextOrMath`, `\begingroup…\endgroup`.
- **Fonts and symbols**: `\imath`, `\jmath` (12 screenshot formulas), `\pmb`, `\textnormal`, `\textup`, `\textmd`, `\emph`, legacy `\it`/`\sf`/`\tt` inside `\text`, `\copyright`, `\minuso`, `\llbracket`, `\lBrace`, `\dddot`.
- **Other**: `\cancel`/`\bcancel`/`\xcancel`/`\sout`, `\phase`, `\angl`, `\Set`/`\set`/`\braket`/`\bra`/`\ket`, `\mathchoice`, `\raisebox`, `\vcenter`, `\hbox`, `\verb`, `\KaTeX`/`\TeX`/`\LaTeX`, `\href`/`\url`, `\htmlId`, `\underbar`, `\operatornamewithlimits`, `\argmax`, `\varliminf`, `\plim`, `\mskip`, `\hskip`, `\mathstrut`, `{a \above 2pt b}`, `\genfrac(]{…}` (unbraced delimiters).

### P1-2 MathML differs from KaTeX on supported commands (59 targeted and 33 screenshot cases)
These are the inputs the README presents as byte-identical. Selected cases (full list: `run_audit.sh` §2–3 and `MATHML_DIFFERS` in `targeted.diff`):

| Input | KaTeX | Pion |
| --- | --- | --- |
| `{\Huge x}`, `{\tiny a+b}` | `<mstyle mathsize="2.488em">` / `"0.5em"` | size **dropped** |
| `𝐀𝑎𝔸` (math alphanumerics) | `<mi>𝐀</mi><mi>𝑎</mi><mi>𝔸</mi>` | `<mi>A</mi><mi>a</mi><mi>A</mi>` (**character changed**) |
| `\text{\'e}` | `<mover accent="true"><mtext>e</mtext><mo>ˊ</mo></mover>` | `<mtext>ˊe</mtext>` (accent printed *before* the letter) |
| `\text{é}`, `\text{ÀàÇç…}` | combining-accent `<mover>` per letter | plain `<mtext>` |
| `\text{c~d}` | `c d` (nbsp) | literal `c~` |
| `\text{c {ab} e}` | `<mtext>c ab e</mtext>` | splits into math `<mi mathvariant="normal">` |
| `\begin{equation}`, `gather` | `mtr-glue` cells + `mml-eqn-num` column | missing |
| `\begin{gathered}` | `rowspacing="0.25em" columnspacing="0em"` | `0.16em` / `1em` |
| `\begin{aligned}` with 2 column pairs | `columnspacing="0em 1em 0em"` | `columnspacing="0em"` |
| `\begin{subarray}` | `scriptlevel="1"`, `rowspacing="0.1em"` | `scriptlevel="0"`, `0.16em` |
| `\sum\limits_{i=1}^n` (inline) | `<msubsup>` | `<munderover>` |
| `\operatorname*{argmax}_x` (inline) | `<msub>` | `<munder>` |
| `\injlim` | `inj lim` | `injlim` |
| `\degree` | `<mi mathvariant="normal">°</mi>` | `<msup><mrow/><mo>∘</mo></msup>` |
| `x\overset{!}{=}y` | `<mo><mover>…</mover></mo>` (relation class kept) | bare `<mover>` (spacing class lost) |
| `\left( a \middle| b \right)` | `lspace="0.05em" rspace="0.05em"` on `\middle` | missing |
| `\rule{1em}{0.5em}`, `\rule{1ex}{2ex}` | `<mpadded height="0em" voffset="0em"><mspace mathbackground="black" …>` | `<mspace …/>` (**invisible rule: no background**) |
| `\hphantom{x}` | `<mpadded height="0px" depth="0px">` | plain `<mphantom>` (keeps height) |
| `\scriptstyle a\;b` | `<mspace width="0.3253em"/>` | `<mtext>  </mtext>` |
| `\genfrac{(}{]}{0pt}{2}{a}{b}` | `<mstyle scriptlevel="1">` (style arg 2) | style argument ignored |
| `\kern300000em x`, `\rule{100000000em}{1em}` | `width="300000em"` | **`width="214748.3647em"`**: 32-bit overflow in `format_em` (`(av*10000.0+0.5).to_int()`) |
| `\cdots;\dots+\dots\int\dots,\dots` | context-sensitive `\dots` → `⋯` before `+`/`\int`, plus `<mtext> </mtext>` / thin-space glue | always `…`, no glue |

### P1-3 `ParseOptions.throw_on_error` is part of the API but never read
`grep throw_on_error src/` finds only the struct field and its defaults. With KaTeX's `throwOnError: false`, `\foo x` renders `<mstyle mathcolor="#cc0000"><mtext>\foo</mtext></mstyle><mi>x</mi>`. Pion's `parse("\\foo x", {throw_on_error: false})` still returns `Err`, and `to_mathml` has no way to accept options at all. There is also no counterpart to KaTeX's `maxSize`, `strict`, `trust`, `macros` (pre-defined macros), `errorColor`, `minRuleThickness`, `output: "html"` or `leqno`/`fleqn`.
Test: `api: ParseOptions.throw_on_error=false must not fail on undefined control sequence`.

### P1-4 Error behaviour differs (37 targeted cases)
Error text is not part of the byte-compatibility claim, so these are not counted as hard defects. Pion's messages often name a different cause, for example `\hspace{1e400em}` gives `Invalid unit: 'e400em'` where KaTeX says `Invalid size: '1e'`. They carry no `KaTeX parse error:` prefix and no position underline, which breaks downstream code that parses KaTeX errors.

---

## P2: layout fidelity, performance and memory

### P2-1 Box layout differs from KaTeX's TeX layout in 31 of 60 formulas
Reference: KaTeX's own `__renderToHTMLTree` root height and depth (KaTeX's implementation of TeXbook Appendix G with the same font metrics). Pion: `box_metrics(render_layout(tex))`. Plain glyphs, scripts, fractions, display `\sum`/`\prod`/`\lim`, `\overline`, `\underline`, `\phantom` and `\rule` match exactly (29 formulas). Everything that uses delimiters, radicals, accents or arrays does not:

| Formula | KaTeX h / d | Pion h / d | Error |
| --- | --- | --- | --- |
| `\hat{x}`, `\hat{A}`, `\vec{v}`, `\bar{x}` | 0.694 / 0 … | 0.894 / 0 … | **+0.200em on every accent** (constant bias) |
| `\sqrt{x}`, `\sqrt[3]{x}` | 0.800 / **0.240** | 0.760 / **0.000** | radical sign has no depth |
| display `\sqrt{\frac{a}{b}}` | 1.545 / 0.895 | 1.295 / 0.686 | −0.25 / −0.21 |
| inline `\left( \frac ab \right)` | 0.850 / 0.350 | 0.750 / 0.345 | delimiter not raised to Size1 |
| `\bigl(` … `\Biggl(` | 0.85/0.35, 1.15/0.65, 1.45/0.95, 1.75/1.25 | 0.78/0.42, 1.17/0.65, 1.56/0.84, 1.95/1.05 | wrong `\big` sizes and axis centring |
| `\overbrace{a+b}^{n}` | 1.844 / 0.083 | 1.044 / 0.083 | **−0.8em**: brace label ignored |
| `\underbrace{a+b}_{n}` | 0.694 / 1.233 | 0.694 / 0.483 | **−0.75em** |
| `\begin{cases}…` (2 rows) | 1.750 / 1.250 | 1.350 / 0.850 | −0.4 / −0.4 |
| `\begin{aligned}` / `pmatrix` / `bmatrix` | | | −0.25 / −0.1 / −0.1 on each side |
| display `\binom{n}{k}` | 1.450 / 0.950 | 1.108 / 0.686 | delimiters not grown |
| inline `\int_0^1 f` | 1.009 / 0.356 | 0.870 / 0.356 | −0.139 |
| `\overset{!}{=}` (display) | 1.153 / 0.000 | 1.053 / **−0.133** | **negative depth** (invalid box) |
| `\underset{n}{\to}` | 0.367 / 0.700 | 0.367 / 0.368 | −0.33 |

The existing `layout_test.pion` checks only loose invariants ("width in (0.5, 0.7)", "sqrt bounds exceed radicand"). None of these errors trips it. A native Invar/mbui renderer using this IR would draw visibly misplaced accents, too-small delimiters and clipped radicals.

### P2-2 wasm32 (the browser target) is slower than KaTeX and uses 9x the memory
Same 500-formula corpus ×20 as the README, same Node, `bench_compare.py --warmup 1 --rounds 5`, SHA-256 identical:

| Implementation | Median (ms) | Min | P95 | ns/op | Peak RSS | vs KaTeX |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `node-katex` 0.19.1 | 750.6 | 640.4 | 910.7 | 75 058 | 67.5 MiB | 1.00x |
| `pion-wasm32` (`--release --target wasm32`, `pion_wasm_rt.mjs`) | 1118.1 | 981.6 | 1902.3 | 111 810 | **579.8 MiB** | **0.67x** |

The RSS is about 600 MiB even for a *single* pass over the corpus (`iters=1`: wasm 599 MiB vs KaTeX 68 MiB), while the module declares only 20 initial pages (1.25 MiB). Not attributed further: it may come from `pion_wasm_rt`'s allocator or texmath's allocation pattern. It is a measured cost to anyone shipping `texmath` to the web either way.
(An earlier quiet run gave KaTeX 598 ms, wasm 886 ms and native 134 ms: the same ordering.)

**Tooling defect found on the way**: through a *pipe*, `node pion_wasm_rt.mjs prog.wasm …` stdout is cut off at 65 536 or 131 072 bytes. Native prints 314 333 bytes; wasm prints 131 072 into `| wc -c`. `bench_compare.py` then reports a SHA mismatch. Writing to a file gives the full output. `run_audit.sh` works around this and prints the check.

### P2-3 The README benchmark corpus is curated to what Pion supports
`bench/pion_bench` aborts at the first formula it cannot parse. Run on KaTeX's own screenshotter corpus it exits 2 on formula **#0** (`Undefined control sequence: \underbar`). KaTeX's bench gets through to #124, the corpus' deliberately invalid entry. The published "2.24x" was measured only on 500 formulas that Pion is known to accept, so the "500 diverse formulas" claim does not show coverage.

### P2-4 Where Pion is *better* (recorded for fairness, not as a defect)
- Native throughput on the README corpus: 4.8x (busy machine) and 2.8–10.8x in other runs. Peak RSS 3.3 MiB vs 68 MiB.
- Stress shapes (SHA-identical): 200k-term flat sum 2.9x, 200×200 `pmatrix` 5.5x, 500-deep `\frac` 5.9x, each at ≤40% of KaTeX's RSS.
- Scaling over 15 shapes (2k→32k repetitions: flat, Greek, `\text`, `\left…\right`, scripts, fractions, wide and tall matrices, macro use, comments, spaces, `\operatorname`, `\mathbf`, `\sqrt`, `\color`) was roughly linear, with no superlinear blow-up found. The one exception is `\operatorname` from 64k to 128k (0.14 s → 0.50 s, about 3.5x for 2x input), which is mild.
- Expansion bombs that do not grow arguments are stopped exactly like KaTeX (`Too many expansions`).
- Moderately deep nesting (1k–9k levels), where KaTeX's JS stack gives up first: Pion renders it. That stops at the crash thresholds in P0-1.
- Empty or whitespace-only input, NUL, U+FFFD, a trailing `\` and an unterminated `\text{`/`\left(` are all handled without crashing.

---

## Not covered

- Invalid UTF-8 could not be fed through the public API: `to_mathml` takes a Pion `String`, and the file-reading driver goes through `fs_read`. It was not probed separately.
- Wasm deep-nesting crash thresholds were not measured. The wasm shadow stack is smaller, so they are expected to be lower.
- Width comparison: KaTeX's HTML tree does not carry the total width (the browser computes it), so only height and depth were compared.
