# RT-crypto-v040: red-team audit of `packages/crypto` v0.4.0 (PBKDF2 / scrypt)

- **Target**: `origin/feat/crypto-v040` @ `8775804` (`src/pbkdf2.pion`, `src/scrypt.pion`, the
  `CryptoError::{InvalidParam, MemoryLimitExceeded}` additions, `kdf_test.pion`, BENCH 13/14).
- **References**: RFC 8018 §5.2, RFC 7914 §2–§6/§11/§12, `golang.org/x/crypto/{pbkdf2,scrypt}` v0.58.0,
  Node.js 24.22.2 `crypto.pbkdf2Sync` / `crypto.scryptSync` (OpenSSL 4.1.0) + `aes-256-gcm`.
- **Toolchain**: `pionc` 0.1.0 (`AFK-surf/pion@66d2b4b`), Go 1.27.3, Darwin arm64.
- **Reproduce**: `sh packages/crypto/audit_v040/run_audit.sh` (all artefacts in `/private/tmp/rt-crypto-v040-*`).
  It exits **1** on `8775804` (gates `tests`, `diff` and `probes` fail on the findings below; `ct`,
  `mutants` and `bench` pass) and is written so that a fix branch reruns it unchanged, without
  touching `audit_v040/`, to `exit 0`: with the minimal fix sketched below (7 changed lines in
  `src/pbkdf2.pion` / `src/scrypt.pion`, applied to a scratch copy) every gate passes and the
  package's own 82 tests still pass.

## Verdict

**0 P0 · 1 P1 · 3 P2.** The cryptographic core is correct: every one of the 1,103 Go-generated
vectors (all HMAC key-folding and `salt || INT(i)` padding boundaries, `dkLen` 1–256, the full
`N × r × p` matrix up to `N = 32768, r = 16, p = 4`, the max_mem boundaries and 16 `.mlogin.enc` v1
envelopes for `N = 1024 … 131072`) is byte-identical to Go **and** to Node.js, in all four build modes
(`native_dbg` / `native_rel` / `wasm_dbg` / `wasm_rel`, identical stdout SHA-256, 0 traps). All 17
re-created bug classes (Salsa20/6, Integerify offset, BlockMix shuffle, HMAC fold at 64/128, INT(i)
endianness, padding off-by-one, ...) are detected. The `.mlogin.enc` v1 path (N=32768, r=8, p=1,
64 MiB) is safe and interoperable.

The findings are all at the **integer / allocation edges** of the public API: a 2 GiB `dk_len`
returns an all-zero "key" (P1-1) or aborts the process (P2-1); a caller-raised `max_mem` traps on
wasm32 (P2-2); and the RFC 7914 `N < 2^(16 r)` rule is not enforced (P2-3). None is reachable through
the `.mlogin.enc` parameters; all are reachable by any caller that forwards untrusted KDF parameters
(e.g. parameters read from an encrypted file header).

| ID | Sev | Finding | Where | Gate |
| --- | --- | --- | --- | --- |
| P1-1 | P1 | `dk_len` ∈ [2³¹−31, 2³¹−17] (SHA-256) / [2³¹−63, 2³¹−17] (SHA-512): `n_blocks` wraps negative, `Ok(2 GiB of zeros)` | `pbkdf2.pion:96`, `:282` (+ `scrypt.pion:359`) | probes |
| P2-1 | P2 | `dk_len` ∈ [2³¹−16, 2³¹−1]: `Bytes::new` aborts the process (native SIGABRT, wasm `pion panic`) instead of `Err` | `pbkdf2.pion:95`, `:281` | probes |
| P2-2 | P2 | `scrypt_with_max_mem` with a ceiling ≥ 1 GiB: V ≥ 2²⁸ words **traps on wasm32** while native computes (native allows V up to 8 GiB) | `scrypt.pion:336-349` | probes |
| P2-3 | P2 | RFC 7914 §2 `N < 2^(128 r / 8)` not enforced: `r = 1, N ≥ 65536` derives a key Node.js/OpenSSL refuse to derive | `scrypt.pion:311` | tests, diff |

## Findings

### P1-1 — 2 GiB `dk_len` silently yields an all-zero key (fail-open)

`pbkdf2.pion:96` computes `let n_blocks = (dk_len + 31) / 32` in 32-bit `Int` (wraps on overflow; the
same at `:282` with `+ 63`). For `dk_len ≥ 2147483617` (SHA-256) or `≥ 2147483585` (SHA-512) the sum
wraps to a negative number, the block loop never runs and the freshly zeroed `Bytes::new(dk_len)`
(`:95`) is returned as `Ok`. The runtime allows `Bytes` up to `0x7FFFFFEF` bytes
(`PION_MAX_CONTAINER_LEN`), so the window is [2³¹−31, 2³¹−17] / [2³¹−63, 2³¹−17]. `scrypt`'s final
`pbkdf2_hmac_sha256(password, b, 1, dk_len)` (`scrypt.pion:359`) inherits it after doing the full ROMix.

Minimal reproduction (all four modes print the same):

```
oracle one P256 70617373 73616c74 1 2147483617   ->  OKBIG:len=2147483617:tail=0000…0000
oracle one P512 70617373 73616c74 1 2147483585   ->  OKBIG:len=2147483585:tail=0000…0000
oracle one SC   70617373 73616c74 2 1 1 2147483620 D  ->  OKBIG:len=2147483620:tail=0000…0000
```

(`dk_len = 2147483616`, one byte below the window, returns the correct 2 GiB output in 37 s: the
arithmetic is only wrong once the `+ 31` wraps.) A KDF must never return a constant key as success.
RFC 8018's `dkLen > (2³² − 1) · hLen` "derived key too long" bound can never trigger with a 32-bit
`Int`, so the effective bound is the implementation's. **Fix**: reject `dk_len` above an explicit
ceiling before allocating (e.g. `> 0x7FFFFFEF` or a documented 1 GiB, `Err(InvalidLength(dk_len))`)
and compute `n_blocks = dk_len / 32 + (if dk_len % 32 == 0 { 0 } else { 1 })` so it cannot wrap.
The `probes` gate accepts any `Err` or an `OKBIG` whose last 32 bytes equal Go's block-wise
`go_oracle tail` value.

Severity rationale: fail-open wrong output from a public KDF entry point with an RFC-legal parameter;
not P0 because no realistic caller (including `.mlogin.enc`, `dk_len = 32`) asks for a 2 GiB key.

### P2-1 — `dk_len` near `Int::MAX` aborts the process

For `dk_len ∈ [2147483632, 2147483647]`, `Bytes::new(dk_len)` (`pbkdf2.pion:95`, `:281`) hits the
runtime's container limit: native `pion panic … container length exceeds maximum` + SIGABRT (exit
134), wasm32 `pion panic` (exit 1). Same for `scrypt`. The package's error model
(`src/error.pion`: "no panics") and the README's documented `InvalidLength` contract call for an
`Err` here; the P1-1 fix (an upper bound checked before allocating) also fixes this.

### P2-2 — caller-raised `max_mem` traps on wasm32 (4-mode divergence)

`scrypt_with_max_mem` guards the V table only against the 32-bit index limit
(`v_words64 > 2147483647`, `scrypt.pion:336-340`), i.e. up to 8 GiB of `FixedArray[UInt]`
(`:349`). On wasm32 a `FixedArray[UInt]` of 2²⁸ elements (1 GiB) or more traps with
`RuntimeError: memory access out of bounds` (measured: 268,435,455 elements work, 268,435,456 trap;
a 2 GiB `Bytes` works), so with a ceiling the caller raised above ~1 GiB:

| probe (`max_mem = Int64::MAX`) | native_dbg / native_rel | wasm_dbg / wasm_rel |
| --- | --- | --- |
| N=2²², r=2 (V = 1 GiB) | `8b2e33fc…` (= Go) | trap |
| N=2²⁰, r=16 (V = 2 GiB) | `f819704b…` (= Go) | trap |
| N=2²⁴, r=2 (V = 4 GiB) | computes (4 GiB RSS) | trap |

The default `scrypt` (256 MiB) and the `.mlogin.enc` ceilings (64 / 256 MiB) are not affected.
**Fix**: a target-independent hard ceiling on the V table (`128 · r · N < 2³⁰`, i.e. `N · r < 2²³`,
→ `MemoryLimitExceeded`) regardless of `max_mem_bytes`, documented in the README. The gate accepts
`ERR:MemoryLimitExceeded` or Go's bytes, but requires all four modes to agree. The wasm32 allocation
trap itself is a toolchain issue (`pion_wasm_rt` / codegen for `FixedArray::make` ≥ 1 GiB) and is
reported separately to the Pion toolchain owners; the package should not depend on its fix.

### P2-3 — RFC 7914 §2 `N < 2^(16 r)` not enforced (Node.js interop)

RFC 7914 §2: N "must be larger than 1, a power of 2, and less than 2^(128 · r / 8)". OpenSSL (and so
Node.js `scryptSync`) refuses `N ≥ 2^(16 r)`; Go x/crypto does not check it. `scrypt.pion:311` checks
only `N > 1` and power of two, so `scrypt(pw, salt, 65536, 1, 1, 32)` returns `c2caa7d8…` where Node.js
throws `ERR_CRYPTO_INVALID_SCRYPT_PARAMS`. With `r ≥ 2` the bound exceeds `Int` (only `r = 1`,
`N ≥ 65536` is affected), and `.mlogin.enc` uses `r = 8`, so the impact is limited to a key a
Pion writer could produce that the Node.js side can never re-derive. **Fix**: `if r < 2 && n >= 65536
{ return Err(InvalidParam) }` (general form: `16 * r < 31 && n >= 1 << (16 * r)`).
Gated by `control_scrypt_n_below_2_pow_16r` and the `sc/nbound/` corpus rows (Node.js refuses both).

### Minimal fix used to prove the gates are self-consistent

Applied to a scratch copy only (this branch changes nothing outside `audit_v040/`); with it
`run_audit.sh` passes every gate unchanged and `pionc test packages/crypto` stays 82/82:

```diff
--- src/pbkdf2.pion   (both pbkdf2_hmac_sha256 and pbkdf2_hmac_sha512)
-  if dk_len <= 0 {
+  if dk_len <= 0 || dk_len > 1073741824 {
     return Err(CryptoError::InvalidLength(dk_len))
-  let n_blocks = (dk_len + 31) / 32                     // (+ 63) / 64 for SHA-512
+  let n_blocks = dk_len / 32 + (if dk_len % 32 == 0 { 0 } else { 1 })
--- src/scrypt.pion   (scrypt_with_max_mem)
   if r <= 0 || p <= 0 {
     return Err(CryptoError::InvalidParam)
   }
+  if r < 2 && n >= 65536 {   // RFC 7914 §2: N < 2^(128 r / 8)
+    return Err(CryptoError::InvalidParam)
+  }
-  if v_words64 > 2147483647L || b_len64 > 2147483647L {
+  if v_words64 >= 268435456L || b_len64 > 2147483647L {   // V < 1 GiB on every target
```

The `dk_len` cap is a suggestion (the probes accept any `Err`, or the correct 2 GiB output); the V
cap must keep the table below 2²⁸ words on wasm32 with the current toolchain (the probes accept
`MemoryLimitExceeded` or Go's bytes, identical in all four build modes).

## What was verified (no defect)

### Differential corpus (`diff` gate)

`go_oracle gen` writes 1,103 deterministic rows (ChaCha8 seed); `node/oracle.mjs` recomputes every
valid row with Node.js and checks the refused ones: **1,023 rows byte-identical Go = Node, 13 error
rows refused by Node too, 0 disagreements**. Pion then matches in all four modes with identical
stdout SHA-256. Families:

- **PBKDF2-HMAC-SHA256 / SHA-512 lengths** (288 rows each): password lengths 0, 1, 31, 32, 63, 64,
  65, 127, 128, 129, 200, 1000 × salt lengths 0, 1, 16, 51–53, 55, 56, 59–61, 64, 107–109, 111, 112,
  119, 120, 123–125, 128, 256, in three flavours (random, embedded NULs, non-ASCII UTF-8 with NUL),
  `c ∈ {1, 2, 3}`, `dkLen ∈ {20, 32, 64, 65}`. Note: the true `salt || INT(i)` padding boundaries
  after the 64/128-byte ipad block are salt = 52 / 60 (SHA-256) and 108 / 124 (SHA-512); the task's
  list (55, 56, 60, 111, 112, 119, 120, 124) was kept and these were added.
- **dkLen sweep** 1, 15, 16, 31–33, 63–65, 95, 96, 100, 128, 255, 256 × `c ∈ {1, 2, 1000}`; iteration
  counts 4, 17, 4096, 10000; Int-edge invalid parameters.
- **scrypt** `N ∈ {2, 4, 8, 16, 64, 1024, 16384, 32768} × r ∈ {1, 2, 4, 8, 16} × p ∈ {1, 2, 3, 4}`
  (160 rows), password/salt boundaries (144), dkLen sweep (15), exact `128 r (N + p + 2)` max_mem
  boundaries and one byte below for 9 parameter sets (Node.js `maxmem` agrees on every one), the
  64 MiB `.mlogin.enc` rule (N=32768 passes, 65536 / 131072 refused, as in Node), 37 hostile
  parameter rows (`N = 0, −1, 1, 3, 6, 15, 1023, 2³⁰, Int::MIN, Int::MAX`, `r, p = 0, −1, Int::MAX`,
  `r · p = 2³², 2³⁰`, `128 r (N + p + 2)` beyond 64 bits, `dk_len = 0, −1, Int::MIN`,
  `max_mem = 0, −1, Int64::MIN`): all clean `Err` of the documented kind, 0 panics, no allocation.
- **`.mlogin.enc` v1** (16 rows): `scrypt(N, 8, 1, 32)` for `N = 1024 … 131072` (64 MiB ceiling up
  to 32768, default above) + AES-256-GCM (12-byte IV, empty AAD), ciphertext ‖ tag identical to
  Node.js, and each envelope re-opens in Pion.

### Control tests (`tests` gate, `tests/redteam_v040_test.pion`)

9 tests: exact error kinds for every hostile PBKDF2/scrypt parameter (iterations checked before
`dk_len`), RFC 7914 §11 PBKDF2-SHA256 KATs (c = 1 and 80,000), HMAC key-fold property at 63–66 /
127–130 bytes (`PBKDF2(P) == PBKDF2(H(P))` iff `|P| >` block), `T_1 ‖ T_2` prefix property for
`dk_len` 1–256, exact max_mem boundaries, a Node.js-produced `.mlogin.enc` envelope from a UTF-8
passphrase with an embedded NUL (Pion derives the same key, opens it and re-seals identical bytes),
call-to-call independence of the ROMix scratch buffers, and the P2-3 rule. 8/9 pass on `8775804`
(`control_scrypt_n_below_2_pow_16r` fails), plus the package's own 82 tests.

### Code review

- `scrypt.pion`: Salsa20/8 quarter-round order and rotations (7, 9, 13, 18) match RFC 7914 §3;
  BlockMix reads `X = B[2r−1]` and writes even outputs to `Y[0..r)`, odd to `Y[r..2r)`; Integerify
  reads the first word of `B[2r−1]` (`block_words − 16`, and `2·block_words − 16` for the ping-pong
  half) masked with `N − 1`; the ping-pong ROMix needs `N` even, which the power-of-two check
  guarantees. Every index is bounded by `v_words64 ≤ 2³¹ − 1`, `b_len64 ≤ 2³¹ − 1` and
  `r · p < 2³⁰`, checked in `Int64` before any `Int` arithmetic (`r << 6`, `r << 7`, `i * block_words`)
  can overflow. One allocation each for `B`, `XY`, `V` per call; no allocation in any loop.
- `pbkdf2.pion`: HMAC pads computed once; the U-loop runs on fixed word arrays with no allocation;
  the `salt || INT(i)` length field uses the true total (`64/128 + |salt| + 4`); INT(i) big-endian;
  output truncation per block correct. Only P1-1/P2-1 above.
- `scrypt_with_max_mem` memory rule `128 · r · (N + p + 2)` equals OpenSSL's `Blen + Vlen`
  (`p · 128 r + 32 r (N + 2) · 4`): identical accept/refuse decisions on every boundary row.

### Constant time (`ct` gate)

`audit/ct_ssa_check.py` and `audit_v030/ct_ssa_check_v030.py` (unchanged): **PASS**, no regression.
New `ct_ssa_check_v040.py` on the release QBE SSA: `salsa20_8_xor`, `blockmix_salsa8`, `scrypt_romix`,
`sha256_compress_w`, `sha512_compress_w` branch-free and table-free; the PBKDF2 / scrypt entry points
branch only on public lengths and parameters. INFO: ROMix's `V[Integerify(X) mod N]` is a
password-dependent memory access by design (RFC 7914 scrypt is not cache-timing constant time, same as
Go, OpenSSL and libsodium); acceptable for `.mlogin.enc`'s offline-file threat model.

### Mutation sensitivity (`mutants` gate)

17/17 killed: Salsa20/6; one wrong rotation; Integerify on B[0] (X and Y halves); BlockMix without
even/odd split (killed only by r > 1 rows); BlockMix X = B[0]; `j mod N/2`; all p lanes on block 0;
memory rule ignoring p (killed only by the max_mem boundary rows); HMAC-SHA256 folding a 64-byte key
and HMAC-SHA512 a 128-byte key (killed only by the 64 / 128-byte passwords); little-endian INT(i);
c − 1 iterations; wrong SHA-256 length field; SHA-256 `rem > 56` / SHA-512 `rem > 112` padding
off-by-one (killed only by salt = 52 / 108); SHA-512 block truncated to 63 bytes.

### Benchmarks (`bench` gate)

BENCH 13/14 reproduced with `bench_compare.py --warmup 1 --rounds 5`; stdout SHA-256 identical
(Pion = Go x/crypto); Go fixed process cost 2.9 ms = 6 % / 4 % of the rows, so they are steady state.
Scaled in-process re-measurement (4,000,000 PBKDF2 iterations; 32 scrypt calls):

| row | Pion | Go x/crypto | repo ratio | in-process ratio | peak RSS Pion / Go |
| --- | ---: | ---: | ---: | ---: | ---: |
| PBKDF2-HMAC-SHA256, 500,000 iter | 249.6 ms (≈ 0.50 µs/iter) | 51.7 ms (≈ 0.09 µs/iter) | 0.21× | 0.18× | 1.8 / 5.0 MiB |
| scrypt N=16384 r=8 p=1 × 4 | 128.6 ms (32.6 ms/op) | 81.1 ms (19.6 ms/op) | 0.63× | 0.60× | 33.8 / 38.5 MiB |

The README's 0.20× / 0.62× claims are honest (within 1.2× of the start-up-free ratio). Go's PBKDF2
uses the ARMv8 `SHA256H` instructions; Pion is portable scalar code.

## Fair assessment

The v0.4.0 KDFs are a careful, faithful implementation: byte-exact against two independent reference
implementations on every boundary the RFCs and the task named, consistent on native and wasm32,
allocation-free in the hot loops, overflow-checked in `Int64` before allocation, and honestly
benchmarked. The four findings are confined to parameter extremes: P1-1/P2-1 need a 2 GiB output
request, P2-2 a caller-raised memory ceiling of ≥ 1 GiB on wasm32, P2-3 `r = 1` with `N ≥ 65536`.
Fixing them is a handful of guard lines in `scrypt_with_max_mem` and the two PBKDF2 entry points;
`audit_v040/` then reruns unchanged to `exit 0`.
