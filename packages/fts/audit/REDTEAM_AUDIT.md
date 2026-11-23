# Red-team audit: `packages/fts` @ `88bf6e4` (`feat/pkg-fts`)

Scope: every line of `src/{utf8,tokenizer,index,snippet}.pion`, the existing tests, the 4-mode `wasm_smoke` entry
and the SQLite FTS5 benchmark contract (`fts5_index_text` + `fts5_match_expr` fed to
`fts5(body, tokenize="unicode61 tokenchars '_'")`).

## Result

| ID | Severity | Area | Status |
| --- | --- | --- | --- |
| RT-1 | **P1** | Tokenizer fold differs from FTS5 `unicode61` (diacritics, `Ÿ`, `ſ`, `İ`, `ς`): in-memory index and SQLite return different documents | **Fixed** |
| RT-2 | **P1** | Kana voicing marks, `゠`, `・` treated as CJK letters: `u_・` tokens become `u_` in SQLite, bigrams lose a character | **Fixed** |
| RT-3 | P2 | `snippet`: `win_start + max_chars` overflows `Int` for huge `max_chars`, returning `……` with no text or highlight | **Fixed** |
| RT-4 | P2 | `snippet`: CJK phrases never highlighted (needle was `全文 文检 检索`); literal `pr12` / `PR2x` only half highlighted | **Fixed** |
| RT-5 | P2 | `bm25_score` did not sanitize `k1` / `b`: `Inf` gives `NaN` scores; `with_bm25(150, …)` silently reset `k1` to `1.2` | **Fixed** |
| RT-6 | P2 | Phrase search re-tokenized every candidate document once per phrase (64 phrases → 64 × corpus tokenization) | **Fixed** |
| RT-7 | P3 | Phrase positions over colocated tokens (CJK bigrams + `u_` unigrams, CamelCase whole + parts) | Documented (parity holds) |
| RT-8 | P3 | Semantics kept by design: hash query truncation, prefix vocabulary scan, `NOT`-only + filters | Documented |

No P0 was found. `fts5_match_expr` never produced an expression SQLite rejected, and no input made any public
function panic, before or after the fixes.

## Method

`audit/difftest.py` drives `audit/diff` (a Pion harness, hex-encoded I/O so malformed UTF-8 survives) against
Python `sqlite3` (SQLite 3.54.0) on random corpora built from 174 adversarial fragments (FTS5 operators, `col:`
filters, `"`, `*`, `^`, `NEAR`, `\0`, control bytes, overlong / surrogate / > U+10FFFF / truncated UTF-8, every
Latin-1 + Latin Extended-A special case, Greek, Cyrillic, kana marks, unassigned CJK, emoji). For every corpus it
checks:

1. **Token parity**: each `fts5_index_text` token is exactly one FTS5 token, unchanged (`fts5vocab` `instance`).
2. **Query safety**: each `fts5_match_expr` is accepted by `MATCH ?`.
3. **Result parity**: `Index::search` returns the same ids, order and BM25 scores (±1e-12) as
   `ORDER BY bm25(docs), rowid`.
4. **Snippet safety**: valid UTF-8, at most `max_chars` codepoints of body, sorted disjoint non-empty highlights on
   character boundaries, including `max_chars` of `0`, `-1` and `2147483647`.

```sh
pionc build --release -o /tmp/fts_audit_diff packages/fts/audit/diff
python3 packages/fts/audit/difftest.py /tmp/fts_audit_diff /tmp 1 60
```

| Seed (60 rounds, 3,797 queries, 2,400 snippets) | Token mismatches | Expr errors | Result mismatches | Snippet failures |
| --- | ---: | ---: | ---: | ---: |
| 1 / 2 / 3 / 9, baseline `88bf6e4` | 563 / 617 / 575 / 636 docs | 0 | 122 / 132 / 110 / 128 | 0 / 0 / 0 / 43 |
| 1–9, after fixes | 0 | 0 | 0 | 0 |

Between 626 and 783 queries per seed return at least one hit, so the parity check is not vacuous.

## Findings

### RT-1 (P1): fold differs from FTS5 `unicode61`

The package promises "100% same-source tokenization" with `tokenize="unicode61 tokenchars '_'"`, whose default is
`remove_diacritics 1`. `fold_unicode_letter` only lowercased, and its Latin Extended-A rule was wrong in places
(`İ` → `ı`, `Ÿ` and `ſ` unchanged). SQLite then folded the emitted tokens a second time:

| Pion token | FTS5 token |
| --- | --- |
| `café`, `naïve` | `cafe`, `naive` |
| `ÿ` / `Ÿ`, `ſ`, `ı` (from `İ`) | `y`, `s`, `i` |
| `ς` | `σ` |

So `café` and `cafe` were one term in SQLite and two in memory. Repro (baseline): `search("cafe")` on
`["Café au lait", "cafe racer"]` returns only doc 2 while FTS5 returns both, and BM25 scores differ whenever such
terms share a document.

**Fix**: `latin_fold_table` holds the `unicode61` fold of U+00C0..U+017F, generated from SQLite itself
(lowercase + single diacritic removal); Greek adds `ς` → `σ`; Greek and Cyrillic otherwise already matched (all 352
letters were checked, and each output is a fixed point of FTS5). Snippet highlighting uses the same fold, so
`cafe` highlights `Café`. `tokenizer_test.pion` expected `café` / `über` / `ñoño`; it now expects `cafe` / `uber` /
`nono`, which is what SQLite stores.

### RT-2 (P1): kana marks and punctuation inside CJK runs

`is_cjk_cp` covered whole blocks. Of the 105,280 code points in those ranges, exactly six are not FTS5 token
characters (checked one by one against SQLite): U+3099..U+309C (voicing marks, Mn/Sk), U+30A0 (`゠`) and U+30FB
(`・`). `ア・イ` produced `ア・`, `・イ`, `u_・`, which FTS5 stores as `ア`, `イ`, `u_`; a query for `・`
matched every document containing any such mark. They are now separators.

### RT-3 (P2): `snippet` overflow

`win_start + max_chars < total_cps` wraps for `max_chars` near `Int` max when the match is past the first 16
characters: the window became empty and the snippet was `……` with no highlight. The comparison is now
`max_chars < total_cps - win_start`.

### RT-4 (P2): highlight needles

- A phrase needle was its tokens joined by spaces, so `"全文检索"` searched for `全文 文检 检索` and never
  highlighted. `phrase_display` chains overlapping CJK bigrams back (`全文检索`) and joins adjacent CJK parts
  without a space.
- A token `prN…` was always treated as a `#N` reference, so the literal words `pr12` / `PR2x` highlighted only
  `12` / `2x`. The literal token is now a needle too.

### RT-5 (P2): BM25 parameters

`bm25_score(…, k1=Inf)` returned `NaN` (`Inf / Inf`), `b = ±Inf` likewise. `with_bm25` reset any `k1 > 100`
(including `+Inf`) to `1.2` instead of clamping. Both now share `sanitize_k1` / `sanitize_b`: clamp to
`[0, 100]` / `[0, 1]`, `NaN` → `1.2` / `0.75`; a negative `doc_len` counts as 0.

### RT-6 (P2): phrase re-tokenization

Each phrase re-tokenized every candidate document. With several phrases, a per-search cache now tokenizes each
candidate once (single-phrase queries skip the cache, so memory is unchanged). 5,000 documents, query of 64
`"quick brown"` phrases, end to end including indexing: 0.61–0.75 s → 0.07–0.25 s.

### RT-7 (P3): phrases over colocated tokens

`fts5_index_text` must be one position stream, so tokens that describe the same text get consecutive positions:
`中文` → `中文 u_中 u_文`, `FooBar` → `foobar foo bar`. Consequences, identical in Pion and SQLite:

- `"中文 中"` matches a document containing only `中文`; `"foobar foo"` matches `FooBar baz`.
- `"FooBar baz"` does not match `FooBar baz` (`foo bar` sit between); space-separated CJK words in a phrase
  never match.

Contiguous CJK phrases (`"全文检索"`) and plain-word phrases work. Fixing this needs colocated tokens, which a
space-joined FTS5 column cannot express; left as a documented limitation.

### RT-8 (P3): kept by design

- A 9-char or 11–39-char hex query is truncated to the nearest indexed prefix tier (8 / 10), so `deadbeef1`
  also matches a document whose only token is `deadbeef`.
- Each prefix term scans the whole vocabulary (`O(V)`), capped at 64 terms per query.
- A query with no positive term returns `[]`, except with filters, where it lists the filtered documents minus the
  `NOT` terms (`fts5_match_expr` returns `""` there; callers must not send that to `MATCH`). Filters never let an
  unfiltered document through.
- `NOT foo-bar` excludes `foo` and `bar` separately, on both sides.

## Attack surface that held (`redteam_test.pion`)

- **FTS5 injection**: 60+ attack queries and 7 malformed-UTF-8 queries (`"`, `""`, `'`, `(`, `)`, `*`, `**`, `^`, `NEAR(a b)`, `AND` / `OR` /
  `NOT NOT NOT`, `col:foo`, `{body}:foo`, `\0`, control bytes, `\`, full-width space, emoji prefix, 40-char hash) all yield the only grammar the function may emit: quoted tokens (`""` escaped), optional `*`,
  joined by ` AND ` / ` NOT `. Operators become plain quoted words, `:` never leaves a string.
- **Index churn**: 600 random upserts (new text, new tags, empty text) and removes (including unknown ids) leave
  an index identical to a fresh rebuild: same `len`, `total_tokens`, vocabulary size, ids, order and scores for 15
  queries with and without filters. Removing everything leaves zero postings and safe queries.
- **Replacement**: re-upserting a document drops its old terms and tags; replacing with empty text keeps the
  document with zero tokens.
- **Filters**: multi-valued tags, AND of filters, empty key/value, case-sensitive and untrimmed comparison, no
  match → no hit.
- **Limits and blowup**: `limit` of `±2147483647`; a 2,000-chunk query of 1,000 phrases and 1,000 prefixes is
  capped at 64 terms and returns a well-formed expression; single-letter prefix over the whole vocabulary.
- **Phrases**: order respected, repeated-word phrases, phrase longer than the run, CJK-then-ASCII adjacency.
- **UTF-8**: 300 random mixes of overlong, surrogate, > U+10FFFF, truncated and stray bytes with emoji / CJK /
  Latin give valid UTF-8 tokens, index text and snippets (`max_chars` 1–30) with valid highlights.
- **BM25**: `NaN`, `±Inf`, huge, negative and zero `k1` / `b`, negative `tf` / `df` / `doc_len`, `df > rows`:
  always finite and non-negative.

`redteam_test.pion`: 11 tests. On the baseline, `rt1`..`rt5` fail and the other 6 pass.

## Cross-target and benchmark

- `wasm_smoke` gained RT-1..RT-5 lines; native debug / release and wasm32 debug / release (`node`) print
  byte-identical stdout (40 lines, `sha256:1ebc76fd113f1090…`).
- `sh packages/fts/bench/run_bench.sh 10000`: stdout SHA-256 is unchanged from the baseline and identical across
  Pion, SQLite C and SQLite Python (`1d044d63afdb2ecb…` mode 1, `742eb42a94d684ec…` mode 2). The bench corpus
  has no characters affected by RT-1 / RT-2. Baseline and fixed Pion binaries interleaved on the same machine
  (9 rounds): mode 1 55.0 → 54.0 ms, mode 2 293.2 → 291.4 ms, peak RSS 25.41 MiB for both; no regression.
