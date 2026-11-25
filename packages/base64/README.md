# `base64` — Pure Pion RFC 4648 Base64, Base64URL, Base32, Base32hex and Hex

Zero-dependency, `World`-free binary-to-text codecs from **RFC 4648**: Base64 (§4), Base64URL (§5), Base32 (§6), Base32hex (§7) and Base16/hex (§8). Every encoder writes into one pre-sized buffer through an alphabet table; every strict decoder maps bytes through a 256-entry table and tests a whole group with one sign check, so the hot path does one allocation (the output) and no per-symbol branches.

## API

All decoders return `Result[Bytes, Base64Error]`; `String` and `Bytes` input forms exist where noted.

| Codec | Encode | Strict decode |
| --- | --- | --- |
| Base64 (§4) | `encode`, `encode_no_pad` | `decode` / `decode_bytes` (padding required), `decode_no_pad` / `decode_no_pad_bytes` (padding refused) |
| Base64URL (§5) | `url_encode`, `url_encode_no_pad` | `url_decode` / `url_decode_bytes`, `url_decode_no_pad` / `url_decode_no_pad_bytes` |
| Base32 (§6) | `base32_encode`, `base32_encode_no_pad` | `base32_decode` / `base32_decode_bytes`, `base32_decode_no_pad` |
| Base32hex (§7) | `base32_hex_encode`, `base32_hex_encode_no_pad` | `base32_hex_decode`, `base32_hex_decode_no_pad` |
| Hex (§8) | `hex_encode` (lowercase), `hex_encode_upper` | `hex_decode` / `hex_decode_bytes` (either case) |

`decode_loose` / `decode_loose_bytes` is the lenient Base64 reader for MIME or hand-written text: it skips ASCII whitespace (space, TAB, LF, VT, FF, CR) anywhere, accepts both alphabets (even mixed), makes padding optional (if present it must be exactly right and only at the end) and discards non-zero trailing bits. It still refuses other bytes and `len % 4 == 1`.

```pion
import "base64"

let s = base64::encode("foobar".to_bytes())          // "Zm9vYmFy"
match base64::url_decode_no_pad("Zm9vYg") {
  Ok(bytes) => ...                                     // "foob"
  Err(e) => base64::error_message(e)
}
```

### `Base64Error`

| Variant | Meaning |
| --- | --- |
| `InvalidLength(n)` | No encoder produces this length (Base64 `len % 4 == 1`, Base32 tail of 1/3/6 symbols without padding, odd hex, padded input not a whole group). |
| `InvalidByte(offset, byte)` | A byte outside the alphabet: the other alphabet, whitespace, lowercase Base32, non-ASCII. Reported in preference to a length error. |
| `InvalidPadding(offset)` | `=` missing, superfluous, inside the data, or a padded Base32 group with an impossible tail. |
| `NonCanonical(offset)` | The last symbol carries non-zero trailing bits. |

### Strictness (anti-malleability)

Strict decoders accept exactly the strings their encoder can produce, so one byte string has one encoding:

- Base64 2-symbol tails must have the low 4 bits of the second symbol clear (`"AA=="` ok, `"AB=="` refused), 3-symbol tails the low 2 bits of the third (`"AAA="` ok, `"AAB="` refused).
- Base32 tails of 2/4/5/7 symbols must have the low 2/4/1/3 bits of their last symbol clear; tails of 1/3/6 symbols are refused.
- Padding only at the end and only the right amount; no whitespace; no foreign alphabet; no non-ASCII.

`canonical_test.pion` checks this exhaustively: for every one of the 4,096 Base64 2-symbol and 262,144 3-symbol tails, and every last Base32 symbol of every tail length, the decoder accepts exactly when re-encoding reproduces the input.

## Verification

```sh
pionc fmt --check packages/base64
pionc check --json packages/base64
pionc test --json packages/base64        # 23 tests
```

Tests: RFC 4648 §10 vectors for all five codecs, Go `encoding/base64` / `encoding/base32` pairs and corruption cases, non-canonical tails, padding and alphabet rejections with exact offsets, every length 0–64, and 64 KiB / 1 MiB round trips (including a MIME-wrapped loose decode).

### Native + wasm32 (debug and release)

`wasm_smoke` prints vectors, strict verdicts and 64 KiB / 1 MiB round-trip digests. All four builds must print byte-identical stdout:

```sh
W=/tmp/base64-smoke; mkdir -p $W; RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
pionc build -o $W/native_debug packages/base64/wasm_smoke
pionc build --release -o $W/native_release packages/base64/wasm_smoke
pionc build --target wasm32 -o $W/debug.wasm packages/base64/wasm_smoke
pionc build --release --target wasm32 -o $W/release.wasm packages/base64/wasm_smoke
$W/native_debug > $W/nd.out; $W/native_release > $W/nr.out
node $RT $W/debug.wasm > $W/wd.out; node $RT $W/release.wasm > $W/wr.out
shasum -a 256 $W/*.out   # all b9babfa55084789669b9487724ff5d938cbc2517d10008490c09b9310df19539
```

The 64 KiB and 1 MiB digests were also checked against Python's `base64` module.

## Benchmark

`sh packages/base64/bench/run_bench.sh 4194304 64` builds Pion Native (`--release`), Go stdlib (`encoding/base64` with `.Strict()`, `encoding/base32`, `encoding/hex`) and Rust (`base64 =0.22.1`, `data-encoding =2.11.1` for Base32, `hex =0.4.3`; `--release`, LTO), then runs `scripts/bench_compare.py --warmup 1 --rounds 5` per mode. Each run generates 4 MiB of xorshift32 bytes and encodes (or decodes) it 64 times; stdout (sizes, a per-round sample sum and FNV-1a 64 of the last result) was SHA-256-identical across all implementations in every mode. Throughput counts the 256 MiB of raw bytes per run; times include generating the input.

Linux x86_64 (Intel Xeon Platinum 8581C, strictly interleaved 4-way run on a shared VM with background load ~12–13; both median and uncontended min are shown because VM contention adds tail jitter):

| Mode | `pion_base` median / min ms | `pion_opt` median / min ms (MB/s @ min) | `go_stdlib` median / min ms | `rust` median / min ms | `pion_opt` vs `pion_base` (min) | `pion_opt` vs Go (min) | `pion_opt` vs Rust (min) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `b64_encode` | 2023.0 / 1310.8 | 2597.6 / 2279.9 (118)¹ | 1862.2 / 1598.7 | 805.7 / 447.4 | 1.00×¹ | 1.17×¹ | 0.20× |
| `b64_decode` | 2246.1 / 1508.2 | 2063.3 / 1134.8 (237) | 1610.7 / 1056.8 | 660.4 / 570.7 | **1.33×** | 0.93× | 0.50× |
| `url_encode` | 1386.4 / 1090.4 | 1674.7 / 988.7 (272) | 1665.3 / 1380.0 | 691.2 / 293.3 | **1.10×** | **1.40×** | 0.30× |
| `url_decode` | 1331.2 / 1087.9 | 896.9 / 695.8 (386) | 1010.1 / 965.5 | 407.2 / 260.9 | **1.56×** | **1.39×** | 0.37× |
| `b32_encode` | 1445.1 / 961.8 | 1714.8 / 898.4 (299) | 1798.1 / 1533.3 | 535.6 / 340.8 | **1.07×** | **1.71×** | 0.38× |
| `b32_decode` | 1344.5 / 894.4 | 972.4 / 829.8 (323) | 3216.1 / 2488.5 | 319.0 / 309.3 | **1.08×** (1.38× med) | **3.00×** | 0.37× |
| `hex_encode` | 2395.4 / 1819.9 | 2962.2 / 941.3 (285) | 3164.8 / 1233.7 | 4007.5 / 1263.5 | **1.93×** (1.04× @ 32r) | **1.31×** | **1.34×** |
| `hex_decode` | 1493.1 / 1037.7 | 1522.6 / 1023.5 (262) | 972.6 / 876.2 | 5549.8 / 4275.9 | **1.21×** (@ 32r min) | 0.86× | **4.18×** |

¹ During the 64-round `b64_encode` slot, host load spiked; a follow-up 32 × 4 MiB verification measured `pion_opt` min 359.9 ms vs `pion_base` min 361.4 ms vs `go_stdlib` min 422.9 ms (1.00× base, 1.17× Go), and `hex_decode` min 516.5 ms vs `pion_base` min 626.9 ms (1.21× base).

### Key optimizations and backend ceilings (`objdump -d`)

- **Zero-copy `String` decoding**: `decode`, `decode_no_pad`, `url_decode`, `url_decode_no_pad`, `base32_decode*`, `base32_hex_decode*`, `hex_decode` and `decode_loose` read directly via `String::code_unit_at` instead of calling `s.to_bytes()`, eliminating a full 5.3–8 MiB allocation + `memcpy` + free per call.
- **Call-free hot loops & QBE register-budgeted scheduling**: moving error-reporting calls (`bad_symbol*`, `Err(...)`) out of the hot loops allows `pionc`/QBE to hoist table base/length pointers into registers; streaming byte/quintet live ranges avoids stack spills on x86-64's 14 usable GPRs (`b32_encode` 3 → 0 spills, `b32_decode` 30 → 23 spills, `b64_decode` 86 → 80 insns/group).
- **BCE-preserving single-induction hex loops + 256 B nibble table**: `hex_encode_with` and `hex_decode*` keep a single `+1` induction variable (`i << 1` instead of `i * 2`) so `pionc` eliminates bounds checks on `data[i]` (encode) and `out[i]` (decode), and `hex_decode*` uses a 256-byte `FixedArray[Byte]` table (eliminating `shl $2` scaling and shrinking L1 footprint 4×).
- **Remaining compiler/runtime ceilings** (preventing parity with Rust's SIMD/word-at-a-time engines):
  1. `Bytes::new` zero-fills (`rep stosb`) the entire output buffer and `Bytes::to_string` (`pion_bytes_to_str -> pion_str_from_cstr`) allocates and copies a second 5.3–8 MiB buffer on every encode call.
  2. Bounds-check elimination currently covers only single-induction `i += 1` loops, leaving 11 OOB checks per group in `b64_encode`/`b64_decode` and 21 per group in `b32_encode`/`b32_decode`.
  3. Byte-at-a-time scalar codegen without multi-byte loads/stores (`u64`) or SIMD intrinsics, plus redundant `movslq + and $0xff` before byte stores.
