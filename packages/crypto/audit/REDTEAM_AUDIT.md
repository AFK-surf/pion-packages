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
