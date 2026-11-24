# Red-team audit: `packages/structured_fields` v0.1.0 (RFC 9651 Structured Field Values)

Auditor: independent red team (`RT-sfv`), 2026-11-24. Audited commit: `fc9180d` (`origin/feat/pkg-structured-fields`).
Nothing under `packages/structured_fields/src`, the package tests, `pion.toml`, the package `README.md` or any
repository-root file is changed by the audit; everything lives in `packages/structured_fields/audit/`.

```sh
sh packages/structured_fields/audit/run_audit.sh            # exit 1 while any P0 condition reproduces
STRICT=1 sh packages/structured_fields/audit/run_audit.sh   # exit 1 while any P0 / P1 / P2 finding is open
```

## Verdict: NOT SIGNED (2 open P2, 0 P0, 0 P1)

Independent run on `fc9180d` + this audit tree, Linux x86_64 (`pvg`-class shared box, load ~10/16), `pionc 0.1.0`
(abi `pionc-v0.19`), node v24.22.1, cargo 1.100.0, Python 3.13.5:
**`sh run_audit.sh` → `EXIT=0` (0 P0); `STRICT=1 sh run_audit.sh` → `EXIT=1`, 2 OPEN (P2-1, P2-2), 0 P0.**
No P0 or P1. The two P2s are below, each with a reproduction, the RFC text, the root cause and a fix. The red team
signs once both are fixed (or P2-2 is documented and changed to reject or collapse) and `STRICT=1` gives
`EXIT=0`.

| ID | Sev | Status | Summary |
| --- | --- | --- | --- |
| P2-1 | P2 | OPEN | List / Dictionary fields that end in HTAB are rejected; RFC 9651 §4.2.1 / §4.2.2 accept them |
| P2-2 | P2 | OPEN | Serializer emits hand-built duplicate Dictionary / Parameter keys; `get_*` (first wins) and every parser (last wins) then disagree |

Everything else the brief asked for was checked and holds; see the gate table and the dimension sections below.

## Gate results

| Gate | Result on `fc9180d` |
| --- | --- |
| static | license MIT, 0 dependencies, 0 `extern "C"` / imports / `World` / module-level mutable state / `Double`/`Float` / panic paths / internal names; `Send` probe: 4 `Send` / 7 `!Send` = README.md table |
| unit | package 28/28 (README.md: 28); audit `pionc test`: 12 control pass, 0 control failing, 2 red-team open (P2-1, P2-2) |
| cases | 12/14 (12 control pass, P2-1 / P2-2 red-team fail) identically in native debug / release, wasm32 debug / release |
| official | **all 20 files** of httpwg/structured-field-tests @ `4a4782f`: Pion 1,607/1,607 parsing + 553/553 serialisation; independent model the same; Rust `sfv` 1,607/1,607 + 544/553 |
| determinism | official 1,607, named 17,250, fuzz 6,000, helpers 40, official serialisation 553, serializer ASTs 4,701: 4 modes byte-identical |
| oracles | 24,857 parse inputs + 5,254 serializer ASTs: 0 unexplained divergences from the model; 20 explained by P2-1, 6 by P2-2; Pion = Rust `sfv` everywhere else |
| dos | 30 bombs (default + raised limits, up to 30 MB / 4 M members): 0 crashes, native = wasm32, slowest 0.7 s native / 1.9 s wasm32, peak 455 MiB (2 M list members under raised limits), linear scaling |
| smoke | 4 x `f8311f93...` (271 B) = README.md; sizes 140,576 / 234,784 / 73,535 / 71,470 B = README.md |
| bench | stdout SHA-256 `02d5fdad...` / `3debee67...` = README.md; ratios and RSS see Dimension 5 |
| inject | 15/15 injected bugs caught by control tests |

## Findings

### P2-1: a List or Dictionary that ends in HTAB is rejected (RFC 9651 says accept)

- Reproduce: `parse_list("a\t")`, `parse_list("a \t")`, `parse_list("1, (2 3)\t")`, `parse_dictionary("a=1\t")`,
  `parse_dictionary("u=1, i\t")`, `parse_permissions_policy("geolocation=()\t")`: all return
  `TrailingData("trailing HTAB not allowed in structured field")`. The independent model and Rust `sfv 0.16.1` accept
  all of them. Test: `redteam_p2_1_trailing_htab_list_dict` (fails while open). The named corpus hits it 14 times
  (`trail-list-09`, `trail-sp-list-09`, `trail-dictionary-09`, `struct-list-3109`, ...) and the fuzz corpus 6 times.
  No other divergence comes from this code.
- RFC text: §4.2.1 (Parsing a List), step 2: "2. Discard any leading OWS characters from input_string. 3. If
  input_string is empty, return members." §4.2.2 (Parsing a Dictionary) has the same step 1.5. OWS is SP or HTAB.
  The trailing OWS is gone before §4.2 step 6 ("Discard any leading SP characters") and step 7 ("If input_string is
  not empty, fail parsing") run. Steps 6–7 do limit **Items** to trailing SP only. `"1\t"` as an Item must fail, and
  Pion correctly rejects it.
- Root cause: `src/parser.pion`, the end of `parse_list_with_limits` and of `parse_dictionary_with_limits`:
  `if p.len > 0 && p.bytes[p.len - 1].to_int() == 9 { return Err(TrailingData(...)) }`. Its comment cites §4.2
  step 7, which is a misreading for these two types. The package README.md lists the same behaviour as a feature
  ("rejects trailing HTAB").
- Impact: the whole field is discarded. Examples are a `Priority`, a `Cache-Status`, a `Signature-Input`, or a
  `Permissions-Policy` whose last byte is a tab. Every other RFC 9651 implementation keeps that field. For
  `Permissions-Policy` this fails open: the document gets the default allowlists instead of the restrictive policy.
  HTTP/1.1 and HTTP/2 stacks usually trim trailing OWS from field values, so the input mostly reaches this parser
  from intermediaries, `parse_*_fields` callers and non-HTTP uses. That is why this is P2 and not P1.
- Fix: delete both HTAB checks. Item parsing is already right. Update the README.md bullet and the package test
  that asserts the rejection.

### P2-2: the serializer emits duplicate keys; `get_*` and parsers disagree on which one wins

- Reproduce: `serialize_dictionary([a=1, a=2])` returns `"a=1, a=2"`. `serialize_item(1;x=1;x=2)` returns
  `"1;x=1;x=2"`. The same holds inside inner lists. Test: `redteam_p2_2_serializer_duplicate_keys`. It accepts
  either an error or a single key. The serializer corpus hits it 6 times (`s-dup-param`, `s-dup-param-bool`,
  `s-struct-dictionary-*`, `s-struct-list-*`).
- RFC: Dictionaries (§3.2) and Parameters (§3.1.2) are ordered maps, so a key occurs at most once. A value with a
  repeated key is not a Structured Field value. §4.1 says to fail when a structure cannot be serialized. Rust
  `sfv` cannot even represent it (`IndexMap`): the duplicate keeps its first position and takes the last value.
- Impact: this is a parser differential inside one library. `get_dict_member(d, "a")` and `get_param(ps, "x")`
  return the **first** value. Any recipient that parses the serialized header gets the **last** value, and so does
  this package (`a=2`). An application that checks a value with `get_*` and then forwards the serialized form
  approves one value and sends another. The output is also not a fixed point:
  `serialize(parse(serialize(x))) != serialize(x)`. README.md says "Every serializer validates ..." without a word
  on duplicates.
- Root cause: `src/serializer.pion` `write_params` and `serialize_dictionary_with_limits` write keys without
  checking whether they repeat.
- Fix: reject a repeated key with `SfvError::InvalidKey("duplicate key")`. For O(n) on large inputs, use a
  `Map[String, Unit]` once a member or parameter count passes a small threshold, as the parser already does.
  Collapsing last-wins at the first position, like Rust `sfv`, is also acceptable, but then `get_*` must agree.
  Document the rule in README.md.

## Dimension 1: RFC 9651 clause-by-clause adversarial testing

The checks run against three things. First, `src/cases.pion`, 12 control cases run in 4 modes. Second, the
`named` corpus of 17,250 inputs. Third, an **independent Python reference model** (`diff/model.py`). The model is
written step by step from RFC 9651 §4.1 and §4.2, cites the step numbers, and was not derived from Pion or `sfv`.
It passes all 1,607 official parsing vectors and all 553 official serialisation vectors on its own, which the build
checks every run.

- **Integer / Decimal.** These inputs were checked:
  - 1–17 digits, with and without `-`, with leading zeros. `0000000000000001` (16 characters) fails and
    `000000000000001` (15) is `1`, so leading zeros count, as §4.2.4 requires. `+1`, `-`, `--1`, `- 1` and `1e5`
    fail.
  - Every split of 0–14 integer digits by 0–4 fraction digits, with digits `9`, `0` and `1`/`5`, both signs.
  - `1.`, `.5`, `-.5`, `1..2` and `1.2345` fail. `-0.0` serializes as `0.0` and `-0.001` as `-0.001`.
  - The 12-digit integer part bound and the 15-digit Integer / Date bounds.

  `Decimal::from_scaled_rounded` was checked against exact `Fraction` round-half-to-even. Cases: ties at
  ±0.0005 and ±0.0015, `INT64_MIN` / `INT64_MAX` at shifts 16, 19 and 20, and overflow after rounding (`9999…9.5`
  is refused). The 9 official rounding vectors (`ser-number#6..14`: `0.0015`, `-0.0025`, `9.9995`, `0.5015`, …)
  pass through it. Rust `sfv` misses all 9 through its `f64` `Decimal::try_from`; that is `sfv`'s problem, not
  Pion's. Static: there is no `Double` / `Float` anywhere in `src/`. All arithmetic is `Int64`, and every
  multiplication is bounded before it happens (15 digits, ×1000, `10^18` at most).
- **String / Token / Key.** For every byte 0x00..0xFF the corpus puts it in these positions: string body,
  escaped string character, token first / middle / end, key first / middle / single in a dictionary, and parameter
  key first / middle. Result: 0 divergences from the ABNF model. Only `\"` and `\\` are escapes. `\t`, `\'` and
  `A` fail. Keys reject uppercase, `_` / `-` / `.` / digits as the first character, and HTAB after `;`.
- **Byte Sequence.** Checks:
  - Every alphabet byte as the last sextet, with and without padding. Non-zero pad bits are accepted (RFC: SHOULD
    NOT fail; `sfv` and the official `can_fail` vector agree).
  - Every length 0–9 with 0–4 `=`. Partial padding is accepted. Padding beyond the 4-character quantum, `=` inside
    the data, length mod 4 = 1, whitespace, LF, base64url `_-`, and a missing closing `:` all fail.
  - Every byte 0x00..0xFF inside the data.

  Re-serialization is canonical (`:aZ==:` → `:aQ==:`).
- **Boolean / Date / Display String.**
  - `?` followed by every byte, and `@` followed by every byte. `@1.0`, `@-`, `@+1`, `@ 1` and `@1000000000000000`
    fail.
  - Display String: every `%xx` in lowercase and uppercase (uppercase always fails), `%a` + every byte, every raw
    byte, and a UTF-8 structure sweep. The sweep covers every lead byte 0x80..0xFF × 8 boundary continuations ×
    2/3/4-byte forms (overlongs, `U+D800..DFFF`, above `U+10FFFF`, `F5..FF`, and every truncation of 14 boundary
    code points). The model's decoder is CPython's strict UTF-8 codec.
  - The serializer escapes `%`, `"`, 0x00–0x1F, 0x7F and every non-ASCII byte as lowercase `%xx`.
- **List / Inner List / Dictionary / Parameters / multi-line.**
  - Every byte before and after `,` in a List and a Dictionary, before `=`, inside `( )`, around `;`, and leading /
    trailing on all three top-level types (with and without an extra SP).
  - Leading HTAB fails on every type. A trailing HTAB fails for an Item, as it must; a List / Dictionary is P2-1.
  - `\r \n \v \f` fail anywhere outside a string.
  - Inner lists need SP between items (HTAB fails). `()` is a valid empty inner list. `(1)(2)`, `((1))`, `,1`,
    `1,,2` and a trailing comma fail.
  - Duplicate dictionary and parameter keys overwrite in place: first position, last value. This holds below and
    above the 8-entry lazy `Map` threshold, matching §4.2.2 / §4.2.3.2 and `sfv`'s `IndexMap`.
  - `parse_*_fields` joins lines with `", "`. 22 line combinations × 3 types: empty, whitespace-only, comma-only,
    CR / LF / NUL injection, a token or string split over two lines. The model and `sfv` agree with Pion on each.
    An empty line next to a non-empty one makes a trailing or leading comma, so the whole field fails, as in `sfv`
    (I-4).
- **Serializer header injection.** 4,701 hand-built ASTs with no validation on the Pion side. They include every
  byte in strings / tokens / keys / display strings, `\r\n` in strings, tokens and keys, NUL, uppercase and empty
  keys, empty tokens, ±10^15, `INT64_MIN` / `INT64_MAX` for Integer, Decimal and Date, 13 kinds of invalid UTF-8,
  and duplicate keys, plus 2,838 random valid ASTs. No output contains a byte outside 0x20..0x7E. Every invalid
  value gives `Err`. The only divergence from the model is P2-2.

## Dimension 2: independent differential testing

- Pion (native `--release`; the same bytes in all 4 modes) against the model and Rust `sfv =0.16.1` (`Cargo.lock`
  with `--locked`, `diff/rust`, a new harness that does not reuse `bench/`):

  | corpus | inputs | Pion = model | explained | unexplained | Pion = `sfv` | `sfv` ≠ model |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: |
  | official parsing | 1,607 | 1,607 | 0 | 0 | 1,607 | 0 |
  | named adversarial | 17,250 | 17,236 | 14 (P2-1) | 0 | 17,236 | 0 |
  | fuzz (seed 9651) | 6,000 | 5,994 | 6 (P2-1) | 0 | 5,994 | 0 |
  | serializer ASTs | 4,701 | 4,695 | 6 (P2-2) | 0 | 4,695 | 6 (`sfv` collapses duplicates) |
  | official serialisation | 553 | 553 | 0 | 0 | 544 | 9 (`sfv` f64 rounding) |

- Official suite: **all 20 files** of `httpwg/structured-field-tests` @ `4a4782f` (2026-11-17), vendored gzip with
  its BSD-3-Clause `LICENSE.md`. That is 1,607 parsing vectors, generated files included, plus 553 serialisation
  vectors. Pion: **1,607/1,607 + 553/553**. The model gets the same. Rust `sfv`: 1,607/1,607 + 544/553 (the 9
  rounding vectors above). README.md's "251/251" covers only the 15 hand-written files; the full suite passes too.

## Dimension 3: DoS, complexity and `SfvLimits`

- Limits. Every field set negative is refused on both parse and serialize. `0` means zero. For each limit the
  exact bound is accepted and bound + 1 gives `LimitExceeded`: `max_input_bytes` (also for joined field lines),
  `max_list_members`, `max_inner_list_items`, `max_dict_members`, `max_params`, and `max_string_bytes` (key, token,
  string, display string, decoded byte sequence). The `max_output_bytes` bounds are exact including the 3× `%xx`
  and 4/3 base64 expansions (`control_limits`).
- 30 bombs on native `--release` and wasm32 `--release`: same summaries, no crash, all inside 20 s / 1 GiB:

  | bomb | limits | native `--release` | peak RSS | wasm32 `--release` |
  | --- | --- | ---: | ---: | ---: |
  | 12 default-limit bombs (64 KiB SP padding, 1,024 / 1,025 members, 13 k duplicate keys, 32 k duplicate params, 1,024 `()`, 16,384 / 16,385-char string, `%c3%a9` × 10,900, 16,384-byte binary, 65,537 B input, 256-item inner list) | default | ≤ 0.01 s each, right `OK` / `LimitExceeded` | < 3 MiB | ≤ 0.08 s |
  | `r02` 1 M distinct dictionary keys (11 MB) | raised | 0.82 s | 311 MiB | 1.75 s |
  | `r03` 4 M duplicate dictionary keys (20 MB) | raised | 0.65 s | 40 MiB | 1.94 s |
  | `r05` 1 M distinct parameters | raised | 0.35 s | 155 MiB | 0.75 s |
  | `r06` 4 M duplicate parameters | raised | 0.34 s | 25 MiB | 1.32 s |
  | `r07` 2 M inner-list items | raised | 0.38 s | 232 MiB | 0.68 s |
  | `r08` 2 M list members | raised | 0.63 s | 455 MiB | 1.35 s |
  | `r09` 2 M empty inner lists `()` | raised | 0.49 s | 416 MiB | 0.94 s |
  | `r10`–`r14` 30 MB display string / binary / escaped string / OWS / token | raised | ≤ 0.47 s | ≤ 148 MiB | ≤ 1.03 s |
  | `r15` 1 M boundary decimals | raised | 0.37 s | 284 MiB | 0.89 s |
  | `r16`–`r18` output bombs (`max_output_bytes` = 1,000) | raised | stop at the limit, ≤ 0.55 s | | ≤ 1.20 s |

  Each list member costs about 230 B of heap (`r08`). That is only reachable with raised limits; under the
  defaults the cap is 1,024 members.

  Going 250 k → 1 M keys or parameters (4× the input) takes 3.4–4.7× / 4.0–5.1× the time over 3 runs, which is
  linear.
  4,000,000 duplicate dictionary keys and 4,000,000 duplicate parameters stay linear through the lazy `Map` index.
  Hash collisions in Pion's `Map` cannot be crafted from outside without knowing its hash, and default limits cap
  any chain at 1,024 or 256 entries (I-7).

## Dimension 4: browser helpers

- `parse_priority` follows RFC 9218 §4 ("unknown priority parameters, priority parameters with out-of-range
  values, or values of unexpected types MUST be ignored"). These inputs fall back to the default: `u=8`, `u=-1`,
  `u=1.0`, `u="1"`, `u=(1)`, `u=?1`, `i=1`. A duplicate `u=2, u=9` keeps the last value (9), which is out of range,
  so the result is `u=3`, per the dictionary rules. A syntax error fails the whole field (§4: "Where the Dictionary
  is successfully parsed"). `serialize_priority` refuses `u` outside 0..7 and leaves out the defaults.
- `parse_permissions_policy`: `*` and `self` work as a bare token and inside a list. `()` means none.
  `camera=(), camera=*` gives `*` (last wins). Unknown tokens such as `src` and `none` are ignored.
  Differences from W3C Permissions Policy §9.2 are left as INFO I-2: a bare String item (`camera="https://a"`)
  is taken as an origin, while §9.2 only reads list elements, and origins are returned unvalidated
  (`"javascript:alert(1)"` comes back as is).

## Dimension 5: `Send`, 4-mode replay, README.md claims

- `pionc check` capture probes, `scope` + `spawn` on every public type: `SfvLimits`, `Decimal`, `SfvError` and
  `Priority` are `Send`. `BareItem`, `Param`, `Item`, `InnerList`, `ListEntry`, `DictMember` and
  `PermissionsDirective` are `!Send` (`E_NOT_SEND`). This is exactly the README.md table. The advice there, to send
  the serialized `String` and parse it inside `spawn`, compiles.
- `wasm_smoke`: all 4 modes print the same 271 B, sha256 `f8311f93…` = README.md. Linux x86_64 sizes are
  140,576 / 234,784 / 73,535 / 71,470 B, matching README.md byte for byte. Unit tests 28/28 = README.md. Static
  checks: no `extern "C"`, no imports, no `World`, no module-level mutable state (only 4 `Int64` constants), no
  floats, no panic paths, no internal machine names.
- Every corpus file is byte-identical in native debug / release and wasm32 debug / release (official, named, fuzz,
  helpers, both serializer sets).
- Benchmarks: `bench/run_bench.sh` was re-run independently and both README.md stdout SHA-256s reproduce.

  | run (shared Linux x86_64, load ~10) | corpus 1 `pion` / `rust_sfv` median | ratio | corpus 2 median | ratio |
  | --- | ---: | ---: | ---: | ---: |
  | README.md | 261.3 / 100.9 ms | 0.39x | 225.5 / 98.6 ms | 0.44x |
  | audit run 1 | 298.3 / 102.7 ms | 0.34x | 176.2 / 78.3 ms | 0.44x |
  | audit run 2 | 165.0 / 62.3 ms | 0.38x | 203.5 / 105.0 ms | 0.52x |
  | audit run 3 (default) | 308.3 / 109.0 ms | 0.35x | 180.7 / 91.0 ms | 0.50x |
  | audit run 4 (`STRICT=1`) | 264.4 / 78.9 ms | 0.30x | 209.5 / 94.3 ms | 0.45x |

  The ratios agree with README.md to within the noise of a loaded shared machine: corpus 1 at 0.30–0.38x against
  the claimed 0.39x, and corpus 2 at 0.44–0.52x against 0.44x. README.md is honest that Pion is slower. Peak RSS
  (`diff/rss.py`, sampled from `/proc/<pid>/status`): `pion` 1.94–1.96 MiB and `rust_sfv` 2.16–2.20 MiB, against
  the claimed 1.90–1.91 and 2.20 MiB. "Pion uses slightly less" reproduces. `bench_compare.py` prints `N/A` for
  RSS here because the box has no `/usr/bin/time`.

## Dimension 6: mutation proof

`diff/inject.py` copies the package to `$AUDIT_OUT/inject`, plants one real bug at a time and runs `pionc test` on
the audit package. All 15 bugs are caught by control tests:

| Injected bug | Caught by |
| --- | --- |
| uppercase `%XX` accepted in Display Strings | `control_display_string` |
| top-level HTAB discarded like SP | `control_string_token_key`, `control_whitespace` |
| 16-digit integers accepted | `control_integer` |
| dictionary duplicate key keeps the first value | `control_duplicates`, `control_fields`, `control_helpers` |
| parameter duplicate key keeps the first value | `control_duplicates` |
| serializer lets CR / LF / controls into Strings | `control_string_token_key` |
| serializer leaves `%` unescaped in Display Strings | `control_display_string` |
| 4 fractional digits accepted | `control_decimal` |
| uppercase first key character accepted | `control_string_token_key` |
| base64 `=` inside the data accepted | `control_binary` |
| UTF-16 surrogates (`ED A0..BF`) accepted | `control_display_string` |
| `max_params` off by one | `control_limits` |
| Priority `u=8` accepted | `control_helpers` |
| serializer Integer range check removed | `control_integer` |
| byte-sequence decoded-size limit off by one | `control_limits` |

## INFO (not blocking)

- I-1: root `THIRD_PARTY_NOTICES.md` does not list `httpwg/structured-field-tests` (BSD-3-Clause; vendored in
  `bench/gen_data.py` and `audit/sft`). Root `catalog.json`, `README.md`, `BENCHMARKS.md` and `index/` do not list
  the package yet. These are root files, handled at release integration and not on this branch.
- I-2: `parse_permissions_policy` treats a bare String item as an origin and returns origins unvalidated. W3C
  §9.2 accepts origins only as list elements and only when they are a valid permissions-source-expression. The
  `report-to` parameter is dropped. Callers must validate origins themselves; README.md should say so.
- I-3: an empty List or Dictionary serializes to `""`. RFC 9651 §4.1 says not to send the field at all, so callers
  must leave the header out. Rust `sfv` returns `None` here.
- I-4: an empty field line joined with others (`["a", ""]` → `"a, "`) fails the whole field, as in `sfv`. RFC 9110
  §5.3 lets a recipient ignore empty list elements before joining, which this API does not offer.
- I-5: there is no separate byte-sequence limit (`max_byte_seq_bytes`, as asked in the brief). `max_string_bytes`
  bounds the decoded size. The default of 16,384 equals the RFC 9651 §3.3.5 minimum.
- I-6: `bench/rust_bench` has no `Cargo.lock` and is not built with `--locked`, so `sfv` / `base64` / `indexmap`
  can drift between runs. The audit oracle pins them.
- I-7: crafted hash collisions in `Map` were not tested (the hash function is internal). The worst case is bounded
  by the default limits, and the 1 M-key bombs stay linear.

## Files

- `run_audit.sh`: one-shot gate, sections `build static unit cases official determinism oracles dos smoke bench
  inject`.
- `src/` (`main.pion` CLI, `dump.pion` shared dump format, `cases.pion` red-team and control cases),
  `control_test.pion`, `redteam_test.pion`: the audit package, which depends on `..`.
- `diff/model.py`: independent RFC 9651 model. `diff/rust/`: Rust `sfv =0.16.1` oracle. `diff/gen.py`: corpora.
  `diff/compare.py`: official / triple / serializer comparison and finding explanations. `diff/dos.py`,
  `diff/rss.py`: bombs and peak RSS. `diff/inject.py`: mutation proof. `diff/readme.py`: README.md claims.
- `sft/`: the official vectors (gzip), `LICENSE.md` (BSD-3-Clause, IETF Trust) and `SOURCE` (upstream commit).
