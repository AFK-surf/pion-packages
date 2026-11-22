# Red-team audit: `packages/url` (Pion) vs Rust `url v2.5.9`

- **Target**: `AFK-surf/pion-packages` `feat/pkg-url` @ `fb85513` (`packages/url/src/**`, read-only)
- **Reference**: Rust `url = "=2.5.9"` + `idna = "=1.1.0"` (pinned, `diff/rust/Cargo.lock`), `--release`, LTO
- **Tie-breakers**: Node.js v24.22.2 `URL` (Ada 4.0.0) for WHATWG parsing/setters/URLSearchParams;
  Unicode `IdnaTestV2.txt` (shipped with `idna 1.1.0`) for UTS #46
- **Machine**: Darwin arm64 (Apple Silicon), `pionc 0.1.0`, rustc stable
- **Everything reproduces with one command** (≈ 2 min; builds and outputs go to `$AUDIT_OUT`,
  default `${TMPDIR:-/tmp}/pion-url-audit`; the worktree is never written to):

```sh
sh packages/url/audit/run_audit.sh            # full
QUICK=1 sh packages/url/audit/run_audit.sh    # skip the throughput benchmarks
cd packages/url && pionc test --json audit    # just the red-team unit tests
```

## Verdict

The README's claims (100 % WPT, "UTS #46 non-transitional IDNA", "O(N) 10K `@` flood",
"1.06x faster than rust-url") do not survive adversarial input:

| # | Sev | Finding | Evidence |
|---|---|---|---|
| F-1 | **P0** | `.%2e` / `.%2E` dot-segments never removed on http/https/ws/wss/ftp → path-ACL bypass | 295/8,000 fast-path fuzz cases, `redteam_dot_pct2e_*` |
| F-2 | **P0** | `Url::join` misclassifies non-special schemes (`hdfs`, `foo`, `web`, …) as special → path glued onto host/port, re-parse yields **another host** | `redteam_join_*`, 8 round-trip violations (rust: 0) |
| F-3 | **P0** | IDNA mapping is a ~20-range subset: no NFC, no NFKC/compat, no full case fold → hosts browsers canonicalize identically get different A-labels (`K.com` vs `k.com`) | IdnaTestV2: **Pion 15.52 %** vs rust **99.86 %**; `redteam_idna_*` |
| F-4 | **P0** | UTS #46 validity (CheckBidi, CheckJoiners, disallowed/unassigned, leading combining marks, `xn--` label NFC/P4) not implemented → 5,125 invalid hosts accepted | `idna_conformance.txt` |
| F-5 | **P1** | Quadratic `@`/userinfo parsing: 80 KB URL = 1.8 s (rust 4.6 ms, **396x**) | `dos_scaling.md` |
| F-6 | **P1** | Punycode has no input bound (rust caps at 1000/2000) → n^1.9 decode, 117 KB host = 0.9 s (**163x**) | `dos_scaling.md` |
| F-7 | **P1** | Every setter re-parses/re-serializes the whole URL: 1000 `set_hash` on a 100 KB URL = 573 ms (**107x**) | `dos_scaling.md` |
| F-8 | **P1** | Throughput on non-template corpora: Pion **0.47x** on joins, **0.49x** URLSearchParams, **0.52x** percent-encoding | `adversarial_net.md` |
| F-9 | **P1** | `bench/` is not a fair or clean head-to-head (template corpus tuned to fast paths, unpinned `url = "2"`, dirties worktree) | §5 |
| F-10 | **P2** | rust-url native API divergences (`set_scheme`, `set_host(None)`, `set_host("h:9")`, `set_path` on `file:`) | 894 NATIVE_API diffs in `setters` |
| F-11 | **P2** | API completeness gaps vs rust-url (`path_segments`, `make_relative`, `to_file_path`, `ParseOptions`, custom `AsciiSet`, …) | §6 |

Controls Pion **survived** (and where it is *more* correct than rust-url) are listed in §7 —
they are part of the honest picture.

---

## 1. Method

| Layer | Tool (in this directory) | What it proves |
|---|---|---|
| Unit evidence | `redteam_test.pion` (+ `src/lib.pion` helpers) | 31 tests: **24 `redteam_*` FAIL** (each = one reproducible defect, asserting rust-url's output), **7 `control_*` pass** |
| 3-way differential | `diff/{pion,rust,node}` drivers + `diff/gen_cases.py` + `diff/compare.py` | 110,754 cases (IdnaTestV2, real IDNs, all WPT inputs, grammar+mutation fuzz, fast-path fuzz, 7,416 setter chains, percent-decoding, 3,025 URLSearchParams scripts, 60,000 random crash-hunt cases). Every Pion≠Rust case is triaged with Node/Ada |
| UTS #46 oracle | `diff/idna_conformance.py` | WHATWG `domainToASCII` vs IdnaTestV2 expectations (WHATWG flags applied) |
| Property | `diff/roundtrip.py` | `parse(u.href()) == u` over 19,857 parses/joins |
| DoS | `perf/dos_scaling.py` | median-of-3 wall time at n and 4n, growth exponent, ratio vs rust |
| Throughput | `perf/run_adversarial_bench.sh` (`scripts/bench_compare.py`, SHA-256 gated) | 8 adversarial corpora + matching no-op corpora to subtract driver overhead |

Triage labels (`compare.py`): **PION_BUG** = Rust == Node ≠ Pion; **RUST_DEVIATION** = Pion == Node ≠ Rust
(Pion is right); **STATUS** = same resulting URL, only the setter's Ok/Err differs; **NATIVE_API** =
rust-url-only API (no WHATWG oracle); **THREE_WAY** = all differ. For IDNA the Node tie-breaker is
*not* authoritative (Ada 4.0.0 does not enforce CheckBidi: it accepts `àא` that IdnaTestV2 marks
B1–B6), so IDNA verdicts come from `idna_conformance.py`, where rust-url scores 99.86 %.

### Differential results (`run_audit.sh` §2)

| suite | cases | Pion≠Rust | PION_BUG | RUST_DEVIATION | other |
|---|---:|---:|---:|---:|---|
| `idna` (IdnaTestV2 sources × A/U/P) | 19,161 | 16,220 | 9,828 | 4,272¹ | 2,120 THREE_WAY |
| `idnareal` (121 real-world IDNs) | 484 | 152 | 140 | 6 | 6 THREE_WAY |
| `fastpath` (dot-segment look-alikes) | 8,000 | 296 | **295** | 1 | — |
| `fuzz` (grammar + mutation) | 10,988 | 316 | **77** | **238** | 1 THREE_WAY |
| `setters` (7,416 single/chained) | 7,416 | 1,180 | 0 | 14 | 272 STATUS, 894 NATIVE_API |
| `wpt` (all urltestdata/setters inputs) | 1,143 | 83 | 0 | **66** | 17 STATUS |
| `query` (URLSearchParams scripts) | 3,025 | 1 | 0 | 1 | — |
| `pct` (malformed UTF-8 decode) | 537 | 0 | 0 | 0 | — |
| `random` (crash hunt, every op/setter) | 60,000 | 2,094 | 961⁴ | 187 | 919 NATIVE_API, 26 STATUS, 1 THREE_WAY |

¹ Node/Ada also skips CheckBidi; IdnaTestV2 sides with rust-url on these (see F-4).
⁴ All 961 fall into F-1/F-2/F-3/F-4 (every PION_BUG without non-ASCII input or `.%2e` is an F-2 join).

**No crash, hang or panic in Pion** across all 110,754 cases. rust-url 2.5.9 itself panics on
`Url::parse("foo://@h/")` → `set_port(Some(80))` → `set_host(Some(""))` (`byte range starts at 7
but ends at 5`, `url-2.5.9/src/lib.rs:2880`; the driver records it as `RUST-PANIC`).

---

## 2. P0 — correctness / security

### F-1 `.%2e` dot-segments survive on special schemes (path traversal normalization bypass)

WHATWG: a *double-dot segment* is `..`, `.%2e`, `%2e.` or `%2e%2e` (ASCII case-insensitive).

```
input                              rust-url / Node        Pion
https://h/static/.%2e/admin        https://h/admin        https://h/static/.%2e/admin
http://h/a/.%2E/x                  http://h/x             http://h/a/.%2E/x
https://h/a/b/.%2e?x               https://h/a/?x         https://h/a/b/.%2e?x
foo://h/a/.%2e/x  (non-special)    foo://h/x              foo://h/x          ← slow path is fine
```

Root cause: `try_fast_parse_absolute` (`src/parser.pion:1391-1393`) only sets `path_has_dots`
for a segment that starts with `.`, and its inline resolver (`src/parser.pion:1706-1724`) only
recognises the literal `.` / `..`; `%2e`-first spellings bail out to the slow path (`:1394-1399`),
`.%2e` does not. Any authorization decision made on Pion's `pathname` (prefix allow-lists, static
file roots, proxy routing) disagrees with what the origin server/browser resolves → bypass.
Tests: `redteam_dot_pct2e_segment_is_parent_special`, `redteam_dot_pct2E_segment_is_parent_special`,
`redteam_dot_pct2e_trailing_segment`, `redteam_dot_pct2e_ws_ftp_ipv6`.

### F-2 `Url::join` treats non-special schemes as special (host smuggling on re-parse)

`try_fast_join` (`src/parser.pion:1806-1813`) decides "special, non-file" by **first byte + length**
only: `h` + len 4/5, `w` + len 2/3, `f` + len 3. So `hdfs`, `hive`, `hello`, `web`, `foo`, `fax`, …
take the special-scheme fast path:

```
base                    relative       rust-url / Node                   Pion
hdfs://namenode:8020    user/data      hdfs://namenode:8020/user/data    hdfs://namenode:8020user/data
foo://example.com       x              foo://example.com/x               foo://example.comx      (re-parse host: example.comx)
foo://                  evil.com/x     foo:///evil.com/x  (host "")      foo://evil.com/x        (re-parse host: evil.com)
hdfs://nn:8020/a/       x?q='1'        hdfs://nn:8020/a/x?q='1'          hdfs://nn:8020/a/x?q=%271%27  (special-query set)
```

The produced `Url` object reports `host=""` / `path="evil.com/x"`, but its serialization names
`evil.com` as host: anything that stores/forwards `href` and re-parses it (a proxy, a cache key, a
second service) talks to a different host than the one that was validated.
`diff/roundtrip.py`: **8 non-idempotent results out of 15,876 parsed (rust-url: 0)**, all from this.
Tests: `redteam_join_hdfs_base_path_glued_to_port`, `redteam_join_nonspecial_result_reparses_to_other_host`,
`redteam_join_empty_host_base_smuggles_host`, `redteam_join_nonspecial_gets_special_query_encoding`,
`redteam_href_reparse_is_identity`.

### F-3 UTS #46 mapping is not UTS #46 (canonical-equivalent hosts diverge)

`uts46_map_single` (`src/idna.pion:333-419`) is a hand-written list of ~20 ranges (ASCII,
Latin-1, basic Greek/Cyrillic upper→lower, fullwidth, a few math alphanumerics). There is no
Unicode mapping table, **no NFC**, no NFKC compatibility mapping, no multi-code-point mapping and no
full case folding. Every host below is resolved to the same name by browsers and rust-url; Pion
produces a different, *valid-looking* A-label (or rejects it):

| host | rust-url / browsers | Pion |
|---|---|---|
| `Bücher.de` (decomposed ü) | `xn--bcher-kva.de` | `xn--bucher-xyd.de` |
| `é.com` | `xn--9ca.com` | `xn--e-xbb.com` |
| `K.com` (KELVIN SIGN) | `k.com` | `xn--62g.com` |
| `ﬀ.com` / `℡.com` / `™.com` / `ⓐⓑⓒ.com` / `Ⅻ.example` | `ff.com` / `tel.com` / `tm.com` / `abc.com` / `xii.example` | `xn--im6c.com` / `xn--x2g.com` / `xn--y2g.com` / `xn--vuhcd.com` / `xn--14g.example` |
| `ẞ.de` / `İstanbul.tr` / `ǅ.example` | `xn--zca.de` / `xn--istanbul-o0e.tr` / `xn--d-toa.example` | `xn--kkg.de` / `xn--stanbul-ifb.tr` / `xn--kja.example` |
| `ΠΑΡΆΔΕΙΓΜΑ.ΔΟΚΙΜΉ` | `xn--hxajbheg2az3al.xn--jxalpdlp` | `xn--ewa9fbheg2az3al.xn--hwa9fpadlp` |
| `가.kr` (jamo) | `xn--o39a.kr` | `xn--ypd8q.kr` |
| `XN--BCHER-KVA.DE` (real, uppercase A-label) | `xn--bcher-kva.de` | **rejected** |
| `㍿.jp`, `㈱.jp`, `≠ᢙ≯.솣-ᡴⴀ` | valid | **rejected** (blanket-disallows U+3200..U+33FF, no NFC for `≠`) |

Consequences: origin checks, cookie domains, CORS/CSP allow-lists, HSTS preload and phishing
filters keyed on Pion's host disagree with the browser's (e.g. an allow-list entry `k.com` does
not match the browser-equivalent `K.com`, and two Pion hosts compare unequal while the network
treats them as one). `domain_to_unicode` inherits the same defects (`redteam_domain_to_unicode_case_insensitive_alabel`).

**IdnaTestV2.txt conformance (`run_audit.sh` §3, 6,348 unique sources, WHATWG flags):**

| impl | pass | fail |
|---|---:|---:|
| Pion | **985 (15.52 %)** | 5,363 |
| rust-url 2.5.9 / idna 1.1.0 | 6,339 (99.86 %) | 9² |

Pion failure classes: 5,125 accepts-invalid, 194 wrong-output, 44 rejects-valid.
² rust-url's 9: 2 × V4 (`xn--xn--…`, not checked with CheckHyphens=false) and 7 × V7 Unicode-version
skew between the 15.1 test file and ICU4X data — not WHATWG-relevant.

### F-4 UTS #46 validity criteria missing (invalid hosts accepted)

Of Pion's 5,125 accepts-invalid failures (one test line can carry several codes):

| code family | count | missing check | example accepted by Pion |
|---|---:|---|---|
| V7 | 3,239 | disallowed / unassigned code points | `͸.com` → `xn--zva.com`; `a b.com`; `a⒈com`; `\u{E0001}.com` |
| B1–B6 | 3,358 | CheckBidi (RFC 5893) | `aא.com` → `xn--a-0hc.com`; `1א.com` |
| C1/C2 | 1,776 | CheckJoiners (ContextJ) | `a‍b.com` → `xn--ab-m1t.com` (ZWJ/ZWNJ spoofing) |
| V6 | 1,508 | label starting with combining mark | `a.b.̈c.d` |
| P4 / V1 | 9 | non-ASCII in `xn--` label; A-label decoding to non-NFC | `xn--a-ä.pt` → `xn--xn--a--gua.pt` (double encoding); `xn--u-ccb` |

Invisible ZWJ/ZWNJ and mixed-direction labels are exactly the homograph vectors UTS #46/IDNA2008
validity rules exist to stop. Tests: `redteam_idna_contextj_zwj_zwnj_rejected`,
`redteam_idna_bidi_rule_enforced`, `redteam_idna_unassigned_and_disallowed_rejected`,
`redteam_idna_label_validity`. Per-line evidence: `$AUDIT_OUT/diff/idna_conformance.txt`.

---

## 3. P1 — denial of service (`run_audit.sh` §5, `perf/dos_scaling.py`)

Median of 3 runs at n and 4n; "growth" = log(t₄ₙ/tₙ)/log 4 (process start-up makes small inputs
read below 1). Same-output = byte-identical driver output.

| workload | n | input @4n | Pion n / 4n (ms) | rust n / 4n (ms) | Pion/rust @4n | growth Pion / rust | verdict |
|---|---:|---:|---:|---:|---:|---|---|
| `https://` + n×`@` + `example.com/` | 20,000 | 78 KB | 112.9 / **1,821.5** | 3.5 / 4.6 | **396x** | n^2.01 / n^0.19 | SUPERLINEAR |
| `https://u:` + n×`@` + `h/` | 20,000 | 78 KB | 116.8 / **1,752.9** | 3.9 / 5.1 | **341x** | n^1.95 / n^0.19 | SUPERLINEAR |
| one n-char CJK label (Punycode encode) | 10,000 | 117 KB | 119.1 / **907.0** | 3.7 / 5.6 | **163x** | n^1.46 / n^0.29 | SLOW (rust rejects > 1000 chars) |
| `xn--` label of n CJK chars (Punycode decode) | 5,000 | 58 KB | 35.3 / **496.3** | 4.1 / 6.0 | **82x** | n^1.91 / n^0.28 | SUPERLINEAR (rust rejects > 2000 B) |
| 1000 × `set_hash` on n-segment URL | 12,500 | 104 KB | 144.4 / **572.8** | 4.1 / 5.4 | **107x** | n^0.99 / n^0.20 | SLOW (O(len URL) per setter) |
| 1000 × `set_query` on n-segment URL | 12,500 | 110 KB | 144.4 / **564.2** | 3.9 / 5.7 | **99x** | n^0.98 / n^0.27 | SLOW |

**F-5** `src/parser.pion:688-729`: every extra `@` copies the whole buffer (`"%40" + prev`) and
then re-copies the *growing* `url.username` into a fresh `StringBuilder` → Θ(n²). The existing
`redteam_test.pion` "10K `@` linear" test passes only because 10 K is small (≈45 ms); 80 K takes 1.8 s.

**F-6** `src/idna.pion:147-243` (decode inserts with an O(n) shift per code point) and
`:56-136`/`:641-720` (encode rescans the label per distinct code point) are unbounded. rust's
`idna` caps internal Punycode at `PUNYCODE_ENCODE_MAX_INPUT_LENGTH = 1000` /
`PUNYCODE_DECODE_MAX_INPUT_LENGTH = 2000` (`idna-1.1.0/src/uts46.rs:35,44`) precisely to remove
this quadratic; WHATWG sets VerifyDnsLength=false, so the cap is the only defence.

**F-7** `src/setters.pion:3-19` + `UrlRecord::from_url` (`src/parser.pion:202`): each setter
re-splits the URL into a record, re-runs the state machine and re-serializes everything; rust
edits the one component in place. Building a URL incrementally (k setters on a size-n URL) is
Θ(k·n).

**Not a finding (hypothesis disproved):** `QueryParams::sort` is *not* O(n²): insertion sort is
used only for ≤ 24 pairs, a bottom-up merge sort above (`src/query.pion:595-691`). 100 K reversed
keys sort in 60 ms (n^0.92), 2.3x rust's `Vec::sort_by` — a constant factor, not a DoS. `../`,
`%2e%2e/`, `a/../`, many labels, `%41` hosts and 300 KB paths needing encoding are all linear and
within 1.5x of rust (controls in the same table).

## 4. P1 — throughput on adversarial / non-template corpora (`run_audit.sh` §6)

`scripts/bench_compare.py`, `--warmup 1 --rounds 5`, SHA-256-verified identical stdout. Both
drivers decode hex input and print only field lengths; each corpus has a same-bytes no-op twin
(op `N`) whose median is subtracted, so the last column is library time only
(> 1 = Pion faster):

| workload | cases | net Pion (ms) | net rust (ms) | **Pion speed vs rust** |
|---|---:|---:|---:|---:|
| `adv_join` (varied relative refs, 4 bases) | 200,000 | 120.9 | 56.5 | **0.47x** |
| `adv_query_sort` (parse+delete+append+set+sort, 8–300 pairs) | 7,500 | 160.5 | 79.0 | **0.49x** |
| `adv_pct` (heavy path/query/fragment encoding) | 100,000 | 242.6 | 126.3 | **0.52x** |
| `adv_setters` (7 setters per URL) | 40,000 | 141.4 | 105.6 | **0.75x** |
| `adv_big_url` (325 KB URLs) | 200 | 92.5 | 76.8 | **0.83x** |
| `adv_ipv6` (compressed / embedded-v4 / upper-case) | 200,000 | 80.9 | 70.0 | **0.86x** |
| `adv_idn` (precomposed real IDNs)³ | 100,000 | 64.6 | 61.7 | **0.96x** |
| `adv_ipv4` (dec / hex / octal / 32-bit forms) | 200,000 | 58.4 | 85.8 | 1.47x |

³ Flatters Pion: it skips the NFC / mapping-table / Bidi / ContextJ work rust-url performs (F-3/F-4)
and the corpus is restricted to inputs Pion maps correctly so the outputs can agree.
Numbers from one run on the audit machine; `$AUDIT_OUT/adversarial_bench.md` has median/min/p95/RSS.
A second full run from an empty `$AUDIT_OUT` gave join 0.35x, query 0.50x, pct 0.56x, setters 0.73x,
ipv6 0.82x, big_url 0.92x, idn 1.08x, ipv4 1.26x — same ranking, ±0.1x noise.

## 5. P1 — `bench/` fairness review (F-9)

1. **Corpus tuned to the fast paths.** `bench/gen_data.py` repeats 10 URL templates 10,000× each;
   9 of 10 are absolute `http(s)/ws(s)/ftp` URLs that hit `try_fast_parse_absolute`, the 10th is a
   single relative template (`../v3/items/...`) that hits `try_fast_join`. On varied joins Pion is
   0.47x, not 1.06x (§4). Only 2 IDN templates, both already NFC.
2. **Reference not pinned.** `bench/rust/Cargo.toml` says `url = "2"` and no lockfile is committed:
   the "v2.5.9" in the README is whatever cargo resolves on the day (here 2.5.9 only because it is
   the newest cached). This audit pins `url = "=2.5.9"`, `idna = "=1.1.0"` with a committed `Cargo.lock`.
3. **Dirties the worktree** (AGENTS.md §1.5): `sh packages/url/bench/run_bench.sh` writes an
   untracked `packages/url/bench/rust/Cargo.lock` (verified: `git status --short` →
   `?? packages/url/bench/rust/Cargo.lock`); `CARGO_TARGET_DIR` does not relocate the lockfile.
4. **Fast paths are where the bugs are.** F-1 and F-2 live in exactly the two fast paths the
   benchmark exercises; the speed of `bench/` is partly bought with incorrect output.
5. Peak RSS: Pion 20.6 MiB vs rust 10.6 MiB (W1), 22.7 vs 11.8 MiB (W2) — reproduced; README lists
   it but draws no conclusion.
6. Reproduced on this machine: W1 Pion 119.1 ms vs rust 125.2 ms (1.05x), W2 256.6 vs 248.0 ms (0.97x)
   — the README's numbers hold *for that corpus*.

## 6. P2 — API semantics and completeness

### F-10 rust-url native setter divergences (894 NATIVE_API cases in `setters`)

| call | rust-url 2.5.9 | Pion | test |
|---|---|---|---|
| `foo://h` `set_host(None)` | `foo:/` (still hierarchical) | `foo:` — re-parses as an **opaque** (cannot-be-a-base) URL | `redteam_set_host_none_keeps_hierarchical_url` |
| `set_scheme("h:ttp")` | `Err(())` | `Ok(())`, scheme becomes `h` | `redteam_set_scheme_rejects_invalid_scheme` |
| `http://u:p@h:8080/` `set_scheme("file")` | `Err(())` | `Ok(())` but nothing changes (caller cannot detect refusal) | `redteam_set_scheme_reports_refusal` |
| `set_host(Some("h2:9"))` | `Ok`, host `h2` | `Err` | — (behavioural difference, not a spec bug) |
| `file://host/p` `set_host(None)` / `set_host(Some(""))` | `Ok` → `file:///p` / `Err` | `Err` / `Ok` | — |
| `file:` `set_path("//x")` | `file:///x` | `file:////x` (matches WHATWG `pathname` setter; rust differs) | — |

`set_*` WHATWG (quirks) setters: 0 PION_BUG; the 272 STATUS cases only differ in the returned Ok/Err
(WHATWG setters return nothing), e.g. `host = "h2:99999"` sets the host and Pion reports `Err`.

### F-11 Missing public API relative to rust-url 2.5.9

`Url::path_segments` / `path_segments_mut`, `query_pairs` / `query_pairs_mut` (only the separate
`QueryParams`), `make_relative`, `authority` / `has_authority`, `domain`, `is_special`,
`set_ip_host`, `from_file_path` / `to_file_path` / `from_directory_path`, `socket_addrs`,
`Url::options()` / `ParseOptions` (`base_url`, `encoding_override`, `syntax_violation_callback`),
`Origin::unicode_serialization` and opaque-origin identity (rust's `Origin::new_opaque()` is never
equal to another opaque origin; Pion's `Origin::Opaque` carries no identity and serializes to
`"null"` like every other), `Position`-based slicing, `Hash`/`Ord`, `percent_encoding`'s custom
`AsciiSet` (Pion exposes a closed `EncodeSet` enum), `form_urlencoded::byte_serialize` /
`Serializer`, `ParseError` variants with Display parity (Pion's `ParseError::eq` compares only
the message string).

## 7. Controls — attacks Pion survived

- **No crash / hang / panic** in 110,754 differential cases incl. 60,000 random ones over every op
  and setter (rust-url 2.5.9 panics on one setter chain, §1).
- `percent_decode_str`: 537 malformed-UTF-8 cases (overlong, surrogates `ED A0 80`, truncated,
  > U+10FFFF) — **0 mismatches**, WHATWG U+FFFD replacement exact (`control_percent_decode_invalid_utf8`).
- URLSearchParams: 3,025 random mutate/sort scripts incl. astral vs BMP keys — **0 PION_BUG**; UTF-16
  ordering correct on both sort branches (`control_queryparams_utf16_sort_large`).
- WHATWG quirks setters: **0 PION_BUG** over 7,416 cases.
- IPv4 (all radices, overflow, trailing dot) and IPv6 (compression, embedded IPv4, RFC 5952) — no
  PION_BUG in fuzz (`control_ipv4_ipv6_edge`).
- C0 / TAB / LF / CR / DEL inputs (in the fuzz and random alphabets): no PION_BUG outside F-1..F-4,
  tab/newline stripping and C0 percent-encoding match rust-url.
- Linear and within 1.5x of rust: 80 K `../`, `%2e%2e/`, `a/../`, 80 K labels, 300 KB encoded paths.
- **Pion is more spec-correct than rust-url** in 66/1,143 WPT cases (exactly rust-url's own
  `expected_failures.txt`: `non-special:opaque  ?hi`, `file:\\\\//`, `file:///w|/m`, …) and in 238
  fuzz cases (`control_spec_cases_where_rust_url_deviates`).

## 8. Files

```
audit/
  REPORT.md                 this report
  run_audit.sh              one-shot reproduction (sections 0-6)
  pion.toml, src/lib.pion   audit package (helpers only; depends on ../ by path)
  redteam_test.pion         24 failing redteam_* + 7 passing control_* tests
  data/                     IdnaTestV2.txt (Unicode, via idna 1.1.0), urltestdata.json and
                            setters_tests.json (WPT, via url 2.5.9) — verbatim copies
  diff/pion/                Pion differential driver (hex/TAB line protocol)
  diff/rust/                Rust driver, url =2.5.9 / idna =1.1.0, Cargo.lock committed
  diff/node/driver.mjs      Node.js URL (Ada) tie-breaker driver
  diff/gen_cases.py         deterministic corpus generator (seeded; 10 suites)
  diff/compare.py           3-way differential + triage
  diff/idna_conformance.py  IdnaTestV2 scoring under WHATWG flags
  diff/roundtrip.py         serialization idempotency property
  perf/dos_scaling.py       n vs 4n adversarial scaling
  perf/gen_adversarial.py   adversarial throughput corpora (+ no-op twins)
  perf/run_adversarial_bench.sh  bench_compare.py runner + net-of-overhead table
```
