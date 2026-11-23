#!/usr/bin/env python3
"""python-dateutil reference expander: `DTSTART|RULE|LIMIT[|CAT]` -> `OK n:occ,...` / `ERR`."""
import itertools
import signal
import sys
import warnings

from dateutil.rrule import rrulestr

warnings.simplefilter("ignore")


class _Timeout(Exception):
    pass


def _alarm(*_):
    raise _Timeout()


def expand(line):
    parts = line.rstrip("\n").split("|")
    dt, rule, limit = parts[0], parts[1], int(parts[2])
    try:
        from datetime import datetime
        start = datetime.strptime(dt, "%Y%m%dT%H%M%S")
        rr = rrulestr(rule, dtstart=start)
        signal.signal(signal.SIGALRM, _alarm)
        signal.alarm(3)
        try:
            occ = list(itertools.islice(iter(rr), limit))
        finally:
            signal.alarm(0)
    except _Timeout:
        return "TIMEOUT"
    except Exception:
        return "ERR"
    return "OK %d:%s" % (len(occ), ",".join(o.strftime("%Y%m%dT%H%M%S") for o in occ))


def main():
    with open(sys.argv[1]) as f:
        for line in f:
            if line.strip():
                print(expand(line))


if __name__ == "__main__":
    main()
