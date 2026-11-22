# `packages/tar` red-team audit

Target: `origin/feat/pkg-tar` @ `1e62c30` (Pion `tar` 0.1.0). References: Go 1.27.3 `archive/tar`, Rust `tar` 0.4.46.
Machine: Darwin arm64 (M-series Mac Studio, 64 GB). Every number below comes from:

```sh
sh packages/tar/audit/run_audit.sh            # full run, ~15 min, needs ~8 GB free RAM for the heavy probes
sh packages/tar/audit/run_audit.sh --quick    # no multi-GiB probes, smaller fuzz
SECTIONS="tests diff" sh packages/tar/audit/run_audit.sh   # individual sections
```

All generated corpora, binaries and logs go to `$AUDIT_OUT` (default `/tmp/pion-tar-audit`); the worktree stays clean.

## Layout

| Path | What it is |
| --- | --- |
| `redteam_test.pion` (+ `pion.toml`, package `tar_redteam_audit`) | 18 Pion tests. The 14 `p0_/p1_/p2_` tests assert the Go behaviour, so they **fail now** and turn green once the bug is fixed. The 4 `control_` tests must pass; they show that the builder, checksum and PAX-record helpers are correct. |
| `probe/` | Separate Pion binary for crash and OOM evidence (a SIGSEGV would kill the test binary). |
| `tools/pion_tar`, `tools/go_tar`, `tools/rust_tar` | Three drivers that print the same canonical dump format: `dump`, `trunc`, `mutate`, `writespec`, plus `scanbench`, `readbench` and `writebench`. `go_tar gencorpus` builds the 110-archive adversarial corpus; `go_tar genspec` builds the 303-header writer spec. |
| `diff/compare.py` | Field-level differential (`dump`, `trunc`, `mutate`, `writer`). `diff/mutate_one.py` re-creates any single mutant for triage. |
| `bench/gen_sparse.py` | Sparse-read workload (400 × PAX 1.0, 1 MiB logical each). |

Run `pionc test --json -p tar_redteam_audit packages/tar/audit` for the tests alone (assertion messages go to stderr).

## Summary

| ID | Sev | Finding | Evidence |
| --- | --- | --- | --- |
| P0-1 | P0 | `Writer::finish` overflows the heap (SIGSEGV) once the archive reaches 4 GiB. Between 2 and 4 GiB it returns `Ok` with a negative `length()`, and reading that result back gives a silent empty archive. | probe `big4g-write` (exit 139), `big2g-write` |
| P0-2 | P0 | Sparse amplification: a 2 KiB input makes `read_all` with `Limits::default()` materialise 512 MiB (RSS 514 MiB). 5 KiB costs 2 GiB, and the cost grows linearly. Go streams the same archive in 4.5 MiB. | `p0_sparse_bomb_read_all_materialises_512MiB_from_2KiB`, probe `sparse-bomb` |
| P1-1 | P1 | The writer rounds negative half-second mtimes the wrong way: −0.5 s is written as −1 (Go: 0) and −1.5 s as −2 (Go: −1). It also switches to a PAX header to do it. | `p1_writer_negative_half_second_mtime_rounding`, writer diff #191/#198/#212 |
| P1-2 | P1 | An empty GNU `L`/`K` entry (payload `""` or `"\0"`) wipes the real name or linkname. | `p1_empty_gnu_longname_or_longlink_clobbers_header_name`, mutation sweep |
| P1-3 | P1 | When `GNU.sparse.size=""` is present, `GNU.sparse.realsize` is ignored, so the file comes back with 5 bytes instead of 100. | `p1_empty_gnu_sparse_size_hides_realsize` |
| P1-4 | P1 | With uncapped `Limits`, a size field past the end of the input is reported as success: `read_data` returns `Ok(0 bytes)` and the next `next()` returns clean EOF. The cause is Int64 overflow. | `p1_huge_size_reads_as_empty_success_with_uncapped_limits`, probe `huge-size-read` |
| P1-5 | P1 | An empty `GNU.sparse.map=` record with no version keys makes a regular file unreadable. | `p1_empty_gnu_sparse_map_rejects_regular_file` |
| P1-6 | P1 | PAX record handling is O(n²) (`kv_set` linear scan, insertion sort). Under default limits, a 23.5 MB archive with 4,000 records per header takes 13.1 s to read (Go: 0.125 s, **105× slower**) and 6.9 s to write (Go: 0.27 s, **26× slower**). | bench `scan paxrecs4000`, `write paxrecs4000` |
| P1-7 | P1 | `Reader::new` copies the whole input into a `String` (`data.to_string()`), and there is no streaming API. Listing one header of a 64 MiB archive is **31× slower** than Go. Input is capped at 2 GiB (`Int` is 32-bit). Peak RSS is about 3× the input. | bench `scan big64MiB` |
| P1-8 | P1 | Large writes copy the payload 4 times (`write_data`: `to_string`, then the builder; `finish`: `to_string`, then `to_bytes`). Writing 64 MiB is **3.6× slower** than Go. | bench `write big64MiB` |
| P2-1 | P2 | PAX numbers with a leading `+` (`size`, `uid`, `mtime`, record length, sparse 1.0 count) are rejected; Go's `strconv.ParseInt` accepts them. | `p2_pax_numbers_with_plus_sign_rejected`, 5 corpus files |
| P2-2 | P2 | An old-GNU `'S'` header whose atime field is not a number (pre-Go 1.8 prefix) is rejected; Go falls back and still reads the sparse map. | `p2_old_gnu_sparse_with_prefix_in_atime_rejected`, mutation sweep |
| P2-3 | P2 | `Limits::default()` refuses archives Go reads: 100,001 entries, 70,000 sparse fragments, 5,000 PAX records, files over 256 MiB, 1 TiB sparse files. | `p2_default_limits_reject_legitimate_archives`, the diff `LIMITS-ONLY` list (10 archives) |
| P2-4 | P2 | The writer accepts a `TypeXGlobalHeader` with `size`/`mode` set and silently drops them; Go returns an error. | `p2_writer_global_header_accepts_ignored_fields`, writer diff #299/#300 |
| P2-5 | P2 | The writer drops user PAX `uid`/`gid`/`size` records whose value matches the header; Go keeps them. | `p2_writer_drops_matching_numeric_pax_records`, writer diff #285 |
| P2-6 | P2 | The `PaxHeaders.0` meta name is not path-cleaned (`./`, `//`, `a/../`, a leading `/`), so the output differs from Go byte for byte. | `p2_writer_pax_header_name_not_cleaned`, writer diff #108–#112 |
| P2-7 | P2 | `Header.format` disagrees with Go: V7 and STAR are reported as `V7`/`STAR` (Go: `<unknown>`), and a GNU `L` mixed with PAX or USTAR is reported as `GNU` (Go: `<unknown>`). | `p2_format_of_mixed_gnu_and_pax_entry`, 11 format-only diff files |
| P2-8 | P2 | `clean_extract_path` accepts Windows hazards that Go's `filepath.IsLocal` (windows) rejects: NTFS streams (`a/b:stream`) and device names (`CON`, `NUL`, `COM1`, …). | `p2_clean_extract_path_windows_devices_and_streams` |

Test run: `total=18 passed=4 failed=14`. All 4 controls pass, and every failing test fails on the documented assertion (stderr lines `[P0-2] …` to `[P2-8] …` in `logs/pionc-test.stderr`).

## P0

### P0-1 Heap overflow in `Writer::finish` at 4 GiB, silent data loss from 2 GiB

```
pion 2.25 GiB archive (finish+read) exit=0   peakRSS=6913.9 MiB   finish OK: length() = -1879046656 (expected 2415920128) / re-read: EOF
pion 4.5 GiB archive (finish)      exit=139 peakRSS=7681.9 MiB   wrote 3 x 1.5 GiB, calling finish()   -> Segmentation fault: 11
```

- **Root cause.** The `Writer` accumulates the whole archive in one `StringBuilder`, and `finish()` returns `sb.to_string().to_bytes()` (`src/writer.pion:921`). The runtime's `pion_strbuf_to_str` (`~/.pion/share/pion/runtime/pion_rt.c:1581`) allocates `(uint32_t)(sizeof(PionString) + len + 1)` bytes and then `memcpy`s `len` bytes. For a 4.5 GiB archive that is a 0.5 GiB allocation receiving 4.5 GiB of data, which is a heap overflow.
- **Same cast elsewhere.** `pion_str_from_cstr` and `pion_str_slice` have the same cast. They are reached by `Reader::new` and `write_data`, but Pion `Bytes` cannot exceed 2³¹ bytes today, so those calls are not yet exploitable.
- **2 to 4 GiB.** Pion `Int` is 32-bit (`Int max + 1 = -2147483648`). `Bytes::length()` wraps negative and `Reader::new` treats the archive as empty: every entry is lost and no error is returned.
- **Go/Rust.** Both write to an `io.Writer` / `Write` and read from a stream, so neither has a size ceiling.
- **Fix direction.** Make the runtime casts size-safe. In tar, stream into a caller-provided sink or chunked `Bytes`, and return `Err` before 2³¹ instead of wrapping.

### P0-2 Sparse amplification: 512 bytes of header become 256 MiB of RSS

```
pion read_all, 2 entries (2 KiB)   exit=0   peakRSS=513.9 MiB    read_all OK: entries=2 materialized_bytes=536870912
pion read_all, 8 entries (5 KiB)   exit=0   peakRSS=2050.0 MiB   read_all OK: entries=8 materialized_bytes=2147483648
pion Reader streaming, 8 entries   exit=0   peakRSS=257.9 MiB    (each read_data still allocates + memsets 256 MiB)
go Reader+io.Copy streaming, 8 ent. exit=0   peakRSS=4.5 MiB
```

- **How it works.** An old-GNU `'S'` header with physical size 0, no fragments and `realsize` = 256 MiB is valid and within `max_entry_size`. `read_data` does `Bytes::new(logical_size)` for each entry, and `read_all` keeps all of them. So n × 512 B of input costs n × 256 MiB, and 40 entries (20 KiB) cost 10 GiB.
- **Why the limits miss it.** `max_entry_size` is checked per entry, never against a total. `read_data` has no streaming or hole-skipping form, so even a careful caller pays 256 MiB of allocation and memset per header.
- **Go.** Go yields holes from a fixed buffer, and `Next()` skips them in O(1).
- **README claim.** The README says this package defends against "multi-TiB sparse-hole OOM bombs". That holds only for a single header with `realsize` > 256 MiB.

## P1

- **P1-1 Negative mtime rounding.**
  - `Timestamp::round_sec` (`src/types.pion:156`) uses `nsec > 500000000` for negative instants. Go's `Time.Round(time.Second)` rounds halves toward +∞.
  - (−1 s, 500 000 000 ns), i.e. −0.5 s, becomes −1 instead of 0. (−2 s, 500 000 000 ns), i.e. −1.5 s, becomes −2 instead of −1.
  - With `Format=Unknown` (the default) Pion also emits a 512-byte PAX header to store the wrong value. The archive is 3072 bytes where Go writes 2048, and Go reads back mtime −1 where it wrote 0.
- **P1-2 Empty `L`/`K`.**
  - `src/reader.pion:795` uses the `has_gnu_long_name` flag. Go applies the long name only when it is non-empty (`if gnuLongName != ""`).
  - In the corpus (`gnu-L-empty`, `gnu-L-zero-size`, `gnu-K-empty`) and in mutants, Pion returns an empty name or linkname where Go keeps `raw-kept` / `target`.
  - An empty `Header.name` reaching an extractor is a correctness bug: it becomes the destination directory itself.
- **P1-3 `GNU.sparse.size=""`.** `kv_get` presence wins over Go's `if size == "" { size = realsize }` (`src/reader.pion:875`). Go returns size 100 with data length 100; Pion returns size 5 with data length 5.
- **P1-4 Overflowing size with custom limits.**
  - `cur_data_start + cur_data_len` overflows Int64 (`src/reader.pion:558`, `:971`), so the `> total_len` checks never fire.
  - With `Reader::with_limits` and a 0x7fff…ff00 size, `next` returns the header, `read_data` returns `Ok(0 bytes)` and the next `next()` returns EOF.
  - Go returns `io.ErrUnexpectedEOF`. A truncated or forged archive therefore looks complete.
- **P1-5 Empty `GNU.sparse.map`.** Pion treats a *present* map as sparse 0.x. Go requires a non-empty one. The result is `missing GNU.sparse.numblocks` on a regular file.
- **P1-6 Quadratic PAX.**
  - Reader: `kv_set` is a linear scan per record (`src/reader.pion:92`), used for records and xattrs.
  - Writer: `kv_set` plus `sort_kv_pairs` insertion sort (`src/writer.pion:89`).
  - 200 files × 4,000 `SCHILY.xattr.*` records, all within `Limits::default()` (4,096 records per header): Pion reads in 13 100 ms against Go's 125 ms and Rust's 142 ms. Pion writes in 6 923 ms against Go's 266 ms.
  - That is about 65 ms of CPU per 88 KB header, a CPU-amplification DoS. With a raised `max_pax_records` it grows quadratically.
- **P1-7 Whole-input copy and no streaming.**
  - `Reader::new` does `data.to_string()` (`src/reader.pion:33`), copying the full archive before the first header.
  - Scanning the single header of `big.tar` (64 MiB) 100 times takes 560 ms in Pion, 18 ms in Go (which uses `Seek`) and 117 ms in Rust.
  - The input must sit in memory, below 2 GiB (P0-1), and RSS is input + copy + payload views: 194 MiB for a 64 MiB archive against Go's 70 MiB.
- **P1-8 Large writes.** `write big64MiB x10` takes 229 ms in Pion, 64 ms in Go and 73 ms in Rust. `write_data` does `data.to_string()` and then appends it, and `finish` does `to_string()` and then `to_bytes()`.

## P2 notes

- **P2-1 `+` sign.** The corpus files `pax-size-plus-sign`, `pax-uid-plus-sign`, `pax-mtime-04` (`+5`), `pax-reclen-plus-sign` and `sparse-pax-1.0-plus-count` are all accepted by Go and rejected by Pion. This is leniency parity only; no known writer emits these.
- **P2-2 GNU fallback.**
  - Pion reuses the post-fallback format (`Unknown`) for the `'S'` check (`src/reader.pion:827`). Go re-checks the raw block magic.
  - Seen in the mutation sweep as the dominant `sparse-old-*` and `gnu-incremental` differences: a mutated byte in 345–368 (atime/ctime).
- **P2-3 Default limits.** In the diff section, 10 archives match Go under Go-like limits but stop early under `Limits::default()`:
  - `gnu-incremental` and `gnu-sparse-big` / `pax-sparse-big` from Go's own testdata
  - `writer-big*`: Go returns the 16 GiB header first
  - 5,000 PAX records, 70,000 fragments, 1 TiB sparse

  Separately, `read_all` of 100,001 empty files fails with `archive exceeds max_entries`. These are policy trade-offs, but the README presents the defaults as production-safe without saying they refuse ordinary large archives such as source trees with more than 100k files, VM images or anything over 256 MiB.
- **P2-4 to P2-6 Writer byte-level parity.** 303 header specs are written one archive each by Go and by Pion. 290 are byte-identical. The others are:
  - P1-1: 4 cases
  - P2-6: 4 cases
  - P2-5: 1 case
  - P2-4: 2 cases accepted by Pion where Go errors
- **P2-7 Format labels.** `Header.format` uses its own V7 and STAR variants, so it is a different API from Go's `Format`. The mixed L+PAX case is a plain mismatch.
- **P2-8 Windows hazards.** No traversal bypass was found; see the passes below. The remaining issues are Windows-host hazards only.
  - `clean_extract_path` also rewrites `\` to `/` on every OS, so `a\b` and `a/b` collide on Unix, where `\` is an ordinary filename byte.
  - No test covers this.

## What passed (fairness)

- **Go's own `archive/tar/testdata`.**
  - All 44 archives (base64 and bz2 decoded) read identically in Go and Pion: every header field, every PAX record and xattr, the FNV of every payload, and the error position.
  - The only exceptions are the V7/STAR format labels (P2-7).
- **Adversarial corpus.** 110 hand-built archives cover:
  - USTAR 100/155/256 splits; `x`/`g` override, inheritance and clearing
  - non-UTF-8 names; −0.5 / −1.25 / −1.5 PAX times; base-256 numbers and 9 GiB sizes
  - all 4 sparse formats, including multi-extension blocks, tail holes, overlap, disorder, missing/extra data and 1 TiB realsize
  - signed checksums; one vs two zero blocks; trailing garbage; truncated padding

  With the Format field ignored, only the 9 archives listed under P1-2/3/5 and P2-1 differ.
- **Truncation sweep.** 412,948 prefixes at stride 1 (archives ≤ 20 KiB) plus 11,996 at stride 509 (≤ 2 MiB): **0 crashes, 0 new differences.** Every truncated input ends in the same `EOF` / `ERR next` / `ERR data` as Go.
- **Mutation sweep.** 2 seeds × 292,000 mutants, with checksums re-stamped two-thirds of the time: **0 crashes.** Every difference traces to P1-2, P2-2, or Go's own nondeterminism:
  - Go's `mergePAX` on a global header with an invalid value returns early in random map order and leaves `PAXRecords`/`Name` unset (`pax-global-records`, `pax-global-then-x-then-file`).
  - Pion is the deterministic one there, so these are not counted against it.
- **Interop.**
  - A Rust-written archive (GNU long names, long links, base-256 uid, PAX path/xattr/sub-second mtime/size override, devices) reads identically in Go and Pion.
  - Go re-reading Pion-written archives differs only in P1-1 and P2-5.
  - Rust reads the Go-written and the Pion-written spec archives the same way. Both stop at the same entry: Rust treats a directory's 16 GiB size field as payload. The tail length differs only because the bytes it swallows contain the P1-1 and P2-5/6 differences.
- **`clean_extract_path`.** It rejects `..` anywhere, `a/b/..`, leading `/` and `\`, `//server/share`, `\\server\share`, `C:foo`, `c:\x`, NUL, empty, `.` and `./` (`control_clean_extract_path_blocks_classic_traversal`). No bypass was found. Link targets are not checked, as in Go; extractors must handle symlink escapes.
- **Performance where Pion is ahead.**

  | Workload | Pion vs Go |
  | --- | ---: |
  | header scan, mixed corpus | 1.53× faster |
  | header scan, 100k tiny files | 2.01× faster |
  | header scan, long PAX paths | 1.96× faster |
  | full read, mixed corpus | 1.18× faster |
  | full read, 100k tiny files | 1.81× faster |
  | write, 100k tiny files | 1.18× faster |
  | write, xattr ×32 | 1.09× faster |
  | write, long paths | 1.61× faster |

  Peak RSS is lower than Go's on small-entry workloads.

## Benchmark fairness of `packages/tar/bench/`

1. **The read benchmark skips the payload work the others do.**
   - `pion_read` takes `read_data()` (a zero-copy slice) and touches only `body[0]` and `body[len-1]`.
   - `go_read` copies every payload with `io.ReadFull` into a buffer, and `rust_read` does `read_to_end`.
   - Hashing every payload byte in all three (`readbench` here) cuts Pion's lead on the same corpus from 1.49× to 1.18×.
2. **The workload hides the weak cases.** The only workload is one 6 MB corpus of small entries (2,000 entries, about 1.9 KB average payload), which rewards per-header overhead. Pion's weak cases are absent:

   | Workload | Pion vs Go |
   | --- | ---: |
   | one 64 MiB file, header scan | 0.03× |
   | one 64 MiB file, write | 0.28× |
   | one 64 MiB file, full read | 0.86× |
   | 32 xattrs per entry, read | 0.78× |
   | 32 xattrs per entry, scan | 0.85× |
   | PAX 1.0 sparse, scan | 0.33× |
   | PAX 1.0 sparse, read | 0.87× |
   | 4,000 PAX records per header, read | 0.01× |
   | 4,000 PAX records per header, write | 0.04× |
3. **Memory is not compared.** Peak RSS is reported but not discussed. Pion holds input + `String` copy (+ the `StringBuilder` and its `String` + `Bytes` copies on write): 194 MiB against 70 MiB for a 64 MiB read.
4. **The rest of the benchmark is sound.** The write benchmark's round-trip verification is the same in all three, pre-sizing is comparable (Go and Rust `Grow` 6 MiB, Pion `write_all` estimates), and the SHA-256 stdout check is real.

### Full table (`run_audit.sh` bench section, `--warmup 1 --rounds 5`, interleaved, median ms / peak RSS)

| Workload | pion | go_tar | rust_tar | pion vs go |
| --- | ---: | ---: | ---: | ---: |
| scan mixed ×20 | 51.0 / 13.7 MiB | 78.2 / 19.6 MiB | 44.1 / 7.8 MiB | 1.53× |
| scan tiny100k ×3 | 187.8 / 197 MiB | 376.7 / 202 MiB | 136.4 / 100 MiB | 2.01× |
| scan big64MiB ×100 | **559.7** / 130 MiB | 18.3 / 70 MiB | 116.6 / 66 MiB | **0.03×** |
| scan longname ×5 | 151.5 / 80 MiB | 297.8 / 87 MiB | 169.4 / 41 MiB | 1.96× |
| scan xattr32 ×10 | 444.2 / 41 MiB | 376.9 / 103 MiB | 516.3 / 21 MiB | 0.85× |
| scan paxrecs4000 ×1 | **13 100.6** / 48 MiB | 125.0 / 55 MiB | 141.5 / 25 MiB | **0.01×** |
| scan sparse ×10 | 152.1 / 204 MiB | 50.2 / 126 MiB | — | 0.33× |
| read mixed ×20 | 125.9 / 14.0 MiB | 149.2 / 20.3 MiB | 117.8 / 7.8 MiB | 1.18× |
| read tiny100k ×3 | 206.3 / 197 MiB | 373.7 / 201 MiB | 136.6 / 100 MiB | 1.81× |
| read big64MiB ×3 | 247.3 / 194 MiB | 212.5 / 70 MiB | 223.6 / 196 MiB | 0.86× |
| read xattr32 ×10 | 413.7 / 41 MiB | 323.3 / 50 MiB | 500.8 / 21 MiB | 0.78× |
| read sparse1.0 ×1 | 490.1 / 205 MiB | 425.7 / 109 MiB | — | 0.87× |
| write tiny100k ×3 | 210.0 / 384 MiB | 248.2 / 560 MiB | 95.6 / 166 MiB | 1.18× |
| write big64MiB ×10 | **228.9** / 258 MiB | 63.5 / 392 MiB | 73.5 / 131 MiB | **0.28×** |
| write xattr32 ×10 | 383.8 / 145 MiB | 418.8 / 138 MiB | — | 1.09× |
| write longname ×5 | 177.5 / 164 MiB | 286.0 / 219 MiB | — | 1.61× |
| write paxrecs4000 ×1 | **6 923.2** / 232 MiB | 266.4 / 242 MiB | — | **0.04×** |

- **Rust columns.** Rust is omitted for sparse (it does not read PAX sparse) and for PAX-heavy writes (its PAX bytes differ in size, so the stdout check would fail).
- **What the read workloads hash.** `read*` hashes every payload byte with FNV-1a in all three, so `read big64MiB` mostly measures the hash loop plus Pion's extra copy.
