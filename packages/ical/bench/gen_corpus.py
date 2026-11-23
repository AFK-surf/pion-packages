#!/usr/bin/env python3
"""Generate deterministic iCalendar / RRULE / RRuleSet benchmark corpora."""
import os
import sys

def gen_enterprise_ics(path: str, num_events: int = 4000) -> None:
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Pion//iCal Benchmark Corpus//EN",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
    ]
    for i in range(num_events):
        year = 2025 + (i // 365) % 4
        month = (i % 12) + 1
        day = (i % 28) + 1
        hour = 8 + (i % 10)
        dtstart = f"{year:04d}{month:02d}{day:02d}T{hour:02d}0000Z"
        dtend = f"{year:04d}{month:02d}{day:02d}T{hour + 1:02d}0000Z"
        lines.append("BEGIN:VEVENT")
        lines.append(f"UID:bench-evt-{i:06d}@pion.dev")
        lines.append(f"DTSTAMP:20260101T000000Z")
        lines.append(f"DTSTART:{dtstart}")
        lines.append(f"DTEND:{dtend}")
        lines.append(f"SUMMARY:Sprint Review #{i}\\, Team {i % 7}; 架构同步与里程碑评审")
        # Intentionally folded long description (RFC 5545 §3.1)
        lines.append(
            f"DESCRIPTION:Quarterly planning session {i} covering RFC 5545 parser\r\n"
            f"  throughput\\, line folding\\; and RRULE recurrence expansion across\r\n"
            f"  multiple timezones\\nAction items tracked in board #{i % 97}."
        )
        lines.append(f"LOCATION:Building {(i % 5) + 1}\\, Room {100 + (i % 40)}")
        lines.append("STATUS:CONFIRMED")
        if i % 3 == 0:
            lines.append("BEGIN:VALARM")
            lines.append("ACTION:DISPLAY")
            lines.append("TRIGGER:-PT15M")
            lines.append("DESCRIPTION:Upcoming meeting reminder")
            lines.append("END:VALARM")
        lines.append("END:VEVENT")
    lines.append("END:VCALENDAR")
    content = "\r\n".join(lines) + "\r\n"
    with open(path, "wb") as f:
        f.write(content.encode("utf-8"))

def gen_rrule_suite(path: str) -> None:
    # Format: DTSTART|RRULE|LIMIT
    specs = [
        ("19970929T090000Z", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-2;COUNT=1000", 1000),
        ("19970805T090000Z", "FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,TH,SU;COUNT=1000", 1000),
        ("20000101T090000Z", "FREQ=MONTHLY;BYDAY=1MO,-1FR;COUNT=1000", 1000),
        ("20000131T090000Z", "FREQ=YEARLY;BYMONTH=1,4,7,10;BYMONTHDAY=-1;COUNT=400", 400),
        ("19970101T090000Z", "FREQ=YEARLY;BYYEARDAY=1,100,200,-1;COUNT=400", 400),
        ("19970101T090000Z", "FREQ=YEARLY;BYWEEKNO=1,20,52;BYDAY=MO,FR;COUNT=400", 400),
        ("20200101T090000Z", "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;COUNT=1500", 1500),
        ("20200229T090000Z", "FREQ=YEARLY;COUNT=100", 100),
    ]
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for _ in range(10):
            for dtstart, rrule, limit in specs:
                f.write(f"{dtstart}|{rrule}|{limit}\n")

def gen_rruleset_suite(path: str, count: int = 200) -> None:
    # Format: DTSTART|RRULE1|RRULE2|RDATE_CSV|EXDATE_CSV|WIN_START|WIN_END
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for i in range(count):
            day = (i % 20) + 1
            hour = 8 + (i % 10)
            dtstart = f"202401{day:02d}T{hour:02d}0000Z"
            r1 = "FREQ=WEEKLY;BYDAY=MO,WE,FR"
            r2 = "FREQ=MONTHLY;BYDAY=1TU,-1TH"
            rdates = (
                f"20250215T{hour:02d}0000Z,20250615T{hour:02d}0000Z,"
                f"20260315T{hour:02d}0000Z,20260915T{hour:02d}0000Z"
            )
            exdates = (
                f"20250101T{hour:02d}0000Z,20250704T{hour:02d}0000Z,"
                f"20251225T{hour:02d}0000Z,20260101T{hour:02d}0000Z,"
                f"20260704T{hour:02d}0000Z,20261225T{hour:02d}0000Z"
            )
            f.write(f"{dtstart}|{r1}|{r2}|{rdates}|{exdates}|20250101T000000Z|20261231T235959Z\n")

def main() -> None:
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    gen_enterprise_ics(os.path.join(out_dir, "enterprise_4k.ics"), 4000)
    gen_rrule_suite(os.path.join(out_dir, "rrule_suite.txt"))
    gen_rruleset_suite(os.path.join(out_dir, "rruleset_suite.txt"), 200)

if __name__ == "__main__":
    main()
