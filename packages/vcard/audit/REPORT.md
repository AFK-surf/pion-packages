# RT-vcard — red-team audit of `packages/vcard` @ `4122045`

Scope: `packages/vcard/src/**` (parser, serializer, escaping, structured, validator, types) and
`packages/vcard/bench/**` on `origin/feat/pkg-vcard` `4122045`. Nothing outside
`packages/vcard/audit/**` was modified.

References used for differential evidence:

| Reference | Version | Role |
| --- | --- | --- |
| RFC 6350 / 2426 / 6868 / 2045 / 2397 / 6473 | — | normative text; every expectation in `diff/cases.py` cites it |
| Go `github.com/emersion/go-vcard` | `v0.1.0` (`diff/go/go.sum`) | same oracle as `bench/`; lossy decoder, no QP / RFC 6868 |
| Rust `calcard` (Stalwart) | `=0.3.14` (`diff/rust/Cargo.lock`, built `--locked`) | lenient (Postel) full vCard parser, typed values |

Reproduce everything: `sh packages/vcard/audit/run_audit.sh` (stages `tests`, `diff`, `wasm`, `dos`;
`bench` reruns `bench/run_bench.sh`). Exit **1** today; exit **0** once the defects are fixed —
verified: `audit/fix_sketch.diff` (a prototype fix, *not* applied to `src/`) makes the unchanged
`audit/` run exit 0 with the upstream suite still 13/13 (see §6). All binaries, corpora and caches
live in `/private/tmp/rt-vcard-*`; the worktree stays clean.

## Summary

| Class | Count | Evidence |
| --- | ---: | --- |
| **P0** serializer card smuggling (CRLF/structure injection red line) | **1 defect** | 3 tests, 3 FAIL |
| **P1** data corruption / line swallowing / DoS / wasm32 abort | **4 defects** | 4 tests FAIL + DoS gates G1, G2 FAIL + diff Q01–Q03 |
| **P2** spec deviations, validation gaps, roundtrip instability | **11 defects** | 11 tests FAIL + diff L12, M03 |
| **Control / fairness** | — | 6 tests PASS, 102/107 diff cases PASS, G3 PASS, 4-mode PASS |

`pionc test --json packages/vcard/audit`: 60 total = 36 deps PASS (`base64` 23 + `vcard` 13,
unchanged) + 18 findings FAIL + 6 controls PASS. `pionc fmt --check` clean for `audit/` and
`audit/driver/`.

Differential corpus (`diff/cases.py`, 107 cases = 47 hand-written lexical/param/QP/structured/media/
UTF-8 cases + 60 generated 75-octet fold-boundary cases; each checked on **parse** and on
**parse → `format_stream` → reparse**):

| | agrees with spec expectation |
| --- | ---: |
| **Pion** `packages/vcard` | **102 / 107** (5 FAIL: L12, Q01, Q02, Q03, M03) |
| Go `go-vcard v0.1.0` (informative) | 93 / 107 |
| Rust `calcard 0.3.14` (informative) | 97 / 107 |

4-mode (`native_dbg`/`native_rel`/`wasm_dbg`/`wasm_rel`, clean `PION_CACHE_DIR`, 220 output lines
covering the corpus, roundtrip, fold/limit/media DoS probes): byte-identical
`sha256=5c3de11a3170c4d50e40e18dba7bf742dbcdc92138730ebae3ab16d444cbd7c3`, 0 SIGSEGV, 0 trap.
The only wasm32 trap found is P1-4 (OOM on a 64 MiB input the default limits accept).

---

## P0

### P0-1 Property names `END` / `BEGIN` are serialized verbatim → one card becomes two (card smuggling)

`serializer.pion:64` writes `sanitize_vcard_name(prop.name)`; `types.pion:154-175`
(`sanitize_vcard_name`) only *deletes* bytes outside `ALPHA / DIGIT / "-"`. It never rejects the
reserved component delimiters, so a property named `END` with value `VCARD` is emitted as a real
`END:VCARD` line and a following `BEGIN`-named property opens a new card; the parser
(`parser.pion:300-323`) recognises them by name. Worse, the deleting sanitizer *assembles* the
reserved name from hostile input: `"\r\nEND"`, `"E N D"`, `"E\0ND"`, `"e.nd"`, `"END\r\n"` all
become `END`. The README claims "Automatic CRLF injection defense across … group/property/parameter
names".

```text
VCard{ VERSION:4.0, FN:Alice, END:VCARD, BEGIN:VCARD, FN:Mallory, EMAIL:mallory@evil.test }
format_card(...) ->  BEGIN:VCARD / VERSION:4.0 / FN:Alice / END:VCARD
                     BEGIN:VCARD / FN:Mallory / EMAIL:mallory@evil.test / END:VCARD
parse_stream(...) -> 2 cards   (attacker-authored second contact)
```

A single card with a `BEGIN`-named property makes the whole `format_stream` export unparsable
(`nested BEGIN:VCARD is not allowed`): every other contact in the address book is lost on import.
Reachable wherever property names come from data (JSContact/CSV/JSON → vCard converters, custom
`X-`/user field names, sync bridges). The parser cannot produce such names (it consumes BEGIN/END
even with a group), so the model only gets them from the public constructors.

Tests: `p0_property_named_END_smuggles_second_card`, `p0_name_sanitizer_assembles_END_from_control_bytes`,
`p0_property_named_BEGIN_poisons_whole_stream`.
Fix: after sanitizing, map names equal (ASCII case-insensitively) to `BEGIN`/`END` to `X-BEGIN`/`X-END`
(or reject them); the tests only require "one card in, one card out, nothing lost".

## P1

### P1-1 Quoted-Printable values are corrupted by parse → format → parse

The unfolder turns a QP soft break `=CRLF` into `=` + raw LF inside the value
(`parser.pion:241`, `:265`). `format_*` then rewrites that LF as the TEXT escape `\n`
(`serializer.pion:17-52` `sanitize_property_value`), which is not a soft break: on reparse
`decode_quoted_printable` sees `=\` and fails (`escaping.pion:414-433`). `fn_name()` / `notes()`
swallow the error and return the raw `=E4=B8=\n=AD` text (`structured.pion:596-599`, `:817-820`).
Every vCard 2.1 contact with a folded QP value (the normal Android/Outlook export shape) is damaged
by one save.

```text
NOTE;ENCODING=QUOTED-PRINTABLE:=E4=B8=\r\n=AD=E6=96=87   parse -> decoded_text() = "中文"
format_stream -> NOTE;ENCODING=QUOTED-PRINTABLE:=E4=B8=\n=AD=E6=96=87
reparse        -> decoded_text() = Err(InvalidValue: invalid Quoted-Printable escape sequence)
```

Tests: `p1_quoted_printable_soft_break_corrupted_by_roundtrip`, `p1_quoted_printable_lf_soft_break_roundtrip`;
diff Q01, Q02 (roundtrip leg). go-vcard does not decode QP and calcard decodes it as Latin-1 without
`CHARSET`, so neither oracle agrees with the spec expectation here; the expectation is RFC 2045 + the
first-parse result of Pion itself.

### P1-2 QP soft breaks are enabled by the substring `QUOTED-PRINTABLE` *anywhere* in the header → next line swallowed

`parser.pion:234-236` / `:258-260` enable soft-break joining when `contains_ascii_ci(header,
"QUOTED-PRINTABLE")`, i.e. for any parameter *value* (`X-HINT=QUOTED-PRINTABLE`,
`LABEL="quoted-printable"`), in vCard 4.0 too. A value ending in `=` then absorbs the next content
line. Through the serializer this is reachable from plain user text: a param value mentioning
"quoted-printable" plus a NOTE such as `1+1=` makes `format_card` output whose reparse swallows the
next property — or `END:VCARD`, which kills the whole stream.

```text
NOTE;X-HINT=QUOTED-PRINTABLE:a=\r\nTEL:1\r\n   ->  NOTE = "a=\nTEL:1", TEL lost
```

Tests: `p1_qp_soft_break_triggered_by_unrelated_param_value`, `p1_serializer_output_swallows_next_line_via_qp_marker`;
diff Q03 (go-vcard **and** calcard agree with the spec, Pion alone differs).
Fix: decide QP once per line from the parsed parameters (`ENCODING=QUOTED-PRINTABLE` or the bare
2.1 token), not from a substring search.

### P1-3 Quadratic QP unfolding (CPU DoS within default limits)

Each soft break runs `line_buf.to_string()` (a full copy of the logical line so far) plus a header
scan (`parser.pion:235`, `:259`). A single 1.2 MB property is ~300k soft breaks:

| input (`d1_qp_N`, one NOTE) | Pion | go-vcard (no QP, reference cost) |
| --- | ---: | ---: |
| 150 KB (37.5k breaks) | 0.47 s* | 0.00 s |
| 300 KB | 0.49 s* | 0.00 s |
| 600 KB | 1.96 s | 0.01 s |
| 1.2 MB (300k breaks) | **7.50 s** (8.48 s on the final run) | 0.02 s |

(*first two runs dominated by load on the shared machine; doubling input ≈ 4× time from 600 KB on.)
`max_line_bytes` (1 MiB) bounds one property, but `max_bytes` (64 MiB) admits ~55 such properties:
≈ 7 min CPU per request. Gate **G1** (1.2 MB must parse in < 1.5 s) FAILS. The prototype fix (flag
computed once, soft break skipped in the scanner) parses it in < 0.01 s.

### P1-4 Default `VCardLimits` admit an input that aborts wasm32 (OOM trap)

`VCardLimits::default()` (`types.pion:205-213`: 64 MiB, 50 000 cards × 2 048 properties) bounds
bytes and per-card counts but not total allocations. 64 MiB of minimal `a;b;c:` properties (every
limit respected; 4 102 cards, 8.4 M properties, each with a parsed `TYPE` param):

| | result | peak RSS |
| --- | --- | ---: |
| native `--release` | OK | 4 042 MiB |
| **wasm32 `--release`** | **`RangeError: WebAssembly.Memory.grow(): Unable to grow instance memory`, exit 1** | 4 151 MiB |
| go-vcard (same 16 MiB shape) | OK | 1 083 MiB (Pion 1 011 MiB) |

The amplification (~60×) is comparable to go-vcard's, so the defect is the *default budget*, not the
data model: a library advertised for Native + Wasm32 accepts, by default, input that is guaranteed
to trap the wasm32 instance (uncatchable; the host process aborts). Gate **G2** FAILS.
Fix: a default that fits the 4 GiB wasm32 address space (e.g. `max_bytes` 16 MiB, or a total
property/param budget). The gate accepts `OK` or `ERR LimitExceeded`, never a trap.

## P2

| # | Defect | Root cause | Test / diff |
| --- | --- | --- | --- |
| P2-1 | `parse_bytes` rejects a fold that splits a UTF-8 sequence; RFC 6350 §3.2 says implementations SHOULD restore it (go-vcard accepts) | UTF-8 validated on raw bytes before unfolding, `parser.pion:349` | `p2_parse_bytes_rejects_fold_inside_utf8_sequence`, diff L12 |
| P2-2 | `data:` URI without `;base64` is not percent-decoded (RFC 2397 §2; calcard decodes) | `escaping.pion:509-510` returns raw bytes | `p2_data_uri_percent_encoding_not_decoded`, diff M03 |
| P2-3 | `validate` accepts VERSION anywhere (RFC 6350 §6.7.9: "MUST appear immediately after BEGIN:VCARD") | only counts VERSION, `validator.pion:29-33` | `p2_validate_accepts_misplaced_VERSION` |
| P2-4 | `validate` accepts a vCard 3.0 without `N` (RFC 2426 §5: N and FN required) | only FN checked, `validator.pion:85-87` | `p2_validate_accepts_v3_card_without_N` |
| P2-5 | `PartialDate::parse` accepts impossible dates `20230229`, `--0230`, `2023-11-31`, `--0431`, `19000229` | day only checked `<= 31`, `structured.pion:348-423` | `p2_partial_date_accepts_impossible_dates` (leap-day controls `20240229`, `--0229` must stay valid) |
| P2-6 | Zone suffix not validated: `T102200Zjunk` → `tz_offset = "ZJUNK"`, `+`, `+2`, `-99:99` accepted | suffix copied verbatim, `structured.pion:449-451` | `p2_partial_date_zone_suffix_unvalidated` |
| P2-7 | `Geo::parse` accepts `geo:91,0`, `geo:0,181`, `geo:abc,def`, `12.5;east` | only non-empty checked, `structured.pion:504-526` | `p2_geo_accepts_out_of_range_and_non_numeric` |
| P2-8 | `validate` rejects `KIND:application` (registered by RFC 6473; §6.1.4 allows iana-token) | only 4 values + `x-`, `validator.pion:9-14` | `p2_validate_rejects_registered_KIND_application` |
| P2-9 | Serializer emits raw NUL/ESC/DEL (ANSI escape `\x1b[31m` survives) in values and param values; RFC 6350 §3.3 VALUE-CHAR/QSAFE-CHAR exclude CTL | only CR/LF handled, `serializer.pion:17-52`, `escaping.pion:251-291` | `p2_serializer_emits_raw_control_bytes` |
| P2-10 | `VCardParam` with an empty value list serializes as `TYPE=` and reparses as `[""]` | `serializer.pion:65-89` writes the name unconditionally | `p2_empty_param_value_list_not_roundtrip_stable` |
| P2-11 | Bare CR inside a value is accepted by the parser and silently rewritten to LF on the next save | parser keeps lone CR (`parser.pion:225`), serializer maps it to `\n` | `p2_bare_cr_value_mutated_by_roundtrip` |

Observed but not counted (by design or matching both references): `item.END:VCARD` is treated as
`END` (calcard identical); `BDAY;VALUE=text:circa 1800` makes `birthday()` return `Err` instead of a
text value (API has no text variant); `CHARSET=` is ignored by `decoded_text()` (non-UTF-8 QP falls
back to raw text in `fn_name()`).

## Controls (attacks withstood)

| Test / probe | What it shows |
| --- | --- |
| `control_crlf_injection_in_value_param_group_and_names_is_neutralized` | `\r\nEND:VCARD\r\nBEGIN:VCARD…` in FN/NOTE values, group, property name, param name, every param value (`"`, `;`, `:`, `,`, `^n`, CRLF) → still one card, no injected EMAIL, property count and values preserved (CRLF → LF). |
| `control_fold_75_octets_never_splits_utf8` + diff `F_*` (60 cases) | every prefix 0..159 × 2-byte, 3-byte, 4-byte, ZWJ (`👩‍💻`), combining (`é`), flag (`🇯🇵`): each physical line ≤ 75 octets, valid UTF-8, exact roundtrip. |
| `control_structured_escapes_backslash_before_separator`, diff S01–S09 | `\\;` (escaped backslash + real separator), `\;`, `\,`, `\N`, dangling `\`, unknown `\:` preserved, `to_value`/`parse` inverse on hostile components. go-vcard gets S01/S03 wrong (it unescapes before splitting). |
| `control_rfc6868_unknown_caret_preserved`, diff P02/P03 | `^n ^' ^^` decoded; unknown `^x` and trailing `^` kept literally (RFC 6868 §3). |
| `control_zero_and_negative_limits_fail_closed` | every `VCardLimits` field set to 0 or negative → `LimitExceeded`, no bypass. |
| `control_pref_bounds_and_utf8_rejections` | `PREF` 0/101/-1/abc/empty/11-digit/1.5 rejected by `validate`; overlong, surrogate, > U+10FFFF, truncated, lone continuation, 5-byte rejected by `is_valid_utf8`. |
| diff L01–L13, P01–P09, M01–M07, U01–U05 | CRLF/LF/HTAB folds, multi-level and empty continuation lines, no final EOL, lowercase BEGIN/END, BOM, nesting/unclosed rejected, groups, quoted `: ; ,` in params, repeated / bare 2.1 params, base64 `data:` / `ENCODING=b`, invalid base64 → error. |
| DoS G3 | 200k-line fold (linear, < 0.01 s), 50k properties / 50k params → `LimitExceeded` in < 0.01 s, 8 × (720 KiB + 360 KiB) inline avatars decoded in 0.08 s. |

## Benchmark review (`packages/vcard/bench/`)

Reproduced on the same machine (`Darwin arm64`, shared, load 8–13) with `bench/run_bench.sh`
(5 interleaved rounds, SHA-256 identical across implementations):

| Workload | Pion median | Go median | Pion / Go (README) | Pion / Go (reproduced) |
| --- | ---: | ---: | ---: | ---: |
| W1 parse 4 000 cards | 35.3 ms | 30.3 ms | 0.90× | 0.86× |
| W2 parse + extract + roundtrip | 35.6 ms | 32.6 ms | 0.92× | 0.92× |
| W3 escapes + base64 avatars | 20.2 ms | 18.2 ms | 0.91× | 0.90× |

The README numbers are reproducible. Fairness findings:

1. **Asymmetric work, against Pion.** go-vcard's `Encoder` never folds (`formatLine` writes the whole
   line), while Pion folds every line to 75 octets in W2/W3. Pion's accessors also compute what the Go
   side never touches: `emails()`/`phones()` build `types()`, `pref()`, `altid()`, `pid()` per value;
   `addresses()` splits all 7 ADR components plus `LABEL`/`TYPE`/`PREF`; Go splits 2–3 components
   and reads `f.Value`. The checksums still match because the generated corpus avoids the inputs where
   go-vcard is lossy (W3 uses `strings.ReplaceAll(\;)` instead of a full unescape). The ratios are
   therefore conservative for Pion, but the README should say so.
2. **Blind spots** (`dos.sh` B1–B4, parse only): wide cards (2 000 props/card) Pion 0.03 s = Go 0.03 s;
   heavy folding 0.01 s vs 0.00 s; escape-dense N/ADR/ORG 0.04 s vs 0.03 s; QP-heavy 2.1 cards
   0.03 s vs 0.01 s (P1-3 already visible at 1 KB lines). None of these shapes is in W1–W3, and QP
   (a README headline feature) is not benchmarked at all; a QP-heavy W4 is recommended.
3. **Where the 8–10 % goes — and how `FIX-vcard` gets past 1.0×.** Every byte of a value is copied
   three times by per-byte loops: the unfolder (`parser.pion:285` `write_byte` per byte), then
   `string_slice_bytes` (`types.pion:140-152`, used for value, group and every param value), plus
   `slice_to_upper` (`types.pion:85-94`) and the fold writer (`escaping.pion:146-150`). Pion already has
   memcpy primitives (`String::slice`, `StringBuilder::write_substring`, used across this repo). In the
   prototype (`fix_sketch.diff`): `string_slice_bytes` → `s.slice`, `slice_to_upper` fast path to
   `slice`, fold chunk via `write_substring`, QP flag computed once. Measured, 15 interleaved rounds,
   identical stdout:

   | | original | prototype | Go | prototype / Go |
   | --- | ---: | ---: | ---: | ---: |
   | W1 | 34.8 ms | 28.9 ms | 30.6 ms | **1.06×** |
   | W2 | 33.0 ms | 28.5 ms | 31.1 ms | **1.09×** |
   | W3 | 19.5 ms | 16.1 ms | 18.4 ms | **1.14×** |

   Further headroom: copy unfolded runs with `write_substring` instead of per-byte `write_byte`, and
   skip the `StringBuilder` entirely for unfolded lines (slice the input directly).
4. Peak RSS advantage (README "1.60×–2.41× lower") reproduced (20.9 vs 33.8 MiB on W1).

## Verification that the audit is fixable without touching `audit/`

`audit/fix_sketch.diff` (6 files, +241 / −52, `pionc fmt`-clean) is a prototype of every fix above:
reserved-name mapping, QP flag from parsed params + soft breaks skipped in the scanner (no LF in the
value), UTF-8 validated after unfolding, `data:` percent-decoding, VERSION position / v3 `N` / iana
`KIND` checks, calendar-date and zone validation, numeric GEO ranges, CTL stripping, empty-param
omission, CTL rejection in content lines, `max_bytes` default 16 MiB, and the memcpy hot-path
changes. Applied to a copy of the tree (never to `src/` here), the unchanged `audit/run_audit.sh all`
exits **0**: red-team tests 24/24, upstream `vcard` 13/13, differential 107/107, 4-mode identical,
G1/G2/G3 PASS. It is a sketch for `FIX-vcard`, not a reviewed patch.

## Files

| Path | Purpose |
| --- | --- |
| `run_audit.sh` | one-shot runner, exit 1 on any defect |
| `redteam_test.pion`, `pion.toml` | 18 failing findings + 6 controls (Pion test package, depends on `vcard` by path) |
| `driver/` | Pion driver: `dump` / `rt` (canonical dumps), `parse` / `fmt` / `media` (DoS) |
| `diff/cases.py`, `diff/compare.py` | spec-derived corpus with expectations; comparison (Pion gating, oracles informative) |
| `diff/go/` | go-vcard v0.1.0 oracle (`go.sum`) |
| `diff/rust/` | calcard 0.3.14 oracle (`Cargo.lock`, `--locked`) |
| `diff/gen_dos.py`, `dos.sh` | DoS / blind-spot inputs and gated probes G1–G3 |
| `fix_sketch.diff` | prototype fix used to prove the audit is satisfiable |
