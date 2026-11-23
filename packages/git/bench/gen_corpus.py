#!/usr/bin/env python3
"""Generate deterministic real `git` CLI benchmark corpora for packages/git.

Outputs into <out_dir>:
  - w1.pack             : Real git Packfile v2 (~40 commits, ~500 objects, rich OFS_DELTA chains)
  - w2_objects.bundle   : Binary bundle of 200 large Trees (150 entries each) + 2,000 Commits
  - w3_index_v2.bin     : Real git CLI `.git/index` v2 (2,000 tracked files)
  - w3_index_v4.bin     : Real git CLI `.git/index` v4 (2,000 tracked files, prefix-compressed)
  - w3_pktline.bin      : 10,000-frame `pkt-line` stream (ref ads + sideband chunks)
"""
import hashlib
import os
import shutil
import struct
import subprocess
import sys


def git(repo, env, *args):
    return subprocess.check_output(["git", "-C", repo, *args], env=env, stderr=subprocess.DEVNULL)


def make_w1_pack(out_dir):
    repo = os.path.join(out_dir, "repo_w1")
    if os.path.exists(repo):
        shutil.rmtree(repo)
    os.makedirs(repo)
    env = os.environ.copy()
    env.update({
        "GIT_AUTHOR_NAME": "Bench Author",
        "GIT_AUTHOR_EMAIL": "bench@example.com",
        "GIT_COMMITTER_NAME": "Bench Committer",
        "GIT_COMMITTER_EMAIL": "bench@example.com",
    })
    git(repo, env, "init", "-b", "main")
    # Create 20 medium files (~8 KiB each) and evolve them across 35 commits so git repack builds deep OFS_DELTA chains
    for d in ["src", "lib", "docs", "tests"]:
        os.makedirs(os.path.join(repo, d), exist_ok=True)
    files = [
        f"{['src', 'lib', 'docs', 'tests'][i % 4]}/module_{i:02d}.txt"
        for i in range(20)
    ]
    base_lines = [f"line_{k:04d}: deterministic payload content for git packfile delta benchmark\n" for k in range(120)]
    for c in range(35):
        ts = str(1700000000 + c * 3600)
        env["GIT_AUTHOR_DATE"] = f"{ts} +0000"
        env["GIT_COMMITTER_DATE"] = f"{ts} +0000"
        # Modify 5 files per commit
        for m in range(5):
            idx = (c * 3 + m) % len(files)
            fpath = os.path.join(repo, files[idx])
            lines = list(base_lines)
            lines[(c * 7 + m * 11) % len(lines)] = f"commit_{c:03d}_edit_{m}: changed content hash={idx * 31 + c}\n"
            lines.append(f"trailing commit {c} file {idx}\n")
            with open(fpath, "w", encoding="utf-8") as f:
                f.writelines(lines)
        git(repo, env, "add", ".")
        git(repo, env, "commit", "-m", f"Benchmark commit #{c:03d}\n\nDetailed commit body for round {c}.")
    git(repo, env, "repack", "-a", "-d", "--window=50", "--depth=20")
    pack_dir = os.path.join(repo, ".git", "objects", "pack")
    pack_name = [f for f in os.listdir(pack_dir) if f.endswith(".pack")][0]
    pack_dst = os.path.join(out_dir, "w1.pack")
    shutil.copyfile(os.path.join(pack_dir, pack_name), pack_dst)
    shutil.rmtree(repo)
    return os.path.getsize(pack_dst)


def make_w2_bundle(out_dir):
    # Format:
    #   u32 tree_count
    #   for each tree: u32 byte_len + raw tree bytes (unsorted? NO, canonical sorted raw tree bytes)
    #   u32 commit_count
    #   for each commit: u32 byte_len + raw commit bytes
    num_trees = 200
    entries_per_tree = 150
    num_commits = 2000

    buf = bytearray()
    buf += struct.pack(">I", num_trees)
    for t in range(num_trees):
        entries = []
        for e in range(entries_per_tree):
            is_dir = (e % 5 == 0)
            if is_dir:
                name = f"dir_{e:03d}"
                mode = b"40000"
                sort_key = (name + "/").encode()
            else:
                # Include names like dir_005-file to exercise Git tree sorting!
                name = f"dir_{e:03d}-file.txt" if (e % 5 == 1) else f"file_{e:03d}.rs"
                mode = b"100755" if (e % 7 == 0) else b"100644"
                sort_key = name.encode()
            oid = hashlib.sha1(f"tree-{t}-entry-{e}".encode()).digest()
            entries.append((sort_key, mode, name.encode(), oid))
        entries.sort(key=lambda x: x[0])
        raw = bytearray()
        for _, mode, name_b, oid in entries:
            raw += mode + b" " + name_b + b"\x00" + oid
        buf += struct.pack(">I", len(raw))
        buf += raw

    buf += struct.pack(">I", num_commits)
    for c in range(num_commits):
        tree_hex = hashlib.sha1(f"t-{c}".encode()).hexdigest()
        p1_hex = hashlib.sha1(f"p1-{c}".encode()).hexdigest()
        p2_hex = hashlib.sha1(f"p2-{c}".encode()).hexdigest()
        lines = [
            f"tree {tree_hex}",
            f"parent {p1_hex}",
        ]
        if c % 4 == 0:
            lines.append(f"parent {p2_hex}")
        lines.append(f"author Dev User {c % 10} <dev{c % 10}@example.com> {1700000000 + c * 60} +0800")
        lines.append(f"committer CI Bot <ci@example.com> {1700000030 + c * 60} -0500")
        if c % 5 == 0:
            lines.append("encoding UTF-8")
            lines.append("gpgsig -----BEGIN PGP SIGNATURE-----")
            lines.append(" ")
            lines.append(f" iQIzBAABCAAdFiEE{c:08x}testsignatureline")
            lines.append(" -----END PGP SIGNATURE-----")
        lines.append("")
        lines.append(f"feat(core): benchmark commit {c}\n\nLine 2 of commit message #{c}.\n")
        raw = "\n".join(lines).encode("utf-8")
        buf += struct.pack(">I", len(raw))
        buf += raw

    dst = os.path.join(out_dir, "w2_objects.bundle")
    with open(dst, "wb") as f:
        f.write(buf)
    return len(buf)


def make_w3_index_and_pktline(out_dir):
    repo = os.path.join(out_dir, "repo_w3")
    if os.path.exists(repo):
        shutil.rmtree(repo)
    os.makedirs(repo)
    env = os.environ.copy()
    git(repo, env, "init", "-b", "main")
    # Create 2,000 files across nested directories
    for d in range(20):
        ddir = os.path.join(repo, f"packages/mod_{d:02d}/src")
        os.makedirs(ddir, exist_ok=True)
        for fidx in range(100):
            with open(os.path.join(ddir, f"file_{fidx:03d}.pion"), "wb") as f:
                f.write(f"// mod {d} file {fidx}\n".encode())
    git(repo, env, "add", ".")
    idx_v2_dst = os.path.join(out_dir, "w3_index_v2.bin")
    shutil.copyfile(os.path.join(repo, ".git", "index"), idx_v2_dst)
    git(repo, env, "update-index", "--index-version", "4")
    idx_v4_dst = os.path.join(out_dir, "w3_index_v4.bin")
    shutil.copyfile(os.path.join(repo, ".git", "index"), idx_v4_dst)
    shutil.rmtree(repo)

    # Generate 10,000 pkt-line frames (5,000 ref ads + 5,000 sideband data frames)
    pkt = bytearray()
    for i in range(5000):
        oid_hex = hashlib.sha1(f"ref-{i}".encode()).hexdigest()
        payload = f"{oid_hex} refs/heads/branch_{i:04d}\n".encode()
        pkt += f"{len(payload) + 4:04x}".encode() + payload
    pkt += b"0000"
    for i in range(4998):
        payload = b"\x01" + f"PACK_CHUNK_{i:05d}_0123456789abcdef0123456789abcdef".encode()
        pkt += f"{len(payload) + 4:04x}".encode() + payload
    pkt += b"0000"
    pkt_dst = os.path.join(out_dir, "w3_pktline.bin")
    with open(pkt_dst, "wb") as f:
        f.write(pkt)
    return os.path.getsize(idx_v2_dst), os.path.getsize(idx_v4_dst), len(pkt)


def main():
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    w1_sz = make_w1_pack(out_dir)
    w2_sz = make_w2_bundle(out_dir)
    v2_sz, v4_sz, pkt_sz = make_w3_index_and_pktline(out_dir)
    print(f"w1_pack={w1_sz} w2_bundle={w2_sz} w3_idx_v2={v2_sz} w3_idx_v4={v4_sz} w3_pkt={pkt_sz}")


if __name__ == "__main__":
    main()
