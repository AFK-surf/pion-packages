# Red-team audit: `packages/toml` (Pion) vs Rust `toml` / Go `BurntSushi/toml`

Target: `AFK-surf/pion-packages` `origin/main` @ `7a40e8f`, branch `audit/redteam-toml`.
Nothing outside `packages/toml/audit/` was changed.

References used for every claim:

| reference | version | why |
| --- | --- | --- |
| Rust `toml` | **1.2.2** (`+spec-1.1.0`, latest on crates.io) | what `cargo add toml` gives today |
| Rust `toml` | 0.8.23 (+ `toml_edit` 0.22.27) | what `packages/toml/bench/rust_bench/Cargo.lock` pins; strict TOML 1.0 |
| Go `BurntSushi/toml` | v1.6.0 | the toml-test authors' own implementation |
| `toml-lang/toml-test` | **v2.2.0** (latest tag) | official compliance suite, run with its own harness (decoder **and** encoder) |

Machine: Apple M5 Max (18 cores, Darwin arm64), pionc 0.1.0, cargo 1.100, go 1.27.3.
The machine was shared with other jobs (load average 30-45). All benchmarks are interleaved
`scripts/bench_compare.py` runs (warmup 1, 5 rounds, stdout SHA-256 identical across implementations);
numbers are from the final clean `run_audit.sh` run, with the earlier exploratory run in brackets
where load changed them noticeably. Conclusions only rely on gaps far larger than that spread.

## Reproduce

```sh
export PATH="$HOME/.pion/bin:$PATH"
sh packages/toml/audit/run_audit.sh            # everything, ~15-25 min; logs in /tmp/pion-toml-audit
sh packages/toml/audit/run_audit.sh --quick    # smaller sizes
SECTIONS="build dos" sh packages/toml/audit/run_audit.sh   # a subset
pionc test --json -p toml_redteam_audit packages/toml/audit # the failing-test evidence alone (~1 s)
```

`pionc test packages/toml/audit` (without `-p`) also runs the 722 tests of the `toml` dependency; they
still pass. **Note on layout:** the brief asked for `audit/tests/redteam_test.pion`, but `pionc test`
only discovers `*_test.pion` in the package root (a file under `tests/` is silently not run), so the
tests are `audit/redteam_test.pion` and `audit/crash_test.pion`.

Result of `pionc test --json -p toml_redteam_audit packages/toml/audit` today: **32 tests, 1 passed
(the control), 31 failed** — every failure is a finding below.

---

## Verdict in one paragraph

On *parsing correctness* Pion's `toml` is genuinely strong: it passes **all** of toml-test v2.2.0 for
TOML 1.0 (205/205 valid, 474/474 invalid, 205/205 encoder), and 20 000 mutated inputs found no parse
disagreement with Rust 0.8 + Go except the BOM policy (F4). It loses — with reproducible evidence — on
everything around the parser: **serialization silently changes floats (F1)**, **any 60-80 KB input can
crash the process (F8)**, **two cheap algorithmic DoS vectors (F9, F10)**, `stringify` can emit invalid
or injected TOML (F3), and **the README's "1.49× faster than Rust" is measured against an outdated
crate**: latest Rust `toml` is 1.30× faster on the README's own workload and 2.3-2.9× faster on
Cargo.lock-shaped, inline-row and float-dense input in steady state (B1, B2).

---

## P0

### F1 — `stringify` / `to_toml_test_json` silently change float values

`serialize.pion::format_exact_finite_float` starts from `Double::to_string` (runtime `"%.15g"`) and
falls back to a hand-rolled 17-digit routine that scales with inexact `* 1e16` arithmetic, tries
`mant-1, mant, mant+1` and **returns the wrong candidate when none round-trips**. Parsing is correct
(libc `strtod`); the corruption happens on output, so `parse → stringify → parse` returns a different
number with no error.

`diff/float_fuzz.py` (20 000 doubles per set; arbiter = Python `float()`, re-parse by Rust toml 1.2):

| input set | pion JSON wrong | pion `stringify` wrong | Rust `to_string` wrong |
| --- | ---: | ---: | ---: |
| uniformly random finite doubles (shortest repr) | 11 625 (58 %) | **11 625 (58 %)** | 0 |
| `random.random()` (what any Python/JS program writes) | 3 263 (16 %) | **3 263 (16 %)** | 0 |
| config-like `round(x, ≤6)` | 0 | 0 | 0 |

Examples (all in `redteam_test.pion`, tests `F1_*`):

| input | Pion writes | |
| --- | --- | --- |
| `0.8311652289356479` | `0.83116522893564784` | a different double |
| `1.7976931348623157e308` (DBL_MAX) | `1.797693134862315e+308` | 4 ulp smaller |
| `-1.989032661366619e+244` | `-1.9890326613666184e+244` | |

The README's claim "Bit-exact IEEE 754 float formatting — preserves full 17-digit double precision on
roundtrip" is false. The in-repo round-trip tests miss it because they only use short decimals
(`3.141592653589793` is exactly representable at 15 significant digits) and re-parse with Pion itself.

### F8 — unbounded recursion: small inputs kill the process (SIGSEGV)

`parse_value ↔ parse_array / parse_inline_table` recurse per nesting level, and `freeze_table /
freeze_val` (and the tree's drop) recurse per *table level* — so even a flat one-line header crashes.
Rust toml returns `Err("recursion limit")` in < 20 ms for every case; Go returns normally.
(`dos/dos_probe.py`; tests `crash_test.pion::F8*`, which `pionc test` reports as failed because the
test process dies.)

| input | size | Pion | Rust toml 1.2 | Go |
| --- | ---: | --- | --- | --- |
| `a = [[[…]]]`, 40 000 levels | 78 KiB | **SIGSEGV** | Err, 10 ms | OK, 26 ms |
| `[a.a.….a]` one header, 30 000 parts | 59 KiB | **SIGSEGV** | Err, 10 ms | OK, 2.8 s / 1.2 GiB |
| `a.a.….a = 1` one key, 50 000 parts | 98 KiB | **SIGSEGV** | Err, 16 ms | — |
| `a = {a = {…}}`, 100 000 levels | 586 KiB | **SIGSEGV** | Err | — |

A SIGSEGV cannot be caught: any service that parses user-supplied TOML (CI configs, manifests uploaded
to a registry) can be killed with a 60 KB file. Fairness note: Rust's limit also rejects legitimately
deep (> ~80 levels) arrays that Pion accepts up to ~20 000 levels; returning an error is still strictly
better than crashing.

### F9 — nested inline tables are super-quadratic

`parse_inline_table` calls `seal_inline_table(tbl)` at every `}`, which re-walks the whole sub-tree
already sealed by the inner `}`s: O(depth²) work plus allocation churn.

| `a = {a = {… 1}}` depth | size | Pion | Rust toml 1.2 |
| ---: | ---: | ---: | ---: |
| 2 500 | 15 KiB | 77 ms [72 ms] | 6 ms (Err) |
| 5 000 | 29 KiB | 250 ms [533 ms] | 7 ms |
| 10 000 | 59 KiB | 1.4 s [4.0 s] | 8 ms |
| 20 000 | 117 KiB | **7.4 s [23.6 s]** | 8 ms |

(Go BurntSushi is also quadratic here — 1.9 s and 1.1 GiB at depth 5 000 — Rust is the reference.)

### F10 — HashDoS: the per-table `Map[String, Int]` index uses an unseeded hash

Every `ParseTable` keeps `index : Map[String, Int]` for duplicate detection. The Pion runtime's
`pion_str_hash` (`~/.pion/share/pion/runtime/pion_rt.c`) has **no per-process seed**, and
`pion_map_probe` uses `h & (cap-1)` with linear probing. `dos/hashdos_gen.c` (the hash function copied
verbatim) brute-forces 12-character *bare* keys whose hashes share the low 16-17 bits; 60 000 of them
take ~4 s to generate once and work against every Pion program forever.

| input (same size, same shape) | size | Pion | Rust toml 1.2 | Go |
| --- | ---: | ---: | ---: | ---: |
| 20 000 random keys (control) | 399 KiB | 11.4 ms | 11.0 ms | 26.4 ms |
| 20 000 colliding keys | 399 KiB | **263 ms** [301 ms] | 13.4 ms | 22.9 ms |
| 60 000 random keys (control) | 1.2 MiB | 28.7 ms | 31.6 ms | 91.7 ms |
| 60 000 colliding keys | 1.2 MiB | **2 611 ms** [6 312 ms], 91× its control | 34.6 ms | 101.8 ms |
| 60 000 colliding keys in one inline table | 1.3 MiB | **2 639 ms** [5 870 ms] | 30.1 ms | 66.7 ms |

Rust `toml` stores tables in `BTreeMap` (`toml::Table`) and `toml_edit` uses `IndexMap` with
`RandomState` (SipHash, random keys); Go maps are randomly seeded. The root cause is in the Pion
runtime, so every Pion package that keys a `Map` by attacker-controlled strings is affected; for
`packages/toml` it is directly reachable from `parse`.

---

## P1

### B1 — the head-to-head benchmark compares against an obsolete Rust crate

`packages/toml/bench/rust_bench/Cargo.toml` asks for `toml = "0.8"` (lock: 0.8.23 on `toml_edit`
0.22, a format-preserving parser). The current crate (1.x, new `toml_parser`) is roughly 2× faster.
Re-running the README's *own* workload (`gen_data.py` corpus, 50 parses, same harness):

| README corpus ×50, median ms | pion | rust toml **1.2.2** | rust toml 0.8.23 | go |
| --- | ---: | ---: | ---: | ---: |
| final run | 128.1 | **98.4** | 185.4 | 308.1 |
| exploratory run | 177.0 | **111.9** | 223.9 | 279.0 |

i.e. **Rust is 1.30× (1.58×) faster than Pion** on the benchmark the README advertises as a Pion
1.49× win; against the pinned 0.8 Pion is indeed ~1.4× faster, which is all the README shows.
The full table for 10 workloads is in the appendix (regenerated by `run_audit.sh`, section `bench`).
Other fairness problems of the original setup: the corpus is generated by the porters and is pure
ASCII; there is only one input shape; no serialization or lookup benchmark exists.

### B2 — single-shot timings hide Pion's tree teardown; steady state is ~4× slower

Parsing the same 7.5 MB Cargo.lock-shaped file *N* times in one process (`bench/steady_state.py`,
parse only, no tree walk):

| parses per process | Pion ms/parse | Rust 1.2 ms/parse |
| ---: | ---: | ---: |
| 1 | 52.7 | 60.5 |
| 10 | 154.4 | 53.6 |
| 30 | 188.2 | 59.5 |

One parse per process shows Pion *ahead*; from the second parse on Pion's per-parse cost triples and
keeps growing (exploratory run with the tree walk: 93 → 178 → 266 → 340 → 363 ms/parse at
1/5/10/20/30 parses) while RSS stays flat at 88 MiB and Rust stays flat. The first parse is cheap
because the process exits before the Pion tree is torn down; every later parse pays for freeing the
previous `ParseTable` tree (one `Map` per table, inline table and AoT element) plus the frozen
`TomlValue` copy. Steady-state ×10 results (appendix B): Cargo.lock-like **Rust 2.9× faster**
(2 151 vs 744 ms), 50k inline rows **2.8×**, 200k doubles **2.3×**, 100k-key wide table **1.4×**. A long-running process that re-reads its
configuration pays the steady-state price. This is why `run_audit.sh` parses every workload ≥ 10 times.

### F2 — out-of-range floats silently become ±inf

`a = 1e400` and `a = -1.5e309` parse to `inf` / `-inf` (`strtod` overflow is not checked). Rust 1.2
("floating-point number overflowed"), Rust 0.8 ("invalid floating-point number") and Go ("out of
range for float64") all reject. Tests `F2_*`.

### F3 — `stringify` returns `Ok` with invalid or injected TOML

`TomlValue`'s datetime variants are bare `String`s and `Table` is a plain `Array[(String, TomlValue)]`,
and the serializer writes datetimes verbatim and never checks keys:

* `LocalDate("not a date")` → `d = not a date` (unparsable), `OffsetDateTime("")` → `d = `
* `Table([("a", 1), ("a", 2)])` → `a = 1\na = 2` (duplicate key)
* **injection:** `LocalTime("07:32:00\nadmin = true")` → the output parses fine and contains a new
  top-level key `admin = true`.

In Rust these values cannot be constructed: `toml::value::Datetime` only comes from a validating
parser/constructor and `toml::Table` is a map. Tests `F3_*`.

### F11 — `toml::get` is a linear scan

`get(value, key)` walks `Array[(String, TomlValue)]`; there is no indexed lookup in the public API.
Looking up every key of a 30 000-key table: **Pion 1 982 ms vs Rust 23 ms (86×)** (bench_compare,
3 rounds); at 100 000 keys 47.7 s vs 48 ms (≈1 000×). Rust `Table::get` is O(log n) (O(1) with `preserve_order`).

---

## P2

### F4 — UTF-8 BOM rejected

`parse_validated` rejects a leading `EF BB BF` ("UTF-8 BOM is not allowed in TOML v1.0.0"). Rust 1.2,
Rust 0.8 and Go all accept it (toml-test only marks `bom-not-at-start-*` invalid). Files saved by
Windows editors fail to load. This was also the **only** class of disagreement found by 20 000
mutated differential cases (5 hits, all BOM). Test `F4_*`.

### F5 — error locations

* Table-conflict and EOF errors are reported on the line *after* the culprit (`[a]\n[a]\n` → line 3;
  `a = [1,\n  2\n` → line 3, which does not exist). Over the toml-test v2.2.0 invalid corpus, on the
  408 files where Rust and Go agree on the error line, Pion reports a different line for 29
  (`diff/errpos_corpus.py`).
* Duplicate keys point at the end of the value (`2:6`), not the key (`2:1`).
* Columns count UTF-8 **bytes**, not characters (`a = "é" x` → col 10; Rust/Go: 9).
* Only `(line, col, offset, message)`: no span, no source snippet (Rust prints a caret diagnostic).

Tests `F5_*`.

### F6 — TOML 1.1.0 unsupported

toml-test v2.2.0 with `-toml 1.1`: Pion 204/214 valid, Rust toml 1.2 210/214. Missing: `\e`,
`\xHH`, newlines and trailing commas in inline tables, times without seconds. Rust ≥ 0.9 and
BurntSushi v1.6 parse TOML 1.1 by default. Tests `F6_*`.

### F7 — datetimes are untyped strings

`as_datetime` returns the source spelling: `1979-05-27T07:32:00Z`, `1979-05-27t07:32:00z` and
`1979-05-27 07:32:00Z` are the same instant but three different values; callers must re-parse.
Rust gives `toml::value::Datetime {date, time, offset}`, Go gives `time.Time`. Test `F7_*`.

### Capability gaps (no single test; from the public API in `README.md` / `src/types.pion`)

| capability | Rust `toml` / `toml_edit` | Go BurntSushi | Pion `toml` |
| --- | --- | --- | --- |
| typed decoding into structs | serde `#[derive(Deserialize)]` | struct tags, `MetaData.Undecoded()` | none: hand-walk `Array[(String, TomlValue)]` |
| typed encoding from structs | serde `Serialize` | `Encoder` | build `TomlValue` by hand |
| spans on values/keys | `toml::Spanned<T>`, `toml_edit` spans | `MetaData.Keys()` / positions | only on errors |
| format-preserving edits (comments, order, style) | `toml_edit::DocumentMut` | — | no; `stringify` drops comments and moves scalars before sub-tables |
| pretty output | `to_string_pretty` (multi-line strings, array layout) | `Encoder.Indent` | one fixed style |
| indexed lookup / dotted path lookup | `Table::get`, `Value::get`, `Index` | map | linear `get` only (F11) |
| datetime type | `Datetime` | `time.Time` | `String` (F7) |
| TOML 1.1 | yes | yes | no (F6) |

### Where Pion is better (for balance)

* toml-test v2.2.0, TOML 1.0: Pion passes everything, Rust 1.2 fails 9 invalid cases (it implements
  1.1, so it accepts 1.1-only syntax) — Pion is the stricter 1.0 parser.
* Pion accepts nesting up to ~20 000 levels where Rust stops at ~80 (but see F8 above that).
* Rust 1.2 writes `1.7976931348623157e308` as a 309-digit literal; Pion uses an exponent.
* Pion wins steady-state parsing of escape-heavy strings (1.14×), `stringify` of the README corpus
  (1.50×) and of the Cargo.lock file (1.05×), and ties on 5 000 small manifests (appendix B).
* The README's "208 valid + 509 invalid" figure refers to an older toml-test release; v2.2.0 lists
  205 + 474 for TOML 1.0.0 and Pion passes all of them, so the compliance claim itself holds.

---

## Appendix A — what each file does

| path | purpose |
| --- | --- |
| `pion.toml`, `redteam_test.pion` | 27 failing tests (F1-F7), assert reference behaviour |
| `crash_test.pion` | F8 crash tests (each dies with SIGSEGV) + 1 passing control |
| `run_audit.sh` | one-shot build + every section below |
| `tools/pion_cli` | Pion CLI: `decode` / `encode` (toml-test), `errpos`, `roundtrip`, `bench-*` |
| `tools/rust_ref` | same CLI on Rust toml 1.2.2 and (prefix `v08-`) 0.8.23 |
| `tools/go_ref` | decode / errpos / bench on Go BurntSushi v1.6.0 |
| `scripts/pion_stdin.sh` | toml-test adapter (the CLIs read files, toml-test writes stdin) |
| `diff/probes.py`, `diff/diff_probe.py` | 132 hand-written edge cases × 4 implementations |
| `diff/fuzz_diff.py` | mutational differential fuzzer seeded by toml-test |
| `diff/float_fuzz.py` | F1 statistics |
| `diff/roundtrip_corpus.py` | stringify fidelity on the toml-test valid corpus (Pion 205/205, Rust 205/205) |
| `diff/errpos_corpus.py` | F5 statistics |
| `dos/dos_probe.py`, `dos/hashdos_gen.c` | F8-F11 and large-input memory |
| `bench/gen_adversarial.py`, `bench/steady_state.py` | B1/B2 workloads |

## Appendix B — benchmark tables

Verbatim `bench_compare.py` output of the final `run_audit.sh` run (`$AUDIT_OUT/bench/ALL.md`); baseline = Rust toml 1.2.2; stdout SHA-256 verified identical for every table.

## parse: packages/toml/bench corpus (150 KB) x50 -- the README's own workload

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `203 B` (`sha256:96cf0bf395d107be...`) | Input: `7526500 B` | Ops: `50`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_toml_1.2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 128.144 | 106.700 | 156.122 | 58.73 | 2562872.50 | 4.62 MiB | 0.77x |
| `rust_toml_1.2` | 98.417 | 93.567 | 103.273 | 76.48 | 1968345.84 | 7.06 MiB | 1.00x (baseline) |
| `rust_toml_0.8` | 185.355 | 173.115 | 194.333 | 40.61 | 3707096.66 | 7.59 MiB | 0.53x |
| `go_burntsushi` | 308.142 | 287.969 | 355.447 | 24.43 | 6162839.16 | 14.30 MiB | 0.32x |

_SHA-256 verified identical across all implementations and rounds: `96cf0bf395d107be36971cbfc72ed7e4f72ed4dfb5d7bcebb3c3b0076b10a67f`._
## parse: Cargo.lock-like, 30k [[package]] (7.5 MB) x10

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `183 B` (`sha256:739ed4aa3d7f2f35...`) | Input: `78624230 B` | Ops: `10`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_toml_1.2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 2150.722 | 2118.026 | 2191.779 | 36.56 | 215072158.40 | 88.20 MiB | 0.35x |
| `rust_toml_1.2` | 744.489 | 696.898 | 765.343 | 105.61 | 74448912.50 | 147.83 MiB | 1.00x (baseline) |
| `rust_toml_0.8` | 1076.633 | 1072.351 | 1160.972 | 73.03 | 107663325.00 | 153.14 MiB | 0.69x |
| `go_burntsushi` | 1332.647 | 1310.282 | 1348.409 | 59.00 | 133264662.50 | 127.73 MiB | 0.56x |

_SHA-256 verified identical across all implementations and rounds: `739ed4aa3d7f2f354a9e1672fb8a1b888af249108b22656b4fe7ff26819dd8b2`._
## parse: 50k inline-table rows (2.8 MB) x10

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `203 B` (`sha256:8f2decf2aadcb9b3...`) | Input: `29416810 B` | Ops: `10`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_toml_1.2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 1629.843 | 1502.811 | 1704.360 | 18.05 | 162984333.40 | 85.81 MiB | 0.36x |
| `rust_toml_1.2` | 591.198 | 548.805 | 1247.494 | 49.76 | 59119816.70 | 188.06 MiB | 1.00x (baseline) |
| `rust_toml_0.8` | 1079.128 | 1039.029 | 1093.644 | 27.26 | 107912808.40 | 188.12 MiB | 0.55x |
| `go_burntsushi` | 1183.451 | 1117.366 | 1203.404 | 24.86 | 118345141.60 | 129.22 MiB | 0.50x |

_SHA-256 verified identical across all implementations and rounds: `8f2decf2aadcb9b347922c88c8dadef94a1d4d8a2a986b976d150ee9650b55fe`._
## parse: 200k program-written doubles (3.8 MB) x10

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `159 B` (`sha256:8c827a116624ce30...`) | Input: `39613330 B` | Ops: `10`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_toml_1.2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 735.553 | 716.968 | 827.058 | 53.86 | 73555266.70 | 25.80 MiB | 0.44x |
| `rust_toml_1.2` | 324.645 | 307.126 | 403.797 | 122.02 | 32464479.20 | 65.67 MiB | 1.00x (baseline) |
| `rust_toml_0.8` | 710.570 | 683.861 | 844.725 | 55.75 | 71057000.00 | 62.80 MiB | 0.46x |
| `go_burntsushi` | 710.471 | 699.248 | 760.909 | 55.76 | 71047095.80 | 51.64 MiB | 0.46x |

_SHA-256 verified identical across all implementations and rounds: `8c827a116624ce30d427f4b590f4e094ee962b5c032e444c58a38048fe8e1045`._
## parse: 20k escape-heavy basic strings (2.3 MB) x10

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `170 B` (`sha256:c8f5b2feac3ffb3a...`) | Input: `24111520 B` | Ops: `10`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_toml_1.2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 283.373 | 256.876 | 303.562 | 85.09 | 28337258.30 | 12.16 MiB | 1.14x |
| `rust_toml_1.2` | 324.438 | 294.772 | 410.789 | 74.32 | 32443787.50 | 18.55 MiB | 1.00x (baseline) |
| `rust_toml_0.8` | 453.326 | 370.485 | 895.014 | 53.19 | 45332620.80 | 16.97 MiB | 0.72x |
| `go_burntsushi` | 586.580 | 523.632 | 613.749 | 41.11 | 58657979.20 | 44.72 MiB | 0.55x |

_SHA-256 verified identical across all implementations and rounds: `c8f5b2feac3ffb3adaf399ed4c104aebabba3f2a63fbee38d020fbf5a748a060`._
## parse: 400 multi-line doc strings (3.9 MB) x10

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `168 B` (`sha256:9536cf33fc03d3a0...`) | Input: `40558890 B` | Ops: `10`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_toml_1.2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 294.620 | 282.393 | 415.211 | 137.66 | 29462045.90 | 12.80 MiB | 0.85x |
| `rust_toml_1.2` | 251.054 | 249.018 | 257.319 | 161.55 | 25105433.40 | 11.42 MiB | 1.00x (baseline) |
| `rust_toml_0.8` | 258.114 | 248.078 | 262.006 | 157.14 | 25811391.70 | 12.14 MiB | 0.97x |
| `go_burntsushi` | 462.924 | 443.268 | 471.863 | 87.61 | 46292408.40 | 51.56 MiB | 0.54x |

_SHA-256 verified identical across all implementations and rounds: `9536cf33fc03d3a0fc4fc5e1ce0459418576809062a92cf58e24faddada0cf44`._
## parse: wide table, 100k keys (2.9 MB) x10

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `165 B` (`sha256:52f12ee020e8efd7...`) | Input: `30888380 B` | Ops: `10`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_toml_1.2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 640.354 | 610.810 | 661.534 | 48.24 | 64035400.00 | 41.81 MiB | 0.71x |
| `rust_toml_1.2` | 452.835 | 410.760 | 459.541 | 68.21 | 45283512.50 | 68.11 MiB | 1.00x (baseline) |
| `rust_toml_0.8` | 722.761 | 713.054 | 817.737 | 42.74 | 72276133.30 | 52.66 MiB | 0.63x |
| `go_burntsushi` | 1516.729 | 1435.998 | 1575.033 | 20.37 | 151672937.50 | 95.28 MiB | 0.30x |

_SHA-256 verified identical across all implementations and rounds: `52f12ee020e8efd7908e061af6c4bf4babdf51ed4baee0c1c6426b7998847627`._
## parse: 3000 dotted headers up to 60 deep (0.4 MB) x30

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `165 B` (`sha256:063fbb2e014e98e8...`) | Input: `11970870 B` | Ops: `30`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_toml_1.2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 230.672 | 216.501 | 245.078 | 51.90 | 7689069.47 | 6.38 MiB | 0.89x |
| `rust_toml_1.2` | 205.480 | 198.102 | 223.102 | 58.26 | 6849327.77 | 19.30 MiB | 1.00x (baseline) |
| `rust_toml_0.8` | 504.830 | 482.023 | 523.105 | 23.71 | 16827684.73 | 10.78 MiB | 0.41x |
| `go_burntsushi` | 696.855 | 670.634 | 754.176 | 17.18 | 23228504.17 | 37.12 MiB | 0.29x |

_SHA-256 verified identical across all implementations and rounds: `063fbb2e014e98e8fe44e4ca2de0686896e8ea1cf5efc8b8a03ccd03eb85f2cd`._
## parse: 5000 small Cargo-style manifests

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `175 B` (`sha256:b0bb2ecff2769e47...`) | Ops: `5000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs rust_toml_1.2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 94.414 | 92.224 | 101.622 | 18882.73 | 2.47 MiB | 0.98x |
| `rust_toml_1.2` | 92.773 | 91.586 | 106.752 | 18554.60 | 2.78 MiB | 1.00x (baseline) |
| `rust_toml_0.8` | 105.480 | 101.737 | 111.254 | 21095.89 | 2.67 MiB | 0.88x |
| `go_burntsushi` | 151.909 | 148.968 | 157.020 | 30381.82 | 15.11 MiB | 0.61x |

_SHA-256 verified identical across all implementations and rounds: `b0bb2ecff2769e479648025604da757837d88198b75da8decdd1170d88589a5a`._
## stringify: corpus x50

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `17 B` (`sha256:5995d50f0f647109...`) | Ops: `50`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs rust_toml_1.2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 28.142 | 26.226 | 29.478 | 562830.00 | 4.91 MiB | 1.50x |
| `rust_toml_1.2` | 42.275 | 41.358 | 44.259 | 845501.68 | 7.28 MiB | 1.00x (baseline) |
| `rust_toml_0.8` | 145.067 | 142.521 | 146.353 | 2901332.50 | 10.33 MiB | 0.29x |

_SHA-256 verified identical across all implementations and rounds: `5995d50f0f64710902fffbf613406799084ac689294a71ad1d849a483f644960`._
## stringify: Cargo.lock-like (7.5 MB)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `16 B` (`sha256:60b9c9cbef18db36...`) | Ops: `3`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs rust_toml_1.2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 87.825 | 86.126 | 92.062 | 29275111.00 | 98.83 MiB | 1.05x |
| `rust_toml_1.2` | 92.199 | 90.763 | 95.991 | 30732958.33 | 115.73 MiB | 1.00x (baseline) |
| `rust_toml_0.8` | 363.278 | 354.250 | 372.143 | 121092597.33 | 259.69 MiB | 0.25x |

_SHA-256 verified identical across all implementations and rounds: `60b9c9cbef18db3662e8f7129e2709ce8639367b008bcf2c55115c9a525c343c`._
## stringify: 200k doubles

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `16 B` (`sha256:60b9c9cbef18db36...`) | Ops: `3`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs rust_toml_1.2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 286.933 | 278.244 | 290.279 | 95644375.00 | 31.89 MiB | 0.25x |
| `rust_toml_1.2` | 70.350 | 68.522 | 78.426 | 23450041.67 | 57.31 MiB | 1.00x (baseline) |
| `rust_toml_0.8` | 172.407 | 169.240 | 172.877 | 57469166.67 | 110.62 MiB | 0.41x |

_SHA-256 verified identical across all implementations and rounds: `60b9c9cbef18db3662e8f7129e2709ce8639367b008bcf2c55115c9a525c343c`._
## lookup: get() each key of a 30k-key table

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `3` (strictly interleaved) | Stdout: `34 B` (`sha256:70992ec5c46cce7f...`) | Ops: `30000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs rust_toml_1.2) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 1982.047 | 1893.255 | 2038.569 | 66068.24 | 11.12 MiB | 0.01x |
| `rust_toml_1.2` | 23.044 | 21.922 | 32.955 | 768.14 | 16.81 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `70992ec5c46cce7f4a9ab5e152721dd42a0e44a8579916295c66a1d407385399`._
