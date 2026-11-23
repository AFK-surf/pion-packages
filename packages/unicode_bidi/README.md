# `unicode_bidi` (`v0.1.0`)

Pure-Pion implementation of the **Unicode Bidirectional Algorithm (UAX #9, Unicode 16.0.0)** with zero `extern "C"` and zero `World` dependency.

## Features

- Complete Unicode 16.0.0 UCD tables (`Bidi_Class`, `BidiBrackets` BD16, `BidiMirroring` L4) matching Rust `unicode-bidi 0.3.18` and `unicode-bidi-mirroring 0.4.0`.
- Full UAX #9 rule pipeline:
  - **P1–P3**: paragraph segmentation and first-strong base direction detection (skipping isolate runs)
  - **X1–X8**: explicit embeddings (`LRE`/`RLE`), overrides (`LRO`/`RLO`), isolates (`LRI`/`RLI`/`FSI`/`PDI`), `MAX_DEPTH = 125` overflow and stack-bomb protection
  - **X9–X10**: isolating run sequences (BD13) with fast path when no isolate controls are present
  - **W1–W7**: weak type resolution
  - **N0–N2**: BD16 paired bracket algorithm (63-entry bracket stack cap) and neutral resolution
  - **I1–I2**: implicit level resolution
  - **L1–L4**: trailing whitespace/separator reset, visual run and index reordering, and RTL glyph mirroring
- Fast path for pure-LTR paragraphs and ASCII lookups (`128`-entry LUT).
- Explicit `Limits` / `Result[BidiInfo, BidiError]` API plus Farview-compatible `bidi_line_levels` and `bidi_visual_order` helpers.
- Verified on Native and Wasm32 (`debug` and `--release`).
