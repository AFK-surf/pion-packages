# `crypto`

Zero-dependency, pure-Pion cryptographic primitives package (`World`-free, portable across Native and WebAssembly `wasm32`):

- **Hash functions (FIPS 180-4)**: `Sha1`, `Sha256`, `Sha384`, `Sha512` (streaming `new`, `update`, `update_slice`, `finalize`, `finalize_hex`, `reset` + one-shot `sha1`, `sha256`, `sha384`, `sha512`, `*_hex`).
- **Message Authentication Codes (RFC 2104 / RFC 4231)**: `HmacSha256`, `HmacSha384`, `HmacSha512` (streaming with precomputed inner/outer pad states + one-shot `hmac_sha256`, `hmac_sha384`, `hmac_sha512`, `*_hex`).
- **Key Derivation (RFC 5869)**: `hkdf_sha256_extract`, `hkdf_sha256_expand`, `hkdf_sha256`, `hkdf_sha512_extract`, `hkdf_sha512_expand`, `hkdf_sha512`.
- **Authenticated Encryption (RFC 8439)**: `chacha20_xor`, `poly1305_mac`, `chacha20_poly1305_seal`, `chacha20_poly1305_open`.
- **Constant-Time Equality & Hex Codec**: `constant_time_eq(a, b)`, `bytes_to_hex(data)`, `hex_to_bytes(hex)`.
- **Strict RFC 8032 Ed25519**: `Ed25519KeyPair` (`from_seed`, `public_key`, `sign`), `ed25519_public_key`, `ed25519_sign`, `ed25519_verify`, `ed25519_verify_strict`.
- **RFC 7748 X25519**: `x25519_public_key`, `x25519`, `x25519_raw`.
- **NIST P-256 (secp256r1 / ES256 / WebAuthn)**: `p256_public_key`, `p256_sign_es256` (RFC 6979 deterministic), `p256_verify_es256`, `p256_verify_der`, `p256_secret_from_pkcs8_der`, `p256_secret_from_pkcs8_pem`.
- **RFC 8017 RSA-2048+ (RS256)**: `RsaPrivateKey` (`from_pkcs8_der`, `from_pkcs8_pem`, `public_key`), `RsaPublicKey` (`from_components`, `from_spki_der`), `rsa_sign_rs256` (CRT + Bellcore fault check), `rsa_verify_rs256`.

## Security Semantics

### Ed25519 (RFC 8032)

`ed25519_verify` and `ed25519_verify_strict` enforce **strict single-signature non-malleability** (equivalent to `ed25519-dalek::VerifyingKey::verify_strict`):

1. **Exact lengths**: seed = 32 bytes, public key = 32 bytes, signature = 64 bytes (`InvalidSeedLength`, `InvalidPublicKeyLength`, `InvalidSignatureLength`).
2. **Canonical scalar `S`**: rejects any signature with `S >= L`, preventing `S + kL` signature malleability (`NonCanonicalScalar`).
3. **Canonical point encoding (`A` and `R`)**: rejects `y >= p` (`p = 2^255 - 19`), off-curve points (`InvalidPoint`), and non-canonical negative zero (`x == 0` with sign bit `1`, `NonCanonicalPoint`).
4. **Small-order torsion rejection (`A` and `R`)**: checks `[8]P != O` for both public key `A` and signature point `R`, rejecting all 8 small-order torsion points (`SmallOrderPoint`).
5. **Strict un-cofactored equation**: verifies `[S]B == R + [k]A` directly in projective coordinates.
6. **Side channels**: key generation and signing use a 4-bit fixed-window base-point ladder whose table lookup is branch-free (`ct_eq_nibble` + masked `cmov`). Verification is variable-time (public inputs only).

### X25519 (RFC 7748)

- Reuses the constant-time Ref10 `Fe` arithmetic (`val struct Fe`) and branch-free conditional swaps in the Montgomery ladder.
- `x25519` applies RFC 7748 scalar clamping, masks bit 255 of `peer_public`, and rejects all-zero shared secrets (covering all 8 small-order points) with `CryptoError::SmallOrderPoint`.
- `x25519_raw` omits the all-zero rejection for raw RFC 7748 ladder test vectors.

### HKDF (RFC 5869) & ChaCha20-Poly1305 (RFC 8439)

- `hkdf_sha256_expand` / `hkdf_sha512_expand` enforce `prk.length() >= HashLen` and `0 <= len <= 255 * HashLen`.
- `chacha20_xor` enforces 32-byte key, 12-byte nonce, and rejects 32-bit block counter wrap-around (`CounterOverflow`).
- `chacha20_poly1305_open` verifies the 16-byte Poly1305 tag in constant time (`constant_time_eq`) before decrypting; authentication failure returns `CryptoError::AuthenticationFailed` and never leaks plaintext.

### NIST P-256 (ES256 / DER / PKCS#8)

- Signing (`p256_sign_es256`) uses RFC 6979 deterministic nonces with branch-free Montgomery field arithmetic, complete projective addition/doubling (Renes-Costello-Batina 2015, `a = -3`), and a branch-free 4-bit windowed base-point scalar multiplication.
- Verification (`p256_verify_es256`) validates `x < p`, `y < p`, curve membership `y^2 ≡ x^3 - 3x + b (mod p)`, non-infinity, and `1 <= r < n && 1 <= s < n`.
- `p256_verify_der` enforces strict ASN.1 DER (`SEQUENCE { INTEGER r, INTEGER s }`), rejecting trailing bytes, non-minimal lengths, negative integers, and redundant leading zero padding (WebAuthn/Passkey compliant).

### RSA-2048+ (RS256)

- Enforces modulus size `2048 <= bits(n) <= 8192`, odd `n` and `e >= 3`, and full CRT parameter consistency (`p * q == n`, `dp == d mod (p-1)`, `dq == d mod (q-1)`, `e * dp ≡ 1 (mod p-1)`, `e * dq ≡ 1 (mod q-1)`, `q * qinv ≡ 1 (mod p)`).
- `rsa_sign_rs256` performs CRT exponentiation followed by a **Bellcore fault self-check** (`s^e mod n == em`) before returning the signature.
- `rsa_verify_rs256` rejects wrong lengths and `sig >= n`, and performs a full-length `constant_time_eq` comparison of `s^e mod n` against the single canonical RFC 8017 PKCS#1 v1.5 SHA-256 `DigestInfo` block (with explicit ASN.1 `NULL`), preventing Bleichenbacher's forgery attacks.

### General Notes

- **Zero-length inputs**: empty messages (`Bytes::new(0)`), empty HMAC keys, empty HKDF salt/info, and empty AEAD plaintext/AAD are handled safely without panics.
- **Internal state is not encapsulated**: Pion does not yet enforce field privacy or immutability across packages; callers must use the public methods rather than reading or mutating struct fields directly.
- **Legacy notice**: `Sha1` is provided only for legacy protocol compatibility; use `Sha256` / `Sha512` for cryptographic security.

## Verification

```sh
sh scripts/verify.sh packages/crypto
sh packages/crypto/bench/run_bench.sh   # 4-mode wasm_smoke parity + head-to-head benchmarks
```

### 4-Mode Cross-Target Parity (`wasm_smoke`)

Native debug, Native release, Wasm32 debug, and Wasm32 release all produce byte-identical stdout (`3283 B`, `sha256:163cbdd5aee50ebe403ad43791062c9d80ac10691b9d51640e8385d6410b5493`), covering SHA-1/2, HMAC-SHA2, Ed25519 (including red-team boundary and adversarial rejection vectors), X25519, HKDF-SHA256/512, ChaCha20-Poly1305 AEAD, NIST P-256 ES256/DER, and RSA-2048 RS256.

### Red-team audit

See [`audit/REDTEAM_AUDIT.md`](audit/REDTEAM_AUDIT.md) and `redteam_test.pion`.

## Head-to-Head Benchmarks

Measured on `Darwin arm64` with `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, stdout SHA-256 verified byte-for-byte identical between Pion and Go on every benchmark):

| Workload | Pion Median (ms) | Go Median (ms) | Pion Throughput / Rate | Pion Peak RSS | Go Peak RSS | Speedup vs Go |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| SHA-256 (16 MiB streaming) | 99.222 | 16.040 | 169.09 MB/s | 1.83 MiB | 5.00 MiB | 0.16x |
| SHA-512 (16 MiB streaming) | 63.226 | 20.020 | 265.35 MB/s | 1.81 MiB | 5.02 MiB | 0.32x |
| HMAC-SHA256 (50,000 × 256 B) | 148.533 | 31.896 | 2,970.67 ns/op | 1.80 MiB | 11.38 MiB | 0.21x |
| Ed25519 (200 sign + 200 verify) | 53.251 | 25.262 | 133.13 µs/op | 1.88 MiB | 5.11 MiB | 0.47x |
| X25519 (200 key exchanges) | 25.949 | 24.797 | 129.75 µs/op | 1.84 MiB | 4.92 MiB | 0.96x |
| HKDF-SHA256 (20,000 × 64 B) | 95.725 | 32.600 | 4,786.25 ns/op | 1.84 MiB | 12.11 MiB | 0.34x |
| ChaCha20-Poly1305 (4 MiB seal + open) | 73.765 | 25.090 | 113.72 MB/s | 2.05 MiB | 10.33 MiB | 0.34x |
| NIST P-256 ES256 (50 sign + 50 verify) | 116.225 | 18.904 | 1.16 ms/op | 1.89 MiB | 5.77 MiB | 0.16x |

**Honest hardware & runtime gap note**:
- On `Darwin arm64`, Go stdlib / `golang.org/x/crypto` accelerates SHA-256/SHA-512 via ARMv8 Cryptography Extensions (`SHA256H`/`SHA512H`), ChaCha20/Poly1305 via NEON/ARM64 assembly, and Ed25519/P-256 via hand-tuned ARM64 assembly + precomputed tables, whereas `packages/crypto` is 100% pure-Pion portable scalar code (zero C FFI / zero assembly, identical on Native and `wasm32`).
- Pure Pion reaches **0.96× of Go stdlib on X25519**, sustains **113.7 MB/s** ChaCha20-Poly1305 AEAD, **169.1 MB/s** SHA-256, and **265.4 MB/s** SHA-512 while using **2.6×–6.6× lower Peak RSS** (1.80–2.05 MiB vs 4.92–12.11 MiB).
