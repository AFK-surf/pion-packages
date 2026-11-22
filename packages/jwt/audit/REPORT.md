# Red-team audit: `packages/jwt` (`feat/pkg-jwt` @ `e1ed360`)

Target: pure-Pion `packages/jwt` (HS256/384/512 JWS, JWT validation, `oct` JWK, SHA-2,
HMAC, Base64URL, strict JSON). References: Rust `jsonwebtoken` **12.0.0** (RustCrypto
`sha2` 0.11.1 / `hmac` 0.13.0 / `base64` 0.23.1 / `serde_json` 1.0.154, `--release`) and
Go `golang-jwt/jwt/v5` **v5.3.1** (Go 1.27 stdlib `crypto/*`, `encoding/base64`,
`encoding/json`). Platform: Darwin arm64 (Apple Silicon), `pionc 0.1.0`, node for wasm32.

Main source was only read. Everything below sits in `packages/jwt/audit/` and runs with:

```sh
sh packages/jwt/audit/run_audit.sh            # all: build, tests, diff, interop, wasm, probe, bench
sh packages/jwt/audit/run_audit.sh tests      # just the Pion red-team suite
```

(artefacts go to `$AUDIT_OUT`, default `${TMPDIR:-/tmp}/pion-jwt-audit`; the worktree stays clean.)

| Piece | What it is |
| --- | --- |
| `tests/findings_test.pion` | One test per finding, written as the **correct** behaviour: FAIL now, PASS once fixed. |
| `tests/control_test.pion` | 17 `control_*` tests for attack surface that held up; they PASS now and catch regressions. |
| `oracle/` | Pion CLI oracle (`vectors`, `sign`, `bench`, `parse`, `deep`, `deepjwt`), built native **and** wasm32. |
| `diff/rust`, `diff/go` | The same oracle CLI on jsonwebtoken 12.0.0 / golang-jwt v5.3.1. |
| `diff/gen_vectors.py` | 270,128 crypto/Base64URL vectors + 184-token JWT attack corpus (signed with Python `hmac`). |
| `diff/gen_adv_bench.py` | 7 adversarial token shapes for the head-to-head benchmark. |
| `diff/compare.py` | Three-way verdict diff, classifying every divergence. |

## Verdict

**No P0.** No forgery, signature bypass, algorithm confusion, claim smuggling or
memory-safety bug is reachable with default settings. The SHA-2/HMAC/Base64URL primitives
match RustCrypto **byte for byte on all 270,128 vectors**, and wasm32 output matches native
on every corpus.

The weaknesses are **unsafe defaults compared with jsonwebtoken (3 × P1)** and **numeric/JSON
fidelity, interop and recursion-hardening issues (6 × P2)**. Current suite:
`pionc test -p jwt_redteam_audit` gives **32 tests: 17 PASS (all controls), 15 FAIL (all findings)**.

| ID | Sev | Finding | Evidence (test / diff row) |
| --- | --- | --- | --- |
| F1 | **P1** | Empty HMAC secret is accepted by `encode`, `decode`, `Signer/Verifier::hmac` and `Jwk::from_json({"k":""})` | `p1_empty_hmac_key_*`, `p1_empty_jwk_k_*`; diff `key/empty_key_signed_empty`: pion=OK, rust=ERR |
| F2 | **P1** | `Validation::new()` does not require `exp`: tokens that never expire are accepted | `p1_default_validation_must_require_exp` |
| F3 | **P1** | A token that names an `aud` is accepted when the verifier configured no audience (RFC 7519 §4.1.3 "MUST be rejected") | `p1_default_validation_must_reject_unexpected_aud` |
| F4 | P2 | Out-of-range numbers (`1e400`) are accepted as `inf`; the serializer writes bare `inf` / `nan`, so a token Pion signs cannot be verified by anyone, Pion included | `p2_number_out_of_double_range_*`, `p2_serializer_must_not_emit_invalid_json_*`; diff `json/big_custom_1e400`: the only PION_ONLY_ACCEPTS row; interop `pion_sign/float/f_inf`, `f_nan` |
| F5 | P2 | Float parsing is not correctly rounded (`0.3` → 0.30000000000000004, DBL_MAX mis-read), `-0.0` loses its sign, `Float(1.0)` round-trips as `Int` | `p2_float_parsing_*`, `p2_float_must_roundtrip_as_float` |
| F6 | P2 | A custom claim with an integer outside Int64 (`u64` ids, `2^63`) makes the whole token fail | `p2_custom_claim_integer_beyond_i64_*`; interop `rust_sign/custom_u64_max`, `go_sign/custom_u64_max`: pion=ERR, rust=OK, go=OK |
| F7 | P2 | Non-integer NumericDate (`exp: 4000000000.5`, `4e9`) is rejected, although RFC 7519 §2 allows it and both references accept it | `p2_non_integer_numericdate_*`; interop `rust_sign/exp_fractional`, `go_sign/exp_fractional` |
| F8 | P2 | `now_unix + leeway` overflows Int64: a huge leeway turns every token with an `nbf` into `ImmatureSignature` | `p2_leeway_arithmetic_must_not_overflow` |
| F9 | P2 | No hard nesting cap, and both parsing and freeing `JsonValue` recurse: native SIGSEGV at about 80k levels; **wasm32 crashes at 2,000 levels**, which fits inside a default 16 KiB token once `max_json_depth` ≥ 2000 | `p2_json_parse_must_enforce_a_hard_depth_cap`; `run_audit.sh probe` |

---

## P1 findings

### F1: Empty HMAC secret accepted everywhere

`hmac_for_alg` / `Signer::hmac` / `Verifier::hmac` / `encode` / `decode` take `key : Bytes`
without checking its length. `Jwk::from_json("{\"kty\":\"oct\",\"k\":\"\"}")` returns a JWK whose
`to_secret_bytes()` is empty. jsonwebtoken 12 refuses this:
`EncodingKey::from_secret(&[])` / `DecodingKey::from_secret(&[])` →
`ErrorKind::InvalidKeyFormat` (`src/encoding.rs:35`, `src/decoding.rs:96`). golang-jwt
accepts it, as Pion does.

Why P1: the usual way this happens is `secret = env("JWT_SECRET").to_bytes()` with the variable
unset. Anyone can then mint tokens. The diff row and the forging test:

```
key/empty_key_signed_empty   pion=OK sub=616c696365   rust=ERR   go=OK
pion_sign/empty_key          pion=OK                  rust=ERR   go=OK
```

Fix: return `Err(InvalidKey…)` for an empty key in `encode`, `decode`, `Signer::hmac` and
`Verifier::hmac` (these need a `Result`, or a check inside `sign_fn`/`verify_fn`), and in
`Jwk::from_json` / `to_secret_bytes`. Optionally add a minimum length (RFC 7518 §3.2:
key ≥ hash output size).

### F2: `exp` is not required by default

`Validation::new` / `with_algorithms` set `required_spec_claims: []`. jsonwebtoken 12
`Validation::new` sets `required_spec_claims = {"exp"}` (`src/validation.rs:120-131`).
`decode(tok("{\"sub\":\"admin\"}"), …, Validation::new(HS256), now)` succeeds, so a token
from a debug tool or a buggy issuer stays valid forever. Fix: default `["exp"]`.

### F3: Unexpected `aud` accepted

With `validation.aud = None`, Pion skips audience processing completely. jsonwebtoken 12
defaults to `validate_aud: true` and rejects a token that has `aud` when the verifier
names none (`(TryParse::Parsed(_), None) => InvalidAudience`, `src/validation.rs:322-345`),
as RFC 7519 §4.1.3 requires. With Pion, a token minted for `billing-service` can be
replayed against any other service that shares the HMAC key. Fix: add
`validate_aud : Bool = true`; when it is set and `aud` is present but `validation.aud` is
`None`, return `InvalidAudience`.

## P2 findings

### F4: Non-finite floats (`1e400` → `inf`; serializer writes `inf` / `nan`)

`parse_double_simple` multiplies by 10.0 up to 1000 times, so `1e400` becomes `+inf` and
the token is accepted. This is the **only** PION_ONLY_ACCEPTS row in the whole corpus;
serde_json and encoding/json both reject "number out of range". `write_json_value` prints
`Float` with `Double::to_string`, which emits `inf`, `-inf` and `nan`. `encode` therefore
signs payloads that are not JSON. `run_audit.sh interop` prints them:

```
pion_sign/float/f_inf        {"sub":"f_inf","exp":4000000000,"f":inf}
pion_sign/float/f_nan        {"sub":"f_nan","exp":4000000000,"f":nan}
```

All three verifiers reject these tokens, Pion's own `decode` included. Fix: reject
non-finite values in `parse_number` and in `encode` / `json_stringify` (return `Err`),
or emit `null` as serde_json does.

### F5: Float parsing is not correctly rounded

`parse_double_simple` accumulates the fraction as `acc + d * scale` with `scale *= 0.1`
and applies the exponent by repeated multiplication:

| input | Pion | correct (serde_json / Go / IEEE) |
| --- | --- | --- |
| `0.3` | `0.30000000000000004` | `0.3` |
| `1.7976931348623157e308` | `1.7976931348623145e+308` | `1.7976931348623157e+308` |
| `-0.0` | `0` (sign lost) | `-0.0` |
| `Float(1.0)` → stringify → parse | `"1"` → `Int(1)` | `1.0` → float |

(`2.675` and `1e23` happen to be exact; they are kept as `control_float_parse_*`.)
Custom claims that carry money, scores or coordinates change value after a decode and
re-encode. Fix: a correctly rounded parser (Eisel-Lemire with a big-decimal fallback,
or fall back to the runtime's `strtod`) and a float printer that always keeps a `.0`
or an exponent.

### F6: Integers outside Int64 in custom claims reject the token

`parse_number` returns `InvalidJson("integer overflow")` for any integer above
`i64::MAX`, also inside custom claims. Tokens that jsonwebtoken and golang-jwt themselves
sign with a `u64` id (`"id":18446744073709551615`) fail Pion verification:

```
rust_sign/custom_u64_max   pion=ERR   rust=OK sub=753634   go=OK sub=753634
go_sign/custom_u64_max     pion=ERR   rust=OK sub=753634   go=OK sub=753634
```

Keep the strict Int64 rule for `exp`/`nbf`/`iat`. That rule is correct and covered by
`control_numericdate_int64_edges`. For custom claims, fall back to `Float` (or add a
`BigInt`/raw-number variant) instead of failing.

### F7: Non-integer NumericDate rejected

RFC 7519 §2 says NumericDate is a JSON numeric value and that "non-integer values can be
represented". jsonwebtoken rounds such values (`visit_f64`, `src/validation.rs:376-384`).
golang-jwt parses them as float. Pion returns `InvalidClaims("'exp' must be an integer NumericDate")`:

```
rust_sign/exp_fractional   pion=ERR   rust=OK   go=OK
time/exp_float_exp_form    pion=ERR   rust=OK   go=OK      (exp: 4e9)
time/nbf_float_past        pion=ERR   rust=OK   go=OK
```

This fails closed, but it breaks interop with issuers that emit millisecond-derived floats.
Accept finite floats in range, apply floor/ceil conservatively (floor for `exp`, ceil for
`nbf`), and keep rejecting non-finite values and values outside Int64.

### F8: `now_unix + leeway` overflow

`validate_claims` clamps a negative leeway to 0 (correct, see `control_leeway_semantics`)
but evaluates `now_unix + leeway < nbf_ts` with wrapping arithmetic. With
`leeway = i64::MAX` the sum wraps negative, so a token with `nbf = 1000000000` gets
`ImmatureSignature`. This fails closed, but it is a real arithmetic bug and makes the
behaviour of "disable time checks with a huge leeway" depend on the sign of the
wrapped sum. The `exp` side (`now - leeway`) does not wrap for `now ≥ 0`, as the control
test shows. Fix: saturating add/sub, or compare `nbf_ts - now_unix > leeway` in a
form that cannot overflow.

### F9: No hard depth cap; recursive parse **and** drop

`max_json_depth` / `json_parse(_, max_depth)` take any value, and both `parse_value` and
the destructor of the resulting `JsonValue` recurse. serde_json hard-caps at 128 and Go
`encoding/json` at 10,000, whatever the configuration. Output of `run_audit.sh probe`:

```
native json_parse nest=50000  max_depth=1e9       rc=0
native json_parse nest=80000  max_depth=1e9       rc=139  (parse returns OK, SIGSEGV while freeing)
native decode()   nest=100000 max_json_depth=1e9  rc=139
native decode()   nest=200000 default depth       rc=0    (JsonDepthExceeded — defaults are safe)
wasm32 json_parse nest=1500   max_depth=1e9       rc=0
wasm32 json_parse nest=2000   max_depth=1e9       rc=1    RangeError: Maximum call stack size exceeded (during drop)
wasm32 json_parse nest=3000   max_depth=1e9       rc=1    RangeError (during parse)
wasm32 decode()   nest=4000   max_json_depth=1e9  rc=1    RangeError  — 4000 levels = ~11 KiB token, under the 16 KiB default
wasm32 decode()   nest=4000   default depth       rc=0
```

The defaults (`max_json_depth: 32`, `max_token_bytes: 16384`) are safe. But on wasm32,
an operator who raises `max_json_depth` to a value that looks harmless (2000–10000)
lets a single unauthenticated header, or a signed payload, crash the process, because
the header is parsed before the signature is checked. Fix: clamp `max_depth` to a hard
cap (≤ 128 is plenty for JWT) inside `json_parse` / `parse_*_json`, and/or make
`parse_value` iterative.

### Smaller gaps (no test; API completeness against jsonwebtoken 12)

- `crit: ["b64"]` (RFC 7797 unencoded payload) is rejected. jsonwebtoken supports it
  (`crit/b64_true`: pion=ERR, rust=OK). Rejecting is the safe choice; the feature is missing.
- No `reject_tokens_expiring_in_less_than`, no `iss` array claim support (jsonwebtoken
  `Issuer::Multiple`), and `validate_nbf` is on by default (jsonwebtoken: off). These are
  policy differences, not bugs.
- `decode_header` hard-codes 16 KiB / depth 32 and ignores `Validation`. That is fine for
  safety but inconsistent.
- `Jwk.alg` / `use` are free strings and are not checked against the supported algorithms.
  They are not used for verification, so this is cosmetic.
- At `exp == now`, Pion rejects the token. That is RFC 7519 §4.1.4 ("MUST be before"), and Go
  does the same; jsonwebtoken accepts it (`exp < now - leeway`). Pion is right here; this
  is noted so nobody "fixes" it.

## Controls: attacked and held

All 17 `control_*` tests PASS. The differential adds these facts:

- **Unicode-escape duplicate-key smuggling** (the focus of this audit). The fast path
  (`scan_std_key` + `seen_std` bitmask) handles only raw 3/4-letter keys. Escaped
  spellings (`"sub"`, `"sub"`, `"exp"`, `"alg"`, `"crit"`,
  …) fall back to `parse_string`, which decodes them, maps them to the same claim id and
  hits the same bitmask. Raw+escaped, escaped+raw, header members, custom claims, nested
  objects, `\/` vs `/` and surrogate-pair vs raw-UTF-8 keys are all rejected as duplicates.
  `"Sub"` (`Sub`) correctly stays a separate custom claim. golang-jwt accepts the
  duplicated `sub` / `exp` / `aud` / header members with last-wins (`dup/*`: go=OK
  sub=admin). Pion and jsonwebtoken reject them, and Pion also rejects duplicates in
  custom and nested claims, which jsonwebtoken (`serde_json::Value`, last-wins) accepts.
- **alg**: `none`/`None`/`NONE`/`nOnE`, with an empty or a real signature, missing, number,
  null, array, `hs256`, `"HS256 "`, `"HS256\u0000"`, `RS256`, and an HS512 token against an
  HS256 allowlist are all rejected.
- **crit**: `[]`, `["exp"]`, `["alg"]`, unknown, non-array, `null` and `[1]` are all rejected.
  golang-jwt ignores `crit` entirely (go=OK).
- **RFC 8259**: trailing commas, leading zeros, `+1`, `.5`, `1.`, `1e`, hex, NaN/Infinity,
  single quotes, comments, trailing data, two objects, non-object top level, bad escapes,
  short `\u`, lone/reversed surrogates, raw control bytes, overlong/CESU/truncated/F4 90+
  UTF-8 and a BOM are all rejected. Surrogate-pair emoji, raw emoji, DEL and all JSON
  whitespace are accepted. golang-jwt maps invalid UTF-8 and lone surrogates to U+FFFD
  and accepts them.
- **NumericDate edges**: `i64::MAX` is accepted; `i64::MAX+1`, `u64::MAX`, `1e23`-digits,
  `i64::MIN-1`, string, null, bool and array are rejected without wrapping. `exp: 0` /
  `exp: -0` are rejected as expired; **golang-jwt `MapClaims` treats `exp: 0` as absent and
  accepts the token** (`time/exp_zero`, `time/exp_neg_zero`: go=OK).
- **Signature/structure**: every character of the token substituted (several replacement
  values per position), the three non-canonical tails of the 43-char HS256 signature
  (malleability), truncation, extension, `=`, surrounding whitespace/newline, 2 or 4
  segments and foreign keys are all rejected. golang-jwt accepts the non-canonical
  signature tails and a trailing `\n` (`sig/noncanonical_tail_*`, `fmt/trailing_newline`:
  go=OK).
- **Base64URL**: all 4,096 two-char and 262,144 three-char tails were checked exhaustively.
  A tail is accepted iff it re-encodes identically (exactly 256 / 65,536 accepted). Every
  byte value 0..255 was tried in every quad position: the LUT has 256 entries, nothing
  ≥ 0x80 aliases to a valid digit, and nothing reads out of bounds. Results are
  byte-identical to `base64` 0.23 `URL_SAFE_NO_PAD`. Go `RawURLEncoding.Strict()` silently
  skips `\r`/`\n` (3 GO_ONLY_DEVIATION rows).
- **SHA-256/384/512 and HMAC**: lengths 0..300 plus 383/384/447/448/511/512/1000/1023/1024/
  4095/4096/4097/65535/65536/1 MiB; HMAC key lengths {0,1,20,31,32,48,63,64,65,111,112,127,
  128,129,131,200,256,1000} × 17 data lengths. All 270,128 crypto/Base64 vectors are
  **identical to RustCrypto and to Go** (`total=270128 identical=270125`; the 3 others are
  the Go CR/LF quirk above).
- **`constant_time_eq`**: by code review, it returns early only on unequal *length* (public
  information; `hmac.Equal` and `subtle` do the same). The loop ORs every byte XOR with no
  data-dependent branch or early exit. A single-bit difference in any position of 64 bytes
  is detected.
- **JWK**: non-`oct` kty (case-sensitive), missing/non-string `k`, non-canonical, padded or
  standard-alphabet `k`, raw and escaped duplicate `k`, mistyped `kid`/`use` and a top-level
  array are all rejected. Unknown members are ignored (RFC 7517 §4).
- **Serializer round-trip**: hostile strings (CJK, emoji, `"`, `\`, all C0 controls incl.
  NUL, U+2028/2029, U+FFFF, U+10FFFF, empty) in `sub`, `aud[]`, a custom key/value and
  `kid` survive `encode` → `decode` for HS512. Rich Pion-signed tokens (unicode, `aud`
  array, nested custom objects, a 300-byte key above the SHA-512 block size, header `kid` +
  extra member) verify under jsonwebtoken and golang-jwt, and their rich tokens verify
  under Pion (`interop`: 77/82 identical; the 5 differences are F1, F6 and F7).
- **wasm32**: the same oracle compiled with `--target wasm32` and run under
  `pion_wasm_rt.mjs` produces byte-identical output to native on all three corpora
  (270,128 + 184 + 82 lines).

## Performance

### Fairness review of `packages/jwt/bench/`

- Outputs are byte-identical (stdout SHA-256 is checked) and the runs are strictly
  interleaved. The setup is fair as far as it goes.
- jsonwebtoken reads the system clock in every `decode` (`get_current_timestamp()`), while
  Pion and Go get a fixed `now`. This gives a small, conservative handicap **against Rust**.
- jsonwebtoken deserializes into a typed struct; Pion builds `Claims` plus a `Map` and Go
  decodes into a typed `BenchClaims` struct. These are comparable.
- **Blind spot**: the corpus has a single shape, ~250-byte tokens with 7 registered claims.
  It never exercises large payloads, many custom claims, deep nesting or escapes, so the
  README numbers say nothing about them. The table below covers them.
- The README's "hardware SHA-2" explanation is correct, and the `parse` rows (HMAC removed)
  below confirm that it explains most of the gap.

### Adversarial shapes (`run_audit.sh bench`; median of 5 interleaved rounds, stdout SHA-256 verified)

`bench` = full `decode` (HMAC-SHA256 + Base64URL + JSON + validation). `parse` = Base64URL +
generic JSON parse of the payload only (Pion `json_parse`, `serde_json::Value`, Go `any`),
which isolates the parser from the SHA-2 hardware gap.

| Shape | Mode | ops | Pion median ms (ns/op) | Rust median ms (ns/op) | Go median ms (ns/op) | Pion vs Rust | Pion vs Go | Peak RSS P / R / G |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `baseline_small` | verify | 64000 | 226.5 (3539) | 85.2 (1331) | 182.5 (2851) | **0.38x** | 0.81x | 2.1 / 2.5 / 16.9 MiB |
| `baseline_small` | parse | 64000 | 70.1 (1095) | 43.8 (684) | 100.5 (1570) | **0.62x** | 1.43x | 2.0 / 2.2 / 16.6 MiB |
| `long_ascii_string_11k` | verify | 3200 | 379.9 (118723) | 67.9 (21214) | 99.9 (31221) | **0.18x** | 0.26x | 2.6 / 2.6 / 21.0 MiB |
| `long_ascii_string_11k` | parse | 3200 | 100.5 (31402) | 37.9 (11846) | 65.9 (20580) | **0.38x** | 0.66x | 2.5 / 2.5 / 16.0 MiB |
| `escape_heavy_string` | verify | 3200 | 306.8 (95861) | 94.8 (29628) | 145.6 (45507) | **0.31x** | 0.47x | 2.5 / 2.7 / 17.2 MiB |
| `escape_heavy_string` | parse | 3200 | 96.2 (30055) | 56.3 (17601) | 121.3 (37906) | **0.59x** | 1.26x | 2.4 / 2.6 / 16.4 MiB |
| `unicode_raw_3k` | verify | 3200 | 328.4 (102621) | 82.3 (25724) | 115.3 (36039) | **0.25x** | 0.35x | 2.5 / 2.6 / 16.6 MiB |
| `unicode_raw_3k` | parse | 3200 | 91.7 (28645) | 50.4 (15740) | 96.1 (30031) | **0.55x** | 1.05x | 2.4 / 2.5 / 16.0 MiB |
| `many_custom_claims_700` | verify | 3200 | 444.1 (138796) | 315.5 (98601) | 437.1 (136578) | **0.71x** | 0.98x | 2.6 / 2.7 / 17.5 MiB |
| `many_custom_claims_700` | parse | 3200 | 236.0 (73750) | 264.5 (82655) | 425.4 (132949) | **1.12x** | 1.80x | 2.5 / 2.5 / 17.6 MiB |
| `float_array_700` | verify | 3200 | 530.2 (165675) | 130.3 (40733) | 301.4 (94198) | **0.25x** | 0.57x | 2.6 / 2.8 / 17.4 MiB |
| `float_array_700` | parse | 3200 | 247.3 (77269) | 83.0 (25946) | 264.6 (82687) | **0.34x** | 1.07x | 2.5 / 2.6 / 17.6 MiB |
| `deep_nesting_30x150` | verify | 800 | 302.0 (377441) | 192.9 (241163) | 442.8 (553488) | **0.64x** | 1.47x | 2.8 / 3.2 / 17.3 MiB |
| `deep_nesting_30x150` | parse | 800 | 245.8 (307268) | 177.3 (221623) | 415.0 (518763) | **0.72x** | 1.69x | 2.7 / 3.1 / 17.5 MiB |

`Pion vs X` = X median / Pion median (> 1.00x means Pion is faster). Stdout SHA-256 identical across all three implementations in every row.

Reading the table honestly:

- **Pion loses every verify row to Rust** (0.18x–0.71x). The cause is mostly SHA-2: the
  difference *verify − parse* (≈ HMAC-SHA256 cost) on `long_ascii_string_11k` is
  ≈ 87 µs/token for Pion against ≈ 9.4 µs for jsonwebtoken (~15 KB token: ≈ 170 MB/s
  scalar against ≈ 1.6 GB/s ARMv8 SHA2). Rust's SHA-2 uses the hardware instructions;
  Pion's is portable scalar code.
- **Pion also loses parse-only rows to Rust**, except `many_custom_claims_700` (1.12x
  faster). The parser itself has hot spots: string slices go through
  `slice_bytes_to_string` (byte loop + `to_string`), giving 0.38x on a long ASCII string.
  Floats are re-sliced into a `String` and parsed by `parse_double_simple`, giving 0.34x;
  that function is also the source of F5.
- Against Go, Pion's JSON parser **wins or ties 6 of 7 parse rows** (1.05x–1.80x;
  `long_ascii_string_11k` 0.66x is the exception). In full verify it loses wherever large
  payloads make SHA-2 dominate.
- Peak RSS: Pion ≈ Rust (2–3 MiB) and ≈ 7x below Go (16–21 MiB) in every row.
- No input shape produced super-linear behaviour in any implementation (all three scale
  linearly with payload size; the deep-nesting rows stay within 32 levels).

## Reproduce single items

```sh
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
pionc test --json -p jwt_redteam_audit packages/jwt/audit/tests          # 15 FAIL = findings, 17 PASS = controls
pionc test --json -p jwt_redteam_audit --filter p1_empty_hmac_key_must_be_rejected_by_decode packages/jwt/audit/tests
sh packages/jwt/audit/run_audit.sh build && sh packages/jwt/audit/run_audit.sh probe   # F9 crash table
sh packages/jwt/audit/run_audit.sh diff && sh packages/jwt/audit/run_audit.sh interop  # three-way verdict tables
```
