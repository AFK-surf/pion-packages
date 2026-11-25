# `bigint` — Pure Pion Arbitrary-Precision Signed Integers

Zero-dependency, 100% pure-Pion arbitrary-precision signed integer package (`BigInt` + encapsulated reusable `BigIntBuf`), with zero `extern "C"`, zero `World` dependencies, and byte-for-byte identical execution across **Native** and **WebAssembly (`wasm32`)** targets.

## Representation & Canonical Invariants

- **`pub val struct BigInt`** (`#derive(Eq)`, immutable, `Send`):
  - Sign-magnitude representation in base $B = 2^{32}$ backed by `ImmArray[UInt]` (4-byte compact limb slots, `Send`, zero-copy sharing).
  - **Canonical zero**: `0` is always uniquely represented as `neg = false, limbs.length() == 0` — never `-0` across `sub`, `neg`, `mul`, `div`, `rem`, shifts, or parsing (`"-0"`, `"-0x0"`).
  - **No trailing zero limbs**: `limbs.length() == 0 || limbs[limbs.length() - 1] != 0U`.
  - **Aliasing-safe**: All operations (`a.add(a)`, `a.sub(a)`, `a.mul(a)`, `a.div_rem(a)`) are safe by construction.
- **`pub struct BigIntBuf`** (`!Send`, mutable, `priv mut` fields):
  - Encapsulated reusable growable limb buffer (`FixedArray[UInt]`) for zero-allocation hot loops (e.g., spigot algorithms and iterative accumulation), snapshotting to immutable `BigInt` via `to_bigint()` without exposing internal mutable state.

## Frozen API & Semantics

### Construction & Conversion
- `BigInt::zero() -> BigInt`, `BigInt::one() -> BigInt`
- `BigInt::from_int(v : Int) -> BigInt`, `BigInt::from_int64(v : Int64) -> BigInt`, `BigInt::from_uint64(v : UInt64) -> BigInt`
- `BigInt::from_string(s : String) -> Result[BigInt, BigIntError]` — strict base-10 with optional leading `+`/`-`.
- `BigInt::from_radix(s : String, radix : Int) -> Result[BigInt, BigIntError]` — strict radix `2..=36` with optional leading `+`/`-`.
- `BigInt::from_hex(s : String) -> Result[BigInt, BigIntError]` — strict base-16 with optional leading `+`/`-` and optional `0x`/`0X` prefix.
  - Strict parsing rejects empty strings, bare signs (`"+"`, `"-"`), bare prefixes (`"0x"`, `"-0x"`), whitespace, underscores, and out-of-radix characters with `Err(...)` (never panics).
- `to_string(self) -> String` — base-10 formatting via $10^9$ chunked division.
- `to_radix(self, radix : Int) -> Result[String, BigIntError]` — lowercase `0-9a-z` for radix `2..=36` (bit-shift fast paths for radices 2/4/8/16/32 with 64-bit length overflow guard returning `Err(BigIntError::OutputTooLarge)` if output including sign exceeds Pion's `Bytes` container limit `2,147,483,631`; chunked division for general radices).
- `to_int(self) -> Option[Int]`, `to_int64(self) -> Option[Int64]`, `to_uint64(self) -> Option[UInt64]` — returns `None` on overflow; `INT32_MIN` (`-2147483648`) and `INT64_MIN` (`-9223372036854775808L`) roundtrip losslessly.

### Arithmetic, Comparison & Single-Limb Fast Paths
- `is_zero`, `is_neg`, `is_pos`, `signum` (`-1 | 0 | 1`), `bit_len() -> Int64` (`0L` for `0`), `abs`, `neg`, `cmp`, `eq` (`==`/`!=`), `lt`, `le`, `gt`, `ge`.
- `add`, `sub`, `mul`, `div`, `rem`, `div_rem`:
  - **Truncating division toward zero**: `-7 / 3 == -2`, `-7 % 3 == -1`, `7 / -3 == -2`, `7 % -3 == 1`. Remainder sign matches dividend (or `0`), and `a == q * b + r` with `|r| < |b|`. Division by zero panics (matching `Int`).
  - **Knuth Algorithm D** ($B = 2^{32}$): handles normalization shifts $s \in [0, 31]$, guards `rhat < B` before forming `B * rhat + u_next` to prevent `UInt64` overflow, and implements full Step D6 add-back. `BigInt::div` includes a zero-allocation single-limb quotient fast path with an O(1) `rem_est >= q` exact short-circuit.
- Single-limb fast paths:
  - `add_int(Int)`, `mul_int(Int)`, `mul_uint(UInt)`, `add_mul_int(BigInt, Int)` (fused single-pass `self + other * k`), `div_rem_uint(UInt) -> (BigInt, UInt)` (returns `(sign(self) * (|self| / d), |self| % d)`).
- Reusable buffer (`BigIntBuf`):
  - `BigIntBuf::new`, `from_int`, `from_bigint`, `to_bigint`, `set_zero`, `set_int`, `copy_from`, `mul_uint_in_place`, `add_mul_uint_in_place`, `sub_mul_uint_in_place`, `add_in_place`, `sub_in_place`, `div_small_uint(denom) -> Option[UInt]` (returns `Some(q)` iff exact `floor(|self| / |denom|) <= 0xFFFFFFFFU`, `None` on overflow, panics on `denom == 0`, with O(1) `rem_est >= q` short-circuit), `cmp`.

### Shifts, Bitwise & Number Theory
- `shl(Int) -> BigInt`, `shr(Int) -> BigInt` (panics on negative shift count), plus `checked_shl(Int) -> Result[BigInt, BigIntError]`, `checked_shr(Int) -> Result[BigInt, BigIntError]`.
  - Arithmetic right shift `shr` floors toward $-\infty$ for negative values (matching Python `>>` and Go `Int.Rsh`: `(-1) >> 1 == -1`, `(-5) >> 1 == -3`).
- `bit_and`, `bit_or`, `bit_xor`, `bit_not` — infinite two's-complement semantics for negative numbers (matching Python `&`, `|`, `^`, `~` and Go `math/big`).
- `pow(Int) -> Result[BigInt, BigIntError]` (`exp < 0` returns `Err(NegativeExponent)`; `0^0 == 1`).
- `gcd(BigInt) -> BigInt` (always non-negative; `gcd(0, 0) == 0`; 64-bit Euclidean fast path).

## Verification

- **Red → Green Unit Suite (`bigint_test.pion`)**: 11 / 11 test groups pass, covering Go `math/big/int_test.go` (`sumZZ`, `prodZZ`, `divisionSignsTests`, `quoTests`, `lshTests`/`rshTests`, `bitwiseTests`, `stringTests`), MoonBit `core/bigint` vectors, `INT32_MIN`/`INT64_MIN`/`UINT64_MAX` roundtrips, strict parsing rejections, aliasing safety, `Send` via `Channel[BigInt]`, `BigIntBuf` snapshot immutability & `div_small_uint` `Option[UInt]` boundaries, 64-bit `bit_len_from_top`/`pow2_format_len` overflow guards, and Knuth Algorithm D adversarial vectors including the true Step D6 add-back vector ($v = 2^{95} + 1, u = 2^{96} + 1$, verified via D6-disabled counterproof).
- **Cross-Package Encapsulation**: Verified with `pionc check` that external packages cannot access `BigIntBuf`'s `priv mut` fields (`neg`/`limbs`/`len`) or construct it via struct literal (`E_PRIVATE_FIELD`).
- **Python Differential Fuzzing (`bench/diff_fuzz.py`)**: **10,236 cases, 0 mismatches** per target (Native and Wasm32) with boundary-limb-biased generation across `div`/`rem`/`div_rem`, `pow`, `from_radix`/`to_radix` (2..36), `from_hex`, `to_int*`/`bit_len`/`signum`, shifts, bitwise ops, `gcd`, single-limb ops, and all `BigIntBuf` methods (including `div_small_uint` valid + overflow `None` cases).
- **4-Mode `wasm_smoke`**: Native debug, Native release, Wasm32 debug (Node + `pion_wasm_rt.mjs`), and Wasm32 release produce byte-identical stdout (`sha256: 4f863ceb52f2bab3eb3aa87538a3b423c62991db84c2fab97f30e5c5fcc68498`).

## Head-to-Head Benchmarks

Measured on `Linux x86_64` (shared build host) with `pionc 0.1.0 (amd64_sysv, abi pionc-v0.22, self-hosted)` (`--release`), `go1.24.4`, and `moon 0.1.20261119` (`--target native --release`) via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification).

### Bench 1: `pidigits` (`N = 2500`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Speedup (vs `go_big`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion_buf` (`BigIntBuf`) | 410.386 | 365.872 | 905.533 | 164154.22 | **2.58x** |
| `pion_imm` (immutable `BigInt`) | 479.667 | 391.374 | 731.743 | 191866.76 | **2.21x** |
| `moonbit` (`core/bigint`) | 511.851 | 227.424 | 553.491 | 204740.29 | 2.07x |
| `go_big` (`math/big`) | 1058.243 | 631.957 | 1536.305 | 423297.29 | 1.00x (baseline) |

- Verified common stdout SHA-256 (`4,142 B`): `32d5af36b0c5eb370536b97699a5f9d67e4c49d937bf45f02caee5cbaa7b3c19`
- Note: Measured under shared-host CPU load (causing higher variance in absolute ms); both `pion_buf` and `pion_imm` consistently outperform `go_big`, while `pion_buf`, `pion_imm`, and `moonbit` perform in the same range (`moonbit` achieved the lowest single-run min at `227.4 ms`).

### Bench 2: Multi-Limb Multiply + Knuth `div_rem` (2,000 rounds, 512×384-bit)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Speedup (vs `go_big`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` (`BigInt`) | 40.453 | 21.625 | 63.483 | 20226.26 | 0.59x |
| `go_big` (`math/big`) | 23.911 | 18.596 | 81.969 | 11955.37 | 1.00x (baseline) |
| `moonbit` (`core/bigint`) | 23.984 | 13.758 | 71.886 | 11992.11 | 1.00x |

- Verified common stdout SHA-256 (`159 B`): `e2c4f488962288ba67041c075c1befc355efe0e27f24b879722b5cdb2dac9b7d`
