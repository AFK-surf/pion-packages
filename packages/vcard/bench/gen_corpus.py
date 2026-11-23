#!/usr/bin/env python3
"""Deterministic corpus generator for packages/vcard head-to-head benchmarks (W1, W2, W3)."""

import base64
import os
import sys


def fold_75(line: str) -> str:
    b = line.encode("utf-8")
    if len(b) <= 75:
        return line
    out = bytearray()
    pos = 0
    first = True
    while pos < len(b):
        limit = 75 if first else 74
        if not first:
            out.extend(b"\r\n ")
        end = min(pos + limit, len(b))
        if end < len(b):
            while end > pos and (b[end] & 0xC0) == 0x80:
                end -= 1
            if end == pos:
                end = pos + 1
        out.extend(b[pos:end])
        pos = end
        first = False
    return out.decode("utf-8")


def make_w1_enterprise(count: int = 4000) -> str:
    """W1: 4,000-card enterprise directory (vCard 4.0/3.0, folded UTF-8 CJK/Emoji, ADR/TEL/EMAIL/ORG, RFC 6868)."""
    depts = ["Core Systems", "Platform Engineering", "Distributed Storage", "Compiler Team", "Security"]
    cities = [
        ("Tokyo", "Tokyo", "100-0001", "Japan"),
        ("San Francisco", "CA", "94105", "USA"),
        ("Shanghai", "Shanghai", "200000", "China"),
        ("Berlin", "BE", "10115", "Germany"),
        ("London", "LDN", "EC2A 3AY", "UK"),
    ]
    cjk_names = ["山田太郎", "张三丰", "李明华", "佐藤花子", "王伟杰"]
    lines = []
    for i in range(count):
        ver = "4.0" if (i % 4 != 3) else "3.0"
        dept = depts[i % len(depts)]
        city, region, postal, country = cities[i % len(cities)]
        cjk = cjk_names[i % len(cjk_names)]
        fam = f"User{i:04d}"
        giv = f"Alice{i % 97}"
        fn = f"{cjk} {giv} {fam} 🚀 #{i}"
        lines.append("BEGIN:VCARD")
        lines.append(f"VERSION:{ver}")
        lines.append(f"UID:urn:uuid:10000000-0000-4000-8000-{i:012d}")
        lines.append(fold_75(f"FN:{fn}"))
        lines.append(f"N:{fam};{giv};Mid{i % 13};Dr.;")
        lines.append(fold_75(f"ORG:Acme\\, Corp.;{dept};Unit-{i % 17}"))
        lines.append(
            fold_75(
                f"ADR;TYPE=work;PREF=1;LABEL=\"Suite {i % 500}^n{city} {postal}\":;;{100 + (i % 900)} Main St;{city};{region};{postal};{country}"
            )
        )
        lines.append(f"TEL;TYPE=work,voice;PREF=1:+1-415-555-{i % 10000:04d}")
        lines.append(f"TEL;TYPE=cell:+81-90-{(i * 7) % 10000:04d}-{i % 10000:04d}")
        lines.append(f"EMAIL;TYPE=work;PREF=1:user{i:04d}@corp.example.com")
        lines.append(f"EMAIL;TYPE=home:personal{i:04d}@mail.example.org")
        lines.append(fold_75(f"NOTE:企业通讯录备注 {cjk} 负责 {dept} 架构与跨区协作项目编号 {i:04d} 🎯"))
        lines.append("END:VCARD")
    return "\r\n".join(lines) + "\r\n"


def make_w2_roundtrip(count: int = 2000) -> str:
    """W2: 2,000-card structured directory for parse + field extraction + 75-octet folded roundtrip."""
    return make_w1_enterprise(count)


def make_w3_escaped_binary(count: int = 1000) -> str:
    """W3: 1,000-card high escape density + Base64 inline avatars (data: URI and vCard 3.0 ENCODING=b)."""
    lines = []
    for i in range(count):
        # Deterministic 240-byte synthetic PNG-like payload per card
        raw_img = bytes([(i * 31 + j * 17) & 0xFF for j in range(240)])
        b64 = base64.b64encode(raw_img).decode("ascii")
        lines.append("BEGIN:VCARD")
        if i % 2 == 0:
            lines.append("VERSION:4.0")
            lines.append(fold_75(f"FN:O'Connor\\, Alice #{i} (\\\\dev\\\\ops)\\nLead"))
            lines.append(f"N:O\\;Connor;Alice;;Dr.;Jr.")
            lines.append(fold_75(f"ORG:Alpha\\, Beta \\; Gamma Inc.;R\\;D Lab;Team\\, {i % 9}"))
            lines.append(
                fold_75(
                    f"ADR;TYPE=work;LABEL=\"Bldg ^'A^'^^2^nRoom {i}\\, Floor 3\":;Suite {i}\\; West;100 Pine\\, Ave.;Tokyo;JP;100-0001;Japan"
                )
            )
            lines.append(fold_75(f"NOTE:Escaped\\, comma\\\\ backslash\\nLine 2\\nLine 3 #{i}"))
            lines.append(fold_75(f"PHOTO:data:image/png;base64,{b64}"))
        else:
            lines.append("VERSION:3.0")
            lines.append(fold_75(f"FN:Smith\\, Bob #{i} (QA)"))
            lines.append(f"N:Smith\\;Jr;Bob;;;")
            lines.append(fold_75(f"ORG:Delta\\, LLC;QA\\;Release"))
            lines.append(fold_75(f"NOTE:vCard3\\, note\\\\ with escapes\\nsecond line #{i}"))
            lines.append(fold_75(f"PHOTO;ENCODING=b;TYPE=PNG:{b64}"))
        lines.append(f"EMAIL;TYPE=work:esc{i:04d}@example.com")
        lines.append("END:VCARD")
    return "\r\n".join(lines) + "\r\n"


def main() -> None:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/w16-vcard-bench"
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "w1_enterprise_4k.vcf"), "w", encoding="utf-8", newline="") as f:
        f.write(make_w1_enterprise(4000))
    with open(os.path.join(out_dir, "w2_roundtrip_2k.vcf"), "w", encoding="utf-8", newline="") as f:
        f.write(make_w2_roundtrip(2000))
    with open(os.path.join(out_dir, "w3_escaped_binary_1k.vcf"), "w", encoding="utf-8", newline="") as f:
        f.write(make_w3_escaped_binary(1000))


if __name__ == "__main__":
    main()
