# Red-team audit: `packages/crypto` @ `8559660` (`feat/pkg-crypto`)

Scope: every line of `src/{ct,error,hex,sha1,sha256,sha512,hmac,ed25519}.pion`, the existing tests, the
4-mode `wasm_smoke` entry and the generated QBE SSA of the Ed25519 signing path.

## Result

| ID | Severity | Area | Status |
| --- | --- | --- | --- |
| RT-1 | **P2** | Ed25519 key generation / signing: secret-dependent conditional jump in the base-point window lookup | **Fixed** |
| RT-2 | P3 (info) | `Ed25519KeyPair` / hasher internals reachable and writable by callers (no field privacy in the language) | Documented; needs a toolchain fix |
| RT-3 | Toolchain | Built-in `sha256_hex(String)` silently shadows the package's own `sha256_hex(Bytes)` inside the package | Out of scope; reported, tests avoid it |

No P0 or P1 was found. Every functional attack in the checklist below was tried and held, both before and
after the fix:

- Ed25519 strict verification rejected every non-canonical `S`, every non-canonical `A`/`R`, all 8
  small-order points, torsion-shifted `R`, wrong lengths and `-R` forgeries.
- The field and scalar arithmetic gave exact results at the `p`, `2p` and all-`0xFF` edges.
- SHA-1/SHA-2/HMAC match the Python `hashlib`/`hmac` references at every block boundary, in every chunking
  and under hostile `update_slice` bounds.

## Attack surface covered (`redteam_test.pion`, 27 tests, ≈2,600 assertions)

**Ed25519**
- Cross-implementation vectors: 4 seeds and messages from Node.js `crypto` (an independent implementation),
  including the empty message and a 100,000-byte message. Each is checked for the public key, the exact
  signature, verify, an appended byte and a dropped byte.
- Exact lengths: public key 0/1/31/33/64, signature 0/1/32/63/65/128, a valid signature plus one trailing
  byte, and seed 0/1/31/33/64 through `from_seed`, `ed25519_sign` and `ed25519_public_key`. Each returns its
  exact `Invalid*Length(n)`.
- `S` boundaries: `L`, `L+1`, `2^253-1`, `2^253`, `2^256-1`, bit 255 only, top byte `0x11` and `S + L` are all
  `NonCanonicalScalar`. `S = L-1` and `S = 0` are canonical and give `SignatureMismatch`.
- Point encodings for both `A` and `R`: `y = p`, `p+1`, `p+2`, `p+3`, `2^255-2` and `2^255-1`, with and without
  the sign bit, plus negative zero `(0, ±1)` with `0x80`, all give `NonCanonicalPoint`. `y = p-1` gives
  `SmallOrderPoint`. Flipping only the sign bit of a valid `A` or `R` gives a mismatch.
- All 8 small-order points:
  - as `A` and as `R`;
  - all 64 trivial `A = T, R = T', S = 0` forgeries;
  - `[8]P == O` is checked to be non-vacuous: `B` and `B + T4` are not small order.
- Torsion / cofactor malleability over 24 messages:
  - `R + T2` and `R + T4` (canonical, not small order) are always rejected.
  - For a mixed-order key `A + T2` with a signature made using the real secret, strict verification
    accepts exactly when `k'` is even. Both outcomes occur in the run. This matches `verify_strict`, which
    accepts mixed-order keys; it is now stated in the README.
- `-R` forgery (`S = k·a - r`): `[S]B - [k]A = -R` differs from `R` only in `x`. It is rejected, so a
  verifier that compared only `y`/`Y:Z` would be caught. The honest `S = k·a + r` signature for the same
  nonce verifies.
- Field edges:
  - `p→0`, `p+1→1` and `2^256-1→18` (bit 255 ignored); `p-1` stays `p-1`.
  - `(p-1)^2 = 1` with both `fe_mul` and `fe_sq`; `inv(p-1) = p-1`; `(p-1)+1 = 0`; `0-1 = p-1`;
    `2(p-1) = p-2`.
  - `inv(0) = 0` with no panic; `sqrt(-1)^2 = -1`.
  - `x · inv(x) = 1` and `mul == sq` for 7 limb-boundary inputs, including non-canonical ones.
- Scalar reduction:
  - `sc_reduce_64` for 64×`0xFF`, `L`, `L-1`, `2L`, `2^256-1`, `L·2^259+5` and bytes `0..63` matches Python
    big-int `mod L`; every output limb is a byte and canonical.
  - `[L]B = O`, `[0]B = O` and `[L-1]B = -B` on the constant-time ladder; `[L]B = O` and
    `[L-1]B + B = O` on the variable-time ladder; `encode(O)` is correct.
- Window select (RT-1): `ct_eq_nibble` over all 256 pairs, and `[n]B` / `[16n]B` for every nibble `n`
  against repeated addition.

**SHA-1 / SHA-256 / SHA-384 / SHA-512**
- 22 lengths (0, 1, 3, 55–57, 63–65, 111–113, 119, 120, 127–129, 191, 192, 255, 256, 1000) against
  `hashlib`, one-shot and streamed in 14 chunk sizes (1 … 4096).
- Hostile `update_slice` bounds: negative start, end past the data, inverted ranges, start beyond `len`,
  both ends negative, `start == end`, and `±2^31` extremes. Each result equals the hash of the clamped
  slice, with no panic and no out-of-bounds read.
- `finalize()` is idempotent and leaves the running state intact (continuing afterwards gives `H(a‖b)`).
  `reset()` with a dirty partial block and length is identical to a fresh hasher.

**HMAC-SHA256/384/512**
- Keys of 0, 1, 63, 64, 65, 127, 128, 129 and 1024 bytes × messages of 0, 1 and 200 bytes (81 `hmac`
  references).
- Each is checked one-shot, streamed in 1-byte and 129-byte chunks, after `reset()` on a dirty state, with
  `finalize()` called twice, and with empty hostile slices treated as no-ops.

**`constant_time_eq` and hex**
- `constant_time_eq`: equal, empty/empty, empty vs 1 byte, length mismatch in both orders, and a 1-bit
  high/low difference at each of 64 positions.
- `hex_to_bytes`: empty input and mixed case are accepted. Rejected: odd length, `0x`/`0X` prefixes,
  `g`/`G`, the characters `/ : @` `` ` `` that sit next to the digit ranges, spaces, signs, non-ASCII
  (`é`, `İ`, full-width digits) and NUL. A round trip of all 256 byte values works.

**Mutation check.** These single-line mutants are each killed by `redteam_*` tests:
- the small-order check, the `S < L` check, `y < p`, negative zero, comparing `y` only in the equation;
- the `update_slice` clamp, the SHA-1/SHA-512 padding thresholds, the HMAC block-key threshold, the
  HMAC-384 outer length;
- hex `G`, a `constant_time_eq` short-circuit, `reset()` not clearing `fill`;
- an off-by-one in `ct_eq_nibble` and a wrong window index.

## RT-1 (P2, fixed): secret-dependent branch in the base-point ladder

- **Where.** `ge_scalarmult_base` (`src/ed25519.pion`) picked `table[j]` with
  `let eq = if hi == j { 1L } else { 0L }` (and the same for `lo`) before a masked `ge_cmov`.
- **Causal chain.** Pion lowers that `if` to `ceqw` + `jnz` (release SSA: four
  `ceqw %nibble, %j; jnz …` sequences in `ge_scalarmult_base`). The nibbles are those of:
  - the clamped secret scalar `a` in `Ed25519KeyPair::from_seed`;
  - the per-signature nonce `r` in `sign`.

  Which branch is taken on each of the 15 comparisons per window therefore depends on secret nibbles.
  Branch-predictor or timing observation can recover nonce bits, and partial nonce leakage across many
  signatures is enough for lattice key recovery. The comment on the function already claimed
  "constant-time".
- **Trigger.** Category ③: an attacker who can measure fine-grained timing or branch behaviour of the
  signing process (co-resident process, SMT sibling, wasm host). Remote exploitation is impractical.
  Default configuration, no misuse needed.
- **Fix.** The new `ct_eq_nibble(a, b) = (((a ^ b) - 1) >> 31).to_int64() & 1L` emits
  `xor/sub/sar/extsw/and` with no branch. After the fix, release SSA has **0** `ceqw→jnz` pairs in
  `ge_scalarmult_base`, against 4 before. `fe_cmov` and `ge_cmov` were already mask-based, and `sc_mod_l`,
  `fe_tobytes` and `fe_invert` are straight-line code.
- **Side effects.**
  - Outputs are unchanged: `wasm_smoke` stdout and the `pion_bench ed25519` stdout are byte-identical
    before and after.
  - No speed regression: Ed25519 bench about 47 ms before and after.
- **Regression tests.** `redteam_ed25519_branch_free_window_select`; the 16-seed signature digest in
  `wasm_smoke`.

## RT-2 (P3, informational): internal state is reachable by callers

Pion does not yet enforce field privacy or immutability across packages. Fields of a `pub struct`, and
even of a non-`pub` struct or a non-`mut` field, can be read and assigned from an importing package; this
was checked with `pionc check` on a downstream probe. Consequences:
- **`Ed25519KeyPair`.** `kp.scalar` and `kp.prefix` are readable, and `kp.pk` is writable. Signing the
  same message after modifying `pk` reuses the nonce `r` with a different `k`, so
  `a = (S1 - S2) / (k1 - k2) mod L`. This is the known "double public key" oracle: the secret key leaks.
- **Hashers and HMAC.** Writing `fill` out of range makes the next `update` panic. The panic is
  bounds-checked, so it is not memory-unsafe.

No API in this package hands out an alias to these fields: `public_key()` returns a copy and the seed is
not stored. So the risk needs a caller to name the internal fields directly, which is why it is rated P3.
The package cannot fix this itself: there is no way to make a field private or immutable. Re-deriving
`pk` inside every `sign` would double signing cost and still leave `scalar` writable. The README now states
the rule. **Proposal (toolchain):** enforce `pub` field visibility and non-`mut` assignment across
packages; then make these structs opaque.

## RT-3 (toolchain, out of scope): built-in `sha256_hex` shadows the package's function

Inside this package, under `pionc test packages/crypto`, an unqualified `sha256_hex(bytes)` resolves to the
compiler's built-in `sha256_hex(String)` (runtime `pion_sha256_hex`, used for cache keys), not to
`pub fn sha256_hex(data : Bytes)`. The `Bytes` argument is accepted without a type error:
- `sha256_hex("abc".to_bytes())` returns `3e4479e6…0105`;
- `bytes_to_hex(sha256("abc".to_bytes()))` returns the correct `ba7816bf…15ad`.

Downstream callers use `crypto::sha256_hex`, which resolves correctly: verified on native debug and
release, and on wasm32 through `wasm_smoke`. Nothing in `src/` calls it unqualified. The red-team tests
build their expectations with `bytes_to_hex(sha256(..))`. **Proposal (toolchain):** let user definitions
take precedence over built-ins, or report the shadowing, and type-check built-in arguments strictly.

## Reviewed and found sound (no change)

- **SHA-1/SHA-256/SHA-512 compression and padding.** The `rem >= 56` / `rem >= 112` second-block logic
  is correct. The 128-bit length uses `total >> 61`. `finalize` works on a copy of the state. The
  `update_slice` clamp is evaluated before any index.
- **HMAC.** The key is hashed with the same function when it is longer than the block, as RFC 2104
  requires; that includes SHA-384 for HMAC-SHA384. Precomputed ipad/opad states, correct outer length
  words (768 / 1408 / 1536 bits), and `reset()` restores the ipad state.
- **Field arithmetic (ref10 radix 2^25.5).**
  - `fe_mul`/`fe_sq` follow ref10's carry chain. `fe_invert`/`fe_pow22523` follow ref10's addition chains.
  - Limb bounds stay within `fe_mul`'s overflow margin: the worst case is `ge_dbl`'s `f = (B-A)-2Z²`
    at about 2.02·2^26, times about 1.5·2^26; the Int64 sums stay well below 2^63.
  - `fe_tobytes` reduces fully.
- **Group law.** `ge_dbl` is dbl-2008-hwcd and `ge_add` is add-2008-hwcd-3 with `k = 2d`. The addition is
  unified and complete for `a = -1` and a non-square `d`, so identity and doubling inputs are safe.
- **Decoding.** `y < p` is checked before decoding. The ref10 square root uses the `±sqrt(-1)` fix-up.
  `x == 0` with the sign bit set is rejected, and `[8]P == O` is rejected for both `A` and `R`.
- **Scalars.** `sc_mod_l` is TweetNaCl `modL`; its intermediates stay below 2^34. `S < L` is checked
  before any point work.
- **Verification.** `k` hashes the raw (already canonical) `R‖A‖M`. Both projective coordinates are
  compared, and `Z ≠ 0` always holds on the complete curve.

## Reproduce

```sh
export PATH="$HOME/.pion/bin:$PATH"
sh scripts/verify.sh --allow-dirty packages/crypto
pionc test --json --filter redteam packages/crypto
sh packages/crypto/bench/run_bench.sh      # 4-mode wasm_smoke parity (first section) + benchmarks
python3 packages/crypto/audit/gen_vectors.py   # regenerates the vector tail of redteam_test.pion
```

---

# v0.2.0 red-team audit: `packages/crypto` @ `5e9829e` (`feat/pkg-crypto-v2`)

Scope: every line of the five new modules and their shared helpers,
`src/{x25519,hkdf,chacha20,bigint,asn1,p256,rsa,error}.pion`, the v0.2.0 tests, the `wasm_smoke` entry and
the release QBE SSA of the signing paths. Differential references: Go 1.27 `crypto/ecdsa`, `crypto/rsa`,
`golang.org/x/crypto/{curve25519,chacha20,chacha20poly1305,poly1305,hkdf}`, and OpenSSL 3.5 for keys.

## Result

| ID | Severity | Area | Status |
| --- | --- | --- | --- |
| RT-4 | **P1** | RSA CRT signing: square-and-multiply branches on the bits of `dp`/`dq`, and variable-time long division modulo the secret primes | **Fixed** |
| RT-5 | **P2** | P-256 ECDSA signing: `k^-1`, `r·d`, `z + r·d` and `k^-1·(…)` computed with variable-time BigUint routines; `Z^-1` of the nonce point through the generic `big_mod_pow` | **Fixed** |
| RT-6 | **P2** | RSA public exponent unbounded (`e < n` only): one verification with an attacker-chosen 8192-bit `e` costs ≈130 normal ones | **Fixed** |
| RT-7 | P3 | `RsaPrivateKey` / `RsaPublicKey` fields are writable by importers (RT-2 again) | Hardened + documented |
| RT-8 | P3 | Residual timing: limb counts of trimmed secret BigUints, RFC 6979 candidate check, key-range checks | Documented |
| RT-9 | P3 (info) | Parsers accept keys they do not fully cross-check (EC `[1] publicKey`, RSA prime balance/primality) | Documented |
| RT-10 | Info | ECDSA verification accepts `(r, n - s)` | Intended (same as Go/OpenSSL); documented in README |

No P0 was found. Every functional attack in the checklist held before and after the fixes; the three
fixes change no output: RSA signatures, P-256 signatures, `wasm_smoke` (apart from its new lines) and all 8
benchmark stdouts are byte-identical before and after.

## Attack surface covered (`redteam_test.pion`, 13 new `redteam_v2_*` tests)

Inputs are SHA-256 counter blocks `rt2_rb(tag, i, n)` that `audit/v2vectors` (Go) recomputes; the generated
tail holds the expected outputs and one digest per family, so each family is a byte-for-byte comparison
with Go over the whole set.

**X25519** (64 cases vs `x/crypto/curve25519`)
- The 7 canonical small-order `u` (0, 1, the two order-8 points, `p-1`, `p`, `p+1`) give `SmallOrderPoint`
  in `x25519` and exactly 32 zero bytes in `x25519_raw`; Go also errors on each.
- Non-canonical encodings `p+2 … 2^255-1`, the `+2^255` aliases of 0 and 1 and of the order-8 points, `2`,
  `9`: outputs equal Go's. Bit 255 of `u` is masked (`u` and `u ^ 2^255` give the same result) for all 64.
- Twist points: random `u` are on the twist half the time; outputs equal Go (RFC 7748 does not reject
  them, and neither does Go).
- Lengths 0/1/31/33/64 for both inputs and for `x25519_public_key` give the exact `Invalid*Length(n)`.

**HKDF-SHA256/512** (11 lengths vs `x/crypto/hkdf`)
- `len` = 0, 1, 31–33, 64, 65, `255·32`, `255·32+1`, `255·64`, `255·64+1`: output digests equal Go and
  the out-of-range lengths error in both. `len = -1` and `-2^31` give `InvalidLength`.
- PRK of 0/31 (SHA-256) and 32/63 (SHA-512) bytes give `InvalidKeyLength`; empty salt equals `HashLen`
  zero bytes; a long expansion's prefix equals the short expansion.

**ChaCha20 / Poly1305 / AEAD**
- Counter `0xFFFFFFFF` allows exactly one block and `0xFFFFFFFE` exactly two; one more byte is
  `CounterOverflow` (never a wrapped block 0, so no keystream reuse). The 21 cases equal Go, whose
  `x/crypto/chacha20` panics where this package returns the error.
- Poly1305 reduction boundary: with `r = 1` or the largest clamped `r`, `s = 0` or `2^128 - 1`, two full
  `0xFF` blocks drive the accumulator to every value from `2^130 - 13` to `2^130 - 2` (straddling
  `p = 2^130 - 5`), with and without a partial block: 48 tags equal Go. 3,000 more cases with all-`0xFF`
  `r` halves and all-`0xFF` messages of every length 0–256 equal Go.
- AEAD: 64 seal/open/tamper cases equal Go. Every single bit of ciphertext and tag (168), AAD (24),
  nonce (96) and key (256) is flipped: all give `AuthenticationFailed` and no plaintext. Every truncation
  (`< 16` → `InvalidLength(n)`), one appended byte, dropped or zero-extended AAD, and an all-zero tag over
  empty input are rejected. AAD/plaintext lengths 0, 1, 15–17, 31–33, 64 in every combination round-trip.

**BigUint and the constant-time helpers**
- Moduli P-256 `p` and `n`, 3, `2^32 ± 1`, `2^255 - 19` and both 1024-bit primes of an OpenSSL RSA key:
  `big_mod_ct` of 0, 1, `m-1`, `m`, `m+1`, `2m-1`, `2m`, `2^(32k)-1`, `(m-1)^2`, `2^(64k)-1`;
  `mont_mul_mod_ct`, `mod_add_ct`, `mod_sub_ct` and `limbs_mul_add_ct` over 8×8 operands including `0`,
  `1`, `m-1`, `m-2`; `mont_pow_ct` with exponents `0`, `1`, `2`, `3`, `m-2`, `m-1`, `2^(32k)-1`, random —
  all equal the reference `big_mod` / `big_mul_mod` / `big_mod_pow`. Carry and borrow chains across all
  limbs.

**NIST P-256**
- Complete group law: `G + (-G)`, `(-G) + G`, `2G + (-2G)` (unnormalised `Z`) are `O`; `O + G`, `G + O`,
  `O + O`, `2O`; `G + G = 2G`; `[0]G = [n]G = O`, `[n-1]G = -G`, `pk(n-1) = (Gx, p - Gy)`; the Shamir
  ladder with `[n-1]G + G` and `G + (-G)`.
- 24 keys including `d = 1`, `d = n - 1`, and the invalid `d = 0`, `d = n`: public keys and RFC 6979
  signatures are byte-identical to Go's deterministic `crypto/ecdsa`; `(r, n - s)` verifies (RT-10);
  `r + 1` and a changed message are mismatches. 8 randomized Go DER signatures verify.
- Public keys: `x = p`, `y = p`, `x + p` and `y + p` aliases, `(0, y0)` vs its alias `(p, y0)` (a real point
  with a small `x`, so the alias is reachable), `y + 1`, all-`0xFF`, `(0, 0)`, prefix `00`, `06` (hybrid),
  33/66-byte encodings; `-Q` is a valid point but a mismatch.
- Scalars `r`, `s` ∈ {0, `n`, `n+1`, `2^256-1`} are `InvalidScalar` in raw and DER form; `r = n - 1` is a
  mismatch; signature lengths 63/65.
- DER: long-form lengths `81 xx` / `82 00 xx` / `84 00 00 00 xx` for short content, indefinite `80 … 00 00`,
  trailing `00` / `00 00`, long-form INTEGER length, redundant `00` before a positive `r` or `s`, negative
  `02 01 80`, empty INTEGER, a third INTEGER, a missing `s`, outer tag `31`, inner tags `03`/`04`, lengths
  off by ±1, `30 ff`, `30 00`, empty input and every strict prefix: all rejected (`InvalidDer`).
- PEM/Base64: exact padding, zero trailing bits (`QR==`, `QUJ=`), `=` in the middle, `-`, `.`, `_`, NUL,
  non-ASCII, lengths not ≡ 0 mod 4; wrong labels, missing footer, two concatenated blocks, encapsulated
  headers, a malformed BEGIN line.
- PKCS#8/RFC 5915, rebuilt field by field: `d = 0`, `d = n`, 31/33-byte `d`, PKCS#8 version 1, ECPrivateKey
  version 0, P-384 and Ed25519 OIDs, `[0]` with the P-384 OID, `[1]` with unused bits, `[1]` before `[0]`, an
  extra element, a trailing byte.

**RSA**
- OpenSSL 3072-bit, 4096-bit and `e = 3` 2048-bit keys: 9 RS256 signatures byte-identical to Go
  `rsa.SignPKCS1v15`; each verifies and a flipped bit is a mismatch.
- Bleichenbacher-style blocks signed with the raw private operation (so only the verifier stands in the
  way): missing `NULL`, garbage parameters, 7-byte PS with trailing garbage, block types `02`/`00`, leading
  byte `01`, `00` or `FE` inside PS, SHA-512 OID with a 32-byte digest, a 31-byte OCTET STRING, 1 or 4
  trailing bytes, missing separator, BER long-form DigestInfo length, another message's digest: all
  `SignatureMismatch`.
- Bleichenbacher 2006 cube-root forgeries for `e = 3` without the private key (PS of 1 and 8 bytes): the test
  first proves `s^3` really starts with `00 01 FF… 00 DigestInfo H`, then requires rejection.
- `sig` = 0, 1, `n-1`, `n`, `n+1`, all-`0xFF`; lengths `size ± 1`.
- Keys: 2047/8193-bit and even moduli, `e` ∈ {empty, 0, 1, 2, 4, 2^16, 2^33+1, 2^64+1, ≈`n`} rejected,
  `e` ∈ {3, 65537, 2^33-1} accepted. SPKI rebuilt field by field: big `e`, `NULL` with content, two `NULL`s,
  unused bits, extra INTEGER, trailing element/byte, RSASSA-PSS OID, negative `n`, non-minimal `83 00 …`
  length. PKCS#8 rebuilt byte-identical to OpenSSL's, then one relation broken at a time: version 1,
  `n ≠ p·q`, even `e`, `e = 1`, `e = 2^33+1`, `d` ∈ {0, 1, `n`}, `p = q`, `p`/`q` swapped, wrong `dp`, `dq`,
  `qinv`, `qinv = 0`, multi-prime `otherPrimeInfos`, PKCS#8 version 2, PSS OID, trailing byte.

**Mutation check.** 25 single-line mutants of the code under test were run against the `redteam_v2_*`
tests; 24 are killed:
- the new `big_mod_ct` mask, `mont_pow_ct` window shift, `mod_add_ct` select, `mod_sub_ct` mask,
  `limbs_mul_add_ct` carry, P-256 `z + r·d`, the `Z^-1` window count, the CRT `a - b` order and the `e` cap;
- Poly1305 final select, AEAD ciphertext padding, the ChaCha20 counter bound, HKDF length and PRK bounds,
  the X25519 all-zero check;
- DER minimal length, zero first length byte, redundant INTEGER `00`, Base64 trailing bits, P-256 `x < p`
  and `s < n`, the PKCS#8 `[0]` OID check, RSA `qinv` relation, SPKI unused bits, and a verifier that only
  compares the last 51 bytes.

The survivor drops `h1 += c` after the last carry in `poly1305_finalize`. That carry is non-zero only when
`h2 = h3 = h4 = 2^26 - 1` and `h0 ≥ 2^26 - 5` all hold after a carry out of `h1`: about `2^-78` per tag for a
secret `r`, and not reachable with `r = 1`. The line is kept, as in poly1305-donna.

## RT-4 (P1, fixed): RSA CRT signing leaks the private key through branches

- **Where.** `rsa_sign_rs256` (`src/rsa.pion`) computed `m^dp mod p` and `m^dq mod q` with
  `big_mod_pow` (`src/bigint.pion`), and recombined with `big_mod` / `big_sub_mod` / `big_mul_mod`.
- **Causal chain.**
  1. `big_mod_pow` is left-to-right square-and-multiply: `if big_get_bit(exp, bit) == 1 { acc = … }`.
     The release SSA has `ceqw …, 1; jnz` on each exponent bit, and the loop runs `bitlen(exp)` times. The
     sequence of squarings and multiplications is `dp` and `dq` bit for bit.
  2. `big_mod_pow` also builds `R^2 mod p` with `mont_r2` → `big_mod`, and reduces `m mod p` with
     `big_mod`. `big_mod` is binary long division with `if ge { subtract }` per bit, so its branch trace
     is the quotient bits of `2^(64k) / p` and `m / p`: the high half of `p` from one call.
  3. `big_mod(b, p)`, `big_sub_mod`, `big_mul_mod(diff, qinv, p)` add more compare-and-branch traces on
     values derived from `p`, `q` and `qinv`.

  Any one of `dp`, `dq` or the top half of `p` factors `n` (with `e`, `dp` gives `p = gcd(m^(e·dp) - m, n)`;
  half of `p` gives Coppersmith). One signing trace is enough.
- **Trigger.** Category ③: an attacker who observes branch or cache behaviour of the signing process
  (co-resident process, SMT sibling, a wasm host that times the guest). Default configuration, no misuse.
  Rated P1 rather than RT-1's P2 because one trace recovers the whole key, against partial nonce bits over
  many signatures for RT-1.
- **Fix.** New constant-time helpers in `src/bigint.pion`, each with a fixed public iteration count:
  - `big_mod_ct(a, a_limbs, m)`: binary long division over exactly `32·a_limbs` bits with a masked
    subtraction per bit;
  - `mont_ctx_ct(m)`: Montgomery context with `R^2 mod m` from `big_mod_ct` (no `big_mod` on a secret modulus);
  - `mont_pow_ct(ctx, base, exp, exp_limbs)`: fixed 4-bit window over every limb of the exponent. Each
    window does 4 squarings, a masked scan of all 16 table entries (`ct_eq_nibble`) and one multiplication.
    Neither the exponent bits nor its length change the control flow or the number of multiplications;
  - `mont_mul_mod_ct`, `mod_add_ct`, `mod_sub_ct`, `limbs_mul_add_ct`: masked carry/borrow selection.

  `rsa_crt_private` uses them for `m mod p`, `m mod q`, both exponentiations, `b mod p`, `(a - b)·qinv mod p`
  and `q·h + b`. The Bellcore check `s^e mod n == m` keeps the generic `big_mod_pow`, because it only touches
  the public signature, `e` and `n`.
- **Evidence.** `audit/ct_ssa_check.py` (release SSA of `wasm_smoke`, fresh `PION_CACHE_DIR`):
  - **before:** `FAIL rsa_sign_rs256 calls big_mod, big_mod_pow, big_sub_mod`;
  - **after:** every constant-time helper has only loop, allocation, bounds-check and refcount `jnz`, and
    `rsa_crt_private` / `rsa_sign_rs256` call no variable-time routine.

  As a negative control, the same detector flags data branches in `big_mod`, `big_cmp`, `big_mul` and
  `big_mod_pow`.
- **Side effects.**
  - Signatures are unchanged: byte-identical to Go for 2048/3072/4096-bit and `e = 3` keys, and the
    existing OpenSSL vectors pass.
  - Speed is unchanged or better: 20 × 2048-bit + 20 × 4096-bit signatures take 0.53–0.56 s after against
    0.60–0.61 s before (fewer multiplications than binary square-and-multiply).
- **Regression tests.**
  - `redteam_v2_bigint_constant_time_helpers_vs_reference`, `redteam_v2_rsa_3072_4096_e3_parity_vs_go`,
    `redteam_v2_rsa_bleichenbacher_forgeries_rejected` (its raw-signature oracle is `rsa_crt_private`);
  - `wasm_smoke` (RSA-2048 signature digest on all 4 targets);
  - `audit/ct_ssa_check.py`.

## RT-5 (P2, fixed): ECDSA P-256 scalar arithmetic was variable-time

- **Where.** `p256_sign_es256` computed `nonce_inv = big_mod_pow(k, n-2, n)`, `rk = big_mul_mod(r, d, n)`,
  `sum = big_add_mod(z, rk, n)` and `s = big_mul_mod(nonce_inv, sum, n)`. `p256_affine` inverted `Z` of
  `[k]G` (and of `[d]G` in `p256_public_key`) with `big_mod_pow` after `fp_from_mont` → `big_trim`.
- **Causal chain.** `big_mul_mod` is `big_mul` (loop bounds from the trimmed limb counts) followed by
  `big_mod`, which branches on every bit of `r·d` and of `k^-1·(z + r·d)` as integers. `r`, `z` and `s` are
  public, so the trace of `r·d mod n` gives linear information on `d` directly. The trace of the final
  reduction gives information on `k^-1`, and partial nonce information across signatures is a lattice
  (hidden number problem) attack. The constant-time base-point ladder did not cover these steps.
- **Trigger.** Category ③, as RT-4; it needs many signatures and precise traces, hence P2.
- **Fix.** `p256_sign_es256` uses one `mont_ctx_ct(n)`:
  - `k^-1 = mont_pow_ct(k, n-2)`;
  - `r·d` and `k^-1·sum` through `mont_mul_mod_ct`, and `z + r·d` through `mod_add_ct`, all over fixed
    8-limb operands.

  `p256_affine` converts `Z` with one Montgomery multiplication and inverts it with
  `mont_pow_ct(mont_ctx_ct(p), Z, p-2)`.
- **Evidence.** `ct_ssa_check.py`:
  - **before:** `FAIL p256_sign_es256 calls big_mod_pow`, `FAIL p256_affine calls big_mod, big_mod_pow`;
  - **after:** PASS.
- **Side effects.**
  - Signatures are unchanged: 24 keys are byte-identical to Go RFC 6979, including `d = n - 1`, and the
    RFC 6979 A.2.5 vectors pass.
  - P-256 bench (50 sign + 50 verify) is 91.6 ms median after against 94.4 ms before; the stdout hash is
    identical.
- **Regression tests.** `redteam_v2_p256_rfc6979_and_verify_vs_go`, `redteam_v2_p256_complete_group_law`,
  `redteam_v2_bigint_constant_time_helpers_vs_reference`, `wasm_smoke` line `v2_rt_p256_sig_d_n_minus_1`.

## RT-6 (P2, fixed): unbounded RSA public exponent

- **Where.** `RsaPublicKey::from_components`, `from_spki_der` and `RsaPrivateKey::from_pkcs8_der`
  accepted any odd `3 ≤ e < n`; `rsa_verify_rs256` then runs `big_mod_pow(s, e, n)`, one squaring per bit
  of `e`.
- **Impact.** An attacker who supplies the key, such as a JWK/JWKS, a certificate or an SPKI upload, picks an
  8192-bit `n` and `e ≈ n`. One verification then takes 0.86 s, against 6.6 ms with `e = 65537` on the same
  modulus: about 130 times as long per request, with no signature needed. Category ③.
- **Fix.** `rsa_max_e_bits() = 33` (BoringSSL's `kMaxExponentBits`; Go's own limit is lower) in all three
  constructors. Every real-world exponent (3, 17, 65537, up to `2^33 - 1`) is still accepted.
- **Regression tests.** `redteam_v2_rsa_malformed_keys_and_exponent_cap` checks `2^33+1`, `2^64+1` and `≈n`
  through `from_components`, SPKI and PKCS#8, and that `2^33-1` is accepted. `wasm_smoke` has the line
  `v2_rt_rsa_e_cap`.

## RT-7 (P3, hardened): RSA key fields are writable by importers

The same language limitation as RT-2 applies to the new key types. A downstream probe compiles
`crypto::RsaPublicKey::{ n: pk.n, e: pk.e, size: 1 }`, so the validation in the constructors can be bypassed
by building keys from fields of other keys. Effects:
- Swapping or mixing `p`, `q`, `dp`, `dq` or `qinv` produces a wrong CRT result. The Bellcore check catches
  it, and no faulty signature (which would factor `n`) is released.
- `rsa_crt_private` now rejects a zero-length or even `p`/`q` and `m ≥ n` before any Montgomery set-up.
- A bogus `size` only produces errors.

No API hands out these fields. **Proposal (toolchain):** the same as for RT-2.

## RT-8 (P3, documented): residual timing

The following still have data-dependent behaviour, each with negligible leakage:
- `to_fixed_limbs` copies `min(a.len, k)` limbs. For a secret BigUint that reveals only whether its top
  limb(s) are zero (probability about `2^-32` per value).
- RFC 6979 rejection sampling compares the candidate with `n`. This is inherent to the RFC and
  independent of the accepted nonce.
- The range checks of `d` in `p256_public_key` / `p256_sign_es256` / PKCS#8 parsing, and the PKCS#8 RSA
  consistency checks, run once per key load, not per signature.

## RT-9 (P3, informational): what the parsers do not cross-check

- `p256_secret_from_pkcs8_der` checks the optional `[1] publicKey` only for DER shape. It does not compare it
  with `[d]G`; the scalar is what gets used.
- `RsaPrivateKey::from_pkcs8_der` checks every CRT relation but not primality or the balance of `p` and `q`.
  A malformed key can at worst make signing fail the Bellcore check; it cannot release a wrong signature.

Neither is reachable without the private key file itself.

## Reviewed and found sound (no change)

- **X25519.** Clamping, the bit-255 mask in `fe_frombytes`, a 255-step ladder with `fe_cswap_pair`
  (mask-based; release SSA has 0 `jnz`), `a24 = 121665`, all-zero output rejection.
- **HKDF.** RFC 5869 block chaining with a single-byte counter (`n_blocks ≤ 255` is guaranteed by the length
  check), and bounds checked before allocation.
- **ChaCha20.** RFC 8439 quarter rounds. The counter check is `(len-1)/64 ≤ 0xFFFFFFFF - counter` before
  any output. `open` authenticates before it decrypts and returns no partial plaintext.
- **Poly1305.** Donna 26-bit limbs: products stay below `2^63`. The final `h + 5 - 2^130` select is
  mask-based, and the 128-bit `s` addition carries correctly (all boundary cases equal Go).
  `poly1305_update_lengths` is only reached after `pad16`, so the buffer is empty.
- **ASN.1/PEM.** Tags, definite lengths only, minimal long form (`n ≤ 3`, no leading zero, `≥ 128`),
  canonical non-negative INTEGERs, `done()` checks after every SEQUENCE, strict Base64 with zero trailing
  bits, exact PEM labels, a 32 KiB PEM cap.
- **P-256.** Constants `p`, `n`, `b`, `G` were checked against SEC 2. `fp_add`/`fp_sub`/`mont_mul_limbs`
  are branch-free (SSA). The RCB complete formulas were checked by the group-law tests. Verification checks
  `x, y < p`, the curve equation, the range of `r, s`, `O`, and `x mod n`.
- **RSA verification.** Full-block `constant_time_eq` against the single canonical EMSA-PKCS1-v1_5
  encoding, `sig < n`, exact length.

## Reproduce (v0.2.0)

```sh
export PATH="$HOME/.pion/bin:$PATH"
sh scripts/verify.sh packages/crypto
pionc test --json --filter redteam_v2 packages/crypto
python3 packages/crypto/audit/ct_ssa_check.py            # constant-time SSA gate (RT-4/RT-5)
sh packages/crypto/bench/run_bench.sh                    # 4-mode wasm_smoke parity + 8 benchmarks
cp -R packages/crypto/audit/v2vectors /tmp/v2vectors && (cd /tmp/v2vectors && go run .)  # regenerate the rt2_* tail
```
