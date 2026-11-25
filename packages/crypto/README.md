# `crypto`

Zero-dependency, pure-Pion cryptographic primitives package (`World`-free, portable across Native and WebAssembly `wasm32`):

- **Hash functions (FIPS 180-4)**: `Sha1`, `Sha256`, `Sha384`, `Sha512` (streaming `new`, `update`, `update_slice`, `finalize`, `finalize_hex`, `reset` + one-shot `sha1`, `sha256`, `sha384`, `sha512`, `*_hex`).
- **Message Authentication Codes (RFC 2104 / RFC 4231)**: `HmacSha256`, `HmacSha384`, `HmacSha512` (streaming with precomputed inner/outer pad states + one-shot `hmac_sha256`, `hmac_sha384`, `hmac_sha512`, `*_hex`).
- **Key Derivation (RFC 5869)**: `hkdf_sha256_extract`, `hkdf_sha256_expand`, `hkdf_sha256`, `hkdf_sha512_extract`, `hkdf_sha512_expand`, `hkdf_sha512`.
- **Password-Based Key Derivation (RFC 8018 & RFC 7914)**: `pbkdf2_hmac_sha256`, `pbkdf2_hmac_sha512`, `scrypt`, `scrypt_with_max_mem`.
- **Authenticated Encryption (RFC 8439 & NIST SP 800-38D)**: `chacha20_xor`, `poly1305_mac`, `chacha20_poly1305_seal`, `chacha20_poly1305_open`, `aes128_gcm_seal`, `aes128_gcm_open`, `aes256_gcm_seal`, `aes256_gcm_open`.
- **Constant-Time Equality & Hex Codec**: `constant_time_eq(a, b)`, `bytes_to_hex(data)`, `hex_to_bytes(hex)`.
- **Strict RFC 8032 Ed25519**: `Ed25519KeyPair` (`from_seed`, `public_key`, `sign`), `ed25519_public_key`, `ed25519_sign`, `ed25519_verify`, `ed25519_verify_strict`.
- **RFC 7748 X25519**: `x25519_public_key`, `x25519`, `x25519_raw`.
- **NIST P-256 (secp256r1 / ES256 / ECDH / WebCrypto / WebAuthn)**: `p256_public_key`, `p256_validate_pubkey`, `p256_validate_pubkey_strict`, `p256_decompress_pubkey`, `p256_ecdh`, `p256_sign_es256` (RFC 6979 deterministic), `p256_verify_es256`, `p256_verify_der`, `p256_secret_from_pkcs8_der`, `p256_secret_from_pkcs8_pem`.
- **RFC 8017 RSA-2048+ (RS256)**: `RsaPrivateKey` (`from_pkcs8_der`, `from_pkcs8_pem`, `public_key`), `RsaPublicKey` (`from_components`, `from_spki_der`), `rsa_sign_rs256` (constant-time CRT + Bellcore fault check), `rsa_verify_rs256`.

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

### HKDF (RFC 5869), ChaCha20-Poly1305 (RFC 8439), & AES-128/256-GCM (NIST SP 800-38D)

- `hkdf_sha256_expand` / `hkdf_sha512_expand` enforce `prk.length() >= HashLen` and `0 <= len <= 255 * HashLen`.
- `chacha20_xor` enforces 32-byte key, 12-byte nonce, and rejects 32-bit block counter wrap-around (`CounterOverflow`).
- `chacha20_poly1305_open` verifies the 16-byte Poly1305 tag in constant time (`constant_time_eq`) before decrypting; authentication failure returns `CryptoError::AuthenticationFailed` and never leaks plaintext.
- `aes128_gcm_seal` / `aes128_gcm_open` (16-byte key) and `aes256_gcm_seal` / `aes256_gcm_open` (32-byte key) use constant-time 64-bit 4-block parallel bitsliced AES (Boyar-Peralta S-box circuit, zero lookup tables) and carry-less GF(2^128) GHASH (4-way masked 32×32 Karatsuba multiplication, zero tables/branches). Both standard 12-byte (96-bit) and arbitrary non-empty nonces (GHASH-derived `J_0` per SP 800-38D §7.1) are supported; empty nonces (`0` bytes) and wrong key lengths are rejected, and decryption verifies the 16-byte tag in constant time before returning plaintext.

### NIST P-256 (ES256 / ECDH / SEC1 / DER / PKCS#8)

- Public key validation & decompression (`p256_validate_pubkey`, `p256_validate_pubkey_strict`, `p256_decompress_pubkey`) match WebCrypto `SubtleCrypto.importKey("raw", ...)` / OpenSSL / Go `crypto/ecdh`: they accept SEC1 uncompressed (`65B`, `0x04 || X || Y`) and compressed (`33B`, `0x02/0x03 || X`) encodings (Go `crypto/ecdh.NewPublicKey` accepts only the 65-byte form; protocols that require strictly uncompressed keys must additionally check `length == 65` before calling these functions or `p256_ecdh`), reject infinity (`0x00`), wrong prefixes/lengths, non-canonical coordinates (`X >= p` or `Y >= p`), off-curve points, and twist points (compressed `Y` recovered via `rhs^((p+1)/4) mod p` with square-root and parity verification).
- Key agreement (`p256_ecdh`) validates `1 <= d < n` with a constant-time fixed 8-limb borrow/OR-mask check (no secret-dependent branch or early exit) and validates/decompresses `peer_public` via `p256_decompress_pubkey` (preventing Invalid Curve Attacks), then computes `[d]Q` using a constant-time 4-bit windowed projective scalar multiplication and returns the 32-byte big-endian shared X coordinate (byte-identical to NIST SP 800-56A / Go `crypto/ecdh.P256()` / WebCrypto `deriveBits`).
- Signing (`p256_sign_es256`) uses RFC 6979 deterministic nonces with branch-free Montgomery field arithmetic, complete projective addition/doubling (Renes-Costello-Batina 2015, `a = -3`), and a branch-free 4-bit windowed base-point scalar multiplication. The nonce inverse, `Z^-1` and `s = k^-1 (z + r·d) mod n` use the fixed-window ladder and branch-free modular helpers of `bigint.pion` over fixed 8-limb operands.
- Signatures are byte-identical to Go's RFC 6979 `crypto/ecdsa` output. Like Go, OpenSSL and WebCrypto, verification accepts both `s` and `n - s` (ECDSA is malleable; normalise to low-`s` at the protocol layer if needed).
- Verification (`p256_verify_es256`) validates `x < p`, `y < p`, curve membership `y^2 ≡ x^3 - 3x + b (mod p)`, non-infinity, and `1 <= r < n && 1 <= s < n`.
- `p256_verify_der` enforces strict ASN.1 DER (`SEQUENCE { INTEGER r, INTEGER s }`), rejecting trailing bytes, non-minimal lengths, negative integers, and redundant leading zero padding (WebAuthn/Passkey compliant).

### RSA-2048+ (RS256)

- Enforces modulus size `2048 <= bits(n) <= 8192`, odd `n`, odd `3 <= e < 2^33` (the BoringSSL bound, which caps verification cost), and full CRT parameter consistency (`p * q == n`, `dp == d mod (p-1)`, `dq == d mod (q-1)`, `e * dp ≡ 1 (mod p-1)`, `e * dq ≡ 1 (mod q-1)`, `q * qinv ≡ 1 (mod p)`).
- `rsa_sign_rs256` performs constant-time CRT exponentiation (fixed 4-bit window with branch-free table scan over every limb of `dp`/`dq`, branch-free reductions modulo the secret primes) followed by a **Bellcore fault self-check** (`s^e mod n == em`) before returning the signature. `audit/ct_ssa_check.py` checks the release SSA for data-dependent branches on these paths.
- `rsa_verify_rs256` rejects wrong lengths and `sig >= n`, and performs a full-length `constant_time_eq` comparison of `s^e mod n` against the single canonical RFC 8017 PKCS#1 v1.5 SHA-256 `DigestInfo` block (with explicit ASN.1 `NULL`), preventing Bleichenbacher's forgery attacks.

### PBKDF2 (RFC 8018) & scrypt (RFC 7914)

- `pbkdf2_hmac_sha256` and `pbkdf2_hmac_sha512` reject `iterations <= 0` (`CryptoError::InvalidParam`) and `dk_len <= 0` or `dk_len > 2^30` (1 GiB cap, `CryptoError::InvalidLength`, checked before allocating; the block count is computed as `(dk_len - 1) / hLen + 1` so it cannot wrap). Both precompute HMAC ipad/opad states once and run the inner iteration loop directly over fixed word arrays with zero per-iteration heap allocations.
- `scrypt` and `scrypt_with_max_mem` enforce RFC 7914 §6 parameter validity (`N > 1` and power of 2, RFC 7914 §2 `N < 2^(16 r)` — i.e. `r = 1` refuses `N >= 65536` as OpenSSL / Node.js do, `r > 0`, `p > 0`, `r * p < 2^30`, `0 < dk_len <= 2^30`, `max_mem_bytes > 0`) and guard against OOM via the standard `128 * r * (N + p + 2) <= max_mem_bytes` check (`CryptoError::MemoryLimitExceeded`). Regardless of `max_mem_bytes`, the ROMix `V` table is hard-capped below 1 GiB (`32 * r * N < 2^28` words, `MemoryLimitExceeded`), so Native and Wasm32 (debug and release) make identical accept/refuse decisions with zero traps (RT-crypto-v040 P1-1 / P2-1 / P2-2 / P2-3). `scrypt` defaults to a `256 MiB` ceiling (covering scrypt + AES-256-GCM envelope decrypt parameters up to `N = 131072, r = 8, p = 1`); callers with tighter budgets (e.g. `64 MiB` for `N = 32768, r = 8, p = 1`) use `scrypt_with_max_mem`.
- `ROMix` uses packed 2×32-bit `FixedArray[UInt64]` storage for `V` and `xy` (halving the `V` table footprint to exact `128 * r * N` bytes, e.g. `16.0 MiB` for `N=16384, r=8`), direct in-place Phase-1 `V[i] -> V[i+1]` mixing (zero `V <- xy` copies), and a fused Phase-2 `BlockMix(X ^ V[j])` 16-register Salsa20/8 kernel with zero inner-loop allocations.

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

Native debug, Native release, Wasm32 debug, and Wasm32 release all produce byte-identical stdout (`4605 B`, `sha256:3f3456531e2f127a430ddf46647ed4d68a38c93f00c57e0b730476ffc6f97108`), covering SHA-1/2, HMAC-SHA2, Ed25519 (including red-team boundary and adversarial rejection vectors), X25519, HKDF-SHA256/512, ChaCha20-Poly1305 AEAD, AES-128/256-GCM (96-bit and non-96-bit nonces + tamper rejection), NIST P-256 ES256/DER/ECDH/pubkey validation & decompression (including RFC 6979 at `d = n - 1` against Go), RSA-2048 RS256, PBKDF2-HMAC-SHA256/512, scrypt (RFC 7914 + scrypt + AES-256-GCM envelope + `max_mem` / invalid parameter rejection), the Poly1305 accumulator landing exactly on `2^130 - 5`, and the RSA public-exponent cap.

### Red-team audit

See [`audit/REDTEAM_AUDIT.md`](audit/REDTEAM_AUDIT.md) and `redteam_test.pion`.

## Head-to-Head Benchmarks

Measured on `Darwin arm64` with `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, stdout SHA-256 verified byte-for-byte identical between Pion and Go on every benchmark):

| Workload | Pion Median (ms) | Go Median (ms) | Pion Throughput / Rate | Pion Peak RSS | Go Peak RSS | Speedup vs Go |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| SHA-256 (16 MiB streaming) | 94.222 | 17.716 | 178.06 MB/s | 1.84 MiB | 5.02 MiB | 0.19x |
| SHA-512 (16 MiB streaming) | 63.312 | 21.785 | 264.99 MB/s | 1.84 MiB | 5.05 MiB | 0.34x |
| HMAC-SHA256 (50,000 × 256 B) | 140.606 | 32.078 | 2,812.11 ns/op | 1.80 MiB | 11.41 MiB | 0.23x |
| Ed25519 (200 sign + 200 verify) | 60.823 | 24.094 | 152.06 µs/op | 1.89 MiB | 5.03 MiB | 0.40x |
| X25519 (200 key exchanges) | 30.242 | 28.051 | 151.21 µs/op | 1.83 MiB | 4.95 MiB | 0.93x |
| HKDF-SHA256 (20,000 × 64 B) | 102.889 | 31.297 | 5,144.44 ns/op | 1.83 MiB | 12.28 MiB | 0.30x |
| ChaCha20-Poly1305 (4 MiB seal + open) | 73.418 | 20.921 | 114.26 MB/s | 2.05 MiB | 10.80 MiB | 0.28x |
| AES-256-GCM (1,000 × 64 KiB seal + open) | 2033.434 | 55.673 | 64.46 MB/s | 2.05 MiB | 14.75 MiB | 0.03x |
| AES-256-GCM Small (150,000 × 256 B seal + open) | 2315.511 | 46.906 | 7.72 µs/op | 1.88 MiB | 11.84 MiB | 0.02x |
| NIST P-256 ES256 (50 sign + 50 verify) | 121.651 | 14.271 | 1.22 ms/op | 1.97 MiB | 5.81 MiB | 0.12x |
| NIST P-256 ECDH (2,000 key exchanges) | 1402.492 | 69.888 | 701.25 µs/op | 1.89 MiB | 7.09 MiB | 0.05x |
| NIST P-256 Pubkey Validate (20,000 uncomp + 20,000 comp) | 828.830 | 81.086 | 20.72 µs/op | 1.81 MiB | 11.11 MiB | 0.10x |
| PBKDF2-HMAC-SHA256 (500,000 iters, 32 B) | 175.074 | 55.964 | 350.15 ns/op | 1.81 MiB | 4.97 MiB | 0.32x |
| scrypt (N=16384, r=8, p=1, 32 B × 4) | 101.280 | 83.341 | 25.32 ms/op | 17.80 MiB | 39.38 MiB | 0.82x |

**Honest hardware & runtime gap note**:
- On `Darwin arm64`, Go stdlib / `golang.org/x/crypto` accelerates SHA-256/SHA-512 via ARMv8 Cryptography Extensions (`SHA256H`/`SHA512H`), AES-GCM via ARMv8 AES+PMULL hardware instructions, ChaCha20/Poly1305 via NEON/ARM64 assembly, and Ed25519/P-256 via hand-tuned ARM64 assembly + precomputed tables, whereas `packages/crypto` is 100% pure-Pion portable constant-time scalar code (zero C FFI / zero assembly, identical on Native and `wasm32`).
- Pure Pion reaches **0.93× of Go stdlib on X25519** and **0.82× of Go `golang.org/x/crypto/scrypt`** (25.32 ms/op vs 20.84 ms/op at `N=16384, r=8, p=1`, with **2.21× lower Peak RSS**: `17.80 MiB` vs `39.38 MiB`), sustains **114.3 MB/s** ChaCha20-Poly1305 AEAD, **178.1 MB/s** SHA-256, and **265.0 MB/s** SHA-512 while using **2.6×–7.2× lower Peak RSS** on non-memory-hard workloads (1.78–2.05 MiB vs 4.95–14.75 MiB).
- For v0.4.0 KDFs (sized so Go runs ≥ 50 ms):
  - **PBKDF2-HMAC-SHA256** (dedicated fully-unrolled 32-byte single-block SHA-256 compression in the inner loop) reaches **350 ns/op (0.32×** of Go's ARMv8 `SHA256H`-accelerated path at 112 ns/op, and **0.95×** of Go `-tags purego` pure-scalar SHA-256 at 320 ns/op on the same machine, confirming that the remaining gap to default Go is the ~3.1× ARMv8 `SHA256H` hardware instruction advantage).
  - **scrypt** (packed `FixedArray[UInt64]` `V`/`xy`, direct Phase-1 `V` writes, fused Phase-2 `BlockMix(X ^ V[j])`) reaches **0.82×** of Go `x/crypto` with **17.80 MiB** Peak RSS (down from 33.78 MiB). Disassembly shows the remaining ~18–19 ms gap over 2.1M Salsa20/8 calls matches QBE emitting 3-instruction `lsl`/`lsr`/`orr` (2-cycle critical path) instead of single-instruction ARM64 `ror` (1 cycle) for each of the 268.4M quarter-round rotations.
- The v0.3.0 rows (AES-256-GCM, P-256 ECDH, P-256 pubkey validation) are sized so Go's side runs ≥ 45 ms of real work (process start-up ≈ 3 ms, < 7% of the Go median), so their ratios reflect steady-state throughput. They are Pion's weakest rows: the constant-time bitsliced software AES-256-GCM reaches **64.5 MB/s** (**0.03×** of Go's ARMv8 AES+PMULL path at ≈ 2.35 GB/s; **0.02×** on 256 B packets), P-256 ECDH runs at **701 µs/op (0.05×** of Go's ARM64-assembly `crypto/ecdh` at 35 µs/op), and P-256 public-key validation at **20.7 µs/op (0.10×)**. The earlier 64–400-iteration rows (0.10×–0.65×) were dominated by process start-up and overstated these ratios (see [`audit_v030/REPORT.md`](audit_v030/REPORT.md) P2-1).
- The older v0.2.0 rows keep their original sizes; the shortest of them (X25519, Go ≈ 28 ms) still include ≈ 3 ms of process start-up per side, so the ratio is approximate.

### Scalar Optimization Results (`Linux x86_64`)

Measured on `Linux x86_64` with `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved against Go stdlib / `golang.org/x/crypto`, stdout SHA-256 verified byte-for-byte identical across all 14 benchmarks and 4-mode `wasm_smoke`):

| Workload | Baseline vs Go | Optimized vs Go | Relative Gain | Key Optimization |
| --- | ---: | ---: | ---: | --- |
| NIST P-256 ES256 (50 sign + 50 verify) | 0.03x | 0.15x | **5.00x** | `val struct Fp` zero-alloc Montgomery CIOS + 4-table fixed-base comb + `p-2` addition chain |
| NIST P-256 ECDH (2,000 key exchanges) | 0.03x | 0.11x–0.12x | **3.67x–4.35x** | `val struct Fp` + Jacobian 3M+5S doubling + multiplication-free P-256 reduction |
| NIST P-256 Pubkey Validate (40,000 ops) | 0.09x | 0.29x–0.44x | **3.22x–4.88x** | Module-cached `P256Ctx`, direct `Fp` parsing, `(p+1)/4` 253S+7M addition chain |
| ChaCha20-Poly1305 (4 MiB seal + open) | 0.44x | 0.88x | **2.00x** | Inlined quarter-round rotates & byte XOR, register-hoisted Poly1305 loop |
| Ed25519 (200 sign + 200 strict verify) | 0.16x | 0.28x | **1.75x** | Lazily-initialized constant-time 4-table fixed-base comb (`B, 2^64 B, 2^128 B, 2^192 B`) |
| AES-256-GCM (1,000 × 64 KiB seal + open) | 0.12x | 0.17x | **1.42x–1.60x** | Inlined `aes_delta_swap` & GHASH Karatsuba (zero tuple boxing), reused `q` scratch |
| AES-256-GCM Small (150,000 × 256 B) | 0.06x | 0.09x | **1.50x–1.63x** | Transpose-based `aes_pack_round_key`, reused key-schedule scratch, zero tuple boxing |

- **Hardware instruction ceiling (`objdump -d`)**: On `Linux x86_64`, `go_crypto_bench` executes `sha256rnds2` / `sha256msg1` / `sha256msg2` (SHA-NI) for SHA-256 and `aesenc` / `pclmulqdq` (AES-NI + CLMUL) for AES-GCM, whereas pure-Pion QBE emits 0 hardware crypto/SIMD instructions (`sha256_compress_w` is already 8-way unrolled with hoisted `sha256_k` and zero helper calls). All constant-time QBE SSA gates (`audit/ct_ssa_check.py`, `audit_v030/ct_ssa_check_v030.py`, `audit_v040/ct_ssa_check_v040.py`) pass with zero secret-dependent branches or table lookups.

## Formal Verification (Lean 4)

15 production cryptographic kernels (`Fe`, `fe_cmov`, `fe_cswap_pair`, `fe_add`, `fe_sub`, `fe_mul`, `fe_sq`, `ct_eq_nibble`, `ct_diff_acc`, `x25519_clamp_low_byte`, `x25519_clamp_high_byte`, `cc_rotl32`, `poly1305_clamp_r`, `poly1305_final_reduce`, `hkdf_sha256_blocks`, `hex_nibble_val`; `types=1, funs=15, externals=0`) are annotated with `#verify` and formally verified in Lean 4 under `proofs/` (**19** `0-sorry` theorems: **7 A-grade** algebraic/cryptographic core theorems + **12 B-grade** primitive/constant-time helper theorems, strict standard-axiom whitelist, 36-case value-comparing native-vs-Lean differential cross-check including boundary extremes and shift-trap checks):

### Stage 2 A-Grade Core Theorems (`CryptoProofs/FieldAndPoly1305.lean`)

| Theorem | Production Kernel | Property Proved |
| --- | --- | --- |
| `fe_add_mod_p_and_bounds` | `fe_add` | Exact integer sum mod $2^{255}-19$ + zero 64-bit overflow for $\|h_i\| \le 2^{61}$ |
| `fe_sub_mod_p_and_bounds` | `fe_sub` | Exact integer difference mod $2^{255}-19$ + zero 64-bit overflow for $\|h_i\| \le 2^{61}$ |
| `fe_mul_mod_p_and_bounds` | `fe_mul` | Real 100-term Ref10 $\mathrm{GF}(2^{255}-19)$ multiplication + 12-step carry chain: $p \mid (\mathrm{feVal}(r) - \mathrm{feVal}(f)\cdot\mathrm{feVal}(g))$, zero overflow, closed post-carry limb bounds |
| `fe_sq_mod_p_and_bounds` | `fe_sq` | Real Ref10 $\mathrm{GF}(2^{255}-19)$ squaring + 12-step carry chain: $p \mid (\mathrm{feVal}(r) - \mathrm{feVal}(f)^2)$, zero overflow, closed post-carry limb bounds |
| `poly1305_clamp_r_rfc8439_spec` | `poly1305_clamp_r` | RFC 8439 §2.5 `r` key clamping bit-for-bit (top 4 bits of bytes 3,7,11,15 = 0; bottom 2 bits of bytes 4,8,12 = 0; limb bounds & $R < 2^{124}$) |
| `poly1305_final_reduce_canonical` | `poly1305_final_reduce` | Constant-time Poly1305 final carry + conditional subtraction mod $2^{130}-5$: unique canonical output $\mathrm{polyVal}(r) < 2^{130}-5$ and $\mathrm{polyVal}(r) \equiv \mathrm{polyVal}(h) \pmod{2^{130}-5}$ |
| `ct_eq_nibble_spec` | `ct_eq_nibble` | Ed25519 branch-free 4-bit window selector exactness `ct_eq_nibble a b = ok (if a = b then 1 else 0)` for all non-negative 32-bit inputs |

### Semantic Mutation Kill Gate (`mutation_check.sh`: 10 / 10 = 100%)

| Mutant | Fault Injected | Result |
| --- | --- | --- |
| `M01_fe_mul_prime18` | `fe_mul`: wrong prime reduction `19 -> 18` | KILLED |
| `M02_fe_mul_wrap20` | `fe_mul`: wrong carry wrap-around `19 -> 20` | KILLED |
| `M03_fe_mul_shift25` | `fe_mul`: wrong radix-$2^{25.5}$ carry shift `26 -> 25` | KILLED |
| `M04_fe_sq_cross19` | `fe_sq`: missing factor of 2 in cross-radix term | KILLED |
| `M05_fe_sq_wrap17` | `fe_sq`: wrong carry wrap-around `19 -> 17` | KILLED |
| `M06_fe_add_sign` | `fe_add`: limb sign flip `+ -> -` | KILLED |
| `M07_fe_sub_sign` | `fe_sub`: limb sign flip `- -> +` | KILLED |
| `M08_poly_clamp_bit` | `poly1305_clamp_r`: missed RFC 8439 §2.5 clamp bit | KILLED |
| `M09_poly_reduce_thresh` | `poly1305_final_reduce`: wrong $2^{130}-5$ threshold `5 -> 4` | KILLED |
| `M10_ct_nibble_off1` | `ct_eq_nibble`: off-by-one branch-free equality | KILLED |

```bash
bash packages/crypto/proofs/run_proofs.sh
bash packages/crypto/proofs/mutation_check.sh
```
