# `packages/brotli` red-team audit

Target: `origin/feat/pkg-brotli` @ `71bb340` (pure Pion RFC 7932 decoder, `v0.1.0`).
References: Google C `libbrotlidec`/`libbrotlienc` **1.2.1** (Homebrew; the oracle) and Rust `brotli-decompressor 4.0.3` (the decoder inside `brotli 7.0.0`; second opinion).
Machine: Apple M5 Max (Darwin arm64), `pionc 0.1.0`, node v24.22.2, cargo 1.100.0.
Reproduce everything with `sh packages/brotli/audit/run_audit.sh all` (about 3 min). Artifacts go to `$AUDIT_OUT`, which defaults to `/private/tmp/pion-brotli-audit`. Nothing is written inside the repository.

## Verdict

| Severity | Count | Summary |
| --- | ---: | --- |
| **P0** (memory unsafety, wrong output, accepting an invalid stream, unbounded resources) | **0** | Pion matched C `libbrotlidec` on all 226,218 inputs, both in verdict and in output bytes (length + FNV-1a 64). Native and wasm32 produced identical output on every input. Every bomb was stopped by `OutputLimitExceeded` before its large allocation. |
| **P1** (process abort reachable from input or config) | **2** | P1-1: a ≥ 512 MiB input overflows `Int` and aborts. P1-2: `max_output_bytes` > 2³¹−17 aborts (native) or traps (wasm32). |
| **P2** (CPU amplification, memory peak, API semantics, toolchain) | **4** | IMTF context map takes 15× C's CPU; wasm32 traps on big limits and peak memory is about 1.8× the limit; the `max_output_bytes = 0` semantics need a decision; `Bytes::new(<0>)` behaves differently on native and wasm. |

The decoder logic is correct. 2,190 RFC 7932 boundary vectors (covering all 121 transforms × all 13,504 dictionary words), 28 targeted malformed streams, and 224,000 mutated streams all give the same verdict and the same output bytes as C. That includes the strict checks for non-canonical `MLEN`/`MSKIPLEN`, incomplete or oversubscribed prefix codes, repeats running past the alphabet, an `insert`/`copy`/dictionary word running past `MLEN`, invalid dictionary references, non-zero padding and trailing bytes.

---

## Coverage (`run_audit.sh vectors|fuzz`, `difftest.py`)

| Family | Count | Content |
| --- | ---: | --- |
| Empty streams / headers | 33 | `0x06`, `0x3b`, empty streams for all of `WBITS = 10..24`, non-zero padding, large-window marker (`1,000,001`), truncated header, trailing `0x00` / garbage / a second stream |
| metadata | 18 | `MSKIPLEN` 0, 1, 255, 256, 65535, 65536, 65537, 1 MiB, 16 MiB; reserved bit = 1; non-canonical `MSKIPLEN`; non-zero padding; truncation; metadata as the last meta-block; 1000 empty metadata blocks in a row; interleaved metadata + uncompressed + compressed |
| uncompressed | 15 | `MLEN` = 1, 2, 16, 65535/65536/65537 (4/5-nibble boundary), 1 MiB/1 MiB+1 (5/6 nibbles), 4 MiB, 16 MiB (max); non-canonical 5/6-nibble `MLEN`; non-zero padding; truncation; 50 uncompressed blocks followed by a copy right at the w10 window edge |
| `NPOSTFIX × NDIRECT` | 64 | All 4 × 16 combinations, each with random LZ77, short codes 0..15 (ring buffer), implicit distance, direct codes, multiple block types |
| Block switching | 22 | `NBLTYPES` L/I/D each = 2, 3, 4, 17, 64, 255, 256; plus L=I=D=256 with `NTREESL`/`NTREESD`=256 |
| Context map | 48 + 12 | `NTREES` ∈ {2, 5, 16, 100, 255, 256} × `RLEMAX` ∈ {0, 1, 4, 16} × IMTF on/off; all 4 context modes (LSB6/MSB6/UTF8/Signed) × 64 trees |
| Prefix codes | 11 | HSKIP 0/2/3, RLE codes 16/17, single-symbol code-length code, forced complex codes, 15-bit deep codes (2-level LUT), all 256 literals at 15 bits |
| Window / ring buffer | 15 | `WBITS = 10..24`, each with output > 3× window (w24: 16 MiB + 4 KiB). Copies at d = max window, window−1 and 1, then one dictionary reference at d = window + 1 |
| **Static dictionary** | 121 + 12 | **121 transforms × all 13,504 words** (17.6 MB of output in total). This covers 5,023 two-byte and 4,345 three-byte UTF-8 characters, 2,553 words whose first character is multi-byte (`UppercaseFirst`), and 10 words whose 3-byte character crosses the word end (`UppercaseAll` boundary). Also w10 small-window dictionary references. |
| libbrotlienc | 1,805 | **q0..q11 × lgwin 10..24** × 10 corpora (text, html, json, utf8 CJK/emoji, random, zeros, ab, binary, 1 B, 3 B) + 5 runs of 1.6 MB mixed input (q0/1/5/9/11), multi-meta-block |
| Malformed | 28 | insert/copy/dictionary word over `MLEN`; dictionary copy_len 2/3/25/26/100; transform id 121/122/127; context map tree id out of range / RLE overrun; simple code with duplicate symbols (2/4) or symbol ≥ 704; complex code incomplete / oversubscribed; code-length code incomplete / oversubscribed / all zero; repeat past alphabet; distance before any output |
| Fuzz | 24,000 (default) + 200,000 (`--fuzz 200000 --seed 1`) | 1/5 are structured random streams from `brenc.py` (random WBITS, NBLTYPES, NTREES, NPOSTFIX/NDIRECT, deep codes, RLE); 4/5 are mutations (bit flip / header flip / byteset / truncate / insert / delete / splice / append / arith) |

Every vector in `brenc.py` carries its own expected output. **All 2,202 expectations matched C, Pion native and Pion wasm**, so the stream writer itself was checked by C as well.

**Pion vs C: 0 differences** (226,218 inputs). Pion `TrailingData` is counted as equal to "C succeeded with input left over", and `OutputLimitExceeded` as equal to the harness limit.
**Pion native vs wasm32: 0 differences.**

### Reference note: Rust `brotli-decompressor 4.0.3` differs from C (not a Pion issue)

Across the 224k fuzz inputs, Rust disagreed with C on 5,119 of them. In every one, Pion agrees with C:

| Rust behaviour | C error | Count (24k + 200k) |
| --- | --- | ---: |
| Accepts non-zero padding bits after the final `ISLAST` | `PADDING_2` | 295 + 2,593 |
| Accepts `insert`/`copy` that runs past `MLEN` (truncates silently) | `BLOCK_LENGTH_1/2` | 238 + 1,990 |
| Enables large-window streams by default (`BrotliState::new` sets `large_window = true`) | `WINDOW_BITS` | 0 + 3 |

For example, `malformed:bad_insert_exceeds_MLEN` (`run_audit.sh vectors`): Rust returns `OK 3`, while C and Pion reject it. Pion's strictness here is correct and is the same as C's.

---

## P1

### P1-1 An input ≥ 536,870,848 bytes aborts the process (32-bit `Int` overflow)
* Test: `redteam_test.pion::redteam_p1_input_over_512mib_does_not_abort` (currently **FAIL**: `pion panic ... negative bytes length`).
* Probe: `run_audit.sh dos` → `input_512MiB_meta.br` (a valid 528 MiB stream made of 33 metadata blocks of 16 MiB each). Pion native **CRASH**; C/Rust return `OK 0`.
* Root cause: `src/brotli.pion:932` computes `let mut init_cap = data.length() * 4 + 256`. When `data.length() ∈ [536,870,848, 1,073,741,759]` this wraps negative. The `> 1048576` clamp does not catch a negative value, so `OutBuf::new` → `Bytes::new(negative)` aborts. This happens right after WBITS is read and before any meta-block, so the default limits trigger it too.
* wasm32 does not crash: `Bytes::new(negative)` there returns an empty buffer. See P2-4.
* Fix: `let init_cap = if data.length() >= 262080 { 1048576 } else { data.length() * 4 + 256 }`, or compute in `Int64`.
* Repro: `sh run_audit.sh dos`, or `pionc test --json packages/brotli/audit`.

### P1-2 `max_output_bytes` above the runtime container maximum aborts (native) or traps (wasm32)
* Test: `redteam_test.pion::redteam_p1_int_max_output_limit_does_not_abort` (currently **FAIL**: `container length exceeds maximum`).
* Probe: `bomb_4GiB_hand.br` (3,265 B → 4 GiB) at `limit=2147483647`. Native aborts after 1.28 s at RSS 2.5 GiB. wasm32 fails with `RangeError: WebAssembly.Memory.grow(): Unable to grow instance memory`. C/Rust both return `LIMIT`.
* Root cause: `OutBuf::ensure_additional` (`src/brotli.pion:612-628`). Once output passes 1 GiB, `new_cap > max_bytes / 2` sets `new_cap = self.max_bytes`. The runtime's `PION_MAX_CONTAINER_LEN = 2^31 − 17 = 2,147,483,631` (`pion_rt.c`), so any `max_output_bytes ∈ [2,147,483,632, 2,147,483,647]` aborts while the buffer grows. Callers naturally pass `Int` max to mean "no limit".
  Measured thresholds: native 2,147,483,000 → correct `OutputLimitExceeded`; 2,147,483,640 → abort. wasm32: 1 GiB → correct, but RSS is 2.9 GB; **1.25 GiB (1,342,177,280) already traps**.
* Fix:
  1. In `decode_with_limits`, clamp `max_output_bytes` to `2147483631` (or return `OutputLimitExceeded`/`InvalidLimit`).
  2. Cap growth at `min(max_bytes, 2147483631)`.
  3. Document in the README that wasm32 can only use about 1 GiB as an output limit (a 4 GiB linear memory has to hold the old buffer, the new buffer and the final slice at once).

---

## P2

### P2-1 IMTF context map gives ~15× CPU amplification
* Probe: `maxtrees_flood.br`, 1 MiB = 841 meta-blocks. Each one has `NBLTYPESL/I/D=256` and `NTREESL=NTREESD=256`, and its context map is 17,408 entries at **0 bits each** (single-symbol code, index 255) with IMTF on.

  | Implementation | Time | Notes |
  | --- | ---: | --- |
  | Pion native | **2.52 s** | |
  | Pion wasm32 | **4.00 s** | |
  | C | 0.17 s | |
  | Rust | 0.52 s | |

  The same stream with IMTF off (`maxtrees_imtf0.br`): Pion 0.15 s vs C 0.06 s. **The gap is entirely in IMTF.**
* Root cause: `read_context_map` (`src/brotli.pion:777-797`). For every entry, `FixedArray[Int]` is shifted one element at a time by `idx` (≤ 255) slots, with a bounds check on every move. That is 17,408 × 255 ≈ 4.4 M moves per meta-block. C does the same O(idx) work, but on `uint8` with an upper bound, and clang compiles it to memmove.
* Impact: Pion decodes at about 0.4 MB/s of attacker input. A service that accepts 1 MB bodies can be held for 2.5 s (4 s on wasm) of CPU per request. Output size and memory are unaffected.
* Fix: store `mtf` in `Bytes` or `FixedArray[Byte]` and track an upper bound like C does. Do the shift with a block copy (`blit` / `copy_within`, if Pion has one), or with 8-byte chunks. At minimum, skip the inner loop when `idx == 0`.

### P2-2 Output buffer growth: wasm32 large limits and peak memory
* Native, default 256 MiB limit, 1 GiB bomb: Pion RSS **478.7 MiB**; C harness 531.9 MiB (realloc doubling); Rust 276 MiB. The peak is about 1.8× the limit, because `ensure_additional` above 32 MiB keeps the old buffer plus the new one, and the final `slice` adds more.
* wasm32: 1 GiB limit → RSS 2.9 GB, and a limit ≥ 1.25 GiB traps (see P1-2).
* On the 8 MiB copy streams Pion's RSS is 39–44 MiB vs C's 14 MiB (`hp_copy_*`).
* Suggestions:
  * Use `MLEN` totals or a 1.5× growth factor.
  * Return without the final `slice` copy (`Bytes::truncate`, if available).
  * Recommend that wasm callers keep `max_output_bytes` ≤ 512 MiB.

### P2-3 `max_output_bytes == 0` semantics (needs a decision)
* The task says to "block `max_output_bytes <= 0`". Current behaviour: `< 0` → `OutputLimitExceeded(-1)`. `== 0` is a valid limit: an empty stream gives `Ok(empty)`, and any output gives `OutputLimitExceeded`. Both are covered by `control_limits_api_validation`.
* `max_window_bits` outside `10..24` → `InvalidWindowBits`, and `WBITS > max_window_bits` → `WindowLimitExceeded`. Both are covered by the same test.
* Recommendation: keep 0 meaning "no output allowed" (consistent and harmless) and say so in the README. If 0 must be rejected, it is a one-line change, but it breaks the "check an empty stream" use case. **Proposed for the leader to decide.**

### P2-4 (Pion toolchain, not this package) `Bytes::new(negative)` behaves differently on native and wasm32
* A minimal program, `Bytes::new(536870912 * 4 + 256)`: native → `pion panic: negative bytes length`; `--target wasm32` → `len=0` and execution continues.
* So the same overflow crashes natively but silently becomes an empty buffer on wasm, which breaks the native/wasm equivalence assumption. Recommend reporting this to the Pion runtime owner: wasm should trap the same way.

---

## Performance hot spots (Web/WOFF2 at 0.46–0.54× of Rust/C)

`run_audit.sh perf` uses `hotpath_gen.py` to build one stream per decoder path, then compares Pion against C one-shot `BrotliDecoderDecompress` with `bench_compare.py` (warmup 1, rounds 5, stdout SHA-256 identical):

| Path (stream) | Pion MB/s | Pion / C | Bottleneck (`src/brotli.pion`) |
| --- | ---: | ---: | --- |
| Literals, 1 tree, 8-bit codes (`hp_literals`) | 89 | **0.19×** | ~11.7 ns per literal vs C's ~2.2 ns. Each symbol goes through `PrefixCode::read` (`:399`): a `Result` wrapper plus `?` branch, a `single` branch, a `cnt < 15` refill check, and a `fill()` that loops byte by byte. `lit_codes[tree]` is an `Array` indirection. The `lut[...]` lookup and the `buf[pos]` write are both bounds-checked. |
| Literals + UTF8 context + 64 trees + block switching (`hp_literals_cm`) | 66 | 0.34× | Same as above, plus two `Bytes` LUT reads for the context and a `lit_map` lookup per literal |
| Short commands, insert 1 + copy 4 (`hp_cmds`) | 64 | **0.20×** | Per command: 3–4 `take()` calls returning `Result`, `Blocks::next` checks, `ensure_additional` twice, and reloading `prev1/prev2` from `buf` |
| Dictionary words (`hp_dict`) | 115 | **0.18×** | `write_dict_word` (`:823`): per word it looks up `transform_prefixes`/`suffixes` (`Array[Bytes]`), copies affixes byte by byte, calls `ensure_additional`, and checks for errors |
| Long copies, d ≥ 8 (`hp_copy_long`) | 1166 | 0.47× | 8× unrolled byte copy, every byte bounds-checked; C uses 16-byte `memcpy` |
| Overlapping copies, d = 2..7 (`hp_copy_short`) | 1207 | 0.70× | Byte-by-byte copy |
| RLE, d = 1 (`hp_copy_rle`) | 1462 | 0.70× | Byte-by-byte fill |

The Web corpus (q6) is mostly long copies plus some literals, which fits its 0.54×. WOFF2 (q11) is literal-heavy with complex context maps, which fits its 0.46×.

Suggested optimisations for the next round, in order of payoff:
1. **A dedicated fast path for literals and commands.** When at least 8 input bytes remain, skip the EOF and `Result` checks the way C/Rust split "safe" and "fast" paths. Refill once with an 8-byte load (a 64-bit buffer keeps ≥ 56 bits, enough for 3 symbols of 15 bits). Inline the table lookup.
2. **Bulk-copy primitives.** Use `blit`/memmove for d ≥ copy, and pattern doubling for d < 8. Precompute per-transform data in `FixedArray`s (kind, prefix and suffix offsets) and write dictionary affixes with block copies.
3. **Call `ensure_additional` once per meta-block**, sized by MLEN within the limit, to remove per-command growth checks. Drop the final `slice` copy.
4. Speed up IMTF (P2-1).

---

## Reproduction commands

```sh
sh packages/brotli/audit/run_audit.sh build      # Pion native + wasm32, C harness (libbrotli 1.2.1), Rust harness (/tmp)
sh packages/brotli/audit/run_audit.sh unit       # redteam_* (2 FAIL = P1-1, P1-2) / control_* (4 PASS) + upstream 10/10
sh packages/brotli/audit/run_audit.sh vectors    # 2,190 vectors + 28 malformed, four-way diff
FUZZ_N=200000 sh packages/brotli/audit/run_audit.sh fuzz   # mutation fuzz (default 24,000)
sh packages/brotli/audit/run_audit.sh dos        # bombs / floods / 512 MiB input (native, three implementations)
sh packages/brotli/audit/run_audit.sh wasm_dos   # same probes under wasm32
sh packages/brotli/audit/run_audit.sh perf       # per-path hot-spot benchmarks
```

Single-case repros (after `build` and `dos`, in `$AUDIT_OUT`):

```sh
bin/pion_audit file input_512MiB_meta.br 268435456        # P1-1: pion panic: negative bytes length
bin/pion_audit file bomb_4GiB_hand.br 2147483647           # P1-2: container length exceeds maximum
node ~/.pion/share/pion/pion_wasm_rt.mjs bin/pion_audit.wasm file bomb_4GiB_hand.br 1342177280   # P1-2 wasm trap
time bin/pion_audit file maxtrees_flood.br 268435456       # P2-1: ~2.5 s vs C 0.17 s (bin/c_audit file ...)
```

## Files

| File | Purpose |
| --- | --- |
| `redteam_test.pion` | Pion unit tests. `redteam_*` FAIL while a defect exists; `control_*` must PASS. Includes an in-test bit writer that builds the bombs. |
| `src/main.pion` | Pion harness CLI (`batch` / `file` / `bench`), compiled to both native and wasm32 |
| `diff/c/c_audit.c` | C libbrotlidec streaming decode (OK/TRAIL/ERR), libbrotlienc batch encode, and dumps of the dictionary, transform table and context LUT |
| `diff/rust/` | Rust `brotli-decompressor =4.0.3` harness (catches panics) |
| `brenc.py` | Independent RFC 7932 stream writer. It tracks the expected output, and the dictionary, transforms and LUT come from C `libbrotlicommon`. |
| `difftest.py` | Vector generation, four-way diff, fuzz |
| `dos_gen.py` | Bomb, flood and large-input probes |
| `hotpath_gen.py` | Per-path performance streams |
| `run_audit.sh` | One-shot entry point |
