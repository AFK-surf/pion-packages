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
  - Explicit `GitLimits { max_object_bytes, max_pack_entries, max_delta_depth, max_delta_result_bytes, max_tree_entries, max_index_entries }`.
  - Rejects path traversal (`..`, `.`, `.git`/`.GIT`, absolute paths, NUL, `//`), truncated varints, corrupt SHA-1 trailers, delta bombs, and cyclic delta chains.

## Verification

- **Unit & Real `git` CLI Fixture Suite**: `sh scripts/verify.sh packages/git` — **25/25 `git` tests PASS** (257/257 total with `flate`/`crypto`/`diff`, 0 failures, `fmt --check`, `check --json`, clean worktree).
- **4-Mode `wasm_smoke` (`packages/git/wasm_smoke`)**: All 4 build modes (Native debug/release + Wasm32 debug/release, each with isolated clean `PION_CACHE_DIR`) exit `0` with byte-identical stdout:
  - `sha256: 722ac87d312b6e35dc2f06fd514c83636016a05474b35a2bd705a7f0795e6d48`

## Head-to-Head Benchmarks vs Rust `gix` (`--release --locked`)

Run on `Darwin arm64` via `sh packages/git/bench/run_bench.sh` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification).

Baseline: Rust `gix-object 0.46` + `gix-pack 0.56` + `gix-index 0.37` + `gix-packetline 0.18` (`--release --locked`).

| Workload | Pion Median (ms) | Rust `gix` Median (ms) | Pion Throughput | Rust Throughput | Pion Peak RSS | Rust Peak RSS | Ratio (vs `rust_gix`) | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| **W1**: Real Git Packfile v2 Full Unpack + `OFS_DELTA` Resolve + SHA-1 (x5 iters, 159.9 KB) | 41.187 | 23.905 | 3.88 MB/s | 6.69 MB/s | 4.33 MiB | 4.48 MiB | **0.58x** | `6375ce4b19dad182...` |
| **W2**: Large Tree (200×150 entries) + Commit (2,000) Parse & Re-encode (x3 iters, 5.35 MB) | 70.421 | 20.925 | 76.04 MB/s | 255.91 MB/s | 5.69 MiB | 4.02 MiB | **0.30x** | `cf3f4606e657d786...` |
| **W3**: `.git/index` v2 + v4 (2,000 files each) + 10,000 `pkt-line` Decode (x5 iters, 4.71 MB) | 17.475 | 7.479 | 269.65 MB/s | 630.02 MB/s | 5.23 MiB | 3.38 MiB | **0.43x** | `c3065f79872ee914...` |

### Honest Performance & Bottleneck Analysis

- **W1 (0.58x, lower Peak RSS)**: Pure Pion `zlib_inflate_at` + pure Pion `crypto::Sha1` achieves 58% of `gix-pack` (which uses `flate2`/`miniz_oxide` + `sha1_smol` + `memmap2`) while using slightly less memory (4.33 MiB vs 4.48 MiB). The main gap is pure-Pion SHA-1 hashing and inflate throughput vs LLVM-vectorized Rust.
- **W2 (0.30x)**: `Tree::encode` calls `a.name.to_bytes()` inside `tree_entry_compare` during O(N log N) merge sort, and `Tree::parse` / `Commit::parse` allocate per-entry `String`/`Bytes` slices rather than borrowing zero-copy slices (`gix_object::TreeRef`/`CommitRef`).
- **W3 (0.43x)**: `gix-index` packs all 2,000 entry paths into a single contiguous `Vec<u8>` arena and `gix-packetline::decode::streaming` borrows `&[u8]` slices with zero copies, whereas `packages/git` currently allocates owned `String` and `Bytes` per index entry / `pkt-line` frame.
