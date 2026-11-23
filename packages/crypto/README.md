# `crypto`

Zero-dependency, pure-Pion cryptographic primitives package (`World`-free, portable across Native and WebAssembly `wasm32`):

- **Hash functions (FIPS 180-4)**: `Sha1`, `Sha256`, `Sha384`, `Sha512` (streaming `new`, `update`, `update_slice`, `finalize`, `finalize_hex`, `reset` + one-shot `sha1`, `sha256`, `sha384`, `sha512`, `*_hex`).
- **Message Authentication Codes (RFC 2104 / RFC 4231)**: `HmacSha256`, `HmacSha384`, `HmacSha512` (streaming with precomputed inner/outer pad states + one-shot `hmac_sha256`, `hmac_sha384`, `hmac_sha512`, `*_hex`).
- **Constant-Time Equality & Hex Codec**: `constant_time_eq(a, b)`, `bytes_to_hex(data)`, `hex_to_bytes(hex)`.
- **Strict RFC 8032 Ed25519**: `Ed25519KeyPair` (`from_seed`, `public_key`, `sign`), `ed25519_public_key`, `ed25519_sign`, `ed25519_verify`, `ed25519_verify_strict`.

## Security Semantics (Ed25519)

`ed25519_verify` and `ed25519_verify_strict` enforce **strict single-signature non-malleability** (equivalent to `ed25519-dalek::VerifyingKey::verify_strict`):

1. **Exact lengths**: seed = 32 bytes, public key = 32 bytes, signature = 64 bytes (`InvalidSeedLength`, `InvalidPublicKeyLength`, `InvalidSignatureLength`).
2. **Canonical scalar `S`**: rejects any signature with `S >= L`, preventing `S + kL` signature malleability (`NonCanonicalScalar`).
3. **Canonical point encoding (`A` and `R`)**: rejects `y >= p` (`p = 2^255 - 19`), off-curve points (`InvalidPoint`), and non-canonical negative zero (`x == 0` with sign bit `1`, `NonCanonicalPoint`).
4. **Small-order torsion rejection (`A` and `R`)**: checks `[8]P != O` for both public key `A` and signature point `R`, rejecting all 8 small-order torsion points (`SmallOrderPoint`).
5. **Strict un-cofactored equation**: verifies `[S]B == R + [k]A` directly in projective coordinates. Note: this intentionally differs from ZIP-215 (which permits non-canonical encodings and uses cofactored `[8S]B == [8]R + [8k]A` for batch verification) in order to guarantee strict single-signature non-malleability.
6. **Zero-length inputs**: empty messages (`Bytes::new(0)`) and empty HMAC keys are handled safely without panics.
7. **Legacy notice**: `Sha1` is provided only for legacy protocol compatibility (e.g. WebSocket handshakes, Git object IDs); use `Sha256` / `Sha512` for cryptographic security.

## Verification

```sh
sh scripts/verify.sh packages/crypto
sh packages/crypto/bench/run_bench.sh
```

### 4-Mode Cross-Target Parity (`bench/wasm_smoke`)

Native debug, Native release, Wasm32 debug, and Wasm32 release all produce byte-identical stdout (`1015 B`, `sha256:c9431b5eed16aa6088a11cec23f738e143a19a3924d1fadf4e907dc134924738`).

## Head-to-Head Benchmarks

Measured on `Darwin arm64` with `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, stdout SHA-256 verified byte-for-byte identical between Pion and Go stdlib on every benchmark):

| Workload | Pion Median (ms) | Go stdlib Median (ms) | Pion Throughput / Rate | Pion Peak RSS | Go Peak RSS | Speedup vs Go |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| SHA-256 (16 MiB streaming) | 93.978 | 15.941 | 178.52 MB/s | 1.80 MiB | 4.66 MiB | 0.17x |
| SHA-512 (16 MiB streaming) | 55.985 | 18.779 | 299.67 MB/s | 1.80 MiB | 4.72 MiB | 0.34x |
| HMAC-SHA256 (50,000 × 256 B) | 122.492 | 27.119 | 2,449.84 ns/op | 1.75 MiB | 11.16 MiB | 0.22x |
| Ed25519 (200 sign + 200 verify) | 44.075 | 16.478 | 110.19 µs/op | 1.83 MiB | 4.78 MiB | 0.37x |

**Honest hardware & runtime gap note**:
- On `Darwin arm64`, Go stdlib accelerates SHA-256/SHA-512 via ARMv8 Cryptography Extensions (`SHA256H`/`SHA512H` SIMD instructions) and Ed25519 via hand-tuned ARM64 assembly + precomputed radix tables, whereas `packages/crypto` is 100% pure-Pion portable scalar code (zero C FFI / zero assembly, identical on Native and `wasm32`).
- Pure Pion sustains **178.5 MB/s** SHA-256, **299.7 MB/s** SHA-512, **408k ops/s** HMAC-SHA256, and **~9.1k ops/s** Ed25519 sign/verify while using **2.6×–6.4× lower Peak RSS** (1.75–1.83 MiB vs 4.66–11.16 MiB).
