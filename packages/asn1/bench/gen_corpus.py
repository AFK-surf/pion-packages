#!/usr/bin/env python3
"""Generate 100 genuine multi-algorithm OpenSSL X.509 v3 certificates (PEM + length-prefixed DER)."""

import os
import struct
import subprocess
import sys
import tempfile


def run(cmd, cwd):
    subprocess.run(cmd, cwd=cwd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def main():
    if len(sys.argv) < 3:
        print("usage: gen_corpus.py <out_pem> <out_derbin>", file=sys.stderr)
        sys.exit(1)

    out_pem = sys.argv[1]
    out_derbin = sys.argv[2]
    os.makedirs(os.path.dirname(os.path.abspath(out_pem)), exist_ok=True)
    os.makedirs(os.path.dirname(os.path.abspath(out_derbin)), exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="asn1_corpus_") as td:
        # Generate 4 reusable keypairs (RSA-2048, EC P-256, EC P-384, Ed25519)
        run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", "rsa.key"], td)
        run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", "ec256.key"], td)
        run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-384", "-out", "ec384.key"], td)
        run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", "ed25519.key"], td)

        # Self-signed root CA for signing leaf certs
        with open(os.path.join(td, "root.cnf"), "w") as f:
            f.write("""[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
C = US
O = Pion Bench CA
CN = Pion Bench Root CA
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:1
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
""")
        run(["openssl", "req", "-x509", "-new", "-key", "rsa.key", "-sha256", "-days", "3650",
             "-set_serial", "1", "-config", "root.cnf", "-out", "root.pem"], td)

        keys = ["rsa.key", "ec256.key", "ec384.key", "ed25519.key"]
        pem_chunks = []
        der_chunks = []

        for idx in range(100):
            key = keys[idx % 4]
            is_ca = (idx % 10 == 0)
            cn = f"svc-{idx:03d}.pion.dev"
            cnf_path = os.path.join(td, f"c{idx}.cnf")
            csr_path = os.path.join(td, f"c{idx}.csr")
            pem_path = os.path.join(td, f"c{idx}.pem")
            der_path = os.path.join(td, f"c{idx}.der")

            if is_ca:
                with open(cnf_path, "w") as f:
                    f.write(f"""[req]
distinguished_name = dn
x509_extensions = v3_ext
prompt = no
[dn]
C = US
O = Pion Bench CA
CN = {cn}
[v3_ext]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
""")
                if key == "ed25519.key":
                    run(["openssl", "req", "-x509", "-new", "-key", key, "-days", "730",
                         "-set_serial", str(1000 + idx), "-config", cnf_path, "-out", pem_path], td)
                else:
                    run(["openssl", "req", "-x509", "-new", "-key", key, "-sha256", "-days", "730",
                         "-set_serial", str(1000 + idx), "-config", cnf_path, "-out", pem_path], td)
            else:
                with open(cnf_path, "w") as f:
                    f.write(f"""[req]
distinguished_name = dn
prompt = no
[dn]
C = JP
O = Pion Cloud
CN = {cn}
[v3_ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
subjectAltName = DNS:{cn}, DNS:*.t{idx:03d}.pion.dev, IP:192.0.2.{idx + 1}
""")
                run(["openssl", "req", "-new", "-key", key, "-config", cnf_path, "-out", csr_path], td)
                run(["openssl", "x509", "-req", "-in", csr_path, "-CA", "root.pem", "-CAkey", "rsa.key",
                     "-set_serial", str(2000 + idx), "-days", "365", "-sha256",
                     "-extfile", cnf_path, "-extensions", "v3_ext", "-out", pem_path], td)

            run(["openssl", "x509", "-in", pem_path, "-outform", "DER", "-out", der_path], td)
            pem_chunks.append(open(pem_path, "rb").read())
            der_bytes = open(der_path, "rb").read()
            der_chunks.append(struct.pack(">I", len(der_bytes)) + der_bytes)

        with open(out_pem, "wb") as f:
            f.write(b"".join(pem_chunks))
        with open(out_derbin, "wb") as f:
            f.write(b"".join(der_chunks))


if __name__ == "__main__":
    main()
