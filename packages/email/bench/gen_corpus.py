#!/usr/bin/env python3
"""Deterministic corpus generator for packages/email head-to-head benchmarks."""
import base64
import os
import sys


def gen_w1_emails(out_dir: str) -> None:
    """5,000 realistic multi-part MIME emails (folded headers + RFC 2047 UTF-8 + alternative + QP/Base64 attachment).
    Stored as 250 distinct emails separated by NUL (\\x00); each benchmark loops 20x -> 5,000 parses.
    """
    msgs = []
    for i in range(250):
        att_payload = (f"Attachment binary payload #{i:04d} " + ("0123456789ABCDEF" * 12)).encode("utf-8")
        att_b64 = base64.b64encode(att_payload).decode("ascii")
        subj_utf8 = f"季度通知 #{i:04d} - Project Alpha".encode("utf-8")
        subj_b64 = base64.b64encode(subj_utf8).decode("ascii")
        name_b64 = base64.b64encode(f"用户{i % 25}".encode("utf-8")).decode("ascii")
        b_mix = f"mix-bnd-{i:04d}"
        b_alt = f"alt-bnd-{i:04d}"
        msg = (
            f"From: =?UTF-8?B?{name_b64}?= <user{i}@example.com>\r\n"
            f"To: Alice <alice@example.org>, Bob <bob@example.org>\r\n"
            f"Subject: =?UTF-8?B?{subj_b64}?=\r\n"
            f" (folded continuation {i})\r\n"
            f"Date: Mon, 23 Nov 2026 12:{i % 60:02d}:{(i * 7) % 60:02d} +0800\r\n"
            f"Message-ID: <msg-{i:04d}@bench.example.com>\r\n"
            f"MIME-Version: 1.0\r\n"
            f"Content-Type: multipart/mixed; boundary=\"{b_mix}\"\r\n"
            f"\r\n"
            f"--{b_mix}\r\n"
            f"Content-Type: multipart/alternative; boundary=\"{b_alt}\"\r\n"
            f"\r\n"
            f"--{b_alt}\r\n"
            f"Content-Type: text/plain; charset=utf-8\r\n"
            f"Content-Transfer-Encoding: quoted-printable\r\n"
            f"\r\n"
            f"Hello=20World=20#{i:04d}=20=E4=B8=96=E7=95=8C!\r\n"
            f"--{b_alt}\r\n"
            f"Content-Type: text/html; charset=utf-8\r\n"
            f"Content-Transfer-Encoding: base64\r\n"
            f"\r\n"
            f"{base64.b64encode(f'<html><body><h1>Report #{i:04d}</h1><p>Hello 世界</p></body></html>'.encode('utf-8')).decode('ascii')}\r\n"
            f"--{b_alt}--\r\n"
            f"--{b_mix}\r\n"
            f"Content-Type: application/octet-stream\r\n"
            f"Content-Disposition: attachment; filename=\"report_{i:04d}.bin\"\r\n"
            f"Content-Transfer-Encoding: base64\r\n"
            f"\r\n"
            f"{att_b64}\r\n"
            f"--{b_mix}--\r\n"
        )
        msgs.append(msg.encode("utf-8"))
    with open(os.path.join(out_dir, "w1_emails.bin"), "wb") as f:
        f.write(b"\x00".join(msgs))


def gen_w2_addr_dates(out_dir: str) -> None:
    """500 distinct (address-list, date) pairs separated by TAB; benchmark loops 200x -> 100,000 parses."""
    zones = ["+0800", "-0500", "+0000", "GMT", "-0800", "+0900", "-0400", "-0700", "+0530", "-0000"]
    days = [
        ("Mon", 23, "Nov", 2026),
        ("Tue", 24, "Nov", 2026),
        ("Wed", 25, "Nov", 2026),
        ("Thu", 26, "Nov", 2026),
        ("Fri", 27, "Nov", 2026),
    ]
    lines = []
    for i in range(500):
        wd, dd, mon, yr = days[i % len(days)]
        z = zones[i % len(zones)]
        addr = (
            f"\"Doe, User{i}\" <user{i}@example.com>, "
            f"Alice (team {i % 7}) <alice{i}@corp.example>, "
            f"bob{i}@test.org"
        )
        dt = f"{wd}, {dd:02d} {mon} {yr} {i % 24:02d}:{i % 60:02d}:{(i * 3) % 60:02d} {z}"
        lines.append(f"{addr}\t{dt}")
    with open(os.path.join(out_dir, "w2_addr_dates.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main() -> None:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/w13-email-bench"
    os.makedirs(out_dir, exist_ok=True)
    gen_w1_emails(out_dir)
    gen_w2_addr_dates(out_dir)


if __name__ == "__main__":
    main()
