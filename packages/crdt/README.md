# `crdt` — Pure Pion Yjs v1 Wire-Compatible CRDT Engine

A pure Pion implementation of the **Yjs / YATA** collaborative CRDT engine with full **Yjs Update v1** and **lib0** binary wire-protocol compatibility. Runs identically on **Native** and **Wasm32** with zero C glue, zero JS/Rust bridge overhead, and no `World` dependency.

## Features

- **lib0 binary codec (`src/lib0.pion`)**: `varuint`, `varint`, `varstring` (UTF-8), `varbytes`, `uint8`/`uint16`/`uint32`/`uint32_be`, IEEE 754 `float32`/`float64`, `bigint64`, and `Any` (tags `116..127`) byte-exact with `dmonad/lib0`.
- **Arena-based YATA engine (`src/store.pion`, `src/doc.pion`)**:
  - Cycle-free flat `Array[Item]` arena with per-client sorted block lists (`O(log N)` binary search) and LRU `SearchMarker` indexing (`O(1)` amortized sequential/random edits).
  - Shared types: `YText` (UTF-16 code unit indexing for full JS/Yjs interoperability, including CJK & emoji surrogate pairs, plus `format` attributes), `YArray` (primitive `Any` + nested `YText`/`YArray`/`YMap`), and `YMap` (LWW by higher `client_id` + nested shared types).
  - Run-length encoded `DeleteSet` with automatic sort-and-merge.
- **Yjs v1 Sync Protocol (`src/encoding.pion`)**:
  - `encode_state_vector` / `decode_state_vector` / `Doc::state_vector`
  - `encode_state_as_update` / `encode_state_as_update_sv` / `Doc::encode_state_as_update_from` / `Doc::encode_state_as_update_from_sv` (binary and in-memory `StateVector` incremental delta sync)
  - `apply_update` (idempotent, handles duplicate, fragmented, and out-of-order causal deliveries & out-of-order deletes via pending queue)
  - `merge_updates`, `diff_update`, & `diff_update_sv` (operates directly on decoded wire blocks + DeleteSets without requiring base state).

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

Measured via `SECTIONS="size bench" ROUNDS=5 sh packages/crdt/audit/run_audit.sh` on `Linux x86_64` (AMD Ryzen 7 PRO 8845HS, 16 vCPU), `pionc 0.1.0`, `rustc 1.100.0`, `node v24.22.1` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, **stdout SHA-256 byte-for-byte identical across all 5 implementations and all rounds**; baseline `rust_yrs`):

| Workload | `pion` | `rust_y_octo` | `node_y_octo_wasm` | `rust_yrs` | `node_yjs` | Pion vs `yrs` / `y-octo` / `y-octo-wasm` / `yjs` | SHA-256 (prefix 16) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `text_w1` (`text 20000×3`) | 117.7 ms (7.25 MiB) | 95.9 ms (5.30 MiB) | 571.1 ms (74.21 MiB) | 2963.8 ms (5.79 MiB) | 1622.2 ms (109.20 MiB) | **25.17x** / 0.81x / **4.85x** / **13.78x** | `06f26a6a9a6d6752` |
| `append_50k` | 6.9 ms (2.80 MiB) | 18.0 ms (2.78 MiB) | 1996.9 ms (74.14 MiB) | 19.2 ms (2.70 MiB) | 234.1 ms (78.86 MiB) | **2.77x** / **2.60x** / **288.44x** / **33.81x** | `ac3b61ee14122a58` |
| `append_100k` | 11.0 ms (3.24 MiB) | 35.4 ms (2.90 MiB) | 7812.2 ms (74.25 MiB) | 33.6 ms (2.75 MiB) | 381.1 ms (88.43 MiB) | **3.06x** / **3.23x** / **711.17x** / **34.69x** | `17d38ef5a096dced` |
| `append_200k` | 21.9 ms (4.11 MiB) | 91.9 ms (3.07 MiB) | 33933.6 ms (72.66 MiB) | 66.7 ms (2.92 MiB) | 907.0 ms (107.07 MiB) | **3.05x** / **4.20x** / **1552.45x** / **41.50x** | `dd403bae8f48744b` |
| `tombstone_50k` | 208.0 ms (20.98 MiB) | 840.0 ms (11.96 MiB) | 4403.7 ms (79.55 MiB) | 14296.3 ms (13.88 MiB) | 2935.8 ms (146.89 MiB) | **68.73x** / **4.04x** / **21.17x** / **14.11x** | `4ebe0a8e06b70de2` |
| `trace_automerge` (259,778 edits) | 261.8 ms (44.03 MiB) | 284.4 ms (18.64 MiB) | 1931.1 ms (145.90 MiB) | 6172.6 ms (18.53 MiB) | 5666.4 ms (166.83 MiB) | **23.58x** / **1.09x** / **7.38x** / **21.65x** | `fbcf04458973cd1c` |
| `remote_apply` (×20) | 110.9 ms (7.08 MiB) | 127.6 ms (7.51 MiB) | 237.6 ms (71.46 MiB) | 85.0 ms (6.16 MiB) | 664.8 ms (121.35 MiB) | 0.77x / **1.15x** / **2.14x** / **5.99x** | `f13556fd49d149ba` |

- Single-digit percentage differences (within ±10%) on a shared Linux host fall within measurement noise and are not bolded.
- Historical progression: `tombstone_50k` eliminated O(N²) split/marker degradation (51.2s → 208 ms, **4.04x faster than `rust_y_octo`** and **68.73x faster than `rust_yrs`**); `trace_automerge` improved **5.29x** on the same host (1237.9 ms → 234.2 ms paired, **1.09x vs `rust_y_octo`**); `remote_apply` improved **2.42x** on the same host (252.3 ms → 104.1 ms paired, **1.15x vs `rust_y_octo`**).
- `automerge-paper` `encodeStateAsUpdate` size (5-way): `pion` **223,411 B**, `rust_yrs` **223,411 B**, `node_yjs` **223,414 B**, `rust_y_octo` **260,509 B**, `node_y_octo_wasm` **260,509 B** (v0.1.0: 990,662 B).
- **Lagging items**:
  - **Latency**:
    - `text_w1` trails `rust_y_octo` (0.81x, 117.7 vs 95.9 ms);
    - `remote_apply` trails `rust_yrs` (0.77x, 110.9 vs 85.0 ms), while leading `rust_y_octo` (1.15x), `node_y_octo_wasm` (2.14x), and `node_yjs` (5.99x).
  - **Peak RSS** (vs `rust_yrs` / `rust_y_octo`):
    - `text_w1`: 7.25 vs 5.79 / 5.30 MiB;
    - `append_100k`: 3.24 vs 2.75 / 2.90 MiB;
    - `append_200k`: 4.11 vs 2.92 / 3.07 MiB;
    - `tombstone_50k`: 20.98 vs 13.88 / 11.96 MiB;
    - `trace_automerge`: 44.03 vs 18.53 / 18.64 MiB;
    - `remote_apply`: 7.08 vs 6.16 MiB (`rust_yrs`), beating `rust_y_octo` (7.51 MiB).
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
