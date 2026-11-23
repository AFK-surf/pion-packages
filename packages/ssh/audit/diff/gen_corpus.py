#!/usr/bin/env python3
"""Deterministic differential corpus for packages/ssh.

usage: gen_corpus.py <vectors_dir> <out.tsv> [n_mutants] [seed]

Writes "<label>\t<kind>\t<hex>[\t<arg>]" lines (see ../oracle/src/main.pion):
  t_*  hand-written targeted vectors (RFC 4251 / PROTOCOL.certkeys / sshd(8) AUTHORIZED_KEYS / known_hosts edge cases)
  m_*  seeded random mutants of real ssh-keygen (OpenSSH_10.3p1) keys, certificates and lines
"""
import base64
import os
import random
import struct
import sys

vec_dir, out_path = sys.argv[1], sys.argv[2]
N = int(sys.argv[3]) if len(sys.argv) > 3 else 10000
SEED = int(sys.argv[4]) if len(sys.argv) > 4 else 4253
rnd = random.Random(SEED)


def read(name):
    with open(os.path.join(vec_dir, name), "rb") as f:
        return f.read()


def line_blob(line):
    return base64.b64decode(line.split()[1])


def s(b):
    if isinstance(b, str):
        b = b.encode()
    return struct.pack(">I", len(b)) + b


def mpint(n):
    if n == 0:
        return s(b"")
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
    if raw[0] & 0x80:
        raw = b"\x00" + raw
    return s(raw)


pub_lines = {n: read(n).decode().strip() for n in ("ca_ed.pub", "ca_rsa.pub", "user_ed.pub", "p256.pub", "p384.pub")}
cert_files = sorted(f for f in os.listdir(vec_dir) if f.endswith("-cert.pub") or (f.startswith("cert_") and f.endswith(".pub")))
cert_lines = {n: read(n).decode().strip() for n in cert_files}
pk_blobs = {n: line_blob(l) for n, l in pub_lines.items()}
cert_blobs = {n: line_blob(l) for n, l in cert_lines.items()}

rows = []


def add(label, kind, data, arg=None):
    if isinstance(data, str):
        data = data.encode()
    row = "%s\t%s\t%s" % (label, kind, data.hex())
    if arg is not None:
        row += "\t" + arg
    rows.append(row)


# ---------------------------------------------------------------- targeted: public key wire
ed = pk_blobs["user_ed.pub"]
p256 = pk_blobs["p256.pub"]
rsa = pk_blobs["ca_rsa.pub"]
# Decompose the RSA blob: string "ssh-rsa", mpint e, mpint n
off = 4 + 7
elen = struct.unpack(">I", rsa[off:off + 4])[0]
e_raw = rsa[off + 4:off + 4 + elen]
off2 = off + 4 + elen
nlen = struct.unpack(">I", rsa[off2:off2 + 4])[0]
n_raw = rsa[off2 + 4:off2 + 4 + nlen]
n_int = int.from_bytes(n_raw, "big")
for lab, e in (("e1", 1), ("e2", 2), ("e3", 3), ("e4_even", 4), ("e65536_even", 65536), ("e65537", 65537)):
    add("t_pk_rsa_" + lab, "pk", s("ssh-rsa") + mpint(e) + mpint(n_int))
add("t_pk_rsa_e_leading_zero", "pk", s("ssh-rsa") + s(b"\x00\x01\x00\x01") + s(n_raw))
add("t_pk_rsa_n_negative", "pk", s("ssh-rsa") + mpint(65537) + s(n_raw.lstrip(b"\x00")))
add("t_pk_rsa_512bit", "pk", s("ssh-rsa") + mpint(65537) + mpint(n_int >> 1536 | 1))
add("t_pk_rsa_trailing", "pk", rsa + b"\x00")
add("t_pk_ed_trailing", "pk", ed + b"\x00")
add("t_pk_ed_31", "pk", s("ssh-ed25519") + s(b"\x01" * 31))
add("t_pk_ed_33", "pk", s("ssh-ed25519") + s(b"\x01" * 33))
# P-256: decompose
x = p256[-64:-32]
y = p256[-32:]
add("t_pk_p256_offcurve", "pk", s("ecdsa-sha2-nistp256") + s("nistp256") + s(b"\x04" + x + bytes([y[0] ^ 1]) + y[1:]))
add("t_pk_p256_zero_point", "pk", s("ecdsa-sha2-nistp256") + s("nistp256") + s(b"\x04" + b"\x00" * 64))
add("t_pk_p256_x_ge_p", "pk", s("ecdsa-sha2-nistp256") + s("nistp256") + s(b"\x04" + b"\xff" * 64))
add("t_pk_p256_compressed", "pk", s("ecdsa-sha2-nistp256") + s("nistp256") + s(bytes([2 + (y[-1] & 1)]) + x))
add("t_pk_p256_wrong_curve", "pk", s("ecdsa-sha2-nistp256") + s("nistp384") + s(b"\x04" + x + y))
add("t_pk_p384_real", "pk", pk_blobs["p384.pub"])
add("t_pk_type_upper", "pk", s("SSH-ED25519") + ed[4 + 11:])
add("t_pk_len_ffffffff", "pk", b"\xff\xff\xff\xff" + ed[4:])
add("t_pk_empty", "pk", b"")
add("t_pk_cert_as_pk", "pk", cert_blobs["cert_ok.pub"])

# ---------------------------------------------------------------- targeted: certificates
for n, b in cert_blobs.items():
    add("t_cert_" + n.replace(".pub", ""), "cert", b)
    add("t_cert_trailing_" + n.replace(".pub", ""), "cert", b + b"\x00")

# ---------------------------------------------------------------- targeted: certificate checks
NOW = "1800000000"  # 2027-01-15, inside every ssh-keygen vector's window [0x69553a70, 0x7c23e070)
for n, b in cert_blobs.items():
    who = "admin" if (n.startswith("sshd_") or n.startswith("craft_")) else "alice"
    add("t_chk_" + n.replace(".pub", ""), "certchk", b, who + " " + NOW)
okc = cert_blobs["cert_ok.pub"]
add("t_chk_wrong_principal", "certchk", okc, "mallory " + NOW)
add("t_chk_before_window", "certchk", okc, "alice 1767193199")  # valid_after - 1
add("t_chk_at_valid_after", "certchk", okc, "alice 1767193200")
add("t_chk_at_valid_before", "certchk", okc, "alice 2082726000")
add("t_chk_u64max", "certchk", okc, "alice 18446744073709551615")

# ---------------------------------------------------------------- targeted: authorized_keys
edl = pub_lines["user_ed.pub"]
ak_cases = {
    "plain": edl,
    "restrict": "restrict " + edl,
    "cmd_escaped_quote": 'command="echo \\"hi\\"" ' + edl,
    "cmd_backslash_backslash": 'command="a\\\\",from="10.0.0.1" ' + edl,
    "unterminated_quote": 'command="echo ' + edl,
    "space_in_unquoted": "no-pty, no-agent-forwarding " + edl,
    "empty_option": ",no-pty " + edl,
    "trailing_comma": "no-pty, " + edl,
    "dup_option": "no-pty,no-pty " + edl,
    "unquoted_value": "command=echo " + edl,
    "tab_sep": "no-pty\t" + edl,
    "nul_in_option": "no-pty\x00x " + edl,
    "cr_inside": "no-pty\rfoo " + edl,
    "comment": "# " + edl,
    "blank": "   ",
    "cert_authority_opts": 'cert-authority,principals="alice" ' + pub_lines["ca_ed.pub"],
    "cert_line": cert_lines["cert_ok.pub"],
    "cert_with_opts": "no-pty " + cert_lines["cert_ok.pub"],
    "p384": pub_lines["p384.pub"],
    "p384_with_opts": "restrict " + pub_lines["p384.pub"],
    "unknown_type": "sk-ssh-ed25519@openssh.com " + edl.split()[1],
    "type_mismatch": "ssh-rsa " + edl.split()[1],
    "missing_blob": "ssh-ed25519",
    "bad_b64": "ssh-ed25519 AAAA!AAA",
    "b64_no_pad": "ssh-ed25519 " + edl.split()[1].rstrip("="),
    "nonascii_comment": edl + " café",
    "env_option": 'environment="A=B" ' + edl,
    "permitopen_multi": 'permitopen="h:1",permitopen="h:2" ' + edl,
}
for k, v in ak_cases.items():
    add("t_ak_" + k, "ak", v)

# ---------------------------------------------------------------- targeted: known_hosts
kh_cases = {
    "plain": "example.com " + edl,
    "multi": "a.example.com,b.example.com,10.0.0.1 " + edl,
    "neg": "!bad.example.com,*.example.com " + edl,
    "port": "[example.com]:2222 " + edl,
    "ipv6": "[::1]:2222 " + edl,
    "cert_authority": "@cert-authority *.example.com " + pub_lines["ca_ed.pub"],
    "revoked": "@revoked * " + edl,
    "unknown_marker": "@foo example.com " + edl,
    "marker_only": "@revoked",
    "hashed": "|1|zP5Wl+PoTJSeV9cix6XxaqulQ7M=|YnLSroYfQzHTHxXKM4KAkUi7ZNw= " + edl,
    "hashed_bad_b64": "|1|zP5Wl+PoTJSeV9cix6Xx!qulQ7M=|YnLSroYfQzHTHxXKM4KAkUi7ZNw= " + edl,
    "hashed_short_salt": "|1|AAAA|YnLSroYfQzHTHxXKM4KAkUi7ZNw= " + edl,
    "empty_pattern": "a,,b " + edl,
    "leading_comma": ",a " + edl,
    "p384": "example.com " + pub_lines["p384.pub"],
    "cert_as_hostkey": "example.com " + cert_lines["cert_ok.pub"],
    "comment": "# example.com " + edl,
    "star_bomb": ("a*" * 64) + "b " + edl,
    "missing_key": "example.com",
}
for k, v in kh_cases.items():
    add("t_kh_" + k, "kh", v)

# ---------------------------------------------------------------- mutants
ALPH = list(b'"\\,= \t#!*?@|[]:\r\x00') + [0xC3, 0xA9, 0xFF, ord("A"), ord("/"), ord("+")]


def mut_bytes(b):
    b = bytearray(b)
    op = rnd.randrange(7)
    if op == 0 and b:  # flip a byte
        i = rnd.randrange(len(b))
        b[i] ^= 1 << rnd.randrange(8)
    elif op == 1 and b:  # truncate
        del b[rnd.randrange(len(b)):]
    elif op == 2:  # append junk
        b += bytes(rnd.randrange(256) for _ in range(rnd.randrange(1, 9)))
    elif op == 3 and len(b) >= 4:  # clobber a length-looking u32
        i = rnd.randrange(len(b) - 3)
        v = rnd.choice([0, 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, len(b), len(b) - i])
        b[i:i + 4] = struct.pack(">I", v & 0xFFFFFFFF)
    elif op == 4 and b:  # set a byte to an interesting value
        b[rnd.randrange(len(b))] = rnd.choice([0, 0x80, 0xFF, 0x7F, 0x2C])
    elif op == 5 and len(b) > 8:  # duplicate a slice
        i = rnd.randrange(len(b) - 4)
        j = min(len(b), i + rnd.randrange(1, 64))
        b[j:j] = b[i:j]
    else:  # delete a slice
        if b:
            i = rnd.randrange(len(b))
            del b[i:i + rnd.randrange(1, 9)]
    return bytes(b)


def mut_text(t):
    b = bytearray(t.encode())
    op = rnd.randrange(5)
    if op == 0 and b:
        b.insert(rnd.randrange(len(b) + 1), rnd.choice(ALPH))
    elif op == 1 and b:
        del b[rnd.randrange(len(b))]
    elif op == 2 and b:
        b[rnd.randrange(len(b))] = rnd.choice(ALPH)
    elif op == 3:  # mutate the base64 blob through the wire mutator
        parts = t.split(" ")
        for k, p in enumerate(parts):
            if p.startswith("AAAA"):
                try:
                    raw = base64.b64decode(p)
                except Exception:
                    break
                parts[k] = base64.b64encode(mut_bytes(raw)).decode()
                break
        b = bytearray(" ".join(parts).encode())
    else:  # prepend an option / marker
        b[0:0] = rnd.choice([b"no-pty ", b'command="x" ', b"@revoked ", b"@cert-authority ", b"!", b"*,"])
    # keep lines single-line for both oracles; the corpus is newline-delimited text
    return bytes(b).replace(b"\n", b" ")


pk_seeds = list(pk_blobs.values())
cert_seeds = list(cert_blobs.values())
ak_seeds = list(ak_cases.values())[:20] + list(pub_lines.values()) + list(cert_lines.values())
kh_seeds = list(kh_cases.values())[:12]
for i in range(N):
    r = i % 5
    if r == 0:
        b = rnd.choice(pk_seeds)
        for _ in range(rnd.randrange(1, 3)):
            b = mut_bytes(b)
        add("m_pk_%05d" % i, "pk", b)
    elif r == 1:
        b = rnd.choice(cert_seeds)
        for _ in range(rnd.randrange(1, 3)):
            b = mut_bytes(b)
        add("m_cert_%05d" % i, "cert", b)
    elif r == 2:
        add("m_ak_%05d" % i, "ak", mut_text(rnd.choice(ak_seeds)))
    elif r == 3:
        add("m_kh_%05d" % i, "kh", mut_text(rnd.choice(kh_seeds)))
    else:
        b = rnd.choice(cert_seeds)
        b = mut_bytes(b) if rnd.random() < 0.5 else b
        add("m_chk_%05d" % i, "certchk", b, rnd.choice(["alice", "admin", "mallory", ""]) + " " +
            rnd.choice([NOW, "0", "1767193200", "2082725999", "2082726000", "18446744073709551615"]))

with open(out_path, "w") as f:
    f.write("\n".join(rows) + "\n")
print("corpus: %d vectors (%d targeted, %d mutants, seed %d) -> %s" % (
    len(rows), sum(r.startswith("t_") for r in rows), sum(r.startswith("m_") for r in rows), SEED, out_path))
