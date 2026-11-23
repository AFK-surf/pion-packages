# `feed` (`v0.1.0`)

Pure Pion, zero-C-dependency, `World`-free, `Send`-clean, Native + Wasm32 unified syndication feed parser and generator supporting **RSS 2.0** (including 0.91/0.92 compatibility), **RSS 1.0 (RDF)**, **Atom 1.0 (RFC 4287)**, and **JSON Feed 1.0 / 1.1**.

Built directly on in-repo `packages/xml`, `packages/json5`, and `packages/time`, benchmarked head-to-head against Rust `feed-rs 2.4.0`.

## Features

- **Format Auto-Detection & Unified Model (`src/lib.pion`, `src/types.pion`)**:
  - `detect_format`, `parse`, `parse_with_limits`, `parse_bytes`, `parse_bytes_with_limits`.
  - Automatic detection of RSS 2.0/0.91/0.92, RSS 1.0/RDF, Atom 1.0, and JSON Feed 1.0/1.1 with UTF-8 BOM, XML declaration, comment, PI, and leading whitespace tolerance.
  - Unified immutable model: `Feed`, `Entry`, `Person`, `Link`, `Category`, `TextContent` (`Text` / `Html` / `Xhtml`), `Image`, `Generator`, `MediaObject`, `MediaContent`, `MediaThumbnail`, `ItunesMeta`.
- **Atom 1.0 (RFC 4287) (`src/atom.pion`, `src/url_resolve.pion`, `src/xml_util.pion`)**:
  - Full support for `id`, `title`, `subtitle`, `summary`, `content` (`type="text"|"html"|"xhtml"`, iterative zero-recursion XHTML subtree serialization with wrapper `<div>` unwrapping, and out-of-line `src`), `link` (`rel`/`type`/`hreflang`/`title`/`length`), `author`/`contributor`, `category` (`term`/`scheme`/`label`), `published`/`updated`, `rights`, `icon`/`logo`, `generator`, `source`, default and prefixed `atom:` namespaces, and RFC 3986 `xml:base` inheritance across `<feed>`, `<entry>`, and child elements.
- **RSS 2.0 & RSS 1.0/RDF + Namespace Extensions (`src/rss.pion`)**:
  - RSS 2.0 / 0.91 / 0.92 channels and items (`guid` with `isPermaLink`, `enclosure`, `source`, `comments`, `author`, `managingEditor`, `webMaster`, `pubDate`, `lastBuildDate`, `ttl`, `image`, `category`, `generator`) and RSS 1.0 (`rdf:RDF`, `rdf:about`).
  - Extensions: `content:encoded`, Dublin Core (`dc:creator`, `dc:date`, `dc:subject`, `dc:rights`, `dc:identifier`, `dc:language`), Media RSS (`media:group`, `media:content`, `media:thumbnail`, `media:title`, `media:description`), iTunes Podcast (`itunes:author`, `itunes:duration`, `itunes:explicit`, `itunes:image`, `itunes:episode`, `itunes:season`, `itunes:summary`, `itunes:subtitle`), and embedded `atom:link`.
- **JSON Feed 1.0 / 1.1 (`src/json_feed.pion`)**:
  - Strict RFC 8259 JSON parsing via `packages/json5` with `version`, `title`, `home_page_url`, `feed_url`, `description`, `icon`, `favicon`, `language`, `authors` (1.1) and `author` (1.0 fallback), `items[]` (`id`, `url`, `external_url`, `title`, `content_html`, `content_text`, `summary`, `image`, `banner_image`, `date_published`, `date_modified`, `authors`/`author`, `tags`, `language`, `attachments`).
- **Robust Feed Date Parsing (`src/date.pion`)**:
  - `parse_feed_date` parses RFC 3339, ISO 8601 (date-only, space separator, compact offsets, fractional seconds), RFC 2822 / RFC 822 (2-digit/4-digit years, GMT/UTC/EST/EDT/CST/CDT/MST/MDT/PST/PDT/CET/CEST/JST/IST, missing seconds, full/mismatched weekdays, extra whitespace, comments) into `time::Timestamp`.
- **Explicit DoS Limits (`FeedLimits`)**:
  - Enforces `max_bytes` (16 MiB), `max_entries` (10,000), `max_depth` (64), `max_links_per_entry` (64), and `max_text_bytes` (4 MiB) with zero recursive DOM/XHTML walks and linear `StringBuilder` assembly.
- **3-Format Standards-Compliant Serialization (`src/serialize.pion`)**:
  - `to_rss2`, `to_atom`, and `to_json_feed` emit properly escaped, injection-safe XML (via `xml::Writer`) and JSON (via `json5::to_json_string`) with full roundtrip fidelity.

## Quick Start

```pion
import "feed"

let parsed = match feed::parse(raw_xml_or_json) {
  Ok(f) => f
  Err(e) => ...
}

// Re-export the unified Feed to any target format
let rss_xml = feed::to_rss2(parsed)
let atom_xml = feed::to_atom(parsed)
let json_str = feed::to_json_feed(parsed)
```

## Verification

- `sh scripts/verify.sh packages/feed`: **PASS** (`pionc fmt --check`, `pionc check --json`, `pionc test --json`: **12/12 `feed` tests PASS**, **554/554** total including `xml`, `json5`, `time`, 0 failures, clean worktree)
- `packages/feed/wasm_smoke` 4-mode matrix (all exit `0`, byte-identical stdout SHA-256 `21a3dc2ba3107ca3ae92a1362c095ab43e9e2c0cf8c24e5d1853fa004f439c25`):
  - Native debug (`pionc build` + run): exit `0`
  - Native release (`pionc build --release` + run): exit `0`
  - Wasm32 debug (`pionc build --target wasm32` + `node pion_wasm_rt.mjs`): exit `0`
  - Wasm32 release (`pionc build --release --target wasm32` + `node pion_wasm_rt.mjs`): exit `0`

## Head-to-Head Benchmarks

Run with `sh packages/feed/bench/run_bench.sh` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, locked `Cargo.lock`, mandatory stdout SHA-256 verification) on **Darwin arm64** against **Rust `feed-rs 2.4.0`** (`--release --locked`).

### W1: RSS 2.0 + Extensions Batch Parse (1,500 items)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Input: `1,662,560 B` | Ops: `1,500` | SHA-256: `b3c67d04a6d2f41ce97b2750faa1c9b3d0c352f8ba0b22807be59af475b0f519`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_feed_rs) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 25.851 | 24.475 | 30.101 | 64.31 | 17233.81 | 21.42 MiB | **1.02x** |
| `rust_feed_rs` | 26.494 | 25.615 | 29.905 | 62.75 | 17662.47 | 22.28 MiB | 1.00x (baseline) |

### W2: Atom 1.0 (RFC 4287) + XHTML Batch Parse (1,500 entries)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Input: `1,286,339 B` | Ops: `1,500` | SHA-256: `f5208b98f96f479f45ddb998669b73e71952b5b244cdda948890c2ed018b5ee6`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_feed_rs) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 22.418 | 22.230 | 22.505 | 57.38 | 14945.44 | 20.58 MiB | **1.01x** |
| `rust_feed_rs` | 22.564 | 22.195 | 22.883 | 57.01 | 15042.81 | 16.34 MiB | 1.00x (baseline) |

### W3: JSON Feed 1.1 Batch Parse (2,000 items)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Input: `1,080,362 B` | Ops: `2,000` | SHA-256: `3a352691417b907cc7930899917b7f71d2e703a20c6faafb907b0f1b58297123`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_feed_rs) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 17.831 | 17.394 | 18.513 | 60.59 | 8915.71 | 12.22 MiB | 0.90x |
| `rust_feed_rs` | 16.075 | 15.916 | 16.440 | 67.21 | 8037.65 | 15.67 MiB | 1.00x (baseline) |

> **Honest Assessment**: `packages/feed` matches and slightly edges out Rust `feed-rs 2.4.0 --release` on both RSS 2.0 + extensions (**1.02x**, 64.31 MB/s, lower RSS) and Atom 1.0 + XHTML (**1.01x**, 57.38 MB/s), and runs at **0.90x** (60.59 MB/s, with 22% lower RSS) on JSON Feed 1.1 where `feed-rs` uses `serde_json` direct deserialization into structs whereas `packages/feed` builds a `json5::Json5Value` DOM before normalizing.
