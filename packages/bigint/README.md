# `bigint` — Pure Pion Arbitrary-Precision Signed Integers

Zero-dependency, 100% pure-Pion arbitrary-precision signed integer package (`BigInt` + reusable `BigIntBuf`), with zero `extern "C"`, zero `World` dependencies, and byte-for-byte identical execution across **Native** and **WebAssembly (`wasm32`)** targets.

## Representation & Canonical Invariants

- **`pub val struct BigInt`** (`#derive(Eq)`, immutable, `Send`):
  - Sign-magnitude representation in base $B = 2^{32}$ backed by `ImmArray[UInt]` (4-byte compact limb slots, `Send`, O(1) RC copy).
  - **Canonical zero**: `0` is always uniquely represented as `neg = false, limbs.length() == 0` — never `-0` across `sub`, `neg`, `mul`, `div`, `rem`, shifts, or parsing (`"-0"`, `"-0x0"`).
  - **No trailing zero limbs**: `limbs.length() == 0 || limbs[limbs.length() - 1] != 0U`.
  - **Aliasing-safe**: All operations (`a.add(a)`, `a.sub(a)`, `a.mul(a)`, `a.div_rem(a)`) are safe by construction.
- **`pub struct BigIntBuf`** (`!Send`, mutable):
  - Reusable growable limb buffer (`FixedArray[UInt]`) for zero-allocation hot loops (e.g., spigot algorithms and iterative accumulation), snapshotting to immutable `BigInt` via `to_bigint()`.

## Frozen API & Semantics

### Construction & Conversion
- `BigInt::zero() -> BigInt`, `BigInt::one() -> BigInt`
- `BigInt::from_int(v : Int) -> BigInt`, `BigInt::from_int64(v : Int64) -> BigInt`, `BigInt::from_uint64(v : UInt64) -> BigInt`
- `BigInt::from_string(s : String) -> Result[BigInt, BigIntError]` — strict base-10 with optional leading `+`/`-`.
- `BigInt::from_radix(s : String, radix : Int) -> Result[BigInt, BigIntError]` — strict radix `2..=36` with optional leading `+`/`-`.
- `BigInt::from_hex(s : String) -> Result[BigInt, BigIntError]` — strict base-16 with optional leading `+`/`-` and optional `0x`/`0X` prefix.
  - Strict parsing rejects empty strings, bare signs (`"+"`, `"-"`), bare prefixes (`"0x"`, `"-0x"`), whitespace, underscores, and out-of-radix characters with `Err(...)` (never panics).
- `to_string(self) -> String` — base-10 formatting via $10^9$ chunked division.
- `to_radix(self, radix : Int) -> Result[String, BigIntError]` — lowercase `0-9a-z` for radix `2..=36` (bit-shift fast paths for radices 2/4/8/16/32; chunked division for general radices).
- `to_int(self) -> Option[Int]`, `to_int64(self) -> Option[Int64]`, `to_uint64(self) -> Option[UInt64]` — returns `None` on overflow; `INT32_MIN` (`-2147483648`) and `INT64_MIN` (`-9223372036854775808L`) roundtrip losslessly.

### Arithmetic, Comparison & Single-Limb Fast Paths
- `is_zero`, `is_neg`, `is_pos`, `signum` (`-1 | 0 | 1`), `bit_len` (`0` for `0`), `abs`, `neg`, `cmp`, `eq` (`==`/`!=`), `lt`, `le`, `gt`, `ge`.
- `add`, `sub`, `mul`, `div`, `rem`, `div_rem`:
  - **Truncating division toward zero**: `-7 / 3 == -2`, `-7 % 3 == -1`, `7 / -3 == -2`, `7 % -3 == 1`. Remainder sign matches dividend (or `0`), and `a == q * b + r` with `|r| < |b|`. Division by zero panics (matching `Int`).
  - **Knuth Algorithm D** ($B = 2^{32}$): handles normalization shifts $s \in [0, 31]$, guards `rhat < B` before forming `B * rhat + u_next` to prevent `UInt64` overflow, and implements full Step D6 add-back. `BigInt::div` includes a zero-allocation single-limb quotient fast path.
- Single-limb fast paths:
  - `add_int(Int)`, `mul_int(Int)`, `mul_uint(UInt)`, `add_mul_int(BigInt, Int)` (fused single-pass `self + other * k`), `div_rem_uint(UInt) -> (BigInt, UInt)` (returns `(sign(self) * (|self| / d), |self| % d)`).
- Reusable buffer (`BigIntBuf`):
  - `BigIntBuf::new`, `from_int`, `from_bigint`, `to_bigint`, `set_zero`, `set_int`, `copy_from`, `mul_uint_in_place`, `add_mul_uint_in_place`, `sub_mul_uint_in_place`, `add_in_place`, `sub_in_place`, `div_small_uint`, `cmp`.

### Shifts, Bitwise & Number Theory
- `shl(Int) -> BigInt`, `shr(Int) -> BigInt` (panics on negative shift count), plus `checked_shl(Int) -> Result[BigInt, BigIntError]`, `checked_shr(Int) -> Result[BigInt, BigIntError]`.
  - Arithmetic right shift `shr` floors toward $-\infty$ for negative values (matching Python `>>` and Go `Int.Rsh`: `(-1) >> 1 == -1`, `(-5) >> 1 == -3`).
- `bit_and`, `bit_or`, `bit_xor`, `bit_not` — infinite two's-complement semantics for negative numbers (matching Python `&`, `|`, `^`, `~` and Go `math/big`).
- `pow(Int) -> Result[BigInt, BigIntError]` (`exp < 0` returns `Err(NegativeExponent)`; `0^0 == 1`).
- `gcd(BigInt) -> BigInt` (always non-negative; `gcd(0, 0) == 0`; 64-bit Euclidean fast path).

## Verification

- **Red → Green Unit Suite (`bigint_test.pion`)**: 7 / 7 test groups pass, covering Go `math/big` & MoonBit `core/bigint` vectors, `INT32_MIN`/`INT64_MIN`/`UINT64_MAX` roundtrips, strict parsing rejections, aliasing safety, `Send` via `Channel[BigInt]`, single-limb fast paths, `BigIntBuf`, and Hacker's Delight `divmnu` / Knuth Algorithm D adversarial vectors ($s = 0$, $s = 31$, `qhat` overestimated by 2, and Step D6 add-back).
- **Python Differential Fuzzing (`bench/diff_fuzz.py`)**: **631 cases (7,572+ operations)** across 0..1024-bit signed operands verified against Python arbitrary-precision `int` with **0 mismatches** on both **Native** and **Wasm32**.
- **4-Mode `wasm_smoke`**: Native debug, Native release, Wasm32 debug (Node + `pion_wasm_rt.mjs`), and Wasm32 release produce byte-identical stdout (`sha256: 7c3ed3008acc0870b5b53716fe4520f9258e4ec4f47c4d71e3a5ba519fe915ca`).

## Head-to-Head Benchmarks

Measured on `Linux x86_64` with `pionc 0.1.0 (amd64_sysv, abi pionc-v0.22, self-hosted)` (`--release`), `go1.24.4`, and `moon 0.1.20261119` (`--target native --release`) via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification).

### Bench 1: `pidigits` (`N = 2500`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Speedup (vs `go_big`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion_imm` (immutable `BigInt`) | 259.899 | 218.039 | 347.633 | 103959.47 | **1.37x** |
| `pion_buf` (`BigIntBuf`) | 286.732 | 208.346 | 310.620 | 114692.68 | **1.24x** |
| `go_big` (`math/big`) | 354.967 | 328.373 | 404.019 | 141986.94 | 1.00x (baseline) |
| `moonbit` (`core/bigint`) | 201.231 | 150.660 | 252.427 | 80492.19 | 1.76x |

- Verified common stdout SHA-256 (`4,142 B`): `32d5af36b0c5eb370536b97699a5f9d67e4c49d937bf45f02caee5cbaa7b3c19`

### Bench 2: Multi-Limb Multiply + Knuth `div_rem` (2,000 rounds, 512×384-bit)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Speedup (vs `go_big`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` (`BigInt`) | 12.657 | 12.300 | 15.167 | 6328.34 | 0.77x |
| `go_big` (`math/big`) | 9.790 | 8.153 | 11.238 | 4895.26 | 1.00x (baseline) |
| `moonbit` (`core/bigint`) | 9.950 | 8.054 | 11.244 | 4974.85 | 0.98x |

- Verified common stdout SHA-256 (`159 B`): `e2c4f488962288ba67041c075c1befc355efe0e27f24b879722b5cdb2dac9b7d`
