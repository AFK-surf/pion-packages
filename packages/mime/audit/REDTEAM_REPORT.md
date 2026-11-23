# `packages/mime` red-team audit (Wave 10 · RT-mime)

Baseline: `origin/feat/pkg-mime` @ `7663d14`. References: Go 1.27.3 `mime`, `mime/multipart`,
`mime/quotedprintable`, `net/http.DetectContentType`; Rust `mime 0.3.18`, `infer 0.16.0`; RFC 2045/2046/2047/2231/
5987/6266/7578/9110 and WHATWG MIME Sniffing. Toolchain: `pionc 0.1.0` (AFK-surf/pion `c375cee`), Darwin arm64.

Reproduce everything (artifacts go to `/private/tmp/rt-mime`, nothing is written into the repo):

```sh
sh packages/mime/audit/run_audit.sh all     # build | unit | diff | perf
```

| Piece | What it does |
|---|---|
| `src/main.pion` | Pion harness: 13 batch modes (`mt cd fmt qpdec qpenc qpencb ewdec ewq ewb sniff safe neg mp`) + `mtn`/`mpfile` perf modes |
| `go/main.go`, `rust/src/main.rs` | Same modes and output format on Go 1.27 stdlib / Rust mime + infer |
| `diff.py` | Seeded adversarial corpora (5,000 cases per parser mode, 40,500 total), runs Pion native debug/release + wasm32 debug/release + Go + Rust, buckets every divergence |
| `perf_gen.py` | Adversarial perf probes (Horspool worst case, param bombs, fan-out) |
| `redteam_test.pion` | 16 `redteam_*` tests (FAIL while the defect exists) + 10 `control_*` tests (PASS) |

## Summary

| ID | Sev | Finding | Evidence |
|---|---|---|---|
| P0-1 | **P0** | Parameter parsing is O(n²): every `Part::form_name()` / `filename()` / `parse_media_type` on attacker headers | 64 parts × 60 KiB (3.8 MB): **Pion 2.6–4.6 s / 10.1–13.2 s vs Go 52–59 ms / 214–225 ms (45–90× / 47–59×)**; wasm32 10.5–12.0 s |
| P1-1 | P1 | Multipart: bare `\n--boundary` inside a CRLF message starts a new part (smuggling vs Go/RFC) | `redteam_p1_mp_bare_lf…` FAIL (2 parts, Go 1); diff: 8 extra-part + 86 split-body + 366 split-then-error cases |
| P1-2 | P1 | One undecodable `filename*` / `name*` makes the **whole** header fail, losing the RFC 6266 `filename` fallback and the form name | `redteam_p1_cd_bad_ext…` FAIL; diff: 731/5000 (mt), 716/5000 (cd) Pion ERR where Go parses |
| P1-3 | P1 | `safe_filename()` passes Windows device names, trailing dot/space, ADS/drive `:`, U+202E, 300-byte names | `redteam_p1_safe_filename…` FAIL (`CON` returned unchanged) |
| P1-4 | P1 | Horspool search degrades to ~70 compares/byte on periodic boundaries | 8 MiB body: **Pion 447–577 ms vs Go 23–29 ms (15.5–24.7×)**; wasm32 1.4–2.4 s |
| P1-5 | P1 | `MultipartWriter` has no random boundary and never checks bodies for the delimiter → part injection | `redteam_p1_writer…` FAIL (round trip yields 2 parts) |
| P1-6 | P1 | `sniff_mime` sniffs untrusted bytes as scriptable `image/svg+xml` | `redteam_p1_sniff…svg` FAIL; Go → text/plain / text/xml, infer → None / text/xml |
| P2-1…12 | P2 | Java class → Mach-O; WHATWG HTML rules; Accept all-or-nothing; fatal RFC 2231 section errors; benign duplicates rejected; MSIE `\` paths; `--b--garbage` close; NUL in part headers; QP all-or-nothing; split UTF-8 encoded-words; `format_media_type` star names; sniff coverage gaps | 11 `redteam_p2_*` FAIL + diff buckets below |

Pion is **not** worse everywhere: 4-mode consistency is perfect (0 traps, 0 differences over 40,500 cases), the
QP binary encoder and RFC 2047 encoders are byte-identical to Go on 7,000 cases, and in five places Pion is better
than Go 1.27 (see Controls).

---

## P0

### P0-1 Quadratic parameter parsing (CPU DoS through the normal multipart API)

Root cause, `src/media_type.pion`:
- fast path, duplicate check is a linear scan per parameter: `:245-246` (`while k < out.length() { if out[k].name == key`);
- RFC 2231 path: plain duplicate scan `:364`, `(base, index)` duplicate scan over all sections `:412-414`, base de-dup
  `:434`, and for **every** base and **every** section index a linear search over all sections `:456-466`
  (O(bases × sections)), then merge scans `:524`, `:545`, `:560-564`.

`MultipartLimits` bounds a part header at 64 KiB, which still holds ~6,600 parameters. Every `Part::form_name()`,
`Part::filename()`, `Part::content_disposition()` re-parses that header (`src/types.pion`, `Part::content_disposition`).
`max_parts` = 1000 and the total body is not bounded, so one request carries up to 1000 such headers.

`sh run_audit.sh perf` (bench_compare.py, warmup 1, rounds 5, identical stdout SHA-256). The host was shared and
loaded, so two full runs are shown; compare ratios (the user-CPU column below is cleaner):

| Probe (`perf_gen.py`) | Pion median (run 1 / run 2) | Go 1.27 median | Pion/Go |
|---|---:|---:|---:|
| 64 parts × 60 KiB plain params (`p0=x; p1=x; …`), 3.8 MB | 4,646 / 2,630 ms | 51.6 / 58.7 ms | **90.0× / 44.8×** |
| 64 parts × 60 KiB RFC 2231 bases (`p0*0=x; …`), 3.8 MB | 10,120 / 13,171 ms | 213.8 / 224.7 ms | **47.3× / 58.6×** |
| same, wasm32 release (node) | 10.49 / 12.02 s | — | — |

Single header, parse only (`mtn` mode, user CPU): 16,000 plain params 0.15 s vs 0.00 s; 16,000 RFC 2231 bases
1.00 s vs 0.01 s; 10,000 sections of one base 0.15 s vs 0.00 s. Scaling 4k → 16k params is ×15–×17 (quadratic).
Extrapolated, a 60 MB request (1000 × 60 KiB headers) costs ~2.5 CPU-minutes in Pion and ~3 s in Go.

Fix: index parameters in a hash map (or sort once) for duplicate detection; bucket RFC 2231 sections by base into a
per-base array indexed by section number (sections are already capped at 10,000), so reassembly is O(n).
Consider a parameter-count cap in `MultipartLimits`.

## P1

### P1-1 Bare-LF delimiter inside a CRLF message smuggles a part

`src/multipart.pion:306-311` (body end search) and `:257` (first boundary) accept `\n--boundary` and `\r\n--boundary`
interchangeably for every occurrence. RFC 2046 §5.1.1 defines the delimiter as `CRLF "--" boundary`; Go accepts
bare LF only when the **first** delimiter line ends in LF and then stays in that mode (`isBoundaryDelimiterLine`).

```
--b\r\nContent-Disposition: form-data; name="a"\r\n\r\nhello\n--b\r\nContent-Disposition: form-data; name="admin"\r\n\r\ntrue\r\n--b--\r\n
Go 1.27 : 1 part  a = "hello\n--b\r\nContent-Disposition: form-data; name=\"admin\"\r\n\r\ntrue"
Pion    : 2 parts a = "hello", admin = "true"
```

A Go (or any RFC-following) proxy/WAF validates one field, the Pion back end receives an extra attacker-named field.
Diff (`mp`, 5000 messages): 8 messages where Pion sees more parts, 86 where Pion cuts a body at a bare LF delimiter,
366 where that cut then turns into a header error. Test: `redteam_p1_mp_bare_lf_delimiter_smuggles_part_in_crlf_message`.

Fix: decide the line-ending mode from the first delimiter line (as Go does) and only accept `nl + "--" + boundary`
afterwards.

### P1-2 An undecodable extended parameter fails the whole header

`src/media_type.pion:384-396` (single `name*`) and `:483`, `:497-505` (continuations) propagate every
`split_ext_value` / `percent_decode_strict` / `decode_charset_bytes` error out of `parse_params_block`, so
`parse_content_disposition` returns `Err` and `Part::filename()` / `form_name()` return `None`.
RFC 6266 §4.3 and Appendix D design `filename` + `filename*` precisely so a recipient that cannot decode
`filename*` falls back to `filename`; Go drops only the bad parameter.

```
attachment; filename="fallback.txt"; filename*=windows-1252''na%EFve.txt   Go: filename=fallback.txt   Pion: Err(InvalidCharset)
attachment; filename="fallback.txt"; filename*=UTF-8''%ff.txt              Go: filename=fallback.txt   Pion: Err(InvalidCharset)
form-data; name="upload"; filename="a.txt"; filename*=koi8-r''%E1         Go: FormName()=upload        Pion: form_name()=None
```

Diff buckets (`P1:pion_err_go_ok:bad_ext_value_kills_whole_header`): **731/5000** media types, **716/5000**
dispositions (InvalidCharset 462/470, InvalidPercentEncoding 165/157, InvalidParameterValue 104/89).
Fix: on a decode failure skip that parameter (keep the plain one), as Go does.

### P1-3 `safe_filename()` is not safe for Windows/SMB targets or UIs

`src/types.pion:132-175` only takes the substring after the last `/` or `\`, removes C0/DEL and rejects `.`/`..`.
Probes (`safe` mode / test `redteam_p1_safe_filename_windows_and_spoofing_bypasses`):

| input | returned |
|---|---|
| `CON`, `nul`, `COM1`, `LPT9.log`, `aux.txt` | unchanged (DOS devices) |
| `evil.exe.`, `evil.exe ` | unchanged (Windows strips → `evil.exe`; extension allow-list bypass) |
| `a:b:$DATA`, `C:evil` | unchanged (NTFS ADS / drive-relative) |
| `U+202E gnp.exe` | unchanged (bidi spoofing) |
| ` ` (single space), 300 × `x` | unchanged (whitespace-only, > NAME_MAX) |
| `\xc2\x85x` (C1 NEL), `.htaccess` | unchanged |

Go's `Part.FileName()` is only `filepath.Base`, but it is not advertised as "safe"; the README advertises
`safe_filename()` as path-traversal protection. Fix: reject or rewrite reserved device stems (case-insensitive, with
any extension), trailing `.`/space, `:`, bidi controls and C1 controls, and cap at 255 bytes (UTF-8 aware).

### P1-4 Boyer–Moore–Horspool worst case (~25× slower than Go)

`src/multipart.pion:41-61`: Horspool compares backwards and shifts by `skip[last byte]`. With boundary `a`×70 the
pattern is `--aaaa…a`; on a body of `a` bytes the last byte always matches, 70 bytes verify, and the shift is 1.
The package's own red-team test only covers the distinct-byte near-miss case.

| 8 MiB single-part body (run 1 / run 2) | Pion | Go 1.27 | Pion/Go |
|---|---:|---:|---:|
| random printable (typical) | 19.7 / 17.8 ms | 25.7 / 25.8 ms | 0.8× / 0.7× |
| near-miss `--boundary1234567890` (package's own case) | 19.6 / 24.2 ms | 24.3 / 24.9 ms | 0.8× / 1.0× |
| **`a`×70 boundary, body all `a`** | **576.7 / 446.5 ms** | 23.4 / 28.8 ms | **24.7× / 15.5×** |
| same, wasm32 release | 1.42 / 2.43 s | — | — |

The boundary is chosen by the sender, so a 64 MiB part (default `max_part_bytes`) costs ~3.5–4.5 s.
Fix: switch to Two-Way / Crochemore-Perrin, or add a Galil-style rule / fall back to a memchr-of-`-` scan
when the skip table is degenerate (every shift for the last byte = 1).

### P1-5 `MultipartWriter` part injection

`src/multipart.pion:365` takes a caller-supplied boundary (no entropy-based constructor; Go's `NewWriter` draws
30 random bytes) and `write_part` (`:399-430`) / `write_field` (`:436`) never search the body for the delimiter.
With any fixed boundary (as in `wasm_smoke`), a field value
`hi\r\n--fixed-boundary\r\nContent-Disposition: form-data; name="role"\r\n\r\nadmin` round-trips as **two** parts
(`redteam_p1_writer_field_value_injects_parts`). Fix: reject bodies/values that contain `\n--` + boundary (the BMH
searcher is already there) and offer a constructor that takes caller-provided random bytes.

### P1-6 `sniff_mime` promotes untrusted bytes to a scriptable type

`src/sniff.pion:353-360` returns `image/svg+xml` for `<svg…` and for `<?xml` with `<svg` in the first 512 bytes.
WHATWG MIME Sniffing never sniffs SVG (scriptable types are only produced with the explicit sniff-scriptable flag);
Go `DetectContentType` gives `text/plain` / `text/xml`, infer gives None / `text/xml`. An upload served with the
sniffed type executes `<svg onload=…>` (stored XSS). Test `redteam_p1_sniff_promotes_untrusted_bytes_to_svg`.
Fix: never return `image/svg+xml` (and gate `text/html`) unless the caller opts in.

## P2

| ID | Finding | Root cause | Evidence |
|---|---|---|---|
| P2-1 | Java class files (`CAFEBABE` + major ≥ 45) reported as `application/x-mach-binary` | `sniff.pion:303` | infer: `application/java`; test FAIL |
| P2-2 | HTML sniffing ignores WHATWG tag-terminating byte (`<htmlfoo>` → html) and misses `<b `, `<br>`, `<p `, `<a>`; UTF-16 BOM text → octet-stream; `%!PS` → text/plain | `sniff.pion:353-380`, `:182` | Go/infer agree on html; test FAIL |
| P2-3 | Accept is all-or-nothing: `q=0.5555`, a bare token, a comment or a repeated accept-ext fails the whole negotiation | `accept.pion:102`, `:116`, `:121` | `text/html;q=0.5555, application/json` → Err; test FAIL |
| P2-4 | RFC 2231 section errors are fatal: orphan `a*1`, `a*01`, `a*b`, and empty charset `a*=''x` (valid RFC 2231) fail the header | `media_type.pion:104`, `:401`, `:408`, `:497` | diff 705 (mt) / 691 (cd); test FAIL |
| P2-5 | Benign duplicates rejected: equal-valued repeats; `a*` with `a*0` (Go: `a*` wins) | `media_type.pion:247`, `:365`, `:414`, `:531` | diff 313 / 361; test FAIL |
| P2-6 | MSIE paths: `"C:\dev\x.txt"` → `C:devx.txt` (Go keeps `\` before non-tspecials) | `media_type.pion:219`, `:317` | diff 61 / 69; test FAIL |
| P2-7 | `--b--garbage` accepted as close delimiter; later parts silently ignored (Go: error) | `multipart.pion:117-119` | diff 1,080 END-vs-ERR; test FAIL |
| P2-8 | NUL/CTL accepted in part header values (Go textproto rejects) | `multipart.pion:208-225` | `name="a\0b"` → form_name `a\0b`; test FAIL |
| P2-9 | QP decode all-or-nothing: one `=ZZ`, `= `, or final `=` at EOF fails the body (RFC 2045 §6.7 note 2; Go passes `=` through) | `encoding.pion:51`, `:60-67` | diff 1,178/5000; test FAIL |
| P2-10 | Encoded-words splitting one UTF-8 character across adjacent words stay undecoded (Go/Python join) | `encoding.pion:379`, `:436` | diff 275; test FAIL |
| P2-11 | `format_media_type` accepts param names with `*` and emits non-reparsable headers (shared with Go) | `media_type.pion:633` | diff `fmt:pion_roundtrip_broken` 36/1000; test FAIL |
| P2-12 | Sniff coverage vs infer 0.16: octet-stream/text for AVI, bz2, xz, 7z, RAR, PE, MIDI, PSD, CAB, CRX, DICOM, AAC, M4A, QuickTime, ISO-BMFF `iso5`/`iso6`/`mmp4`, deb, SWF | `sniff.pion` | `diff_report.txt` sniff table (no test: coverage, not correctness) |

Divergences found but **not** counted as defects (Pion is RFC-correct or deliberately stricter):
- Multipart obs-fold / space-before-colon / no-colon header lines are rejected (Go folds/accepts): 275 diff cases;
  covered by `control_mp_strict_header_syntax`.
- LF-mode message with `\r\n` before the delimiter: Pion strips the `\r`, Go keeps it in the body (292 cases).
- `{`/`}` in token values rejected (RFC 9110 tchar; Go's tspecials omit braces): 114/111 cases.
- `Accept: application/json;charset=utf-8` does not match a bare `application/json` candidate (RFC 9110 §12.5.1).
- Writer rejects CR/LF in names (Go 1.27 percent-encodes them) – both safe.

## Controls (already correct; Pion better than Go marked ★)

All 10 `control_*` tests PASS; upstream package tests 23/23 PASS.
- Accept q grammar: `1.001`, `.5`, `NaN` rejected; `1.` accepted; `q=0` excludes even with `*/*`; `text/*;q=0` vs
  `text/html`; `level=1` specificity; accept-ext after `q` ignored; `*/html` rejected.
- ★ QP text encoder keeps the line break in `\r` + encoded bytes + `\n` (Go 1.27 drops it: `=FF\r\n=3D~`); the only
  10/5000 `qpenc` differences are this Go bug. `qpencb` 5000/5000, `ewq` 1000/1000, `ewb` 1000/1000 byte-identical.
- ★ RFC 2231 ISO-8859-1 continuations decode (`title*0*=ISO-8859-1''caf%E9` → `café`); Go blanks the value to `""`.
- ★ RFC 2047 unknown charset leaves that word literal and decodes the rest; Go fails the whole header
  (1,312/5000 cases). Pion also refuses SP and `?` inside encoded text (RFC 2047 §2), Go decodes them.
- `safe_filename` strips `../`, `..\`, mixed separators, rejects `.`, `..`, `dir/`, control-only names.
- Writer escapes `"`/`\` in names and filenames (no parameter injection), rejects CRLF.
- Token/case rules, case-insensitive duplicate detection, RFC 2231 continuation joining, `filename*` overrides
  `filename` (RFC 6266 §4.3); QP encoder never splits `=XX` and wraps at ≤ 76 columns.
- Epilogue with a fake delimiter is ignored; nested multipart has no recursive API, so no stack-depth exposure.

## 4-mode Wasm32 consistency

`diff.py` ran every corpus through native debug, native release, wasm32 debug and wasm32 release (node):
**40,500 cases, 0 traps, 0 byte differences** across `mt cd fmt qpdec qpenc qpencb ewdec ewq ewb sniff mp`.
Sniff truncations 1–64 bytes of 89 signatures included. The perf probes also run under wasm32 (see P0-1, P1-4).

## Benchmark fairness (`packages/mime/bench`)

The published numbers are reproducible, but every corpus avoids the paths where Pion is weak:
- **multipart**: the 5 MiB payload is `(j*37+13) & 0xFF`, which makes Horspool shift ~boundary length almost every
  step (best case). No periodic payload (P1-4: 24.7× slower), no header with many params (P0-1: 47–90× slower).
  Go reads through a streaming `io.Reader` and copies bodies, Pion slices one in-memory buffer; worth stating.
- **headers_mt**: 10 templates, none with RFC 2231/escapes/duplicates, so only the fast path is measured.
- **qp**: no lowercase hex, no invalid `=`, no bare CR — all inputs where Pion errors or differs are absent.
- **sniff**: the corpus is exactly the 20 formats Pion supports, every sample hits Pion's first-byte dispatch, and
  `canonicalize_infer` remaps infer's names to Pion's. No text/HTML/JSON/unknown inputs (where Pion runs
  `is_utf8_text` twice) and none of the 21 formats in P2-12.
Recommended additions: the probes in `perf_gen.py` (random/near-miss/worst multipart, param bombs, 1000-part fan-out).
On the typical probes Pion is at parity or ahead of Go (0.7–1.0× time on random body, near-miss and 1000-part fan-out).

## Raw data locations (after `run_audit.sh all`)

`/private/tmp/rt-mime/unit.json`, `diff/diff_report.txt` (every bucket with up to 4 minimal samples, full sniff
table), `diff/cases_*.txt` (exact corpora), `perf/*.md|json` (bench_compare tables with SHA-256).
