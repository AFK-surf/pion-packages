# Red-Team Audit: `packages/uuid` @ `ffba5a1` vs Rust `uuid 1.29.3` + `ulid 1.2.1`

Scope: correctness, RFC 9562 / ULID compliance, safety, API completeness and performance of the pure-Pion
`packages/uuid`, measured against the exact upstream crates it claims parity with (`uuid =1.29.3`, `ulid =1.2.1`,
pinned in `audit/oracle/Cargo.lock`). Only `packages/uuid/audit/**` was written; the audited sources are untouched.

Host: `Darwin arm64` (Mac Studio, shared; load average ~15 during the benchmark run), `pionc 0.1.0 (arm64_apple, self-hosted)`,
`cargo 1.100.0`, Node `v24.22.2` for wasm32.

## How to reproduce

```sh
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
sh packages/uuid/audit/run_audit.sh             # tests + native/wasm32 differential + all benchmarks (~3 min)
sh packages/uuid/audit/run_audit.sh --no-bench  # tests + differential only (~2 s)
pionc test --json packages/uuid/audit           # red-team tests only
```

Artifacts go to `$AUDIT_OUT` (default `/tmp/pion-uuid-audit`); the worktree stays clean. The script exits non-zero while
any `DEFECT` exists.

| Path | What it is |
| --- | --- |
| `redteam_test.pion` | 21 Pion tests. `p1_*`/`p2_*` assert the correct behaviour (FAIL now, PASS after a fix); `div_*` assert Rust's behaviour where Pion diverges; `ctl_*` are controls for suspected weak spots that turned out correct (must PASS). |
| `oracle/` | Rust oracle (`oracle`), adversarial sort bench (`sort_adv`), `ContextV7` burst probe (`v7ctx`). |
| `driver/` | Pion driver that runs the same corpus and prints the same format; also cross-checks typed vs raw entry points (`INTERNAL_MISMATCH`). |
| `gen_corpus.py` / `diff.py` | Deterministic 8,594-case corpus; classifier: `DEFECT` / `UNEXPECTED` (fail) vs `DIVERGENCE` / `POLICY` (reported). |
| `bench/idiom_*` | The three upstream benches rewritten with the idiomatic typed API (`Uuid::parse_slice`, `Uuid::sort`, `Uuid::new_v5`, `Uuid::new_v7`, `Ulid::parse_slice`, `Ulid::sort`, `encode_*` / `to_string`), with stdout byte-identical to the Rust benches. |
| `bench/sort_adv` | All four sort APIs on adversarial distributions, stdout byte-identical to Rust `sort_unstable`. |

## Results at a glance

- **P0 (memory safety, crash on valid input, wrong UUID/ULID values): none found.** 8,594 differential cases, typed and raw
  entry points cross-checked on every case: 8,225 are byte-identical to Rust. Every one of the 369 mismatches is classified
  below, with 0 `UNEXPECTED`. MD5/SHA-1 v3/v5 match Rust at every name length 0–199 B plus 239/240/247/248/255/256/511/512/1000/4095/4096/65535/65536/1 MiB
  (this covers the `sha1_single_block_into` 39/40-byte boundary and the 48/55/56/64-byte block edges). All 4 sort APIs × 10
  distributions × 10 sizes match. wasm32 output is byte-identical to native on the full corpus.
- **P1: 3 findings**: a batch-parser defect, benchmark fairness, and sort performance on duplicate-heavy input.
- **P2: 9 findings**: API hazards and divergences from upstream.

## P1

### P1-1 `parse_uuid_lines_raw` / `parse_ulid_lines_raw` reject valid input with blank lines (look-ahead fast path)

`src/uuid.pion:1550` peeks at `pos + 36` (`src/ulid.pion` peeks at `pos + 26`). When that byte is `\n`, it takes
`[pos, pos+36)` as **one** line without checking for an earlier `\n` inside the window, so runs of blank lines followed by a
record are mis-split and the whole batch returns `false`. Rust `content.lines()` and both `*_fixed` variants (which have no
fast path) accept the same input.

| Input | Rust uuid / ulid | Pion `*_lines_raw` | Pion `*_lines_fixed` |
| --- | --- | --- | --- |
| `"\n\n\n\n" + simple32 + "\n"` | Ok, 1 UUID | **false** | 1 |
| `"\n" + "\r\n"×18 + simple32 + "\r\n"` | Ok, 1 UUID | **false** | 1 |
| `"\n"×37` | Ok, 0 UUIDs | **false** | 0 |
| `"\n"×27` (ULID) | Ok, 0 ULIDs | **false** | 0 |
| `"\r\n"×13 + "\n" + ULID + "\n"` | Ok, 1 ULID | **false** | 1 |

Tests: `p1_parse_uuid_lines_raw_blank_lines_before_simple`, `p1_parse_uuid_lines_raw_crlf_blank_run`,
`p1_parse_uuid_lines_raw_only_blank_lines`, `p1_parse_ulid_lines_raw_blank_lines`; differential corpus lines 8546/8550/8552/8580/8586.
This is the parser the headline benchmark uses. It only rejects input and never accepts bad input (see the controls below).
Fix: in the fast path, require that the window contains no `\n` (or drop the fast path; the `_fixed` variants show it is not needed).

### P1-2 Benchmark fairness: the README numbers use raw APIs, and the idiomatic typed API is 2.2–3.9× slower than Rust

The `ffba5a1` benches call `parse_uuid_lines_raw` / `sort_u128_pairs_raw` / `encode_uuid_hyphenated_raw` /
`uuid_v5_raw` / `uuid_v7_raw` / `parse_ulid_lines_raw`, and the Rust side uses the normal typed API. `bench/idiom_*` runs the same
work through the typed API a Pion user would write. All rows in a table have identical stdout SHA-256, and every run used
`scripts/bench_compare.py --warmup 1 --rounds 5`.

| Workload | `pion_raw` (README path) | `pion_typed_buf` (`encode_*` into buffer) | `pion_typed_str` (`to_hyphenated()`/`to_string()`) | Rust |
| --- | ---: | ---: | ---: | ---: |
| UUID batch parse+sort+format 500k (18.6 MB) | 51.9 ms **0.80×** | 110.4 ms **0.37×** | 123.1 ms **0.34×** | 41.3 ms |
| UUID v5+v7 generate+format 200k | 64.3 ms **0.50×** | 67.7 ms **0.48×** | 79.8 ms **0.41×** | 32.5 ms |
| ULID batch parse+sort+format 500k (13.5 MB) | 48.2 ms **0.78×** | 144.7 ms **0.26×** | 159.0 ms **0.24×** | 37.6 ms |

- `parse_uuid_lines_raw` takes **no validation shortcut**. Every byte is range-checked (`>= 128` is rejected before the
  128-entry LUT), hyphens/braces/URN prefix are checked, and URN is case-insensitive exactly like Rust 1.29.3
  (`eq_ignore_ascii_case`). The only semantic extras are that it skips empty lines (the Rust bench does the same) and strips
  one trailing `\r`. The control `ctl_uuid_parse_high_byte_aliases_rejected_everywhere` and 3,858/3,858 identical `uparse`
  cases back this up.
- The gap is in the typed path itself. `Uuid::parse_slice` → `Result[Uuid, UuidError]` per element, `Array[Uuid]` +
  `Uuid::sort` (≈ 0.47× of Rust on random data vs 0.85× for the raw parallel-array sort, see P1-3), and the branchy
  `crockford_val` decoder in `Ulid::parse_slice` (no LUT) for ULID. v5/v7 are fine: typed ≈ raw.
- Recommendation: the README / `BENCHMARKS.md` should state that the 0.80× / 0.78× rows are for the raw batch API and should
  add the typed rows (0.37× / 0.48× / 0.26×).

### P1-3 Sorting duplicate-heavy data is 4–4.5× slower than Rust (linear, not O(n²))

1M elements, `sort_adv` (`bench_compare.py`, median ms, SHA-256 identical):

| Distribution | `Uuid::sort` | `sort_u128_pairs_raw` | `Ulid::sort` | Rust `sort_unstable` |
| --- | ---: | ---: | ---: | ---: |
| random | 92.4 (0.47×) | 50.5 (0.85×) | 90.4 (0.48×) | 43.0 |
| dup33 (every value ×33) | **190.0 (0.23×)** | **136.1 (0.32×)** | **195.9 (0.22×)** | 43.1 |
| deep33 (groups of 33 share 15-byte prefix) | **224.6 (0.25×)** | **181.4 (0.31×)** | **230.9 (0.24×)** | 56.0 |
| lastbyte (only last byte differs) | 139.8 (0.34×) | 54.0 (0.87×) | 128.0 (0.37×) | 46.9 |
| signed quadrant edges `0x7FFF…/0x8000…` | 148.8 (0.32×) | 76.2 (0.62×) | 151.1 (0.31×) | 47.0 |
| all equal | 106.1 (0.28×) | 41.2 (0.71×) | 106.3 (0.28×) | 29.4 |

Scaling 250k → 1M → 4M (dup33, `Uuid::sort`): 72 → 210 → 783 ms (wall-clock including process start), so the cost
grows linearly and does not degrade to O(n²). The cause is the MSD radix itself. A bucket of more than 32 equal keys
recurses through all remaining byte levels: up to 16 levels × (count pass + 256-bucket scan + 3 fresh 256-entry `FixedArray`
allocations in `Uuid::sort` / `Ulid::sort` / `sort_u128_pairs_raw`). pdqsort's equal-element partitioning in Rust dispatches
such runs in one pass. Correctness holds on every distribution, including the empty array, n ≤ 33, and signed quadrants
(`ctl_sort_adversarial_shapes_match_reference` plus 400 differential sort cases).

## P2

| # | Finding | Evidence |
| --- | --- | --- |
| P2-1 | `parse_uuid_lines_raw` leaves a **partial batch** in the caller's `his`/`los` when it returns `false` (no rollback). | `p2_parse_uuid_lines_raw_no_partial_output_on_error` |
| P2-2 | `sort_u128_pairs_raw` with `his.length() != los.length()` and `sort_u128_pairs_fixed` with `n > capacity` are **silent no-ops**: no sort, no error, no panic. | `p2_sort_u128_pairs_raw_len_mismatch_is_silent_noop`, `p2_sort_u128_pairs_fixed_n_too_large_is_silent_noop` |
| P2-3 | Out-parameter raw APIs index `out_pair[1]` unchecked: `parse_uuid_slice_raw(…, FixedArray::make(1, 0UL))` aborts with `pion panic: index 1 out of bounds (len 1)` instead of returning `false` (`uuid_v5_raw` / `uuid_v7_raw` / `parse_ulid_slice_raw` likewise). | `p2_parse_uuid_slice_raw_short_out_pair_returns_false` |
| P2-4 | ULID decoding accepts `I/i/L/l → 1` and `O/o → 0`; `ulid 1.2.1` rejects them (`LOOKUP[I/L/O] = NO_VALUE`). This is documented in the README, but it is a divergence from the crate the tests claim compliance with, and it lets several strings decode to one ULID (`0IAN…`, `0LAN…`, `01AN…` are the same ID), which matters for string-keyed dedup and allowlists. | `div_ulid_parse_rejects_ilo_like_rust`; 210 differential cases |
| P2-5 | `Uuid::version()` returns `Unknown` unless the variant is RFC 4122. Rust `get_version()` is variant-agnostic (`4` + NCS/Microsoft/Future → `Some(Random)`). As a result `timestamp_ms()` also hides v7 timestamps for non-RFC variants. | `div_uuid_version_ignores_variant_like_rust`; 64 + 8 differential cases |
| P2-6 | No v1/v6 timestamp decoding: `timestamp_ms()` is v7-only, while Rust `get_timestamp()` decodes v1/v6/v7. There is also no `get_node_id`. | `div_uuid_timestamp_v1_v6`; 24 differential cases |
| P2-7 | `V7Context` has only a 12-bit counter (rand_a). A same-millisecond burst of 100k UUIDs pushes the embedded timestamp ~24 ms into the future, whereas Rust `ContextV7` (42-bit counter) keeps drift at 0 ms for 10k/100k/1M (`oracle` bin `v7ctx`). Monotonicity itself is correct (`ctl_v7context_monotonic_under_rollback_and_exhaustion`). | `div_v7context_counter_capacity_no_drift` |
| P2-8 | A bare trailing `\r` (input `"\r"`) is treated as a blank line by both line parsers; Rust `str::lines` keeps it and the parse fails. | differential lines 8568/8569 |
| P2-9 | API surface gaps vs `uuid 1.29.3`: no `from_fields`/`as_fields`(`_le`), `from_u128`/`as_u128`, `from_bytes_le`/`to_bytes_le`, `get_node_id`, `Timestamp`, no RNG/clock-backed `new_v4`/`now_v1`/`now_v6`/`now_v7` (by design: no `World`), and no error detail beyond the enum. vs `ulid 1.2.1`: no `Generator::generate` with a clock or RNG, no `datetime()`, no `u128` conversions. | source survey |

## POLICY: Pion is stricter than Rust and spec-correct (no action; listed for completeness)

- ULID with first char `'8'..'Z'` (> 128 bits): Pion returns `Overflow`. **Rust `ulid 1.2.1` silently truncates** (`"8000…"` → nil,
  `"ZZZ…"` → max), against the ULID spec's "must be rejected". 69 cases. Pion is better here.
- `new_v7` / `Ulid::from_parts` with timestamp > 48 bits, and `new_v1` / `new_v6` with ticks ≥ 2^60 or clock_seq > 14 bits: Pion
  returns `Err`, while Rust masks or truncates silently. 11 cases.

## Controls that held (attack surfaces probed, nothing found)

- **Parser bytes ≥ 128**: every position of hyphenated, simple and URN forms was replaced with `0x80/0xB0/0xB9/0xC1/0xE1/0xE6/0xAD/0xFF/0xC0`
  (bytes whose low 7 bits alias hex digits or `-`). All are rejected by `Uuid::parse`, `parse_bytes`, `parse_uuid_slice_raw` and
  `parse_uuid_lines_raw`. There is no out-of-bounds LUT read (`c >= 128` is checked first) and no `& 0x7F` aliasing. The same holds for ULID.
  Fullwidth and Arabic-Indic digits, Cyrillic `е`, BOM, invalid UTF-8 and NUL are all rejected without panic.
- **Shapes**: leading/trailing whitespace, CR/LF, half or mismatched braces, `{simple}`, `urn:uuid:` + simple, `urn:uuid:{…}`,
  shifted or missing hyphens, `0x`/`+`/`-` prefixes, every length 0–50, plus 3,000 random byte mutations: all identical to Rust.
  Uppercase `URN:UUID:` is accepted by both (Rust 1.29.3 uses `eq_ignore_ascii_case`).
- **Generators**: negative or over-range timestamps, `rand10` of length 0/9/11, `from_bytes` 15/17, short nodes, negative `write_bytes`
  offsets and short encode buffers all return `Err`/`false`/`0` without panicking (`ctl_generators_reject_bad_inputs`).
- **Monotonic generators**: `V7Context` stays strictly monotonic under 20k mixed same-ms/rollback/forward steps and surfaces
  `SequenceOverflow` at end-of-time. `MonotonicUlid` carries `rand_lo = 0xFFFF…` into `rand_hi`, returns `Overflow` at 80-bit
  saturation without wrapping into the timestamp, and recovers on a later millisecond.
- **version()/variant() matrix**: all 16 version nibbles × 11 variant bytes + Nil/Max/neighbours. `variant()` and `version_num()`
  match Rust everywhere; `version()` differs only as described in P2-5.

## wasm32

- The differential driver was built with `--target wasm32` and run on the full 8,594-case corpus: **stdout byte-identical to native**.
- Timings (Node + `pion_wasm_rt.mjs`, median ms; this host has no Rust wasm toolchain, so the baseline is Rust native):

| Workload | wasm `pion_raw` | wasm `pion_typed` | native `pion_raw` | native Rust |
| --- | ---: | ---: | ---: | ---: |
| UUID batch 500k | 121.0 (0.36×) | 187.7 (0.23×) | 56.3 (0.77×) | 43.5 |
| UUID v5+v7 200k | 88.8 (0.36×) | 101.2 (0.31×) | 61.5 (0.51×) | 31.6 |
| ULID batch 500k | 100.4 (0.36×) | 240.9 (0.15×) | 47.4 (0.77×) | 36.3 |

wasm32 peak RSS is 48–100 MiB (Node), against 2–37 MiB native.
