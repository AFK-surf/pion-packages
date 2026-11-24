# Red-team audit: `packages/css_color` v0.1.0

- **Target**: `origin/feat/pkg-css-color` @ `7e78a4b8ba71cb7c2170877559dbc59daa5d5e01`. Read in full: `src/{types,named,math,space,parser,mix,format,css_color_test}.pion`, `bench/`, `wasm_smoke/`, `README.md`, `pion.toml`.
- **Deliverable**: `packages/css_color/audit/` only (branch `audit/pkg-css-color`). No file outside `audit/` was changed.
- **Reproduce**: `sh packages/css_color/audit/run_audit.sh` (about 25 s warm, offline once the cargo registry holds `color 0.3.3`). Sections: `build cases unit determinism oracles gamut dos api portability smoke bench harness docs`.
- **Exit status**: `1` while any P0 condition reproduces, `0` otherwise. Open P1/P2 findings are printed as `OPEN` and fail the run only with `STRICT=1`.
  - P0 conditions: a crash, trap or timeout on any input; a native-vs-wasm32 or debug-vs-release byte difference; a divergence from WPT, Chrome, `color 0.3.3` or `spec_ref.py` that no open finding explains; software math error > 1e-9 of the range; a failing `control_*` case; a DoS budget breach; a gamut-mapping invariant violation; a `wasm_smoke` output or SHA-256 that differs from `README.md`; bench output that is not byte-identical; a gate that misses an injected bug.
  - `README.md` numbers (smoke SHA-256 and output line, wasm sizes, differential case counts, bench medians and speed-ups) are parsed from `README.md` at run time by `diff/readme.py`; `run_audit.sh` contains none of them. A fix branch can therefore make `STRICT=1` pass **without editing `audit/`**.
- **Toolchain**: pionc 0.1.0 (arm64_apple, self-hosted), node v24.22.2 (`pion_wasm_rt.mjs`), cargo 1.100.0 + `color =0.3.3` (locked `Cargo.lock`), python3 3.9 stdlib, macOS arm64. Oracles: WPT `css/css-color/parsing` @ `6a5adcd6` (2026-11-24), Google Chrome for Testing 159.0.8154.6 headless shell (golden files), CSS Color 4 / 5 Editor's Drafts retrieved 2026-11-24.

## Verdict

| Severity | # | Summary |
|---|---|---|
| **P0** | **0** | No crash, trap, hang or nondeterminism. **33 151 corpus inputs** (named, hex, syntax matrix, `none`/powerless, `color-mix()`, relative/`calc()`, 6 000 numeric, **10 000 fuzz**, **11 654 WPT vectors**) + 1 424 gamut mappings + 228 DoS bombs + a 32 368-call API sweep with NaN/±Inf/subnormals give **byte-identical results in native debug/release and wasm32 debug/release**. Parsing is linear: a 16 KiB full binary `color-mix()` tree (depth 9, 512 leaves) takes 0.27 ms; 32/33-level guards hold for `color-mix`, `from` and `calc()`. Software `pow/cbrt/sin/cos/atan2/exp/ln/sqrt` match libm float64 to **≤ 1e-12** of the range on every conversion path. Every remaining divergence from WPT is reproduced and removed by a working candidate fix (fix model, below): **0 unexplained**. |
| **P1** | 2 | **P1-1**: HSL/HWB of near-white / near-black colors lacks the ED epsilon guard. `lab(100 0 0)` converts to `hsl(91.76 848.95% 100%)`, and `color-mix(in hsl, lab(100 0 0), blue)` gives `hsl(165.9 474.5% 75%)`, a saturated cyan far outside sRGB. The WPT answer is `hsl(240 50% 75%)`. **P1-2**: relative-color channel keywords turn `none` and powerless hues into `0`. `oklch(from #808080 l c h)` gets hue 0° instead of `none`, so `color-mix(in oklch, oklch(from #808080 l c h), oklch(0.7 0.2 140))` gives hue **70°** (orange) instead of 140° (Chrome and WPT). This accounts for 335 WPT vectors. |
| P2 | 14 | P2-1 `to_css()` corrupts \|v\| ≥ 9.2e12 and writes NaN/Inf as `0`. P2-2 Bradford/ProPhoto constants are pre-2023 values. P2-3 hash/`from` token boundaries. P2-4 `calc()` is too lax. P2-5 `calc()`/literals are too strict. P2-6 CSS Color 5 ED `color-mix()` forms and `display-p3-linear` are rejected. P2-7 x/y/z analogs and analogous sets are not carried. P2-8 powerless epsilons. P2-9 `hsl()` clamps S > 100% and L. P2-10 `to_gamut` early exit. P2-11 `color-mix()` missing hue and zero-alpha rules. P2-12 hues ≥ 2^52·360 normalise to 0. P2-13 README/process claims. P2-14 WCAG helpers ignore alpha. |

`run_audit.sh` exits **0** on the baseline (`AUDIT PASS (0 P0)`, with OPEN lines for P1-1, P1-2 and P2-1…P2-14). `STRICT=1 sh packages/css_color/audit/run_audit.sh` exits **1**.

**Contradiction with the brief.** The brief says `0% + 0%` "必须报错". The CSS Color 5 ED changes list says *"Remove the 'invalid if sum to zero' wording for color-mix(), per WG resolution"* and *"if the percentages sum to zero, return transparent"*. The pinned WPT vectors expect, for example, `color-mix(in srgb, color(srgb .1 .2 .3) 0%, color(srgb .5 .6 .7) 0%)` → `color(srgb 0.3 0.4 0.5 / 0)`, and Chrome 159 accepts it. css_color still rejects it, as its own test `src/css_color_test.pion:473` requires. The audit therefore reports the rejection as non-conformant (P2-6) rather than as a control. The brief's other syntax expectations all match the package and WPT: comma/space mixing, `rgb(255, 50%, 0)` rejected, `rgb(255 50% 0)` accepted, non-ASCII whitespace, `>100%` / negative mix percentages, and invalid channel names.

### What holds (measured, all 4 modes)

- **Static red lines** (`portability`): 0 `extern "C"`, 0 `World`, 0 imports, 0 `[dependencies]`, 0 module-level `let mut`, 0 module-level containers. The 10 module-level `let`s are all `Double`/`Int` scalars. `parse(..)`'s `Result`, `Color`, `ColorSpace` and `HueInterpolation` all compile across a `spawn` boundary (`Send`).
- **Determinism** (`determinism`): every corpus, gamut mapping, DoS bomb and the API sweep is byte-identical across the 4 modes. Doubles are compared as IEEE-754 bits (see toolchain note T-1). `wasm_smoke` prints the README line in all 4 modes, with SHA-256 `74a74237…` = README.
- **Named colors**: all 148 + `transparent` are correct in lower, UPPER and mIxEd case, with leading/trailing `\t\n\r\f` and space. NBSP, `\v`, U+3000, U+FEFF, U+2028, U+0085 and NUL are rejected anywhere (Chrome agrees, 796/796). `currentcolor`, system colors and CSS-wide keywords are rejected by design (out of scope).
- **Syntax matrix** vs Chrome (`syntax` 1 117 inputs):
  - Legacy/modern separation is exact: `rgb(255, 0 0)`, `rgb(255, 0, 0 / 0.5)`, `rgb(255 0 0, 0.5)`, `rgb(255, 50%, 0)`, `hsl(120, 100, 50)`, `none` in legacy, wrong arity, units, trailing garbage, `rgb (`.
  - Every angle unit, with negative and large (< 2^52 turns) angles, normalises like Chrome.
  - All 9 `color()` spaces with `%`, `none` and alpha forms are accepted; unknown spaces are rejected.
  - The only divergences are P2-4/P2-5 (`calc()`), P2-12 (1e300rad, ill-conditioned) and unclosed `(` at EOF. CSS auto-closes the latter; rejecting it is a reasonable library choice.
- **Numeric accuracy**:
  - `color =0.3.3` (f32): 6 000/6 000 random colors in 14 source forms × 14 target spaces agree to 3.1e-5 of the range; named and hex agree to 1e-7.
  - Chrome: 6 000/6 000 within its float32 tolerance.
  - `spec_ref.py` (`compare.py spec … auto`): **every target ≤ 1e-9** (sRGB/P3/a98/rec2020/XYZ/Oklab ≈ 1e-13; Lab/LCh ≈ 1e-12). The gate first uses the ED's constants; if they fail, it retries with css_color 0.1.0's pre-2023 Bradford and/or ProPhoto constants and routing. Passing only with old constants means P2-2; failing with every set is a P0 math error. It also accepts an origin normalised the ED's powerless way, which is what a P2-8 fix does, and reports P2-8 while a build does not do it.
  - The sRGB, Display-P3, A98, Rec.2020 and Oklab matrices equal the ED's rational matrices to ≤ 2.2e-16.
- **`color-mix()`**:
  - All 14 spaces and 4 hue modes are covered, crossing 0/360, exactly 180° apart (shorter goes increasing, as the ED specifies), one or both hues `none`, alpha `0`/`none`, and percentage normalisation (`< 100%` alpha multiplier, `> 100%` scaling, one or both omitted, `-10%` / `150%` rejected).
  - Every divergence from Chrome/WPT is P2-6/7/8/11 or Chrome noise (below).
  - Versus `color 0.3.3`, 685/752 mixes agree to 2e-3. The rest are P2-11 or `color`'s own gaps: no `none`-alpha carry and f32 powerless thresholds. This comparison is informational.
- **Relative colors / `calc()`**:
  - Channel keywords work in any case (`R G B`).
  - Invalid channel sets (`rgb(from red l c h)`) are rejected.
  - Precedence and parentheses are correct: `2 + 3 * 4`, `(2 + 3) * 4`, `64 / 4 / 2`.
  - Unbalanced parentheses and empty `calc()` are rejected.
  - Division by zero and NaN never reach a color: they are rejected (P2-5 describes what CSS does instead).
  - `calc()` results that overflow are rejected as `NonFiniteValue`.
- **DoS** (`dos`, 228 bombs + all 145 prefixes of a nested expression, native and wasm32): no crash; worst 0.27 ms natively.
  - Nesting: `color-mix` 32 levels OK, 33/64/600 levels `MaxDepthExceeded`. Full binary `color-mix` trees of depth 1–9 grow linearly in time per byte; depth 10 exceeds 16 KiB.
  - `calc()`: parenthesis/`calc()`/unary bombs up to 5 000 deep; 4 000 terms.
  - Numbers and length: 10 000 / 16 000 × `9`, `0.(10 000 zeros)1`, `1e9999`, `1e-9999`, a 5 000-digit exponent; 16 384 B accepted, 16 385 B and 1 MiB rejected.
  - Garbage and extremes: NUL, invalid UTF-8, lone-surrogate bytes, overlong NUL; gamut mapping of `oklch(0.5 1e300 30)`, `lab(50 1e300 0)` and `color(xyz 1e300 …)`.
- **API sweep** (`api`): `Color::new` in all 14 spaces with {0, −0, ±1e-12, 5e-324, 0.5, 1, 100, ±360, ±1e6, ±1e300, NaN, ±Inf} in every channel goes through `convert` × 14, `to_gamut` (sRGB, P3), `to_rgba8`, `to_rgba8_clamped`, `to_css`, `to_hex`, `relative_luminance`, `contrast_ratio` and `mix` × 14 (32 368 calls).
  - No hang, no trap. Every `to_rgba8` value is within 0..255, and no `nan`/`inf` text appears in `to_css`.
  - Non-finite coordinates come only from overflowing inputs (|v| ≥ 1e300; 664 calls); none come from |v| ≤ 1e6.
- **Gamut mapping** (`gamut`, 1 424 origins → sRGB, P3, rec2020, a98, ProPhoto, sRGB-linear, hsl, hwb):
  - Every result is in gamut, and in-gamut origins come back bit-identical.
  - L ≤ 0 maps to black and L ≥ 1 to white; chroma never increases.
  - The brief's cases `oklch(0.7 0.4 150)`, `color(rec2020 1 0 0)` and `color(display-p3 0 1 0)` are mapped.
  - ΔE_OK to the ED algorithm (float64) is ≤ 0.0005 for 1 423/1 424 cases. The exception is P2-10.
- **WCAG**: `relative_luminance` matches the WCAG 2.1 formula to 1e-12 for 2 024 in-gamut sRGB colors; contrast(white, black) = 21, contrast(white, `#767676`) = 4.54.
- **Bench** (`bench`, shipped `run_bench.sh` re-run):
  - stdout SHA-256 is identical across implementations and rounds, with warmup 1 and 5 rounds.
  - Measured speed-ups 0.44x (README 0.46x) and 0.28x (README 0.28x), so the README's statement that Pion is 2.2x / 3.6x **slower** than `color 0.3.3` is honest.
  - Both sides do the same work (parse + sRGB convert + clamp), and an accumulator printed to stdout prevents dead-code elimination. Pion computes in f64 and `color` in f32, as the README states.
  - The shipped differential oracle reproduces its README numbers (2 562 = 2 042 + 360 + 160 cases).
- **Harness** (`harness`): 5 bugs injected into copies of the package are each caught.
  - `coral` 80 → 81: caught by Chrome named, relative and WPT.
  - Shorter-hue branches swapped: caught by Chrome mix and WPT.
  - Depth guard ×1000: caught by the DoS verdicts and `control_dos_guards`.
  - sRGB matrix coefficient +1e-6: caught by WPT and the `spec_ref` math gate.
  - Legacy number/percentage mixing allowed: caught by WPT.

### Oracles and how divergences are attributed

- **WPT** (`diff/wpt/`, `PINNED`): `extract.mjs` evaluates the inline scripts of 29 `css/css-color/parsing/*.html` files at the pinned commit with recording stubs. This expands the template loops into 11 654 (kind, specified, expected) vectors. Expected serializations are compared with WPT's own fuzzy epsilon (0.01, or the test's) after converting css_color's result into the expected color space. `none` must match when the spaces are equal.
- **Headless Chrome 159** (`diff/chrome/*.txt`, recorded with `REFRESH_CHROME=1`; `*.sha256` pins the corpus each golden file belongs to): validity comes from `CSS.supports('color', x)` and the value from computed `color`. The tolerance is 2e-3 of the range (0.02% for 0..100/360 ranges), relative 0.3% outside the reference range, and ±0.5/255 for legacy `rgb()`.
  - Chrome itself disagrees with **625 of the 11 654** WPT vectors (powerless 251/570, none 251/678; `compare.py chromewpt`).
  - Two Chrome-side effects are therefore classed as oracle noise and listed, not hidden:
    - `ORACLE-chrome-powerless` (82): polar mixes or relative colors of near-achromatic inputs, where Chrome keeps float32 noise hues that the ED makes powerless;
    - `ORACLE-chrome-a98` (52): Chrome's a98-rgb path is off by up to 0.0064. `color(from red a98-rgb r g b)` gives `g = −0.0064` in Chrome, while the exact answer is 0 because red is an a98 primary; css_color matches `spec_ref` to 1e-15.
  - `ORACLE-ill-conditioned` (9): angles of 1e300rad/grad, where the double rounding of the unit conversion exceeds 360°.
  - `ORACLE-chrome-color-mix-arity` (0 on the baseline): well-formed single-colour and N > 2 `color-mix()`, which the CSS Color 5 ED grammar (`[ <color> && <percentage>? ]#`) and the pinned WPT vectors accept. WPT also gives their computed values, e.g. `color-mix(in srgb, red, green, blue)` → `color(srgb 0.333333 0.16732 0.333333)`. Chrome 159 rejects them; it still implements exactly two colors.
  - `ORACLE-wpt-rec2020` (2 WPT vectors): the 2025 ED and WPT moved rec2020 to BT.1886 gamma 2.4. Chrome 159, `color 0.3.3`, `spec_ref.py` and css_color keep the BT.2020 piecewise OETF, so this is an oracle disagreement, not a finding. It is explained by the last fix-model stage. `ORACLE-chrome-rec2020-pre-ED` (0 on the baseline) covers the opposite choice against the Chrome golden.
- **Rust `color =0.3.3`** (`diff/oracle`, locked): a parse + convert oracle in f32. It parses neither `color-mix()`, relative colors nor `calc()`, and lacks the 7 `grey` aliases.
- **`diff/spec_ref.py`**: a float64 port of the ED sample code. Matrices are derived from the primaries and white points with rational arithmetic, and match the ED's printed values. It also contains the ED gamut-mapping algorithm and the WCAG formula.
- **Fix model** (`diff/fixmodel.py`): 8 cumulative candidate fixes applied to copies of `src/`, one per value finding (P1-1, P2-8, P1-2, P2-7, P2-11, P2-12, P2-9, P2-2), plus the oracle stage `ORACLE-wpt-rec2020`.
  - On a tree that is already (partly) fixed, a patch whose original snippet is gone is skipped. A stage that then fails to compile is reverted to the previous stage's source and binary, so the fix model never causes a P0. The `build` section prints `patches applied / reverted` per stage.
  - The harness has alternative injection points for each bug. It needs at least 3 of the 5 to be injectable.
  - A value divergence is attributed to the first stage that makes css_color agree with the oracle, and only if the audited build's output equals the fix model's base output (so an injected bug cannot be "explained" away).
  - Acceptance divergences are attributed by narrow patterns (`compare.py classify_accept`).
  - Applying all 8 stages: WPT passes go from 9 849 to 10 349, the package's own 32 tests still pass, and red-team cases P1-1, P1-2, P2-2, P2-7, P2-8, P2-9, P2-11 and P2-12 flip to PASS. The remaining WPT gaps are the acceptance findings P2-4/5/6 and out of scope.
- **Out of scope** (counted, not findings): `currentcolor` (44 WPT), system colors, CSS-wide keywords, `var()`/`env()` (28), `light-dark()`/`contrast-color()`/`alpha()` (2), math functions other than `calc()` (`sign`, `abs`, `min`, …, 168), length units inside `calc()`, CSS comments/escapes (5), and an unclosed `(` at end of input. The README documents `calc()` as `+ - * /` with parentheses.

## Findings

Severity follows the trigger: P1 = wrong visible output for ordinary, valid input; P2 = spec edge cases, newer-ED features, doc claims. Each has a `redteam_*` case that fails while it is open (`src/cases.pion`, also run by `pionc test` through `redteam_test.pion`).

### P1-1 — HSL/HWB conversion of near-white / near-black colors explodes (`space.pion:428-463`, `:497`)

- **Cause**: `srgb_to_hsl` computes `s = d / (1 - |2l - 1|)` and treats only `denom == 0.0` as achromatic. The hue is powerless only when `|s| < 1e-7`.
  - White or black reached through a conversion (`lab(100 0 0)`, `lch(100% 0 0)`, `oklab(1 0 0)`, `color(display-p3 1 1 1)` → sRGB ≈ 0.99999999…) gives `denom ≈ 1e-9`, so the saturation is in the hundreds of percent and the hue is noise.
  - The ED `rgbToHsl` sets `sat = 0` when `|L| ≤ 1e-5` or `|1 − L| < 1e-5`, and makes the hue powerless when `sat ≤ 1e-5`.
  - `srgb_to_hwb` likewise needs `W + B ≥ 99.999`; css_color uses `100 − 1e-7`.
- **Impact** (default configuration, any caller):
  - `lab(100 0 0).convert(Hsl)` = `hsl(91.76 848.95% 100%)`, and `to_css()` writes that string.
  - `color-mix(in hsl, lab(100 0 0), blue)` = `hsl(165.9 474.5% 75%)` (sRGB `0.296 0.887 1.204`). WPT expects `color(srgb 0.625 0.625 0.875)`. `color-mix(in hwb, lch(100% 0 0), blue)` fails the same way.
  - `hsl(from lab(…) h s l)` and relative HWB inherit the problem.
  - 9 WPT vectors fail; Chrome 159 has the same bug and also fails them.
- **Fix** (fix-model stage 1): add the ED guard to `srgb_to_hsl`, and use `white + black >= 100 - 0.001` in `srgb_to_hwb`.
  - Side effect: none on in-gamut colors with real saturation. All 32 own tests still pass.
- **Case**: `redteam_p1_1_hsl_near_white_black`.

### P1-2 — relative-color channel keywords drop `none` and powerless hues (`parser.pion:272-287`, `:479-489`)

- **Cause**: `CalcEnv` stores only values. `parse_component` returns `(v, false, false)` for a keyword, so a component that is missing in the origin, or made powerless by the conversion into the relative space (`rect_to_polar` returns `hm`), becomes `0`.
  - The CSS Color 5 ED changes list says *"Clarified that component keywords can return none as well as a number"*.
  - WPT `color-computed-none.html` and `-powerless.html` expect `none` (e.g. `hsl(from hsl(none 50% 50%) h s l)` → `hsl(none 50% 50%)`; `lch(from hwb(180 100% 25%) l c h)` → `lch(82.04 0 none)`).
  - Chrome agrees: `oklch(from white l c h)` → `oklch(0.999994 0.0000498 none)`.
- **Impact**: the derived color carries hue 0° (red) instead of a missing hue. Any later interpolation then swings through red. This is the design-token pattern `oklch(from <gray> l c h)`:
  - `color-mix(in oklch, oklch(from #808080 l c h), oklch(0.7 0.2 140))` → css_color hue **70°**; Chrome/WPT 140°.
  - `color-mix(in oklch, oklch(from white l c h), blue)` → 312° (purple) instead of 264.05°.
  - Alpha `none` is lost the same way.
  - 335 WPT vectors; 99 + 26 Chrome-corpus cases.
- **Fix** (stage 3, ~30 lines): carry `m0 m1 m2 ma` in `CalcEnv` (`with_missing`, `lookup_missing`) and return the missing flag when a component is exactly a channel keyword. Inside `calc()` a missing value stays 0, as the ED says.
- **Case**: `redteam_p1_2_relative_keywords_keep_none`.

### P2-1 — `to_css()` fidelity (`format.pion:78-116`)

- **Cause**: `format_num` computes `floor(|v| * 1e6 + 0.5).to_int64()`. That saturates for |v| ≥ 2^63/1e6 ≈ 9.22e12, so every such value is written as `9223372036854.775807`. NaN and ±Inf are written as `0` without notice. 22 syntax-corpus inputs are affected, e.g. `color(srgb 1e13 0 0)`; Chrome serializes `1.00000e+13`.
- **Also**: an out-of-range Lab/Oklab L (reachable through `convert`) is serialized as `lab()`/`oklab()`, and an HSL L outside 0..100 (relative colors such as `hsl(from color(display-p3 1 0 0) l h s)`) as `hsl()`. Both forms clamp L when re-parsed. A lossless form (e.g. `color(srgb …)`) is needed for such values.
- Everything else round-trips: 6 000/6 000 numeric colors, and every in-range WPT result.
- **Fix**: exponent notation for large magnitudes, and an explicit choice for non-finite values (`calc(infinity)` like Chrome, or an error).
- **Case**: `redteam_p2_1_to_css_fidelity`.

### P2-2 — constants and transfer functions vs the current ED (`space.pion:83-115`, `:221-253`, `:57-79`, `:742-745`)

- **Bradford D65↔D50** is the pre-2023 matrix (max difference 7.7e-8). The ED's values equal the first-principles derivation in `spec_ref.py`.
- **The ProPhoto RGB matrices** are the old ones (8e-6). With the ED's constants, conversions from ProPhoto move by up to 1.6e-4 of the range (sub-LSB in 8-bit).
- **D50↔D50 conversions** (Lab↔ProPhoto, LCh↔XYZ-D50) round-trip through D65 with two matrices that are not exact inverses, adding ~1e-6.
- 2 WPT vectors (`lch(from hwb(180 99.96% 0%) l calc(c * 1000) h)`, `color-mix(in oklch, lch(20 0.00151 180), …)`) are this drift amplified, and are attributed to the P2-2 stage.
- **rec2020** is not part of P2-2. The 2025 ED defines its transfer as BT.1886 gamma 2.4, but css_color correctly keeps the BT.2020 piecewise OETF, like Chrome 159 and `color 0.3.3`. The 2 WPT vectors that follow the new ED are classed `ORACLE-wpt-rec2020`.
- The README's "exact §18 matrices, exact Bradford" claim is not accurate.
- **Case**: `redteam_p2_2_ed_matrices`.

### P2-3 — token boundaries (`parser.pion:538-545`, `:577`)

- `#fffr` is one hash token, and an invalid color. css_color reads `#fff` and lets `r` become a channel keyword, so `rgb(from #fffr g b)` = white.
- `from#f00` is valid CSS (an ident followed by a hash), but css_color requires whitespace after `from`.
- **Case**: `redteam_p2_3_token_boundaries`.

### P2-4 — `calc()` accepts invalid input (`parser.pion:291-439`)

Inputs that CSS Values 4 and Chrome reject:
- binary `+`/`-` without surrounding whitespace (`calc(1+2)`, `calc(r -10)`);
- unary minus on an identifier or parenthesis (`-r`, `-(r)`, `- r`; `-r` is an identifier in CSS);
- number⊕percentage and number⊕angle mixes in relative colors (`calc(r + 10%)`, `calc(h + 30deg)`, since channel keywords are numbers);
- `%` for a hue (`hsl(calc(50%) …)`);
- `calc(50%)` hiding legacy number/percentage mixing.

There are 56 such inputs in the Chrome corpus and 20 in WPT. **Case**: `redteam_p2_4_calc_too_lax`.

### P2-5 — valid `calc()` and number edge cases rejected (`parser.pion:228-239`, `:348-350`, `:475`, `:1122-1133`)

Inputs that are valid CSS but rejected (170 WPT vectors, 30 corpus inputs):
- division by zero, `NaN` and `infinity` (CSS Values 4 §10.9: NaN → 0, infinities clamp; WPT `color(srgb calc(0 / 0) 0 0)` → `color(srgb 0 0 0)`);
- out-of-range literals (`rgb(1e309 0 0)`, 10 000 × `9`), which CSS clamps;
- `calc()` percentages in legacy `hsl(120, calc(50%), 50%)` (the result is not flagged as a percentage);
- `calc()` in `color-mix()` percentages.

The rejection is safe, since nothing non-finite ever reaches a `Color`. **Case**: `redteam_p2_5_calc_and_numbers_too_strict`.

### P2-6 — CSS Color 5 ED `color-mix()` and CSS Color 4 ED spaces (`mix.pion:107-110`, `parser.pion:1171-1224`, `:1041-1053`)

Valid per WPT and Chrome 159, rejected by css_color:
- percentages summing to `0%` (transparent result; the brief's "must error" predates the WG resolution, see above);
- a missing interpolation method (Oklab by default);
- a single color or N > 2 colors;
- `display-p3-linear`.

This is 868 WPT vectors. **Case**: `redteam_p2_6_css_color_5_ed_syntax`.

### P2-7 — analogous components and analogous sets (`space.pion:629-687`)

- The ED table lists *Reds r,x / Greens g,y / Blues b,z*; `channel_category` gives XYZ no analogs. As a result, `color-mix(in xyz, color(srgb none 0 0), blue)` interpolates x from 0: css_color gives x = 0.090, Chrome 0.1805.
- Analogous sets ("the components that remain after removing all analogous components") are not implemented. For example `oklab(0.1 none none)` mixed in Oklch should carry `c` and `h` as missing.
- 116 WPT + 64 Chrome-corpus divergences. **Fix**: stage 4. **Case**: `redteam_p2_7_analogous_components_and_sets`.

### P2-8 — powerless-hue thresholds (`space.pion:401`, `:459`, `:497`, `:612/621/719/727`, `:690`)

- The ED tables give: hsl S ≤ 0.001 (percent), hwb W + B ≥ 99.999, lch C ≤ 0.0015, oklch C ≤ 4e-6.
- css_color uses S < 1e-7 (fraction), W + B ≥ 100 − 1e-7, C < 1e-4, C < 1e-6, and applies them only after a conversion, never to the origin.
- Example: `color-mix(in lch, hsl(180 0.001% 50%), lch(11 33 44))` → hue 121.7°; WPT 44°.
- 15 WPT + 9 Chrome-corpus divergences. **Fix**: stage 2 (thresholds plus `powerless_normalize` before `convert`). **Case**: `redteam_p2_8_powerless_epsilons`.

### P2-9 — `hsl()` parse-time clamping (`parser.pion:790-832`)

The ED clamps only a negative saturation. css_color also clamps S to ≤ 100%. For example, `hsl(120 550% none)` gives S = 100; Chrome gives `hsl(120 550% none)`. Relative HSL results with S > 100% therefore do not round-trip through `to_css()` (103 round-trip failures). Chrome 159 does clamp L to [0, 100], and no WPT vector disagrees, so the fix model keeps that clamp. Chrome is not consistent here: it keeps S > 100% in `hsl()` serializations, but clamps S when resolving to sRGB (`hsla(1209 110% 20%)` → `rgb(0, 102, 15)`). The Chrome comparison therefore treats S > 100% as `ORACLE-chrome-hsl-s-over-100`, while the ED text, which the red-team case follows, clamps only negative S. **Case**: `redteam_p2_9_hsl_parse_clamping`.

### P2-10 — `to_gamut` deviations from ED §13.2 (`space.pion:803-869`)

- When the first out-of-gamut candidate is already within `eps` of the JND, the `break` at `:844-846` leaves `min_in_gamut = true`. Lines `:855-860` then return the last in-gamut chroma instead of `clipped`. Example: `oklch(0.90244 0.39113 249.065)` → a98-rgb, ΔE_OK 0.015 from the ED result.
- The ED's step 11 shortcut (return `clip(origin)` when ΔE_OK < JND) is missing.
- `eps` is 1e-5 instead of 1e-4.
- The loop is capped at 64 iterations, so chroma ≥ ~1e14 never converges. This only shows on absurd inputs.
- `gamut.py` ports css_color's loop and the corrected loop and checks both reproduce their sides. **Case**: `redteam_p2_10_gamut_map_early_exit`.

### P2-11 — `color-mix()` missing-hue and zero-alpha rules (`mix.pion:60-76`)

- A missing hue returns the other hue directly, skipping the hue fix-up. The ED fills it in *before* the fix-up, so `longer` with an achromatic side must go the long way round. Example: `color-mix(in hsl longer hue, red, white)` → css_color `(0.875, 0.625, 0.625)`; WPT `(0.625, 0.875, 0.875)`.
- When the interpolated alpha is 0, css_color returns the unpremultiplied average; WPT expects 0 (e.g. `color-mix(in srgb, color(srgb -2 -3 -4 / -5), …)` → `color(srgb 0 0 0 / 0)`).
- 21 WPT + 51 Chrome-corpus divergences. **Case**: `redteam_p2_11_mix_missing_hue_and_zero_alpha`.

### P2-12 — huge hue normalisation (`math.pion:87-97`)

`f64_rem_euclid` relies on `f64_floor`, which returns its argument unchanged for |x| ≥ 2^52. The remainder `x − floor(x/m)·m` then degenerates and the guard returns 0. So `hsl(1e20deg 50% 50%)` gets hue 0; Chrome gives 280°. An exact binary fmod fixes it (stage 6). **Case**: `redteam_p2_12_huge_hue_normalisation`.

### P2-13 — README / process claims

- "Complete W3C CSS Color 4 & 5" is contradicted by P1-1, P1-2 and P2-3…P2-12, and by the out-of-scope list.
- "Exact … matrices, exact Bradford" is contradicted by P2-2.
- The differential table is honest about its numbers, but its corpus is curated. It contains only inputs that `color 0.3.3` accepts: no rejection tests, no `none`, no relative colors, no `calc()`, and the 7 `grey` aliases are removed. Its "160/160 gamut" check tests only the in-gamut property, not ΔE against the ED algorithm.
- AGENTS.md 1.1 asks for the upstream suite to be ported. The package has 32 hand-written tests, while the pinned WPT `css-color/parsing` suite has 11 654 vectors (now available as `audit/diff/wpt/vectors.tsv`).
- The README wasm sizes are off by 76 B, because binaries embed absolute source paths (T-2). The check therefore allows ±0.2%.

### P2-14 — WCAG helpers ignore alpha (`format.pion:241-256`)

`relative_luminance()` and `contrast_ratio()` drop alpha, so `rgb(0 0 0 / 0)` vs white reports 21:1. WCAG does not define contrast for translucent colors. Either composite over a caller-supplied backdrop or document it. **Case**: `redteam_p2_14_wcag_ignores_alpha`.

## Toolchain observations (not css_color defects; for the Pion owners)

- **T-1**: `Double::to_string()` differs between native and wasm32 on shortest-digit ties. `9290347888448.8125` prints `9290347888448.812` natively and `9290347888448.813` on wasm32. css_color is not affected, because its own `format_num` uses integers. Any package that prints doubles with `to_string` is not 4-mode deterministic. The audit prints doubles as IEEE bits (`dbits`) for this reason.
- **T-2**: wasm32 binaries embed absolute source paths (`/Users/…/packages/css_color/src/format.pion`). Sizes therefore depend on the checkout path, and build paths leak into artifacts.

## Layout

| Path | Purpose |
|---|---|
| `run_audit.sh` | all sections; `STRICT=1` fails on open findings; `REFRESH_CHROME=1` re-records the Chrome golden files |
| `src/main.pion`, `src/cases.pion` | audit CLI (`run`, `gamut`, `time`, `api [dump]`, `list`, `case`) and the 15 red-team + 10 control cases |
| `control_test.pion`, `redteam_test.pion` | the same cases under `pionc test` |
| `diff/gen.py` | deterministic corpus: named, hex, syntax, none, mix (+ `mix.rust`), relative, numeric, fuzz, gamut |
| `diff/wpt/` | `extract.mjs`, `vectors.tsv` (11 654 WPT vectors), `PINNED` |
| `diff/chrome/` | Chrome 159 golden results per group, corpus SHA-256, `VERSION`; `diff/chrome.py` records them |
| `diff/oracle/` | Rust `color =0.3.3` oracle (locked) |
| `diff/spec_ref.py` | float64 ED reference (conversions, gamut mapping, WCAG) |
| `diff/compare.py`, `diff/gamut.py`, `diff/dos.py`, `diff/readme.py` | comparators and budgets, README claim parser |
| `diff/fixmodel.py` | the 8 candidate fixes used for attribution; a starting point for the fix branch |

## Re-audit of the fix branch `feat/pkg-css-color-fix` @ `576f406`

- I read the whole `576f406` diff (`src/{format,math,mix,parser,space,types}.pion`, `wpt_test.pion`, README) and found no new P0, P1 or P2.
- Run on the merged tree (fix sources + this `audit/`): `STRICT=1 sh packages/css_color/audit/run_audit.sh` → `AUDIT PASS (0 P0)`, 0 `OPEN`, exit 0.
  - WPT: 11 405 pass, 247 out of scope, 2 `ORACLE-wpt-rec2020`, 0 unexplained.
  - Chrome golden: 0 unexplained. The 5 accepted single-colour / N-ary `color-mix()` inputs are `ORACLE-chrome-color-mix-arity`, confirmed against the WPT expectations above.
  - The 5 injected bugs are all caught.
- Behaviour differences that remain, all non-blocking and spec-permitted:
  1. Infinite results are kept as such. `rgb(from red calc(r / 0) g b)` stores +∞ (`to_css` → `color(srgb calc(infinity) 0 0)`), and a literal `1e400` becomes ∞. Chrome clamps these two to float max (`1.33444e+36` / `3.40282e+38`), but Chrome itself keeps `oklch(0.5 calc(infinity) 30)` and gives `oklab(calc(NaN) …)` for `color-mix(in oklab, lab(50 1e400 0), blue)`. No trap, `to_rgba8` stays within 0..255, and `to_css` re-parses.
  2. Modern `hsl()` no longer clamps L, which follows the ED text. Chrome 159 clamps L, and no WPT vector covers it.
  3. `src/wpt_test.pion` ports 8 selected WPT-derived tests rather than all 11 654 vectors. The full pinned suite runs in `audit/`.
