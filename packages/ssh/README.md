# `ssh` — Pure Pion OpenSSH Wire Protocol, Keys, Certificates, `SSHSIG`, `authorized_keys` & `known_hosts`

Pure Pion, zero-C, `World`-free implementation of the OpenSSH wire format, public/private keys, OpenSSH certificates (`*-cert-v01@openssh.com`), Git SSH signatures (`SSHSIG`), `authorized_keys`, `known_hosts` (including `|1|` HMAC-SHA1 hashed hosts), and Sans-IO RFC 4253 transport framing (`VersionExchange`, `BinaryPacket`, `KexInit`).

Built directly on `packages/base64` and `packages/crypto` `v0.2.0` (Ed25519, NIST P-256, RSA-SHA2-256, SHA-1, SHA-256, SHA-512, constant-time equality).

## Features

- **RFC 4251 SSH Wire Codec (`src/wire.pion`)**:
  - `SshReader` / `SshWriter` for `byte`, `boolean`, `uint32`, `uint64`, `string`/`bytes`, `name-list`, and strict RFC 4251 §5 unsigned `mpint` (rejects negative values and non-canonical leading zeros).
  - Configurable `Limits` (`max_string_len`, `max_packet_len`, `max_list_items`) to prevent allocation bombs on hostile inputs.
- **SSH Public Keys, Fingerprints & OpenSSH Private Keys (`src/key.pion`)**:
  - Public key wire & OpenSSH text codec for `ssh-ed25519`, `ecdsa-sha2-nistp256`, and `ssh-rsa`.
  - OpenSSH `SHA256:<base64-no-pad>` fingerprint calculation and constant-time comparison (`public_key_fingerprint_eq`).
  - Real cryptographic signing (`Ed25519`, `ECDSA P-256`) and verification (`ssh-ed25519`, `ecdsa-sha2-nistp256`, `rsa-sha2-256`).
  - `openssh-key-v1` private key parser/encoder (`parse_openssh_private_key`, `encode_openssh_private_key`) enforcing `checkint1 == checkint2`, strict ascending `1,2,3,...` padding, and public/private key derivation consistency; encrypted keys return `SshError::EncryptedKeyUnsupported(cipher)` and expose header metadata via `parse_openssh_private_key_header`.
- **OpenSSH Certificates (`src/cert.pion`)**:
  - Full `ssh-ed25519-cert-v01@openssh.com`, `ecdsa-sha2-nistp256-cert-v01@openssh.com`, and `ssh-rsa-cert-v01@openssh.com` parse/encode/sign/verify.
  - Verifies CA key match, certificate type (`User` / `Host`), validity window (`valid_after <= now < valid_before`), principals (including wildcard host principals), and real CA cryptographic signature.
- **`SSHSIG` (`src/sshsig.pion`)**:
  - Parse, armor-encode, sign (`Ed25519` / `P-256`), and verify `-----BEGIN SSH SIGNATURE-----` (OpenSSH `PROTOCOL.sshsig` / Git commit & tag signatures) with `sha256` and `sha512`.
- **`authorized_keys` (`src/authorized_keys.pion`)**:
  - Full option parser with quoted values and `\"` / `\\` escapes (`command="..."`, `from="..."`, `cert-authority`, `restrict`, etc.), supporting both public keys and OpenSSH certificates.
- **`known_hosts` (`src/known_hosts.pion`)**:
  - Parses `@cert-authority` / `@revoked` markers, comma-separated host patterns, `*`/`?` wildcards, `!negated` exclusions, `[host]:port`, and `|1|<salt>|<hash>` HMAC-SHA1 hashed hostnames (constant-time match).
- **Sans-IO RFC 4253 Transport (`src/transport.pion`)**:
  - Protocol version exchange (`parse_version_line`, `encode_version_line`), unencrypted binary packet framing (`encode_binary_packet`, `decode_binary_packet`), and `SSH_MSG_KEXINIT` codec + client-preference algorithm negotiation (`negotiate_kex`).

## Verification

- **Unit & Compliance Tests (`sh scripts/verify.sh packages/ssh`)**:
  - `17/17` tests in `packages/ssh` (`109/109` including `base64` + `crypto`) passing against real `OpenSSH_10.3p1` (`ssh-keygen`) generated keys, SHA-256 fingerprints, User/Host certificates, `ssh-keygen -Y sign` `SSHSIG` vectors, `ssh-keygen -H` `|1|` `known_hosts`, and adversarial malformed inputs.
- **Dual-Target Wasm32 Smoke (`packages/ssh/wasm_smoke`)**:
  - All 4 build modes (Native debug/release + Wasm32 debug/release, clean `PION_CACHE_DIR`) exit `0` with byte-identical stdout:
    `ssh_wasm_smoke: OK fp=SHA256:/qjJWRy8QUCo3C4H7pEmjFSVrY+SrgXh6CrKUeBL39Q serial=42 kh=1 pkt=16/4`
    (`sha256: c4d2b3d187844bbd814f0869d1f813c489b4279e6cf7bd8b5b057c9343e12599`).

## Head-to-Head Benchmarks

Measured on `Darwin arm64` via `sh packages/ssh/bench/run_bench.sh` (`scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved) against Go `golang.org/x/crypto/ssh v0.38.0` (`go1.27.3 darwin/arm64`). All 3 workloads verified **byte-identical stdout SHA-256** across both implementations and all rounds.

| Workload | Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs Go) | Stdout SHA-256 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| **W1**: 20,000x `authorized_keys` parse + SHA-256 fingerprint | `pion` (`--release`) | 105.463 | 82.826 | 112.193 | 5273.16 | **2.14 MiB** | 0.71x | `8a48c5cbe0f0ef40...` |
| | `go_x_crypto_ssh` | 74.869 | 70.740 | 91.494 | 3743.44 | 15.98 MiB | 1.00x | `8a48c5cbe0f0ef40...` |
| **W2**: 5,000x `known_hosts` (`\|1\|` HMAC-SHA1) + 1,000x OpenSSH Cert Ed25519 CA verify | `pion` (`--release`) | 208.399 | 183.665 | 220.933 | 34733.14 | **2.22 MiB** | 0.43x | `201b5c12cfa6c460...` |
| | `go_x_crypto_ssh` | 88.899 | 70.387 | 97.606 | 14816.52 | 16.06 MiB | 1.00x | `201b5c12cfa6c460...` |
| **W3**: 1,000x `SSHSIG` Ed25519 verify + 50,000x RFC 4253 binary packet roundtrip | `pion` (`--release`) | 144.678 | 137.781 | 175.244 | 2836.82 | **2.11 MiB** | 0.64x | `b09bb6eb1cb7a2df...` |
| | `go_x_crypto_ssh` | 92.267 | 68.470 | 104.305 | 1809.16 | 14.19 MiB | 1.00x | `b09bb6eb1cb7a2df...` |

### Honest Analysis

- **Memory footprint**: Pion Native uses **2.1–2.2 MiB Peak RSS** across all three workloads — roughly **6.7x–7.5x smaller** than Go (`14.2–16.1 MiB`), with zero GC runtime overhead and identical code compiling to `wasm32`.
- **Throughput gap vs Go**: Go's `crypto/sha1`, `crypto/sha256`, `crypto/sha512`, and `crypto/ed25519` (`filippo.io/edwards25519`) use hand-tuned ARMv8 crypto-extension assembly (`SHA1H`/`SHA256H`/`SHA512H` + ARM64 Ed25519 field arithmetic), whereas Pion's `packages/crypto` is 100% portable pure Pion with no inline assembly. This explains why W2 (dominated by 30,000 HMAC-SHA1 calls + 1,000 Ed25519 verifies) runs at `0.43x` of Go, while W1 (`authorized_keys` parsing + SHA-256) and W3 (Ed25519 `SSHSIG` + 50k binary packet roundtrips) reach `0.71x` and `0.64x` respectively.
