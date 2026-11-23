#!/usr/bin/env python3
"""Deterministic benchmark corpus generator for packages/kdl."""
import sys


def gen_w1(path: str, sections: int = 800) -> None:
    """Generate ~2.5 MB realistic Zellij / Niri / build-manifest KDL v2 corpus."""
    parts = [
        "// Large realistic KDL v2 configuration corpus (Zellij / Niri / Manifest style)\n",
        "workspace \"pion-cloud-prod\" edition=\"2026\" strict=#true {\n",
    ]
    for i in range(sections):
        port = 8000 + (i % 1000)
        weight = 10 + (i % 90)
        ratio = f"{(i % 100) / 100.0:.2f}"
        tls = "#true" if (i % 2 == 0) else "#false"
        parts.append(
            f"    // Service section {i}\n"
            f"    (svc)service \"svc-{i:04d}\" host=\"10.0.{i // 256}.{i % 256}\" port={port} tls={tls} ratio={ratio} weight={weight} {{\n"
            f"        layout \"split-horizontal\" borderless=#false focus=#true {{\n"
            f"            pane name=\"logs-{i}\" command=\"tail\" split=\"vertical\" size=40 {{\n"
            f"                args \"-f\" \"/var/log/svc-{i:04d}/access.log\" \"--lines=200\"\n"
            f"                env \"RUST_LOG\" \"info,svc=debug\" level=3\n"
            f"            }}\n"
            f"            pane name=\"metrics-{i}\" command=\"prom-exporter\" size=60 {{\n"
            f"                endpoint \"http://127.0.0.1:{port}/metrics\" timeout=5000 retries=3\n"
            f"                tags \"prod\" \"region-ap-{i % 4}\" \"tier-{i % 3}\" enabled=#true\n"
            f"            }}\n"
            f"        }}\n"
            f"        keybinds clear-defaults=#false {{\n"
            f"            bind \"Mod+{i % 9 + 1}\" \"focus-workspace\" {i % 9 + 1} repeat=#false\n"
            f"            bind \"Mod+Shift+{i % 9 + 1}\" \"move-column-to-workspace\" {i % 9 + 1}\n"
            f"        }}\n"
            f"        limits max-conns={1000 + i * 2} max-mem=536870912 timeout-ms=30000 fallback=#null\n"
            f"    }}\n"
        )
    parts.append("}\n")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(parts))


def gen_w2(path: str, blocks: int = 80) -> None:
    """Generate deeply nested + multiline/raw strings + type annotations + slashdash mixed KDL v2 doc."""
    parts = ["// Mixed KDL v2 document for parse + format + re-parse roundtrip\n"]
    for i in range(blocks):
        parts.append(
            f"/- commented_out_block_{i} 1 2 3 {{\n"
            f"    ignored \"payload\" key=#true\n"
            f"}}\n"
            f"(bundle)pipeline \"pipe-{i:03d}\" version=(u16){i + 1} active=#true ratio={(i % 50) * 0.25:.2f} {{\n"
            f"    /- skip_arg \"nope\"\n"
            f"    script \"\"\"\n"
            f"        #!/bin/sh\n"
            f"        echo \"running pipeline {i}\"\n"
            f"          indented line {i}\n"
            f"        \"\"\"\n"
            f"    regex #\"^[a-z0-9_\\-]+\\.{i}$\"#\n"
            f"    raw_doc #\"\"\"\n"
            f"        raw \\n \\u{{41}} \"quotes\" #{i}\n"
            f"        \"\"\"#\n"
            f"    stage \"build\" timeout=(u32)120 {{\n"
            f"        step \"compile\" /- deprecated=#true flags=\"-O2\" {{\n"
            f"            step \"link\" target=\"wasm32\" {{\n"
            f"                step \"verify\" checksum=0xdead_beef expected=#true limit=#inf\n"
            f"            }}\n"
            f"        }}\n"
            f"    }}\n"
            f"}}\n"
        )
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(parts))


def gen_w3(path: str) -> None:
    """Generate small realistic plugin/microservice config snippet for high-frequency hot-reload."""
    snippet = (
        "// Microservice plugin hot-reload config\n"
        "(plugin)service \"auth-edge\" version=\"2.4.1\" enabled=#true {\n"
        "    listen \"0.0.0.0\" port=8443 tls=#true\n"
        "    route \"/v1/login\" method=\"POST\" rate-limit=120 auth=#false\n"
        "    route \"/v1/token\" method=\"POST\" rate-limit=600 auth=#true\n"
        "    route \"/v1/health\" method=\"GET\" rate-limit=1000 auth=#false\n"
        "    upstream \"identity-core\" host=\"10.12.0.5\" port=9000 weight=100\n"
        "    upstream \"identity-backup\" host=\"10.12.0.6\" port=9000 weight=25\n"
        "}\n"
    )
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(snippet)


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "w1":
        gen_w1(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 800)
    elif mode == "w2":
        gen_w2(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 80)
    elif mode == "w3":
        gen_w3(sys.argv[2])
    else:
        raise SystemExit(f"unknown mode: {mode}")
