# Red-team audit (RT-xpath): `packages/xpath` v0.1.0 (Pion W3C XPath 1.0)

Target: `AFK-surf/pion-packages` `origin/feat/pkg-xpath` @ `d017c40`, branch `audit/redteam-xpath`.
Nothing outside `packages/xpath/audit/` was changed (`src/`, `*_test.pion`, `bench/`, `pion.toml`,
`README.md`: 0 bytes).

| reference | version | used for |
| --- | --- | --- |
| W3C XPath 1.0 (REC-xpath-19991116) | — | normative expectations in every `p*_`/`control_` test |
| Rust `sxd-xpath` + `sxd-document` | **=0.4.2 / =0.3.2** (`tools/rust_oracle/Cargo.lock`, `--locked`) | differential oracle, DoS baseline, the shipped bench's baseline |
| libxml2 (system, `XML_PARSE_NOCDATA`) | 2.9.13 | second differential oracle, extra bench baseline |
| Python model of XPath §3.5/§4.2/§4.4 | `diff/gen_corpus.py` (`xp_number`, `xp_string`, `xp_round`, `math.fmod`) | ground truth for 2,700 number-fuzz queries |

Machine: Apple M5 Max (Darwin arm64), Apple Silicon arm64 Darwin, `pionc 0.1.0` (`AFK-surf/pion@66d2b4b`),
node 24.22 (wasm32 runtime), shared machine. Benchmarks are interleaved `scripts/bench_compare.py`
runs (warmup 1, 5 rounds, stdout SHA-256 identical across implementations).

## Reproduce

```sh
sh packages/xpath/audit/run_audit.sh                         # build, tests, diff, wasm, dos (gating, ~4 min)
SECTIONS="build bench" sh packages/xpath/audit/run_audit.sh  # benchmark fairness review (~4 min)
pionc test --json packages/xpath/audit                       # only the red-team tests (~5 s)
```

Everything built or generated goes to `$AUDIT_OUT` (default `/private/tmp/rt-xpath-audit`); the
worktree stays clean (`git status --porcelain --ignored` empty). **`run_audit.sh` exits 1 while any
defect below is present and 0 once all are fixed** — it gates on: every audit test passing,
native_rel matching the spec model on every number-fuzz query, 4-mode byte identity, and every
`dos/run_dos.py` verdict. A fixing branch re-runs it without editing `audit/`.

## Result summary

No P0 (no crash, no memory-safety issue, no wrong node-set from any of the 13 axes). The axis /
predicate / document-order core is solid: in the 9,000-query axis x node-test x predicate cross
product pion never disagreed with *both* oracles except where the oracles are themselves wrong
(see "Oracle disagreements"). The defects are in number semantics, in the resource-limit design,
and in the node-set comparison algorithm.

| id | sev | area | one-line |
| --- | --- | --- | --- |
| P1-1 | P1 | §4.2 number→string | exponent notation: `string(1e21)` = `1e+21`, `string(2^60)` = `1.1529215046068467e+18`, `string(0.0000001)` = `1e-07` |
| P1-2 | P1 | §4.4 string→number | not correctly rounded (`0.49999999999999994` → `0.5`, so `round()` → 1); a 310+ digit fraction → `NaN` |
| P1-3 | P1 | §3.5 `mod` | not IEEE remainder: `5.5 mod 1.1` = 0, `9031316886084362240 mod 7.5` = **-1024**, `-0 mod 5` = +0 |
| P1-4 | P1 | limits | `max_depth` hard-clamped to 128 and charged per left-nested operator: a 129+ term `or`/`+`/`\|` chain is rejected |
| P1-5 | P1 | limits | default `max_nodes` = 200,000 counts intermediate sets: `count(/r/e)` on a 1.2 MB doc and `count(//@k)` on a 2.1 MB doc fail; `xpath::eval*` cannot raise it |
| P1-6 | P1 | perf / DoS | node-set `=` node-set is O(n·m) with per-pair string-value rebuilds: 30k x 30k = 16–19 s (sxd ≈0.1 s, libxml2 ≈0.7 s) |
| P1-7 | P1 | limits / DoS | `XPathLimits` does not meter string-value work: `count(//e[string(/)="x"])` on 750 KB runs 23–36 s under the *default* limits |
| P1-8 | P1 | 4-mode | "4-mode byte-identical" is false: 3 / 11,705 corpus queries format differently on wasm32 (`…129.12` vs `…129.13`) |
| P2-1 | P2 | namespace axis | explicit `xmlns:xml="http://www.w3.org/XML/1998/namespace"` deletes the `xml` namespace node |
| P2-2 | P2 | API | `XPathContext::with_namespace` / `with_variable` mutate the receiver's maps (aliasing) |
| P2-3 | P2 | API | node-set variables are not normalized: `count($v \| /r/a)` = 3 for a reversed 2-node `$v`; `$v[1]` not in document order |
| P2-4 | P2 | input | `XPathDoc::parse` rejects any `<!DOCTYPE …>` document (even `<!DOCTYPE r>`) |

Measured (all reproduced by `run_audit.sh`):

| check | result |
| --- | --- |
| audit tests (`audit/*_test.pion`) | 38 tests: 20 `p1_`/`p2_` FAIL (evidence), 18 `control_` PASS; upstream `packages/xpath` 23/23 pass |
| differential corpus | 11,705 queries: pion = libxml2 on 10,932, pion = sxd on ~10,785 (sxd's namespace-node output is not deterministic run to run); pion is the lone dissenter on ~215 (all explained below) |
| Python spec model (number fuzz) | pion agrees on 2,321 / 2,700 (379 misses = P1-1/P1-2/P1-3) |
| 4-mode (native_dbg / native_rel / wasm_dbg / wasm_rel) | native pair identical, wasm pair identical, native vs wasm differ on 3 queries (P1-8) |
| DoS battery (`dos/run_dos.py`) | 9 pion verdicts fail (3 budget, 6 false rejections); 6 stack cases pass in all 4 modes |

## Findings

### P1-1 — number→string uses exponent notation (§4.2)

`src/num.pion:160-189` `xp_number_to_string` formats integers with `|x| < 2^53` exactly and hands
everything else to the runtime's `Double::to_string`, which switches to scientific notation.
§4.2 forbids exponents: "the number is represented in decimal form … with no leading zeros …"
(sxd-xpath prints all of these correctly).

```
string(1000000000000000000000)  -> "1e+21"                  (want "1000000000000000000000")
string(1152921504606846976)     -> "1.1529215046068467e+18" (want "1152921504606846976")
string(-347895384104287104)     -> "-3.478953841042871e+17"
string(0.0000001)               -> "1e-07"                  (want "0.0000001")
concat(1 div 10000000, '|', 100000000000000000000) -> "1e-07|1e+20"
```

Affects `string()`, `concat()`, string comparisons and every value a caller renders.
Tests: `p1_string_of_large_integer_has_no_exponent`, `p1_string_of_2_pow_60_is_plain_integer`,
`p1_string_of_small_fraction_has_no_exponent`, `p1_number_to_string_exponent_leaks_into_concat_and_equality`.
Fix: emit shortest round-trip digits (e.g. Ryu/Grisu digit generation) and lay them out without
exponent in pion itself — this also removes the wasm32 divergence (P1-8).

### P1-2 — string→number is not correctly rounded; long fractions become NaN

`src/num.pion:100-158` accumulates `int_val*10 + d` and `frac_val*10 + d` / `frac_scale*10` in
doubles and returns `int_val + frac_val / frac_scale`: three roundings, and both fraction
accumulators overflow to `+Inf` after 309 digits (`Inf / Inf = NaN`). The same routine parses
Number tokens in the lexer, so literals are affected too.

```
0.49999999999999994              -> 0.5        (nearest double is 0x3fdfffffffffffff); round() then gives 1
number('0.44170928548011157')    -> 0.4417092854801116    (1 ulp off)
number('2340032014150785536')    -> 2.340032014150785e18   (want 2.3400320141507855e18, 1 ulp)
number('0.111…' 330 digits)      -> NaN                    (want 0.1111111111111111)
```

Most of the 379 spec-model misses trace back to this parser (directly, or through `round`/`floor` of a mis-parsed literal).
Tests: `p1_number_literal_is_correctly_rounded`, `p1_round_just_below_half_is_zero`, `p1_long_fraction_is_not_nan`.
Fix: correctly rounded decimal→double (Eisel-Lemire fast path + big-decimal fallback), digits
beyond ~770 significant only need a sticky bit.

### P1-3 — `mod` is not the IEEE-754 remainder (§3.5)

`src/num.pion:83-92` computes `a - trunc(a / b) * b`. §3.5 defines `mod` as the truncating remainder
"same as the % operator in ECMAScript", i.e. C `fmod`, which is exact. The formula loses the result
whenever `a / b` or `q * b` rounds, and returns +0 where the dividend is -0:

```
5.5 mod 1.1                     -> 0          (want 1.0999999999999996, as sxd and libxml2)
100000000000000000000 mod 3     -> 0          (want 1)
9031316886084362240 mod 7.5     -> -1024      (want 5: wrong sign and |r| > |b|)
1 div (-0 mod 5), 1 div (-6 mod 3) -> Infinity (want -Infinity)
```

Tests: `p1_mod_is_exact_remainder`, `p1_mod_large_dividend_sign_and_magnitude`, `p1_mod_keeps_negative_zero`.
Fix: exact fmod (binary long division on the mantissas) and `copysign` of the dividend on a zero result.

### P1-4 — `max_depth` rejects ordinary flat expressions and cannot be raised

`src/parser.pion:16` and `src/eval.pion:17` clamp `max_depth` to at most 128, and
`EvalEnv::enter` (`src/eval.pion:61`) charges one level per `eval_expr` call. The parser builds
`a or b or c …`, `1+1+…` and `a|b|…` iteratively as *left-nested* trees, so a flat chain of N terms
needs N evaluation levels. Generated filters such as `//*[@id='1' or … or @id='200']` therefore fail
with `LimitExceeded`, and `XPathLimits::new(100000, …)` is silently clamped back to 128.
sxd-xpath and libxml2 evaluate all of these.

```
count(/r[@id="0" or … or @id="L"])  (201 terms)  -> ERR  (sxd, libxml2: 1)
1+1+…+1 (200)                                    -> ERR  (sxd, libxml2: 200)
count(/r/a|/r/a|…)  (200)                         -> ERR  (sxd, libxml2: 1)
```

Tests: `p1_or_chain_of_201_terms_evaluates`, `p1_plus_chain_of_200_terms_evaluates`,
`p1_union_chain_of_200_terms_evaluates`, `p1_max_depth_above_128_is_honoured`; DoS cases `accept_*_chain_*`.
Fix: evaluate same-precedence chains iteratively (or flatten them in the parser) and honour the
caller's `max_depth`; the real native/wasm stack needs are small (`control_moderate_nesting_ok`,
`stack_*` cases).

### P1-5 — default `max_nodes` rejects legitimate queries on 1–2 MB documents

`XPathLimits::default().max_nodes = 200,000` (`src/types.pion:78`) is checked against every
intermediate step result (`collect_axis`, `eval_steps`), and the convenience API (`xpath::eval`,
`eval_str`, `eval_string`, `eval_number`, `eval_bool`, `eval_nodes`, `XPathExpr::eval*`) always uses
the defaults. `//@k` additionally materializes `descendant-or-self::node()` (elements **and** text)
before the attribute step, so the cap is hit at 120,000 elements.

```
count(/r/e)          on <r><e/>×300000</r>  (1.2 MB)            -> ERR  node-set size exceeds max_nodes
count(//@k)          on 120,000 <e k=".."/>t</e> (2.1 MB)       -> ERR
count(//e[@k >= 0])  on 250,000 elements (4.6 MB)               -> ERR
```

(`packages/xml` itself accepts up to 1,000,000 nodes by default.) Tests:
`p1_default_limits_count_300k_children`, `p1_default_limits_descendant_attributes_120k`; DoS cases `accept_count_*`, `accept_desc_250k`.
Fix: limits should bound *work and memory*, not document size; at minimum align with the XML
parser's node cap, fuse `//@x` like `//x`, and expose limits on the convenience API.

### P1-6 — node-set comparisons are O(n·m) and rebuild string-values per pair

`EvalEnv::compare_values` (`src/eval.pion:912-960`) compares node-sets with a nested loop that calls
`xp_doc_string_value` (allocating, subtree walk for elements) for every *pair* and `xp_parse_number`
per pair for relational operators. sxd-xpath and libxml2 hash / pre-convert one side.

| `//a = //b` (disjoint, all pairs differ) | pion (default limits) | sxd-xpath | libxml2 |
| --- | ---: | ---: | ---: |
| 30,000 x 30,000 (`dos` `budget_nodeset_eq_nodeset_30k`) | **16.0–19.1 s** | 0.07–0.11 s | 0.63–0.73 s |
| 8,000 x 8,000, x5 (`bench` `b4_nodeset_compare`) | **4,210 ms** | 114 ms | 247 ms |

None of this work is charged to `max_steps`, so it is also a limits bypass (see P1-7).
Fix: compute each side's string-values once, hash the smaller side for `=`, sort numbers for
relational operators, and tick the budget per comparison.

### P1-7 — `XPathLimits` does not bound string-value work (DoS under default limits)

The README promises `XPathLimits` "preventing stack overflow and exponential query DoS". But
`xp_doc_string_value` (`src/doc.pion:286`) — called by `string()`, `normalize-space()`,
`string-length()`, `contains()`, `=`, `sum()`, … — copies the whole subtree text without ticking
`max_steps` or checking `max_output_bytes` (only `concat()` checks it). One predicate per node that
touches `/` makes the query O(nodes x document size) while only a handful of budget ticks are spent:

| case (pion with `XPathLimits::default()`, oracles unlimited) | pion | sxd-xpath | libxml2 |
| --- | ---: | ---: | ---: |
| `count(//e[string(/) = "x"])`, 50,000 `<e>` (750 KB) | 23.3–36.5 s | >60 s (timeout) | 35.6–54.7 s |
| `count(//e[normalize-space(/) = "x"])`, 30,000 `<e>` | 22.4–29.4 s | 39.1–56.4 s | 47.3–62.6 s |

The oracles are slow too (they make no bounding claim); pion's defect is that its advertised
budget does not stop it: a 750 KB document and a 30-byte query hold a core for half a minute.
Gated by `dos/run_dos.py` (`budget_*`: must finish or return `LimitExceeded` within 5 s).
Fix: charge string-value construction (bytes copied) and comparison loops to `max_steps`, apply
`max_output_bytes` to every produced string, and cache root/element string-values per evaluation.

### P1-8 — 4-mode byte identity does not hold (wasm32 number formatting)

Over the 11,705-query corpus `native_dbg` = `native_rel` and `wasm_dbg` = `wasm_rel`, but native
and wasm32 differ on 3 queries, all exact decimal ties fed to `Double::to_string` (P1-1 path):

```
string(76363424606129.125)      native 76363424606129.12   wasm32 76363424606129.13
string(-581796045283169.25)     native -581796045283169.2  wasm32 -581796045283169.3
string(9529711820703874 div 7)  native 1361387402957696.2  wasm32 1361387402957696.3
```

Both spellings are 16-digit round-trip strings, so either satisfies §4.2 — the defect is the
README's "byte-identical across native_dbg, native_rel, wasm_dbg, wasm_rel" claim (its smoke test
has only 4 checks). Root cause is in the toolchain's wasm32 `Double::to_string` tie-breaking;
formatting numbers inside the package (P1-1 fix) removes the dependency. Gated by the `wasm`
section.

### P2-1 — explicit `xmlns:xml` declaration removes the `xml` namespace node

`src/doc.pion:170-196`: when an element declares `xmlns:xml="http://www.w3.org/XML/1998/namespace"`
(legal per Namespaces 1.0), the inherited `xml` entry is treated as overridden and the own
declaration is skipped (`d_pref != "xml"`), so `namespace::xml` disappears for that element and its
descendants (`count(/a/namespace::xml)` = 0; sxd and libxml2: 1). Test `p2_explicit_xmlns_xml_keeps_xml_namespace_node`.

### P2-2 — `XPathContext` builders alias their maps

`with_namespace` / `with_variable` (`src/types.pion:367-388`) call `set` on `self.namespaces` /
`self.variables` and wrap the same maps in the "new" context. `base.with_namespace("p","urn:two")`
silently rebinds `p` in `base` and every context derived from it. Test `p2_context_builders_do_not_alias`.

### P2-3 — node-set variables are trusted to be sorted and unique

`VarRef` returns the caller's array as is (`src/eval.pion:782`); `union_sorted_nodes` assumes sorted
inputs and predicates use array order. With `$v` = [`b`, `a`]: `count($v | /r/a)` = 3 and
`name($v[1])` = `b` (spec: a node-set is unordered, `[1]` is first in document order). Test
`p2_nodeset_variable_is_normalized_to_document_order`.

### P2-4 — every DOCTYPE document is rejected

`XPathDoc::parse` (`src/types.pion:217`) uses `xml::Document::parse` defaults, which reject any
DTD — including an internal-subset-free `<!DOCTYPE r>` that XHTML, DocBook and SVG files carry.
`XPathDoc::from_document` is the workaround but nothing points to it. Test `p2_doctype_document_is_queryable`.

Not filed (documented scope): `id()` indexing unprefixed `id` attributes without a DTD is an
extension (README "Known Scope Boundaries"); unknown functions and arity errors are raised at
evaluation, not compile time (allowed by §4, same as libxml2).

## Oracle disagreements where pion is right

All ~215 "pion alone" rows of `diff/odd_one_out.txt` were inspected. Besides P1-1..P1-3 and P2-1 they
are oracle bugs or implementation-defined orders:

- `following::` from an attribute or namespace node: pion includes the owner element's descendants
  (§2.2: they follow the attribute in document order); sxd-xpath 0.4.2 and libxml2 2.9.13 return
  nothing (most of the cross-product rows).
- Positional predicates on `namespace::` (`namespace::*[2]`): namespace-node order is
  implementation-defined (§5).
- `number('1e5')`, `number('+1')`, `number('Infinity')`, `1e5`: sxd and/or libxml2 accept forms the
  XPath 1.0 grammar forbids; pion correctly gives NaN / a syntax error.
- sxd-xpath: does not merge CDATA/entity text into one text node (6 text nodes vs 1), drops the
  default namespace node, wrong existential `!=` (`//a != 2` false), `string(-0)` = `-0`, no `lang()`
  / `id()`, and it **crashes** (stack overflow, no output) on 100,000 unary minus signs where pion
  returns a clean `LimitExceeded`.
- libxml2 2.9.13: reports an `xmlns=""` undeclaration as a namespace node, orders attributes before
  namespace nodes and before their element in unions, prints numbers with `%g`-style exponents.

Every one of these pion behaviours is pinned by a `control_` test (`redteam_model_test.pion`,
`redteam_lexer_test.pion`, `redteam_numbers_test.pion`).

## Coverage of the brief (what was attacked and held)

- §3.7 disambiguation: `div/div`, `and/or`, `mod mod mod`, `*/@*`, `a * *`, `child :: r`, `@mod`,
  `node/node()`, `text/text`, `comment`, `processing-instruction`, `a-b` vs `a - b`, `.5`, `5.`,
  `1e5` rejected, both quote styles, `//a[1]` vs `/descendant::a[1]` vs `(//a)[1]`, `(a|b)[2]/c`,
  `$var/a`, `---1`, 22 malformed expressions — all correct (`control_operator_name_disambiguation`,
  `control_abbreviations_and_filters`, `control_syntax_errors`).
- 13 axes, reverse-axis proximity inside the step and document order outside, multi-predicate
  reverse positions, `following`/`preceding` exclusions, parents of attribute/namespace nodes,
  namespace inheritance / override / `xmlns=""`, text merging, `name()`/`local-name()`/
  `namespace-uri()` on every node kind, unbound prefixes, default namespace not applying to name
  tests — correct (9,000-query cross product + controls).
- Comparisons and conversions: existential node-set rules incl. node-set vs boolean, `substring()`
  (all §4.2 examples + NaN/±Inf + emoji), `translate()`, `normalize-space()` (NBSP kept), `lang()`,
  `round(-0.5)` = -0, `round(2^70)` without Int64 overflow, no float-to-int trap in any of the 4 modes.
- Stack: 120 nested parens, 60 nested predicates, 255-deep XML string-values, 100,000 unary minus,
  10,000 `/..` steps, 60 nested `concat` — clean result or `LimitExceeded` in all 4 modes
  (`stack_*`), 5,000 nested parens rejected cleanly (`control_deep_parens_rejected_cleanly`).
  Because `max_depth` is clamped to 128 (P1-4) native SIGSEGV / wasm `RangeError` are not reachable.

## Benchmark fairness (`bench/`)

Shipped bench re-run (`bench/run_blindspots.sh` section 1, unchanged `bench/run_bench.sh`):

| workload | README | re-run (pion / sxd median ms) | re-run speedup |
| --- | ---: | ---: | ---: |
| W1 10 precompiled queries x5, 866 KB | 3.62x | 90.2 / 309.4 | 3.43x |
| W2 compile+eval x20,000 | 1.50x | 272.4 / 414.7 | 1.52x |
| W3 deep axes x5, 157 KB | 1.52x | 35.5 / 51.0 | 1.44x |

Verdict: **the shipped numbers reproduce and the harness is symmetric** (same queries, same compile
counts, same doc parse, identical stdout, `Cargo.lock` pinned). XML parsing is a small share
(W1 parse-only 11.8 ms vs 15.3 ms, W3 8.3 vs 9.1 ms), so the gains are in XPath evaluation. But the
comparison is selective:

1. **Weak baseline.** sxd-xpath 0.4.2 (2019, unmaintained) is the only baseline. Against libxml2
   2.9 (C, `-O2`) through the same audit runners pion is at parity or behind:

   | workload (x5 rounds, compile+eval) | pion | sxd-xpath | libxml2 |
   | --- | ---: | ---: | ---: |
   | `parse_only_w1` | 13.0 ms | 16.0 ms | 10.6 ms |
   | `b1_string_values` (element string-values) | 55.9 ms | 171.1 ms | 53.5 ms |
   | `b2_reverse_axes` (`preceding::`, `ancestor::`, `preceding-sibling::`) | 59.5 ms | 188.8 ms | 61.8 ms |
   | `b3_general_descendant` (`//@id`, `//text()`, `//node()`) | 47.1 ms | 155.4 ms | **24.0 ms** |
   | `b4_nodeset_compare` (`//a = //b`, 8k x 8k) | **4,210 ms** | 114 ms | 247 ms |
   | `b5_namespaces` (prefixed tests, 20k items) | 179.7 ms | 559.8 ms | 165.3 ms |

2. **Blind spot hides a 37x loss.** No shipped workload compares two large node-sets; there pion
   is 37x slower than sxd and 17x slower than libxml2 (P1-6).
3. **Workloads stay under the default limits.** All shipped inputs are < 1 MB; the same queries on
   a 1.2–4.6 MB document return `LimitExceeded` (P1-5), which no table mentions.
4. Nits: `bench/run_bench.sh` builds Rust without `--locked`; W1's sxd timings vary 3.4–6.9x
   between runs on a loaded machine (README should state load/spread).

Recommendation: keep the sxd table but add libxml2 as a second baseline, add a node-set comparison
workload and a > 1 MB input, and report the losses next to the wins (AGENTS.md 1.3).

## Files

```
audit/run_audit.sh            one-shot runner (exit 0 only when every defect above is fixed)
audit/pion.toml, src/lib.pion test-only package `xpath_audit` and helpers
audit/redteam_numbers_test.pion  P1-1/2/3 + number controls
audit/redteam_limits_test.pion   P1-4/5 + limit controls
audit/redteam_model_test.pion    P2-1..4 + axes / data-model / comparison / string controls
audit/redteam_lexer_test.pion    §3.7 and grammar controls
audit/tools/pion_runner/      PACK runner (built 4 ways), `default` arg = XPathLimits::default()
audit/tools/rust_oracle/      sxd-xpath =0.4.2 runner (Cargo.lock)
audit/tools/c_oracle/         libxml2 runner
audit/diff/                   corpus generator (+ Python spec model), differential runner
audit/dos/run_dos.py          DoS / false-rejection / stack battery with verdicts
audit/bench/                  fairness review: shipped re-run, parse share, blind-spot packs
```
