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

## Formal Verification (Lean 4)

Production `#verify` kernels (4 types, 19 functions, 0 externals) across `src/types.pion`, `src/object.pion`, `src/oid.pion`, `src/pktline.pion`, `src/refs.pion`, `src/index.pion`, and `src/delta.pion` are extracted via `pionc extract-lean` and formally verified in `packages/git/proofs/` (**22 theorems**, 0 `sorry`, 0 `admit`, 0 custom axioms, 0 `bv_decide`, 0 `native_decide`):

- **`GitProofs/WireAndRefs.lean` (11 theorems)**: `hex_nibble` exact range & ASCII hex specification, `pkt_line_decode_len` exact 16-bit big-endian assembly & injectivity, `pkt_line_classify_len` total partition (Flush / Delim / ResponseEnd / Data `4..65520` / Invalid), end-to-end `pkt_line_encode_decode_roundtrip` over `[0, 65516]`, `git-check-ref-format(1)` forbidden single-char & pair specs, `ObjectKind` pack-type bijection, and `FileMode::to_u32` injectivity.
- **`GitProofs/IndexAndDelta.lean` (11 theorems)**: `HashKind::byte_len` (20 / 32), `GitLimits::default` positivity & `git_limits_is_valid` iff characterization, `index_flags_stage` exact `[0, 3]` extraction, `.git/index` v2/v3 8-byte alignment (`index_v2_padded_len`, `index_v2_pad_bytes`, and encoder-decoder equivalence `index_v2_encode_decode_alignment_eq`), `delta_copy_size` roundtrip on `[1, 65536]`, and overflow-free `delta_copy_range_ok` bounds soundness.
- **Reproduce**: `packages/git/proofs/run_proofs.sh` (verifies extraction, static scan, `lake build`, `CheckAxioms.lean` standard-axioms-only check, and 39-case Native Pion vs Lean `EvalDiff` `diff -u` cross-check).

## Head-to-Head Benchmarks vs Rust `gix` (`--release --locked`)

Run on `Linux x86_64` via `sh packages/git/bench/run_bench.sh` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification) and noise-free per-process CPU time + Peak RSS (`os.wait4` `ru_utime + ru_stime` / `ru_maxrss`) comparing baseline `01ef1b7e` vs optimized `packages/git` vs Rust `gix`. W1 uses streaming single-pass unpacking (`PackStream::open` + `PackStream::next` with a 4 MiB bounded delta-base cache vs `gix-pack`'s `pack.entry(offset)` + `decode_entry` + LRU cache).

Baseline: Rust `gix-object 0.46` + `gix-pack 0.56` + `gix-index 0.37` + `gix-packetline 0.18` (`--release --locked`).

| Workload | Pion Baseline (ms) | Pion Optimized (ms) | Rust `gix` (ms) | Speedup vs Baseline | Ratio vs `rust_gix` | Peak RSS (Base → Opt vs `gix`) | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| **W1**: Synthetic Git Packfile v2 Full Unpack + `OFS_DELTA` Resolve + SHA-1 (x5 iters, 159.9 KB) | 83.2 | **62.1** | 37.0 | **1.34x** | **0.60x** | 12.9 → 12.9 MiB (vs 12.9 MiB) | `6375ce4b19dad182...` |
| **W1 (real pack)**: Real `.git` Packfile v2 (13.9 MB, 4,547 objs, 47.7 MB uncomp, x1 iter) | 1079.5 | **947.9** | 459.2 | **1.14x** | **0.48x** | **70.5 → 28.4 MiB (-60%)** (vs 18.4 MiB) | `9004fd3d2cb5a47d...` |
| **W2**: Large Tree (200×150 entries) + Commit (2,000) Parse & Re-encode (x3 iters, 5.35 MB) | 106.7 | **66.7** | 34.6 | **1.60x** | **0.52x** | 13.0 → 13.0 MiB (vs 13.0 MiB) | `cf3f4606e657d786...` |
| **W3**: `.git/index` v2 + v4 (2,000 files each) + 10,000 `pkt-line` Decode (x5 iters, 4.71 MB) | 67.4 | **34.6** | 8.5 | **1.95x** | **0.25x** | 13.0 → 13.0 MiB (vs 13.0 MiB) | `c3065f79872ee914...` |

### Key Optimizations & Honest Bottleneck Analysis

- **W1 (1.34x synthetic / 1.14x real pack, -60% Peak RSS)**: Added streaming `PackStream` with a 4 MiB bounded ring delta-base cache (slashing real-pack Peak RSS from 70.5 MiB to **28.4 MiB**), upgraded `zlib_inflate_at` to 10-bit/9-bit packed Huffman LUTs + 32-bit batch bitbuf refill + split fast/slow loops + 8-byte unrolled LZ77/RLE copies, unrolled `apply_delta` 8-byte copies, added inline Pass-1 `OFS_DELTA` resolution & lazy `oid_to_idx` in `PackReader::open`, and added a zero-bounds-check 4-way split struct-field-window SHA-1 (`src/sha1_fast.pion`). The remaining gap vs `gix` is primarily byte-wise `Bytes` indexing during SHA-1 64-byte block loads (`data[off + k]` bounds checks) vs Rust's unchecked slice/word loads.
- **W2 (1.60x speedup, 0.52x Rust `gix`)**: Eliminated per-entry `Bytes::slice`/`String` allocations for `FileMode`, combined duplicate + Git-order comparison into a single pass (`tree_name_cmp_strict`), unrolled `Tree::encode` writes, and rewrote `Commit::parse` (zero-copy byte header scanning + 256-entry hex LUT) and `Commit::encode` (single pre-sized `Bytes` allocation). The remaining gap is owned `String`/`Bytes` allocation per entry vs `gix_object::TreeRef`/`CommitRef` zero-copy borrowing.
- **W3 (1.95x speedup)**: Eliminated per-segment `String::slice` allocations in `validate_git_rel_path` / `validate_git_rel_path_bytes`, replaced COW `Bytes` with a reusable `FixedArray[Byte]` path buffer for v4 prefix-compressed paths, inlined 4-hex LUT decoding in `decode_pkt_lines` without per-frame `Result` tuples, and used `git_sha1_slice` for index trailer verification. The remaining gap vs `gix` is owned `String`/`Bytes` per entry/frame vs `gix-index`'s contiguous path arena and `gix-packetline`'s zero-copy `&[u8]` borrow.
