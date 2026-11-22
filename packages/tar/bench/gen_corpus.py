#!/usr/bin/env python3
"""Generate a deterministic 2,000-entry mixed USTAR + PAX + GNU TAR corpus for benchmarking."""

import io
import os
import sys
import tarfile


def make_payload(idx: int, size: int) -> bytes:
    # Deterministic pseudo-random printable/binary payload
    seed = (idx * 2654435761 + 17) & 0xFFFFFFFF
    buf = bytearray(size)
    for i in range(size):
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        buf[i] = (seed >> 16) & 0xFF
    return bytes(buf)


def generate(out_path: str, count: int = 2000) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    # Build segments in USTAR, PAX, and GNU formats, then concatenate (stripping intermediate EOF zero blocks)
    chunks = []

    def emit_one(fmt: int, setup_fn):
        bio = io.BytesIO()
        with tarfile.open(fileobj=bio, mode="w", format=fmt) as tf:
            setup_fn(tf)
        raw = bio.getvalue()
        # Python tarfile pads to 10 KiB record boundary with trailing zero blocks; strip trailing 512B zero blocks
        end = len(raw)
        while end >= 512 and raw[end - 512 : end] == b"\x00" * 512:
            end -= 512
        chunks.append(raw[:end])

    for i in range(count):
        mod = i % 20
        if mod < 12:
            # 60%: USTAR regular files & directories & symlinks
            if mod == 11:
                def _dir(tf, idx=i):
                    ti = tarfile.TarInfo(name=f"pkg/mod_{idx // 20:03d}/dir_{idx:04d}/")
                    ti.type = tarfile.DIRTYPE
                    ti.mode = 0o755
                    ti.uid = 1000
                    ti.gid = 1000
                    ti.uname = "builder"
                    ti.gname = "staff"
                    ti.mtime = 1700000000 + idx
                    tf.addfile(ti)
                emit_one(tarfile.USTAR_FORMAT, _dir)
            elif mod == 10:
                def _sym(tf, idx=i):
                    ti = tarfile.TarInfo(name=f"pkg/mod_{idx // 20:03d}/link_{idx:04d}")
                    ti.type = tarfile.SYMTYPE
                    ti.linkname = f"file_{idx - 1:04d}.dat"
                    ti.mode = 0o777
                    ti.uid = 1000
                    ti.gid = 1000
                    ti.uname = "builder"
                    ti.gname = "staff"
                    ti.mtime = 1700000000 + idx
                    tf.addfile(ti)
                emit_one(tarfile.USTAR_FORMAT, _sym)
            else:
                sz = 256 + ((i * 397) % 3072)
                payload = make_payload(i, sz)
                def _ustar(tf, idx=i, data=payload):
                    ti = tarfile.TarInfo(name=f"pkg/mod_{idx // 20:03d}/src/file_{idx:04d}.dat")
                    ti.size = len(data)
                    ti.mode = 0o644
                    ti.uid = 1000
                    ti.gid = 1000
                    ti.uname = "builder"
                    ti.gname = "staff"
                    ti.mtime = 1700000000 + idx
                    tf.addfile(ti, io.BytesIO(data))
                emit_one(tarfile.USTAR_FORMAT, _ustar)
        elif mod < 17:
            # 25%: PAX long paths (>150 B) + UTF-8 + custom PAX xattr
            sz = 512 + ((i * 613) % 4096)
            payload = make_payload(i, sz)
            long_name = (
                f"workspace/services/telemetry_cluster_v4/shards/region_ap_northeast_1/"
                f"partition_{i // 10:04d}/sub_component_alpha_beta_gamma/artifact_日本_{i:05d}.bin"
            )
            def _pax(tf, idx=i, name=long_name, data=payload):
                ti = tarfile.TarInfo(name=name)
                ti.size = len(data)
                ti.mode = 0o644
                ti.uid = 2500000 + idx
                ti.gid = 1000
                ti.uname = "pax_user"
                ti.gname = "pax_group"
                ti.mtime = 1700000000 + idx
                ti.pax_headers = {"SCHILY.xattr.user.bench": f"v{idx}"}
                tf.addfile(ti, io.BytesIO(data))
            emit_one(tarfile.PAX_FORMAT, _pax)
        else:
            # 15%: GNU LongName (>120 B)
            sz = 512 + ((i * 521) % 3584)
            payload = make_payload(i, sz)
            gnu_name = (
                f"gnu_archive/deep_hierarchy/segment_0001/segment_0002/segment_0003/"
                f"segment_0004/segment_0005/long_gnu_entry_{i:05d}.blob"
            )
            def _gnu(tf, idx=i, name=gnu_name, data=payload):
                ti = tarfile.TarInfo(name=name)
                ti.size = len(data)
                ti.mode = 0o644
                ti.uid = 1000
                ti.gid = 1000
                ti.uname = "gnu_user"
                ti.gname = "gnu_group"
                ti.mtime = 1700000000 + idx
                tf.addfile(ti, io.BytesIO(data))
            emit_one(tarfile.GNU_FORMAT, _gnu)

    # Final two 512-byte zero blocks (standard TAR EOF)
    chunks.append(b"\x00" * 1024)
    full = b"".join(chunks)
    with open(out_path, "wb") as f:
        f.write(full)
    print(f"Generated {out_path}: {count} entries, {len(full)} bytes", file=sys.stderr)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-tar-bench/corpus_2000.tar"
    cnt = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
    generate(out, cnt)
