#!/usr/bin/env python3
"""Generate a realistic ~200 KB TOML v1.0.0 workspace & service config corpus."""

import os
import sys


def generate(out_path: str, sections: int = 240) -> int:
    lines = [
        "# Realistic monorepo workspace + service configuration corpus (TOML v1.0.0)",
        'schema_version = "1.0.0"',
        "generated_at = 2026-11-22T12:34:56.789Z",
        "release_date = 2026-11-22",
        "maintenance_window = 03:30:00",
        "max_workers = 64",
        "timeout_ratio = 1.75",
        "strict_mode = true",
        "",
        "[workspace]",
        'resolver = "2"',
        'name = "pion-ecosystem"',
        "members = [",
    ]
    for i in range(sections):
        lines.append(f'  "crates/svc-{i:03d}",')
    lines.append("]")
    lines.append("")
    lines.append("[workspace.package]")
    lines.append('edition = "2024"')
    lines.append('license = "MIT OR Apache-2.0"')
    lines.append('repository = "https://github.com/AFK-surf/pion-packages"')
    lines.append('authors = ["Pion Core Team <core@pion.dev>", "Systems Group <sys@pion.dev>"]')
    lines.append("")
    lines.append("[workspace.dependencies]")
    for i in range(sections):
        feat_a = f"feat-{i % 7}"
        feat_b = f"codec-{(i * 3) % 11}"
        opt = "true" if (i % 4 == 0) else "false"
        lines.append(
            f'dep_{i:03d} = {{ version = "{1 + (i % 5)}.{(i * 7) % 20}.{i % 13}", '
            f'features = ["{feat_a}", "{feat_b}"], optional = {opt}, priority = {100 + i} }}'
        )
    lines.append("")

    for i in range(sections):
        lines.append(f"[services.svc_{i:03d}]")
        lines.append(f'name = "service-{i:03d}"')
        lines.append(f'endpoint = "https://svc-{i:03d}.internal.example.com:8443/v1/api"')
        lines.append(f"port = {8000 + i}")
        lines.append(f"weight = {(i % 100) + 0.25}")
        lines.append(f"enabled = {'true' if i % 3 != 0 else 'false'}")
        lines.append(f"updated_at = 2026-0{(i % 9) + 1}-{(i % 28) + 1:02d}T{(i % 24):02d}:{(i * 5) % 60:02d}:00Z")
        lines.append(f'tags = ["tier-{i % 4}", "region-{i % 6}", "lang-pion"]')
        lines.append(f'notes = "Service #{i} handles \\"batch\\" payloads\\twith retries."')
        lines.append("")
        lines.append(f"[services.svc_{i:03d}.limits]")
        lines.append(f"max_conns = {1024 + i * 16}")
        lines.append(f"burst_bytes = {65536 + i * 256}")
        lines.append(f"retry_backoff = {0.125 * ((i % 8) + 1)}")
        lines.append("")
        lines.append("[[routes]]")
        lines.append(f'path = "/api/v1/svc-{i:03d}/items"')
        lines.append(f'target = "svc_{i:03d}"')
        lines.append(f'methods = ["GET", "POST", "PUT"]')
        lines.append(f"cache_ttl = {30 + (i % 120)}")
        lines.append(f"auth_required = {'true' if i % 2 == 0 else 'false'}")
        lines.append("")

    content = "\n".join(lines) + "\n"
    out_dir = os.path.dirname(os.path.abspath(out_path))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(content)
    return len(content.encode("utf-8"))


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-toml-bench/corpus.toml"
    sec = int(sys.argv[2]) if len(sys.argv) > 2 else 240
    nbytes = generate(out, sec)
    print(f"Generated {out} ({nbytes} bytes, {sec} services/routes)")
