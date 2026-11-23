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

`bench/wasm_smoke` prints vectors, strict verdicts and 64 KiB / 1 MiB round-trip digests. All four builds must print byte-identical stdout:

```sh
W=/tmp/base64-smoke; mkdir -p $W; RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
pionc build -o $W/native_debug packages/base64/bench/wasm_smoke
pionc build --release -o $W/native_release packages/base64/bench/wasm_smoke
pionc build --target wasm32 -o $W/debug.wasm packages/base64/bench/wasm_smoke
pionc build --release --target wasm32 -o $W/release.wasm packages/base64/bench/wasm_smoke
$W/native_debug > $W/nd.out; $W/native_release > $W/nr.out
node $RT $W/debug.wasm > $W/wd.out; node $RT $W/release.wasm > $W/wr.out
shasum -a 256 $W/*.out   # all b9babfa55084789669b9487724ff5d938cbc2517d10008490c09b9310df19539
```

The 64 KiB and 1 MiB digests were also checked against Python's `base64` module.

## Benchmark

`sh packages/base64/bench/run_bench.sh 4194304 64` builds Pion Native (`--release`), Go 1.27.3 stdlib (`encoding/base64` with `.Strict()`, `encoding/base32`, `encoding/hex`) and Rust (`base64 =0.22.1`, `data-encoding =2.11.1` for Base32, `hex =0.4.3`; `--release`, LTO), then runs `scripts/bench_compare.py --warmup 1 --rounds 5` per mode. Each run generates 4 MiB of xorshift32 bytes and encodes (or decodes) it 64 times; stdout (sizes, a per-round sample sum and FNV-1a 64 of the last result) was SHA-256-identical across all three in every mode. Throughput counts the 256 MiB of raw bytes per run; times include generating the input (about 20 ms per process for every implementation).

Darwin arm64 (Apple M5 Max), on a shared machine with background load (load average 16–18), so treat small gaps with care:

| Mode | pion median ms (MB/s) | go_stdlib median ms (MB/s) | rust median ms (MB/s) | pion vs rust | pion vs go | Peak RSS pion / go / rust (MiB) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `b64_encode` | 239.2 (1122) | 122.6 (2189) | 100.7 (2667) | 0.42x | 0.51x | 16.4 / 31.7 / 11.1 |
| `b64_decode` | 228.9 (1173) | 110.5 (2429) | 99.0 (2711) | 0.43x | 0.48x | 20.5 / 32.5 / 15.1 |
| `url_encode` | 228.6 (1175) | 122.4 (2193) | 99.3 (2703) | 0.43x | 0.54x | 16.5 / 26.8 / 11.1 |
| `url_decode` | 226.5 (1185) | 106.7 (2515) | 94.6 (2838) | 0.42x | 0.47x | 20.5 / 30.4 / 15.1 |
| `b32_encode` | 253.3 (1060) | 118.6 (2263) | 113.2 (2371) | 0.45x | 0.47x | 18.6 / 29.9 / 12.2 |
| `b32_decode` | 253.1 (1060) | 642.3 (418) | 110.9 (2421) | 0.44x | 2.54x | 22.6 / 49.1 / 16.2 |
| `hex_encode` | 300.7 (893) | 209.7 (1280) | 511.6 (525) | 1.70x | 0.70x | 21.8 / 66.3 / 13.8 |
| `hex_decode` | 315.7 (850) | 185.1 (1450) | 1449.4 (185) | 4.59x | 0.59x | 25.8 / 31.4 / 20.0 |

- Base64 / Base64URL / Base32 encode and decode: Pion runs at about 1.1 GB/s, **0.42–0.54x** Rust `base64` and Go. Both reference implementations decode several symbols per machine word; this package reads one byte at a time through bounds-checked `Bytes` indexing, which is what the current backend allows (a 4,096-entry two-symbol table and unrolled index variants measured no gain).
- Base32 decode: Pion is **2.5x faster than Go** (Go's decoder handles padding and newlines per group) and 0.44x Rust `data-encoding`.
- Hex: Pion is **1.7x (encode) and 4.6x (decode) faster than Rust `hex`**, and 0.70x / 0.59x Go.
- Peak RSS is between Rust's and Go's in every mode.
