# `packages/flate` red-team audit

Target: `origin/feat/pkg-flate` @ `ad6f6b9` (pure Pion RFC 1951 / 1950 / 1952, CRC-32, Adler-32).
References: Rust `flate2 1.1.11` with the `rust_backend` (`miniz_oxide`), Go `go1.27.3` `compress/{flate,zlib,gzip}`, and CPython `zlib`.
Machine: Darwin arm64 (tokyo-mac-studio-0). Every result below can be reproduced with `sh packages/flate/audit/run_audit.sh all`. All artifacts are written to `$AUDIT_OUT`, which defaults to `/private/tmp/pion-flate-audit`. That is the real path of `/tmp`, so wasm32 runs see the same paths as native runs.

## Verdict

| Severity | Count | Summary |
| --- | ---: | --- |
| **P0** (memory safety / crash / wrong output / unbounded resource) | **0** | No P0 in 224 k fuzz cases, 81 RFC edge vectors or 100 compressor interop runs. |
| **P1** (silent data loss, missing capability, large gaps) | 3 | The gzip encoder accepts a NUL in `FNAME` and emits a stream nobody can decode. There is no streaming API (memory is O(output), output tops out at 2 GiB, and the default 256 MiB cap is mandatory). Throughput is 0.13–0.69× `miniz_oxide`, with the worst gaps on incompressible data and CRC. |
| **P2** (spec nits, interop, perf corner cases, bench fairness) | 7 | See below. |

The decoder is as strict as zlib/Go on every edge vector, and stricter than `miniz_oxide`: miniz accepts back-references that point before the start of the output.
Native and wasm32 gave byte-identical results on every input.

---

## P1

### P1-1 `gzip_compress_with_header` silently produces an undecodable stream when FNAME/FCOMMENT contains NUL
* Test: `audit_test.pion::redteam_gzip_name_with_nul_must_not_corrupt_stream` (currently **FAIL**).
* Repro: `gzip_compress_with_header("payload", 6, name = "a\u{0}b")` returns `Ok(gz)`. `gzip_decompress(gz)` then fails with `InvalidDistance`. The NUL ends `FNAME` early, so the bytes `b\0` are parsed as DEFLATE data.
* Reference: Go `gzip.Writer` rejects such a header (`gzip.Write: non-Latin-1 header string` / NUL check). The Pion API returns `Ok` and the data is lost.
* Fix: in `src/gzip.pion` (`gzip_compress_with_header`), return `Err(InvalidHeader)` when `name` or `comment` contains `\u{0}`.

### P1-2 No streaming / incremental API; memory is O(output); the default limit is the only bomb guard
* Every entry point is `Bytes -> Bytes`. Go `io.Reader` and flate2 `Read`/`Write` decode in constant memory with a 32 KiB window. Pion must hold the whole input plus the whole output plus one growth copy.
* Measured (`run_audit.sh dos`): with the default limit, a 1 MiB input (`bomb_1GiB.deflate`, 1:1024) forces **391 MiB RSS** before `OutputLimitExceeded`. The interception itself is correct. Growth stops exactly at `max_output_bytes`; `control_output_limit_is_exact` and `control_gzip_multimember_cumulative_limit` pass. But the peak is about 1.5× the limit because of the doubling copy plus the final `slice`. With `*_with_limit(1 MiB)`, RSS is 5 MiB.
* Output is capped below 2 GiB (`Int` lengths). The default 256 MiB cap makes `gzip_decompress` reject legitimate large `.gz` files, and the only way out is to call `*_with_limit`. The README's "Zip Bomb protection" is really "bounded but large allocation".
* Recommendation:
  * Add `Inflater` / `Deflater` state machines (feed input chunk, drain output chunk, 32 KiB ring). Most of the hot loop already keeps its state in locals and can move into a struct.
  * Until then, document that the default limit lets any caller allocate about 400 MiB.

### P1-3 Throughput gaps vs `miniz_oxide` / Go across real corpora
Measured with `scripts/bench_compare.py` (warmup 1, 5 interleaved rounds, stdout SHA-256 identical across all three implementations). Full logs are in `$AUDIT_OUT/bench_*.md`; the matrix comes from `summarize_bench.py`.

| corpus | op | pion MB/s | miniz_oxide MB/s | go MB/s | pion vs miniz | pion vs go |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| entropy (4 MiB random) | gzip decompress | 530.6 | 2097.6 | 1797.1 | **0.25x** | 0.30x |
| entropy | compress L1 | 37.0 | 281.6 | 1599.1 | **0.13x** | **0.02x** |
| entropy | compress L6 | 33.7 | 63.5 | 1437.2 | 0.53x | **0.02x** |
| entropy | compress L9 | 34.1 | 62.3 | 174.6 | 0.55x | 0.20x |
| html (Go spec) | gzip decompress | 260.5 | 383.2 | 285.2 | 0.68x | 0.91x |
| html | compress L1 / L6 / L9 | 83.4 / 30.2 / 17.7 | 212.9 / 45.6 / 36.9 | 214.7 / 124.8 / 29.7 | 0.39 / 0.66 / 0.48x | 0.39 / 0.24 / 0.60x |
| json (varied records) | gzip decompress | 268.3 | 416.0 | 274.6 | 0.64x | 0.98x |
| json | compress L1 / L6 / L9 | 88.9 / 35.2 / 10.3 | 264.4 / 51.1 / 24.6 | 253.7 / 139.6 / 26.6 | 0.34 / 0.69 / 0.42x | 0.35 / 0.25 / 0.39x |
| source (Go stdlib) | gzip decompress | 268.4 | 402.1 | 297.1 | 0.67x | 0.90x |
| source | compress L1 / L6 / L9 | 84.5 / 26.7 / 19.0 | 219.4 / 45.5 / 40.3 | 215.6 / 127.4 / 38.2 | 0.39 / 0.59 / 0.47x | 0.39 / 0.21 / 0.50x |
| text (web2 words) | gzip decompress | 191.5 | 291.5 | 210.0 | 0.66x | 0.91x |
| text | compress L1 / L6 / L9 | 70.5 / 20.9 / 6.4 | 197.0 / 33.2 / 16.4 | 164.6 / 111.8 / 15.6 | 0.36 / 0.63 / 0.39x | 0.43 / 0.19 / 0.41x |
| big16 (16 MiB mix) | gzip decompress | 232.5 | 391.2 | 279.4 | 0.59x | 0.83x |
| big16 | compress L1 / L6 / L9 | 64.0 / 23.1 / 11.4 | 178.9 / 40.0 / 21.0 | 162.0 / 106.8 / 22.3 | 0.36 / 0.58 / 0.54x | 0.40 / 0.22 / 0.51x |
| all corpora | CRC-32 + Adler-32 | 702–826 | 1556–2458 | 1096–1563 | **0.33–0.45x** | 0.53–0.64x |

Compression ratio is not the problem. Pion is within ±3 % of miniz at L6/L9 and 2–18 % *smaller* at L1 (table in `$AUDIT_OUT/bench_summary.md`). One small anomaly: on `text`, L9 (759,907 B) is larger than L6 (759,374 B).

Where the time goes (code reading + the corpus shapes above):
1. **Incompressible data has no fast path.** Entropy L1 runs at 0.13× miniz and 0.02× Go. `deflate_compress` runs full LZ77 and builds three Huffman candidates per 32 768-token block, only to pick Stored. Go's L1–L6 detect incompressible input and skip it. Fix: if the first block chose Stored, or literals are more than about 98 % of tokens with a near-flat histogram, switch to stored emission / skip matching for that block (a cheap entropy probe).
2. **Bulk byte copies are byte loops.** Entropy decompress (mostly stored blocks) runs at 0.25×. Stored payloads, `grow_bytes`, `bw_write_raw`, the gzip member concat and the final `out.slice` all copy one bounds-checked byte at a time. Use a runtime bulk-copy primitive (`Bytes` blit/memcpy) if Pion exposes one or can add it. This is the single biggest decompress win on low-ratio data.
3. **CRC-32 is 0.33–0.45× and is paid on every gzip decode.** It is slice-by-8 with eight separate byte loads per step. Options: (a) a slice-by-16 table, (b) a 64-bit little-endian load primitive (`Bytes::get_u64_le`) so the loop does one load instead of 8 checked indexes, (c) fuse CRC into the stored-copy loop. Adler-32 can move to 16-byte unrolling with deferred `s2 += 16*s1`.
4. **Inflate literal path.** Every literal pays two compares (`out_len >= max_output_bytes`, `out_len >= out.length()`) plus `grow_bytes` checks. Precompute `safe_end = min(out.length(), max_output_bytes)` and decode 2–3 literals per 56-bit refill, as `inflate_fast` does. Pack `len_base`/`len_extra` and `dist_base`/`dist_extra` into the LUT entries (miniz/libdeflate style) to remove two table loads per match. Consider an 11-bit litlen root (libdeflate) to make subtable hits rare on text.
5. **Compressor L6 is 0.2× Go.** `lz77_find_match` compares one byte at a time after the 4-byte unroll and returns a tuple per call. Lazy matching re-searches `pos+1` with `max_chain >> 1` and then searches again on the next iteration. Add zlib's `good_length` / `max_lazy` tables so the lazy search is skipped once the match is good enough, and do 8-byte compares if a 64-bit load primitive becomes available.

---

## P2

| ID | Finding | Evidence | Fix |
| --- | --- | --- | --- |
| P2-1 | gzip `FNAME`/`FCOMMENT` are written as UTF-8, not ISO-8859-1 (RFC 1952 §2.3.1). Pion↔Pion round-trips only because `Bytes::to_string` decodes valid UTF-8 first. Go/Python/gzip(1) show `cafÃ©.txt`. | `redteam_gzip_name_is_iso8859_1_on_the_wire` (FAIL: wire bytes `195,169`); controls `control_gzip_*_non_ascii_self_roundtrip` pass | Encode code points ≤ 0xFF as single bytes |
| P2-2 | Names outside Latin-1 (`名字.txt`) are accepted silently; Go returns an error. | `redteam_gzip_name_non_latin1_rejected` (FAIL) | Return `Err(InvalidHeader)` |
| P2-3 | zlib `FDICT` with an empty preset dictionary (DICTID = `adler32("")` = 1) is rejected with "requires preset dictionary". zlib (`inflateSetDictionary(…,0)`) and Go (`NewReaderDict(r, []byte{})`) accept it. | `redteam_zlib_fdict_empty_dictionary_accepted` (FAIL) | Compare DICTID instead of testing `dict.length() == 0` |
| P2-4 | Every gzip member allocates a 64 KiB output buffer (`init_cap` is derived from the *remaining input of the whole stream*, not the member). 100 000 empty members (2 MB) take **0.49 s vs Go 0.01 s / miniz 0.15 s**. | `run_audit.sh dos` → `empty_members_100k.gz` | Size from member history, start small, or reuse one buffer across members |
| P2-5 | Level 9 on adversarial low-entropy input is linear but slow: `adv_ab_4M` takes 4.4 s vs miniz 1.06 s (Go 35.96 s). `adv_prefix3_4M` takes 1.61 s vs miniz 0.73 s / Go 0.18 s. No O(n²): `max_chain` ≤ 1024 bounds it. | `run_audit.sh dos` | `good_length`/`nice` early exit, as zlib does |
| P2-6 | Benchmark fairness in `packages/flate/bench`: (a) one synthetic 2 MiB corpus of 3 repeating templates (3.37 % ratio) mostly exercises long-match copies and hides the incompressible-data and CRC gaps (entropy 0.13–0.25×); (b) the compress benches print only `mode=… input_bytes=…`, so the mandatory SHA-256 check proves nothing about output correctness (checked once by Python in the setup step only); (c) the Pion decompress bench converts the output with `to_string()` before printing, a cost Rust/Go do not pay (it slightly *under*-states Pion). | `audit/gen_corpora.py`, `audit/src/main.pion` `bench` (prints len+CRC of a re-decode, so a broken encoder cannot win) | Adopt multi-shape corpora + output-verifying stdout |
| P2-7 | Error kinds can mislead: an unterminated `FNAME` that runs into the trailer is reported as `InvalidStoredLength` (vector `G07`). Trailing zero padding after the last gzip member is an error (same as Go/miniz, but gzip(1) and Python accept; vector `G19`). | `difftest.py vectors` | Optional: a `skip_trailing_zeros` option |

---

## What was attacked and held

### RFC edge / malformed vectors (`difftest.py vectors`, 81 vectors × 5 decoders)
Every hand-built vector met its RFC-derived expectation. Native matched wasm32 on every vector.

* **Huffman trees.** These all behave correctly:
  * a zero-code distance tree, and a single 1-bit distance code both unused and used;
  * an EOB-only litlen tree;
  * over-subscribed and incomplete trees rejected;
  * 15-bit litlen and 15-bit distance codes (the subtable path);
  * `HLIT` 287/288 and `HDIST` 31/32 rejected;
  * a missing EOB rejected;
  * repeat-16 and repeat-18 runs **crossing the HLIT|HDIST boundary** accepted, as §3.2.7 allows;
  * repeat-16 at index 0 and repeat runs past the end rejected;
  * incomplete or empty code-length trees rejected;
  * a distance symbol used with an empty tree rejected.

  The single incomplete length-2 distance code is rejected by Pion and by all references.
* **Blocks and window.**
  * Stored blocks: `LEN != ~NLEN` rejected, non-zero padding ignored, LEN=65535 handled.
  * `BTYPE=11` rejected; fixed symbols 286/287 and distance symbols 30/31 rejected.
  * Distance > history rejected; distance == history accepted.
  * Overlapping copies with `dist` = 1/2/3/7 × length 258 are correct.
  * `dist=32768` reaching back through stored → fixed → stored into a dynamic block is correct; 32768 with only 32767 bytes of history is rejected.
  * 5000 empty fixed blocks and 5000 empty stored blocks decode; a stream with no final block is rejected; trailing garbage after a raw stream is ignored, as in all references.
* **zlib.** `CM≠8`, `CINFO>7`, a bad FCHECK, FDICT without a dictionary, a bad or truncated Adler-32 and the minimal 8-byte stream all behave correctly. Trailing bytes are ignored, as in Go/Rust/Python.
* **gzip.**
  * Header checks: bad magic and `CM≠8` are rejected; reserved `FLG` bits 0x20/0x40/0x80 are **rejected**. Rust rejects them too; Go and Python accept them, so Pion is RFC-correct here.
  * Optional fields: FEXTRA (truncated and valid), unterminated FNAME, Latin-1 FNAME, FCOMMENT with control bytes, and FHCRC (correct and wrong) all behave correctly.
  * Trailer: CRC and ISIZE mismatches are rejected; ISIZE is taken mod 2³².
  * Multi-member input: concatenation, empty members in between, a bad or truncated second member, and the 20-byte minimal member all behave correctly.
* **Reference-decoder note.** `flate2`/`miniz_oxide` **accepts** back-references before the start of the output: vectors `W01`, `W02` and `W06` return OK(4), OK(3) and OK(32770). Go, CPython zlib and Pion reject them.

### Mutation fuzz (`difftest.py fuzz`)
* Seeds: 8 data shapes × {raw L0/L1/L6/L9, fixed-only, zlib, full-flag gzip, 2-member gzip}.
* Mutations: bit flips, truncation, byte set, splice and delete.

| run | cases | crashes / hangs | native ≠ wasm32 | Pion ≠ unanimous(Go, Rust, Python) |
| --- | ---: | ---: | ---: | ---: |
| seed 20261123 | 24 000 | 0 | 0 | 0 |
| seed 77 | 200 000 | 0 | 0 | 0 |

### Compressor interop (`difftest.py compress`)
* Levels 0–9 were run over these corpora: empty, 1 byte, 1 MiB zeros, 256 KiB random, 100 KiB long repeats, 96 KiB beyond-window, **Fibonacci-frequency literals** (Huffman depth > 15 that forces Package-Merge clamping), `abc`×1 MiB, a 2-letter alphabet and JSON.
* All **100/100** streams decode byte-identically with Pion, Go `compress/flate`, `miniz_oxide` and CPython zlib.
* Pion's sizes are ≤ zlib's except for small-alphabet L4–L9 (+1–3 %) and Fibonacci L3/L5–L9 (≤ +1 %).

### Zip bomb (`run_audit.sh dos`)
`bomb_1GiB.deflate` / `.gz` (1 MiB → 1 GiB):

| limit | result | time | RSS |
| --- | --- | ---: | ---: |
| 1 MiB | `OutputLimitExceeded` | 0.00 s | 5 MiB |
| default (256 MiB) | `OutputLimitExceeded` | 0.13 s | 391 MiB |

The default-limit case is where P1-2 applies. A flood of 50 000 dynamic blocks decodes in time comparable to Go and miniz.

---

## Files

| path | purpose |
| --- | --- |
| `audit/pion.toml`, `audit/src/main.pion` | Pion harness CLI (`batch`, `compress`, `file`, `cfile`, `gzfile`, `bench`); builds for native and wasm32 |
| `audit/audit_test.pion` | `redteam_*` tests (FAIL until fixed) and `control_*` regression tests (PASS) |
| `audit/diff/go`, `audit/diff/rust` | the same CLI protocol over Go `compress/*` and flate2 `rust_backend` |
| `audit/difftest.py` | vectors, fuzz and compress differential runner (5 decoders) |
| `audit/gen_corpora.py`, `audit/summarize_bench.py` | multi-shape benchmark corpora and the summary matrix |
| `audit/run_audit.sh` | one-shot runner: `all\|build\|unit\|vectors\|fuzz\|compress\|dos\|bench` (`FUZZ_N=200000` for the long run) |
