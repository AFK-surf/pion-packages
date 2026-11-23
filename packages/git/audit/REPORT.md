# RT-git: adversarial audit of `packages/git` @ `4eab80e`

Auditor: independent red team `RT-git`. Target: `origin/feat/pkg-git` (`4eab80e`). The audit only adds files under `packages/git/audit/**`; `src/`, `*_test.pion`, `bench/` and `README.md` are unchanged.
References: real `git 2.54.0` (Apple Git-157) and Rust `gix` (`gix-object 0.46.1`, `gix-pack 0.56.0`, `gix-index 0.37.0`, `gix-packetline 0.18.4`, `gix-validate 0.9.4`). Toolchain: `pionc 0.1.0` (`AFK-surf/pion@79d1fbd`), Darwin arm64.

Reproduce everything with `sh packages/git/audit/run_audit.sh`. All output goes to `/tmp/rt-git-*`, and the worktree stays clean.

## 1. Verdict

`packages/git` gets real `git` right on the happy path. 3/3 real packfiles (6 MB, 33 MB and 56 MB) unpack to OID-identical object sets. `check-ref-format` agrees with git on 949/950 vectors, and every vector replays identically in all four build modes (native/wasm × debug/release). Against hostile input it falls short of `git`, and partly of `gix`:

* **P0: 2 reachable process aborts** (native `SIGABRT` rc=134, wasm32 trap) in the delta engine, each reachable through `PackReader::open`, i.e. by any peer that can send a packfile.
* **P1: 11 defects.** 1 abort that needs non-default limits; the tree-safety gaps git fsck exists for (unsorted/duplicate entries, `.git` NTFS/HFS aliases, symlinked `.gitmodules`); `Tree::encode` emitting git-invalid trees; commit header smuggling; a non-canonical OFS varint; unbounded memory amplification (~600,000×); and two interop breaks (depth > 50 packs, `\` in names).
* **P2: 16 conformance / round-trip / minor interop defects.**
* **Benchmarks.** README W1 uses a 32 KB synthetic pack. On real packs Pion is **0.51–0.70× gix and uses 2–5.3× its RSS**. W1 also makes gix inflate every entry twice, so the published gap understates the deficit. W2 loses about **half its tree time** to a comparator that allocates on every compare.

`packages/git/audit/redteam_test.pion` holds these defects as **31 currently-FAILING tests (4 `p0_` + 11 `p1_` + 16 `p2_`) and 9 PASSING `control_` tests**.

## 2. Findings

Severity: **P0** = crash/abort from untrusted bytes; **P1** = security parity or major interop vs git/gix; **P2** = spec conformance / round-trip / minor interop.
"git" means `git 2.54.0`. A git verdict comes from `hash-object` (built-in fsck), `fsck --strict`, `index-pack`, `verify-pack`, `ls-files` or `check-ref-format`.

### P0

| ID | Defect | Location | Evidence | git | gix |
| --- | --- | --- | --- | --- | --- |
| P0-1 | Delta copy bound check overflows 32-bit `Int`: `cp_off + cp_size > base_size` with `cp_off=0x7fffffff, cp_size=0x10000` wraps negative, the check passes, and `base[cp_off]` aborts (`index 2147483647 out of bounds`) | `src/delta.pion:151` | `p0_apply_delta_copy_offset_overflow_must_not_abort`, `p0_pack_open_copy_offset_overflow_must_not_abort`; difftest `delta` "copy off 0x7fffffff" = CRASH in 4/4 modes | rejects ("failed to apply delta") | **also panics** (gix-pack 0.56) |
| P0-2 | Delta header varint lets bit 31 through at shift 28: `target_size = 0xffffffff` decodes to `-1`, passes `> max_delta_result_bytes`, and `Bytes::new(-1)` aborts (`negative bytes length`) | `src/delta.pion:15-18,80-83` | `p0_apply_delta_negative_target_size_must_not_abort`, `p0_pack_open_negative_target_size_must_not_abort`; difftest CRASH in 4/4 modes | rejects | panics |

Both are reachable remotely: a 300-byte pack (`PackWriter` + one `OFS_DELTA`) kills the process in `PackReader::open`. Fix: do the bound arithmetic in `Int64`, or use `cp_off > base_size - cp_size`. Reject a varint whose accumulated value would exceed `0x7fffffff` (check `shift == 28 && (b & 0x78) != 0`, not only `shift >= 31`).

### P1

| ID | Defect | Location | Evidence | git | gix |
| --- | --- | --- | --- | --- | --- |
| P1-1 | `.idx` table offsets `count*20`/`count*28` overflow `Int`. With `max_pack_entries` raised through the public `GitLimits::new`, `fanout[255]=153391690` makes `off64_off` wrap to 1056, so a 1,096-byte file parses and `lookup` aborts (`index 1533917932 out of bounds (len 1096)`) | `src/pack_idx.pion:73-77` | `p1_pack_index_table_offset_overflow_must_not_abort` | size-checked in `size_t` | `usize` |
| P1-2 | `Tree::parse` accepts **unsorted** trees (fsck `treeNotSorted`, ERROR). `encode()` then silently re-sorts, so the OID changes | `src/object.pion:284-338` | `p1_tree_parse_rejects_unsorted_entries`; difftest 20 pair vectors | rejects | parses (fsck is separate) |
| P1-3 | `Tree::parse` accepts **duplicate** names, including file `a` + dir `a` placed apart (fsck `duplicateEntries`, ERROR). This is the classic two-parsers-disagree vector | same | `p1_tree_parse_rejects_duplicate_entries`; difftest 6 vectors | rejects | parses |
| P1-4 | `Tree::encode` only checks sorted neighbours. File `a` and dir `a` sort apart (`a` < `a-b` < `a/`), so encode **emits trees that git/GitHub refuse** | `src/object.pion:362-365` | `p1_tree_encode_rejects_nonadjacent_file_dir_duplicate` | `hash-object`: duplicateEntries | n/a |
| P1-5 | Only the exact `.git` is blocked. NTFS/HFS+ aliases are accepted: `.git.`, `.git `, `GIT~1`, `git~1`, `.git::$INDEX_ALLOCATION`, `.g‌it`, `.gi‍t` (the CVE-2014-9390 / CVE-2019-1353 class). The package claims "no .git" protection, and this bypasses it | `src/types.pion:290-321` | `p1_tree_rejects_ntfs_hfs_dotgit_aliases` (7/7 accepted); difftest 28 vectors | `hasDotgit` | parse-level accept (gix checks at checkout) |
| P1-6 | Symlinked `.gitmodules` / `GITMOD~1` / `.gitattributes` / `.gitignore` accepted (CVE-2018-11235 class) | same | `p1_tree_rejects_symlinked_gitmodules` | `gitmodulesSymlink` ERROR | accept |
| P1-7 | **Interop:** `\` in a tree name rejects the *whole tree*, so real repositories with such files (legal on POSIX) are unreadable | `src/types.pion:316` | `p1_tree_accepts_backslash_names_like_git`; difftest 8 vectors | accepts | accepts |
| P1-8 | Commit header smuggling: two `tree` headers are accepted and the **last one wins**. Two `author` headers likewise. git and gix reject, so a Pion consumer resolves a different tree than git for the same commit id | `src/object.pion:558-577` | `p1_commit_rejects_duplicate_tree_header`, `p1_commit_rejects_duplicate_author` | `multipleAuthors` / `missingAuthor` | rejects |
| P1-9 | OFS_DELTA offset varint has no overflow check. A 20-byte non-canonical encoding wraps `Int64` back onto a valid base offset and resolves | `src/pack.pion:51-68` | `p1_pack_rejects_overflowing_ofs_delta_varint` | "offset value overflow for delta base object" | rejects |
| P1-10 | **Memory amplification, no aggregate budget.** `PackReader::open` keeps every inflated payload *and* every resolved object resident. Limits are per object only. 0.8 KiB of pack → 506 MiB RSS (8 × 63 MiB deltas over one 64 KiB base); 510 KiB → 515 MiB (8 zlib bombs). git index-pack and gix stay flat at ~67–194 MiB. On a real 33 MB pack Pion peaks at **803 MiB vs gix 152 MiB** | `src/pack.pion:153-352` | `dos.py` table (§4) | streams to disk | streams with LRU cache |
| P1-11 | **Interop:** the default `max_delta_depth = 50` rejects valid packs at depth 51+ (`git repack --depth=250`, `pack.depth` ≤ 4095). The depth limit doubles as an interop limit instead of a DoS bound | `src/types.pion:97` | `p1_default_limits_accept_depth_51_delta_chain`; difftest depths 51/60/100/250 | accepts | accepts |

### P2

| ID | Defect | Evidence | git | gix |
| --- | --- | --- | --- | --- |
| P2-1 | Loose header with zero-padded size (`blob 012`) accepted | `p2_loose_rejects_zero_padded_size` | "unable to parse header" | accepts |
| P2-2 | Bytes after the loose object's zlib/Adler-32 trailer are ignored | `p2_loose_rejects_trailing_garbage`; difftest 4 vectors | "garbage at end of loose object" | accepts |
| P2-3 | Timestamp overflow wraps silently (`18446744073709551616` → `0`) | `p2_signature_timestamp_overflow_rejected` | `badDateOverflow` | rejects |
| P2-4 | Negative (`-5`), `+`-signed and zero-padded dates accepted | `p2_signature_rejects_negative_and_zero_padded_dates` | `badDate` / `zeroPaddedDate` | accepts |
| P2-5 | Valid commits rejected: tz minutes ≥ 60 or hours > 23 (`+0060`, `+9999`); a leading extra space before the date | `p2_signature_accepts_out_of_range_tz_like_git` | accepts | accepts / rejects |
| P2-6 | Header order not enforced (author before tree, parent after author, extra header before author) | `p2_commit_enforces_header_order` | `missingTree` etc. | rejects |
| P2-7 | Round-trip loss: `encoding` is always re-emitted before extra headers; a duplicate `committer` is dropped. `encode()` changes the OID of commits git accepts | `p2_commit_encode_preserves_header_order`; difftest `rt_lossy` | n/a | byte-identical |
| P2-8 | Round-trip loss: unknown tag headers are dropped by `Tag::parse` | `p2_tag_roundtrip_preserves_unknown_headers` | n/a | rejects |
| P2-9 | Tag continuation headers (`gpgsig` with ` `-continued lines) rejected; header order / duplicates not checked | `p2_tag_accepts_continuation_headers`; difftest | accepts / rejects | rejects |
| P2-10 | Tag name not validated (`v..1`, `v 1`, `v.lock`, `@{` …) | `p2_tag_rejects_invalid_tag_name`; difftest 22 vectors | `badTagName` | parses |
| P2-11 | Index v3 unknown extended-flag bits accepted | `p2_index_rejects_unknown_extended_flag_bits` | "unknown index entry format" | rejects |
| P2-12 | Unknown *required* (lowercase) index extension accepted | `p2_index_rejects_unknown_required_extension` | "index uses zzzz extension, which we do not understand" | rejects |
| P2-13 | Index `flags.name_len` ignored (path is NUL-scanned). Three parsers, three answers for one file: git `abcd`, gix `abc`, Pion `abcdef`. Also: v2 entry with `CE_EXTENDED` rejected (git/gix accept) | `p2_index_honours_name_len_field`; difftest | — | — |
| P2-14 | `.idx`: OID table sorting/uniqueness not validated, so `lookup` misses objects `entry_at` returns. Negative 64-bit offsets are surfaced. There is no idx↔pack cross-check API (CRC/OID flips go unnoticed) | `p2_pack_index_rejects_unsorted_oids`; difftest 10 vectors | `verify-pack` rejects | same leniency at `File::at` (has `verify_integrity`) |
| P2-15 | Delta shorter than `DELTA_SIZE_MIN` (4 bytes) accepted | `p2_delta_rejects_truncated_minimal_delta` | "failed to apply delta" | accepts |
| P2-16 | PACK version 3 rejected | `p2_pack_accepts_version_3` | accepts | **panics** |

Report-only (no test), by design but worth recording:
* Default `max_tree_entries = 100000` rejects 100,001-entry trees that git and gix accept. Default `max_object_bytes = 64 MiB` rejects larger blobs.
* The reversed-REF_DELTA fixed-point loop in `PackReader::open` is O(N·depth) and allocates `to_hex()` per probe. Depth 1000 → 0.04 s, depth 5000 → 0.77 s (git: 0.06 s). It is harmless under default limits (depth ≤ 50).
* Thin packs fetched with `--fix-thin` (bases appended at the end) always take the multi-round path.
* `PackReader` and `.idx` are SHA-1 only. `HashKind::Sha256` exists only for trees and loose objects.

### Controls: attack surfaces that held

| Surface | Result |
| --- | --- |
| `check_ref_format` vs `git check-ref-format` (all 128 ASCII bytes × 3 positions + 95 hand-picked names, with/without `--allow-onelevel`) | 949/950 agree. The 1 mismatch is `-`, which `git` parses as an option, an argv artifact |
| pkt-line: `0000/0001/0002`, `0003`, `0004`, upper-case `000A`, `fff1`, truncation | matches git's `packet_length` (upper-case hex and `0004` accepted, as in git; gix rejects `0004`) |
| Real packfiles: pion-packages own `.git` pack (6 MB), 33 MB and 56 MB internal monorepo packs | **OID + kind + size identical** to git and gix |
| OFS self/forward/<12/mid-entry offsets, REF self/cycle, thin base, count 0x7fffffff, size-varint 2^35 / bit-31, bad trailer, 80 random bit-flips, 40 random OFS/REF packs | identical verdicts to git |
| OFS chain depth 5000 / reversed REF depth 5000 (permissive limits) | no recursion: 0 stack overflow in native or wasm, 0.02 s / 0.77 s |
| Delta `size==0 ⇒ 0x10000`, copy past base, insert past end, result ≠ target, 64 MiB+ result | correct; limit checked before allocation |
| Loose zlib bomb, index count 0x7fffffff, pack count 0x7fffffff | rejected by limits without pre-allocation |
| Index v4 prefix compression with multi-byte UTF-8, non-UTF-8 tree/commit bytes | lossless (Pion `String` round-trips raw bytes) |

## 3. Three-way differential (`difftest.py`)

| Surface | Vectors | Agree | Pion lenient | Pion strict | Content diff | Round-trip lossy | Pion crash |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `tree` | 419 | 328 | 83 | 8 | 0 | 0 | 0 |
| `commit` | 258 | 148 | 93 | 13 | 0 | 4 | 0 |
| `tag` | 45 | 17 | 25 | 1 | 0 | 2 | 0 |
| `loose` | 39 | 29 | 6 | 4 | 0 | 0 | 0 |
| `delta` | 27 | 23 | 1 | 1 | 0 | 0 | 2 |
| `pack` | 165 | 158 | 1 | 6 | 0 | 0 | 0 |
| `idx` | 21 | 11 | 10 | 0 | 0 | 0 | 0 |
| `index` | 55 | 34 | 3 | 16 | 1 | 1 | 0 |
| `pkt` | 55 | 53 | 2 | 0 | 0 | 0 | 0 |
| `ref` | 950 | 949 | 1 | 0 | 0 | 0 | 0 |
| **total** | **2034** | | | | | | |

Plus 27 delta vectors wrapped into packs for the git/gix verdict. Pack vectors include the pion-packages own-repo packs; in an earlier run with the same harness (`--real-pack`), the 33 MB and 56 MB internal monorepo packs were also OID/kind/size-identical across all three implementations. Full per-vector output: `/tmp/rt-git-out/difftest.txt` / `difftest.json`.

Classes: `pion_lenient` = Pion accepts, git rejects. `pion_strict` = Pion rejects, git accepts. `content_diff` = both accept, decoded content differs. `rt_lossy` = both accept, Pion `encode()` is not byte-identical. git verdicts come from `hash-object` (strict fsck) for tree/commit/tag, `fsck --strict` for loose, `index-pack` + `cat-file --batch-check` for packs, `verify-pack` for idx, `ls-files -s` for index and `check-ref-format` for refs. pkt-line has no git CLI decoder, so gix is the reference there.

Not counted as Pion defects (git is more lenient there, and Pion's strictness is intentional or harmless): loose size ≥ 2^31 / size mismatch (git fsck streams big blobs), index trailer checksum, `.git/...` and `../` paths in the index (git does not validate paths on read), truncated index extensions, and the `0004` pkt-line versus gix. `missingTaggerEntry` is INFO-level in fsck and is ignored.

## 4. DoS / complexity (`dos.py`, peak RSS from `/usr/bin/time -l`)

| Case | Input | Impl | rc | Wall s | Peak RSS MiB | Result |
| --- | ---: | --- | ---: | ---: | ---: | --- |
| zlib-bomb pack: 1 x 64 MiB blobs | 63.7 KiB | pion | 0 | 0.27 | 66.2 | `0 OK n=1 h=c42a2e3ccd4dc937484d07f769e5a287ef275ce7` |
| zlib-bomb pack: 1 x 64 MiB blobs | 63.7 KiB | gix | 0 | 0.10 | 66.5 | `0 OK n=1 h=c42a2e3ccd4dc937484d07f769e5a287ef275ce7` |
| zlib-bomb pack: 1 x 64 MiB blobs | 63.7 KiB | git index-pack | 0 | 0.11 | 68.6 | `3bf6c2530df23edf1b7b10e0c443fd4b340a235d` |
| zlib-bomb pack: 4 x 64 MiB blobs | 254.9 KiB | pion | 0 | 1.11 | 258.7 | `0 OK n=4 h=39f2a4e76a5f22e240cad2a483ff024db8f4ee79` |
| zlib-bomb pack: 4 x 64 MiB blobs | 254.9 KiB | gix | 0 | 0.27 | 66.9 | `0 OK n=4 h=39f2a4e76a5f22e240cad2a483ff024db8f4ee79` |
| zlib-bomb pack: 4 x 64 MiB blobs | 254.9 KiB | git index-pack | 0 | 0.40 | 68.7 | `42d450159b5a2cf05fe3e5413e70370b5c9d9f31` |
| zlib-bomb pack: 8 x 64 MiB blobs | 509.8 KiB | pion | 0 | 2.12 | 515.2 | `0 OK n=8 h=1db094ad4ae35c606eaaa5c69705044628cdf10c` |
| zlib-bomb pack: 8 x 64 MiB blobs | 509.8 KiB | gix | 0 | 0.52 | 67.4 | `0 OK n=8 h=1db094ad4ae35c606eaaa5c69705044628cdf10c` |
| zlib-bomb pack: 8 x 64 MiB blobs | 509.8 KiB | git index-pack | 0 | 0.85 | 68.7 | `f21acf4332c5a68e7a816ecb4650e85766d8f05a` |
| delta-amp pack: 64KiB base + 1 x 63MiB OFS_DELTA | 0.6 KiB | pion | 0 | 0.26 | 65.2 | `0 OK n=2 h=032b36188b661559ea09088acbce0abc681c19b0` |
| delta-amp pack: 64KiB base + 1 x 63MiB OFS_DELTA | 0.6 KiB | gix | 0 | 0.07 | 128.4 | `0 OK n=2 h=032b36188b661559ea09088acbce0abc681c19b0` |
| delta-amp pack: 64KiB base + 1 x 63MiB OFS_DELTA | 0.6 KiB | git index-pack | 0 | 0.09 | 67.8 | `f471634dc0af1914789977dffe619ceecdaf394a` |
| delta-amp pack: 64KiB base + 4 x 63MiB OFS_DELTA | 0.7 KiB | pion | 0 | 1.06 | 254.3 | `0 OK n=5 h=1c9ae2a066f67137abe14ef4685640feff503d18` |
| delta-amp pack: 64KiB base + 4 x 63MiB OFS_DELTA | 0.7 KiB | gix | 0 | 0.27 | 128.4 | `0 OK n=5 h=1c9ae2a066f67137abe14ef4685640feff503d18` |
| delta-amp pack: 64KiB base + 4 x 63MiB OFS_DELTA | 0.7 KiB | git index-pack | 0 | 0.19 | 193.8 | `e8dabaad37529081523679d96dec536b002f4382` |
| delta-amp pack: 64KiB base + 8 x 63MiB OFS_DELTA | 0.8 KiB | pion | 0 | 2.05 | 506.4 | `0 OK n=9 h=a13abbd92eb5e77452ff4b7bc4b37bb7b012cf9c` |
| delta-amp pack: 64KiB base + 8 x 63MiB OFS_DELTA | 0.8 KiB | gix | 0 | 0.49 | 128.4 | `0 OK n=9 h=a13abbd92eb5e77452ff4b7bc4b37bb7b012cf9c` |
| delta-amp pack: 64KiB base + 8 x 63MiB OFS_DELTA | 0.8 KiB | git index-pack | 0 | 0.22 | 320.0 | `65f63c917b77acdb08b70a7e8151f00b16bbb84e` |
| OFS chain depth 1000 (permissive limits) | 49.2 KiB | pion | 0 | 0.01 | 3.2 | `0 OK n=1001 h=d259724af2808c6a801854befeb9b33c9f8e8222` |
| OFS chain depth 1000 (permissive limits) | 49.2 KiB | gix | 0 | 1.00 | 3.0 | `0 OK n=1001 h=d259724af2808c6a801854befeb9b33c9f8e8222` |
| OFS chain depth 1000 (permissive limits) | 49.2 KiB | git index-pack | 0 | 0.03 | 5.2 | `45769d473ddeff966ad39f09de11b4827bbc0651` |
| reversed REF chain depth 1000 (permissive limits) | 67.8 KiB | pion | 0 | 0.04 | 3.3 | `0 OK n=1001 h=d259724af2808c6a801854befeb9b33c9f8e8222` |
| reversed REF chain depth 1000 (permissive limits) | 67.8 KiB | gix | 0 | 0.01 | 2.3 | `0 ERR decode` |
| reversed REF chain depth 1000 (permissive limits) | 67.8 KiB | git index-pack | 0 | 0.03 | 5.3 | `3f2820e74ba0742db5f758ead4f71c72770ff997` |
| OFS chain depth 5000 (permissive limits) | 243.9 KiB | pion | 0 | 0.02 | 7.0 | `0 OK n=5001 h=ccba87d48b5c7eacfa887c1cf31f2e31ac3d1eb7` |
| OFS chain depth 5000 (permissive limits) | 243.9 KiB | gix | 0 | 24.76 | 4.4 | `0 OK n=5001 h=ccba87d48b5c7eacfa887c1cf31f2e31ac3d1eb7` |
| OFS chain depth 5000 (permissive limits) | 243.9 KiB | git index-pack | 0 | 0.06 | 6.2 | `1da51c6b23487a897ec7417ee5e89c94156a4f8f` |
| reversed REF chain depth 5000 (permissive limits) | 336.7 KiB | pion | 0 | 0.78 | 7.8 | `0 OK n=5001 h=ccba87d48b5c7eacfa887c1cf31f2e31ac3d1eb7` |
| reversed REF chain depth 5000 (permissive limits) | 336.7 KiB | gix | 0 | 0.01 | 2.6 | `0 ERR decode` |
| reversed REF chain depth 5000 (permissive limits) | 336.7 KiB | git index-pack | 0 | 0.06 | 6.4 | `12d6fe074a5c2a9cd6a52f8e0a8a6d75081790df` |
| tree 100000 entries parse+encode | 3515.6 KiB | pion | 0 | 0.09 | 37.4 | `0 OK n=100000 rt=same` |
| tree 100000 entries parse+encode | 3515.6 KiB | gix | 0 | 0.01 | 16.8 | `0 OK n=100000 rt=same` |
| tree 100000 entries parse+encode | 3515.6 KiB | git hash-object | 0 | 0.02 | 7.4 | `1a1d2c877413cf792f566c32c512926f18c7c031` |
| tree 100001 entries (default max_tree_entries) | 3515.7 KiB | pion | 0 | 0.01 | 27.8 | `0 ERR limit_exceeded` |
| tree 100001 entries (default max_tree_entries) | 3515.7 KiB | gix | 0 | 0.01 | 16.8 | `0 OK n=100001 rt=same` |
| tree 100001 entries (default max_tree_entries) | 3515.7 KiB | git hash-object | 0 | 0.02 | 7.4 | `37d2d86b433a93f90712473ba1988fb2f2ec1a9c` |

Full run (`run_audit.sh` without `--quick`) adds: 16 × 64 MiB zlib bombs (1019.5 KiB pack) → **Pion 1028 MiB** vs gix 68 MiB / git 69 MiB; 16 × 63 MiB delta amplification (**1.1 KiB** pack) → **Pion 1011 MiB** vs gix 128 MiB / git 383 MiB; OFS depth 10000 → Pion 0.04 s / 11.5 MiB.

The gix oracle uses `cache::Never`, so its 25 s at OFS depth 5000 is an oracle artifact (O(D²) without a base cache) and is not reported against gix.

## 5. 4-mode Wasm32 consistency (`fourmode.py`)

| Batch | Records | native_dbg | native_rel | wasm_dbg | wasm_rel | Crashes (per mode) | Verdict |
| --- | ---: | --- | --- | --- | --- | ---: | --- |
| `commit` | 258 | fc7f3ccb7488 | fc7f3ccb7488 | fc7f3ccb7488 | fc7f3ccb7488 | 0/0/0/0 | identical |
| `delta` | 27 | 9ccc5e35a021 | 9ccc5e35a021 | 9ccc5e35a021 | 9ccc5e35a021 | 2/2/2/2 | identical |
| `idx` | 21 | 3bdb24987fd3 | 3bdb24987fd3 | 3bdb24987fd3 | 3bdb24987fd3 | 0/0/0/0 | identical |
| `index` | 55 | faeb6ebc4cf1 | faeb6ebc4cf1 | faeb6ebc4cf1 | faeb6ebc4cf1 | 0/0/0/0 | identical |
| `loose` | 39 | 6a96fe2f3a74 | 6a96fe2f3a74 | 6a96fe2f3a74 | 6a96fe2f3a74 | 0/0/0/0 | identical |
| `pack` | 165 | 2a5d1d04d021 | 2a5d1d04d021 | 2a5d1d04d021 | 2a5d1d04d021 | 0/0/0/0 | identical |
| `packx` | 4 | baddc5d2cef2 | baddc5d2cef2 | baddc5d2cef2 | baddc5d2cef2 | 0/0/0/0 | identical |
| `pkt` | 55 | 35eb58ccbf0b | 35eb58ccbf0b | 35eb58ccbf0b | 35eb58ccbf0b | 0/0/0/0 | identical |
| `ref` | 950 | 0e59de2dee3c | 0e59de2dee3c | 0e59de2dee3c | 0e59de2dee3c | 0/0/0/0 | identical |
| `tag` | 45 | 2b08bc2d280d | 2b08bc2d280d | 2b08bc2d280d | 2b08bc2d280d | 0/0/0/0 | identical |
| `tree` | 419 | 521a0f4d2a57 | 521a0f4d2a57 | 521a0f4d2a57 | 521a0f4d2a57 | 0/0/0/0 | identical |

Total records replayed per mode: 2038

Every vector (including the DoS packs: depth-5000 chains, 4 × 64 MiB zlib bombs, 4 × 63 MiB delta amplification) yields byte-identical result lines in all four modes. **0 diff**. The only traps are the two P0 vectors, and they trap identically in every mode (native `SIGABRT`; wasm `pion panic: index out of bounds: idx=2147483647, len=1024` / `negative bytes length`).

## 6. Benchmark fairness (`bench/`)

Upstream numbers reproduce. Fairness checks:

| Workload | Pion median ms | gix median ms | Pion/gix | Pion RSS | gix RSS | Note |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| W1 upstream (32 KB synthetic pack ×5) | 41.1 | 22.9 | 0.56× | 4.30 MiB | 4.48 MiB | reproduces README (0.58×) |
| W2 upstream | 70.5 | 22.0 | 0.31× | 5.67 MiB | 4.02 MiB | reproduces README (0.30×) |
| W3 upstream | 17.2 | 7.1 | 0.41× | 5.23 MiB | 3.38 MiB | README 0.46× |
| W1 on real pion-packages pack (6.1 MB) | 234.0 | 164.1 | 0.70× | 49.3 MiB | 24.2 MiB | SHA-256 verified |
| W1 on real 33 MB monorepo pack | 3168.2 | 1618.9 | 0.51× | **802.7 MiB** | 152.0 MiB | SHA-256 verified |
| W2 trees: `Tree::encode` vs zero-alloc comparator (Pion vs Pion) | 64.7 | 32.7 (noalloc) | **1.98×** speed-up | 5.36 MiB | 5.34 MiB | byte-identical output, SHA-256 verified |

1. **W1 input is not representative.** It is a 32 KB synthetic pack × 5 iterations. On real packs Pion is 0.70× (6 MB) and 0.51× (33 MB), with 2.0× / 5.3× gix's peak RSS (P1-10). README reports 4.33 vs 4.48 MiB RSS, which hides the eager-materialisation cost.
2. **W1 handicaps gix.** `rust/src/main.rs` iterates `pack.streaming_iter()` (`Mode::Verify`, `KeepAndCrc32`: inflates every entry into a sink) and then `decode_entry` inflates it again. gix therefore inflates twice and Pion once, which biases W1 *toward* Pion. A fair harness drops the streaming pass, or uses `index::File::write_data_iter_to_stream` / `traverse` once.
3. **W2 comparator allocates.** `tree_entry_compare` calls `name.to_bytes()` on both sides of every comparison inside the merge sort. An audit-local zero-alloc comparator with byte-identical output (`bench_fair`, SHA-256 verified) runs **1.95–1.98× faster** on the same W2 tree bundle. W2's 0.30× is therefore partly self-inflicted. Also: parse could detect already-sorted input and skip the sort.
4. **O(D²) concern.** The worry was that `PackReader::resolve_object` re-inflates bases with no cache. It does not: `open()` resolves each object exactly once (memoised), so there is no O(D²) with depth. The cost is paid in memory (P1-10) instead. The remaining super-linear path is the REF_DELTA fixed-point loop (§2 report-only).

## 7. Files

| File | Purpose |
| --- | --- |
| `pion.toml`, `src/main.pion` | Pion batch oracle (`git_audit <mode> <batch> [start]`; `packx`/`treex` use permissive limits) |
| `redteam_test.pion` | 31 FAIL (`p0_`/`p1_`/`p2_`) + 9 PASS (`control_`) |
| `gix_oracle/` | Rust gix batch oracle, same format (built to `/tmp/rt-git-cargo`) |
| `difftest.py` | vector generators + three-way runner (git / gix / Pion) |
| `dos.py` | RSS / wall-time probes vs `git index-pack` / gix |
| `fourmode.py` | native_dbg / native_rel / wasm_dbg / wasm_rel replay with crash-resume |
| `bench_fair/` | W2 comparator fairness probe |
| `run_audit.sh` | one-shot runner; all artifacts in `/tmp/rt-git-*` |
