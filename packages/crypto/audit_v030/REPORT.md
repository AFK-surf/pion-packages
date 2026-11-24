# RT-crypto-v030: red-team audit of `packages/crypto` v0.3.0

| | |
| --- | --- |
| Target | `origin/feat/crypto-v030` @ `fc168c0` (`src/aes_gcm.pion`, the v0.3.0 additions to `src/p256.pion`, the new benchmarks and README claims) |
| Reference | Go 1.27.3 stdlib: `crypto/aes` + `cipher.NewGCMWithNonceSize`, `crypto/ecdh.P256()`, `crypto/elliptic.UnmarshalCompressed`; NIST SP 800-38D; SEC 1 v2 §2.3.3–2.3.4; Wycheproof attack classes |
| Toolchain | `pionc` 0.1.0 (`AFK-surf/pion@66d2b4b`), node + `pion_wasm_rt.mjs`, `darwin/arm64` (Apple M5 Max (Darwin arm64)) |
| Reproduce | `sh packages/crypto/audit_v030/run_audit.sh` (≈2–4 min; artefacts in `/private/tmp/rt-crypto-v030-*`, the worktree stays clean) |
| Changes | Only `packages/crypto/audit_v030/**`; nothing else in the repository was touched |

## Result: 0 P0 / 0 P1 / 1 P2 (+ 3 informational notes)

| ID | Severity | Area | Gate in `run_audit.sh` |
| --- | --- | --- | --- |
| P2-1 | **P2** | Benchmarks: the 4 new head-to-head rows overstate Pion's ratio to Go by **3.3×–12.4×** because Go's side is mostly process start-up (README headline "0.65× on P-256 pubkey validation" is in-process **0.09–0.11×**) | `bench` → **FAIL** (exit 1) |
| INFO-1 | info | `p256_ecdh` scalar range check runs the secret `d` through variable-time `big_from_be`/`big_cmp` (same pattern as the existing `p256_public_key` / `p256_sign_es256`) | reported by `ct` (not gated) |
| INFO-2 | info | SP 800-38D input-length limits (P ≤ 2^39−256 bits, i.e. ≤ 2^32−2 blocks) are not enforced; Go panics instead | documented only (needs a 64 GiB buffer) |
| INFO-3 | info | `p256_validate_pubkey` accepts 33-byte compressed keys, `crypto/ecdh.NewPublicKey` does not | documented API choice |

**No functional or constant-time defect was found in AES-128/256-GCM, P-256 validation/decompression or
P-256 ECDH.** All 20,054 Go-oracle vectors are byte-identical in all four build modes, every control test
passes, the SSA constant-time gate passes, and 10 / 10 re-created bug classes are detected by this audit
(so the clean result is not an artefact of weak tests). `run_audit.sh` exits 1 only because of P2-1; a
fix branch that raises the benchmark iteration counts reruns it unchanged to `exit 0`.

Gate summary (`run_audit.sh all` on Apple M5 Max (Darwin arm64) at load average ≈ 30; timings vary with load, the verdicts did not across 3 runs):

```
GATE tests: PASS      84/84 (8 audit controls + the package's 76)
GATE diff: PASS       20054 vectors x 4 modes, 0 mismatches, 0 traps, one stdout sha256
GATE ct: PASS         32 functions branch-free, 26 table-free, 7 public-branch budgets, 0 VT calls
GATE mutants: PASS    10/10 killed
GATE bench: FAIL      4/4 rows overstated >= 2x  -> P2-1
```

---

## P2-1: the v0.3.0 benchmark rows measure process start-up, not crypto

**Where.** `packages/crypto/bench/pion_bench/src/main.pion` and `bench/go/main.go` (`aes256gcm` 64 × 64 KiB,
`aes256gcm_small` 2,000 × 256 B, `p256_ecdh` 50 ops, `p256_validate` 200 + 200 ops), run by
`bench/run_bench.sh` BENCH 9–12; reported in `packages/crypto/README.md` (benchmark table and the
"Pure Pion reaches … 0.65× on P-256 pubkey validation" headline).

**What.** Each benchmark is a separate process. Spawning, runtime init and exit cost ≈3 ms for the Go binary
and ≈2.5 ms for the Pion binary here (≈6–7 ms inside `bench_compare.py`, which also samples RSS). Go's
actual work in these four rows is only 0.8–5 ms, so 49–83 % of the Go median is fixed cost, which pushes
every Pion/Go ratio towards 1. The stdout SHA-256 check passes (the outputs are identical), so the rows are
*valid* but *misleading*, contrary to AGENTS.md §1.3 ("如实记录领先与落后项").

**Evidence** (`bench_check.py`; the same workloads re-run in-process with a larger `n`, identical inputs,
identical stdout SHA-256 to the repository bench at equal `n`, `bench_compare.py --warmup 1 --rounds 5`):

| Workload | repo row (as run_bench.sh) Pion / Go median | repo ratio | in-process n | Pion rate | Go rate | honest ratio | overstated by |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| AES-256-GCM 64 KiB seal+open | 120.2 ms / 10.8 ms | 0.090× | 2,000 | 73.0 MB/s | 2,687 MB/s | **0.027×** | 3.3× |
| AES-256-GCM 256 B seal+open | 37.2 ms / 8.5 ms | 0.229× | 300,000 | 7.53 µs/op | 0.14 µs/op | **0.018×** | 12.4× |
| P-256 ECDH | 42.4 ms / 9.5 ms | 0.223× | 3,000 | 736 µs/op | 34.4 µs/op | **0.047×** | 4.8× |
| P-256 pubkey validate (U + C) | 14.0 ms / 8.1 ms | 0.580× | 50,000 | 18.8 µs/op | 1.77 µs/op | **0.094×** | 6.1× |

An earlier run under a different load gave the same picture (overstated 3.3×–39×; P-256 validate 0.107×,
ECDH 0.045×). README's own figures (Go 12.4 ms for 400 validations, 14.3 ms for 50 ECDH, 11.8 ms for 2,000
small AES-GCM packets) are themselves start-up dominated.

**Minimal reproduction.**
```sh
sh packages/crypto/audit_v030/run_audit.sh build && sh packages/crypto/audit_v030/run_audit.sh bench
```

**Fix (outside `audit_v030/`).** Raise the iteration counts in both bench programs (and the `--ops`/`--bytes`
in `run_bench.sh`) so each side runs well over 100 ms of real work, e.g. validate ≥ 50,000, ECDH ≥ 3,000,
small AES-GCM ≥ 300,000, large AES-GCM ≥ 1,000 × 64 KiB; then refresh the README table and headline (and
add the v0.3.0 rows to the root `BENCHMARKS.md`, which still lists only the 8 v0.2.0 rows). The gate
compares the repository row's ratio with the in-process ratio and passes once they agree within 2×.

Note that Pion's in-process AES-256-GCM rate (73 MB/s) is *higher* than the README's 55.2 MB/s: the
current rows understate Pion's absolute throughput while overstating its ratio to Go.

---

## INFO-1: variable-time scalar range check in `p256_ecdh`

`src/p256.pion:881-883` parses the secret with `big_from_be` (→ `big_trim`, `src/bigint.pion:11-16`, loops
while the top limb is zero) and compares it with `big_cmp(d, n)` (`src/bigint.pion:46-63`, returns at the
first differing limb). Timing therefore depends on `d` only when its top 32-bit limb is `0` or
`0xFFFFFFFF` (probability ≈2^-31 for a random key), and reveals at most that fact. `p256_public_key`
(`:404-406`) and `p256_sign_es256` (`:466-468`) use the same pattern and were accepted by the earlier audit.
Not a practical leak; a fixed-limb, mask-based range check would remove it. The scalar multiplication
itself (`p256_scalarmult_ct`, `:727`) is branch-free and table-free in the emitted SSA (see below).

## INFO-2: SP 800-38D length limits not enforced

`aes_gcm_seal_inner` / `aes_gcm_open_inner` (`src/aes_gcm.pion:724-794`) accept any plaintext length. Beyond
2^32 − 2 blocks (≈ 64 GiB) the 32-bit counter would wrap back to `J0` and reuse keystream; Go panics with
"message too large for GCM". Unreachable on wasm32 and impractical natively (a single 64 GiB `Bytes`), so
informational; a length check returning `InvalidLength`, like ChaCha20's `CounterOverflow`, would close it.

## INFO-3: compressed points are accepted

`p256_validate_pubkey*` and `p256_ecdh` accept SEC1 compressed keys (33 B) besides uncompressed (65 B).
Go's `crypto/ecdh.NewPublicKey` rejects compressed encodings; `crypto/elliptic.UnmarshalCompressed` and
OpenSSL accept them. The behaviour is documented in the README and is correct (both encodings of a point
give identical ECDH output, see below). Protocols that require uncompressed keys must check the length.

---

## What was attacked and held (fair account of the robust parts)

### AES-128-GCM / AES-256-GCM (`src/aes_gcm.pion`)

- **`inc_32` wrap (SP 800-38D §6.2).** `gcm_inc32` (`:608-617`) carries only through bytes 12–15 and drops
  the final carry. Tested with 16-byte nonces *constructed* so that `J0`'s low word is `0xFFFFFFFF`,
  `0xFFFFFFFE`, `0xFFFFFFFD`, `0xFFFFFFFC`, `0xFFFFFFF0`, `0x7FFFFFFF` or `0`, including `J0` whose upper 96 bits
  are all `0xFF` (so a 128-bit carry would change every later block): the Go oracle solves
  `N = ((J0·H⁻¹) ⊕ L)·H⁻¹` in GF(2^128) and self-checks it, 504 seal/open vectors match Go. Control
  test `control_gcm_inc32_wraps_low_32_bits_only` pins 4 KATs and asserts the output differs from what a
  128-bit increment would produce. Mutant M1 (128-bit carry) is caught by 216 vectors.
- **Length grid.** Plaintext `{0,1,15,16,17,31,32,33,47,48,49,63,64,65,127,128,129,1000}` × AAD
  `{0,1,15,16,17,32,65}` × nonce `{0,1,8,11,12,13,16,32,64,128}` × both key sizes, seal and open (5,040
  vectors), plus 64 KiB + 5 B / 4 KiB AAD / 1000-byte nonce, 20,000 B plaintext and 70,000 B AAD cases. Byte-identical
  to Go. The 4-block bitsliced tail path (`gcm_gctr`, `:641-691`) handles every residue mod 64.
- **Forgery / tampering.** Every tag bit, sampled ciphertext bits, AAD bits, nonce bits, key bits,
  truncation by 1–16 bytes, an appended byte, AAD ± 1 byte, moving one byte across the AAD/ciphertext
  boundary, a 12-byte nonce vs its zero-padded 16-byte form, the all-zero tag, and `tag = E_K(J0)` for an
  empty message: 8,404 vectors, all rejected exactly as Go. The tag is checked with `constant_time_eq`
  before any decryption (`:781-792`); no plaintext is returned on failure.
- **Input validation.** Empty nonce → `InvalidNonceLength(0)`; key length 0/1/15/17/24/31/33/64 →
  `InvalidKeyLength(n)` (AES-192 keys are rejected by both APIs, and the 128/256 APIs do not accept each
  other's key size); `open` input of 0–15 bytes → `InvalidLength(n)`. All-zero key/nonce/AAD/plaintext match Go.
- **Constant time.** In the release QBE SSA, all AES round functions, key packing, `aes_sub_word_ct`,
  GHASH (`ghash_bmul32/64`, `ghash_mul_gf128`, …), `gcm_inc32` and `gcm_compute_tag` contain no data branch
  and load no data symbol (no S-box, T-table or 4-bit GHASH table). The only data branches in the GCM layer
  are on public lengths/indices: `aes_key_expand` 6 (`i % nk`), `gcm_gctr` 3, `gcm_derive_j0` 1 (nonce
  length), `ghash_update_padded` 1, the seal/open length checks and the final tag verdict. The GHASH
  32×32 multiply uses BearSSL's masked "holes" technique; with 8 terms per lane the carries never reach the
  next lane, so it is exact (also confirmed by the differential).

### P-256 public keys (`p256_parse_sec1_pubkey`, `src/p256.pion:777-832`)

- Infinity `0x00`, empty, `0x04‖0‖0`, `(0,0)`, `x = p`, `x = p+1`, `x = 2^256−1`, `y = p`, `x = y = 2^256−1`,
  `G` with `y+1` / `x−1`, 40 random off-curve points, 60 twist `x` (non-residue `x³−3x+b`) as `02`/`03`/`04`,
  prefixes `00 01 05 06 07 08 FF` on 33- and 65-byte bodies, hybrid `06/07` with correct parity, lengths
  0–70, trailing bytes, raw 64-byte `X‖Y`, and 300 random valid points with `y → p−y` (valid) and
  `y → y+1` (invalid): `validate`, `validate_strict`, `decompress` agree with each other and with Go on all
  of them. Exact error kinds are pinned by `control_p256_rejects_invalid_encodings`.
- **Non-canonical coordinates that still fit 32 bytes.** `y + p` only fits when `y < 2^256 − p ≈ 2^224`, so
  random points never test it. The oracle finds such points by solving `x³ − 3x + b − y² = 0` over F_p for
  small `y` (root of `gcd(X^p − X, f)`); e.g. `(0xd7325d76…8de1d7, 5)` is on the curve and
  `(…, 5 + p)` must be rejected — it is. `(0, √b)` is valid and `(p, √b)` (= `0 + p`) is rejected.
  Removing the `y < p` check (mutant M5) is caught only by these vectors.
- **Compressed points.** `x = 0` (b is a QR) decodes for both parities like Go; `x ≥ p` is rejected;
  non-residue `x` is rejected because `√` is verified by squaring (`:820`); parity selection (`:823`) and
  the `02`↔`03` flip give `(x, p−y)`; compress → decompress round-trips for `d = 1..24`.

### P-256 ECDH (`p256_ecdh`, `src/p256.pion:877-902`)

- `d = 0, n, n+1, 2^256−1` → `InvalidScalar`; length 0/1/31/33/64 → `InvalidKeyLength`; `d = 1` gives
  `Pₓ`, `d = n−1` gives `Pₓ` (since `(−P)ₓ = Pₓ`), `d = 2, n−2, n−16, 15, 16, 2^255, p` match Go against both a
  random peer and `G`, each in compressed and uncompressed form. 64 sparse scalars (a single non-zero
  byte at every position: long runs of zero windows, the `table[0]`/infinity path of the complete
  formulas) match Go. 200 random `(d, Q)` pairs match Go for `Q` uncompressed, compressed, and
  parity-flipped compressed (`−Q`, same x-coordinate). All invalid peers above are rejected before any
  scalar multiplication.
- `p256_scalarmult_ct` (`:727-773`) uses the complete Renes–Costello–Batina formulas, so the exceptional
  cases of the fixed 4-bit window (accumulator at infinity, zero nibbles) are handled without branches; the
  window lookup is a full 16-entry `cmov` scan. Its SSA is branch-free, table-free and calls only
  `p256_add` / `p256_dbl` (themselves branch-free).

### 4-mode Wasm32 consistency

`native_dbg`, `native_rel`, `wasm_dbg`, `wasm_rel` each produce 20,054 lines with SHA-256
`487393102a94facced1af47a4194037f68ca693ff527b206621bfd16726c19df`, identical to the Go expectation file;
0 traps, 0 non-zero exits (≈1 s per mode).

### Mutation sensitivity (`mutants.py`)

| Mutant | Bug class | Killed by |
| --- | --- | --- |
| M1 | `inc_32` carries into the upper 96 bits | 216 corpus vectors |
| M2 | tag check skipped | 8,342 |
| M3 | GHASH length block drops `len(A)` | 4,428 |
| M4 | 96-bit nonce `J0` counter = 0 | 522 |
| M5 | `y ≥ p` accepted | 12 (small-y points only) |
| M6 | on-curve check skipped | 812 |
| M7 | compressed parity swapped | 603 |
| M8 | `√` not verified (twist accepted) | 308 |
| M9 | ECDH accepts `d = n` (fails later as `InvalidPoint`) | control test (exact error kind) |
| M10 | hybrid `0x06` accepted | 122 |

## Files

| File | Purpose |
| --- | --- |
| `run_audit.sh` | One command: build, tests, diff, ct, mutants, bench gates (exit 1 on any failure) |
| `go/main.go` | Go stdlib oracle: deterministic corpus + expectations (`gen`), KATs (`kat`), scaled bench (`bench`) |
| `oracle/` | Pion oracle (`vectors`, scaled `bench`), built in all four modes |
| `tests/redteam_v030_test.pion` | 8 `control_*` tests (exact error kinds, inc_32 KATs, encodings, ECDH edges) |
| `ct_ssa_check_v030.py` | Release-SSA constant-time gate for the v0.3.0 code |
| `mutants.py` | Mutation sensitivity of the corpus and tests (copies under `/private/tmp`) |
| `bench_check.py` | Benchmark reproduction and the P2-1 gate |
