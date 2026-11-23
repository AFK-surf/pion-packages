# `fts` — Pure Pion Multilingual & Code-Aware Full-Text Search (BM25 / SQLite FTS5 Parity)

Zero-dependency, `World`-free full-text search engine for **Native** and **Wasm32**: multilingual + code-aware tokenizer, in-memory Okapi BM25 inverted index with exact SQLite FTS5 ranking parity, structured tag filtering, and UTF-8-safe snippet extraction with highlight byte spans.

## API

### Tokenizer (`src/tokenizer.pion`)

- `tokenize(text : String) -> Array[String]`
  - **CJK** (Han, Hiragana, Katakana, Hangul): adjacent bigrams plus `u_<char>` unigrams for single-character search.
  - **Unicode case folding**: ASCII, Latin-1 Supplement, Latin Extended-A, Greek, and Cyrillic, folded exactly as SQLite FTS5 `unicode61` does with its default `remove_diacritics 1` (`Café` → `cafe`, `Ÿ` → `y`, `ς` → `σ`). Kana voicing marks, `゠` and `・` are separators.
  - **Code identifiers**: whole lowercased identifier plus `CamelCase` (`GroupSurface` → `group`, `surface`; `HTTPServer` → `http`, `server`) and `snake_case` (`nc_follow` → `nc`, `follow`) parts; all-underscore words are skipped.
  - **References & hashes**: `#1234` → `pr1234`, `1234`; lowercase hex SHAs (length ≥ 7 with at least one digit) emit 6/7/8/10-char prefix tokens.
- `tokenize_query(query : String) -> Array[QueryTerm]`
  - Parses exact terms (`QueryTerm::Exact`), prefix terms `foo*` (`QueryTerm::Prefix`), quoted phrases `"foo bar"` (`QueryTerm::Phrase`), and `NOT` exclusions (`QueryTerm::Not`).
- `fts5_index_text(text : String) -> String`
  - Emits a space-separated normalized token string ready for SQLite FTS5 (`tokenize="unicode61 tokenchars '_'"`), guaranteeing 100% same-source tokenization between in-memory search and SQLite FTS5.
- `fts5_match_expr(query : String) -> String`
  - Formats a query as an SQLite FTS5 `MATCH` expression.

### Inverted Index (`src/index.pion`)

- `Index::new() -> Index` — Okapi BM25 with SQLite FTS5 defaults (`k1 = 1.2`, `b = 0.75`).
- `Index::with_bm25(k1 : Double, b : Double) -> Index` — custom BM25 parameters, clamped to `k1 ∈ [0, 100]`, `b ∈ [0, 1]` (`NaN` falls back to `1.2` / `0.75`; `bm25_score` applies the same clamp).
- `Index::upsert(self, doc_id : Int64, text : String, order_key~ : Int64 = 0L, tags~ : Array[(String, String)] = []) -> Unit`
- `Index::remove(self, doc_id : Int64) -> Bool`
- `Index::len(self) -> Int`
- `Index::search(self, query : String, limit~ : Int = 50, filters~ : Array[(String, String)] = []) -> Array[Hit]`
  - Returns `Hit { doc_id, score, order_key }` sorted by `score` descending (positive Okapi BM25 equal to `-fts5_bm25()`), then `order_key` descending, then `doc_id` ascending.
- `bm25_score(tf, df, doc_len, doc_count, total_tokens, k1~, b~) -> Double`

### Snippet & Highlights (`src/snippet.pion`)

- `snippet(text : String, query : String, max_chars~ : Int = 120) -> Snippet`
  - Returns `Snippet { text, highlights }` where `text` is truncated to at most `max_chars` Unicode codepoints (never splitting multi-byte UTF-8 characters) with `…` markers when trimmed, and `highlights` are sorted, non-overlapping UTF-8 byte ranges `(start, end)` aligned to codepoint boundaries so `sn.text.slice(start, end)` is always valid UTF-8.

```pion
import "fts"

let idx = fts::Index::new()
idx.upsert(1L, "Hello 中文全文检索 GroupSurface #1234", order_key=100L, tags=[("lang", "zh")])
let hits = idx.search("全文检索 surface", limit=10, filters=[("lang", "zh")])
let sn = fts::snippet("Hello 中文全文检索 GroupSurface #1234", "全文检索", max_chars=40)
```

## Verification

```sh
sh scripts/verify.sh packages/fts
```

### Native + Wasm32 (debug and release)

`wasm_smoke` exercises tokenization, FTS5 expression formatting, indexing, removal, BM25 ranking, tag filtering, and UTF-8 snippet extraction. All four builds produce byte-identical stdout:

```sh
W=/tmp/fts-smoke; mkdir -p "$W"; RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
pionc build -o "$W/native_debug" packages/fts/wasm_smoke
pionc build --release -o "$W/native_release" packages/fts/wasm_smoke
pionc build --target wasm32 -o "$W/debug.wasm" packages/fts/wasm_smoke
pionc build --release --target wasm32 -o "$W/release.wasm" packages/fts/wasm_smoke
"$W/native_debug" > "$W/nd.out"
"$W/native_release" > "$W/nr.out"
node "$RT" "$W/debug.wasm" > "$W/wd.out"
node "$RT" "$W/release.wasm" > "$W/wr.out"
shasum -a 256 "$W"/*.out
# 0beee5ef3a5922100e7b544d93fc8840af67fb8db1f32ccfb9bb226458623b40
```

## Head-to-Head Benchmark

`sh packages/fts/bench/run_bench.sh 10000` compares Pion Native (`--release`) against SQLite FTS5 in C (`-O3 -lsqlite3`, `:memory:`) and Python `sqlite3` (`:memory:`) on a deterministic 10,000-document multilingual + code corpus (English, Chinese, Japanese, Korean, CamelCase, snake_case, `#PR`, hex SHAs) across 30 diverse queries (exact, CJK, code, phrases, prefixes, `NOT`). Pion tokenizes raw text on the fly during indexing while SQLite FTS5 ingests the same-source `fts5_index_text` tokens; all three produce byte-identical query results verified by `scripts/bench_compare.py` (`--warmup 1 --rounds 5`).

### Index 10,000 docs + 30 queries (620,254 B raw, `sha256:1d044d63afdb2ecb...`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `sqlite_fts5_c`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 45.518 | 43.582 | 46.837 | 13.63 | 25.41 MiB | 0.71x |
| `sqlite_fts5_c` | 32.386 | 31.103 | 33.194 | 19.15 | 6.53 MiB | 1.00x (baseline) |
| `sqlite_fts5_py` | 61.211 | 60.792 | 62.303 | 10.13 | 16.44 MiB | 0.53x |

### Index 10,000 docs + 600 queries (30 queries × 20 reps, `sha256:742eb42a94d684ec...`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `sqlite_fts5_c`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 226.551 | 217.275 | 265.433 | 377585.42 | 25.41 MiB | 0.87x |
| `sqlite_fts5_c` | 196.257 | 192.415 | 204.213 | 327095.42 | 6.58 MiB | 1.00x (baseline) |
| `sqlite_fts5_py` | 223.737 | 222.254 | 226.689 | 372895.07 | 16.58 MiB | 0.88x |
