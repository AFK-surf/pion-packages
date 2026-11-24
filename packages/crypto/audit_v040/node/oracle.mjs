// RT-crypto-v040 Node.js cross-oracle: independently recomputes the Go oracle's expected values.
//
//   node oracle.mjs <corpus.tsv> <expected.out>
//
// - every row whose expected result is hex is recomputed with crypto.pbkdf2Sync / crypto.scryptSync
//   (OpenSSL EVP_PBE_scrypt) and, for ML rows, aes-256-gcm with a 12-byte IV and empty AAD
//   (scrypt + AES-256-GCM envelope: ct || 16-byte tag): bytes must be identical to golang.org/x/crypto;
// - the max_mem boundary rows (sc/.../maxmem/), the 64 MiB scrypt + AES-256-GCM envelope rows (sc/env64/) and
//   the RFC 7914 §2 N < 2^(16 r) rows (sc/nbound/) that the Go corpus expects as errors must be
//   refused by Node too (same 128 r (N + p + 2) memory rule and N bound as OpenSSL).
// Exit 0 = Go and Node agree on every checked row.
import crypto from "node:crypto";
import fs from "node:fs";

const [corpusPath, expectPath] = process.argv.slice(2);
const corpus = fs.readFileSync(corpusPath, "utf8").split("\n").filter(Boolean);
const expect = fs.readFileSync(expectPath, "utf8").split("\n").filter(Boolean);
const DEFAULT_MAXMEM = 268435456;
const hex = (s) => Buffer.from(s, "hex");

function nodeScrypt(pass, salt, n, r, p, dk, maxmem) {
  return crypto.scryptSync(pass, salt, dk, { N: n, r, p, maxmem });
}

let checked = 0, refused = 0, bad = 0;
const fams = {};
for (let i = 0; i < corpus.length; i++) {
  const f = corpus[i].split("\t");
  const [label, op] = f;
  const want = expect[i].split("\t")[1];
  if (expect[i].split("\t")[0] !== label) {
    console.log(`line ${i}: label mismatch`);
    bad++;
    continue;
  }
  const isHex = /^[0-9a-f]*$/.test(want);
  const mustRefuse = !isHex && /^sc\/(heavy\/)?(maxmem|env64|nbound)\//.test(label);
  if (!isHex && !mustRefuse) continue;
  let got;
  try {
    if (op === "P256" || op === "P512") {
      got = crypto.pbkdf2Sync(hex(f[2]), hex(f[3]), +f[4], +f[5], op === "P256" ? "sha256" : "sha512").toString("hex");
    } else if (op === "SC") {
      const mm = f[8] === "D" ? DEFAULT_MAXMEM : +f[8];
      got = nodeScrypt(hex(f[2]), hex(f[3]), +f[4], +f[5], +f[6], +f[7], mm).toString("hex");
    } else if (op === "ML") {
      const n = +f[4];
      const key = nodeScrypt(hex(f[2]), hex(f[3]), n, 8, 1, 32, n <= 32768 ? 64 * 1024 * 1024 : DEFAULT_MAXMEM);
      const c = crypto.createCipheriv("aes-256-gcm", key, hex(f[5]));
      c.setAAD(Buffer.alloc(0));
      got = Buffer.concat([c.update(hex(f[6])), c.final(), c.getAuthTag()]).toString("hex");
    } else {
      continue;
    }
  } catch (e) {
    got = "NODE_THROW:" + (e.code || e.message);
  }
  const fam = label.split("/").slice(0, 2).join("/");
  fams[fam] = (fams[fam] || 0) + 1;
  if (mustRefuse) {
    if (got.startsWith("NODE_THROW")) refused++;
    else { bad++; console.log(`MISMATCH ${label}: go expects ${want}, node accepted -> ${got.slice(0, 64)}`); }
  } else if (got === want) {
    checked++;
  } else {
    bad++;
    console.log(`MISMATCH ${label}\n  go   ${want.slice(0, 128)}\n  node ${got.slice(0, 128)}`);
  }
}
console.log(`node ${process.version} (OpenSSL ${process.versions.openssl}): ${checked} rows byte-identical to Go, ` +
  `${refused} error rows refused by Node too, ${bad} disagreements`);
console.log("families:", Object.entries(fams).map(([k, v]) => `${k}=${v}`).join(", "));
process.exit(bad ? 1 : 0);
