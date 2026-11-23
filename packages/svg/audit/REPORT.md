# Red-team audit: `packages/svg` (`feat/pkg-svg` @ `4f97bad`)

Scope: `packages/svg/src/**` (path, math, geometry, transform, color, dom, optimize), the 4-mode `wasm_smoke`, and `packages/svg/bench/**`.
References: Rust `svgtypes =0.15.3`, `roxmltree =0.20.0`, `kurbo =0.11.3` (pinned in `oracle/Cargo.lock`, built with `--locked`), platform libm, independent Python references (W3C SVG 1.1 F.6.5/F.6.6 arc parameterisation, exact cubic extrema, dense Gauss-Legendre arc length, CSS Color 4 `hslToRgb`, SVG 2 §8.2 viewBox equations), CPython expat for optimizer output, and `svgo@3.3.2` (bench lockfile) for optimizer semantics.

Reproduce everything: `sh packages/svg/audit/run_audit.sh` (about 40 s on an M-series Mac; `QUICK=1` for a smaller run). Artifacts go to `/private/tmp/rt-svg-audit` (override with `AUDIT_TMP`). The script exits 1 while any finding below is open. A fix branch that leaves `audit/` byte-identical and fixes every finding exits 0: every check encodes the spec/oracle expectation, not the current Pion output.

## Summary

| Severity | Count | Theme |
| --- | ---: | --- |
| P0 | **0** | No crash, signal, wasm trap, OOM, hang, or XML injection. 14 adversarial probes × 4 build modes all exit 0, with byte-identical stdout across modes. |
| P1 | **6** | `flatten_path` breaks its tolerance contract (up to 3.99×). `optimize_svg` changes rendered text in three ways (whitespace, `&#233;` double-escaping) and changes rendering in two more (`<switch>`, animated `<g>`). `format_path` writes `inf`. |
| P2 | **21** | Number parsing is not correctly rounded and mishandles exponent range. Trig loses precision at large angles. bbox and length are not scale invariant. XML well-formedness and namespaces, CSS cascade details, and shape/viewport semantics have gaps. There are smaller optimizer issues and a quadratic `<g>` re-scan. |

Final `run_audit.sh` ledger at `4f97bad`: **P0 3 PASS / 0 FAIL, P1 18 PASS / 20 FAIL, P2 3 PASS / 66 FAIL, controls 25 PASS / 0 FAIL**. Several checks cover each finding: unit tests plus differential checks.

4-mode result: `native_rel`, `native_dbg`, `wasm_rel` and `wasm_dbg` (executed under node with `pion_wasm_rt.mjs`) are byte-identical on 9 corpora (path 3,097, geom 449, fmt 675, rot 2,010, color 648, xml 61, extract/opt/optc 361 records each, including 300 bench icons). There are 0 traps. `.to_int()` on NaN, ±Inf and 1e300 saturates identically on native and wasm32 (`clamp_u8_f64`, `reduce_angle`, `format_compact_number` were probed with `rgb(1e300,…)`, `rotate(1e300)`, arcs between ±1e308 and `transform_path` by `matrix(1e300 …)`).

---

## P1 findings

### P1-1 `flatten_path` exceeds the requested tolerance by up to 4×
- Repro: `flatten_path(parse_path("M0 0C10 20 30 20 40 0"), 0.25)`. The polyline is 0.925 away from the curve (3.70× tol). Over the geom corpus, 1,271 of 1,549 paths violate the tolerance, with a worst ratio of **3.99×**. Test: `p1_flatten_path_respects_tolerance*`; check: `geom_check.py`.
- Contract: README §3 says "within geometric tolerance `tolerance`". kurbo `flatten` and lyon both guarantee the bound.
- Root cause: `geometry.pion:217` computes `tol16_sq = (16*tol)^2`. The Willcocks/Hain bound (max distance ≤ ¼·max(|3P1−2P0−P3|, |3P2−P0−2P3|)) needs `16*tol^2`, so the test admits curves 4× too far from their chord. The comment at line 179 carries the same transcription error. A second issue is that `f.depth >= 18` (`:297`) silently emits a non-flat piece instead of reporting it, for example with tol 1e-9 at 1e12 coordinates.

### P1-2 `optimize_svg` (and `parse_svg`) destroy significant whitespace in text
- Repro: `<text>Hello <tspan>World</tspan> again</text>` becomes `<text>Hello<tspan>World</tspan>again</text>`, which renders "HelloWorldagain". `<tspan>a</tspan> <tspan>b</tspan>` renders "ab". With `xml:space="preserve"`, `"  two  spaces  "` becomes `"two  spaces"`. svgo 3.3.2 keeps all three (shown by `bench_fairness.py`). Tests: `p1_optimize_keeps_*`.
- Root cause: `dom.pion:472-473` drops whitespace-only text nodes at parse time, and `optimize.pion:207` writes `ascii_trim(node.text)`.

### P1-3 Character references ≥ U+0080 are not decoded, and `optimize_svg` double-escapes them
- Repro: in `parse_svg("<svg><text>caf&#233;</text></svg>")`, the text node is the literal `caf&#233;`; roxmltree gives `café`. `optimize_svg` then emits `caf&amp;#233;`, which renders as the visible characters "&#233;". The same happens to attributes: `aria-label="&#x2713; ok"` becomes `&amp;#x2713;`. `&#160;` (exported by Illustrator) and `&#x1F600;` are affected too. Tests: `p1_parse_svg_decodes_*` and `p1_optimize_does_not_double_escape_charrefs`.
- Root cause: `dom.pion:168` decodes a reference only when `cp > 0 && cp < 128` and otherwise keeps the raw text. A UTF-8 encoder is needed for code points up to U+10FFFF, and invalid ones (surrogates, 0, > 0x10FFFF) must be rejected.

### P1-4 `collapse_groups` unwraps `<g>` inside `<switch>`
- Repro: `<switch><g><rect/><circle/></g><g><rect/></g></switch>` becomes `<switch><rect/><circle/><rect/></switch>`. `<switch>` renders only its first conforming direct child, so the circle disappears. svgo `collapseGroups` returns early when the parent is `switch`. Test: `p1_optimize_does_not_unwrap_groups_inside_switch`.
- Root cause: `optimize.pion:214` collapses any attribute-less `g` without looking at its parent.

### P1-5 `collapse_groups` unwraps a `<g>` whose child is an animation element
- Repro: `<g><animateTransform …/><rect/></g>` becomes `<animateTransform …/><rect/>`, so the animation now targets the parent `<svg>`. svgo keeps such groups. Test: `p1_optimize_does_not_unwrap_group_with_animation_child`.
- Root cause: the same line, `optimize.pion:214`.

### P1-6 `format_path` / `optimize_svg` emit `inf`, producing invalid path data
- Repro: `format_path(parse_path("M0 0L1e306 1e307"), 3)` returns `M0 0 inf inf`, and `optimize_svg` writes `d="M0 0 inf inf"`. svgtypes rejects that string, so browsers drop the element. Tests: `p1_format_path_never_emits_inf`, `p1_optimize_huge_coordinate_keeps_valid_d`; checks: `fmt_check.py`, `dom_opt_check.py`.
- Root cause: `math.pion:408` checks `is_finite(v)` but not `v * scale` (`:419-423`). For |v| ≳ 1.8e308/10^p, `abs_scaled` is `inf` and the fallback `rounded.to_string()` (`:473`) prints `inf`. Non-finite inputs, for example from `transform_path`, are silently written as `0` (`:409`), which turns a geometry error into a different shape.

---

## P2 findings

| ID | Finding (minimal repro) | Expected (spec / oracle) | Root cause |
| --- | --- | --- | --- |
| P2-1 | **Number parsing is not correctly rounded and gets the exponent range wrong.** `-948.2166391075641` parses as `-948.216639107564`, 1 ulp off. On 20k fuzz paths, 12,794 differ from `f64::from_str` (1 ulp: 1,672; 2-16 ulp: 3,353; gross: 7,755). `0.000000000000000305655` parses as `3.05e-16` (0.2 % error). `1e-320` gives `1e-308`. `4.9e-324` gives `4.9e-307`. `1e309` and `1e400` are accepted as `1e308`, while `1.7976931348623157e308` (DBL_MAX) is **rejected**. | svgtypes: correctly rounded `f64::from_str`; ±inf is an error. | `math.pion:305-330` accumulates the mantissa in a double and counts leading zeros toward an 18-digit cap (`:318`). `pow10_f64` (`:266`) returns 1e308 for exponents above 308 and multiplies by repeated squaring. |
| P2-2 | **`path_bbox` is not scale invariant.** `M0 0C0 1e-13 1e-13 1e-13 1e-13 0` gives max_y `0`; exact and kurbo give 7.5e-14. Error is 0.75 of the extent. | Exact extrema at any scale. | `geometry.pion:25-26` uses absolute `1e-12` thresholds on the derivative coefficients. |
| P2-3 | **`path_length` uses an absolute tolerance floor.** `length(1e-9·C)·1e9` differs from `length(C)` by 4.3e-5 relative. The worst fuzz loop is 3.3e-6 relative (kurbo agrees with the Python reference to 1e-9). | Relative accuracy 1e-6 (the code's own criterion). | `geometry.pion:471` uses `1e-6*(1.0+whole)`; there is a depth cap at `:453`. |
| P2-4 | **Trig precision degrades with angle.** `rotate(1e6)` cos error is 1.08e-12 (at most 1e-15 for \|deg\| ≤ 720). `rotate(1e15)` cos is 0.17345 vs libm 0.17281. `rotate(≥1e18)` gives exactly cos=1, sin=0. | libm-accurate reduction (fdlibm `__rem_pio2`). | `math.pion:57-70` uses a 2-term Cody-Waite reduction plus a `floor(v/tau)` pre-reduction that cannot reduce large values. Note: `atan_f64` (`:117`) truncates at v^19 (about 5e-14 abs) and `acos_f64` (`:179`) uses `sqrt(1-x²)`, which cancels near ±1. The measured arc angle error stays at 2.7e-15 on the corpus, so this is recorded as a note only. |
| P2-5 | `parse_viewbox("0 0 0 10")` is accepted, and `viewbox_transform` then returns identity. | svgtypes rejects w ≤ 0 or h ≤ 0. In SVG 2 a zero size disables rendering. | `transform.pion:405` checks only `< 0`. |
| P2-6 | `parse_color("rgb(255,0,0,)")` gives `#f00`. | Error (svgtypes, CSS Color 4). | `color.pion:360/409`: `skip_color_sep` eats the comma, then `p3 == end` is treated as "no alpha". |
| P2-7 | **XML well-formedness gaps** (11 classes, all rejected by roxmltree): duplicate attributes, `<` in an attribute value, bare `&`, unknown entity `&nbsp;`, attributes with no whitespace between them, `</ g>`, two root elements, text after the root, undeclared prefix, `<!foo>`, and `--` inside a comment. `optimize_svg` silently rewrites such input into different, well-formed XML. | XML 1.0 §2-§4. | `dom.pion` scanner: no duplicate or separator checks, document-level content is unchecked, and `<!` with anything else is skipped as a declaration. |
| P2-8 | **Namespaces are not resolved.** `<svg:svg xmlns:svg="…/2000/svg"><svg:path d=…/>` produces 0 render paths; roxmltree resolves it. | Namespaces in XML. | `extract_render_paths` compares raw qualified tag names. |
| P2-9 | **CSS cascade details.** `style="/*x*/fill:red"` and `style="fill:red !important"` are ignored. `opacity=".5" style="opacity:.5"` gives `0.25`. `fill-opacity="50%"` gives `50`. `opacity="2"` is not clamped. | CSS Syntax: comments, `!important`. Style overrides presentation attributes. `<alpha-value>` takes `%` and is clamped to [0,1]. | `dom.pion:793-833` (naive `;`/`:` split) and `:736` (multiplies when it should override). |
| P2-10 | Shapes inside `<marker>` are extracted as ordinary render paths. | Markers render only at vertices. | `is_non_render_container` (`dom.pion:854`) has no `marker`. |
| P2-11 | **One bad element aborts the whole document.** `rotate(oops)`, `d="M0 0L2 2 X"`, or `points="0 0 10 10 20"` makes `extract_render_paths` return `Err` for all paths. | SVG 2: an invalid value affects only that element. A path renders up to its error, and an odd trailing polyline coordinate is ignored. | `dom.pion:910/921/929` use `return Err(e)`. |
| P2-12 | `<rect rx="auto" ry="5">` and `<rect rx="-3" ry="5">` produce sharp corners. | SVG 2 §10.2: `auto`, negative and invalid values resolve to `ry` (`A5 5`). | `dom.pion:561-566`. |
| P2-13 | Nested `<svg x y width height viewBox>` is handled as a plain `<g>`: no translate and no viewBox scale. | SVG 2 §8.2 new viewport. | Missing in `extract_render_paths`. |
| P2-14 | `optimize_svg` removes an empty `<g filter="url(#f)">`, which still paints (for example `feFlood`); svgo keeps `g[filter]`. | Keep it. | `is_empty_group` ignores attributes. |
| P2-15 | `optimize_svg` removes `<?xml-stylesheet …?>`. | Keep it: it is a stylesheet link, not the XML declaration. | `optimize.pion:85` treats every PI as `XmlDecl`. |
| P2-16 | **Relative-command rounding drift in `format_path`.** `M0 0` + 1000×`l.0004 0` ends at x=0 instead of 0.4. `h.0006`×500 drifts by 0.2. | svgo rounds relative coordinates against the rounded absolute position. | `format_path` rounds every relative number on its own. |
| P2-17 | `minify_colors` rewrites `rgba(255,0,0,.5)` as `#ff000080` and `hsla(…)` as `#00ff0040`. | SVG 1.1 renderers do not understand 4/8-digit hex. svgo `convertColors` leaves alpha colors alone. | `optimize.pion:42-59`. |
| P2-18 | Attribute values containing `&#10;`/`&#9;` are re-serialized raw, so every XML parser normalizes them to spaces (`a\nb\tc` becomes `a b c`). | Re-escape TAB, LF and CR in attributes. | `write_xml_escaped` (`optimize.pion:61`). |
| P2-19 | `Transform2D::scale(1e-8,1e-8).invert()` returns `None`. | Invertible (det = 1e-16). | `transform.pion:95`: absolute `det.abs() < 1e-15`. |
| P2-20 | With `max_path_segments = 1e9`, `to_cubic_beziers_with_limits` rejects a 2-segment path ("cubic expansion exceeds limit"). | No spurious limit. | `path.pion:565`: `max_path_segments * 4` overflows `Int`. |
| P2-21 | **Quadratic `optimize_svg` on deep `<g>` chains.** At depth 2,500 it takes 0.055 s; at 10,000 it takes 0.77 s (×14 for ×4 depth); at 20,000 it takes 3.1 s native and 5.2 s wasm32. This needs a raised `max_depth`; the default 128 keeps it bounded. | Linear. | `is_empty_group` re-scans the whole subtree for every `<g>` it visits, and again for every child check (`optimize.pion:92, 210, 277`). |

### Controls (Pion survived; must stay green)

- XML injection: attribute and text escaping of `" & < >` round-trips (checked by P0 checks and `control_optimize_escapes_attribute_and_text`). `javascript:` and `on*` are preserved verbatim. `optimize_svg` is not a sanitizer and does not claim to be one.
- DTD: billion-laughs and XXE entities are never expanded or fetched.
- The default `max_depth` (128), `max_elements`, `max_path_segments` and `max_flatten_points` all trigger cleanly. Tolerance ≤ 0 or NaN is rejected.
- Grammar: all 20 commands, implicit `L`/`l` after `M`/`m`, `Z` followed by relative commands (base = subpath start), compact flags `0110`, invalid flag `2`, and a first command other than M/m are handled. Form feed counts as whitespace and `1 , 1` is a valid flag separator (svgtypes gets both wrong; Pion is right).
- Arcs: rx/ry = 0 becomes a line, negative radii use the absolute value, coincident endpoints are dropped, F.6.6 radius scaling, rotations of 360000° and −720°, aspect ratio 1e6, and 1,500 fuzz arcs. All are within 2.7e-4·r radially and 2.7e-15 rad in angle of the F.6.5 reference.
- S/s and T/t reflection chains (after C/Q/T/L/A/Z) match the reference bit-for-bit, and kurbo bbox and perimeter agree on non-arc paths.
- `parse_transform` (6 functions, argument counts, separators) and its composition order match svgtypes. `viewbox_transform` matches SVG 2 §8.2 for 3 viewBoxes × 3 viewports × 10 aligns × meet/slice.
- Colors: all 148 named colors, and 3,000 random `hsl()` values match CSS Color 4 exactly.
- `optimize_svg` on 500 bench icons produces well-formed output with identical render paths.

---

## Benchmark fairness review (`packages/svg/bench`)

Measured by `scripts/bench_fairness.py` on the bench corpora (`gen_data.py`): median of 5 strictly alternating rounds on this machine.

| W1, 50k paths | ms | vs `rust_bench` |
| --- | ---: | ---: |
| Pion bench driver | 64.0 | 0.39× |
| `rust_bench` (svgtypes parser + hand-port of **Pion's** arc/bbox code) | 24.7 | 1.00× |
| Rust idiomatic upstream (`SimplifyingPathParser` → kurbo arcs → kurbo `bounding_box`) | 41.8 | 0.59× |
| Pion `parse_path` only | 36.6 | — |
| svgtypes `PathParser` only | 16.3 | — |

1. **W1 and W3a compare the same algorithm, not upstream libraries.** The Rust side re-implements Pion's arc-to-cubic, bbox and optimizer by hand (`rust_bench/src/main.rs`). Only parsing (svgtypes) and XML (roxmltree) come from upstream. That is a legitimate "same algorithm, other language" comparison, but it should not be labeled as svgtypes or roxmltree performance. Against idiomatic upstream Rust, Pion is 0.65× on W1, not 0.43×.
2. **The output-equality proof is weak.** W1 and W2 hash `Σ round(bbox·10)`, and W3a hashes the optimizer output of a hand-port with the same bugs. Equal SHA-256 only shows agreement to ±0.05 per coordinate. It would not catch any P1/P2 above: flatten and length are never run, and the corpora contain no text, entities, `<switch>` or animation.
3. **The corpora are narrow.** W1 cycles 4 templates with small integers and ≤ 2 decimals. That favors Pion's not-correctly-rounded number fast path (P2-1); a correct parser costs more. The W2/W3 icons all come from one template family.
4. **W2 is roughly balanced but not equal work.** Pion also resolves styles (`parse_paint` and others on every node), while roxmltree performs full well-formedness and namespace checks that Pion skips (P2-7/P2-8).
5. **The W3b "24.1× faster than svgo" claim is not a fair comparison.** svgo runs about 30 plugins, and its output differs (885,794 B vs 1,146,400 B), so the SHA-256 equality rule in AGENTS.md §1.3 cannot hold. Each round includes node start-up plus `import('svgo')`, which is **88 ms of the 523 ms** measured. svgo also preserves the semantics Pion breaks (P1-2 to P1-5): the script shows svgo's output for the same inputs. Recommendation: present W3b as a non-equivalent reference with no speed-up headline, or compare against an equivalent plugin subset with the process start-up subtracted.

### W1 optimization opportunities (phase split: parse 36.6 ms = 57 %, cubic/arc 18.3 ms = 29 %, bbox 8.2 ms = 13 %)
- Parsing is 2.25× slower than svgtypes. Add a streaming or visitor API (`parse_path_into` or a direct cubic normalizer) so the `Array[PathSegment]` of boxed 8-field variants is never materialized. Pre-size arrays from `d.length()`. Replace the 20-way `is_path_cmd` comparison chain with a 128-entry table.
- Use an exact fast number path (Clinger: ≤ 15 digits and |exp| ≤ 22 with an exact `10^k` table, falling back to Eisel–Lemire). It is faster than the `pow10_f64` loop and fixes P2-1.
- In `arc_to_cubics`, reuse `(cos2, sin2)` as the next segment's `(cos1, sin1)` to halve the trig calls, or rotate by a precomputed `(cos δ, sin δ)` so each arc needs only 2 trig calls. Replace `vec_angle`'s `acos` (an `atan` polynomial plus `sqrt`) with `atan2(cross, dot)`, which is cheaper and more accurate.
- In the bench driver, `split_lines` allocates all 50k substrings before the timed work starts.

---

## Files

| Path | Purpose |
| --- | --- |
| `run_audit.sh` | One-shot reproduction. Serial 4-mode build into `$AUDIT_TMP`, then steps 2-12. Exits non-zero while findings are open. |
| `redteam_test.pion`, `pion.toml` | 48 `p1_`/`p2_` unit tests (open defects) and 8 `control_` tests. |
| `probe/` | Pion batch probe (length-framed I/O): path, geom, fmt, color, paint, tf, rot, vb, par, vbt, len, xml, extract, opt, optc, `dos <kind>`, `w1`. |
| `oracle/` | Rust oracle: svgtypes 0.15.3, roxmltree 0.20.0, kurbo 0.11.3 and libm (`Cargo.lock`, `--locked`). |
| `scripts/path_diff.py` | Path grammar and number differential (20k fuzz). |
| `scripts/geom_check.py` | Arc F.6.5/F.6.6, reflections, bbox, length, flatten, and kurbo cross-check. |
| `scripts/attr_diff.py` | Transform, viewBox, preserveAspectRatio, trig vs libm, colors (148 names, CSS hsl), lengths. |
| `scripts/fmt_check.py` | `format_path` validity, rounding and drift. |
| `scripts/dom_opt_check.py` | XML vs roxmltree, entities, namespaces, optimizer semantics and safety, style cascade, 500 bench icons. |
| `scripts/dos.py` | 14 DoS/crash probes × 4 modes, and the depth-scaling check. |
| `scripts/wasm4.py` | 4-mode byte parity. |
| `scripts/bench_fairness.py` | Benchmark fairness measurements (informational). |
