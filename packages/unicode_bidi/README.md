# `unicode_bidi` (`v0.1.0`)

Pure-Pion implementation of the **Unicode Bidirectional Algorithm (UAX #9, Unicode 16.0.0)** with zero `extern "C"` and zero `World` dependency.

## Features

- Complete Unicode 16.0.0 UCD tables (`DerivedBidiClass.txt` including `@missing` defaults with 0/1,112,064 divergences, `BidiBrackets.txt` BD16 with canonical skeletons, `BidiMirroring.txt` L4 with all 428 entries).
- O(1) BMP two-level 256-entry page table (57 unique pages, 14.6 KB static ASCII string) + compact 270-range SMP binary search.
- Full UAX #9 rev 50 rule pipeline:
  - **P1–P3**: paragraph segmentation and first-strong base direction detection (skipping isolate runs)
  - **X1–X8**: explicit embeddings (`LRE`/`RLE`), overrides (`LRO`/`RLO`), isolates (`LRI`/`RLI`/`FSI`/`PDI`), `MAX_DEPTH = 125` overflow and stack-bomb protection
  - **X9–X10**: isolating run sequences (BD13) with zero-allocation fast path when no isolate controls are present
  - **W1–W7**: weak type resolution
  - **N0–N2**: BD16 paired bracket algorithm (63-entry bracket stack cap, returning an empty pair list on overflow per UAX #9 rev 50) and neutral resolution
  - **I1–I2**: implicit level resolution (clamped to `0..=126` invariant)
  - **L1–L4**: trailing whitespace/separator reset, O(line) `visual_runs` / `reordered_levels` / `reorder_line` / `reorder_line_with_mirroring`, zero-allocation backward UTF-8 RTL reversal, and RTL glyph mirroring
- Compact 1-byte `FixedArray[Byte]` internal working buffers (zero COW overhead), hoisted table references with inline ASCII fast paths, flat BD13 run-sequence chains, and reusable `BidiScratch` across paragraphs.
- Explicit `Limits` / `Result[BidiInfo, BidiError]` API (`new_with_limits`) plus total `BidiInfo::new` and convenience `bidi_line_levels` / `bidi_visual_order` helpers.
- Verified on Unicode 16.0.0 `BidiCharacterTest` (`91,707/91,707`) and `BidiTest` (`770,241/770,241`), red-team audit (`18/18`), and Native + Wasm32 (`debug` / `--release`).

## Head-to-Head Benchmarks (`Linux x86_64`, Pion Native `--release` vs Rust `unicode-bidi 0.3.18 --release`)

Run `sh packages/unicode_bidi/bench/run_bench.sh` (`--warmup 1 --rounds 5`, strictly interleaved, SHA-256 verified identical across all rounds):

| Benchmark | Pion Median (ms) | Rust Median (ms) | Pion Throughput (MB/s) | Rust Throughput (MB/s) | Speedup vs Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| Pure LTR fast path (`40k ops`, `3.95 MB`) | 223.448 | 610.910 | 17.69 | 6.47 | **2.73×** |
| Mixed Arabic/Hebrew/English (`10k ops`, `900 KB`) | 164.294 | 244.927 | 5.48 | 3.68 | **1.49×** |
| Deep nested isolates & brackets (`5k ops`, `383 KB`) | 118.067 | 124.999 | 3.25 | 3.07 | **1.06×** |
| Per-line `visual_runs` + `reorder_line` (`10k ops`, `900 KB`) | 270.247 | 390.638 | 3.33 | 2.31 | **1.45×** |
