# `gif` (`v0.1.0`)

Pure Pion GIF87a / GIF89a multi-frame animated LZW decoder.

- **100% Pure Pion**: `0 extern "C"`, `0 World`, `0` external dependencies, `0` module-level mutable state (`DecodeLimits` is `Send`).
- **Full GIF87a / GIF89a Support**:
  - Header & Logical Screen Descriptor (`GIF87a` / `GIF89a`, GCT, background index, pixel aspect ratio).
  - Graphic Control Extension (`0x21 0xF9`: `delay_cs`, transparency, all 4 Disposal Methods: `Unspecified`, `DoNotDispose`, `RestoreToBackground`, `RestoreToPrevious`).
  - Application Extension (`NETSCAPE2.0` / `ANIMEXTS1.0` loop count), Comment / Plain Text / unknown extension handling.
  - Image Descriptor (Local Color Table, sub-rectangles with clipping, 4-pass Interlaced de-interlacing).
  - High-speed variable-width LSB-first LZW decoder (`min_code_size` 2..8, 12-bit 4096-entry flat tables, 64-bit bit buffer with 48-bit batch refill, stackless backward write, Deferred Clear Code, KwKwK, malformed-code guards).
  - Full-canvas RGBA8888 animation compositor (`decode`, `decode_first_frame`) and raw de-interlaced palette-indexed decoding (`decode_indexed`).
  - `DecodeLimits` bomb guard (canvas dimensions, pixel count, sub-rect pixels, frame count, total output bytes).

## Quick Usage

```pion
import "gif"

let img = gif::decode(raw_bytes)
let first = gif::decode_first_frame(raw_bytes)
let hdr = gif::probe_header(raw_bytes)
```

## Verification

```sh
sh scripts/verify.sh packages/gif
pionc run packages/gif/wasm_smoke
pionc run --release packages/gif/wasm_smoke
pionc run --target wasm32 packages/gif/wasm_smoke
pionc run --release --target wasm32 packages/gif/wasm_smoke
sh packages/gif/bench/run_bench.sh
```
