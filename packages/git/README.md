# `git` (`packages/git` v0.1.0)

100% pure Pion **Git Plumbing Core Engine** — zero `extern "C"`, zero `World` dependency, Native + `wasm32` dual-target compatible, built directly on in-repo [`packages/flate`](../flate), [`packages/crypto`](../crypto), and [`packages/diff`](../diff).

Modeled after Rust [`gix`](https://github.com/GitoxideLabs/gitoxide) (`gix-object`, `gix-pack`, `gix-index`, `gix-packetline`) and verified byte-for-byte against real `git` CLI (`git 2.54.0`) binary fixtures.

## Features

- **OID & Loose Objects (`src/oid.pion`, `src/object.pion`)**:
  - `Oid` supporting both SHA-1 (20B) and SHA-256 (32B): hex/raw codecs, zero check, lexicographical comparison, and short-hex prefix matching.
  - Streaming `hash_object_bytes` / `hash_object_sha1` over `<type> <size>\0<payload>`.
  - Loose object zlib encoding/decoding (`encode_loose_object`, `decode_loose_object`) with automatic OID verification and `GitLimits` enforcement.
  - Full structured object codecs:
    - `Blob`
    - `Tree` with **exact Git tree sorting** (directories compare with a virtual trailing `'/'`, e.g., file `a-b` sorts before directory `a`) and modes `40000` / `100644` / `100755` / `120000` / `160000`.
    - `Commit` (tree, multi-parent merges, `Signature` with signed timestamp & timezone offset, `encoding`, multiline `gpgsig`/`mergetag`/extra headers, message).
    - `Tag` (annotated tags with optional tagger and message).
- **Packfile v2 + `.idx` v2 + Delta Engine (`src/pack.pion`, `src/pack_idx.pion`, `src/delta.pion`, `src/zlib_stream.pion`)**:
  - Full Packfile v2 parsing (`PackReader::open`) and writing (`PackWriter`) with trailing SHA-1 verification.
  - All 6 entry types: `COMMIT`, `TREE`, `BLOB`, `TAG`, **`OBJ_OFS_DELTA`** (Git negative offset varint), and **`OBJ_REF_DELTA`** (20B base OID).
  - Zero-copy offset-aware zlib stream inflation (`zlib_inflate_at`) reusing `flate` primitives and a single scratch table per packfile.
  - Binary delta instruction decoder (`apply_delta`, copy 4+3 bit encoding, insert, reserved opcode `0x00` rejection) and hash-indexed delta encoder (`create_delta`).
  - Multi-level `OFS_DELTA` + `REF_DELTA` chain resolution with cycle detection and `max_delta_depth` / `max_delta_result_bytes` guards.
  - `.idx` v2 parser (`PackIndex::parse`, monotonic 256-entry fanout table, zero-alloc O(log N) `lookup`, 32-bit + 64-bit >2 GiB offset tables, trailer SHA-1) and canonical builder (`PackIndex::build` / `PackReader::build_idx_v2`, verified byte-identical to `git repack`).
- **Git Index `.git/index` v2 / v3 / v4 (`src/index.pion`)**:
  - Full `DIRC` v2, v3 (extended flags: `intent-to-add`, `skip-worktree`), and v4 (varint path prefix compression without 8-byte padding) parsing and byte-identical re-serialization.
  - Preserves extensions (`TREE`, `REUC`, `LINK`, etc.) and validates trailing SHA-1.
- **Wire Protocol `pkt-line`, Sideband-64k & Ref-Spec (`src/pktline.pion`, `src/refs.pion`)**:
  - Sans-IO `pkt-line` codec (`0000` Flush, `0001` Delim, `0002` ResponseEnd, `0004..fff0` Data, rejecting `0003` and `> 65520`).
  - Sideband-64k demultiplexing (Channel 1 pack data, Channel 2 progress, Channel 3 error).
  - Protocol v1 ref advertisement (`\0` capabilities, `^{}` peeled tags, `symref=`), Protocol v2 `ls-refs`, and `want`/`have`/`done` negotiation.
  - Complete `check_ref_format` enforcing all rules of `git-check-ref-format(1)`.
- **Security & `GitLimits` (`src/types.pion`)**:
  - Explicit `GitLimits { max_object_bytes, max_pack_entries, max_delta_depth, max_delta_result_bytes, max_tree_entries, max_index_entries, max_pack_total_bytes }` (default `max_delta_depth = 500`, aggregate `max_pack_total_bytes = 256 MiB` scaling with pack size for real large packs while capping small amplification bombs).
  - Enforces Git `fsck`-equivalent safety: strict tree sorting & non-adjacent duplicate rejection, `.git` NTFS/HFS+ aliases (`.git.`, `.git `, `GIT~1`, `.git::$INDEX_ALLOCATION`, HFS+ Unicode ignorables), symlinked `.gitmodules`/`.gitattributes`/`.gitignore`, commit/tag header ordering & smuggling protection, overflow-checked delta/OFS varints & `.idx` table offsets, and index extended-flag/required-extension/`name_len` validation.

## Verification

- **Unit & Real `git` CLI Fixture Suite**: `sh scripts/verify.sh packages/git` — **26/26 `git` tests PASS** (0 failures, `fmt --check`, `check --json`, clean worktree).
- **Adversarial Red-Team Suite (`packages/git/audit`)**: `pionc test --json --only-pkg packages/git/audit` — **40/40 PASS** (31/31 red-team defects fixed + 9/9 controls, 0 FAIL); `run_audit.sh --quick` confirms **2,038/2,038** records identical across all 4 build modes (`native_dbg`/`native_rel`/`wasm_dbg`/`wasm_rel`) with **0 diff / 0 crash / 0 trap**.
- **4-Mode `wasm_smoke` (`packages/git/wasm_smoke`)**: All 4 build modes (Native debug/release + Wasm32 debug/release, each with isolated clean `PION_CACHE_DIR`) exit `0` with byte-identical stdout:
  - `sha256: 722ac87d312b6e35dc2f06fd514c83636016a05474b35a2bd705a7f0795e6d48`

## Head-to-Head Benchmarks vs Rust `gix` (`--release --locked`)

Run on `Darwin arm64` via `sh packages/git/bench/run_bench.sh` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification). W1 uses a fair single-pass `gix-pack` decode loop (`pack.entry(offset)` + `decode_entry` advancing by `outcome.compressed_size`, inflating each entry once).

Baseline: Rust `gix-object 0.46` + `gix-pack 0.56` + `gix-index 0.37` + `gix-packetline 0.18` (`--release --locked`).

| Workload | Pion Median (ms) | Rust `gix` Median (ms) | Pion Throughput | Rust Throughput | Pion Peak RSS | Rust Peak RSS | Ratio (vs `rust_gix`) | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| **W1**: Synthetic Git Packfile v2 Full Unpack + `OFS_DELTA` Resolve + SHA-1 (x5 iters, 159.9 KB) | 39.470 | 17.805 | 4.05 MB/s | 8.98 MB/s | 4.36 MiB | 4.20 MiB | **0.45x** | `6375ce4b19dad182...` |
| **W1 (real pack)**: `pion-packages` own `.git` Packfile v2 (6.1 MB, x1 iter) | 221.075 | 110.195 | 27.81 MB/s | 55.79 MB/s | 48.50 MiB | 23.70 MiB | **0.50x** | `fade04aed0186d6f...` |
| **W2**: Large Tree (200×150 entries) + Commit (2,000) Parse & Re-encode (x3 iters, 5.35 MB) | 37.943 | 20.510 | 141.13 MB/s | 261.09 MB/s | 5.66 MiB | 4.00 MiB | **0.54x** | `cf3f4606e657d786...` |
| **W3**: `.git/index` v2 + v4 (2,000 files each) + 10,000 `pkt-line` Decode (x5 iters, 4.71 MB) | 17.577 | 7.895 | 268.08 MB/s | 596.83 MB/s | 5.25 MiB | 3.36 MiB | **0.45x** | `c3065f79872ee914...` |

### Honest Performance & Bottleneck Analysis

- **W1 (0.45x synthetic / 0.50x real 6.1 MB pack, ~2x Peak RSS on real pack)**: After removing the double-inflate overhead in the `gix` harness, pure-Pion `zlib_inflate_at` + pure-Pion `crypto::Sha1` runs at ~45–50% of `gix-pack` (`flate2`/`miniz_oxide` + `sha1_smol` + `memmap2`). Because `PackReader::open` materializes resolved objects in memory (while freeing raw delta payloads as they resolve and capping aggregate bytes via `max_pack_total_bytes`), peak RSS on the 6.1 MB real pack is 48.5 MiB vs `gix`'s streaming 23.7 MiB.
- **W2 (0.54x, improved from 0.30x)**: Replacing the allocating `name.to_bytes()` comparator with zero-allocation `code_unit_at` comparison plus an O(n) already-sorted fast path cut W2 median time from 70.4 ms to **37.9 ms** (**1.86x speedup**). The remaining gap is owned `String`/`Bytes` allocation per entry vs `gix_object::TreeRef`/`CommitRef` zero-copy borrowing.
- **W3 (0.45x)**: `gix-index` packs all 2,000 entry paths into a single contiguous `Vec<u8>` arena and `gix-packetline::decode::streaming` borrows `&[u8]` slices with zero copies, whereas `packages/git` allocates owned `String` and `Bytes` per index entry / `pkt-line` frame.
