# `ssh` — Pure Pion OpenSSH Wire Protocol, Keys, Certificates, `SSHSIG`, `authorized_keys` & `known_hosts`

Pure Pion, zero-C, `World`-free implementation of the OpenSSH wire format, public/private keys, OpenSSH certificates (`*-cert-v01@openssh.com`), Git SSH signatures (`SSHSIG`), `authorized_keys`, `known_hosts` (including `|1|` HMAC-SHA1 hashed hosts), and Sans-IO RFC 4253 transport framing (`VersionExchange`, `BinaryPacket`, `KexInit`).

Built directly on `packages/base64` and `packages/crypto` `v0.2.0` (Ed25519, NIST P-256, RSA-SHA2-256, SHA-1, SHA-256, SHA-512, constant-time equality).

## Features

- **RFC 4251 SSH Wire Codec (`src/wire.pion`)**:
  - `SshReader` / `SshWriter` for `byte`, `boolean`, `uint32`, `uint64`, `string`/`bytes`, printable US-ASCII `name-list`, and strict RFC 4251 §5 unsigned `mpint` (rejects negative values and non-canonical leading zeros).
  - Configurable `Limits` (`max_string_len`, `max_packet_len`, `max_list_items`) to prevent allocation bombs on hostile inputs.
- **SSH Public Keys, Fingerprints & OpenSSH Private Keys (`src/key.pion`, `src/math.pion`)**:
  - Public key wire & OpenSSH text codec for `ssh-ed25519`, `ecdsa-sha2-nistp256` (full Montgomery on-curve validation `y^2 ≡ x^3 - 3x + b (mod p)`), and `ssh-rsa` (rejects even or `< 3` exponents and even moduli at parse time).
  - OpenSSH `SHA256:<base64-no-pad>` fingerprint calculation and constant-time comparison (`public_key_fingerprint_eq`).
  - Real cryptographic signing (`Ed25519`, `ECDSA P-256`) and verification (`ssh-ed25519`, `ecdsa-sha2-nistp256`, `rsa-sha2-256`, `rsa-sha2-512`). Legacy SHA-1 `ssh-rsa` signatures are refused.
  - `openssh-key-v1` private key parser/encoder (`parse_openssh_private_key`, `encode_openssh_private_key`) enforcing `checkint1 == checkint2`, strict ascending `1,2,3,...` padding, public/private key derivation consistency, and full RSA CRT mathematical validation (`p * q == n`, `e * d ≡ 1 (mod p-1, q-1)`, `q * iqmp ≡ 1 (mod p)`). Encrypted keys return `SshError::EncryptedKeyUnsupported(cipher)` and expose header metadata via `parse_openssh_private_key_header`.
- **OpenSSH Certificates (`src/cert.pion`, `src/cidr.pion`)**:
  - Full `ssh-ed25519-cert-v01@openssh.com`, `ecdsa-sha2-nistp256-cert-v01@openssh.com`, and `ssh-rsa-cert-v01@openssh.com` parse/encode/sign/verify.
  - Strict `PROTOCOL.certkeys` / OpenSSH `sshd(8)` verification (`Certificate::verify` & `Certificate::verify_with_options`):
    - Rejects unknown or duplicate `critical_options` and malformed option value encodings (trailing bytes after inner SSH string).
    - Enforces `source-address` IPv4/IPv6 CIDR restrictions (`CertVerifyOptions::with_client_ip`); certificates carrying `source-address` are rejected when no matching client IP is supplied.
    - Rejects User certificates with an empty `valid_principals` list by default (`require_principal: true`).
    - Verifies CA key match, certificate type (`User` / `Host`), validity window (`valid_after <= now < valid_before`), principals (including wildcard host principals), and CA cryptographic signature (`Ed25519`, `P-256`, `rsa-sha2-256`, `rsa-sha2-512`).
- **`SSHSIG` (`src/sshsig.pion`)**:
  - Parse, armor-encode, sign (`Ed25519` / `P-256`), and verify `-----BEGIN SSH SIGNATURE-----` (OpenSSH `PROTOCOL.sshsig` / Git commit & tag signatures) with `sha256` and `sha512`, including stock OpenSSH `rsa-sha2-512` signatures.
  - Trust-anchor verification APIs: `sshsig_verify_with_key` (single trusted public key) and `sshsig_verify_allowed` (allowed-signers key list, matching `ssh-keygen -Y verify`). `sshsig_verify` performs self-contained cryptographic verification only (matching `ssh-keygen -Y check-novalidate`).
- **`authorized_keys` (`src/authorized_keys.pion`)**:
  - OpenSSH `sshd(8)`-aligned option parser (allowlisted option names, flag/value arity checks, `opt_dequote()` `\"`-only unescaping, empty comma segments, control-character rejection), supporting both public keys and OpenSSH certificates.
  - `parse_authorized_keys` skips unsupported or malformed lines (matching `sshd`/Go); `parse_authorized_keys_strict` fails on the first invalid line.
  - `encode_authorized_key` neutralizes CR/LF/NUL to prevent newline key injection; `encode_authorized_key_checked` rejects CR/LF/NUL with `Err`.
- **`known_hosts` (`src/known_hosts.pion`)**:
  - Parses `@cert-authority` / `@revoked` markers, comma-separated host patterns, linear-time iterative `*`/`?` wildcards (immune to exponential backtracking ReDoS), `!negated` exclusions, `[host]:port`, and `|1|<salt>|<hash>` HMAC-SHA1 hashed hostnames (constant-time match).
  - `parse_known_hosts` skips unsupported or malformed lines (matching `ssh-keygen -F`/Go); `parse_known_hosts_strict` fails on the first invalid line.
- **Sans-IO RFC 4253 Transport (`src/transport.pion`)**:
  - Protocol version exchange (`parse_version_line`, `encode_version_line`) accepting `SSH-2.0` and RFC 4253 §5.1 `SSH-1.99` compatibility strings while rejecting NUL/control/non-ASCII bytes.
  - Unencrypted binary packet framing (`encode_binary_packet`, `decode_binary_packet`) enforcing 8-byte block alignment and `padding_length >= 4`.
  - `SSH_MSG_KEXINIT` codec (rejecting non-ASCII or comma-containing algorithm names on both decode and encode) + client-preference algorithm negotiation (`negotiate_kex`).

## Verification

- **Unit & Compliance Tests (`sh scripts/verify.sh packages/ssh`)**:
  - `19/19` tests in `packages/ssh` (`111/111` including `base64` + `crypto`) passing against real `OpenSSH_10.3p1` (`ssh-keygen`) generated keys, SHA-256 fingerprints, User/Host certificates, `ssh-keygen -Y sign` `SSHSIG` vectors, `ssh-keygen -H` `|1|` `known_hosts`, and adversarial malformed inputs.
- **Dual-Target Wasm32 Smoke (`packages/ssh/wasm_smoke`)**:
  - All 4 build modes (Native debug/release + Wasm32 debug/release, clean `PION_CACHE_DIR`) exit `0` with byte-identical stdout:
    `ssh_wasm_smoke: OK fp=SHA256:/qjJWRy8QUCo3C4H7pEmjFSVrY+SrgXh6CrKUeBL39Q serial=42 kh=1 pkt=16/4`
    (`sha256: c4d2b3d187844bbd814f0869d1f813c489b4279e6cf7bd8b5b057c9343e12599`).

## Head-to-Head Benchmarks

Measured on `Darwin arm64` via `sh packages/ssh/bench/run_bench.sh` and `sh packages/ssh/audit/run_audit.sh bench` (`scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved) against Go `golang.org/x/crypto/ssh v0.38.0` (`go1.27.3 darwin/arm64`). All 6 workloads verified **byte-identical stdout SHA-256** across both implementations and all rounds.

> **Benchmark methodology note**: On the Go side, `golang.org/x/crypto/ssh` does not export `|1|` hashed-host matching (W2), RFC 4253 binary packet framing (W3), or `SSHSIG` parsing/verification (W3 & SSHSIG suite); those parts are equivalent Go implementations in `bench/go/main.go` and `audit/diff/go/main.go`. Peak RSS numbers reflect total process RSS, which on Go includes Go's ~10–14 MiB runtime baseline rather than library working set alone.

| Workload | Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs Go) | Stdout SHA-256 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| **W1**: 20,000x `authorized_keys` parse + SHA-256 fingerprint | `pion` (`--release`) | 88.459 | 72.433 | 89.921 | 4422.96 | 2.16 MiB | 0.47x | `8a48c5cbe0f0ef40...` |
| | `go_x_crypto_ssh` | 41.307 | 39.917 | 43.428 | 2065.36 | 16.22 MiB | 1.00x | `8a48c5cbe0f0ef40...` |
| **W2**: 5,000x `known_hosts` (`\|1\|` HMAC-SHA1) + 1,000x OpenSSH Cert Ed25519 CA verify | `pion` (`--release`) | 214.219 | 203.608 | 223.219 | 35703.14 | 2.27 MiB | 0.34x | `201b5c12cfa6c460...` |
| | `go_x_crypto_ssh` (incl. equiv. Go `\|1\|`) | 72.530 | 69.580 | 96.976 | 12088.38 | 17.11 MiB | 1.00x | `201b5c12cfa6c460...` |
| **W3**: 1,000x `SSHSIG` Ed25519 verify + 50,000x RFC 4253 binary packet roundtrip | `pion` (`--release`) | 148.606 | 145.698 | 160.819 | 2913.84 | 2.09 MiB | 0.37x | `b09bb6eb1cb7a2df...` |
| | `go_x_crypto_ssh` (equiv. Go SSHSIG + pkt) | 54.266 | 51.365 | 59.989 | 1064.04 | 14.66 MiB | 1.00x | `b09bb6eb1cb7a2df...` |
| **SSHSIG RSA-2048** (`rsa-sha2-256`, 200x) | `pion` (`--release`) | 93.666 | 92.260 | 103.798 | 468332.50 | 2.33 MiB | **0.24x** | `6d403f5828734861...` |
| | `go_x_crypto_ssh` (equiv. Go SSHSIG) | 22.696 | 19.759 | 24.033 | 113480.62 | 10.33 MiB | 1.00x | `6d403f5828734861...` |
| **SSHSIG ECDSA P-256** (`sha512`, 500x) | `pion` (`--release`) | 977.063 | 841.482 | 1255.210 | 1954126.83 | 2.38 MiB | **0.04x** | `b8ac5346e99ad98e...` |
| | `go_x_crypto_ssh` (equiv. Go SSHSIG) | 40.443 | 35.611 | 44.862 | 80885.25 | 11.61 MiB | 1.00x | `b8ac5346e99ad98e...` |
| **SSHSIG Ed25519** (`sha512`, 500x) | `pion` (`--release`) | 77.757 | 72.249 | 79.627 | 155514.17 | 2.25 MiB | **0.47x** | `b8ac5346e99ad98e...` |
| | `go_x_crypto_ssh` (equiv. Go SSHSIG) | 36.629 | 35.430 | 38.689 | 73258.42 | 10.33 MiB | 1.00x | `b8ac5346e99ad98e...` |

### Honest Analysis

- **Memory footprint**: Pion Native uses **2.1–2.4 MiB Peak RSS** across all six workloads vs Go's **10.3–17.1 MiB** (most of Go's RSS is its ~10 MiB runtime/GC baseline), with zero GC overhead and identical code compiling to `wasm32`.
- **Throughput gap vs Go**: Go's `crypto/sha1`, `crypto/sha256`, `crypto/sha512`, `crypto/elliptic` (NIST P-256), `crypto/rsa`, and `crypto/ed25519` use hand-tuned ARMv8 crypto-extension and field-arithmetic assembly, whereas Pion's `packages/crypto` is 100% portable pure Pion with no inline assembly. On pure-crypto workloads, Pion reaches `0.47x` of Go on Ed25519, `0.24x` on RSA-2048, and `0.04x` on ECDSA P-256 (roughly 20–25× slower than Go's ARM64 P-256 assembly; ~0.06× in `REPORT.md`).
- **Algorithmic complexity advantage**: On `known_hosts` wildcard matching (`("a*" × n) + "b"` vs `"a" × 4n`), Pion's iterative O(N·M) matcher runs in **0.03–0.05 s** even at `n = 20,000`, whereas both Go `knownhosts` (`58.5 s` at `n = 11`) and OpenSSH `ssh-keygen -F` (`17.0 s` at `n = 11`) exhibit exponential backtracking.
