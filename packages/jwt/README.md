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
  - `Header` (`alg`, `typ`, `kid`, `cty`, `crit`, `extra`), `Claims` (`iss`, `sub`, `aud` single string or string array, `exp`, `nbf`, `iat`, `jti`, `custom : Map[String, JsonValue]`), and `Validation` (explicit `algorithms` allowlist, `leeway`, `validate_exp`, `validate_nbf`, `required_spec_claims`, `iss`/`aud`/`sub`, `max_token_bytes`, `max_json_depth`, pure `now_unix : Int64` parameter).
  - `Jwk` (`kty: "oct"`): `Jwk::from_oct_key`, `Jwk::to_json`, `Jwk::from_json`, `Jwk::to_secret_bytes`.
- **Day-1 Security Defenses (Immune to Classic JWT CVEs by Default)**:
  - Hard-rejects `alg: "none"` (case-insensitive: `"none"`, `"None"`, `"NONE"`, `"nOnE"`).
  - Enforces explicit `validation.algorithms` allowlist (rejects empty allowlist and header/verifier algorithm mismatch — immune to algorithm confusion).
  - Rejects unrecognized or empty `crit` headers per RFC 7515 §4.1.11.
  - Built-in strict RFC 8259 JSON parser rejects **duplicate JSON keys** (prevents claim smuggling), enforces **nesting depth limits** (prevents JSON bombs), enforces **token byte-size limits**, and rejects **non-integer or out-of-range `Int64` timestamps**.
  - Enforces strict 3-segment structure (exactly 2 `.`, non-empty segments, no whitespace/newlines) and verifies signatures before parsing claims.

## Verification

```sh
pionc fmt --check packages/jwt
pionc check --json packages/jwt
pionc test --json packages/jwt
pionc build --release --target wasm32 -o /tmp/jwt_wasm_smoke.wasm packages/jwt/wasm_smoke
node "$HOME/.pion/share/pion/pion_wasm_rt.mjs" /tmp/jwt_wasm_smoke.wasm
```

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
