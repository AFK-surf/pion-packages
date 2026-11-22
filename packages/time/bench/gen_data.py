#!/usr/bin/env python3
"""Deterministic generator for 200,000 diverse RFC 3339 timestamps."""
import datetime
import sys

def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/time-bench-rfc3339.txt"
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 200000
    offsets = [
        ("Z", 0),
        ("+00:00", 0),
        ("-00:00", 0),
        ("+09:00", 9 * 3600),
        ("-05:30", -(5 * 3600 + 30 * 60)),
        ("+05:30", 5 * 3600 + 30 * 60),
        ("-04:00", -4 * 3600),
        ("+14:00", 14 * 3600),
        ("-12:00", -12 * 3600),
        ("+01:00", 3600),
    ]
    fracs = [
        "",
        ".5",
        ".123",
        ".000456",
        ".123456789",
        ".000000001",
        ".999999999",
        ".010",
    ]
    base = datetime.datetime(1950, 1, 1, 0, 0, 0, tzinfo=datetime.timezone.utc)
    state = 123456789
    lines = []
    for i in range(n):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        # Span ~100 years (1950..2050) including pre-1970 and leap days
        sec_off = state % (100 * 365 * 86400)
        dt = base + datetime.timedelta(seconds=sec_off)
        off_str, _ = offsets[i % len(offsets)]
        frac_str = fracs[(i // 3) % len(fracs)]
        lines.append(
            f"{dt.year:04d}-{dt.month:02d}-{dt.day:02d}T"
            f"{dt.hour:02d}:{dt.minute:02d}:{dt.second:02d}{frac_str}{off_str}\n"
        )
    with open(out_path, "w", encoding="utf-8") as f:
        f.writelines(lines)

if __name__ == "__main__":
    main()
