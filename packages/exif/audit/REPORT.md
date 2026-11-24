# Red-team audit: `packages/exif` v0.1.0

- **Target**: `origin/feat/pkg-exif` @ `3408202f7b80c74af31a42c51db0a1bc0ac47930`. Audited: `packages/exif/src/{types,container,tiff,tags,exif_test}.pion`, `bench/`, `wasm_smoke/`, `README.md`.
- **Deliverable**: `packages/exif/audit/` only (branch `audit/pkg-exif`). No file outside `audit/` was changed.
- **Reproduce**: `sh packages/exif/audit/run_audit.sh`. It takes about 30 s warm and needs no network once the cargo registry holds `kamadak-exif 0.6.2`. Sections: `build cases unit diff adv trunc fuzz dos portability smoke bench harness`.
- **Exit status**: `1` while any P0 condition reproduces, `0` otherwise. Open P1/P2 findings are printed as `OPEN` and fail the run only with `STRICT=1`.
  - P0 conditions are: a crash, trap or hang on any input; a silent value deviation from kamadak-exif on well-formed input; any native/wasm32 or debug/release divergence; a failing `control_*` case; a P0 DoS budget breach; a portability gate; a `wasm_smoke` hash that differs from `README.md`; or bench output that is not byte-identical.
  - The fixes for P1/P2 must make the `redteam_*` cases pass **without editing `audit/`**.
- **Toolchain used**: pionc 0.1.0 (arm64_apple, self-hosted), node v24.22.2 (`pion_wasm_rt.mjs`), cargo 1.100.0 + `kamadak-exif` 0.6.2 (locked `Cargo.lock`), python3 stdlib, macOS arm64.

## Verdict

| Severity | # | Summary |
|---|---|---|
| **P0** | **0** | No crash, trap, hang, OOB or silent value deviation. Covered: 37 well-formed files, 209 adversarial files, 6 755 truncations and 10 000 mutants, each in all 4 modes. Gates verified with injected bugs (`harness`). |
| **P1** | 2 | **P1-1**: one field of an unknown TIFF type (TIFF 6.0 says skip it) fails the whole parse, so Orientation is lost. **P1-2**: the README `1.01x` only holds on a 0.6 KB/file corpus. With a camera-sized 30 KB MakerNote Pion runs at **0.49–0.55x** of kamadak because UNDEFINED is copied byte by byte. A one-line `Bytes::slice` fix measures **1.61x**. |
| P2 | 6 | P2-1 thumbnail sub-IFDs are reported as the primary image's. P2-2 no JPEG marker resync. P2-3 decoded memory is ~8x `max_payload_bytes`. P2-4 `format_canonical` is O(n²). P2-5 one corrupt sub-IFD entry fails the whole parse. P2-6 spec/API/doc nits (Interop pointer in IFD0, "cyclic" label on shared IFDs, "zero-copy" extract that copies, non-`Send` results, canonical output not cross-language-stable for FLOAT/DOUBLE/non-UTF-8 ASCII, O(n) visited set, missing `BENCHMARKS.md` / `index/` entries). |

`run_audit.sh` exit status on the baseline: **0** (`AUDIT PASS (0 P0)`, 10 OPEN lines for P1-1, P1-2, P2-1…P2-5).

### What holds (all measured, all 4 modes: native debug / native release / wasm32 debug / wasm32 release)

- **Differential vs kamadak-exif 0.6.2**: 37/37 well-formed files decode identically, field by field. Corpus:
  - all 12 types in LE and BE, inline at 1/2/3/4 bytes (left-aligned in BE) and external;
  - extreme values: `LONG 0x80000000/0xFFFFFFFF` (never sign-extended), `SLONG INT32_MIN`, `SRATIONAL INT32_MIN/-1`, `0/0` and `1/0`, binary32 sNaN/qNaN payloads, ±0, subnormals, ±inf, `FLT_MAX`, binary64 NaN payloads;
  - ASCII without NUL, with embedded NULs, NUL-only, bytes ≥ 0x80, count 0;
  - camera layouts IFD0/ExifIFD/GPSIFD/InteropIFD/IFD1 with N/E and S/W GPS below sea level;
  - an 8-IFD chain, 1000-element arrays, unaligned and odd IFD offsets, duplicate/unsorted tags;
  - JPEG with APP0+XMP+COM+DQT, 50×`FF` fill and two EXIF APP1;
  - WebP with VP8X/ICCP/ALPH/VP8L, an odd padded chunk and an odd last chunk without pad;
  - PNG `eXIf` before and after IDAT;
  - kamadak's own test images (`exif.jpg/.tif/.png/.webp`, `yaminabe.tif`, `yaminale.tif`).
  
  The accessors are checked too. `orientation`, `gps_coords`, `gps_altitude` and `color_space` must equal values derived independently from kamadak's fields (`compare.py expected_acc`).
- **Adversarial**: 195/209 behave as a correct parser must; the other 14 are P1-1 / P2-1, listed below.
  - **JPEG**: segment length 0/1/2/past EOF; APP1 holding only `Exif\0\0`; 1000 fill bytes; RST0–7/TEM before APP1; EOI first; `FFE1 Exif` after SOS and inside `FF00`-stuffed entropy data (both ignored: `NotFound`; kamadak wrongly accepts the first); first of two EXIF APP1 wins; 65535-byte segment.
  - **WebP**: RIFF size 3/4/`0xFFFFFFFF`/short; chunk size `0xFFFFFFFF`/`0xFFFFFFFE`/`0x7FFFFFFF` (no 32-bit wrap); EXIF with and without `Exif\0\0`; truncated header.
  - **PNG**: `eXIf` length `0x80000000`/`0xFFFFFFFF`; `eXIf` after IEND (ignored; kamadak accepts it); bad signature; truncated chunk.
  - **Auto-detect**: raw APP1 payload, TIFF magic 43, `IM` byte order, RIFF/AVI, PNG signature followed by TIFF.
  - **IFD structure**:
    - rejected: IFD0 offset 0/4/`0xFFFFFFFF`; self loop, mutual loop, ExifIFD → IFD0, ExifIFD next → IFD0, ExifIFD and GPSIFD sharing one offset;
    - tolerated: SHORT / count-2 / type-13 / zero sub-IFD pointers.
  - **Orientation**: `0`/`9`/`65535`/ASCII/count 0/IFD1-only → `None`; LONG 7 → 7; LONG `0x80000006` → `None`; first duplicate wins.
  - **Counts**: `0xFFFFFFFF`, `0x80000000`, `0x40000000`, `0x20000000` (wraps to 0 in 32-bit) and `0x1FFFFFFF` × {BYTE, SHORT, LONG, RATIONAL, DOUBLE, SRATIONAL} are all rejected with `LimitExceeded` before any allocation.
  - **GPS**: `0/0`, `1/0`, lat > 90, lon > 180, lat `0xFFFFFFFF/1`, missing/invalid/empty/BYTE-typed refs, 2-component and SRATIONAL latitude all → `None`; exactly 90° S accepted; AltitudeRef 1 negates, 2 → `None`, missing → positive, denominator 0 → `None`.
- **Truncation and fuzz**: every byte prefix of six seeds (6 755 files) and 10 000 LCG mutants (bit/byte/interesting-u16/u32/insert/delete/duplicate/splice) produced 0 crash, 0 trap and 0 timeout in all 4 modes. All 4 modes are byte-identical on every record. Against kamadak, every remaining difference falls into a documented class: P1-1 459, P2-2 30, and Pion being stricter or more lenient on pointers, CRC and IFD0 offset 0. There are **0 unexplained value differences**.
- **DoS**: 14 bombs, all within the P0 budget (≤ 250 ms/parse, ≤ 256 MiB, expected verdict).
  - 65 535 entries, 33/1000-IFD chains and count `0xFFFFFFFF` are rejected in < 10 µs.
  - 500 × 50 KB overlapping UNDEFINED fields stop at 4 MiB (`LimitExceeded`).
  - The worst accepted input is a 50 KB JPEG: 12.6 ms and 34.9 MiB (P2-3). kamadak needs 136.5 MiB on the same file.
- **Controls (6/6 pass, all 4 modes)**:
  - Orientation 1–8: the `cw_degrees` + `flip_horizontal` decomposition is checked against the TIFF 6.0 / EXIF Orientation row/column table for two pixels, plus `swaps_dimensions`, `from_int` rejections and numeric edges.
  - `ExifLimits` exact boundaries (payload 106 OK / 105 rejected; IFD/entry limits); negative and `INT_MAX` limits fail closed or work.
  - Full prefix + XOR sweep of a 3-IFD JPEG under 4 limit sets with no panic; `extract_*` equals in-place parse; shared sub-IFD rejected.
- **Portability**: 0 `extern "C"`, 0 `World`, 0 `import`, 0 `[dependencies]`, 0 module-level mutable bindings (4 immutable `Int` constants). `wasm_smoke` gives the same line in all 4 modes, with sha256 `87f92b30…98ffa` equal to `README.md`. `pionc fmt --check`, `pionc check` and `pionc test` (10/10) pass on `packages/exif`.
- **Bench integrity**: `run_bench.sh` reproduces 1.07–1.09x on the shipped corpus. Its stdout sha256 `aa3f9fec…6218830` equals `README.md`. Both sides really parse every file each iteration (Rust's `fields().count()` forces kamadak's lazy value decoding). No skipped work and no unfair Rust-side overhead was found. The problem is the corpus (P1-2).

## Findings

### P1-1 An unknown field type aborts the whole parse (Orientation lost)

- **Where**:
  - `tiff.pion:395-398`: `elem_size == 0` → `return Err(InvalidValue("unsupported TIFF type …"))` for the whole TIFF;
  - also `tiff.pion:295` (`decode_field_value` `_ =>` arm).
- **Spec**: TIFF 6.0 §2, IFD entry *Type*: "Readers should skip over fields containing an unexpected field type." EXIF 2.32 inherits TIFF's IFD rules. libtiff, ExifTool and kamadak-exif skip such fields (kamadak keeps them as `Value::Unknown`).
- **Effect**: any entry of type 0, 14, 16–18 (BigTIFF LONG8/SLONG8/IFD8) or 0xFFFF fails the whole parse. It does not matter whether the entry is in IFD0, ExifIFD, GPSIFD or IFD1. `parse` returns `Err`, so `orientation()` and every other field are lost, and a correctly rotated photo is displayed unrotated.
  - Type-0 entries in ExifIFD are a known real-world defect: ExifTool's frequent warning "Bad format (0) for ExifIFD entry N".
- **Reach**: with default limits. A single 12-byte entry anywhere in the TIFF block is enough. In the fuzz run, 459 of 10 000 mutants (4.6 %) that kamadak parses are rejected only for this reason.
- **Minimal repro** (LE TIFF, 38 bytes):

  ```
  49 49 2A 00 08 00 00 00 02 00
  12 01 03 00 01 00 00 00 06 00 00 00
  00 C0 00 00 01 00 00 00 01 02 03 04
  00 00 00 00
  ```

  Pion returns `Err(InvalidValue)`; kamadak returns 2 fields, Orientation 6.
- **Evidence**: `redteam_p1_1_unknown_type_in_ifd0_skipped` (types 0/14/16/0xFFFF, LE and BE), `redteam_p1_1_unknown_type_in_exif_ifd_keeps_orientation` (raw TIFF and JPEG), `adv/tiff_unknown_type_*` (12 files), fuzz class `pion_err_unknown_type`.
- **Fix**: when `elem_size == 0`, skip the entry. Do not decode it, do not read its offset, and do not charge it to `max_payload_bytes`. Still count it toward `max_total_entries`. Optionally keep it as an opaque `FieldValue::Unknown(type, count)` like kamadak.
  - **Side effects**: none for the limits. The entry occupies only its 12 directory bytes, which are already bounds-checked by `dir_bytes`.

### P1-2 The `1.01x` benchmark claim only holds on an unrepresentatively small corpus; UNDEFINED is copied byte by byte

- **Where**:
  - the copy loops: `tiff.pion:235-243` (`FieldValue::Undefined`) and `container.pion:3-11` (`slice_bytes`, used by `extract_from_*`);
  - the claim: `README.md:57-61`;
  - the corpus: `bench/gen_corpus.py`.
- **The corpus**:
  - It is 4 files of 548–886 B (2 619 B total).
  - It uses only 6 of the 12 types (ASCII, SHORT, LONG, RATIONAL, BYTE, UNDEFINED). The only UNDEFINED value is the 4-byte ExifVersion.
  - It has no MakerNote, no thumbnail, no FLOAT/DOUBLE/SBYTE/SSHORT/SLONG/SRATIONAL.
  - Camera JPEGs carry 1.5 KB (iPhone) to 30+ KB (Nikon/Canon/Sony) of MakerNote plus a ~10 KB IFD1 thumbnail.
- **Measured**: the same shipped `pion_exif` / `rust_kamadak` binaries and `bench_compare.py` protocol (warmup 1, rounds 5, interleaved, stdout sha256 verified identical), on `diff/gen_bench_real.py` corpora with the same 4 file names. The corpus is IFD0 12 / ExifIFD 38 / GPS 14 / Interop 2 / IFD1 6 tags, an 11 KB thumbnail, and a JPEG with XMP + ICC + 256 KB scan.

  | Corpus | pion ns/op | kamadak ns/op | speedup |
  |---|---:|---:|---:|
  | shipped (0.65 KB/file) | 1 546 | 1 647 | 1.07x |
  | camera, MakerNote 1.5 KB | 4 861 | 4 697 | **0.97x** (0.97–1.03x across runs: parity) |
  | camera, MakerNote 30 KB | 14 285 | 7 029 | **0.49x** (0.53–0.55x in other runs) |
  | same, with the one-line fix below | 4 413 | 7 100 | **1.61x** |

- **Bench fairness**: no cheating found (see "Bench integrity" above). The issue is that the claim is published from a corpus that avoids Pion's slow path. It is not a security issue.
- **Fix**:
  - `7 => Ok(FieldValue::Undefined(data.slice(val_pos, val_pos + count)))`, using the runtime `memcpy` (`pion_bytes_slice`), and the same in `slice_bytes`. This was measured above: the output sha256 is unchanged and 3x faster on the 30 KB corpus.
  - Consider `FieldValue::Byte(Bytes)` (see P2-3).
  - Re-measure the README/`BENCHMARKS.md` table on a camera-sized corpus and record the losing rows as AGENTS.md §1.3 requires.

### P2-1 The thumbnail's ExifIFD/GPSIFD is reported as the primary image's

- **Where**:
  - `types.pion:91-98`: `Ifd::Exif` / `Gps` / `Interop` carry no IFD index;
  - `tiff.pion:420-441`: pointers are honoured from `Ifd::Primary | Ifd::Thumbnail` alike and queued as `Ifd::Exif` / `Ifd::Gps`;
  - `tags.pion:167-172` (and every `get(Ifd::Exif|Gps, …)` accessor): first match wins.
- **Effect**: when IFD1 carries an ExifIFD pointer, its fields become indistinguishable from the primary ExifIFD in `fields()` and `format_canonical`. kamadak reports them as `In(1)`. If IFD0 has no ExifIFD, `color_space()`, `pixel_x_dimension()`, `exposure_time()` and `gps_coords()` return the **thumbnail's** values for the primary image.
- **Evidence**: `redteam_p2_1_thumbnail_exif_ifd_not_reported_as_primary` (`color_space()` = 65535 from IFD1, want `None`), `adv/ifd1_exif_subifd_{le,be}.tif`.
- **Fix**: give sub-IFDs their parent index (e.g. `Ifd::Exif(n)` or a `parent` field), and have the primary accessors look up parent 0 only. Alternatively, do not follow sub-IFD pointers from IFD1.

### P2-2 No JPEG marker resynchronisation

- **Where**: `container.pion:65-67`. A non-`FF` byte where a marker is expected returns `InvalidFormat`.
- **Effect**: libjpeg's `next_marker` skips stray bytes ("Corrupt JPEG data: N extraneous bytes before marker"), so every libjpeg-based viewer and browser shows such files, rotated correctly. kamadak-exif resyncs too. Pion drops the EXIF.
- **Evidence**: `redteam_p2_2_jpeg_stray_bytes_before_marker_tolerated` (APP0, `00 00`, APP1), `adv/jpeg_garbage_between_segments.jpg`, fuzz class `pion_err_jpeg_no_resync` (30).
- **Fix**: before SOS, scan forward to the next `FF` (bounded by the file) instead of failing. Keep the stop at SOS, which is correct and safer than kamadak's scan past SOS.

### P2-3 Decoded memory is not bounded by `max_payload_bytes`

- **Where**:
  - `tiff.pion:400-404`: only declared input bytes are charged;
  - `tiff.pion:119-154`: one `String` per NUL-separated ASCII piece;
  - `tiff.pion:164-175`: BYTE → `Array[Int]`;
  - `tiff.pion:177-187`: SHORT → `Array[Int]`.
- **Effect**: overlapping value offsets are legal, so a 50 KB JPEG can declare 4 095 × 1 KiB fields that all point at the same block, keeping the total at 4 MiB = `max_payload_bytes`.
  - With ASCII NULs this becomes 4.2 M empty strings: **34.9 MiB peak RSS, 12.6 ms**.
  - As BYTE it is 18.8 MiB; a 1 MiB NUL ASCII in a raw TIFF needs 15.1 MiB.
  - It is bounded, and kamadak needs 136.5 MiB on the same file, but the README presents `max_payload_bytes` as the memory guard.
- **Evidence**: `dos.py` advisory budget (16 MiB for inputs < 64 KiB) on `overlap_ascii_nul_4mib.jpg` and `overlap_byte_4mib.jpg`.
- **Fix**:
  - Charge the decoded size: e.g. 16 B per array element and per ASCII piece, or cap the number of ASCII pieces per field.
  - Store BYTE/SBYTE as `Bytes`.
  - Document the actual bound.

### P2-4 `format_canonical` is O(n²)

- **Where**: `tags.pion:607-627`, an insertion sort over up to `max_total_entries` (4 096) fields.
- **Effect**: on a 49 KB TIFF with 4 096 tags in descending order it takes **52.8 ms**, against 0.17 ms for ascending order.
- **Fix**: a stable O(n log n) merge sort on `(rank, tag, index)`.

### P2-5 One corrupt sub-IFD entry fails the whole parse

- **Where**:
  - `tiff.pion:366-368`: a dangling sub-IFD offset gives `UnexpectedEof`;
  - `tiff.pion:410-413`: a value offset out of bounds gives `InvalidValue`;
  - `tiff.pion:380-382`: a truncated sub-IFD.
- **Effect**: a MakerNote whose offset points past a truncated APP1, or a dangling GPS pointer, makes `parse` return `Err`. IFD0's intact Orientation is then unavailable.
  - This is the same default as kamadak (which offers `continue_on_error`).
  - Orientation readers that stop at IFD0 still rotate such files.
- **Evidence**: `redteam_p2_5_corrupt_subifd_keeps_ifd0_orientation`, `adv/tiff_value_oob_in_exif_*`, `adv/tiff_gps_ptr_oob_*`.
- **Fix**: a partial-result mode (skip the broken entry or sub-IFD and report it), or at least an `orientation`-only fast path that parses IFD0 alone.

### P2-6 Spec, API and documentation nits

1. **InteropIFD pointer honoured in IFD0** (`tiff.pion:442-452`, `Ifd::Exif | Ifd::Primary`). EXIF defines `0xA005` as an Exif IFD attribute. kamadak treats it as a plain IFD0 tag. Harmless, but it diverges.
2. **Shared sub-IFD reported as "cyclic"** (`tiff.pion:360-362`). Rejecting a second visit is fine: kamadak does the same, and it bounds the work. The message and README line 22 ("self-loops and mutual cycles") should say that shared IFDs are rejected as well.
3. **"zero-copy … container extraction"** (`README.md:3`): `extract_from_{jpeg,webp,png}` copies byte by byte (`container.pion:3-11, 189-211`). Only `parse*` is zero-copy.
4. **Results are not `Send`**: `exif::parse(..)` results cannot cross `spawn` (`E_NOT_SEND`; `Exif.entries : Array`, `Undefined(Bytes)`). `ExifLimits` and `Orientation` are `Send`. AGENTS.md §1.1 asks for immutable `Send` public values where possible.
5. **`format_canonical` is not cross-language-stable** (`tags.pion:574-593, 483-492`). The doc says "byte-for-byte cross-language SHA-256 verification" (`tags.pion:598`).
   - FLOAT is printed as the widened binary64: `0.10000000149011612`, where Rust prints `0.1`.
   - FLOAT/DOUBLE extremes print as `1e+21` / `nan`, where Rust prints `1000000000000000000000` / `NaN`.
   - Non-UTF-8 ASCII is printed raw, where the bench's Rust side uses `from_utf8_lossy`.
   - Demonstrated by running the shipped bench binaries on `types_ext_le.tif`: stdout sha256 differs (`7db913d2…` vs `a1b095a2…`). The shipped corpus avoids all three.
   - ASCII values are raw bytes (possibly invalid UTF-8; `tiff.pion:106-117`). The wasm32 host's `io_print` replaces them with U+FFFD, so document this for consumers.
6. **Visited-IFD check is linear** (`tiff.pion:299-309, 360, 490`), O(`max_ifds`²). Trivial at the default 32, but a caller-raised `max_ifds` makes it quadratic. kamadak uses a `HashSet`.
7. **Process (AGENTS.md §1.3/§1.4)**: no `exif` row in the root `BENCHMARKS.md` and no `index/exif.toml` on this branch.

Accepted divergences (not findings, documented by the fuzz classes):

- **Pion is stricter**: it stops at SOS; it ignores `eXIf` after IEND; it requires the 4-byte CRC of `eXIf`; it rejects IFD0 offset 0, where kamadak returns 0 fields.
- **Pion is more lenient**: it skips zero / count≠1 / non-LONG sub-IFD pointers and ignores sub-IFD next pointers, where kamadak errors; it accepts WebP `EXIF` with an `Exif\0\0` prefix; it decodes type 13 (IFD, TIFF TN1) as LONG, where kamadak keeps it Unknown.
- **Duplicate tags**: Pion's accessors use the first occurrence; kamadak's `get_field` uses the last. Both keep every entry in `fields()`.

## Layout

```text
audit/
  REPORT.md                 this report
  run_audit.sh              one-shot runner (exit 1 = P0 reproduced; STRICT=1 also fails on open P1/P2)
  pion.toml, src/main.pion  exif_audit CLI: dump | dumplist | time | canon | list | case (native + wasm32)
  src/dump.pion             bit-exact record format (hex ASCII/UNDEFINED, binary64 bits for FLOAT/DOUBLE)
  src/cases.pion            redteam_* (findings) and control_* cases + a small TIFF writer
  redteam_test.pion         pionc test wrappers of redteam_* (FAIL on the baseline)
  control_test.pion         pionc test wrappers of control_* (must PASS)
  diff/gen.py               deterministic corpus: diff / adv (+ manifest.json expectations) / trunc / fuzz / dos
  diff/compare.py           crash-isolating batch runner + diff / adv / fuzz / cross-mode checkers
  diff/dos.py               DoS budgets (verdict, ms/parse, peak RSS)
  diff/gen_bench_real.py    camera-sized corpus for the bench fairness probe (P1-2)
  diff/oracle/              Rust kamadak-exif 0.6.2 oracle (Cargo.lock pinned), same record format
```
