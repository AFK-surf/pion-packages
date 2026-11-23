# Red-team audit: `packages/json` v0.1.0 (`feat/pkg-json` @ `44160880`)

Auditor: `RT-json`. Toolchain: `pionc 0.1.0` (`AFK-surf/pion@66d2b4b`), `cargo 1.100.0`, Node `v24.22.2`, Darwin arm64.
References: RFC 8259, RFC 8785 (JCS), RFC 6901, nst/JSONTestSuite @ `1ef36fa`, Rust `serde_json =1.0.145`
(`arbitrary_precision` + `preserve_order`, `Cargo.lock`, `--locked`), Rust std `f64` parsing, Node.js `JSON` +
the RFC 8785 Appendix canonicalizer, Go `encoding/json` (bench only).

```sh
sh packages/json/audit/run_audit.sh            # all stages, ~2 min; exit 1 while any defect below is present
sh packages/json/audit/run_audit.sh tests jcs  # selected stages
```

`audit/` only adds files; nothing outside `packages/json/audit/` is touched. All builds and outputs go to
`$OUT` (default `/private/tmp/rt-json-audit`). Every check accepts every correct fix (for example "return `Err`"
*or* "emit the RFC 8785 form"), so a fixed branch passes without changing one byte of `audit/`.

## Verdict

The parser is excellent: 0 divergences from serde_json over 6,228 syntax documents, all 318 JSONTestSuite
files, 27,508 number literals (0-ULP including exact binary64 midpoints, 800-digit and 100,000-digit literals)
and 3,027 pointer lookups; Ryu output is ECMAScript-exact on 30,000/30,000 doubles; 1,000,000-level nesting
parses, serializes, compares and drops in all 4 build modes. The defects are in what the package **emits**
and in its **object model**:

| ID | Sev | Finding | Evidence (stage / test) |
|---|---|---|---|
| P0-1 | P0 | `stringify` / `stringify_canonical` write `BigNum` text unvalidated: `Json::big_num("1,\"admin\":true")` injects keys, `big_num("NaN")` emits invalid JSON | `p0_bignum_raw_text_is_emitted_unvalidated_json_injection` |
| P0-2 | P0 | HashDoS: object hash seed is derived from attacker-controlled bytes; 840 KB of colliding keys take **2,624 ms** vs **10 ms** (256x), 1.68 MB take **11.0 s**; quadratic, reachable with default `JsonLimits` | `hashdos` |
| P1-1 | P1 | `stringify_canonical` emits non-finite numbers (`1e400`, `1E999`) instead of the error RFC 8785 §3.2.2.2 requires (41/3,013 random docs) | `jcs`, `p1_canonical_emits_nonfinite_bignum_instead_of_error` |
| P1-2 | P1 | `stringify_canonical` writes integers beyond 2^53 and `BigNum` integers with exact digits, not ECMAScript `Number::toString`: 466/3,013 documents differ from the RFC 8785 reference; one binary64 value has several canonical forms | `jcs`, `p1_canonical_big_integers_not_in_ecmascript_form` |
| P1-3 | P1 | "Immutable" values leak live internals: `get_array`/`as_array`/`entries()` return the internal `Array`; writes through a `set_field` copy change the original | `p1_set_field_copy_aliases_original_children` |
| P1-4 | P1 | Writing through `entries()` desynchronizes the O(1) index: `get` returns a value whose key is gone, misses a present key, and duplicate keys reach `stringify_canonical` output | `p1_entries_alias_desyncs_index_and_duplicates_keys` |
| P1-5 | P1 | `stringify_canonical` aborts the process (`index 1 out of bounds`, exit 134) on an object key that is not UTF-8 (e.g. `"é".slice(0, 1)`), although it returns `Result` | `utf8` |
| P2-1 | P2 | `-0` parses to `Int(0)`: sign lost (serde_json, Go, JS keep `-0.0`) | `p2_negative_zero_integer_literal_loses_sign` |
| P2-2 | P2 | `json_eq` / `Json::eq` is object-key-order sensitive (RFC 8259 §4: objects are unordered) | `p2_json_eq_is_object_order_sensitive` |
| P2-3 | P2 | `BigNum` accessors accept garbage: `big_num("abc").as_f64() == Some(0.0)` | `p2_bignum_accessors_accept_garbage` |
| P2-4 | P2 | `stringify` copies non-UTF-8 string bytes verbatim: output its own parser rejects | `p2_stringify_emits_invalid_utf8` |
| P2-5 | P2 | `without_keys` is O(n·k): 20k keys from a 40k-key object take 858 ms vs 13 ms for serde_json (64x) | `bench` H3 |

Current result: `run_audit.sh` exits **1** (stages `tests jcs utf8 hashdos` fail; 9/9 exhibits fail, 8/8 controls pass,
package's own 22/22 tests pass).

---

## P0-1 `BigNum` text is emitted unvalidated (JSON injection / invalid JSON)

```pion
let doc = Json::obj([("amount", Json::big_num("1,\"admin\":true"))])
stringify(doc)            // Ok("{\"amount\":1,\"admin\":true}")   <- extra key injected
stringify_canonical(doc)  // Ok("{\"amount\":1,\"admin\":true}")   <- and it is what gets signed
stringify(Json::obj([("a", Json::big_num("NaN"))]))  // Ok("{\"a\":NaN}")  <- invalid JSON
```

Root cause: `src/serialize.pion:277` `Json::BigNum(r) => sb.write_string(r)`; `src/types.pion:371`
`Json::big_num(repr)` accepts any `String`; `Json::BigNum(..)` is also a public variant. `BigNum` is the
documented way to carry arbitrary-precision decimals ("lossless"), so callers will put user-supplied amounts in
it. `NonFiniteNumber` is checked for `Float` only (`write_json_float`), so the "never emit NaN/Infinity" promise is
bypassed through `BigNum("NaN")`/`BigNum("Infinity")` too.

Fix: validate `BigNum` text against the RFC 8259 `number` grammar in the serializers (return `Err(InvalidNumber)`),
ideally also behind a `Json::big_num(..) -> Result` constructor.

## P0-2 HashDoS on objects with > 8 keys

`derive_seed_from_str` (`src/object_index.pion:14`) builds the per-document seed from the input length and its
first, middle and last byte; `hash_str_seeded` (`:41`) is a fixed public function; the table uses the low bits
with linear probing (`insert_if_absent`, `:141`; parser `src/parser.pion:490,524`). An attacker fixes those four
inputs (`{`, `}`, a pinned middle byte, a chosen length) and brute-forces keys whose hash is 0 modulo the final
capacity (`oracle/rust` `hashgen`: 40,000 keys in 3.9 s on 12 cores). Every insert then probes the whole cluster:

| keys (doc size) | colliding keys | ordinary keys | serde_json (either) |
|---:|---:|---:|---:|
| 40,000 (840 KB) | 2,624.5 ms | 10.2 ms | 7.2 ms |
| 80,000 (1.68 MB) | 10,990 ms | 20 ms | — |

Doubling the keys quadruples the time (O(N²)); a 64 MiB document (default `max_bytes`) is hours of CPU per request.
`JsonObject::from_pairs`/`build_json_object` use `derive_seed_from_entries` (`:25`), equally predictable.
The README claims "zero O(n²) degradation on 50k+ key objects".

Fix: a keyed hash with a secret per-process (or per-parse, from a CSPRNG) seed such as SipHash-1-3, or a
probe-length cap that falls back to an ordered tree; never derive the seed from the input.

## P1-1 `stringify_canonical` emits non-finite numbers

`parse("1e400")` gives `BigNum("1e400")` (documented); `stringify_canonical` then writes `1e400`. RFC 8785
§3.2.2.2: numbers must be I-JSON (IEEE-754 binary64) and non-finite values "MUST cause an error". `[1E400, 1e400,
10e399]` canonicalizes to three different byte strings for the same (non-)value. 41/3,013 random documents.
Fix: in canonical mode, convert `BigNum` with `as_f64()` and return `Err(NonFiniteNumber)` on `None`.

## P1-2 `stringify_canonical` big integers are not in ECMAScript form

`src/serialize.pion:263` (`Json::Int` -> `write_i64`) and `:277` (`BigNum` raw) bypass the ES formatter:

| input | Pion canonical | RFC 8785 (Node reference, any conformant impl) |
|---|---|---|
| `9007199254740993` | `9007199254740993` | `9007199254740992` |
| `9223372036854775807` | `9223372036854775807` | `9223372036854776000` |
| `18446744073709551615` | `18446744073709551615` | `18446744073709552000` |
| `123456789012345678901234567890` | `123456789012345678901234567890` | `1.2345678901234568e+29` |

466/3,013 random documents (every one whose numbers include |n| > 2^53 as integer literals) produce different
canonical bytes than the reference, so a signature made by any other JCS implementation fails to verify in Pion
and vice versa, and `18446744073709551616` / `18446744073709551616.0` / `18446744073709551617` (one binary64 value)
get three different canonical forms. All other number forms are exact: 30,000/30,000 doubles match
`Number::toString` byte for byte, including `-0.0 -> 0`, `1e20` vs `1e+21`, `0.000001` vs `1e-7`, `5e-324`.
Fix: in canonical mode format every number through its binary64 value (`Int` beyond ±2^53 and `BigNum`), or
reject numbers that are not exactly representable (the RFC's Appendix advises carrying such values as strings).

## P1-3 / P1-4 The "immutable" value model aliases its mutable internals

```pion
let a = parse("{\"arr\":[1],\"o\":{\"x\":1}}")
let b = a.set_field("new", Json::int(1L))          // "immutable update"
b.get_array("arr").unwrap().push(Json::str("INJECTED"))
stringify(a) // {"arr":[1,"INJECTED"],"o":{"x":1}}   <- the original changed

let big = parse("{\"k0\":0,...,\"k9\":9}")          // > 8 keys: hash index
let es = big.as_obj().unwrap().entries()
es[0] = ("evil", Json::int(666L)); es.push(("k1", Json::int(777L)))
big.get("k0")      // Some(666): returns the value now stored under "evil"
big.get("evil")    // None
stringify_canonical(big) // {"evil":666,"k1":1,"k1":777,...}  <- duplicate key in "canonical" output
```

Root cause: `JsonObject::entries()` (`src/types.pion:223`), `Json::as_array`/`get_array` (`:476`, `:540`) return
the internal `Array` (Pion arrays are mutable references); `set`/`set_field` copy only the top level and share
children; `Json::arr(items)`/`Json::obj(pairs)` keep the caller's array. The index (`ObjectHashIndex`) is
not updated by such writes. The README promises an immutable value tree and `Send` values; the duplicate keys in
canonical output defeat `DuplicateKeyPolicy::Reject`-based key-smuggling defenses downstream.
Fix: return copies (or a read-only view type) from `entries()`/`as_array()`/`get_array()`, copy the input arrays
in `Json::arr`/`Json::obj`/`from_pairs`, or make the containers persistent/immutable types.

## P1-5 `stringify_canonical` panics on non-UTF-8 keys

`next_utf8_cp` (`src/serialize.pion:63`) trusts the lead byte and reads `pos+1..pos+3` without a bound check;
`cmp_utf16_code_units` (`:84`) calls it on every key during the sort. Pion `String` admits any bytes
(`String::slice` is byte-indexed: `"é".slice(0, 1)` is the lone byte `0xC3`; `StringBuilder::write_byte`).
`run_audit.sh utf8`: `stringify` returns `Ok` (with invalid UTF-8, P2-4), `stringify_canonical` aborts with
`pion panic: index 1 out of bounds (len 1)`, exit 134, native release and debug. Fix: validate keys/strings in the
serializer (`Err(InvalidUtf8)`), or bound-check in `next_utf8_cp`.

## P2

- **P2-1 `-0`**: `src/parser.pion:323` returns `Json::Int(0L)` for `-0`, so `as_f64()` is `+0.0` and `stringify`
  prints `0`. serde_json yields `f64 -0.0`, Go `float64(-0)`, JavaScript `-0`. `-0.0` is preserved correctly.
- **P2-2 `json_eq` order**: `src/serialize.pion:410` compares entries positionally;
  `{"a":1,"b":2}` != `{"b":2,"a":1}`. serde_json's `Value` (IndexMap equality is order-independent even with
  `preserve_order`), Go `reflect.DeepEqual` on maps and JS deep-equal libraries treat them as equal.
- **P2-3 `BigNum` accessors**: `parse_raw_as_f64` (`src/float_parse.pion:824`) does not check that the text is a
  number; `big_num("abc")` / `big_num("1.5.5")` return `Some(0.0)` / a number from `as_f64()`.
- **P2-4 invalid UTF-8 output**: `write_json_string` (`src/serialize.pion:12`) copies bytes verbatim, so
  `stringify(Json::str(<bytes FF C0 80 ED A0 80>))` is `Ok` with output that `parse` rejects.
- **P2-5 `without_keys` O(n·k)**: nested linear scan (`src/types.pion:296`). H3: 858 ms vs 13 ms (serde_json
  `HashSet` filter). `JsonObject::set` also rebuilds the whole entries array and hash index per call, so N
  successive `set_field`s are O(N²) (inherent to copy-on-write without structural sharing; worth documenting).

## Controls: attacked and found sound

| Area | Result |
|---|---|
| RFC 8259 grammar | 6,228/6,228 agree with serde_json: leading zeros (`01`, `-01`, `00`), `+1`, `1.`, `.1`, `1e`, `1e+`, comments, trailing commas, single quotes, unquoted keys, BOM, NBSP/`\v`/`\f`, raw `0x00..0x1F`, `\a`/`\x41`/`\v`/`\'`, truncated escapes, trailing garbage, 3,000 mutated docs |
| UTF-8 / surrogates | overlong, CESU-8, `U+D800..DFFF` encoded, `> U+10FFFF`, truncated, stray continuation bytes rejected; `\uD800`, `\uDFFF`, `\uDC00\uD800`, `\uD83DA` rejected; `😀` -> `😀` |
| JSONTestSuite @ 1ef36fa | 318/318 agree with serde_json; y_ 95/95 accepted, n_ 188/188 rejected, i_ 10 accepted / 25 rejected |
| Number model | 27,508/27,508 agree: `i64::MIN/MAX` exact `Int`, `2^53+1` exact, `i64::MAX+1`/`u64::MAX` -> `BigNum` with exact `as_u64`, `u64::MAX+1` -> `as_u64() == None`, `1e400` -> `BigNum` (never `Infinity`), 3,000 exact binary64 midpoints ±1 digit (ties-to-even), `2.2250738585072011e-308`, `2.4703282292062327e-324` vs `...28e-324`, 2,000 400..800-digit decimals, 100,000-digit literals (linear time) |
| Number formatting | 30,000/30,000 `stringify_canonical` == ES `Number::toString`; 30,000/30,000 `stringify` bit-exact round trips; NaN/±Inf `Float` -> `Err(NonFiniteNumber)` |
| JCS keys/strings | UTF-16 code-unit order (`U+10000`/`😀` before `U+E000..U+FFFF`), only `"` `\` `0x00..0x1F` escaped, short escapes for `\b\f\n\r\t`, lowercase `\u00xx`, `/` and non-ASCII unescaped; all 2,506 RFC-correct docs byte-identical to Node |
| Duplicate keys | `Reject` catches escaped-equivalent (`"a"`/`"a"`), nested and hash-indexed duplicates; `LastWins` keeps the first slot with no ghost keys, index consistent; `FirstWins` correct |
| RFC 6901 | 3,027/3,027 agree with serde_json; `""` root, `"/"` empty key, `~01` -> `~1`, `/01` and `/-` on arrays -> none, `~2` / dangling `~` / no leading `/` -> `Err(InvalidPointer)` (stricter than serde_json, correct per RFC) |
| Limits | `max_depth` 0/-1, `max_bytes` -1, `max_elements` 0, `max_string_bytes` 0 (incl. escaped strings and keys) all fail closed |
| Depth / stack | default limit rejects deep input; with raised limits 20k, 100k and 1M levels of `[` and `{"k":` parse, `stringify`, `stringify_canonical`, `json_eq`, drop with exit 0 in native dbg/rel and wasm32 dbg/rel (no SIGSEGV, no `RangeError`). `stringify_pretty` output is O(depth²) bytes (400 MB for 20k levels at indent 1), inherent to indentation, not a defect |
| 4-mode parity | syntax, numbers, numfmt, jcs, ptr, rt, jsonts, `Reject` and `FirstWins` outputs byte-identical across native dbg/rel + wasm32 dbg/rel (9 sets, 78,000+ lines) |
| Round trips | 6,285/6,285 accepted docs: compact and pretty re-parse `json_eq` to the original, canonical is a fixed point |

Note on the oracle: Rust std `str::parse::<f64>` saturates exponents above 65,535, so for
`"1" + 10,000,000 zeros + "e-10000001"` it returns `inf` while Pion correctly returns `0.1` (checked with Python
`float`). No such literal is in the differential corpus; it is recorded here because Pion is right and Rust is not.

## Benchmarks

### W1/W2/W3 reproduction (`sh packages/json/bench/run_bench.sh`, same machine, SHA-256 gated)

| Workload | rust_serde_json | go_encoding_json | pion_json | Pion vs Rust (README) | Pion vs Go (README) |
|---|---:|---:|---:|---:|---:|
| W1 parse 5 × 3.44 MB | 62.6 ms | 158.5 ms | 103.1 ms | 0.61x (0.78x) | 1.54x (1.59x) |
| W2 parse+extract+stringify 8 × 2.07 MB | 101.3 ms | 185.5 ms | 201.4 ms | 0.50x (0.47x) | 0.92x (0.64x) |
| W3 50k keys parse+lookups+JCS 5 × 1.55 MB | 117.7 ms | 427.5 ms | 208.4 ms | 0.56x (0.33x) | 2.05x (1.03x) |

All three SHA-256 checks pass. The README's ratios do not reproduce (W1 is worse, W3 better than published);
the README table should be regenerated rather than quoted.

Fairness:
- Rust uses default `serde_json` features: no `float_roundtrip`, so its float parsing is the fast, not always
  correctly rounded path, while Pion is 0-ULP; W1 (and W2's float fields) favour Rust slightly. `Map` is a
  `BTreeMap` (O(log n) lookups in W3) and W3 builds every key/value with a separate `serde_json::to_string`
  allocation, which handicaps Rust in W3. Go uses `UseNumber` (fair for integers). All three canonical outputs
  are only ints/strings, so P1-2 does not affect the W3 hash.
- The workloads are fair for parsing and lookups; none exercises adversarial keys (see H1/H2) or `without_keys`.

### Where W2/W3 lose time (phase timings, 20 iterations, best of 5, release build)

| Phase | W2 (2.07 MB) | W3 (1.55 MB, 50k keys) |
|---|---:|---:|
| `parse` only | 13.0 ms/iter | 8.0 ms/iter |
| + 2 pointer lookups per record / 50k `contains_key` | +2.0 ms | +2.5 ms |
| + `stringify` of the whole doc | +7.0 ms | +3.5 ms |
| + `stringify_canonical` of the whole doc | — | +16.5 ms |

- W3: `stringify_canonical` is 2/3 of the time beyond parsing. `sort_entries_utf16` (`src/serialize.pion:154`)
  copies the 50k entries twice with `push` and runs a merge sort calling `cmp_utf16_code_units` (decoding UTF-8 to
  UTF-16 per comparison, `:84`). For valid UTF-8, UTF-16 order equals byte order except when the first differing
  bytes are a 3-byte lead `0xEE`/`0xEF` (U+E000..U+FFFF) against a 4-byte lead `0xF0..0xF4`; a byte-wise compare
  with that one fix-up (or sorting precomputed UTF-16 keys once) removes almost all of this cost.
- W2: parsing itself is the gap (Pion's parse alone ≈ Rust's whole W2 iteration). `parse_str_impl` runs a full
  `validate_utf8_str` pass before parsing (`src/parser.pion:519`) and every byte goes through bounds-checked
  `code_unit_at`; an ASCII fast path (8 bytes at a time) for validation and string scanning, and validating UTF-8
  inside the string scanner instead of a separate pass, are the hot spots. `Json::pointer` per record (README's
  explanation) is only ~2 ms of ~25 ms per iteration.

### Adversarial (`run_audit.sh bench`, scripts/bench_compare.py, warmup 1, 5 interleaved rounds, SHA-256 gated)

| Workload | pion median | serde_json median | ratio |
|---|---:|---:|---:|
| H1 parse + 40k lookups, 40k colliding keys (840 KB) | 2,675.4 ms | 12.0 ms | 0.004x |
| H2 same with ordinary keys | 14.3 ms | 11.2 ms | 0.78x |
| H3 `without_keys` 20k of 40k keys | 858.3 ms | 13.4 ms | 0.02x |

## Files

| Path | Role |
|---|---|
| `run_audit.sh` | one-command audit; exit 1 while any defect is present |
| `redteam_test.pion`, `pion.toml` | 9 exhibits (`p*_`) + 8 controls (`ctl_*`), `pionc test packages/json/audit` |
| `driver/` | Pion differential driver (`parse`/`canon`/`rt`/`numfmt`/`ptr`/`adv`/`deep`/`utf8`) |
| `oracle/rust/` | serde_json =1.0.145 oracle (`Cargo.lock`), HashDoS key generator (`hashgen`) replicating `object_index.pion` |
| `oracle/node/oracle.mjs` | RFC 8785 reference canonicalizer and `Number::toString` |
| `tools/gen_cases.py` | deterministic corpus generator (seeded) |
| `tools/compare.py`, `tools/jcs_compare.py` | line differential and RFC 8785 classifier |
