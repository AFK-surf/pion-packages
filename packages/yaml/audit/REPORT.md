# Red-team audit: `packages/yaml` @ `00b956c` (`feat/opt-yaml`)

Prosecution brief against the Pion YAML 1.2 package. It is compared with **Rust `yaml-rust2 0.10.4`** and
**Go `gopkg.in/yaml.v3 v3.0.1`**, all run on the same bytes and the same machine
(`Darwin arm64`, Apple M-series, `tokyo-mac-studio-0`, 2026-11-23).

Nothing under `packages/yaml/src/**`, the existing tests or the repository root was modified. Everything
lives in `packages/yaml/audit/`.

## How to reproduce

```sh
export PATH="$HOME/.pion/bin:$PATH"
pionc test packages/yaml/audit                  # 26 exhibits, every FAIL is evidence (upstream 381 still pass)
sh packages/yaml/audit/run_audit.sh             # all stages (~10 min): tests yts probes fuzz dos bench
sh packages/yaml/audit/run_audit.sh probes dos  # selected stages only
```

All builds, corpora and the `yaml-test-suite` checkout go to `$OUT` (default `$TMPDIR/pion-yaml-audit`).
The worktree stays clean.

| file | purpose |
|---|---|
| `redteam_test.pion` | 26 failing tests, one per exhibit. They are in the package root because `pionc test` does not discover `tests/`. |
| `harness/pion_driver`, `harness/rust_driver`, `harness/go_driver` | The same CLI for all 3 impls: `json`, `rt` (type-aware round trip), `rtjson` (emit benchmark); Pion also has `typed` and `emit`. |
| `harness/yts_run.py` | Runs the full official yaml-test-suite (all 402 cases) through all 3 impls. |
| `harness/yts_events.py` | Strict oracle: rebuilds every valid case's typed value tree from `test.event` (Core Schema) and compares it with Pion. |
| `harness/probes.py` | Targeted differential probes plus an emitter round-trip table. |
| `harness/dos.py` | Bombs, depth, merge-key quadratic, budget false positives and emit amplification, with wall time and peak RSS. |
| `harness/regress_fuzz.py` | Mutation fuzz of `00b956c` against its parent `09ca291` (regression hunt). |
| `harness/fuzz_vs_rust.py` | Mutation fuzz of Pion against yaml-rust2. |
| `harness/gen_corpora.py` | 9 adversarial benchmark corpora (SHA-identical output across the 3 impls). |

## Verdict in one paragraph

The parser is strong on conformance. It is identical to the `yaml-test-suite` event streams on **308/308** valid
cases (typed and order-preserving, stricter than the ported `in.json` tests) and rejects **94/94** error cases.
`00b956c` introduced **no** behavioural regression: 8,040 mutants show 0 differences from `09ca291`.

The damage is in everything around the parser:
- **Both output paths corrupt doubles.** They print 15 significant digits, so DBL_MAX becomes `inf` after a round trip.
- **Duplicate keys are silently accepted and kept twice.** Two readers of the same `Map` see different values.
- **The Billion-Laughs budget rejects valid real-world input.** It is never reset between documents, and it charges scalar aliases.
- **Recursive aliases silently become `null`.**
- **Invalid UTF-8 is accepted.**
- **`stringify` is not round-trip safe** in 6 distinct ways.

On speed, Pion loses to yaml-rust2 on 3 of 9 adversarial parse corpora and on one emit corpus. The headline benchmark
corpus avoids every one of those weak spots.

---

## P0: silent data corruption, or valid input rejected

### P0-1 Doubles truncated to 15 significant digits in `to_canonical_json` and `stringify`
`emitter.pion` formats floats with `Double::to_string()`, which prints `%.15g`.

| input | Pion | yaml-rust2 | yaml.v3 |
|---|---|---|---|
| `0.30000000000000004` | `0.3` | `0.30000000000000004` | `0.30000000000000004` |
| `3.141592653589793` | `3.14159265358979` | `3.141592653589793` | `3.141592653589793` |
| `1.7976931348623157e308` → `stringify` → `parse` | **`+inf`** | DBL_MAX | DBL_MAX |

- **Impact:** the "canonical JSON for cross-language SHA-256 verification" is lossy. The bench SHA only matched
  because the corpus floats are `0.995` and `0.25`.
- **Exhibits:** `p0_canonical_json_truncates_doubles_to_15_digits`, `p0_stringify_turns_dbl_max_into_infinity`, `p0_stringify_loses_double_precision`.
- **Repro:** `run_audit.sh probes`, row `float_precision`.

### P0-2 Duplicate mapping keys accepted, and both entries kept
- `admin: false\nadmin: true` returns `Ok`. yaml-rust2 fails with `duplicated key in mapping`; yaml.v3 fails with
  `mapping key "admin" already defined`. YAML 1.2.2 §3.2.1.1 requires unique keys.
- The returned `YamlValue::Map` holds **both** pairs:
  - a first-match lookup reads `admin == false`;
  - `to_canonical_json` (last wins) reads `{"admin":true}`.

  This is a parser-differential, config-smuggling primitive. The same applies to flow maps, duplicate `<<`, and
  `1:` vs `"1":` (the JSON view silently drops one of them).
- **Benchmark bias:** this also skews the benchmark. yaml-rust2 (LinkedHashMap) and yaml.v3 hash and check every key;
  Pion just `push`es to an `Array`.
- **Exhibits:** `p0_duplicate_mapping_key_is_accepted`, `p0_duplicate_key_two_readers_disagree`, `p2_duplicate_merge_key_is_accepted`.

### P0-3 Alias budget rejects valid documents (false-positive DoS)
`Loader.expanded_nodes` (limit 100,000) is **never reset between documents**, and **every alias costs ≥ 1 node**, even
an alias to a scalar, which cannot amplify anything.

| valid input | Pion | yaml-rust2 | yaml.v3 |
|---|---|---|---|
| 1,500 independent docs (480 KB), each merging its own 20-key `&d` twice | `ERR 34158:7 alias expansion limit exceeded` | ok, 0.07 s | ok, 0.11 s |
| one CI file, 120,000 × `image: *img` (4.2 MB) | `ERR 200004:12 alias expansion limit exceeded` | ok, 0.18 s | ok, 0.29 s |

- **Exhibits:** `p0_alias_budget_is_shared_across_documents`, `p0_scalar_aliases_count_against_billion_laughs_budget`.
- **Repro:** `run_audit.sh dos`, rows `valid_*`.

## P1: spec violations, and emitter bugs that change data

| id | finding | Pion | yaml-rust2 | yaml.v3 | exhibit |
|---|---|---|---|---|---|
| P1-1 | Recursive alias `&a [&b 1, *a]` / `&a {x: &b 1, y: *a}`: the anchor slot is pre-filled with `Null` when a later anchor grows the table, so `*a` silently loads `null` | `[1,null]` | `BadValue` | `anchor 'a' value contains itself` | `p1_recursive_alias_in_*` |
| P1-2 | Invalid UTF-8 (`FF FE`) and overlong `C0 81` are accepted and written into the "canonical JSON" | Ok | not accepted (`&str`) | `invalid leading UTF-8 octet` | `p1_invalid_utf8_is_accepted`, `p1_overlong_utf8_is_accepted` |
| P1-3 | `stringify(Float(2.0))` emits `2`, which re-parses as `Int(2)`. Hits spec ex. 2.27 (suite `UGM3`, `price: 450.00`); it is the only suite case of 308 that fails the round trip | `Int` | `2.0` kept | float64 kept | `p1_stringify_float_comes_back_as_int` |
| P1-4 | `stringify(Str("..."))` emits `...`, a document-end marker, so the value vanishes (0 documents) | lost | ok | ok | `p1_stringify_doc_end_marker_string_vanishes` |
| P1-5 | A quoted `"<<"` key is emitted bare and then **becomes a merge** | data rewritten | ok | rewritten too | `p1_stringify_quoted_merge_key_becomes_merge` |
| P1-6 | A string starting with U+FEFF is emitted unquoted, and Pion rejects its own output | `RT_ERR` | ok | ok | `p1_stringify_leading_bom_string_unparseable` |
| P1-7 | A key longer than 1024 chars is emitted as an implicit key, and Pion rejects its own output | `RT_ERR` | `RT_ERR` | ok (`? ` form) | `p1_stringify_long_key_unparseable` |
| P1-8 | `stringify` output is O(depth²). Alias chains push depth past the 256 limit for free | 14 KB → **482 MB**, 926 MiB RSS | (emit+reparse 0.08 s) | Marshal 0.16 s | `p1_stringify_output_quadratic_in_alias_depth` (6 KB → 40.7 MB) |
| P1-9 | Core-Schema integers outside i64 silently become strings: `9223372036854775808`, `18446744073709551615` | `Str` | number | uint64 | `p1_out_of_range_int_becomes_string` |

## P2: divergences and gaps

| id | finding | Pion | yaml-rust2 | yaml.v3 | exhibit |
|---|---|---|---|---|---|
| P2-1 | Custom or local tag `!foo 12` is re-resolved by the Core schema | `12` | `"12"` | `"12"` | `p2_custom_tag_resolved_as_core_int` |
| P2-2 | `%TAG !! tag:example.com,2000:app/` then `!!int 13`: `!!` is no longer the Core prefix | `13` | `"13"` | `"13"` | `p2_redefined_secondary_handle_still_resolves_core_int` |
| P2-3 | Raw C0 control characters (`\x01`) are not `c-printable` (§5.1) | accepted | accepted | rejected | `p2_c0_control_characters_accepted` |
| P2-4 | `<<: 5` (merge with a non-map value) | accepted as key `<<` | (no merge) | rejected | `p2_merge_with_scalar_value_accepted` |
| P2-5 | Block-nesting limit of 256 rejects a valid 300-level document | `ERR 258:258` | ok | ok (limit 10000) | `p2_nesting_limit_256_rejects_valid_input` |
| P2-6 | Error position for a tab used as indentation on line 2 | `1:4` | `1:4` | `line 2` | `p2_tab_indentation_error_points_to_wrong_line` |
| P2-7 | `0xFFFFFFFFFFFFFFFF` | `Str` | `Str` | uint64 | `p2_u64_hex_becomes_string` |

### Capability gaps against yaml.v3 / yaml-rust2

These are API facts, read from `src/lib.pion` (the entire public API is `parse`, `parse_all`, `stringify`,
`to_canonical_json`, `write_canonical_json_to`):
- **No Node or AST layer.** There are no comments, positions, scalar styles, tags or anchors on values; yaml.v3 has
  `yaml.Node`. Tags are dropped after resolution.
- **No streaming API.** `parse_all` materialises the whole stream. yaml.v3 has `Decoder.Decode` per document;
  yaml-rust2 has an event `Parser` with `MarkedEventReceiver`.
- **No source spans on values or errors after the first error.** yaml-rust2 has `Marker`; yaml.v3 has `Node.Line/Column`.
- **No duplicate-key detection** (see P0-2) and no hook for custom tags.
- **No integers beyond i64** (P1-9) and no `!!binary` decoding (yaml.v3 decodes it).
- **The emitter has no options.** There are no anchors or aliases (shared nodes are re-expanded, so P1-8 and the byte
  amplification below apply), no flow style, no block-literal output (multi-line strings become `"a\nb"`), and no
  indent or width control.

## DoS / robustness

Full table: `run_audit.sh dos`.

| input | Pion | yaml.v3 | yaml-rust2 |
|---|---|---|---|
| 9×9 seq / map / merge / alias-as-key bombs | rejected in 0.01 s, ~2 MiB ✅ | rejected ✅ | **no limit: 22 GiB RSS, killed at 60 s** (seq bomb, measured once) |
| `[`×1M closed or unclosed | rejected, 0.03 s ✅ | ✅ | ✅ |
| merge 40k-key map once (578 KB) | **13.5–17.8 s** (O(n²) `map_entries_has`) | 11.3–12.6 s | 0.07 s (no merge support) |
| merge 10k keys into a map with 100k explicit keys (1.7 MB) | **10.5–11.3 s** | 54.8–80.7 s | 0.10–0.13 s |
| 256 KiB string × 4096 aliases (274 KB → 1 GiB JSON) | parse ok, JSON 2.5–3.1 s / 2.0 GiB RSS: the budget counts nodes, not bytes | 4.2–5.5 s / 4.0 GiB | (not run: no alias limit) |
| alias-depth chain 28×250, `stringify` | **482 MB output, 926 MiB RSS** (P1-8) | 0.16 s / 259 MiB | 0.08 s |

Pion's bomb defence is real, but it is node-counted only:
- it does not bound bytes;
- merge keys are quadratic;
- the budget produces the false positives in P0-3.

## Performance: where Pion loses

All runs use `scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, with SHA-256 checked identical
across impls. The workload is parse plus canonical JSON (`json`), or parse, emit, re-parse and JSON (`rtjson`).
Baseline is yaml-rust2.

| corpus (~3 MB) | Pion median | yaml-rust2 | yaml.v3 | Pion vs Rust | Pion RSS / Rust RSS |
|---|---:|---:|---:|---:|---:|
| **dq_escapes** (double-quoted, `\t é \\ \n \" \U0001F600`) | 90.5 ms | 53.9 ms | 7,300 ms | **0.60×** | 20.8 / 22.3 MiB |
| **wide_map** (one map, 101,733 keys) | 114.6 ms | 90.1 ms | ~89 s (single run, not in table) | **0.79×**, even though Pion skips duplicate checks | 41.8 / 40.4 MiB |
| **plain_multiline_comments** (Ansible-style) | 54.7 ms | 50.1 ms | 93.3 ms | **0.92×** | 24.4 / 24.7 MiB |
| **emit rt: block_scalars** | 51.6 ms | 41.0 ms | 107.6 ms | **0.79×** | 13.1 / 14.7 MiB |
| block_scalars | 25.1 ms | 26.7 ms | 44.1 ms | 1.06× | |
| flow_json | 87.0 ms | 107.4 ms | 182.1 ms | 1.23× | |
| deep_nesting (100 levels) | 23.0 ms | 33.9 ms | 49.6 ms | 1.47× | |
| anchors_aliases (16k aliases) | 21.3 ms | 28.7 ms | 42.6 ms | 1.35× | |
| many_small_docs (60,849 docs) | 95.4 ms | 146.0 ms | 240.2 ms | 1.53× | |
| long_plain_lines | 21.0 ms | 33.4 ms | 50.4 ms | 1.59× | |
| emit rt: flow_json / many_small_docs / plain_multiline | 192 / 236 / 84 ms | 220 / 381 / 88 ms | 490 / 734 / 216 ms | 1.14× / 1.62× / 1.05× | |

Pion never lost to yaml.v3 in any benchmark run. The only DoS case where it is slower than yaml.v3 is the 40k-key merge
(13.5–17.8 s vs 11.3–12.6 s).

### Loopholes in how the headline benchmark is measured (README 1.42× Rust / 2.17× Go)
1. **The corpus is three templates repeated 679 times.** K8s, CI and OpenAPI are formatted identically, with no
   anchors, no flow-heavy data, no escapes, no long strings and no duplicate keys. Every corpus above on which Pion
   loses is absent.
2. **The floats are only `0.995` and `0.25`.** Any 16–17 digit double would have broken the SHA gate and exposed P0-1.
3. **The work is not equivalent.** yaml-rust2 and yaml.v3 hash every key and detect duplicates; Pion appends to an
   array and deduplicates only at JSON time. Pion is also not doing the alias, merge or depth work the others do
   (yaml-rust2 does none of that).
4. **The README reports Pion's peak RSS at 33.86 MiB against Go's 22.52 MiB**, i.e. Pion is +50% over Go on its own
   headline corpus.
5. **`BENCHMARKS.md` was not updated for `00b956c`.** It still lists `yaml` at 133.488 ms, 0.89× Rust, 33.95 MiB,
   which AGENTS.md §1.3 requires to be kept in sync.

## Regression check for `00b956c` (the perf commit)
- Typed event oracle with the `09ca291` build: 308/308, same as `00b956c`.
- Mutation fuzz of 8,040 mutants of suite inputs: **0** value, accept or reject differences and **0** error-message
  or position differences between `00b956c` and `09ca291`.
- All 9 corpora and all DoS inputs produce byte-identical output from both builds.
- The only visible change is in the 300-level probe: its depth error moved from `257:257` to `258:258`.

**Conclusion:** the perf commit is behaviour-neutral. Every P0/P1 finding above predates it.

## Where Pion beats the references (for the record)
- **Conformance:**

  | | error cases | `in.json` | event-only |
  |---|---:|---:|---:|
  | Pion | 94/94 | 279/279 | 29/29 |
  | yaml-rust2 | 94/94 | 279/279 | 27/29 |
  | yaml.v3 | 79/94 | 223/279 | 5/29 |

- **Fuzz against yaml-rust2:** Pion handles empty block scalars (`- |` gives `""`; Rust gives `"\n"`) and reserved
  directives with punctuation in their names, which Rust wrongly rejects.
- **Robustness:** a mid-document BOM is correctly rejected by Pion (Rust and Go accept it). yaml-rust2 truncates at a
  NUL byte (`x\0y` → `"x"`); Pion and Go reject it.
