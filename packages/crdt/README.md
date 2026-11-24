# `crdt` — Pure Pion Yjs v1 Wire-Compatible CRDT Engine

A pure Pion implementation of the **Yjs / YATA** collaborative CRDT engine with full **Yjs Update v1** and **lib0** binary wire-protocol compatibility. Runs identically on **Native** and **Wasm32** with zero C glue, zero JS/Rust bridge overhead, and no `World` dependency.

## Features

- **lib0 binary codec (`src/lib0.pion`)**: `varuint`, `varint`, `varstring` (UTF-8), `varbytes`, `uint8`/`uint16`/`uint32`/`uint32_be`, IEEE 754 `float32`/`float64`, `bigint64`, and `Any` (tags `116..127`) byte-exact with `dmonad/lib0`.
- **Arena-based YATA engine (`src/store.pion`, `src/doc.pion`)**:
  - Cycle-free flat `Array[Item]` arena with per-client sorted block lists (`O(log N)` binary search) and LRU `SearchMarker` indexing (`O(1)` amortized sequential/random edits).
  - Shared types: `YText` (UTF-16 code unit indexing for full JS/Yjs interoperability, including CJK & emoji surrogate pairs, plus `format` attributes), `YArray` (primitive `Any` + nested `YText`/`YArray`/`YMap`), and `YMap` (LWW by higher `client_id` + nested shared types).
  - Run-length encoded `DeleteSet` with automatic sort-and-merge.
- **Yjs v1 Sync Protocol (`src/encoding.pion`)**:
  - `encode_state_vector` / `decode_state_vector`
  - `encode_state_as_update` / `encode_state_as_update_from` (incremental delta sync)
  - `apply_update` (idempotent, handles duplicate, fragmented, and out-of-order causal deliveries & out-of-order deletes via pending queue)
  - `merge_updates` & `diff_update` (operates directly on decoded wire blocks + DeleteSets without requiring base state).

## Quick Example

```pion
import "crdt"

pub fn example() -> String {
  let d1 = crdt::Doc::new(10UL)
  let d2 = crdt::Doc::new(20UL)

  d1.get_text("doc").insert(d1, 0, "Hello, ")
  d2.get_text("doc").insert(d2, 0, "Pion!")

  let _ = d1.apply_update(d2.encode_state_as_update())
  let _ = d2.apply_update(d1.encode_state_as_update())

  // Both peers deterministically converge to "Hello, Pion!"
  d1.get_text("doc").to_string(d1)
}
```

## Verification

- **134 unit, protocol, convergence (SEC), and official Node.js `yjs` golden wire-vector tests**:
  ```sh
  pionc fmt --check packages/crdt
  pionc check --json packages/crdt
  pionc test --json packages/crdt
  ```
- **Red-Team Audit (`packages/crdt/audit`, v0.2.0)**: 16/16 red-team tests pass and 660 three-way differential fuzz runs (Pion / Node.js `yjs` / Rust `yrs`) show 0 mismatches. `encodeStateAsUpdate` size on the `automerge-paper` trace (5-way): `pion` **223,411 B**, `rust_yrs` **223,411 B**, `node_yjs` **223,414 B**, `rust_y_octo` **260,509 B**, `node_y_octo_wasm` **260,509 B** (v0.1.0: 990,662 B). Reproduce with `sh packages/crdt/audit/run_audit.sh`.
- **Wasm32 smoke build**:
  ```sh
  pionc build --target wasm32 -o /tmp/crdt_wasm_smoke.wasm packages/crdt/wasm_smoke
  ```

## v0.2.0 Five-Way Benchmarks (Pion vs `y-octo` vs `y-octo-wasm` vs `yrs` vs `yjs`)

Reference implementations:
- Node.js official [`yjs`](https://github.com/yjs/yjs) `13.6.33`
- Rust [`yrs`](https://github.com/y-crdt/y-crdt) `0.28.2` (`--release`, `lto=thin`, `OffsetKind::Utf16`)
- Rust [`y-octo`](https://github.com/y-crdt/y-octo) `0.4.0` (`y-crdt/y-octo@58c9ffc`, `--release`, `lto=thin`)
- Node.js `y-octo-wasm` (`y-crdt/y-octo@58c9ffc`, `wasm32-unknown-unknown --release`, `DocSession { gc: true, undo: "disabled" }`)

Measured via `SECTIONS="size bench" ROUNDS=5 sh packages/crdt/audit/run_audit.sh` on `Linux x86_64` (Intel Xeon Platinum 8581C @ 2.30 GHz, 8 vCPU), `pionc 0.1.0`, `rustc 1.96.0`, `node v24.22.1` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, **stdout SHA-256 byte-for-byte identical across all 5 implementations and all rounds**; baseline `rust_yrs`):

| Workload | `pion` | `rust_y_octo` | `node_y_octo_wasm` | `rust_yrs` | `node_yjs` | Pion vs `yrs` / `y-octo` / `y-octo-wasm` / `yjs` | SHA-256 (prefix 16) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `text_w1` (`text 20000×3`) | 247.4 ms (7.12 MiB) | 227.3 ms (5.24 MiB) | 897.5 ms (76.70 MiB) | 3358.9 ms (5.60 MiB) | 2846.7 ms (111.35 MiB) | **13.58x** / 0.92x / **3.63x** / **11.51x** | `06f26a6a9a6d6752` |
| `append_50k` | 33.3 ms (2.48 MiB) | 43.7 ms (2.60 MiB) | 3167.1 ms (76.05 MiB) | 48.4 ms (2.52 MiB) | 407.4 ms (80.14 MiB) | **1.45x** / **1.31x** / **95.13x** / **12.24x** | `ac3b61ee14122a58` |
| `append_100k` | 78.0 ms (2.95 MiB) | 98.1 ms (2.72 MiB) | 12408.6 ms (76.06 MiB) | 91.2 ms (2.59 MiB) | 663.3 ms (88.51 MiB) | **1.17x** / **1.26x** / **159.17x** / **8.51x** | `17d38ef5a096dced` |
| `append_200k` | 139.8 ms (3.85 MiB) | 189.9 ms (2.88 MiB) | 54698.8 ms (76.16 MiB) | 154.5 ms (2.89 MiB) | 1196.5 ms (108.71 MiB) | **1.11x** / **1.36x** / **391.28x** / **8.56x** | `dd403bae8f48744b` |
| `tombstone_50k` | 7013.2 ms (20.43 MiB) | 1527.5 ms (11.84 MiB) | 5843.5 ms (82.95 MiB) | 5995.2 ms (13.95 MiB) | 3876.9 ms (148.54 MiB) | 0.85x / 0.22x / 0.83x / 0.55x | `4ebe0a8e06b70de2` |
| `trace_automerge` (259,778 edits) | 1857.7 ms (44.05 MiB) | 1470.6 ms (18.46 MiB) | 3528.9 ms (145.53 MiB) | 9639.7 ms (18.27 MiB) | 9269.2 ms (165.86 MiB) | **5.19x** / 0.79x / **1.90x** / **4.99x** | `fbcf04458973cd1c` |
| `remote_apply` (×20) | 314.3 ms (8.70 MiB) | 211.0 ms (7.46 MiB) | 446.4 ms (74.68 MiB) | 160.7 ms (6.04 MiB) | 968.6 ms (125.46 MiB) | 0.51x / 0.67x / **1.42x** / **3.08x** | `f13556fd49d149ba` |

- Single-digit percentage differences (within ±10%) on a shared Linux VM fall within measurement noise and are not bolded.
- Historical progression: `append_200k` was O(n²) in v0.1.0 on Apple M5 Max (1944.3 ms / 66.8 MiB); v0.2.0 runs it in 80.8 ms / 3.64 MiB on Apple M5 Max (**24.1x faster**) and 139.8 ms / 3.85 MiB on this Linux x86_64 host.
- `automerge-paper` `encodeStateAsUpdate` size (5-way): `pion` **223,411 B**, `rust_yrs` **223,411 B**, `node_yjs` **223,414 B**, `rust_y_octo` **260,509 B**, `node_y_octo_wasm` **260,509 B** (v0.1.0: 990,662 B).
- **Lagging items**:
  - **Latency**:
    - `text_w1` trails `rust_y_octo` (0.92x, 247.4 vs 227.3 ms);
    - `tombstone_50k` trails all 4 references: `rust_y_octo` (0.22x), `node_yjs` (0.55x), `node_y_octo_wasm` (0.83x), and `rust_yrs` (0.85x);
    - `trace_automerge` trails `rust_y_octo` (0.79x, 1857.7 vs 1470.6 ms);
    - `remote_apply` trails `rust_yrs` (0.51x, 314.3 vs 160.7 ms) and `rust_y_octo` (0.67x, 314.3 vs 211.0 ms).
  - **Peak RSS** (vs `rust_yrs` / `rust_y_octo`):
    - `text_w1`: 7.12 vs 5.60 / 5.24 MiB;
    - `append_100k`: 2.95 vs 2.59 / 2.72 MiB;
    - `append_200k`: 3.85 vs 2.89 / 2.88 MiB;
    - `tombstone_50k`: 20.43 vs 13.95 / 11.84 MiB;
    - `trace_automerge`: 44.05 vs 18.27 / 18.46 MiB;
    - `remote_apply`: 8.70 vs 6.04 / 7.46 MiB.
- **Driver semantics & `y-octo-wasm` `append` O(N²) root cause**:
  - `rust_yrs` is driven with one `transact_mut()` per edit (`OffsetKind::Utf16`); batched single-transaction replay was not measured.
  - In the main 5-way table, `node_y_octo_wasm` is driven one call per edit (matching the other 4 implementations). In `y-crdt/y-octo@58c9ffc`, every `DocSession::text_insert` commits via `commit_store` (`y-octo/src/doc/transaction/mod.rs`) and encodes a V1 delta from `before_state`; because adjacent same-client single-char inserts merge into one long string item in the store, encoding each delta runs `DocStore::write_structs_since` (`y-octo/src/doc/store.rs`) → `WireStruct::from_node` → `WireStruct::split_at` → `WireContent::split_in_place` (`y-octo/src/doc/codec/wire_struct.rs`) → `utf16_split_in_place` / `Utf16Slices::boundary` (`y-octo/src/doc/common/algorithm.rs`), linearly scanning from the start of the merged string to split at offset `i`, producing O(N²) scaling across `append_50k` (3167.1 ms) → `append_100k` (12408.6 ms) → `append_200k` (54698.8 ms) (a `y-octo` core behavior that also reproduces on native `Doc` with a subscriber attached).
  - As a same-host footnote reference with `YOCTO_WASM_BATCH=1` (wrapping each document build in `s.transact(...)`, SHA-256 verified identical): `trace_automerge` drops to **1512.6 ms** (161.59 MiB, 2.33x faster than unbatched; Pion vs batched wasm is 0.92x against paired `pion` at 1650.9 ms, within ±10% noise); `text_w1` is **1053.8 ms** (76.25 MiB, slower than unbatched 897.5 ms, paired `pion` 410.5 ms); `append_50k` degrades to **32014.9 ms** (paired `pion` 32.8 ms) because unmerged same-client single-char items accumulate in the linked list within the single transaction, triggering `MarkerList::walk` (`y-octo/src/doc/types/list/search_marker.rs`) fallback and `find_pos_from` (`y-octo/src/doc/types/list/mod.rs`) linear rescans (also reproduces on native `Doc::transact_mut`, so `append_200k` batched was omitted).

## v0.1.0 Head-to-Head Benchmarks (historical, Pion Native vs Node.js Official `yjs`)

Measured before red-team remediation on `Darwin arm64` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, **mandatory stdout SHA-256 byte-for-byte identical**):

### Workload 1: Sequential + Random Text Edits (20,000 ops × 10 iters) + v1 Encode/Decode
`sha256:0ed09d229ad8d2ccc4309209b62dce774bbb95cb8322f2e63b42601de4e0423f`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `node_yjs`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 1926.438 | 1466.458 | 2320.333 | 9632.19 | 15.48 MiB | **3.50x** |
| `node_yjs` | 6750.219 | 6070.897 | 7636.549 | 33751.10 | 246.91 MiB | 1.00x (baseline) |

### Workload 2: 2-Client Concurrent Mixed Edits (2 × 5,000 Text+Array+Map ops × 10 iters) + Incremental v1 Sync
`sha256:32c9ec4460bf7bb803c77429623574041f23f879e9f4c2ce3d3729801889b8b1`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `node_yjs`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 255.262 | 236.044 | 289.484 | 2552.61 | 8.05 MiB | **4.92x** |
| `node_yjs` | 1254.732 | 1205.617 | 1594.238 | 12547.32 | 226.08 MiB | 1.00x (baseline) |

Run locally with:
```sh
sh packages/crdt/bench/run_bench.sh
```
