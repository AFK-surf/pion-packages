# `webvtt` (v0.1.0)

100% pure Pion W3C WebVTT subtitle/caption parser, rich-text cue payload parser, and high-speed `O(log N + K)` playback timeline query engine — zero `extern "C"`, zero `World`, zero external dependencies, `Send`-clean, Native + Wasm32 portable.

## Features

- **W3C WebVTT Specification**:
  - UTF-8 BOM stripping and `\r\n` / `\r` / `\n` line-ending normalization
  - `WEBVTT` signature validation with optional header title & `Key: Value` header metadata
  - `NOTE` comment blocks, `STYLE` CSS blocks (pre-cue, `-->` abort), and `REGION` blocks (`id`, `width`, `lines`, `regionanchor`, `viewportanchor`, `scroll:up`, duplicate-id upsert)
  - Cue identifiers, exact `Int64` millisecond timestamps (`MM:SS.mmm` and arbitrary-digit `HH+:MM:SS.mmm`, overflow-checked), strict & browser-lenient (`parse_lenient`) modes
  - Full cue layout settings: `vertical` (`rl`/`lr`), `line` (percentage or signed line number + `start`/`center`/`end`), `position` (percentage + `line-left`/`center`/`line-right`), `size`, `align` (`start`/`center`/`end`/`left`/`right`/`middle`), `region`
- **Rich-Text Cue Payload & Entities**:
  - `<b>`, `<i>`, `<u>`, `<c.class1.class2>`, `<v Speaker>`, `<lang xx>`, `<ruby>`, `<rt>`, and inline timestamps `<00:12.500>`
  - HTML entity decoding (`&amp;`, `&lt;`, `&gt;`, `&nbsp;`, `&lrm;`, `&rlm;`)
  - Zero-allocation fast-path `plain_text(payload)` for markup-free cues
- **Playback Hot Path (`O(log N + K)`)**:
  - Augmented sorted interval index (`sorted_starts` + `prefix_max_end`) with `O(N)` zero-sort fast path when input cues are already ordered
  - `active_cues_at(track, time_ms)` and `active_cue_indices_at(track, time_ms)` with half-open `[start_ms, end_ms)` semantics
- **DoS Protection (`ParseLimits`)**:
  - Configurable bounds on `max_input_bytes`, `max_cues`, `max_styles`, `max_regions`, `max_notes`, and `max_tag_depth`

## Quick Usage

```pion
import "webvtt"

let track = match webvtt::parse(vtt_source) {
  Ok(t) => t
  Err(e) => ...
}
let active = track.active_cues_at(12500L)
let text = active[0].plain_text()
```

## Verification & Benchmark

```sh
sh scripts/verify.sh packages/webvtt
pionc run --target wasm32 packages/webvtt/wasm_smoke
sh packages/webvtt/bench/run_bench.sh
```
