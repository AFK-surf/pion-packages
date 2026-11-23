# Red-team audit: `packages/hyphenation` vs Rust `hyphenation =0.8.4`

Target: `packages/hyphenation` v0.1.0 at `62b43a6` (branch `feat/pkg-hyphenation`), `pionc 0.1.0` (self-hosted), Darwin arm64 (Apple M5 Max).

Oracle: Rust `hyphenation =0.8.4` + `hyphenation_commons =0.8.4`, pinned in `rust/Cargo.lock`. The oracle uses `Standard::from_embedded(Language::EnglishUS)`, the crate's own bincode with 4,938 patterns and 1,441 exceptions. It can also load any `.pat.txt`/`.hyp.txt` through the crate's own `Parse::pair` + `Builder`, the same path as its `build.rs`, with `minima` overridden.

Reproduce everything with one command. All outputs go to `/private/tmp/redteam-hyph`, and `git status --porcelain --ignored` stays empty:

```sh
sh packages/hyphenation/audit/run_audit.sh          # QUICK=1 smaller; HUGE=1 adds the 2 x 1.1 GB limit-wrap probe
python3 packages/hyphenation/audit/scripts/one.py --dict en_us WORD...            # one-off: Pion vs Rust
python3 packages/hyphenation/audit/scripts/one.py --dict PATS:HYP:LMIN:RMIN WORD... # custom tables on both sides
python3 packages/hyphenation/audit/scripts/one.py --text - "computer—typography"   # hyphenate_text
```

(`one.py` needs the binaries from step 1 of `run_audit.sh`.)

| Part | Contents |
|---|---|
| `redteam_test.pion` | 21 tests: 7 `p1_`, 5 `p2_` (each failure is evidence) and 9 `control_` tests that must pass |
| `probe/` | Pion batch probe (`opp`, `all`, `text`, `load`, `bulk`, `bulka`), built in 4 modes |
| `rust/` | `oracle` binary: same CLI and record format, on hyphenation 0.8.4 |
| `scripts/diff.py` | English differential, 568,355 records in 15 classes × 3 dictionary setups, plus split/hyphenate invariants |
| `scripts/multilang.py` | all 80 hyph-utf8 tables bundled with the crate, loaded from the same text on both sides, 487,341 words |
| `scripts/text_diff.py` | `hyphenate_text` round-trip and per-word consistency, 4,000 texts × 4 separators |
| `scripts/dos.py` | 7 adversarial pattern shapes and 4 query shapes at N and 2N, plus 2 Int32 crash/limit probes |
| `scripts/wasm4.py` | Native debug/release and Wasm32 debug/release, all executed (node), compared by SHA-256 |
| `scripts/bench_fair.py` | re-run of `bench/` through `scripts/bench_compare.py` with fairness variants |

`pionc test --json -p hyphenation_audit packages/hyphenation/audit` gives `total=21 passed=9 failed=12`. All 12 p1/p2 tests fail, which is the evidence, and all 9 controls pass. The package's own suite is untouched (`11/11`), and `fmt`/`check` are clean.

## Summary

| ID | Sev | Finding |
|---|---|---|
| P1-1 | P1 | Built-in `en_us()` is not hyph-utf8 / Rust en-us: it ships 14 TeXbook exceptions instead of the 1,441 hyph-utf8 ones. 276 of 239,642 dictionary words differ (`hyphenation` → `hy-phen-ation` vs `hy-phen-a-tion`). The README calls the table "standard hyph-utf8", and the benchmark measures a different table (the crate's 1,441). |
| P1-2 | P1 | Non-ASCII letters are never case-folded. ALL-CAPS Cyrillic, Greek, Armenian and Georgian words get no breaks. Capitalised Latin words with diacritics lose inhibiting patterns and get breaks the dictionary forbids. This accounts for 46,459 of the 49,934 diffs across 80 languages. |
| P1-3 | P1 | `hyphenate_text` glues Unicode punctuation and spaces (curly quotes, em/en dash, NBSP, ZWSP, bullet, «», …) to the word. 2,724 of 10,748 such words (25%) break differently from the bare word, and 2,409 of them violate `left_min`/`right_min` (`com-put-er—-ty-pog-ra-phy`). ASCII neighbours: 0 / 15,178. |
| P1-4 | P1 | Int32 overflow of the packed value pointer `-((off << 8) | cnt)`. With raised `Limits` (16.8 MB, 524,289 patterns) `from_tex` returns `Ok`, then every query on the affected key panics (`index 134217745 out of bounds`) in all 4 modes. Rust loads and answers the same input. |
| P2-1 | P2 | `max_input_bytes` check wraps in Int32: 2 × 1.1 GB input passes the **default** 1 MiB limit (`Ok` after 7.5 s, 3.2 GB RSS). |
| P2-2 | P2 | DAT packing is O(N²) once `max_trie_nodes` is raised (growth 3.9–4.1 at 2.4 M → 4.8 M nodes, 221 MB RSS vs Rust 24 MB). Bounded by the default limits (worst case measured: 0.1 s). |
| P2-3 | P2 | A duplicate pattern key with different values is silently last-wins. Rust keeps the first; TeX raises "Duplicate pattern". This hits real hyph-sq (`2dhj`/`dh2j`, `3sh4pr`/`2shpr`): 56 lowercase diffs. |
| P2-4 | P2 | Patterns containing `-` (hyph-ru/uk/be/pt/tk/af: 3,419 lowercase diffs) are accepted into the alphabet but can never match, because every API splits at `-`. |
| P2-5 | P2 | Soft hyphens (U+00AD) already in the word are ignored. Rust returns exactly those positions, while Pion hyphenates over them (`hy­phen­a-tion`). |
| P2-6 | P2 | `opportunities` refuses any token with an ASCII non-letter (`organization's` → `[]`) while `hyphenate_text` hyphenates the same word; Rust gives `[2,4,6,8]`. |
| P2-7 | P2 | U+0130 `İ` is not refolded as Rust does (192 diffs, e.g. `allopİhyle`). |
| P2-8 | P2 | The README's "zero-allocation hot path" is false: `opportunities_into` allocates a `FixedArray(2·len+5)` per call (`src/hyphenation.pion:580`). The query scratch is about 18 B/byte (141 MB RSS for an 8 MB word vs Rust 17.5 MB), with no limit. |
| Bench | — | The 3.38× lead is real: 3.3–3.5× on the bench corpus and 2.6–3.7× on 235,915 distinct dictionary words, not from buffer reuse or API overhead. But the bench corpus is 214 words, `en_us()` ships different tables (P1-1), and "load" compares text parsing with bincode (Pion is 0.74× vs Rust building from the same text). See §Benchmark. |

There is no P0. The engine is exact: on the crate's own tables Pion agrees with Rust on **100.000%** of the 514,215 letter-only records (dictionary, case variants, short, long compounds, exceptions), once exceptions get TeX case-insensitive semantics; see control C-1. There are 0 panics in 4 modes over every corpus, except the deliberate P1-4 crash, which fails identically in all 4 modes.

---

## P1-1 `en_us()` is not the hyph-utf8 / Rust en-us dictionary

`src/en_us_data.pion` says *"Source: hyph-utf8 `hyph-en-us.hyp.txt` (14 exceptions)"*. hyph-utf8's `hyph-en-us.hyp.txt`, which the Rust crate vendors byte-for-byte as `patterns/hyph-en-us.hyp.txt`, has **1,441** entries. The 14 embedded words are Knuth's TeXbook `\hyphenation` list (`as-so-ciate … ta-ble`), and **none** of them is in hyph-utf8's list. The 4,938 patterns are identical (token-for-token).

| word | Pion `en_us()` | Rust en-us |
|---|---|---|
| `hyphenation` | `[2,6]` hy-phen-ation | `[2,6,7]` hy-phen-a-tion |
| `acronym` | `[]` | `[4]` |
| `accusative` | `[2]` | `[2,4,6]` |
| `acupuncture` | `[7]` | `[3,7]` |

`diff.py` en_us setup: `dict_lower` 276 / 239,642 diffs, `dict_capitalized` 95, `dict_upper` 89, `exceptions` 1,983 / 4,362. The package's own test and `wasm_smoke` pin the 14-exception count and `[2,6]` for "hyphenation", so the divergence is baked into the acceptance tests.

`bench/run_bench.sh` copies the crate's 1,441-exception file over the generated tables before running, so **the published benchmark does not measure the dictionary `en_us()` ships**. Fix: embed hyph-utf8's `hyph-en-us.hyp.txt`, or document the TeXbook list and rename the claim.

Tests: `p1_en_us_exception_table_is_texbook_14_not_hyph_utf8_1441`, `p1_en_us_diverges_from_rust_en_us_on_common_words`.

## P1-2 Non-ASCII case folding missing (multi-script dictionaries)

`char_map` folds only `A–Z` (`src/hyphenation.pion:33`, `:143`). Rust lowercases every query with `str::to_lowercase` (`case_folding.rs`). Any uppercase non-ASCII byte maps to id 0, which cuts the trie walk.

* **No breaks at all** for ALL-CAPS words in non-Latin scripts: `ПРОГРАММИРОВАНИЕ` → Pion `[]`, Rust `[6,14,18,22,26]` (hyph-ru). The same holds for `ΚΑΛΗΜΈΡΑ` (el-monoton), and for Armenian, Georgian (Mtavruli), Coptic, Church Slavonic and Bulgarian.
* **Forbidden breaks added**: an uppercase letter hides the even (inhibiting) value its lowercase pattern carries. Minimal case: `from_tex("1b ä2b")` gives `"äb"` → `[]` but `"Äb"` → `[2]`. In real tables: `ODRŽSMČ` (sh-latn) Pion `[2]` vs Rust `[]`, and `RSTILHTØPSE` (nb) `[2,10]` vs `[2]`.

`multilang.py` (80 tables, both sides loading the same text): 46,459 of 49,934 diffs are in words with uppercase letters. Every language with a cased script is affected (`hu` 1,414, `ru` 2,161, `el-polyton` 1,621, `de-1996` 173, …). The 20 identical languages are exactly the caseless scripts (Indic, Thai, Ethiopic) plus en-us/en-gb/ia/id/it/pms/rm. Fix: fold with Unicode simple lowercase at query time (and Rust's `İ` refold), keeping byte offsets aligned to the original.

Tests: `p1_uppercase_cyrillic_greek_get_no_breaks`, `p1_uppercase_umlaut_hides_inhibiting_pattern_and_adds_forbidden_break`.

## P1-3 `hyphenate_text` treats every non-ASCII byte as a letter

`is_word_byte` returns `true` for every byte ≥ 0x80 (`src/hyphenation.pion:464`). In running text, `“ ” ‘ ’ — – … « » ¿ ¡ • NBSP ZWSP ideographic-space` and emoji all become part of the word. The neighbour then counts as a character toward `left_min`/`right_min`, and the word-boundary `.` patterns no longer apply.

| input | Pion `hyphenate_text(…, "-")` | bare words |
|---|---|---|
| `computer—typography` | `com-put-er—-ty-pog-ra-phy` | `com-puter`, `ty-pog-ra-phy` |
| `hyphenation typography` | `hy-phen-ation -ty-pog-ra-phy` | `hy-phen-ation`, `ty-pog-ra-phy` |
| `•greenth​` | `•green-th​` | `greenth` |

`text_diff.py` (4,000 texts, identical for all 4 separators): words with only ASCII neighbours have 0 / 15,178 wrong. Words with a Unicode neighbour have **2,724 / 10,748 wrong, and 2,409 of them put a break closer than 2 letters to the start or 3 letters to the end** of the real word. Round-trip itself is always exact (0 failures), so this is wrong output rather than corruption. Fix: classify scalars, not bytes (letters/marks vs punctuation/space), the same way `opportunities` trims ASCII punctuation.

Tests: `p1_hyphenate_text_em_dash_breaks_minima`, `p1_hyphenate_text_nbsp_breaks_left_min`, `p1_hyphenate_text_curly_quote_breaks_right_min`.

## P1-4 Int32 overflow of the packed value pointer → panic on query

`Int` is 32-bit in Pion (`1 << 40 == 256`, `2147483647 + 1 == -2147483648`). Multi-value pattern nodes store `-((off << 8) | cnt)` (`src/hyphenation.pion:290`), and exception nodes store `(off << 8) | kept` (`:369`). Once `val_pairs` passes 2²³ entries, `off << 8` wraps:

* `off ∈ [2²³, 2²⁴)`: the stored value is positive and is read back as a *single* value at position `meta >> 4`, which gives an out-of-bounds index and a **panic**;
* `off ∈ [2²⁴, 2²⁴+2²³)`: it wraps to a small negative value that points at earlier, unrelated `val_pairs`, so values are **silently wrong**.

Duplicate keys re-push their pairs every time, so this needs neither many trie nodes nor a large alphabet:

```sh
python3 -c 'print(("1"+"1".join("abcdefghijklmno")+"1\n")*524289, end="")' > /tmp/ovf.pat   # 16.8 MB
printf '15\nabcdefghijklmno' > /tmp/ovf.in
/private/tmp/redteam-hyph/bin/pion_probe opp /tmp/ovf.pat - 1 1 /tmp/ovf.in /tmp/ovf.out 1073741824 16777216 16777216 4096 4096 67108864
# pion panic: index 134217745 out of bounds (len 35)        (native: SIGABRT; wasm32: trap)   — Rust: ok
```

`load` on the same input returns `ok`: the dictionary looks valid and the crash comes later, inside `opportunities`/`hyphenate_text`. The defaults (1 MiB) cannot reach it, but `Limits` accepts any value and nothing documents the hidden 2²³-pair ceiling. Fix: reject `val_pairs`/`exc_points` > 2²³ with `TooManyPatterns`/`TooManyExceptions`, or store `off` and `cnt` in separate arrays. Deduplicating repeated keys would also stop the blow-up.

Reproduced by `dos.py` (`crash:meta_offset_int32_overflow`) and `wasm4.py`: native debug/release rc = SIGABRT, wasm32 debug/release rc = 1 with the same panic.

## P2 findings

**P2-1 `max_input_bytes` wraps.** `patterns.length() + exceptions.length() > max_input_bytes` (`src/hyphenation.pion:73`) is Int32. Two 1,107,296,256-byte whitespace inputs sum to a negative number, and the **default** limit lets them through: `ok 0 0` after 7.5 s scan and 3.2 GB RSS (`HUGE=1 run_audit.sh`, `limits:max_input_bytes_int32_wrap`). Fix: compare each length separately (`p > max || e > max - p`).

**P2-2 Quadratic DAT packing.** In `pack_raw_trie` (`src/trie.pion:133-173`), `first_free` only advances over a contiguous occupied prefix, or when the 95% heuristic fires. `nonzero_num` counts only the cells skipped at `b + min_c` and not the failed full-fit attempts, so the heuristic rarely fires on sparse tries, and every node rescans the same holes. `dos.py`, limits raised:

| probe (60k → 120k patterns) | Pion N / 2N s | growth | Pion RSS | Rust N / 2N s | growth |
|---|---|---|---|---|---|
| `long_disjoint_64` (2.4 M → 4.8 M nodes) | 0.69 / 2.66 | **3.86** | 221 MB | 0.26 / 0.49 | 1.87 |
| `random_saturated_alphabet` (227-byte alphabet) | 0.18 / 0.48 | 2.8 (4.8 in an earlier run) | 39 MB | 0.07 / 0.10 | 1.6 |
| `fanout_all_pairs`, `sparse_two_children`, `sparse_byte_extremes`, `duplicates_multi_digit`, `nested_prefixes` | ≤ 0.10 | 0.95–2.2 | ≤ 38 MB | similar | — |

Under the **default** limits the worst shape stops at 262,144 nodes, about 0.04–0.1 s, so this is not a DoS with defaults. It matters for anyone raising `max_trie_nodes`. Fix: a free-cell list or bitmap (darts-clone / cedar style), and count every rejected `b` in the heuristic.

**P2-3 Duplicate keys are last-wins.** `from_tex("a2b a1b")` gives `ab` → `[1]` (Pion), `[]` (Rust keeps the first, via `uniques()` stable sort + dedup), and TeX raises the error "Duplicate pattern". Real impact: hyph-sq has two such keys, giving 56 lowercase diffs (`dnxdhj` Pion `[2,3]`, Rust `[2]`). Suggest `InvalidPattern`, or per-position max merge, and document it.

**P2-4 `-` patterns are dead.** hyph-ru (`.а-8`, `--8`), uk, be, pt (`1-`), tk and af encode hyphen rules for compounds. `from_tex` puts `-` into the alphabet, but `is_word_byte`/`opportunities_into` always split at `-` (`src/hyphenation.pion:467`, `:698`, `:713`), so these patterns never fire. Each segment is then hyphenated with its own minima. Lowercase diffs: ru 1,173, uk 1,394, be 810, af 28, pt 13, tk 1. Example: `ab-cd` with `1-` gives Rust `[2]`, Pion `[]`. Suggest: when the alphabet contains `-`, hyphenate the compound as one word. Otherwise reject such patterns, or at least document the behaviour.

**P2-5 Soft hyphens ignored.** Rust's `hyphenate` returns the U+00AD positions when the word already contains any (`soft_hyphen_indices`). Pion runs patterns across them instead. `hy­phen­ation` gives Pion `[11]` (an extra break after the author's own marks) and Rust `[2,8]`. In `unicode_marks`, 357 diffs are all U+00AD.

**P2-6 `opportunities` vs `hyphenate_text` disagree.** In `hyphenate_segment_into`, any ASCII byte outside the alphabet makes the whole segment return `[]`. So `opportunities("organization's")`, `("abroma67")` and `("a\tb…")` give `[]`, while `hyphenate_text` splits those bytes out and hyphenates the word (`or-ga-ni-za-tion's`). Rust gives `[2,4,6,8]`. The `apostrophe`, `digits` and `whitespace_ctl` classes in `diff.py` are mostly this, plus Rust scoring across the punctuation (Rust says the input "should be a single run of letters"). Suggest the same segmentation in both APIs.

**P2-7 `İ` not refolded.** Rust maps U+0130 → `i` and realigns offsets (`case_folding.rs`). Pion treats it as an opaque byte pair. `allopİhyle`: Pion `[2]`, Rust `[2,5,7]`; all 192 `non_ascii` diffs.

**P2-8 README claims.**
* "Zero-allocation hot path": `FixedArray::make(wn * 2 + 1, 0)` on every segment (`src/hyphenation.pion:580`).
* "14 hyph-utf8 exceptions": see P1-1.
* The query scratch grows with the input and nothing bounds it: 141–157 MB RSS for one 8 MB word, Rust 17.5–27.6 MB.

---

## Controls (attacks survived; must keep passing)

| ID | Result |
|---|---|
| C-1 engine parity | Crate tables, exceptions lowercased for Rust (TeX semantics): **100.000%** on `dict_lower` 239,642, `dict_as_is` 25,203, `dict_capitalized` 79,872, `dict_upper` 79,881, `dict_mixed` 47,928, `exceptions` 4,362, `short_0_5` 17,027 (incl. empty and 1-char), `long_compound` 20,300 (up to 40 words). Pattern merge (max per position), byte-indexed loci, `left_min`/`right_min` boundaries and exception filtering all match the oracle. |
| C-2 capitalised exceptions | hyph-en-us has 175 capitalised exceptions (`Ar-kan-sas`, `ATP-ase`, `Alex-an-der`…). Rust stores keys verbatim and lowercases the query, so it **never** matches them. That explains all 556 `engine` diffs in the letter-only classes (438 in `exceptions`, the rest dictionary words such as `arkansas`, `boston`, `cohen`). Pion matches case-insensitively like TeX's `\hyphenation`. Pion is right here. |
| C-3 TeX pattern syntax | ASCII uppercase in patterns is folded (TeX `\lccode`), consecutive digits / interior `.` / letterless patterns are rejected (TeX "Bad \patterns"), value `9` works, and malformed exceptions (`-ab`, `a--b`, `ab-`) are rejected. |
| C-4 minima | `0`/negative give `InvalidMinima`. `INT_MAX` (and `1 + INT_MAX`, which wraps negative) give no breaks and no panic. Minima longer than the word give no breaks. TeX clamps `\lefthyphenmin ≤ 0` to 1, which is an API choice, not a bug. |
| C-5 Limits | 0/negative limits return `Err`. `max_patterns`, `max_trie_nodes` (root counted) and `max_pattern_len` are exact at the boundary. No bypass with the defaults except P2-1. |
| C-6 UTF-8 safety | Invariants over 568,196 records (all 15 classes): `split_word` round-trip, `hyphenate` = parts joined, ascending offsets, every offset on a char boundary: **0 violations**. All 80 hyph-utf8 tables (incl. ZWJ/ZWNJ, combining marks, 4-byte scalars) load and query without panic. |
| C-7 `hyphenate_text` round-trip | 0 / 16,000 failures (seps `-`, U+00AD, `==`, `<shy>`). Empty `sep` is the identity. Tabs, CR/LF, runs of punctuation and empty text are preserved. |
| C-8 query DoS | Linear in word length (growth 1.1–1.9 for 8 M → 16 M byte single words: `a…a`, random letters, `é…é`). Faster than Rust except `é…é` at 8 M (0.19 vs 0.15 s); memory see P2-8. |
| C-9 4 modes | `wasm4.py`: 14 query corpora (103,560-record English sample, en_us and crate tables; 8 scripts: de, ru, el, hu, th, hi, ka, fr; `hyphenate_text` with 3 seps) and 5 adversarial `load` sets. Native debug/release and Wasm32 debug/release are **byte-identical**. The P1-4 crash panics identically in all 4. |

Oracle quirks found along the way (not Pion bugs): Rust's `build.rs` parses `.hyp.txt` one entry per *line*, so `Ying-yong Shu-xue Ji-suan` becomes one key with spaces, and the embedded map holds 1,439 keys rather than 1,441. The 175 capitalised exceptions are dead in Rust (C-2).

---

## Benchmark fairness (`bench/`)

`bench_fair.py` runs `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, interleaved, stdout SHA-256 must match). Both sides use the same crate tables (4,938 + 1,441).

Run on the shared Darwin arm64 Mac at load average 25–35 (other sessions running). The order is strictly interleaved, so ratios are comparable, but absolute times are not README-grade; compare min and median.

| corpus | `pion_into` (bench/) | `pion_alloc` | `rust_hyph` (bench/) | `rust_opp` | Pion lead, median / min |
|---|---|---|---|---|---|
| bench100k, 100,000 draws × 10 | 151.4 ms (min 144.1) | 154.3 (145.5) | 533.3 (474.8) | 531.0 (493.2) | **3.52× / 3.30×** |
| dict, 235,915 distinct × 10 | 500.6 (473.6) | 518.7 (502.4) | 1849.6 (1242.8) | 1402.2 (1295.7) | **3.69× / 2.62×** |

| load × 20 (hyph-en-us 4,938 + 1,441) | median ms | per load |
|---|---|---|
| `pion_from_tex` (parse + DAT build) | 60.5 | 3.02 ms |
| `rust_from_text` (`Parse::pair` + `fst` build from the same text) | 44.8 | 2.24 ms |
| `rust_bincode` (bench/'s baseline, `from_embedded`) | 13.4 | 0.67 ms |

All SHA-256 checks match. For the dict corpus, 61 words that hit a capitalised exception are dropped: those differ by design (C-2), and the first attempt with them failed the SHA check as it should.

Assessment:

* **Same tables, same outputs**: yes. Pion is fed the crate's `.pat`/`.hyp` files and the SHA-256 matches. There is no caching between iterations on either side, and Pion's per-process `from_tex` (≈3 ms) is inside its timing.
* **Not the same work per call.** `rust_hyph` (`Standard::hyphenate`) scans for U+00AD, checks `is_uppercase` per char, Unicode-lowercases capitalised words into a new `String`, concatenates `".word."` and allocates `values` and the `Word` result `Vec`. It also looks exceptions up in a SipHash `HashMap` and walks an `fst` byte-by-byte. Pion folds only ASCII, skips the soft-hyphen and Unicode work (P1-2, P2-5), and reuses the output buffer. The variants show this overhead is **not** where the lead comes from. `rust_opp` (lowercased once outside the loop, then `opportunities`) is no faster than `hyphenate` on bench100k and 1.3× faster on dict. `pion_alloc` (fresh `Array` per call) costs Pion only 2–4%. So the lead is real: the DAT walk beats `fst` prefix iteration with per-start `PrefixTallies`. Pion does skip the Unicode case work it should be doing (P1-2), which a fix will add back on non-ASCII words only.
* **Corpus**: the bench corpus is 100,000 draws from a 214-word vocabulary, so everything stays hot in cache and there is no diversity. On the `dict` corpus (235,915 distinct words) the lead by min drops from 3.3× to 2.6×; that is the honest number. It should replace or join the bench corpus in the README and `BENCHMARKS.md`.
* **Load (bench 2)** compares Pion *parsing + building* from text with Rust *deserialising* a pre-built bincode. The README discloses this, but it is not the same work. Against Rust building from the same text (`rust_from_text`), Pion is **0.74×** (3.0 vs 2.2 ms), so the 0.20× in the README is mostly bincode vs text. Improvement space for `from_tex`:
  1. pre-build the `en_us` DAT at compile time (embed `FixedArray` literals, or a byte blob plus a `from_bytes`), so load drops to a copy;
  2. add `Dictionary::to_bytes`/`from_bytes` for custom tables;
  3. replace the sibling linked list in `RawTrie::step_or_insert` (O(alphabet) per step) with a sorted or direct child table;
  4. fix the `first_free` scan (P2-2);
  5. single pass instead of validate-then-insert.

---

## Raw evidence

`run_audit.sh` writes `diff.json`, `multilang.json`, `text.json`, `dos.json`, `wasm4.json`, `bench_*.json/md` and `redteam.json` to `$AUDIT_TMP`.
