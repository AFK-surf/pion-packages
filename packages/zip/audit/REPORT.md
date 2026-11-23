# RT-zip — Red-Team Audit of `packages/zip`

- **Target**: `AFK-surf/pion-packages` `feat/pkg-zip` @ `2598d1c` (`packages/zip/src/{reader,writer,types,path}.pion`, `bench/`).
- **References**: Go `go1.27.3` `archive/zip`, Rust `1.100.0` `zip =2.2.3` (`default-features = false, features = ["deflate"]`, locked via `diff/rust/Cargo.lock`), CPython `3.9.6` `zipfile`.
- **Toolchain**: `pionc 0.1.0 (arm64_apple, self-hosted)`, `node v24.22.2` (`pion_wasm_rt.mjs`), Darwin arm64 (`tokyo-mac-studio-0`, shared machine, load 20–35 during timing runs — timings are given as ratios against a same-run control).
- **Reproduce**: `sh packages/zip/audit/run_audit.sh` (sections: `build unit writer vectors paths fuzz modes dos prof`). All artifacts land in `/private/tmp/pion-zip-audit`; the worktree stays clean (`git status --porcelain --ignored` is checked at the end).

| File | Purpose |
| --- | --- |
| `redteam_test.pion` | 12 `redteam_*` tests (FAIL while the defect exists) + 6 `control_*` tests (PASS); vectors embedded as hex |
| `src/main.pion` | Pion CLI: `batch`/`file` canonical reader output, `paths`, `writecases`, `prof` |
| `diff/go`, `diff/rust` | same canonical output from Go `archive/zip` and Rust `zip` (+ `verify`, `paths`, Go `prof`) |
| `zipcraft.py` | field-level ZIP builder (every LFH/CD/EOCD/ZIP64 field overridable) |
| `difftest.py` | 62 crafted vectors, 2×6,000-case mutation fuzz, path matrix, writer interop, 4-mode check, DoS |
| `run_audit.sh` | one-shot driver |

Canonical reader output per archive: `OK n=<N> |<hex name>:OK:<len>:<crc32>|…` or `ERR <reason>`; Pion is run with `Limits::permissive()` (parser parity) and `Limits::default()` (hardened).

## Summary

| ID | Sev | Finding | Go | Rust | Python |
| --- | --- | --- | --- | --- | --- |
| P0-1 | **P0** | ZIP64 locator offset `0x7FFFFFFFFFFFFFF0`: `Int64` overflow in the bounds check → **panic / wasm32 trap** on a 201-byte input | reads | reads | reads |
| P0-2 | **P0** | ZIP64 `cd_offset + cd_size` `Int64` wrap passes the CD bound; every later bound uses the huge `cd_offset` → **out-of-bounds read panic / trap** (484-byte input) | entry error | rejects | rejects |
| P0-3 | **P0** | Same wrap + Store entry: `Bytes::slice` silently clamps at EOF; with a forged CRC `read_entry` returns **`Ok` with 453 bytes for an entry declaring 268,435,200 bytes**, the bytes being the archive's own CD/EOCD — **under default hardened limits** | rejects | same bug | rejects |
| P1-1 | P1 | Seed-independent **HashDoS** on the `name_index` `Map`: 65,536 crafted names → open takes **13.4 s vs 0.12 s** for same-size control names (quadratic; root cause in Pion runtime string hash) | 0.14 s | 0.97 s | 0.96 s |
| P1-2 | P1 | CPython-produced streamed ZIP64 archive (`force_zip64` to a non-seekable stream) **unreadable**: data-descriptor width chosen from CD sentinels instead of LFH ZIP64 extra (APPNOTE 4.3.9.2) | reads | reads | reads |
| P1-3 | P1 | **CD records beyond the EOCD count are silently dropped**: EOCD count 1 / CD 2 → 1 entry; legacy non-ZIP64 archive with 100,000 entries → **34,464 entries** (65,536 hidden) | rejects / 100,000 | 1 / 34,464 | 2 / 100,000 |
| P1-4 | P1 | ZIP64 EOCD **overrides a sentinel-free EOCD** (APPNOTE 4.4.1.4): Pion sees `eocd64.txt`, Rust sees `eocd32.txt` — scanner/extractor differential | rejects | `eocd32.txt` | `eocd64.txt` |
| P1-5 | P1 | No `baseOffset`: SFX stub / prepended data, and `zip1 ‖ zip2`, **fail to open** | reads | reads | reads |
| P1-6 | P1 | LFH vs CD **file name mismatch accepted silently** (`evil.sh` vs `good.txt`) | accepts | accepts | rejects |
| P1-7 | P1 | Any bytes after EOCD (or comment_len shorter than the tail) → `InvalidArchive` | reads | reads | reads |
| P2-1 | P2 | ZIP64 `total_entries = 0x80000001` truncates to negative `Int` → archive opens with **0 entries** (permissive limits) | 1 entry | 1 entry | 1 entry |
| P2-2 | P2 | `DosDateTime` clamps year only (1979-06-15 → 1980-06-15, 2200 → 2107-01-01) and writes invalid dates (2023-02-31) | 1980-01-01 / normalises | `None` | strict error |
| P2-3 | P2 | `clean_extract_path` misses `COM¹-³`/`LPT¹-³`, `CONIN$`/`CONOUT$`, trailing dot/space aliases, control chars | Windows `IsLocal` rejects first two groups | — | — |
| P2-4 | P2 | Benchmark hygiene: `bench/rust` has no `Cargo.lock`; W2 stdout check does not cover compressed size; W3 compares a zero-copy slice against copying readers | — | — | — |
| P2-5 | P2 | 2 GiB ceiling: archives/entries ≥ 2 GiB cannot be read or written (`Bytes`/`Int` 32-bit); README's ">4 GiB auto ZIP64" path is unreachable | streams | streams | streams |

No defect found in: the writer's on-disk format (9 archive families, 0 diffs vs Go/Rust/Python), ZIP64 extra field order, overlong field rejection, bomb caps, overlap/duplicate detection, EOCD scan cost, 4-mode determinism. Details and the places where Pion is ahead are in [Fair findings](#fair-findings-no-defect--pion-ahead).

---

## P0 — memory safety on untrusted input

`Int` is 32-bit and `Int64` arithmetic wraps silently in Pion (`0x7FFFFFFFFFL.to_int() == -1`, `2147483647 + 1 == -2147483648`, verified with a scratch program). The reader validates offsets with unchecked `Int64` additions and then narrows with `to_int()`.

### P0-1 ZIP64 locator offset overflow → panic (`reader.pion:272-281`)

```pion
let z64_eocd_off = read_i64_le(data, loc_pos + 8)
if z64_eocd_off < 0L || z64_eocd_off + 56L > loc_pos.to_int64() {   // 0x7FFFFFFFFFFFFFF0 + 56 wraps < 0
  return Err(...)
}
let zoff = z64_eocd_off.to_int()                                      // == -16
if read_u32_le(data, zoff) != sig_zip64_eocd {                        // data[-16] -> panic
```

Vector `z64_locator_off_overflow` (201 bytes, a valid archive whose locator offset is `0x7FFFFFFFFFFFFFF0`):

```
pion(native debug/release)  rc=-6  pion panic: index -16 out of bounds (len 201)
pion(wasm32 debug/release)  rc=1   pion panic: index out of bounds: idx=-16, len=201
go / rust / python          OK n=1 a.txt (fall back to the 32-bit EOCD, which has no sentinel)
```

Same defect class in the next line (`z64_eocd_off + 12L + rec_size`, harmless there) and in `parse_zip64_extra` callers. `redteam_p0_zip64_locator_offset_int64_wrap_must_not_panic` panics.

### P0-2 `cd_offset + cd_size` wrap → out-of-bounds read (`reader.pion:306-327, 175-179, 421`)

ZIP64 EOCD with `cd_offset = 2^62 + 335`, `cd_size = 2^62 + 51`: both non-negative, the sum wraps negative so `cd_offset + cd_size > eocd_start` is false; `cd_offset.to_int()` keeps the low 32 bits (the real CD at 335). From there on every bound compares against `cd_offset ≈ 4.6e18`, so `lh_off + 30L > cd_offset` never fires. Vector `z64_wrap_then_far_lfh` sets the entry's local header offset to `0x10000000`:

```
pion(all 4 modes, default AND permissive)  panic: index 268435456 out of bounds (len 484)   (check_no_overlaps -> read_u32_le)
go     OK n=1 c.bin=ERR      rust  ERR invalid Zip archive     python  ERR ValueError
```

### P0-3 silent short read of a Store entry under default limits (`reader.pion:643-647`)

With the same wrap, a Store entry declaring `csize = usize = 0x0FFFFF00` (< 256 MiB `max_entry_size`, ratio 1) passes every check; `self.data.slice(data_start, data_end)` **clamps** to EOF instead of failing, and the Store path never compares the output length with `uncompressed_size`. `zipcraft` forges the CRC by solving 4 bytes of the entry comment over GF(2), so CRC verification passes:

```
z64_wrap_store_clamp_forged_crc  (488 bytes)
  pion_def  OK n=1 |782e62696e:OK:453:1515870810      <- 453 bytes returned, entry declares 268435200
  pion_perm OK n=1 |782e62696e:OK:453:1515870810
  go        OK n=1 |782e62696e:ERR:read
  rust      OK n=1 |782e62696e:OK:453:1515870810      <- zip 2.2.3 has the same defect
  py        ERR ValueError
```

The returned "file content" is the archive's own CD, ZIP64 EOCD and EOCD — a different byte sequence than any tool that honours the declared size would produce. Fix for P0-1..3: checked `Int64` adds (or compare `x > limit - y`), reject `cd_offset + cd_size` / any offset beyond `data.length()`, and assert `out.length() == uncompressed_size` for Store.

**Fuzz census**: random mutation from the non-crashing seeds (60 vectors < 200 KB + Pion-written archives + CPython archives) (pass `clean`, 6,000 cases) found **0** Pion crashes — the defects need specific 64-bit values, which byte-level mutation rarely forms; with the 2 crash vectors among the seeds (pass `all`, 6,000 cases) **56** mutants crash Pion (45 × negative index, 11 × index ≥ len) and **0** crash Go/Rust/Python. Native and wasm32 fail on exactly the same inputs.

## P1

### P1-1 HashDoS through `name_index : Map[String, Int]` (`reader.pion:325, 425-432`)

`pion_str_hash` (`~/.pion/share/pion/runtime/pion_rt.c:1979`, mirrored by `hashBytes64` in `pion_wasm_rt.mjs`) is seeded, but per 8-byte block it does `h ^= w; h *= K; h ^= h >> 32` with odd `K`. Flipping bit 63 of `w` changes `w*K` by exactly `2^63` for **every** `h`, so the block output changes by exactly `2^63 | 2^31`, and XOR-ing that into the next block cancels it. Each block pair therefore has two interchangeable values and `k` pairs give `2^k` equal-length names with one hash value **for every seed** (`difftest.py: hash_collide_names`). With linear probing every insert / `get` walks the whole cluster.

`difftest.py dos` (Store, empty payload, same name length for collide/control; each process draws a fresh random seed):

| entries | Pion collide | Pion control | Go collide | Rust collide | Python collide |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 4,096 | 0.03 s | 0.01 s | 0.01 s | 0.04 s | 0.13 s |
| 16,384 | 0.41 s | 0.02 s | 0.03 s | 0.15 s | 0.20 s |
| 32,768 | 1.96 s | 0.04 s | 0.05 s | 0.31 s | 0.34 s |
| 65,536 | **13.43 s** | 0.12 s | 0.14 s | 0.97 s | 0.96 s |

Canonical run above (`run_all.log`); on an earlier, more loaded run the 65,536 case took 24.1 s vs 0.11 s. Doubling `n` multiplies Pion's time by ~4–5 (quadratic) while the control stays linear. wasm32 (node) 16,384 entries: collide 1.17 s vs control 0.07 s. The default `max_entries` (100,000) admits ~2.3× more. The archive for 65,536 entries is 37 MB. Root cause is the Pion runtime hash (should be reported to the Pion runtime owner); `packages/zip` can mitigate locally (sort + binary search like Go's `fs.FS` index, or cap name-index work).

### P1-2 ZIP64 data descriptor width taken from the CD (`reader.pion:613`)

APPNOTE 4.3.9.2: the descriptor uses 8-byte sizes when the **LFH** carries a ZIP64 extra. Pion uses `entry.is_zip64`, set only when the **CD** has a `0xFFFFFFFF` sentinel. CPython itself produces the failing layout (non-seekable output, `force_zip64=True`): LFH ZIP64 extra, 24-byte descriptor, CD with plain 32-bit sizes because the file is small. Vectors `py_stream_force_zip64` (generated live by CPython) and `dd_zip64_lfh_extra_small`: Pion `ERR InvalidArchive ("data descriptor mismatch")`, Go/Rust/Python read 240 bytes. (Go and Rust only check the descriptor CRC.)

### P1-3 entries beyond the EOCD count are invisible (`reader.pion:323-454`)

Pion parses exactly `total_entries` records and ignores the rest of `[cd_offset, cd_offset + cd_size)`:

```
cd_count_short (EOCD n=1, CD has 2)   pion OK n=1 (a.txt) | go ERR unexpected EOF | rust OK n=1 | python OK n=2
entries_100000_legacy_u16count        pion OK n=34464     | go OK n=100000        | rust 34464  | python 100000
```

Writers that pre-date ZIP64 (and some current ones) store the entry count mod 65,536; Go explicitly tolerates that (`uint16(len(r.File)) != uint16(end.directoryRecords)`). A scanner built on Pion sees 1 (or 34,464) files where `unzip`/Python extract 2 (or 100,000): files can be hidden from a Pion-side policy check. Fix: after the loop require `pos == cd_end` (or keep reading records while the signature matches, as Go does, and compare mod 65,536).

### P1-4 ZIP64 EOCD trusted without a sentinel (`reader.pion:268-296`)

The locator is honoured whenever present, even when the 32-bit EOCD has no `0xFFFF`/`0xFFFFFFFF` field. Vector `z64_eocd_disagrees_no_sentinel`: the 32-bit EOCD points at `CD{eocd32.txt}`, the ZIP64 EOCD at `CD{eocd64.txt}`. Pion and Python list `eocd64.txt`, Rust `eocd32.txt`, Go rejects. Related: `z64_locator_off_huge` (locator pointing outside the file, no sentinel) is rejected by Pion but read by all three references. Fix: use the ZIP64 record only when a 32-bit field is a sentinel; otherwise require both records to agree.

### P1-5 no prepended-data (`baseOffset`) support

`prefix128_unadjusted` (`cat stub.sh a.zip`, the SFX / shell-script-installer / some JAR launcher layout): Pion `ERR InvalidArchive (bad central directory header signature)`; Go, Rust, Python read both entries. `concat_two_zips`: Pion errors, Go/Python read the second archive, Rust the first. Go computes `baseOffset = directoryEndOffset - cd_size - cd_offset`.

### P1-6 LFH/CD name mismatch (`reader.pion:569-601`)

The LFH is cross-checked for method, CRC and compressed size (stricter than Go/Rust/Python, see the fair section) but **not the file name**. `lfh_name_differs` (LFH `evil.sh`, CD `good.txt`): Pion, Go, Rust return the content under `good.txt`; Python raises `BadZipFile: File name in directory 'good.txt' and header b'evil.sh' differ`. Streaming extractors (`bsdtar`, Java `ZipInputStream`) see `evil.sh`. Since Pion already reads the LFH name length, comparing the bytes costs nothing.

### P1-7 trailing data after EOCD

`find_eocd` accepts only `eocd_pos + 22 + comment_len == len`. `trailing_16` and `comment_len_short` are read by Go, Rust and Python and rejected by Pion. (`comment_len_long` — comment length past EOF — is rejected by Pion, Go, Rust; Python accepts.)

## P2

- **P2-1** `total_entries.to_int()` (`reader.pion:323`): `z64_entries_neg_as_int` (ZIP64 count `0x80000001`) opens with **0** entries under `Limits::permissive()`; `z64_entries_2pow32p1` opens with 1. Default limits reject via `max_entries`.
- **P2-2** `DosDateTime::new`/`from_unix` (`types.pion:136-201`) clamp each field independently. Pion-written `w06_times.zip` read back by the references:

  | input | Pion writes | Go reads | Rust reads | Python reads |
  | --- | --- | --- | --- | --- |
  | 1979-06-15 12:00 | 1980-06-15 12:00 | same | same | same |
  | 2108-03-01 | 2107-03-01 | same | same | same |
  | unix 7258118400 (2200-01-01) | 2107-01-01 | same | same | same |
  | 2023-02-31 | 2023-02-31 | 2023-03-03 | *invalid (None)* | (2023, 2, 31) |

  Go's writer maps pre-1980 to 1980-01-01; CPython (`strict_timestamps=False`) to 1980-01-01 / 2107-12-31 23:59:58. Odd seconds (59 → 58) and 2024-02-29 are correct.
- **P2-3** `clean_extract_path` (`path.pion`) vs Go `filepath.IsLocal` on Windows: accepts `COM¹`, `LPT².txt`, `CONIN$`, `CONOUT$` (Go rejects these as reserved), `foo.`/`foo `/`a/.. /b` (Win32 strips trailing dots/spaces → aliasing; e.g. `foo.` and `foo` collide), and control characters `\x01`/`\x1f` (invalid on Windows). Everything else in the 56-input matrix is equal or stricter than Go/Rust (`..`, absolute, UNC, drive, ADS, NUL, `CON`…`LPT9` all rejected).
- **P2-4** Benchmark hygiene:
  - `packages/zip/bench/rust` has `Cargo.toml` only (`git ls-files` → no `Cargo.lock`), so `flate2`/`miniz_oxide`/`crc32fast`/`zopfli` float between runs. This audit pins them (`diff/rust/Cargo.lock`: `flate2 1.1.11`, `miniz_oxide 0.9.1`, `crc32fast 1.5.0`, `zopfli 0.8.3`). Note `zip`'s `deflate` feature also pulls `zopfli` (unused at level 6).
  - W2's SHA-256 gate covers only `files / total_uncomp / xor of declared CRC`, not compressed size or decompressibility of the other implementations' output; Pion's L6 output is 3.6 % larger than Go's (performance section).
  - W3 (`2.54×` Go, `4.13×` Rust): Pion's `open_by_name` returns a zero-copy `Bytes::slice` for Store entries; Go (`io.ReadAll` through `fs.File`) and Rust (`read_to_end` through a `ZipFile` reader) copy into fresh buffers, and Go's `Open(name)` also builds its sorted `fs.FS` directory tree on first use. The lead is real but partly measures copy/API shape, not lookup.
- **P2-5** `Bytes` length and offsets are `Int` (32-bit): input archives and single entries ≥ 2 GiB cannot be represented, so the writer's automatic ZIP64 upgrade for `>= 0xFFFFFFFF` sizes/offsets (README) is unreachable; only `force_zip64` and the ≥ 65,535-entry path exercise ZIP64. Go/Rust/Python stream.

## Performance root cause (W1 0.84× Go, W2 0.52× Go)

`run_audit.sh prof`: same corpus as `bench/` (200 files, 23.6 MB), 5 iterations, three rounds, Pion `--release` vs Go 1.27 (load ~30 on the host; take ratios, not absolutes):

| phase (5 iters) | Pion ms | Go ms | Pion / Go |
| --- | ---: | ---: | ---: |
| raw inflate only (`flate` / `compress/flate`) | 138–161 | 109–116 | ~1.3× slower |
| CRC-32 only | 43–54 | 10–11 | **~4.5× slower** |
| full `read_entry` (inflate + CRC + header checks) | 172–200 | 101–108 (`f.Open` + `io.Copy`) | ~1.7× |
| raw Deflate L6 only | 544–653 | 250–282 | **~2.2× slower** |
| CRC-32 of inputs (writer) | 44–57 | — | — |
| full `ZipWriter` (200 × add_file + finish) | 581–726 | — | ≈ deflate + CRC (±10 %) |
| **Deflate L6 output size** (200 payloads) | **2,317,817 B** | 2,237,829 B | Pion **+3.6 %** (C zlib L6: 2,241,847 B) |

- **Reader**: `read_entry ≈ inflate + CRC`; ZIP parsing, LFH/DD validation and the Store zero-copy path are negligible (`open` of the 200-entry archive: 0–1 ms for 5 iterations). The gap to Go is the software CRC-32 (slice-by-16, ~2 GB/s vs Go's ARMv8 `CRC32X` path ~20 GB/s) plus a ~1.2× slower inflate. Hardware CRC alone would remove ~25 % of W1 time.
- **Writer**: `ZipWriter` adds ≤ 10 % over `flate::deflate_compress`; the remaining 2× is the L6 compressor in `packages/flate`. Payloads ≥ 2 KiB are not copied into `ZipBuf` (pushed as chunks), but `concat_bytes_chunks` does ⌈log2(chunks)⌉ full copies of the archive (≈ 9 × 2.2 MB here) and keeps intermediates alive — visible as the 64 MiB peak RSS, not as time.
- W2 is understated by the bench: Pion's L6 is ~2.2× slower **and** its output is 3.6 % larger than Go/zlib L6 on the same payloads, which the W2 SHA-256 gate (metadata only) cannot see.
- Conclusion: W1/W2 gaps belong to `packages/flate` (CRC-32, inflate inner loop, the L6 matcher), not to `packages/zip`.

## Fair findings (no defect / Pion ahead)

- **Writer interop: 0 differences.** 9 Pion-written families (empty files Store/Deflate, 70 KB Store/Deflate, UTF-8 + emoji names, directory, symlink `0o120777`, UTF-8 archive comment, duplicate names, 65,535-byte name + 65,535-byte comment, `force_zip64` on Store/Deflate/empty, 65,535 and 70,000 entries (ZIP64 EOCD), all Deflate levels 0–9) read back byte-identically by Go, Rust and Python (`testzip() == None`). Names/comments of 65,536 bytes are **rejected with `InvalidArgument`**, never truncated to `u16` (`w04_overlong`).
- **ZIP64 extra field order** (APPNOTE 4.5.3, only-`csize`, only-`offset`, only-`usize`) correct; truncated / overrunning ZIP64 extras rejected.
- **Bombs**: honest 256 MiB zeros (ratio ~1000) and lying `usize=1` rejected in **0.01 s / 2–3 MiB RSS** (Go 580 MiB, Rust 268 MiB, Python 274 MiB decompress it fully; Rust also inflates the full 8 MiB of a `usize=0` liar). Full-overlap (64 CD entries on one payload) and nested-LFH overlaps rejected by default; Go/Rust/Python serve them.
- **Stricter than all references (safe direction)**: LFH method / CRC / compressed-size disagreement, data-descriptor size disagreement, missing descriptor, encrypted entries (Go serves ciphertext as plaintext), duplicate names by default (Rust silently keeps only the last of two `dup.txt`).
- **EOCD scan**: bounded to 64 KiB + 22 with a first-byte filter; a 64 KiB comment full of `PK\x05\x06` opens in 0.01 s (Go and Python fail to open it); 1 MiB of `PK\x05\x06` without a valid EOCD fails in 0.01 s (Rust 0.65 s).
- **100k entries** (proper ZIP64): 0.04 s / 58 MiB vs Go 0.06 s / 74 MiB, Rust 0.23 s, Python 0.81 s. 300 entries with 60 KB extra fields: 0.01 s.
- **4-mode determinism**: native debug/release and wasm32 debug/release produce byte-identical stdout (SHA-256) on the 60 non-crashing vectors and 6,000 fuzz cases, both limit profiles; on the crash inputs all four modes fail identically (native `abort`, wasm `pion panic` → node exit 1).
- **Benchmarks**: W3 (20k-entry CD scan + lookups) leads Go 2.54× and Rust 4.13× (caveat in P2-4); W1 peak RSS 6.2 MiB vs Go 17 MiB.
