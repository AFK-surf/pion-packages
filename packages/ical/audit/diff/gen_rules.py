#!/usr/bin/env python3
"""Deterministic RRULE differential corpus generator (RT-ical red-team audit).

Emits `DTSTART|RULE|LIMIT|CATEGORY` lines. Only floating (naive) DTSTART/UNTIL so
that Pion, python-dateutil and Rust `rrule` see identical civil inputs.
"""
import random
import sys
from datetime import datetime, timedelta

WD = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
LIMIT = 40


def fmt(dt):
    return dt.strftime("%Y%m%dT%H%M%S")


def rand_dt(r, years=(1997, 2030)):
    base = datetime(r.randint(*years), 1, 1, r.choice([0, 9, 12, 23]), r.choice([0, 30, 59]), r.choice([0, 15]))
    return base + timedelta(days=r.randint(0, 364))


def pick(r, xs, lo=1, hi=3):
    k = r.randint(lo, min(hi, len(xs)))
    return r.sample(xs, k)


def join(xs):
    return ",".join(str(x) for x in xs)


def tail(r, allow_until=True):
    """COUNT or UNTIL (floating) or nothing."""
    c = r.random()
    if c < 0.5:
        return ";COUNT=%d" % r.randint(1, 30)
    if c < 0.8 and allow_until:
        return None  # UNTIL filled by caller relative to dtstart
    return ""


def finish(r, dt, rule):
    t = tail(r)
    if t is None:
        u = dt + timedelta(days=r.randint(30, 3 * 365), hours=r.randint(0, 23))
        rule += ";UNTIL=" + fmt(u)
    else:
        rule += t
    if r.random() < 0.3:
        rule += ";WKST=" + r.choice(WD)
    return rule


def gen(seed=5545):
    r = random.Random(seed)
    out = []

    # A. YEARLY + BYWEEKNO around ISO year boundaries
    for _ in range(500):
        y = r.randint(1997, 2030)
        dt = datetime(y, 12, r.randint(26, 31), 9, 0, 0) if r.random() < 0.5 else datetime(y, 1, r.randint(1, 5), 9, 0, 0)
        wn = pick(r, [1, 2, 52, 53, -1, -2, 20, -53], 1, 2)
        rule = "FREQ=YEARLY;BYWEEKNO=%s" % join(wn)
        if r.random() < 0.8:
            rule += ";BYDAY=" + join(pick(r, WD, 1, 3))
        if r.random() < 0.4:
            rule += ";INTERVAL=%d" % r.randint(2, 3)
        if r.random() < 0.15:
            rule += ";BYSETPOS=%s" % join(pick(r, [1, -1, 2], 1, 2))
        rule += ";WKST=" + r.choice(["MO", "SU", "TH"])
        rule += ";COUNT=%d" % r.randint(3, 20)
        out.append((dt, rule, "A_yearly_byweekno"))

    # B. YEARLY + BYDAY ordinals (with and without BYMONTH)
    for _ in range(400):
        dt = rand_dt(r)
        nth = [str(r.choice([1, 2, 3, 4, -1, -2, 20, -20, 53, -53, 5])) + r.choice(WD) for _ in range(r.randint(1, 2))]
        rule = "FREQ=YEARLY;BYDAY=%s" % ",".join(nth)
        if r.random() < 0.5:
            rule += ";BYMONTH=%s" % join(pick(r, list(range(1, 13)), 1, 3))
        if r.random() < 0.2:
            rule += ";INTERVAL=%d" % r.randint(2, 4)
        out.append((dt, finish(r, dt, rule), "B_yearly_byday_nth"))

    # C. MONTHLY + BYMONTHDAY (+/-) + BYDAY (plain or ordinal)
    for _ in range(500):
        dt = rand_dt(r)
        md = pick(r, [1, 2, 7, 8, 13, 14, 15, 28, 29, 30, 31, -1, -2, -7, -31], 1, 4)
        rule = "FREQ=MONTHLY;BYMONTHDAY=%s" % join(md)
        if r.random() < 0.7:
            if r.random() < 0.5:
                rule += ";BYDAY=" + join(pick(r, WD, 1, 3))
            else:
                rule += ";BYDAY=" + ",".join(str(r.choice([1, 2, -1, -2])) + r.choice(WD) for _ in range(r.randint(1, 2)))
        if r.random() < 0.2:
            rule += ";INTERVAL=%d" % r.randint(2, 5)
        out.append((dt, finish(r, dt, rule), "C_monthly_bymonthday_byday"))

    # D. WEEKLY + INTERVAL>1 + non-default WKST
    for _ in range(500):
        dt = rand_dt(r)
        rule = "FREQ=WEEKLY;INTERVAL=%d;WKST=%s" % (r.randint(2, 4), r.choice(WD))
        if r.random() < 0.85:
            rule += ";BYDAY=" + join(pick(r, WD, 1, 4))
        if r.random() < 0.15:
            rule += ";BYMONTH=%s" % join(pick(r, list(range(1, 13)), 1, 4))
        rule += ";COUNT=%d" % r.randint(2, 25)
        out.append((dt, rule, "D_weekly_interval_wkst"))

    # E. BYSETPOS (negative, out of range, duplicated) with COUNT / UNTIL
    for _ in range(500):
        dt = rand_dt(r)
        f = r.choice(["MONTHLY", "YEARLY", "WEEKLY", "DAILY"])
        if f == "MONTHLY":
            rule = "FREQ=MONTHLY;BYDAY=" + join(pick(r, WD, 1, 5))
        elif f == "YEARLY":
            rule = "FREQ=YEARLY;BYMONTH=%s;BYDAY=%s" % (join(pick(r, list(range(1, 13)), 1, 2)), join(pick(r, WD, 1, 3)))
        elif f == "WEEKLY":
            rule = "FREQ=WEEKLY;BYDAY=" + join(pick(r, WD, 2, 5))
        else:
            rule = "FREQ=DAILY;BYHOUR=%s" % join(pick(r, list(range(24)), 2, 4))
        sp = pick(r, [1, 2, 3, -1, -2, -3, 30, -30, 366, -366], 1, 3)
        if r.random() < 0.2:
            sp = sp + [sp[0]]
        rule += ";BYSETPOS=" + join(sp)
        out.append((dt, finish(r, dt, rule), "E_bysetpos"))

    # F. HOURLY / MINUTELY / SECONDLY with BYxxx across day/month boundaries
    for _ in range(500):
        dt = rand_dt(r)
        f = r.choice(["HOURLY", "MINUTELY", "SECONDLY"])
        rule = "FREQ=" + f
        if r.random() < 0.5:
            rule += ";INTERVAL=%d" % r.choice([2, 5, 7, 13, 25, 90])
        if r.random() < 0.6:
            rule += ";BYHOUR=%s" % join(pick(r, list(range(24)), 1, 3))
        if f != "HOURLY" or r.random() < 0.5:
            if r.random() < 0.6:
                rule += ";BYMINUTE=%s" % join(pick(r, [0, 1, 15, 30, 45, 59], 1, 3))
        if f == "SECONDLY" and r.random() < 0.6:
            rule += ";BYSECOND=%s" % join(pick(r, [0, 1, 30, 59], 1, 2))
        if r.random() < 0.3:
            rule += ";BYMONTHDAY=%s" % join(pick(r, [1, 15, 28, 31, -1], 1, 2))
        if r.random() < 0.2:
            rule += ";BYDAY=%s" % join(pick(r, WD, 1, 3))
        rule += ";COUNT=%d" % r.randint(1, 25)
        out.append((dt, rule, "F_subdaily"))

    # G. YEARLY BYMONTHDAY / BYYEARDAY without BYMONTH (RFC 5545 table: expand)
    for _ in range(300):
        dt = rand_dt(r)
        if r.random() < 0.5:
            rule = "FREQ=YEARLY;BYMONTHDAY=%s" % join(pick(r, [1, 13, 15, 29, 30, 31, -1], 1, 2))
            if r.random() < 0.4:
                rule += ";BYDAY=" + join(pick(r, WD, 1, 2))
        else:
            rule = "FREQ=YEARLY;BYYEARDAY=%s" % join(pick(r, [1, 59, 60, 100, 200, 365, 366, -1, -366], 1, 3))
            if r.random() < 0.4:
                rule += ";BYMONTH=%s" % join(pick(r, list(range(1, 13)), 1, 3))
        out.append((dt, finish(r, dt, rule), "G_yearly_expand"))

    # H. Fully random mixes
    for _ in range(800):
        dt = rand_dt(r)
        f = r.choice(["YEARLY", "MONTHLY", "WEEKLY", "DAILY"])
        rule = "FREQ=" + f
        if r.random() < 0.3:
            rule += ";INTERVAL=%d" % r.randint(2, 4)
        if r.random() < 0.4:
            rule += ";BYMONTH=%s" % join(pick(r, list(range(1, 13)), 1, 4))
        if r.random() < 0.3:
            rule += ";BYMONTHDAY=%s" % join(pick(r, [1, 5, 10, 15, 20, 28, 31, -1, -3], 1, 3))
        if r.random() < 0.4:
            if f in ("YEARLY", "MONTHLY") and r.random() < 0.4:
                rule += ";BYDAY=" + ",".join(str(r.choice([1, 2, 3, -1, -2])) + r.choice(WD) for _ in range(r.randint(1, 2)))
            else:
                rule += ";BYDAY=" + join(pick(r, WD, 1, 3))
        if r.random() < 0.25:
            rule += ";BYHOUR=%s" % join(pick(r, [0, 6, 9, 12, 18, 23], 1, 2))
        if r.random() < 0.15:
            rule += ";BYMINUTE=%s" % join(pick(r, [0, 15, 30, 45], 1, 2))
        if r.random() < 0.15:
            rule += ";BYSETPOS=%s" % join(pick(r, [1, 2, -1, -2], 1, 2))
        out.append((dt, finish(r, dt, rule), "H_random"))
    return out


def main():
    rows = gen(int(sys.argv[1]) if len(sys.argv) > 1 else 5545)
    for dt, rule, cat in rows:
        print("%s|%s|%d|%s" % (fmt(dt), rule, LIMIT, cat))


if __name__ == "__main__":
    main()
