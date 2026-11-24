# Third-Party Notices

This repository (`AFK-surf/pion-packages`) is licensed under the MIT License (see `LICENSE`),
except where third-party data tables, test suites, or ported algorithms are noted below.
For all MIT-licensed upstream components listed below, the full MIT License text is provided
in the root [`LICENSE`](LICENSE) file. For Apache-2.0 components, the full Apache License 2.0
text is provided in [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt).

---

## Important Notice: CC BY-SA 4.0 Test Data (Markdown Specification Examples)

> **CC BY-SA 4.0** — The following **test-only** files contain specification examples adapted from
> the CommonMark 0.31.2 Specification (© John MacFarlane) and the GitHub Flavored Markdown (GFM)
> Specification (© GitHub, Inc.), licensed under the Creative Commons Attribution-ShareAlike 4.0
> International License (<https://creativecommons.org/licenses/by-sa/4.0/>):
>
> - `packages/markdown/spec_part1_test.pion`
> - `packages/markdown/spec_part2_test.pion`
> - `packages/markdown/spec_part3_test.pion`
> - `packages/markdown/spec_part4_test.pion`
> - `packages/markdown/gfm_test.pion` (`gfm_table_*`, `gfm_strikethrough_*`, `gfm_tasklist_*`, and
>   `gfm_autolink_*` tests: © GitHub, Inc., CC BY-SA 4.0; `smart_punct_test_*` 16 tests: original
>   test data from `commonmark/cmark` `test/smart_punct.txt`, Copyright (c) 2014, John MacFarlane,
>   BSD-2-Clause, transcribed via `pulldown-cmark/pulldown-cmark` `tests/suite/smart_punct.rs`,
>   © Google Inc., MIT)
>
> These files are **test data only** and are **not compiled into library artifacts**; they do not
> affect the MIT license of the `markdown` library code (`packages/markdown/src/`).

---

## Third-Party Components, Data Tables, and Test Suites

### Brotli (`packages/brotli/src/tables.pion`)
- **Upstream**: `google/brotli` (<https://github.com/google/brotli>)
- **Copyright**: Copyright (c) 2009, 2010, 2013-2016 by the Brotli Authors
- **License**: MIT (full text in `LICENSE`)

### pulldown-cmark (`packages/markdown/src/entities.pion`, `packages/markdown/gfm_test.pion` `smart_punct_test_*`, and parser/entity references)
- **Upstream**: `pulldown-cmark/pulldown-cmark` (<https://github.com/pulldown-cmark/pulldown-cmark>)
- **Copyright**: Copyright 2015 Google Inc. / pulldown-cmark contributors
- **License**: MIT (full text in `LICENSE`)

### commonmark/cmark (`packages/markdown/gfm_test.pion` `smart_punct_test_*` test data)
- **Upstream**: `commonmark/cmark` (`test/smart_punct.txt`, <https://github.com/commonmark/cmark>)
- **Copyright**: Copyright (c) 2014, John MacFarlane
- **License**: BSD-2-Clause:

```text
Copyright (c) 2014, John MacFarlane

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### KaTeX (`packages/texmath/`)
- **Files**:
  - `packages/texmath/src/symbols.pion`
  - `packages/texmath/src/metrics_data.pion`
  - `packages/texmath/src/parser.pion`
  - `packages/texmath/src/lexer.pion`
  - `packages/texmath/src/macros.pion`
  - `packages/texmath/src/mathml.pion`
  - `packages/texmath/src/layout.pion`
  - `packages/texmath/audit/corpus_katex_screenshotter.txt`
- **Upstream**: `KaTeX/KaTeX` (<https://github.com/KaTeX/KaTeX>)
- **Copyright**: Copyright (c) 2013-2020 Khan Academy and other contributors
- **License**: MIT (full text in `LICENSE`)

### imara-diff (`packages/diff/`)
- **Upstream**: `pascalkuthe/imara-diff` (<https://github.com/pascalkuthe/imara-diff>)
- **Copyright**: Copyright Pascal Kuthe
- **License**: Apache-2.0 (full text in `LICENSES/Apache-2.0.txt`)
- **Modification Notice**: Modified and ported from Rust to Pion.

### BurntSushi Crates (`packages/glob/`, `packages/time/`, `packages/csv/`)
- **Upstream**: `BurntSushi/ripgrep` (`globset`), `BurntSushi/jiff`, `BurntSushi/rust-csv`
- **Copyright**: Copyright Andrew Gallant (BurntSushi) and contributors
- **License**: MIT OR Unlicense (MIT full text in `LICENSE`)

### dtolnay/semver & petgraph (`packages/semver/`, `packages/graph/`)
- **Upstream**: `dtolnay/semver` (<https://github.com/dtolnay/semver>), `petgraph/petgraph` (<https://github.com/petgraph/petgraph>)
- **Copyright**: Copyright David Tolnay (`semver`); Copyright petgraph contributors (`petgraph`)
- **License**: MIT OR Apache-2.0 (MIT full text in `LICENSE`; Apache-2.0 full text in `LICENSES/Apache-2.0.txt`)

### MIT Upstream Test Suites & Reference Implementations
The following packages incorporate or adapt test vectors and/or algorithms from MIT-licensed upstream projects (full MIT License text in `LICENSE`):
- `packages/decimal/`: `paupino/rust-decimal` — Copyright (c) 2016 Paul Mason (MIT)
- `packages/crdt/`:
  - `yjs/yjs` (`v13.6.33`) — Copyright (c) 2023 Kevin Jahns `<kevin.jahns@protonmail.com>` and Chair of Computer Science 5 (Databases & Information Systems), RWTH Aachen University, Germany (MIT)
  - `dmonad/lib0` (`v0.2.99`) — Copyright (c) 2019 Kevin Jahns `<kevin.jahns@protonmail.com>`. (MIT)
- `packages/highlight/`: `PrismJS/prism` — Copyright (c) 2012 Lea Verou (MIT)
- `packages/graphql/`: `graphql/graphql-js` (Copyright (c) GraphQL Contributors) / `apollographql/apollo-rs` (`apollo-parser`, Copyright 2021 Apollo Graph, Inc.) (MIT)
- `packages/cbor/`: `fxamacker/cbor` — Copyright (c) 2019-present Faye Amacker (MIT), and RFC 8949 test vectors
- `packages/json5/`: `json5/json5-tests` — Copyright (c) 2012-2016 Aseem Kishore, and [others](https://github.com/json5/json5/contributors). (MIT)
- `packages/toml/`: `toml-lang/toml-test` — Copyright (c) 2018 TOML authors (MIT)
- `packages/yaml/`: `yaml/yaml-test-suite` — Copyright (c) 2016-2020 Ingy döt Net (MIT)
- `packages/msgpack/`: `kawanet/msgpack-test-suite` — Copyright (c) 2017-2018 Yusuke Kawasaki (MIT)
- `packages/jsonschema/`: `json-schema-org/JSON-Schema-Test-Suite` — Copyright (c) 2012 Julian Berman (MIT)

### Unicode Character Database (UCD 13.0.0 / 16.0.0)
- **Files**:
  - `packages/json5/src/unicode_id.pion` (UCD 13.0.0)
  - `packages/regex/src/unicode*.pion` (UCD 16.0.0)
  - `packages/unicode_bidi/src/tables.pion` (UCD 16.0.0)
  - `packages/url/src/idna_tables.pion` (UCD 16.0.0)
  - `packages/url/audit/data/IdnaTestV2.txt` (UCD 16.0.0)
  - `packages/hyphenation/src/unicode.pion` (UCD 16.0.0)
- **Upstream**: Unicode Consortium — Unicode Character Database (<https://www.unicode.org/Public/>)
- **Copyright**: Copyright © Unicode, Inc.
- **License**: Unicode-3.0 (full text in `packages/url/audit/data/LICENSE.unicode`)

### WHATWG Specifications & Embedded Tables (`packages/encoding/src/tables.pion`, `packages/html/src/entities_table.pion`, `packages/webvtt/src/entities_table.pion`)
- **Upstream**:
  - WHATWG Encoding Standard indices (<https://encoding.spec.whatwg.org/>), aligned with Mozilla `encoding_rs`
  - WHATWG HTML Living Standard named character references (<https://html.spec.whatwg.org/entities.json>)
- **Copyright**: Copyright © WHATWG (Apple, Google, Mozilla, Microsoft)
- **License**: WHATWG Living Standards are licensed under CC BY 4.0 (<https://creativecommons.org/licenses/by/4.0/>); portions embedded as source code and data tables are explicitly licensed under the **3-Clause BSD License** per the WHATWG IPR Policy:

```text
Copyright © WHATWG (Apple, Google, Mozilla, Microsoft).

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### Web Platform Tests — WebVTT (`packages/webvtt/`)
- **Upstream**: `web-platform-tests/wpt` (`webvtt/`)
- **Copyright**: Copyright © web-platform-tests contributors
- **License**: BSD-3-Clause (see `packages/webvtt/audit/wpt/LICENSE.md`)

### Web Platform Tests — URL (`packages/url/audit/data/urltestdata.json`, `packages/url/audit/data/setters_tests.json`, `packages/url/wpt_*_test.pion`)
- **Upstream**: `web-platform-tests/wpt` (`url/`)
- **Copyright**: Copyright © web-platform-tests contributors
- **License**: BSD-3-Clause (see `packages/url/audit/data/LICENSE.wpt`)

### Go `archive/tar/testdata` (`packages/tar/src/testdata_test.pion`)
- **Upstream**: The Go Programming Language (`src/archive/tar/testdata`, `go1.27.3`)
- **Copyright**: Copyright 2009 The Go Authors.
- **License**: BSD-3-Clause:

```text
Copyright 2009 The Go Authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google LLC nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### JSONPath Compliance Test Suite (`packages/jsonpath/audit/cts/`)
- **Upstream**: `jsonpath-compliance-test-suite/jsonpath-compliance-test-suite`
- **License**: BSD-2-Clause (see `packages/jsonpath/audit/cts/LICENSE`)

### `hyph-en-us` Hyphenation Patterns (`packages/hyphenation/src/en_us_data.pion`)
- **Upstream**: `hyph-utf8` / `ushyphmax.tex`
- **Copyright**: Copyright (C) 1990, 2004, 2005 Gerard D.C. Kuiken
- **License**: Permissive license with attribution preserved in file header (`packages/hyphenation/src/en_us_data.pion`).

### Mozilla Public Suffix List (`packages/cookie/src/psl_data.pion`, `packages/cookie/audit/psl/`)
- **Upstream**: `publicsuffix/list` @ `763a4c200052` (`public_suffix_list.dat`; audit vectors `tests/test_psl.txt` @ `6ca11f5`, pinned with sha256 in `packages/cookie/audit/psl/PINNED`)
- **Copyright**: Mozilla Foundation and Public Suffix List contributors
- **License**: Mozilla Public License 2.0 (MPL-2.0), https://mozilla.org/MPL/2.0/; MPL-2.0 headers are kept in each file, and the embedded rule table holds the same 10,472 rules re-sorted for O(log N) lookup

### bzip2 / libbzip2-rs (`packages/bzip2/`)
- **Upstream**: `bzip2`/`libbzip2` by Julian R Seward; `libbzip2-rs` (`libbz2-rs-sys` 0.2.3) by Trifecta Tech Foundation (<https://github.com/trifectatechfoundation/libbzip2-rs>)
- **Copyright**: Copyright (C) 1996-2021 Julian R Seward; Copyright (C) 2019-2020 Federico Mena Quintero; Copyright (C) 2021 Micah Snyder; Copyright (C) 2024-2025 Trifecta Tech Foundation and contributors
- **License**: `bzip2-1.0.6` (full license text and copyright notice in [`packages/bzip2/NOTICE`](packages/bzip2/NOTICE)); Pion port additions are licensed under MIT (full text in `LICENSE`), so `packages/bzip2` is licensed under `MIT AND bzip2-1.0.6`.
- **Modification Notice**: Altered version — rewritten and ported to pure Pion as a standalone stream compressor and decompressor.

### Unicode 16.0.0 data files (`packages/idna/src/tables_uts46.pion`, `packages/idna/src/tables_uts39.pion`, `packages/idna/audit/ucd/`)
- **Upstream**: Unicode Consortium — Unicode Character Database, UTS #46 IDNA and UTS #39 Security data, version 16.0.0 (<https://www.unicode.org/Public/16.0.0/ucd/>, <https://www.unicode.org/Public/idna/16.0.0/>, <https://www.unicode.org/Public/security/16.0.0/>)
- **Files**: `IdnaMappingTable.txt`, `UnicodeData.txt`, `CompositionExclusions.txt`, `DerivedNormalizationProps.txt`, `DerivedBidiClass.txt`, `DerivedJoiningType.txt`, `Scripts.txt`, `DerivedCoreProperties.txt`, `BidiBrackets.txt`, `BidiMirroring.txt`, `IdentifierStatus.txt`, `confusables.txt`; the embedded lookup tables are generated from them by `packages/idna/tools/gen_tables.py`, and the red-team audit keeps unmodified gzip copies (plus the `IdnaTestV2.txt` test vectors) with SHA-256 pins in `packages/idna/audit/ucd/LICENSE`
- **Copyright**: Copyright © 1991-2026 Unicode, Inc.
- **License**: Unicode License v3 (SPDX: `Unicode-3.0`), full text in [`packages/idna/audit/ucd/LICENSE`](packages/idna/audit/ucd/LICENSE)

### httpwg/structured-field-tests (`packages/structured_fields/bench/gen_data.py`, `packages/structured_fields/audit/sft/`)
- **Upstream**: `httpwg/structured-field-tests` (<https://github.com/httpwg/structured-field-tests>) @ `4a4782f8234512af133f6f57c4ca998578b57110`
- **Usage**: the 251 core conformance vectors embedded in `packages/structured_fields/bench/gen_data.py`, and unmodified gzip copies of all 20 parsing files plus the `serialisation-tests/` files kept by the red-team audit in `packages/structured_fields/audit/sft/` (test data only; nothing is compiled into the package)
- **Copyright**: Copyright (c) 2018- IETF Trust and the persons identified as authors of the code. All rights reserved.
- **License**: BSD 3-Clause License (SPDX: `BSD-3-Clause`), full text in [`packages/structured_fields/audit/sft/LICENSE.md`](packages/structured_fields/audit/sft/LICENSE.md)

### Unicode 16.0.0 data files (`packages/unicode_segment/src/tables.pion`, `packages/unicode_segment/audit/ucd/`)
- **Upstream**: Unicode Consortium — Unicode Character Database and UAX #29 Text Segmentation test data, version 16.0.0 (<https://www.unicode.org/Public/16.0.0/ucd/>, <https://www.unicode.org/Public/16.0.0/ucd/auxiliary/>, <https://www.unicode.org/Public/16.0.0/ucd/emoji/>)
- **Files**: `GraphemeBreakProperty.txt`, `WordBreakProperty.txt`, `SentenceBreakProperty.txt`, `emoji-data.txt`, `DerivedCoreProperties.txt`, `UnicodeData.txt`; the embedded lookup tables in `packages/unicode_segment/src/tables.pion` are generated from them by `packages/unicode_segment/tools/gen_tables.py`. The red-team audit keeps unmodified gzip copies of these 6 files plus the 3 official test files `GraphemeBreakTest.txt`, `WordBreakTest.txt`, `SentenceBreakTest.txt` in `packages/unicode_segment/audit/ucd/16.0.0/`, and unmodified gzip copies of the same 6 property files from Unicode 17.0.0 (<https://www.unicode.org/Public/17.0.0/ucd/>, used only to detect 16 → 17 property drift) in `packages/unicode_segment/audit/ucd/17.0.0/` (test data only; nothing from 17.0.0 is compiled into the package)
- **Copyright**: Copyright © 1991-2026 Unicode, Inc.
- **License**: Unicode License v3 (SPDX: `Unicode-3.0`), full text in [`packages/unicode_segment/audit/ucd/LICENSE`](packages/unicode_segment/audit/ucd/LICENSE)
