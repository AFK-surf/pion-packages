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

- **132 unit, protocol, convergence (SEC), and official Node.js `yjs` golden wire-vector tests**:
  ```sh
  pionc fmt --check packages/crdt
  pionc check --json packages/crdt
  pionc test --json packages/crdt
  ```
- **Red-Team Audit (`packages/crdt/audit`, v0.2.0)**: 16/16 red-team tests pass and 660 three-way differential fuzz runs (Pion / Node.js `yjs` / Rust `yrs`) show 0 mismatches. `encodeStateAsUpdate` size on the `automerge-paper` trace is now **223,411 B** (`yjs` 223,414 B, `yrs` 223,411 B; v0.1.0: 990,662 B). Reproduce with `sh packages/crdt/audit/run_audit.sh`.
- **Wasm32 smoke build**:
  ```sh
  pionc build --target wasm32 -o /tmp/crdt_wasm_smoke.wasm packages/crdt/wasm_smoke
  ```

## v0.2.0 Three-Language Benchmarks (Pion vs Node.js `yjs` vs Rust `yrs --release`)

Measured after red-team remediation via `sh packages/crdt/audit/run_audit.sh` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, stdout SHA-256 identical across all three implementations; one transaction per edit; baseline `rust_yrs`):

| Workload | `pion` | `node_yjs` | `rust_yrs` | Pion vs `yrs` | Pion vs `yjs` |
| --- | ---: | ---: | ---: | ---: | ---: |
| `text_w1` (`text 20000×3`) | 192.7 ms (7.1 MiB) | 1017.7 ms (103.7 MiB) | 1965.6 ms (5.5 MiB) | **10.20x** | **5.28x** |
| `append_50k` | 26.1 ms (2.4 MiB) | 163.6 ms | 26.0 ms (2.6 MiB) | 1.00x | **6.27x** |
| `append_200k` | 80.8 ms (3.64 MiB) | 417.0 ms (100.1 MiB) | 68.8 ms (2.8 MiB) | 0.85x | **5.16x** |
| `trace_automerge` (259,778 edits) | 1312.8 ms (43.6 MiB) | 7023.4 ms | 6010.3 ms (17.3 MiB) | **4.58x** | **5.35x** |
| `remote_apply` (×20) | 155.5 ms (9.2 MiB) | 464.0 ms | 81.6 ms (6.4 MiB) | 0.52x | **2.98x** |

- `append_200k` was O(n²) in v0.1.0 (1944.3 ms / 66.8 MiB); v0.2.0 runs it in 80.8 ms / 3.64 MiB (**24.1x faster**).
- Lagging items: `append_200k` is 0.85x and `remote_apply` 0.52x of `yrs`; peak RSS on `trace_automerge` is 43.6 vs 17.3 MiB.
- `yrs` is driven with one `transact_mut()` per edit and `OffsetKind::Utf16`; batched single-transaction replay was not measured.

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
