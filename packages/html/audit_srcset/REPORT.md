# Red-team audit: `packages/html/src/srcset.pion` (WHATWG HTML §4.8.4.3 `srcset` / `<picture>`)

- Target: `origin/feat/enrich-url-html` @ `67385f72` — `parse_srcset`, `select_srcset_candidate`,
  `select_picture_source`, `is_supported_image_mime`.
- Oracle: `diff/ref/srcset_ref.py`, a line-by-line port of "parse a srcset attribute"
  (§4.8.4.3.10, spec fetched 2026-11-23) incl. the floating-point parsing rules; selection
  checked against "update the source set". 82 handpicked + 200,000 seeded fuzz inputs.
- Companion audit of `data.pion`: `packages/url/audit_data/REPORT.md`.
- Reproduce everything: `sh packages/html/audit_srcset/run_audit.sh` (writes only to `$AUDIT_OUT`).

## Summary

| ID | Sev | Finding | Evidence |
|---|---|---|---|
| S-1 | **P1** | `select_picture_source` picks a matching `<source>` whose srcset has zero valid candidates and returns `None` — no fall-through to later `<source>`s or the `<img>`; the whole `<picture>` shows no image. | 2 failing `redteam_*` tests |
| S-2 | **P1** | `select_srcset_candidate` is O(n²) (linear-scan dedupe + insertion sort): ~1.1 MB srcset with 100k distinct densities takes **20.2 s**; 100k widths 2.1 s. | `perf/dos_scaling.py`, `probe` (Native + wasm32) |
| S-3 | P2 | Numeric descriptor edges: `0x`/`-0x`/underflow dropped (spec keeps density 0), `>= 1e308x` dropped (spec: only ±2^1024 is an error), `>= 2147483648w` dropped. | 3 failing tests; all 92/200,082 differential mismatches are this class |

**No P0.** The tokenizer state machine matches the spec reference on every one of 200,082
inputs apart from S-3: commas inside URLs (`w_400,f_auto`), trailing/leading/repeated commas,
only-commas/only-whitespace, parenthesised descriptors (`(100w, 200w)`, unclosed `(`, nested
`((a))`), `0w`/`-100w`/`1.5w`/`+100w`, `NaNx`/`Infinityx`/`1e309x`/`-2x`, `w`+`x`, duplicate
`w`/`x`, `h` rules, uppercase units, VT not being whitespace. `parse_srcset` is linear on every
100k shape (commas, spaces, `(`, `)`, `()`, `a,`, ` 1x`, candidates) with 0 panic on Native and
wasm32; no recursion. Selection inputs `target_width <= 0`/NaN, `dpr <= 0`/NaN/+inf, empty
candidate lists, and MIME edge cases (case, params, `image/webp foo`, unsupported types) don't
panic and act sensibly.

## S-1 (P1) `<source>` with an empty source set is not skipped

`select_picture_source` (`src/srcset.pion:428-434`) returns
`select_srcset_candidate(parse_srcset(src.srcset), "", …)` for the first matching `<source>`
whose srcset is non-blank. When the parse yields **zero** candidates the result is `None` and the
loop stops. The spec (§4.8.4.3.5 *update the source set*, `<source>` children): "Parse child's
srcset attribute … **If source set has zero image sources, continue to the next child.**"

```
<picture>
  <source srcset="hero.avif 0w" type="image/avif">   ← invalid descriptor
  <source srcset="hero.webp 1x" type="image/webp">
  <img src="hero.jpg">
</picture>
Pion: None (no image)        spec/browsers: hero.webp
```
`[source(",,, ,"), source("a.webp 1x 2x")]` + `<img src=img.jpg>` → Pion `None`, spec `img.jpg`.
Fix: `if cands.length() == 0 { continue }` (advance `si`) before selecting.

## S-2 (P1) Quadratic selection — CPU DoS

`select_srcset_candidate` (`src/srcset.pion:326-418`) dedupes by scanning `dens` for each
candidate (O(n²) whenever densities are distinct) and then insertion-sorts (O(n²) for descending
input). `select_picture_source` calls it on raw attribute text, so one attribute is enough.

| shape (`select_srcset_candidate`; probe row via `select_picture_source`) | n | t(n) | t(4n) | ratio |
|---|---|---|---|---|
| distinct densities, descending `a0 Nx, a1 N-1x, …` | 25k | 1,335 ms | **20,194 ms** | 15.1 |
| distinct widths `a0 1w, a1 2w, …` | 25k | 121 ms | 2,051 ms | 17.0 |
| same density (dedupe hits at index 0) | 25k | 7 ms | 20 ms | 3.0 |
| in-process (probe), descending densities | 2.5k → 10k | native 13 → 195 ms, wasm32 19 → 293 ms | | 15 |

Parsing the same 100k-candidate attribute takes 6 ms (native) — the selector, not the parser,
is the hot spot. Fix: stable `O(n log n)` sort by density, then dedupe adjacent equal densities
keeping the earliest original index (or a `Map[Double, …]`).

## S-3 (P2) Numeric descriptor edges

| input | Pion | spec |
|---|---|---|
| `a.jpg 0x`, `0.0x`, `00x`, `-0x`, `1e-400x` | dropped | kept, density 0 ("If the result is less than 0, let error be yes"; spec notes density 0 ⇒ infinite natural size) |
| `a.jpg 1e308x`, `1.5e308x` | dropped (`v < 1.0e308`) | kept (finite; only values rounding to ±2^1024 are errors) |
| `a.jpg 2147483648w`, `99999999999999999999w` | dropped (Int32 guard) | kept |

Low impact (pages relying on these are unusual) but a conformance gap. A fix that keeps density 0
must keep `select_srcset_candidate` well-defined for it (it never divides by density today). Failing tests:
`redteam_zero_density_is_a_valid_candidate`, `redteam_large_finite_density_is_valid`,
`redteam_width_above_int32_is_valid`.

Observation (not a finding, selection is implementation-defined): with `target_width <= 0`/NaN
every `w` candidate gets density `1e6`, dedupe keeps only the first listed one — whatever its size.

## Commands

```sh
export PATH=$HOME/.pion/bin:$PATH
(cd packages/html && pionc test --json audit_srcset)       # 5 FAIL (findings), 6 pass (controls)
sh packages/html/audit_srcset/run_audit.sh                 # tests, 200k differential, Native+wasm32 probe, DoS scaling
QUICK=1 sh packages/html/audit_srcset/run_audit.sh         # 20k fuzz, skip DoS scaling
```

## Files

- `redteam_test.pion`, `src/lib.pion` — unit tests (`redteam_*` fail = finding, `control_*` pass).
- `diff/ref/srcset_ref.py` — spec port; `diff/cases.py`, `diff/pion/`, `diff/compare.py` — differential.
- `probe/` — in-process no-panic/DoS probe, built for Native and wasm32.
- `perf/dos_scaling.py` — n vs 4n scaling over 10 shapes.
