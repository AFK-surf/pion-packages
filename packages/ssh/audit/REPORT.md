# Red-team audit: `packages/ssh` @ `81a2816` (`feat/pkg-ssh`)

Auditor: RT-ssh. Scope: all of `packages/ssh/src/**` (2,699 lines, read in full) plus `bench/` and
`wasm_smoke/`. References: a real **OpenSSH_10.3p1** (`sshd(8)` run unprivileged on 127.0.0.1, `ssh-keygen(1)`),
and **Go `golang.org/x/crypto/ssh` v0.38.0** (go1.27.3).

Reproduce everything with one command (about a minute; all artefacts go to `$AUDIT_OUT`, default `/tmp/rt-ssh-audit`):

```sh
sh packages/ssh/audit/run_audit.sh            # build tests diff wasm interop sshd dos bench
sh packages/ssh/audit/run_audit.sh sshd       # one step
```

| File | Purpose |
| --- | --- |
| `redteam_test.pion` (`pion.toml`) | 21 findings as failing assertions (`p0_*`/`p1_*`/`p2_*`), 16 `control_*` attacks Pion survives |
| `oracle/` | Pion CLI: differential `vectors`, `craft` (signs adversarial certs with the test CA), `akinject`, SSHSIG/private-key interop, `dos`, `bench_sshsig` |
| `diff/go/` | Go `x/crypto/ssh` oracle with the same I/O format, plus `dos kh_star` and `bench_sshsig` |
| `diff/gen_corpus.py`, `diff/compare.py` | 117 targeted + 10,000 seeded mutants (seed 4253); classifier |
| `sshd_oracle.sh` | Logs in to a real `sshd` with every certificate / `authorized_keys` case and prints sshd's verdict next to Pion's |
| `vectors/` | `ssh-keygen` (OpenSSH_10.3p1) keys, certificates, SSHSIGs; `craft_*` certs signed by the throw-away test CA `vectors/ca_ed` |

## Summary

| | Count |
| --- | ---: |
| Audit unit tests | 37 = **21 FAIL** (P0 2, P1 8, P2 11) + **16/16 control PASS** |
| Original `packages/ssh` tests | 17/17 PASS (109/109 with `base64` + `crypto`), untouched |
| Differential vectors (Pion vs Go) | 10,117: 9,021 identical, 1,096 differing, **all 1,096 classified** (below) |
| 4-mode (native rel/dbg, wasm32 rel/dbg) over the corpus | **byte-identical** (sha256 `dd8475c63d0c251a…`), 0 traps |
| 4-mode over the DoS shapes | 5/6 shapes identical; **`dos namelist`: native SIGBUS in both native modes, wasm32 fine** (T-1) |
| `sshd` oracle | 8 cert cases + 5 `authorized_keys` cases + 1 injection: Pion disagrees with sshd on **8** |

## P0 — authorization bypass against the OpenSSH certificate rules

### P0-1 Unknown critical options are ignored — `p0_cert_unknown_critical_option_must_be_rejected`
`Certificate::verify` (`src/cert.pion:305-344`) never looks at `critical_options`. PROTOCOL.certkeys: *"If an
implementation does not recognise a critical option, it MUST refuse to authorise the certificate."*
`vectors/cert_unknown_crit.pub` (`ssh-keygen -O critical:evil@rt.example=…`) verifies `Ok`.

* sshd: `Certificate critical option "evil@rt.example" is not supported` → **DENIED**
* Go `CertChecker.CheckCert`: `ssh: unsupported critical option "evil@rt.example" in certificate`
* Pion: `OK`. Any restriction a CA expresses through a new critical option (e.g. `verify-required`) silently vanishes.

### P0-2 A user certificate without principals is valid for every user — `p0_user_cert_without_principals_must_be_rejected`
`if self.valid_principals.length() > 0 { … }` (`src/cert.pion:324`) treats an empty list as a wildcard, so
`vectors/cert_noprinc.pub` (`ssh-keygen -s` without `-n`) verifies for `root`.
sshd: `Refusing certificate … Certificate lacks principal list` → **DENIED**. (Go's `CertChecker` has the same
wildcard semantics as Pion; for user authentication OpenSSH is the reference and is strict.)

## P1

| ID | Test | Finding | Reference behaviour |
| --- | --- | --- | --- |
| P1-1 | `p1_cert_duplicate_critical_option_must_be_rejected` | Two `force-command` options (`/bin/true`, `/bin/sh`) in one CA-signed cert are both returned; which one runs depends on the caller. `parse_cert_options` has no duplicate check. | sshd `Invalid certificate options` (DENIED); Go `options are not in lexical order` |
| P1-2 | `p1_cert_source_address_is_silently_not_enforced` | `verify()` has no client-address parameter and returns `Ok` for a `source-address=10.0.0.0/8` cert; the README says it "verifies" certificates. | sshd from 127.0.0.1: `not from a permitted source address` (DENIED); Go enforces it in `CertChecker.Authenticate` |
| P1-3 | `p1_cert_signed_by_rsa_ca_with_default_rsa_sha2_512_verifies`, `p1_sshsig_from_ssh_keygen_rsa_key_verifies` | `public_key_verify` knows only `rsa-sha2-256` (`src/key.pion:309`). `ssh-keygen -s <rsa CA>` and `ssh-keygen -Y sign -f <rsa key>` both emit **`rsa-sha2-512` by default**, so every RSA-CA certificate and every RSA-signed Git commit from stock OpenSSH fails (`unsupported SSH algorithm: rsa-sha2-512`). RSA signing is not implemented at all (`private_key_sign` → `UnsupportedAlgorithm`). | sshd, Go and ssh-keygen accept both |
| P1-4 | `p1_sshsig_verify_has_no_trust_anchor` | `sshsig_verify(sig, ns, msg)` verifies against the key **embedded in the signature**. A signature made with an arbitrary attacker key returns `Ok`. Contrast `Certificate::verify(ca_key, …)` in the same package. | `ssh-keygen -Y verify` requires `-f allowed_signers -I identity` |
| P1-5 | `p1_authorized_keys_one_unsupported_line_drops_every_key`, `p1_known_hosts_one_unsupported_line_drops_every_host` | `parse_authorized_keys` / `parse_known_hosts` return `Err` for the whole file on the first bad line. One `ecdsa-sha2-nistp384` / `sk-*` / `ssh-dss` line (common `ssh-keyscan` output) locks out every user / makes every host unverifiable. | sshd and Go skip the bad line; `ssh-keygen -F` still finds the ed25519 entry |
| P1-6 | `p1_encode_authorized_key_newline_injection` | `encode_authorized_key` escapes only `"` and `\`; a newline in an option value or comment is emitted verbatim. **sshd-confirmed:** for `restrict,command="true\n<attacker key> "` on the victim key, sshd skips the broken first line and **logs the attacker key in with no restrictions** (`sshd_oracle.sh`, "newline injection"). | — (Go has no options encoder; OpenSSH has none) |

## P2

| ID | Test | Finding | Reference |
| --- | --- | --- | --- |
| P2-1 | `p2_rsa_public_key_even_exponent_rejected_at_parse`, `…exponent_one…` | `parse_public_key_body` only checks `e`/`n` non-empty: `e = 1, 2, 4, 65536` parse and get fingerprints (verification later fails inside `crypto`). | Go `ssh: incorrect exponent` |
| P2-2 | `p2_p256_public_key_off_curve_rejected_at_parse` | Only length 65 + `0x04` prefix are checked: `(0,0)`, `x ≥ p`, off-curve points parse (68 fuzz mutants too). | Go `ssh: invalid curve point` |
| P2-3 | `p2_openssh_rsa_private_key_inconsistent_crt_rejected` | `openssh-key-v1` RSA: `d`, `iqmp`, `p`, `q` are never checked (d = 3 accepted). | Go `rsa.PrivateKey.Validate()` |
| P2-4 | `p2_authorized_keys_backslash_backslash_differs_from_sshd`, `p2_authorized_keys_unknown_option_rejected` | Option grammar ≠ sshd: Pion unescapes `\\` (sshd's `opt_dequote` only `\"`), so `command="echo a\\"` is accepted by Pion and refused by sshd (`invalid key option string`); unknown names (`frobnicate`), names containing CR/NUL or `@revoked` are returned as options while sshd refuses the line (fail-closed). Conversely `,no-pty <key>` logs in on sshd but is `Err` in Pion (and, via P1-5, kills the file). | sshd (`sshd_oracle.sh`) |
| P2-5 | `p2_binary_packet_must_be_block_aligned` | `decode_binary_packet` accepts a 17-byte packet (not a multiple of 8). | RFC 4253 §6 MUST; OpenSSH `padding error` |
| P2-6 | `p2_kexinit_non_ascii_algorithm_name_rejected`, `p2_kexinit_encode_rejects_comma_inside_name` | Decoder accepts non-ASCII names; encoder writes `"a,b"` as one name that decodes as two algorithms. | RFC 4251 §6 |
| P2-7 | `p2_version_1_99_compat_accepted`, `p2_version_line_with_nul_rejected` | `SSH-1.99-…` is rejected (RFC 4253 §5.1 says treat as 2.0; OpenSSH does); NUL and 0xFF in the software version are accepted and land in a `String` (not UTF-8-validated). | RFC 4253 §4.2/§5.1, OpenSSH `kex.c` |
| P2-8 | diff only (`m_cert_06466`) | Critical-option values are not structurally validated (trailing data after the inner string accepted). | Go `unexpected trailing data after certificate option value`; OpenSSH `corrupt (extra data)` |

## T-1 Toolchain: native crash in both native modes, wasm32 fine (not an `ssh` bug as far as evidence shows)

`oracle_pion dos namelist 1` (build a 256-name KEXINIT, `to_payload`, `KexInit::from_payload` with a caller-built
`ssh::Limits::{ …, max_list_items: 1024 }`, `negotiate_kex`) exits **138 (SIGBUS)** in native release *and* debug
builds, while wasm32 release/debug print the correct result (`payload=9414 -> 4`). Replacing the literal with
`Limits::default()` or inserting `io_eprintln` calls around `from_payload` makes the crash disappear, and the same
sequence in a standalone 60-line program does not crash: a layout/codegen-dependent native back-end bug in `pionc`
(wasm32 bounds checks would trap on an out-of-bounds access in `ssh`; they do not). Not a stack-size issue
(`ulimit -s 65520` still crashes). Repro: `sh run_audit.sh wasm`, last two rows. Proposal: hand to the `pionc` owners.

## Differential: Pion vs Go `x/crypto/ssh` (10,117 vectors, seed 4253)

| Class | Kind | Pion / Go | n | Explanation |
| --- | --- | --- | ---: | --- |
| feature gap | ak/cert/kh/pk | ERR / OK | 138 | nistp384/521, sk-*, certificates as known_hosts keys: not implemented |
| P0-1, P1-1 | cert, certchk | OK / ERR·REJECT | 107 + 74 + 19 | duplicate / unknown critical options (also unsorted options: Go is stricter than sshd here; sshd accepts unsorted, so that part is **not** a Pion finding) |
| P1-3 | certchk | REJECT / OK | 12 | `rsa-sha2-512` CA signature |
| P2-1/2 | pk | OK / ERR | 72 | RSA exponent, off-curve P-256 |
| P2-4 | ak | OK / ERR, ERR / OK | 73 + 102 | option grammar (`\\`, CR, unknown names, unquoted values, leading/trailing comma) |
| — | kh | ERR / OK | 149 | Go accepts unknown markers (`@foo`) as markers; Pion rejects the line (OpenSSH also ignores it) |
| — | certchk | REJECT / ERR, ERR / REJECT | 316 + 23 | both refuse; they just fail at different stages (Pion parses more leniently but rejects at verify) |
| — | kh | OK / OK | 3 | Pion drops empty patterns in `a,,b`; Go keeps them |
| — | pk | ERR / OK | 2 | **Pion stricter:** Go accepts negative `n` and `e` with a redundant leading zero |
| oracle artefact | certchk | OK / REJECT | 2 | `now = 2^64-1` overflows the Go oracle's `time.Unix(int64)`; not a Go bug |

No crash, hang or trap in either implementation over the corpus.

## Fairness — where Pion is right, or better than the originals

* **Exponential-time `known_hosts` wildcard (ReDoS) — Pion wins outright.** Pattern `("a*"×n)+"b"` vs `"a"×4n`:
  Go `knownhosts` 1.85 s (n=10) → **15.4–17.1 s (n=11)**; OpenSSH `ssh-keygen -F` 1.06 s → **8.8–13.8 s (n=11)** (two runs, loaded host); both
  recursive backtracking. Pion's iterative matcher: **0.11 s at n=20,000** (`control_known_hosts_wildcard_is_linear_no_redos`).
* Stricter than Go and equal to OpenSSH: RFC 4251 `mpint` canonicality (Go accepts negative `n` / padded `e`), key
  type prefix must match the blob (Go accepts `ssh-rsa <ed25519 blob>`), strict base64.
* Correct cert validity window `after ≤ now < before` incl. `u64::MAX` (`control_cert_validity_window_boundaries`),
  CA mismatch, type confusion, TBS tampering, trailing bytes, certificate-as-CA-key, SHA-1 `ssh-rsa` refused.
* Strict Ed25519 (S+L refused), ECDSA `r ∈ [1, n)`, P-256 `d = 0` refused; `openssh-key-v1` `num_keys`, checkint,
  padding and truncation all refused (`control_openssh_private_key_structure`).
* SSHSIG: namespace confusion, hash downgrade, trailing bytes, text before the armor, version ≠ 1 all refused.
  Interop with `ssh-keygen`: Ed25519 and P-256 SSHSIG **both directions, sha256 and sha512**, and private-key
  re-encode (`ssh-keygen -y` gives the same key) all pass (`run_audit.sh interop`).
* Unsorted cert options and duplicate extensions are accepted — exactly like sshd (Go is stricter than OpenSSH here).
* Hashed `|1|` known_hosts matching is case-sensitive while plain patterns are not — same as OpenSSH `ssh-keygen -F`.
* Linear behaviour on size bombs: 100,001 negated patterns 0.16 s, 50,001 options 0.15 s, 20,000 wildcard principals
  (829 KB cert) 0.19 s; byte-identical in all four build modes.
* Memory: 2.2–2.3 MiB peak RSS vs Go's 10.3–11.7 MiB in every benchmark.

## Benchmark fairness (`bench/`)

1. **W3 is not `x/crypto/ssh` code on the Go side**: the binary-packet codec (`encodeBinaryPacket` /
   `decodeBinaryPacket`, 30 lines) and the SSHSIG verifier are hand-written in `bench/go/main.go` (x/crypto/ssh
   exports neither); the Go decoder also skips the `max_packet_len` and `packet_length < 5` checks Pion does.
   W2's hashed-host matcher on the Go side is likewise hand-written. The work is equivalent, the label is not.
2. W2's Go `CertChecker.CheckCert` also walks critical options (P0-1); Pion does not — a small edge in Pion's favour.
3. **Missing dimensions** — the README covers only Ed25519, SHA-1/256/512 and parsing. Measured here with the same
   `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, interleaved, stdout SHA-256 verified), SSHSIG
   parse+verify, `sh run_audit.sh bench`:

   | Workload | Pion median | Go median | Pion vs Go | Pion RSS / Go RSS |
   | --- | ---: | ---: | ---: | ---: |
   | 200× RSA-2048 `rsa-sha2-256` | 67.1 ms (335 µs/op) | 15.0 ms (75 µs/op) | **0.22×** | 2.25 / 10.44 MiB |
   | 500× ECDSA P-256 (sha512) | 513.2 ms (1.03 ms/op) | 28.9 ms (58 µs/op) | **0.06×** | 2.30 / 11.67 MiB |
   | 500× Ed25519 (sha512) | 55.0 ms (110 µs/op) | 24.0 ms (48 µs/op) | 0.44× | 2.20 / 10.33 MiB |

   Measured on the shared `Darwin arm64` (M5 Max) under heavy unrelated load (load average 60–140): absolute times are
   inflated, the interleaved ratios are the usable signal. **P-256 verification is ~17× slower than Go** and RSA ~4.5×,
   neither visible in the README table. Not measured anywhere: private-key parsing, KEXINIT codec, plain-pattern
   `known_hosts`, distinct-line `authorized_keys` files (the workloads cycle three constant lines), wasm32 throughput.
4. The Peak-RSS comparison mostly measures Go's runtime baseline (≈10 MiB for a trivial Go program), not the
   library's working set; the "6.7–7.5× smaller" claim should say so.

## Proposals for the leader to decide

* P0-1/P0-2/P1-1/P1-2: give `Certificate::verify` an options struct (supported critical options, client address,
  require-principal default `true` for User certs) and reject unknown / duplicate critical options.
* P1-3: add `rsa-sha2-512` (verify) — needed for any real OpenSSH RSA interop; RSA signing optional.
* P1-4: `sshsig_verify` should take the trusted public key (or an allowed-signers list) like `ssh-keygen -Y verify`.
* P1-5: per-line results (skip or report bad lines) instead of failing the whole file.
* P1-6: reject or escape CR/LF/NUL in option names, values and comments in `encode_authorized_key` and `to_openssh`.
* T-1: route the native SIGBUS repro to the `pionc` owners.
