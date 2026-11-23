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
  - **L1–L4**: trailing whitespace/separator reset, O(line) local-buffer `reorder_line` / `reorder_line_with_mirroring`, UTF-8 boundary byte-copy RTL reversal, and RTL glyph mirroring
- Compact 1-byte `Bytes` internal working buffers and reusable `BidiScratch` across paragraphs.
- Explicit `Limits` / `Result[BidiInfo, BidiError]` API (`new_with_limits`) plus total `BidiInfo::new` and Farview-compatible `bidi_line_levels` / `bidi_visual_order` helpers.
- Verified on Unicode 16.0.0 `BidiCharacterTest` (`91,707/91,707`) and `BidiTest` (`770,241/770,241`), red-team audit (`18/18`), and Native + Wasm32 (`debug` / `--release`).

## Head-to-Head Benchmarks (`Darwin arm64`, Pion Native `--release` vs Rust `unicode-bidi 0.3.18 --release`)

Run `sh packages/unicode_bidi/bench/run_bench.sh` (`--warmup 1 --rounds 5`, SHA-256 verified identical across all rounds):

| Benchmark | Pion Median (ms) | Rust Median (ms) | Pion Throughput (MB/s) | Rust Throughput (MB/s) | Speedup vs Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| Pure LTR fast path (`40k ops`, `3.98 MB`) | 63.711 | 68.927 | 62.43 | 57.71 | **1.08×** |
| Mixed Arabic/Hebrew/English (`10k ops`, `900 KB`) | 46.083 | 38.388 | 19.54 | 23.46 | **0.83×** |
| Deep nested isolates & brackets (`5k ops`, `383 KB`) | 30.637 | 27.972 | 12.52 | 13.71 | **0.91×** |
| Per-line `visual_runs` + `reorder_line` (`10k ops`, `900 KB`) | 69.079 | 48.495 | 13.04 | 18.57 | **0.70×** |
