# Red-team audit: `packages/json5` @ `b9f6a1f` (`feat/pkg-json5`)

This is the case against the pure Pion JSON5 v2.0 / JSONC / RFC 6901 / RFC 6902 package. Each finding was run on the
same bytes, on the same machine (`tokyo-mac-studio-0`, Apple M5 Max, macOS 27.0.1, 2026-11-23), against:

| reference | role |
|---|---|
| Node `json5@2.2.3` (Node v24.22.2) | JSON5 v2.0 reference implementation (identifier tables: Unicode 10) |
| Rust `json5 =1.3.8` | Independent JSON5 implementation (identifier tables: Unicode 17, ES5.1 categories) |
| `JSON.parse` / `serde_json =1.0.140` | strict RFC 8259 |
| Rust `json-patch =4.2.0`, Node `fast-json-patch@3.1.1` | RFC 6902 |

The audit modified nothing under `packages/json5/src/**`, the package's `*_test.pion`, or anything outside
`packages/json5/audit/`.

## How to reproduce

```sh
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
pionc test packages/json5/audit                       # 10 p*_ exhibits FAIL, 5 ctl_* controls pass; package's own 241 still pass
sh packages/json5/audit/run_audit.sh                  # every stage (~25 min, the depth bisection is most of it)
sh packages/json5/audit/run_audit.sh ident bench      # selected stages
```

Every build, corpus and result goes to `$OUT` (default `/private/tmp/pion-json5-audit`). The worktree stays clean.

| file | purpose |
|---|---|
| `redteam_test.pion` | 10 failing exhibits (`p1_*`, `p2_*`) and 5 passing controls (`ctl_*`). |
| `driver/` | Pion differential driver with modes `parse`, `idscan`, `numfmt`, `ptr`, `patch`, `diffrt`, `deep`, `wide` and `adv`. |
| `oracle/node/oracle.mjs` | The same CLI over json5@2.2.3 and fast-json-patch@3.1.1. |
| `oracle/rust/` | The same CLI over json5 1.3.8, serde_json 1.0.140 and json-patch 4.2.0. A custom value type keeps ±Infinity, NaN and key order. |
| `tools/gen_cases.py` | Deterministic corpora: 60,000 doubles, 37,995 numeric literals, 142 JSON5 and 163 strict-JSON syntax vectors, pointer and patch vectors, 2,000 random diff pairs. |
| `tools/compare.py`, `tools/compare_idscan.py` | Line-by-line differential reports. The idscan report groups disagreements by Unicode range. |
| `tools/depth_bisect.py` | Finds the nesting depth at which each probe first crashes, in all 4 build modes. |
| `tools/gen_bench.py` | Adversarial benchmark corpora (A1–A8). |
| `run_audit.sh` | One command for every stage. |

Every number below comes from a fresh `run_audit.sh` run, except the depth table. That table comes from `tools/depth_bisect.py` on the same driver source.

## Verdict

The **core lexer is strong**:
- **Whitespace:** identical to both references on all 1,112,064 code points.
- **Strict JSON:** 0 differences from both `JSON.parse` and serde_json on 163 vectors.
- **Decimal parsing:** correctly rounded, 0 differences from Node and Rust on 37,995 literals.
- **Shortest-double formatting:** byte-identical to `JSON.stringify` on 60,000 doubles.
- **RFC 6902 edge vectors:** Pion agrees with every verdict where Node and Rust agree with each other.
- **`diff()`:** round-trips 2,000/2,000 random pairs. fast-json-patch replays Pion's patches to the same result 2,000/2,000 times.
- **Wasm32:** all four build modes produce byte-identical output on every differential corpus.

The damage is in four places:

1. **P0, crashes on nested values.** Any `Json5Value` nested a few thousand levels deep cannot be dropped, cloned, diffed or compared:
   - **Thresholds:** Wasm32 traps at **~1.5k–2.8k** levels and native SIGSEGVs at **~29k–52k**.
   - **Reachable with default options:** a JSON Patch of constant-size ops nests the document one level per 3 ops, so the crash needs no non-default setting.
   - **Contradicts the package's own test:** the package's red-team test calls 10,000–12,000 levels safe.
2. **P0/DoS, quadratic algorithms everywhere an object is looked up.**
   - **Lookups:** `value_eq`, the patch `test` op, `diff`, `pointer_get` and every patch op scan objects linearly. The parser builds a seeded hash index and then throws it away.
   - **`apply_patch`:** deep-clones the whole document on every call, and again for every moved value.
   - **Cost:** Pion is 85×–870× slower than Rust on 50k-key objects and 185× slower on a 6,000-level patch.
3. **P1, silent wrong numbers.**
   - **Bug:** hex literals with 16 or more digits are double-rounded.
   - **Scale:** Pion disagrees with both references on 25 of 1,200 random hex literals.
   - **Visibility:** no error is raised.
4. **P1, the Unicode identifier table is a hand-written range list.**
   - **Wrongly accepted:** 52,410 code points as IdentifierStart where both references reject them. They include digits, emoji, full-width punctuation and symbols.
   - **Wrongly rejected:** 87 real letters, and 360 identifier-part code points such as combining marks and connector punctuation.

## Findings

### P0-1: recursive drop, clone, diff and serializer teardown crash on nested values (wasm32 from ~1.5k levels)

`tools/depth_bisect.py` reports the smallest depth that crashes each probe, to 1% precision. Every probe first builds the
value and then runs one operation on it.

| probe | native-debug | native-release | wasm32-debug | wasm32-release |
|---|---|---|---|---|
| `build`: nested array built in a loop, no parser, then dropped | ~52,375 SIGSEGV | ~52,375 SIGSEGV | ~1,691 `RangeError: Maximum call stack size exceeded` | ~1,691 RangeError |
| `parse`: `parse_with_options(max_depth = d+8)`, then drop | ~52,375 SIGSEGV | ~52,375 SIGSEGV | ~1,691 RangeError | ~1,691 RangeError |
| `parse_obj`: the same with `{a:{a:…}}` | ~37,375 SIGSEGV | ~37,375 SIGSEGV | ~1,738 RangeError | ~1,468 RangeError |
| `json`: `to_json_string` | ~52,375 SIGSEGV | ~52,375 SIGSEGV | ~2,828 RangeError | ~2,828 RangeError |
| `eq`: `value_eq(a, a')` | ~52,375 SIGSEGV | ~52,375 SIGSEGV | ~2,828 RangeError | ~2,828 RangeError |
| `clone`: `apply_patch(a, [])` | ~52,375 SIGSEGV | ~52,375 SIGSEGV | ~2,828 RangeError | ~2,828 RangeError |
| `diff`: `diff(a, a with the leaf changed)` | **~29,125 SIGSEGV** | ~29,125 SIGSEGV | **~1,538 `RuntimeError: memory access out of bounds`** | ~1,538 OOB |
| `copy`: `apply_patch({x:a}, copy /x → /y)` | ~52,375 SIGSEGV | ~52,375 SIGSEGV | ~2,828 RangeError | ~2,828 RangeError |
| **`patchgrow`: default `ParseOptions` only** | ≥ 64,000 (each run hits the 180 s timeout first, see P0-2) | same | **~1,890 RangeError** | ~1,890 RangeError |

There are three root causes. They are separate and all three need fixing:
- **Compiler-generated drop.** The `build` row has no package code in it: the value is constructed with a loop and goes out of scope. It still crashes at the same depth as `parse`. This is the same class of bug as W7-msgpack: a recursive enum gets a recursive RC drop.
- **Explicitly recursive code in the package.** `clone_value` (`src/patch.pion:8`) and `diff_rec` (`src/patch.pion:492`) recurse. `diff` crashes at about half the depth of everything else (29k native). On wasm32 it fails with `memory access out of bounds`, not a clean stack-overflow trap: the linear-memory shadow stack ran into the heap.
- **Every API returns or holds a `Json5Value`.** The iterative parser (`parse_validated`) and serializer (`serialize_impl`) do not protect anything, because the value they produce or consume still has to be dropped. The README's Workload 2 note says the iterative serializer trades speed for "stack-overflow immunity". The value it serializes cannot be freed beyond these depths, so that immunity does not exist.

**Reachable with default options.**
- **Probe:** the `patchgrow` probe parses a patch with default `ParseOptions` (`max_depth: 128`). The patch repeats `{op:'add',path:'/b',value:{}},{op:'move',from:'/a',path:'/b/a'},{op:'move',from:'/b',path:'/a'}` N times. Every op is constant-size and every path has 2 segments, yet each round nests the document one level deeper.
- **Wasm32 result:** a ~0.4 MB patch of 1,890 rounds crashes the module.
- **Native result:** the same construction costs O(N^2.3) time first (P0-2). 8,000 rounds take 10 s, so a native process is pinned long before it would crash.

**Contradicts the package's own claims.** `redteam_deep_nesting_10k_iterative_no_sigsegv` (`packages/json5/redteam_test.pion:12`) parses 10,000 levels with `max_depth: 12000` and passes natively. The same test crashes on wasm32 at ~1.7k.

### P0-2: quadratic lookups and full-document clones (DoS)

Source:
- `value_eq` (`src/lib.pion:115`) looks every key of `a` up in `b` with `get`, a linear scan, so it is O(k²) per object.
- `diff_rec` calls `value_eq(a, b)` at every level (`src/patch.pion:498`), then `get(b, ka)` per key (`src/patch.pion:508`), so it is also O(k²).
- `pointer_get` and every patch op scan entries linearly (`src/pointer.pion`, `resolve_parent`).
- The parser's `HashIndex` exists only during parsing. The returned `Json5Value::Object` is a plain `Array[(String, Json5Value)]`.
- `apply_patch` starts with `clone_value(doc)` (`src/patch.pion:390`), a deep clone of the whole document on every call.
- `move` re-clones the moved subtree in `patch_add` (`src/patch.pion:447` → `224`/`244`) even though it was just detached.

The `adv` workloads below ran through `scripts/bench_compare.py` with warmup 1, 5 rounds, strictly interleaved, and stdout SHA-256 identical across all implementations:

| workload | Pion median | Rust median | Node median | Pion vs Rust |
|---|---:|---:|---:|---:|
| A3 RFC 6902 `test` of a 50k-key object against itself | 5,545 ms | 23.7 ms | 84.0 ms | **234× slower** |
| A4 `diff()` of two 50k-key objects, one value changed | 16,594 ms | 19.0 ms | 76.9 ms | **873× slower** |
| A6 50k `pointer_get("/k<i>")` on a 50k-key object | 5,022 ms | 17.9 ms | 74.2 ms | **281× slower** |
| A7 200 single-op atomic patches on a 2.5 MB document | 1,193 ms | 29.9 ms | 54.9 ms | **40× slower** |
| A8 one 18,000-op add/move patch nesting 6,000 levels | 4,009 ms | 21.7 ms | (fast-json-patch throws) | **185× slower** |

Scaling, from `driver wide <n> <kind>` against the same Rust ops:

| n keys | `value_eq` | `diff` | `test` | n × `pointer_get` | Rust, any of these |
|---:|---:|---:|---:|---:|---:|
| 10,000 | 0.25 s | 0.71 s | 0.24 s | 0.27 s | ≤ 0.04 s |
| 20,000 | 0.98 s | 2.59 s | 0.87 s | 0.82 s | ≤ 0.04 s |
| 40,000 | 3.43 s | 10.28 s | 3.58 s | 3.23 s | ≤ 0.05 s |

A 50k-key object is 0.7 MB of JSON. Parsing it takes 40 ms, but a single `test` op on it takes 5.5 s.

**No Pion-specific weakness:** the `copy` amplification bomb (`copy "" → /a<i>`, ×20) grows memory 2^n in all three implementations about equally (Pion 0.23 s / 459 MB, Rust 0.24 s / 528 MB, Node 0.69 s / 406 MB). It is a missing budget everywhere, not a gap between Pion and the references.

### P1-1: hex literals of 16 or more digits are double-rounded (silent wrong value)

`src/parser.pion:510-516` accumulates the first 15 hex digits in a `UInt64` and converts that prefix to `Double`, which is one rounding. Each further digit then runs `acc_d * 16.0 + d`, which rounds again. ES5.1 §9.3.1 requires the correctly rounded value of the whole HexIntegerLiteral:
- V8, and therefore Node json5, rounds once.
- Rust json5 1.3.8 accumulates in `u128` and converts once.

| literal | Pion | Node json5 = Rust json5 |
|---|---|---|
| `0x1000000000000081` (2^60 + 129) | `0x43B0000000000000` = 1152921504606846976 | `0x43B0000000000001` = 1152921504606847232 |
| `0x7C64C675149ad201` | `…26B4` | `…26B5` |
| `0x4f61027c9a6d620d1` | `…9B58` | `…9B59` |
| `0x026DEd6c5eB9FFDd8A5` | `…CFFE` | `…CFFF` |

Pion disagrees with Node on 25 of the 1,200 random hex literals (1–40 digits) in the numeric corpus. On 16 of those 25, Rust json5 gives Node's value exactly. The other 9 have more than 32 hex digits, which overflow Rust's `u128`, so Rust rejects them. No error is raised. Test: `p1_hex_literal_16plus_digits_double_rounded`.

### P1-2: the identifier table accepts digits, symbols and emoji, and rejects real letters

`is_es5_id_start` / `is_es5_id_part` (`src/unicode_id.pion:100-174`) are block ranges, not ES5.1 §7.6 categories:
- `0x037F..0x1FFF`, `0x2C00..0x2FEF`, `0x3041..0x9FFF`, `0xFDF0..0xFFFD` and `0x10000..0x2FFFF` are accepted wholesale.
- Letters outside the listed ranges are missing.

The `ident` stage tries every Unicode scalar value in five positions against both references. The table below counts only "strong" disagreements, where Node (Unicode 10) and Rust (Unicode 17) agree with each other and Pion does not:

| position | wrongly accepted | wrongly rejected |
|---|---:|---:|
| raw IdentifierStart `{X:1}` | **52,410** (669 ranges) | 87 |
| raw IdentifierPart `{aX:1}` | 49,499 | 360 |
| escaped start `{\uXXXX:1}` | 4,774 | 87 |
| escaped part `{a\uXXXX:1}` | 3,200 | 120 |
| whitespace `[X1]` | 0 | 0 |

Examples:
- **Accepted as an unquoted key, though both references reject it:** `٠` `०` `０` `𝟘` (digits, Nd); `😀` `🎉` `™` `㈱` (So); `！` `（` `։` `।` `⸺` (punctuation); `＄` (Sc); `҃` (Mn as the first character); `゛` (Sk); `a·`; `a䷀`.
- **Rejected, though both references accept it:** `ⁿ` `ⁱ` `ₐ` (Lm); `ힰ`..`ퟻ` (Hangul Jamo Extended-B, Lo); `a⃗` `a⃥` (Mn, U+20D0–20F0); `a〪` (U+302A–302F); `a⁔b` (Pc U+2054); `a` + U+E0100–E01EF variation selectors.

Consequence: a hand-written config with `{ⁿ: 1}` or `{a⃗: 1}` fails to load. A config that Pion accepts, such as `{😀: 1}`, is rejected by every other JSON5 tool. Tests:
- `p1_identifier_start_accepts_digits_symbols_emoji`
- `p1_identifier_part_accepts_punctuation_and_emoji`
- `p1_identifier_rejects_valid_letters_and_marks`
- `p1_accepted_identifier_keys_are_not_portable`

### P2: divergences and policy gaps

| test | finding | references |
|---|---|---|
| `p2_valid_overflowing_literals_rejected_by_default` | `1e400`, `-1e400`, `1e309`, `[1.8e308]` and `{a: 2e308}` are errors with the default `reject_overflow: true`. Across the numeric corpus, 958 of 37,995 literals are rejected. They are valid ES5.1 NumericLiterals and evaluate to ±Infinity, and JSON5 has an `Infinity` literal anyway, so rejecting them is not a defense. | Node json5 and Rust json5 both return ±Infinity. |
| `p2_negative_zero_lost_in_json_roundtrip` | `to_json_string(-0.0)` is `"0"`. This is the only failure among 59,999 finite doubles. | serde_json writes `-0.0`, which round-trips. Node's `JSON.stringify(-0)` is also `"0"`. |
| `p2_patch_test_equates_distinct_big_integers` | Because `Number(Double)` is the only numeric type, `test 9007199254740993 == 9007199254740992` passes, and so do Int64::MAX vs Int64::MAX−1 and u64::MAX vs u64::MAX−1. | Rust json-patch rejects all three. fast-json-patch behaves like Pion. |
| `p2_big_integers_silently_rounded_on_roundtrip` | `9007199254740993` becomes `9007199254740992`. `9223372036854775807` becomes `9223372036854776000` (= 2^63, which no longer fits in an `Int64`). `-9223372036854775808` round-trips as `-9223372036854776000`. | serde_json keeps all three exactly. |
| `p2_value_eq_asymmetric_on_duplicate_keys` | Through the public `Json5Value::Object(Array[…])` constructor, `value_eq({a:1,a:1}, {a:1,b:2})` is `true` and the reverse is `false`. The check only looks up keys of `a` in `b`. | n/a |

The following were also measured. They are not tests because the references disagree with each other or the behaviour is defensible:
- **Lone surrogates:** `'\uD800'` is rejected by Pion and Rust and accepted by Node, whose JS strings can hold lone surrogates.
- **Leading-zero patch index:** `add` at `/01` is rejected by Pion and Rust and accepted by Node.
- **Removing the root:** `remove ""` is rejected by Pion and Rust and accepted by Node.
- **Patch path `/a~2`:** rejected by Pion and Rust; Node reads `~2` as a literal key.
- **Number type in `test`:** Rust json-patch fails `test 1 == 1.0` and `test -0.0 == 0`. Pion and Node pass them, which is what RFC 6902 §4.6 requires.
- **Pointer syntax:** serde_json's `Value::pointer` is lenient about `~2`, a dangling `~` and a missing leading `/`; Pion rejects all three, which is correct per RFC 6901.
- **JSONC line comments:** in JSONC mode, Pion ends a `//` comment at U+2028/U+2029.

### Controls: attacks the package survived

| area | result |
|---|---|
| Whitespace set (all Zs, `\v`, `\f`, NBSP, BOM between tokens, U+2028/2029; U+180E and U+200B rejected) | 0 / 1,112,064 code points differ from either reference |
| Escapes and line continuations (`\0` vs `\00`/`\01`/`\1..\9`, `\xHH`, `\v`, NonEscapeCharacter, `\`+LF/CRLF/CR/U+2028/U+2029, raw U+2028 in strings, raw LF/CR rejected) | identical to both references |
| Numbers: `.5`, `5.`, `+.5`, `5.e3`, `-0x0` → −0, leading zeros, `0x`, `0x1.5`, `0x1p2`, `Infinityx`, `1_000`, `0b1`, `1n` | identical to both references |
| Decimal parse, 15–40 digits plus 8,000 exact halfway cases | 0 / 37,995 differ from Node and Rust (with `reject_overflow: false`) |
| `to_json_string` formatting | byte-identical to `JSON.stringify` on 59,999 / 59,999 finite doubles. serde_json 1.0.140 without `float_roundtrip` fails 14,606 of these round trips, so Pion is better here. |
| Strict JSON (`strict_json()`): every JSON5-only feature rejected | 0 / 163 differ from `JSON.parse` and serde_json |
| RFC 6901 (`-`, `~01` → `~1`, `/01`, `/-/x`, dangling `~`, huge indices) | matches the spec, and matches serde_json wherever serde_json is strict |
| RFC 6902 (move into own child vs `/a`→`/ab`, move to self, `-` only as the last `add` token, atomic rollback, deep `copy` isolation, unknown and missing members) | agrees on every row where Node and Rust agree |
| `diff()` round trip on 2,000 random trees (keys `/`, `~`, `~1`, `""`, `-`, `0`; type swaps; array insert, delete and shuffle) | 2,000/2,000. Same op count as Rust json-patch (4,228), 12% fewer than fast-json-patch (4,813). |
| Wasm32: native debug and release plus wasm32 debug and release on every differential corpus (including the 1,112,064-code-point idscan) | byte-identical, 0 traps |
| Wide objects with duplicate keys: HashIndex upgrade at 16 keys; LastWins keeps the first position, as JS does | correct. Parsing 50k keys takes 40 ms. |

## Benchmark fairness (`packages/json5/bench/`)

The three committed workloads are measured honestly, and their SHA-256 gate is real. They do, however, avoid every weak spot found above:

1. **Workload 1/2 corpus avoids every weak spot.**
   - **What it contains:** a tsconfig-like file with ASCII identifier keys only, objects of fewer than 16 keys, shallow nesting, and numbers of at most 15 digits, which all take the `fast_int` path.
   - **Non-ASCII identifiers (A1):** Pion is **0.83×** Rust, against 0.98× in the README.
   - **17-digit doubles, the `String::to_double` slow path (A2):** Pion is **0.49×–0.54×** Rust.
2. **Workload 3 uses a ~400-byte document.**
   - **What that hides:** a deep clone of the whole document per `apply_patch` costs almost nothing at that size. The headline "Pion 1.31× faster than Rust json-patch" depends on it.
   - **At 2.5 MB (A7):** Pion is **40× slower**. Rust `json_patch::patch` is atomic in place, using an undo log, so no clone is needed.
   - **How the README's Workload 3 equalizes:** the Rust code does an explicit `doc.clone()` per iteration to match Pion's API. That cost belongs to Pion's API design, not to Rust.
3. **`diff()` is never benchmarked**, although it is public API. On 50k keys (A4) it is **873× slower** than `json_patch::diff`, which is linear: one pass, no repeated `==`, and map lookups.
4. **No workload looks anything up in a large object** (A3 and A6). The README does not mention that the hash index is discarded after parsing.
5. **`serde_json` with `preserve_order`** (IndexMap) is the right reference choice: it has the same key-order semantics and still O(1) lookup.

The full A1–A8 tables, with min, P95 and peak RSS, are printed by `run_audit.sh bench`.

## Suggested fixes (proposals, not applied)

- **P0-1:**
  - Make `clone_value` and `diff_rec` iterative, with explicit stacks.
  - Give `Json5Value` an explicit iterative teardown, or get a compiler-level fix for recursive-enum RC drop, which this shares with W7-msgpack.
  - Until then, document a depth ceiling that holds on wasm32 (≤ ~1,000), and give `apply_patch` a depth / node budget so patches cannot nest documents without bound.
- **P0-2:**
  - Keep a key index in `Object`, or build one lazily for objects with 16 or more keys, so `get`, `pointer_get`, `value_eq` and `diff` stop being quadratic.
  - Drop the per-level `value_eq` from `diff_rec`; compare only scalars.
  - Make `apply_patch` atomic through an undo log instead of a full clone.
  - Have `move` reuse the detached value instead of cloning it.
- **P1-1:** accumulate hex digits exactly (big-int limbs, or keep the first 54 significant bits plus a sticky bit) and round once.
- **P1-2:** generate `ID_Start` / `ID_Continue` tables from UCD categories (Lu Ll Lt Lm Lo Nl / +Mn Mc Nd Pc), as json5-rs does with `ucd-generate`.
- **P2:**
  - Default to `reject_overflow: false` (JSON5 semantics), or make the option opt-in and document it.
  - Emit `-0.0` (or `-0`) for negative zero in `to_json_string`.
  - Consider an `Int64`/`UInt64` number variant, or a raw-literal variant, for exact integers.
