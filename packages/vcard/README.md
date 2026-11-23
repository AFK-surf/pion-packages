# `vcard`

Pure Pion implementation of **RFC 6350** (vCard 4.0), **RFC 2426** (vCard 3.0), **RFC 6868** (Parameter Value Encoding), and vCard 2.1/3.0 **Quoted-Printable** / bare-parameter compatibility — streaming multi-card `.vcf` parser, structured data model, semantic validator, and canonical 75-octet UTF-8-safe serializer.

Built as the CardDAV/PIM sister package to `packages/ical`, reusing `packages/base64` for `data:` URIs and vCard 3.0 `ENCODING=b`/`BASE64` binary payloads, with **zero C/FFI dependencies**, **no `World`**, no global mutable state, and full **Native + Wasm32** support.

## Features

- **Content-Line Lexer & Multi-Card Stream Parser (`parse_stream`, `parse_card`, `parse_stream_with_limits`, `parse_bytes`)**
  - Streaming RFC 6350 §3.2 line unfolding (`CRLF`/`LF` + `SP`/`HTAB`) plus Quoted-Printable soft line break (`=\r\n` / `=\n`) handling without copying the entire input upfront.
  - Strict RFC 3629 UTF-8 validation (`is_valid_utf8`, `parse_bytes`) rejecting lone continuations, truncated sequences, overlong encodings, and UTF-16 surrogates.
  - Group prefixes (`item1.EMAIL`, `HOME.TEL`), case-insensitive property and parameter normalization, multi-value parameters (`TYPE=work,voice`), quoted parameter values, and vCard 2.1/3.0 valueless parameter shorthand (`TEL;WORK;VOICE:+1-555-0100`, `PHOTO;BASE64:...`, `NOTE;QUOTED-PRINTABLE:...`).
  - **RFC 6868** parameter value escaping/unescaping (`^n` → LF, `^'` → `"`, `^^` → `^`, unknown `^x` preserved).
  - Preserves all custom `X-*` extension properties and property group names.
  - Explicit DoS guardrails via `VCardLimits` (`max_bytes`, `max_cards`, `max_properties_per_card`, `max_line_bytes`, `max_params_per_prop`).
- **Structured & Typed Data Model**
  - Exact escape-aware splitting (`split_escaped`, `split_text_list`, `join_text_list`) that distinguishes escaped `\,`, `\;`, `\\`, `\n`/`\N` from structural delimiters.
  - `N` (`StructuredName`: 5 semicolon-separated components, each comma-separated multi-value), `FN`, `NICKNAME`, `ADR` (`Address`: 7 components + `LABEL`/`TYPE`/`PREF`/group), `ORG` (`Organization`: multi-level hierarchy), `TEL`, `EMAIL`, `IMPP`, `URL`, `BDAY`/`ANNIVERSARY` (`PartialDate`: full, extended ISO, yearless `--MMDD`/`--MM-DD`, truncated `---DD`/`YYYY-MM`/`YYYY`, date-time with timezone offset), `GEO` (vCard 4.0 `geo:lat,lon` & vCard 3.0 `lat;lon`), `TZ`, `UID`, `REV`, `PRODID`, `CATEGORIES`, `NOTE`, `KIND`, `LANG`, `GENDER` (`Gender`), `MEMBER`, `RELATED`, `CLIENTPIDMAP` (`ClientPidMap`), `PREF` (`1..100`), `ALTID`, `PID`.
  - Inline binary & URI media decoding for `PHOTO`, `LOGO`, `KEY` (`MediaValue::Uri` / `MediaValue::Inline(BinaryValue)`), supporting RFC 6350 `data:[<mediatype>];base64,...` URIs (`parse_data_uri` / `format_data_uri`) and vCard 3.0 `ENCODING=b`/`BASE64`.
- **Validation & Canonical Serializer (`validate`, `format_card`, `format_stream`, `fold_line`)**
  - RFC 6350 semantic validation: required `VERSION` & `FN`, `PREF` integer bounds `1..100`, `GENDER` sex code (`""`/`M`/`F`/`O`/`N`/`U`), `CLIENTPIDMAP` (`positive_int;uri`), `KIND` values, and `MEMBER` restricted to `KIND:group`.
  - Canonical CRLF (`\r\n`) serializer with **75-octet UTF-8-safe line folding** (never splits 2/3/4-byte UTF-8 sequences such as CJK or emoji).
  - Automatic CRLF injection defense across property values, group/property/parameter names, and RFC 6868 parameter values.

## Quick Start

```pion
import "vcard"

fn example(raw : String) -> Result[String, vcard::VCardError] {
  let cards = match vcard::parse_stream(raw) {
    Ok(cs) => cs
    Err(e) => return Err(e)
  }
  if cards.length() > 0 {
    let c = cards[0]
    let _ = vcard::validate(c)
    let _ = c.fn_name()
    let _ = c.structured_name()
    let _ = c.addresses()
    let _ = c.emails()
  }
  Ok(vcard::format_stream(cards))
}
```

## Verification

- **Unit & compliance tests**: `sh scripts/verify.sh packages/vcard` — **13/13 `vcard` tests** (36/36 including `base64`) covering RFC 6350 / RFC 2426 / RFC 6868 unfolding, UTF-8 validation, groups, multi-value & bare parameters, Quoted-Printable, structured properties (`N`, `ADR`, `ORG`, `GENDER`, `CLIENTPIDMAP`, `BDAY`/`ANNIVERSARY`, `GEO`, `PHOTO`/`LOGO`/`KEY`), semantic validation, 75-octet UTF-8 CJK/emoji folding, CRLF injection defense, and DoS limits.
- **4-Mode `wasm_smoke`** (`native_dbg`, `native_rel`, `wasm_dbg`, `wasm_rel` with clean `PION_CACHE_DIR`):
  - All 4 modes exit `0` with byte-identical stdout SHA-256:
    `062b3062a404dbb21182c199bdaf2c749dcd1b03aae768a1317d58c5bf86cd13`

## Head-to-Head Benchmarks (`pion --release` vs Go `emersion/go-vcard v0.1.0`)

Run via `sh packages/vcard/bench/run_bench.sh` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 equality check, Platform: `Darwin arm64`):

| Workload | Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup | Stdout SHA-256 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| **W1**: Enterprise 4,000-vCard Multi-Card Parse (`2.33 MB`, folded UTF-8 CJK/Emoji, `ADR`/`TEL`/`EMAIL`/`ORG`, RFC 6868) | **`pion`** | 39.245 | 36.247 | 40.794 | 59.48 | **20.91 MiB** | 0.90x | `5c9de8558cfccf2c…` |
| | `go_vcard` (`v0.1.0`) | **35.395** | 33.747 | 39.291 | **65.94** | 33.44 MiB | 1.00x | `5c9de8558cfccf2c…` |
| **W2**: Parse + Structured Extraction (`N`/`FN`/`ADR`/`ORG`/`EMAIL`/`TEL`) + 75-Octet Folded Roundtrip (`2,000` vCards, `1.17 MB`) | **`pion`** | 43.098 | 41.565 | 45.294 | 27.07 | **13.84 MiB** | 0.92x | `739025f926a04efb…` |
| | `go_vcard` (`v0.1.0`) | **39.466** | 38.167 | 46.289 | **29.56** | 28.25 MiB | 1.00x | `739025f926a04efb…` |
| **W3**: High Escape Density + Base64 Avatar (`data:` URI & vCard 3.0 `ENCODING=b`) Parse & Roundtrip (`1,000` vCards, `647 KB`) | **`pion`** | 23.782 | 23.261 | 25.161 | 27.19 | **6.34 MiB** | 0.91x | `90ce94a71657fa96…` |
| | `go_vcard` (`v0.1.0`) | **21.679** | 20.930 | 22.360 | **29.83** | 15.27 MiB | 1.00x | `90ce94a71657fa96…` |

### Honest Analysis

- **Throughput (0.90x–0.92x vs Go `emersion/go-vcard v0.1.0`)**: Pure Pion is within ~8–10% of compiled Go across all three workloads (`59.5 MB/s` vs `65.9 MB/s` on W1; `27.1 MB/s` vs `29.6 MB/s` on W2; `27.2 MB/s` vs `29.8 MB/s` on W3). The remaining gap comes primarily from byte-by-byte `StringBuilder` assembly in the streaming unfolder and slice copies in `parse_property_line`, whereas Go's `bufio.Reader` + zero-copy `string` slicing copies whole runs in `memmove`.
- **Memory Efficiency (1.60x–2.41x lower Peak RSS)**: Pion's flat `Array[VCardProperty]` representation avoids Go's per-card `map[string][]*Field` hash tables and GC heap overhead (`20.91 MiB` vs `33.44 MiB` on W1; `13.84 MiB` vs `28.25 MiB` on W2; `6.34 MiB` vs `15.27 MiB` on W3).
- **Spec Fidelity Notes**: `emersion/go-vcard v0.1.0` eagerly unescapes `\,` and `\\` during line decoding (which can conflate escaped commas with list delimiters in `N` and leaves `\;` unescaped in `FN`/`NOTE`) and does not implement RFC 6868 parameter unescaping natively. `packages/vcard` preserves raw escapes until structured splitting, natively supports RFC 6868 and Quoted-Printable, and enforces explicit `VCardLimits` DoS bounds.
