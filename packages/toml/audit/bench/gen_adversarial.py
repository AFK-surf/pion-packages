#!/usr/bin/env python3
"""Generate the adversarial benchmark corpora (all valid TOML 1.0.0, realistic shapes).

usage: gen_adversarial.py <out_dir>
Every file is deterministic (fixed seeds), so stdout SHA-256 checks are reproducible.
"""
import os, random, string, sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)


def w(name, text):
    with open(os.path.join(out, name), "w") as f:
        f.write(text)


# 1. float-dense: telemetry/ML-style config, 200k doubles written by a program (repr = 17 sig digits)
r = random.Random(1)
rows = []
for i in range(2000):
    rows.append(f"series_{i} = [" + ", ".join(repr(r.uniform(-1e6, 1e6)) for _ in range(100)) + "]")
w("floats.toml", "\n".join(rows) + "\n")

# 2. escape-heavy strings: JSON-ish blobs / Windows paths stored in basic strings
r = random.Random(2)
rows = []
for i in range(20000):
    s = "".join(r.choice(['\\"', "\\\\", "\\n", "\\t", "\\u00e9", "a", "b", "c", "d", "e", " "]) for _ in range(60))
    rows.append(f'k{i} = "{s}"')
w("escapes.toml", "\n".join(rows) + "\n")

# 3. long multi-line strings (documentation / embedded scripts)
r = random.Random(3)
doc = []
for i in range(400):
    body = "\n".join("".join(r.choice(string.ascii_letters + "  ") for _ in range(100)) for _ in range(50))
    doc.append(f'[doc_{i}]\ntext = """\n{body}\n"""\nraw = \'\'\'\n{body}\n\'\'\'\n')
w("multiline.toml", "\n".join(doc))

# 4. huge array of tables (Cargo.lock-like: 30k [[package]] entries)
r = random.Random(4)
pk = []
for i in range(30000):
    deps = ", ".join(f'"dep-{r.randrange(30000)} 0.{r.randrange(50)}.{r.randrange(20)}"' for _ in range(r.randrange(0, 6)))
    pk.append(f'[[package]]\nname = "crate-{i}"\nversion = "0.{r.randrange(50)}.{r.randrange(20)}"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\nchecksum = "{r.getrandbits(256):064x}"\ndependencies = [{deps}]\n')
w("cargo_lock.toml", "version = 3\n\n" + "\n".join(pk))

# 5. wide flat table: 100k keys (feature flags / i18n catalog)
r = random.Random(5)
w("wide.toml", "".join(f"flag_{i:06d}_{r.getrandbits(24):06x} = {r.randrange(10**9)}\n" for i in range(100000)))

# 6. array of 50k small inline tables (data rows)
r = random.Random(6)
w("inline_rows.toml", "rows = [\n" + "".join(f'  {{ id = {i}, name = "n{i}", ok = {str(i % 2 == 0).lower()}, w = {i}.5 }},\n' for i in range(50000)) + "]\n")

# 7. many small files (monorepo with 5000 tiny pion.toml / Cargo.toml manifests)
small_dir = os.path.join(out, "small")
os.makedirs(small_dir, exist_ok=True)
r = random.Random(7)
paths = []
for i in range(5000):
    p = os.path.join(small_dir, f"m{i:05d}.toml")
    with open(p, "w") as f:
        f.write(f'[package]\nname = "pkg{i}"\nversion = "0.{i % 50}.0"\nedition = "2021"\n\n[dependencies]\n' +
                "".join(f'dep{d} = {{ version = "1.{r.randrange(9)}", features = ["std"] }}\n' for d in r.sample(range(500), r.randrange(1, 8))))
    paths.append(p)
w("small_list.txt", "\n".join(paths) + "\n")

# 8. deep-but-legal nesting (60 levels) repeated: Kubernetes-ish configs as dotted headers
rows = []
for i in range(3000):
    rows.append("[" + ".".join(f"l{j}" for j in range(i % 60 + 1)) + f".leaf{i}]\nv = {i}\n")
w("deep_headers.toml", "\n".join(rows))
print("ok", out)
