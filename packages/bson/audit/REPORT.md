# Red-team audit: `packages/bson` @ `341de2d` (`feat/pkg-bson`)

Auditor: RT-bson (independent adversarial review). Scope: BSON 1.1 binary codec, IEEE 754-2008 BID
`Decimal128`, Extended JSON v2 (Canonical & Relaxed), DoS / stack safety, 4-mode Native/Wasm32
consistency, and fairness of `bench/` (W1/W2/W3).

| | |
| --- | --- |
| Target | `packages/bson` @ `341de2d`, not modified (this branch only adds `packages/bson/audit/**`) |
| Toolchain | `pionc 0.1.0` built from `AFK-surf/pion@79d1fbd` (runtime path `/tmp/pion-upgrade-79d1fbd`), node for wasm32 |
| Oracle 1 | Rust `bson =2.15.0` (+ `serde_json` `preserve_order`), `audit/oracle/rust` |
| Oracle 2 | Go `go.mongodb.org/mongo-driver/v2` **v2.4.1** `bson`, `audit/oracle/go` |
| Spec | MongoDB `specifications` @ `2a20bd509e2ad4ee354b552145094ecdf434ee9d`: `bson-corpus` (31 files, 986 cases), `extended-json.md`, `bson-decimal128` |
| Reproduce | `sh packages/bson/audit/run_audit.sh` (~40 s build+run on M-series; everything goes to `/private/tmp/rt-bson-audit`) |

## Verdict

The codec is strong on Decimal128 arithmetic, double formatting, deep nesting and the bulk of the
spec, but it has **one P0 memory-safety class** (13-byte inputs abort the process on native and
wasm32), **five P1 spec-conformance defects** that fail 15 assertions of the official BSON Corpus that
both Rust and Go pass, and **five P2 issues**. The W1 "2.14× faster than Rust" headline is
produced by extra work in the Rust harness: with that removed Pion's lead is 1.65×, and Rust's own
zero-copy API (`RawDocument`) is **1.93× faster than Pion**.

| ID | Sev | Finding | Evidence (all reproducible by `run_audit.sh`) | Unit tests (FAIL today) |
| --- | --- | --- | --- | --- |
| P0-1 | **P0** | Signed 32-bit overflow in 6 length bounds checks of `decode()` → out-of-bounds index / 2 GiB alloc → process abort on 13–26-byte inputs | 43 aborting inputs (34 targeted + 9 found independently by mutation fuzz); native `SIGABRT` (134), wasm32 `pion panic`; Rust & Go return errors | `p0_*` (8) |
| P1-1 | P1 | Type-wrapper objects with extra/legacy keys are silently kept as ordinary documents (and partially converted) | 11 official corpus `top.json` parseErrors accepted; 20/21 adversarial vectors disagree with the consensus of Rust & Go | `p1_corpus_top_bad_*` (10), `p1_binary_extra_field_*` |
| P1-2 | P1 | Array keys validated by default → 3 official corpus **valid** vectors rejected | `array.json` degenerate BSON; 11 targeted + 1 fuzz vector; Rust & Go decode them | `p1_corpus_array_*` (3) |
| P1-3 | P1 | Regex options never alphabetized (decode, encode, from/to ExtJSON) | corpus `regex.json` "flags not alphabetized" ×2; spec footnote "MUST be in alphabetical order"; Rust & Go sort | `p1_corpus_regex_*` (2), `p1_regex_canonical_extjson_options_sorted` |
| P1-4 | P1 | Wrapper values of the wrong type accepted (`$date:{$numberInt}`, `$minKey:{$numberInt}`, `$timestamp.t:{$numberInt}`) | spec "values of an incorrect type … MUST report an error"; Rust & Go reject | `p1_date_*`, `p1_minkey_*`, `p1_timestamp_*` |
| P1-5 | P1 | Invalid UTF-8 passes `from_extjson` / `encode` unchecked → Pion emits BSON that its own `decode` rejects | `{"a":"\xff"}`, key `C0 AF`, regex `FE` → `encode` OK, `decode` Err; Rust rejects the input | `p1_extjson_invalid_utf8_*`, `p1_encode_invalid_utf8_*` |
| P2-1 | P2 | `$numberDouble` limited to strict JSON grammar: `"1."`, `".5"`, `"-.5"`, `"inf"` rejected | 9 vectors, Rust & Go both accept | `p2_numberdouble_*` |
| P2-2 | P2 | ISO-8601 `$date` accepts `+00` offset (RFC 3339 requires `+HH:MM`) | Rust & Go reject | `p2_date_rfc3339_*` |
| P2-3 | P2 | `to_extjson` aborts on a malformed `ObjectId` / `Decimal128` value that `encode` rejects with `Err` | pub `bytes` field of length 3 / 4 → index panic | `p2_to_extjson_malformed_*` (2) |
| P2-4 | P2 | `to_extjson` emits `{"$timestamp":{"t":-1,…}}` (encode rejects it, from_extjson rejects it) | asymmetric validation | `p2_to_extjson_out_of_range_timestamp_*` |
| P2-5 | P2 | Bench W1 claim is inflated by the Rust harness (see §6) | `rust_ref` 1.65× / `rust_raw` 0.52× of Pion's time | — |

Unit-test summary (`pionc test packages/bson/audit`): **41 tests, 35 FAIL (findings), 6 PASS
(controls)**. `sh scripts/verify.sh packages/bson` stays 25/25 green (the audit is its own package and
is not picked up by the parent package's test run).

---

## 1. P0-1 — signed overflow in decode bounds checks (process abort)

`Int` is 32-bit and wraps (`2147483647 + 1 == -2147483648` on native and wasm32). Every
length-prefixed element is checked as `pos + len > frame.end_pos - 1`; for `len` close to
`0x7FFFFFFF` the sum wraps negative, the check passes, and the next access indexes at
`pos + len - 1 ≈ -2^31` (or allocates `Bytes::new(0x7FFFFFFF)`):

| Site | Type | Example input (hex) | Pion | Rust 2.15.0 | Go v2.4.1 |
| --- | --- | --- | --- | --- | --- |
| `decode.pion:292` | String / JavaScript / Symbol | `0e000000026100ffffff7f780000` (14 B) | `pion panic: index -2147483639 out of bounds (len 14)`, exit 134 | `Err: expected buffer to contain at least 2147483651 bytes` | `Err` (or `PANIC`, see note) |
| `decode.pion:320` | Document / Array | `0d000000036100ffffff7f0000` (13 B) | index −2147483643, exit 134 | `Err: length exceeds remaining length` | `Err: too few bytes` |
| `decode.pion:348` | Binary | `0f000000056100ffffff7f00aabb00` | `pion_rt.c:155: container length exceeds maximum`, exit 134 | `Err` | `Err` / `PANIC` |
| `decode.pion:448` | DBPointer | `1a0000000c6100ffffff7f78000101…0100` | index −2147483639, exit 134 | `Err` | `PANIC` |
| `decode.pion:480` | CodeWScope inner string | `170000000f61000f000000ffffff7f7800050000000000` | index −2147483635, exit 134 | `Err` | `Err: EOF` |

(`decode.pion:473`, the CodeWScope *total* length, also wraps but is caught by the inner check; it is
kept as a control.) The abort is identical in all four modes (§4): on wasm32 the runtime throws
`Error: pion panic: index out of bounds`, so a host embedding the module loses the instance.

* Reach: any caller of `bson::decode` / `decode_with_limits` on untrusted bytes; default limits do not
  help (the input is 13 bytes). Mutation fuzzing found 9 more crashing inputs on its own.
* Fix: compare against remaining space instead of adding, e.g.
  `if slen < 1 || slen > frame.end_pos - 1 - pos { … }` (and the same shape for `sub_len`, `blen`
  (`blen > end - 1 - pos - 1`), DBPointer `slen > end - 1 - pos - 12`, CWS `slen > cws_end - pos - 5`,
  `cws_len > end - 1 - cws_start`). `pos`/`end_pos` are always `<= data.length()`, so these cannot wrap.
* Go note: on some of these inputs Go panics (recovered by the oracle wrapper, shown as `PANIC`);
  Rust returns an error for all of them. Pion is therefore below Rust, roughly level with Go
  on this class — but Go recovers, Pion cannot.

## 2. Official MongoDB BSON Corpus (986 cases → 2,818 spec-runner assertions)

Graded with the corpus runner rules (`decode(cB)→encode==cB`, `→canonical EJ`, `→relaxed EJ`,
`decode(dB)→cB`, `parse(cEJ/dEJ)→cB`, `parse(rEJ)` ok, every `decodeErrors` / `parseErrors` entry
rejected). ExtJSON is compared structurally (`$numberDouble` by IEEE bits, so `5e-324` vs `5E-324` is
not a failure).

| Implementation | pass | fail |
| --- | ---: | ---: |
| Pion `bson` | 2,802 | **16** |
| Rust `bson` 2.15.0 | 2,797 | 21 |
| Go mongo-driver v2.4.1 | 2,812 | 6 |

Pion's 16: **15 that both Rust and Go pass** (hard evidence) + 1 shared with both
(`top.json` "Bad $date (number, not string or hash)", all three accept `{"$date": 42}`).

| File | Case | Check | Pion |
| --- | --- | --- | --- |
| `array.json` | index set to empty key / to `ab` / duplicate indexes | `decode(dB)→cB` | `ERR invalid array key` (P1-2) |
| `regex.json` | flags not alphabetized | `decode(dB)→cB`, `parse(dEJ)→cB` | keeps `mix` (P1-3) |
| `top.json` | Bad `$oid` / `$numberInt` / `$numberLong` / `$numberDouble` / `$numberDecimal` / `$code` / `$timestamp` / `$date` / `$minKey` / `$maxKey` (extra field) | parseError | accepted as a sub-document (P1-1) |

For balance: Rust's 21 failures are 19 Decimal128 syntax leniencies (`"E+02"`, `"."`, `""`, `"+-32.4"`
all parse) plus 4 clamped-zero exponents it cannot parse and 2 framing/date cases; Go's 6 are 4
invalid-UTF-8 strings it accepts, the `$date` number, and one panic on a zero length. **Pion is
better than Rust on Decimal128 syntax and better than Go on UTF-8.**

## 3. Adversarial differential (4,993 vectors, seed 20261123)

`diff/gen_vectors.py` → `diff/diff_vectors.py`. Verdicts: `CRASH` (Pion aborted), `CONSENSUS` (Rust
and Go agree, Pion differs: hard evidence), `SPLIT` (the two references disagree; informational).

| Area | Vectors | AGREE | CRASH | CONSENSUS | SPLIT (Pion sides with) |
| --- | ---: | ---: | ---: | ---: | --- |
| Length lies (`len_*`, envelope, code_w_scope) | 252 | 214 | **34** | 0 | 4 (Rust 3, Go 1) |
| UTF-8 in strings/keys/regex/code/dbpointer | 199 | 81 | 0 | 1 (regex options order, P1-3) | 117 (Rust 117: Go accepts bad UTF-8) |
| Binary subtypes / Vector / BinaryOld | 80 | 79 | 0 | 0 | 1 (Rust) |
| Array keys | 13 | 2 | 0 | **11** | 0 |
| Regex options | 10 | 5 | 0 | **5** | 0 |
| Double (bits, specials, 600 random) | 654 | 647 | 0 | 0 | 7 (Go: Rust prints subnormals as bare numbers in *canonical* mode) |
| DateTime / Int32 / Int64 / Timestamp / Bool / unknown types | 48 | 48 | 0 | 0 | 0 |
| Duplicate keys | 2 | 0 | 0 | 0 | 2 (Go: both preserve, Rust last-wins) |
| Decimal128 strings (93 edge + 700 random) | 792 | 777 | 0 | 0 | 15 (Go 10, Rust 2, alone 3: `-NaN`/`sNaN` → `0x7C…`) |
| Decimal128 bit patterns (100 edge + 400 random + 150 in BSON) | 650 | 625 | 0 | 0 | 25 (Rust 25: Go mis-renders non-canonical significands > 10^34−1) |
| ExtJSON wrappers / numbers / dates / binary / uuid / strings / structure | 293 | 216 | 0 | **35** | 42 (Rust 21, Go 16, alone 5) |
| Mutation fuzz of well-formed seeds | 2,000 | 1,925 | **9** | 1 (array key) | 65 (Rust 55, Go 10) |
| **Total** | **4,993** | **4,619** | **43** | **53** | **278** |

51 of the 53 `CONSENSUS` rows map to P1-1 … P1-4 and P2-1/P2-2; the other 2 are
`{"$code":"x","$scope":{"$numberInt":"1"}}` / `…{"$oid":…}}`, which Pion rejects (it converts the
scope object into an Int32/ObjectId first) while Rust and Go keep the scope as a document with a
`$`-key. Such a scope cannot be represented unambiguously in ExtJSON (spec "Restrictions and
limitations"), so this is noted, not counted. With the corpus requests this is
**7,053 differential requests**, of which ~2,700 exercise Decimal128 (parse, format, BID bytes).

Decimal128 (≥1,000 cases asked for): **0 consensus disagreements.** Clamping
(`0E+99999→0E+6111`, `100E-6178→1E-6176`, `1E+6144→1.000…000E+6144`), overflow/underflow errors,
the `adjusted_exp < -6` / `exp > 0` display threshold, trailing-zero preservation and non-canonical
`11`-combination / `>10^34−1` significands all match Rust byte-for-byte. Pion only differs on
`-NaN` (sign dropped) and `sNaN` (stored as quiet `0x7C`, Rust keeps `0x7E`); the decimal128 spec
makes sNaN support optional (MAY) and renders both as `"NaN"`, so this is not counted as a finding.

## 4. 4-mode consistency (native release/debug, wasm32 release/debug)

All 7,053 corpus + adversarial requests through all four builds: **identical output in every mode
(sha256 `69a583a1…`)**, the same 43 aborts in every mode, 0 wasm `RuntimeError`/`unreachable` traps
outside those 43 `pion panic`s. The P0 is therefore not a native-only artefact.

## 5. DoS / stack safety

Controls that **passed** (Pion better than at least one reference):

* Depth with limits lifted (`max_depth = 2^31−1`), 500 / 5,000 / 20,000 / 1,000,000 levels, native and
  wasm32, for `decode`, `encode`, `to_extjson`, `from_extjson`, `bson_doc_eq` and RC teardown of the
  tree: all succeed, ≤ 0.44 s at 10^6 levels. **Rust `Document::from_reader` overflows its stack and
  aborts (`SIGABRT`) at 20,000 levels**; Go decodes them; both reference ExtJSON parsers refuse ≥ 200
  levels.
* Default `max_depth = 128` is enforced identically by all four entry points (128 ok, 129 rejected).
* Wide documents (10^5 … 10^6 keys): linear in all four entry points (0.24 s for 10^6-key ExtJSON
  parse). No O(n²) found.
* Malicious root/element lengths (`-1`, `0x80000000`, length > buffer) are rejected without
  allocation, except the overflow class of P0-1.

Observation (not a finding): memory amplification ≈ 20–50× (1M-entry document of 12.9 MB → 260 MiB
RSS; 1M-deep nesting of 8 MB → 393 MiB). Under the default limits (16 MiB / 1M elements / depth 128)
this bounds a single decode to a few hundred MiB, comparable to Rust's `Document`.

## 6. Benchmark fairness (`bench/`, W1/W2/W3)

Same machine, same `bench/gen_corpus.py` corpus, `scripts/bench_compare.py --warmup 1 --rounds 7`,
stdout SHA-256 identical across all implementations in every table.

**W1 decode + walk (50,000 docs)**

| Implementation | Median (ms) | vs Pion |
| --- | ---: | ---: |
| `pion` (official) | 59.9 | 1.00× |
| `rust_official` (`bench/rust_bench`) | 129.3 | Pion 2.16× faster |
| `rust_ref`: same decode, walk by reference (no `doc.clone()`, no per-node `Vec` of owned values) | 98.9 | Pion 1.65× faster |
| `rust_raw`: `RawDocument::from_bytes` + walk over `RawBsonRef` (bson's documented zero-copy path) | **31.1** | **Rust 1.93× faster** |

The official Rust walker starts with `Bson::Document(doc.clone())` and turns every node into owned
values (`d.into_iter().collect()`), i.e. it deep-copies each decoded document once more inside the
timed region; Pion's walker shares the tree. That accounts for ~30 ms of Rust's 129 ms. A reader
choosing the idiomatic Rust API for "decode and look at everything" would use `RawDocument`, which
validates every element it yields (UTF-8 included) and is twice as fast as Pion.

**W2 encode** — fair: `rust_to_vec` 45.8 ms vs official 47.1 ms; Pion 42.6 ms (1.07–1.11×).

**W3 ExtJSON** — Pion 1.77× (150.8 vs 266.5 ms). Rust's only public ExtJSON API goes through
`serde_json::Value` (IndexMap with `preserve_order`) and `into_*_extjson(self)` consumes its input, so
the per-document `clone()` is API-imposed; we report the number as-is, with that caveat. The corpus
has no escapes, no non-ASCII and only `x.5` doubles, so the formatting paths most likely to be slow
(escaping, shortest double) are not exercised.

Recommendation: report W1 against `rust_raw` and `rust_ref` as well, and add a W1 variant whose walk
only touches part of each document (where lazy raw decoding is expected to win even more).

## 7. Details for P1/P2

**P1-1 extra keys (`extjson.pion:861-1150`).** `ej_convert_special_object` only recognises a wrapper
when the object has exactly 1 key (or `$code`+`$scope`); with any extra key it falls through to
`Ok(BsonValue::Document(entries))`. Because children are converted before parents
(`extjson.pion:1265/1292`), `{"$date":{"$numberLong":"1"},"x":1}` becomes a sub-document
`{"$date": Int64(1), "x": true}`: a silently type-confused value instead of an error. The same path
turns the legacy `{"$binary":"AA==","$type":"00"}` into a document with a `"$binary"` string field
(Rust: error; Go: legacy Binary). Fix: if any key of the object is a Conversion-table keyword, require
the exact key set (order-insensitive) or return `InvalidExtJson`.

**P1-2 array keys (`types.pion:171,185`, `decode.pion` `dec_check_array_key`).**
`validate_array_keys` is `true` in `BsonLimits::default()` and hard-wired `true` in `BsonLimits::new`.
The corpus lists `"0"`→`""`, `"ab"`, duplicate `"0"` as valid degenerate BSON; drivers ignore array
keys on read and rewrite them on write. Fix: default to `false` (keep the strict mode opt-in).

**P1-3 regex options (`decode.pion:417`, `encode.pion:287/425`, `extjson.pion:451`).** Options are
stored verbatim. Fix: sort the option characters when constructing the value (decode and
`from_extjson`) and in `encode`/`to_extjson` (as Rust's `Regex::new` and Go do).

**P1-4 wrong value types (`extjson.pion:934,1050,1128`).** `$date` accepts `Int32` (i.e. a
`{"$numberInt"}` wrapper, or a bare JSON number), `$minKey`/`$maxKey` accept `Int32(1)` produced from
`{"$numberInt":"1"}`, `$timestamp` fields accept converted wrappers. Fix: check the raw JSON token type
(the parser should keep "was a JSON number literal" vs "was a converted wrapper").

**P1-5 invalid UTF-8 (`extjson.pion:591` `ej_parse_json_string`, `encode.pion:234`).** Pion `String`
is a byte string and `Bytes::to_string` does not validate, so `from_extjson` and `encode` receive and
emit arbitrary bytes; `decode` correctly rejects the result (`string.json` decodeErrors), so the
library breaks its own round trip. Fix: validate UTF-8 once in `from_extjson` (input) and in `encode`
for keys, strings, regex, code, symbol and DBPointer namespaces (or document that callers must).

**P2-1 `$numberDouble` (`extjson.pion:742`)** delegates to `json5` strict JSON; the spec only says
"decimal string" and both references accept `1.`, `.5`, `-.5`, `inf`. **P2-2** `ej_parse_iso8601_ms`
treats the `:MM` part of the offset as optional (`extjson.pion:231`). **P2-3/P2-4**: `to_extjson`
does not apply the same value checks as `encode` (ObjectId 12 bytes, Decimal128 16 bytes, Timestamp
u32 range); the first two index past the end of the public `bytes` field and abort.

## 8. Not findings (checked, Pion correct or within spec)

Embedded NUL inside BSON strings/code/symbol/DBPointer (allowed, round-trips); embedded NUL in keys
and regex rejected by `encode`; BinaryOld inner-length checks; UUID/Vector payloads of any size (as
Rust/Go); relaxed `$date` falls back to `$numberLong` for `< 0` and `> 9999-12-31T23:59:59.999Z`,
`INT64_MIN/MAX` safe; doubles: `-0.0`, all NaN payloads → `"NaN"`, ±Infinity, shortest round-trip for
1,000+ doubles incl. `5e-324`, `DBL_MAX`, `0.30000000000000004`, `1e21`, `2^53+1` (bits identical
after canonical and relaxed round trip); duplicate keys preserved in order (as Go; Rust keeps the last);
`$uuid` strict 36-char form (no-hyphen form is MAY); `$code`+`$scope` in either order; JSON lone
surrogates rejected; `$code`+`$scope` whose scope object is itself a type wrapper is rejected (Rust/Go
keep it as a document; ambiguous in the spec, see §3).

## Files

| Path | Purpose |
| --- | --- |
| `audit/pion.toml`, `audit/redteam_test.pion` | 35 failing `p0_`/`p1_`/`p2_` tests + 6 passing controls |
| `audit/probe/` | Pion line-protocol probe (`diff`, `deep`, `wide`), built in 4 modes |
| `audit/oracle/rust/`, `audit/oracle/go/` | Rust `bson =2.15.0` and Go mongo-driver v2.4.1 oracles (same protocol, locked deps) |
| `audit/diff/diff_corpus.py` | official BSON Corpus runner over the three implementations |
| `audit/diff/gen_vectors.py`, `diff_vectors.py` | 4,993-vector adversarial generator and three-way differential |
| `audit/diff/fourmode.py` | native/wasm32 × debug/release consistency |
| `audit/diff/gen_deep.py`, `oneshot.py` | DoS / depth one-shots with exit status, time and RSS |
| `audit/bench/rust_fair/` | W1/W2 Rust variants without harness overhead (`decode_ref`, `decode_raw`, `encode_vec`) |
| `audit/run_audit.sh` | runs all of the above (`STEPS=` to select) |
