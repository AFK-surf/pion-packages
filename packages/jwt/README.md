# `jwt` — Pure-Pion RFC 7515 JWS / RFC 7519 JWT / RFC 7517 JWK

Zero-dependency, pure-Pion, Wasm32-friendly implementation of **RFC 7515 (JWS)**, **RFC 7519 (JWT)**, and **RFC 7517 (JWK)** with symmetric HMAC signing (**HS256 / HS384 / HS512**), extensible `Signer`/`Verifier` hooks, and standalone exported cryptographic primitives (**FIPS 180-4 SHA-256 / SHA-384 / SHA-512**, **RFC 4231 HMAC-SHA2**, **strict RFC 4648 §5 unpadded Base64URL**, and **constant-time byte comparison**). No `World` dependency and no C FFI.

## Features

- **Standalone Cryptographic Primitives (`src/crypto.pion`, `src/base64url.pion`)**:
  - `sha256`, `sha384`, `sha512`: FIPS 180-4 compliant, 8-way register-unrolled compression, verified across 0B / 55B / 56B / 64B / 111B / 112B / 128B / 1 MiB boundaries.
  - `hmac_sha256`, `hmac_sha384`, `hmac_sha512`: RFC 4231 compliant (all 7 official vectors including > block-size keys), zero-intermediate-buffer inner→outer chaining.
  - `base64url_encode`, `base64url_decode`, `base64url_decode_bytes`: strict RFC 4648 §5 unpadded Base64URL using top-level `FixedArray` LUTs; rejects `+`, `/`, `=`, whitespace, non-ASCII, `len % 4 == 1`, and **non-canonical trailing bits** (prevents signature malleability).
  - `constant_time_eq(a, b)`: constant-time byte equality for MAC verification.
- **JWT / JWS / JWK Engine (`src/jwt.pion`, `src/json.pion`, `src/types.pion`)**:
  - `encode`, `decode`, `decode_header` (unverified preview), plus extensible `encode_with_signer` / `decode_with_verifier` (`Signer` / `Verifier`).
  - `Header` (`alg`, `typ`, `kid`, `cty`, `crit`, `extra`), `Claims` (`iss`, `sub`, `aud` single string or string array, `exp`, `nbf`, `iat`, `jti`, `custom : Map[String, JsonValue]`), and `Validation` (explicit `algorithms` allowlist, `leeway`, `validate_exp`, `validate_nbf`, `validate_aud`, `required_spec_claims`, `iss`/`aud`/`sub`, `max_token_bytes`, `max_json_depth`, pure `now_unix : Int64` parameter).
  - `Jwk` (`kty: "oct"`): `Jwk::from_oct_key`, `Jwk::to_json`, `Jwk::from_json`, `Jwk::to_secret_bytes`.
- **Hardened Secure Defaults & Red-Team Defenses (Aligned with Rust `jsonwebtoken 12.0.0`)**:
  - **Non-empty HMAC secrets**: `encode`, `decode`, `Signer::hmac`, `Verifier::hmac`, `Jwk::from_json`, and `Jwk::to_secret_bytes` all reject empty (`len == 0`) keys (`InvalidKey` / `InvalidJwk`).
  - **Mandatory `exp` by default**: `Validation::new` / `Validation::with_algorithms` default to `required_spec_claims: ["exp"]` so tokens without expiry are never silently accepted forever (callers can explicitly clear `required_spec_claims` and set `validate_exp = false` when needed).
  - **Strict `aud` validation by default (RFC 7519 §4.1.3)**: `Validation.validate_aud` defaults to `true`; tokens carrying an `aud` claim are rejected with `InvalidAudience` when the verifier has not configured `validation.aud` (prevents cross-service token replay).
  - Hard-rejects `alg: "none"` (case-insensitive: `"none"`, `"None"`, `"NONE"`, `"nOnE"`).
  - Enforces explicit `validation.algorithms` allowlist (rejects empty allowlist and header/verifier algorithm mismatch — immune to algorithm confusion).
  - Rejects unrecognized or empty `crit` headers per RFC 7515 §4.1.11.
  - Built-in strict RFC 8259 JSON parser rejects **duplicate JSON keys** (prevents claim smuggling), enforces a **hard nesting depth cap (`<= 128`)** on both native and wasm32 (prevents JSON stack-overflow bombs even if callers raise `max_json_depth`), enforces **token byte-size limits**, uses correctly rounded IEEE 754 `Double` parsing (`-0.0` preserved, non-finite numbers rejected on parse and `encode`, out-of-`Int64` integers in custom claims fall back to finite `Float`), supports RFC 7519 §2 fractional NumericDate with conservative rounding (`floor` for `exp`/`iat`, `ceil` for `nbf`), and uses overflow-free saturating `leeway` arithmetic.
  - Enforces strict 3-segment structure (exactly 2 `.`, non-empty segments, no whitespace/newlines) and verifies signatures before parsing claims.
  - **Red-Team Audit**: Verified across 270,128 SHA-2/HMAC/Base64URL differential vectors (0 diffs vs RustCrypto), 3-way JWT differential & interop suites, wasm32 byte-for-byte parity, and recursion depth crash probes (0 SIGSEGV / 0 `RangeError`).

## Verification

```sh
pionc fmt --check packages/jwt
pionc check --json packages/jwt
pionc test --json packages/jwt
pionc build --release --target wasm32 -o /tmp/jwt_wasm_smoke.wasm packages/jwt/wasm_smoke
node "$HOME/.pion/share/pion/pion_wasm_rt.mjs" /tmp/jwt_wasm_smoke.wasm
```

## Formal Verification (Lean 4)

The security-critical pure kernels of `packages/jwt` are extracted directly from `packages/jwt/src/*.pion` (`#verify`) via `pionc extract-lean` into Lean 4 (`Jwt.Types`, `Jwt.Funs`) and verified end-to-end in Lean 4 (`v4.36.0-rc2` + `Aeneas` + `PionLean`) with **0 `sorry`**, **0 `admit`**, **0 `native_decide`**, **0 `bv_decide`**, and only the three standard Lean axioms (`propext`, `Classical.choice`, `Quot.sound`).

Reproduce the full proof build, `#print axioms` audit, and Lean-vs-Native Pion differential check:

```sh
sh packages/jwt/proofs/run_proofs.sh
```

### Verified Theorems (`packages/jwt/proofs/JwtProofs.lean`)

1. **Constant-Time Byte Comparison (`packages/jwt/src/crypto.pion`)**:
   - `constant_time_eq_spec`, `constant_time_eq_total`, `constant_time_eq_iff`, `constant_time_eq_refl`, `constant_time_eq_symm`: For all valid `Bytes` `a, b`, `constant_time_eq` never panics/goes out-of-bounds and decides exact byte equality (`constant_time_eq a b = ok true ↔ a = b`).
2. **Anti-CVE Algorithm & HMAC Key Gate (`packages/jwt/src/types.pion`, `packages/jwt/src/jwt.pion`)**:
   - `algorithm_equals_iff`, `algorithm_from_str_as_str`, `algorithm_from_str_ok_iff`: `algorithm_from_str` accepts only `"HS256"`, `"HS384"`, `"HS512"` and roundtrips with `algorithm_as_str`.
   - `algorithm_from_str_rejects_none_variants`, `algorithm_from_str_rejects_unknown`: All 16 case variants of `"none"` (`"none"`, `"None"`, `"NONE"`, `"nOnE"`, …) always return `Err(AlgorithmNoneNotAllowed)`; all other unknown algorithms return `Err(UnsupportedAlgorithm _)`.
   - `hmac_key_valid_iff`, `hmac_key_valid_rejects_empty`: Empty HMAC keys (`key.length() == 0`) are unconditionally rejected.
   - `alg_in_allowlist_spec`, `alg_in_allowlist_empty`, `check_verifier_alg_iff`: Empty allowlists reject all algorithms, and `check_verifier_alg` enforces both `header_alg ∈ allowlist` and `header_alg = verifier_alg` (immune to algorithm confusion).
3. **Saturating `exp` / `nbf` Time-Window & Leeway Overflow Immunity (`packages/jwt/src/jwt.pion`)**:
   - `saturating_add_nonneg_spec`, `saturating_sub_nonneg_spec`, `normalize_leeway_spec`: Exact `ℤ` saturation (`min(INT64_MAX, a + b)` and `max(INT64_MIN, a - b)` for `b ≥ 0`, negative leeway clamped to `0`).
   - `is_expired_sound`, `is_expired_iff_of_gt_min`, `is_expired_zero_leeway`: Across all `Int64` values (including `INT64_MIN`, `INT64_MAX`, and extreme `leeway`), if `now ≥ exp + max(0, leeway)` in exact `ℤ`, `is_expired` always rejects (zero signed wraparound); `leeway = 0` matches `now ≥ exp` exactly.
   - `is_immature_spec`, `is_immature_zero_leeway`: Exact mathematical equivalence `is_immature now nbf leeway = ok (decide (now + max(0, leeway) < nbf))` across all `Int64` values.
4. **Strict Unpadded Base64URL Codec & Canonical Tail Bits (`packages/jwt/src/base64url.pion`)**:
   - `b64url_encode_decode_roundtrip`: For all `0 ≤ v < 64`, `b64url_decode_byte (b64url_encode_val v) = ok v`.
   - `b64url_decode_byte_spec`, `b64url_decode_rejects_invalid_chars`: Accepts only `A-Z`, `a-z`, `0-9`, `-`, `_`; unconditionally rejects `+`, `/`, `=`, whitespace, control bytes, and non-ASCII bytes (`-1`).
   - `base64url_len_valid_iff`, `base64url_len_valid_rejects_mod4_eq1`, `base64url_encoded_decoded_len_roundtrip`: Rejects all `len % 4 = 1` and proves encoded/decoded length roundtrip.
   - `base64url_tail_bits_valid_iff`: Enforces canonical zero trailing bits (`rem = 2 → last_val % 16 = 0`, `rem = 3 → last_val % 4 = 0`), preventing Base64URL signature malleability.
5. **SHA-256 Bitwise Primitives (`packages/jwt/src/crypto.pion`)**:
   - `sha256_ch_same`, `sha256_maj_same_xy`, `sha256_maj_symm_xy`, `sha256_rotr_spec`, `sha256_rotr_compose`, `sha256_sigmas_total`: Algebraic identities and shift-overflow freedom for `sha256_ch`, `sha256_maj`, `sha256_rotr`, and `Σ0`/`Σ1`/`σ0`/`σ1`.

### Proof Artifacts

- `packages/jwt/proofs/JwtProofs.lean`: Full Lean 4 proof suite over `Jwt.Funs`.
- `packages/jwt/proofs/CheckAxioms.lean`: `#print axioms` audit across all 37 main theorems (only `propext`, `Classical.choice`, `Quot.sound`).
- `packages/jwt/proofs/EvalDiff.lean`: `#guard` + `#eval` suite over extracted `Jwt.Funs`, cross-checked byte-for-byte (`diff -u`) against Pion native execution by `run_proofs.sh`.
- `packages/jwt/proofs/run_proofs.sh`: Self-contained verification script using `/private/tmp/pion-lean-jwt` (zero git worktree pollution).

## Head-to-Head Benchmarks (Pion Native vs Rust `jsonwebtoken 12.0.0` vs Go `golang-jwt/jwt/v5 v5.3.1`)

Measured on `Darwin arm64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification). Reproducible via `sh packages/jwt/bench/run_bench.sh` (all build artifacts, `Cargo.lock`, `go.sum`, and corpus isolated in `/tmp`).

### Bench 1: Sign / Encode 50,000 JWTs (25,000 HS256 + 25,000 HS512)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (ops/s) | ns/op | Peak RSS | Speedup (vs `rust_jsonwebtoken`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 150.028 | 147.757 | 152.324 | 333,271 | 3000.56 | 1.95 MiB | **0.39x** |
| `rust_jsonwebtoken` (`12.0.0`, `--release`) | 58.353 | 56.970 | 59.274 | 856,854 | 1167.06 | 2.28 MiB | 1.00x (baseline) |
| `go_golang_jwt` (`v5.3.1`) | 101.761 | 100.608 | 106.362 | 491,347 | 2035.22 | 18.19 MiB | 0.57x |

- Verified common stdout SHA-256 (all 50,000 generated tokens bit-for-bit identical across all 3 implementations):
  `9636875f1e3f086e5919fe68afc497b2546c33c7e537888aaa1b3168a01fbf6d`

### Bench 2: Verify / Decode 50,000 JWTs (25,000 HS256 + 25,000 HS512 + `exp`/`nbf`/`iss`/`aud` Validation)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (ops/s) | ns/op | Peak RSS | Speedup (vs `rust_jsonwebtoken`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 182.783 | 180.810 | 194.363 | 273,548 | 3655.67 | 28.16 MiB | **0.34x** |
| `rust_jsonwebtoken` (`12.0.0`, `--release`) | 62.162 | 60.077 | 70.407 | 804,350 | 1243.25 | 15.42 MiB | 1.00x (baseline) |
| `go_golang_jwt` (`v5.3.1`) | 107.808 | 107.122 | 115.416 | 463,787 | 2156.16 | 42.44 MiB | 0.58x |

- Verified common stdout SHA-256:
  `8e46e6e648d8b3f24d2ad00ff40c08f537f02000766e0b6df96929f62d23d5c5`

### Optimization & Performance Notes

1. **8-way register-unrolled SHA-256/512 + zero-intermediate-buffer HMAC**: Eliminating per-round register shifts and chaining inner hash state directly into outer block `w[]` (plus single-buffer `encode` and direct slice HMAC on `decode`) reduced Sign from `200.2 ms → 150.0 ms` (**1.33x**) and Verify from `260.3 ms → 182.8 ms` (**1.42x**).
2. **Zero-allocation standard JSON key scanner & ASCII-fast string writer**: Matching standard JWT keys (`alg`/`typ`/`kid`/`cty`/`crit`/`iss`/`sub`/`aud`/`exp`/`nbf`/`iat`/`jti`) directly on raw bytes with a bitmask duplicate detector eliminates ~400k temporary key string allocations per 50k verifications.
3. **Honest hardware gap note**: On `Darwin arm64`, both Rust `sha2` (`jsonwebtoken 12.0.0`) and Go stdlib `crypto/sha256`/`sha512` accelerate SHA-2 via ARMv8 Cryptography Extensions (`SHA256H`/`SHA512H` hardware SIMD), whereas `packages/jwt` executes 100% pure-Pion scalar SHA-2 (zero C FFI, portable to `wasm32`). Despite running purely in scalar software, Pion sustains **333k signs/s** and **274k verifications/s** with the **lowest Sign Peak RSS (1.95 MiB)** of all three implementations.
