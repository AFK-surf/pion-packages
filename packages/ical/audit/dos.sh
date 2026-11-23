#!/bin/sh
# DoS / complexity probes. usage: dos.sh <pion_driver> <rust_ref> <python-with-dateutil>
set -u
PION=$1; RUST=$2; PY=$3
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
W=/tmp/rt-ical-work/dos; mkdir -p "$W"
H=$(seq -s, 0 23 | sed 's/,$//'); M=$(seq -s, 0 59 | sed 's/,$//')

measure() { # label cmd...
  label=$1; shift
  out=$( { /usr/bin/time -l timeout 300 "$@" > "$W/out.txt" 2> "$W/err.txt"; } 2>&1; tail -n 40 "$W/err.txt")
  real=$(printf '%s\n' "$out" | awk '/ real /{print $1}' | head -1)
  rss=$(printf '%s\n' "$out" | awk '/maximum resident/{printf "%.1f", $1/1048576}' | head -1)
  printf '  %-12s real=%6ss  peakRSS=%8s MiB  -> %s\n' "$label" "$real" "$rss" "$(head -c 60 "$W/out.txt")"
}

rule3() { # label dtstart rule limit
  echo "$2|$3|$4" > "$W/rule.txt"
  echo "[$1] $3" | cut -c1-140
  measure pion "$PION" time "$2" "$3" "$4"
  measure rust "$RUST" "$W/rule.txt"
  measure dateutil "$PY" "$AUDIT_DIR/diff/ref_dateutil.py" "$W/rule.txt"
}

echo "== D1 timeset explosion: per-period candidate materialisation (COUNT=1) =="
rule3 D1a 20250101T000000 "FREQ=YEARLY;BYDAY=MO,TU,WE,TH,FR,SA,SU;BYHOUR=$H;BYMINUTE=$M;BYSECOND=$M;COUNT=1" 1
rule3 D1b 20250101T000000 "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR,SA,SU;BYHOUR=$H;BYMINUTE=$M;BYSECOND=$M;COUNT=1" 1
rule3 D1c 20250101T000000 "FREQ=YEARLY;BYDAY=MO,TU,WE,TH,FR,SA,SU;BYHOUR=$H;BYMINUTE=$M;BYSECOND=$M;BYSETPOS=1;COUNT=1" 1

echo "== D2 unsatisfiable / sparse sub-daily rules (README: 'terminate safely') =="
rule3 D2a 20250101T000000 "FREQ=SECONDLY;BYMONTH=2;BYMONTHDAY=30" 1
rule3 D2b 20250301T000000 "FREQ=SECONDLY;BYMONTH=2;COUNT=1" 1
rule3 D2c 20250101T000000 "FREQ=DAILY;BYMONTH=2;BYMONTHDAY=30" 1

echo "== D3 VTIMEZONE observance RRULE evaluated from its DTSTART on every offset_at() call =="
mk() { printf 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTIMEZONE\r\nTZID:Evil\r\nBEGIN:STANDARD\r\nDTSTART:%s\r\nRRULE:%s\r\nTZOFFSETFROM:-0400\r\nTZOFFSETTO:-0500\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\nEND:VCALENDAR\r\n' "$1" "$2" > "$3"; }
mk 16010101T020000 "FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU" "$W/ms1601.ics"
mk 20250101T000000 "FREQ=SECONDLY" "$W/sec1y.ics"
mk 20200101T000000 "FREQ=SECONDLY" "$W/sec5y.ics"
for f in ms1601 sec1y sec5y; do
  echo "[D3 $f] $(wc -c < "$W/$f.ics" | tr -d ' ') bytes, offset_at(2025-06-01)"
  measure pion "$PION" vtz "$W/$f.ics" 20250601T000000
done

echo "== D4 parser linearity (events/s should stay flat as input grows) =="
for n in 2000 8000 32000; do
  python3 - "$n" > "$W/big.ics" <<'PY'
import sys
n = int(sys.argv[1])
out = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//RT//x//EN"]
for i in range(n):
    out += ["BEGIN:VEVENT", "UID:%d@x" % i, "DTSTART:20250101T090000Z",
            "SUMMARY:" + ("lorem ipsum " * 12), " folded continuation 会议\U0001F600", "END:VEVENT"]
out.append("END:VCALENDAR")
sys.stdout.write("\r\n".join(out) + "\r\n")
PY
  echo "[D4 $n events, $(wc -c < "$W/big.ics" | tr -d ' ') bytes]"
  measure pion "$PION" ics "$W/big.ics"
done
