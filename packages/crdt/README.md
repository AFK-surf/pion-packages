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

- **128 unit, protocol, convergence (SEC), and official Node.js `yjs` golden wire-vector tests**:
  ```sh
  pionc fmt --check packages/crdt
  pionc check --json packages/crdt
  pionc test --json packages/crdt
  ```
- **Wasm32 smoke build**:
  ```sh
  pionc build --target wasm32 -o /tmp/crdt_wasm_smoke.wasm packages/crdt/wasm_smoke
  ```

## Head-to-Head Benchmarks (Pion Native vs Node.js Official `yjs`)

Measured on `Darwin arm64` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, **mandatory stdout SHA-256 byte-for-byte identical**):

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
