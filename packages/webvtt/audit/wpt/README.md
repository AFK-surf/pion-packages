# Vendored upstream WebVTT conformance tests (web-platform-tests)

Source: <https://github.com/web-platform-tests/wpt> at commit `3e4b8e44c5cf5e454dd54f1fa32540775cfd5e07`
(3-Clause BSD, see `LICENSE.md`). Files are byte-for-byte copies; nothing was edited.

| Path here | Upstream path |
| --- | --- |
| `file-parsing/tests/*.html`, `file-parsing/tests/support/*.vtt` | `webvtt/parsing/file-parsing/tests/` |
| `file-parsing/signature-invalid.html`, `file-parsing/support/*.vtt` | `webvtt/parsing/file-parsing/` |
| `cue-text-parsing/dat/*.dat`, `cue-text-parsing/buildtests.py` | `webvtt/parsing/cue-text-parsing/` |

Runners (audit-owned glue, documented at the top of each file):

- `run_file_parsing.mjs <probe>`: evaluates each test page's own assertion block (unmodified JS) against the cues
  `probe track` produces with `webvtt::parse_lenient`; `signature-invalid.html` files must fail to parse.
  `stylesheets.html` is the only test marked not applicable (it inspects `document.styleSheets`).
- `run_cue_text.py <probe> <workdir>`: reads `.dat` files exactly like `buildtests.py`, wraps the input exactly like
  `cue-text-parsing/common.js`, and compares the `test_serializer` layout byte-for-byte.
