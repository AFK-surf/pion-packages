use chrono::{Datelike, NaiveDateTime, TimeZone, Timelike};
use icalendar::{Calendar, CalendarComponent, Component};
use rrule::{RRule, RRuleSet, Tz};
use std::env;
use std::fs;
use std::str::FromStr;

fn mix(h: i64, v: i64) -> i64 {
    const M: i64 = 1_000_000_007;
    ((h * 131) + (v % M) + M) % M
}

fn hash_str(h0: i64, s: &str) -> i64 {
    let bytes = s.as_bytes();
    let mut h = mix(h0, bytes.len() as i64);
    for &b in bytes {
        h = mix(h, b as i64);
    }
    h
}

fn dt_key(dt: &chrono::DateTime<Tz>) -> i64 {
    let ymd = (dt.year() as i64) * 10000 + (dt.month() as i64) * 100 + (dt.day() as i64);
    let hms = (dt.hour() as i64) * 10000 + (dt.minute() as i64) * 100 + (dt.second() as i64);
    ymd * 1_000_000 + hms
}

fn parse_utc(s: &str) -> chrono::DateTime<Tz> {
    let trimmed = s.trim_end_matches('Z');
    let naive = NaiveDateTime::parse_from_str(trimmed, "%Y%m%dT%H%M%S").expect("valid utc dt");
    Tz::UTC.from_utc_datetime(&naive)
}

fn bench_ics_roundtrip(raw: &str) {
    let cal = Calendar::from_str(raw).expect("parse ics");
    let serialized = cal.to_string();
    let cal2 = Calendar::from_str(&serialized).expect("reparse ics");
    let mut events = 0usize;
    let mut checksum = 0i64;
    for comp in &cal2.components {
        if let CalendarComponent::Event(ev) = comp {
            events += 1;
            if let Some(uid) = ev.property_value("UID") {
                checksum = hash_str(checksum, uid);
            }
            if let Some(dtstart) = ev.property_value("DTSTART") {
                checksum = hash_str(checksum, dtstart);
            }
            if let Some(summary) = ev.property_value("SUMMARY") {
                checksum = hash_str(checksum, summary);
            }
            if let Some(desc) = ev.property_value("DESCRIPTION") {
                checksum = hash_str(checksum, desc);
            }
            if let Some(loc) = ev.property_value("LOCATION") {
                checksum = hash_str(checksum, loc);
            }
        }
    }
    println!("events={}", events);
    println!("checksum={}", checksum);
}

fn bench_rrule_expand(raw: &str) {
    let mut total = 0i64;
    let mut checksum = 0i64;
    for line in raw.lines() {
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() < 3 {
            continue;
        }
        let dtstart = parse_utc(parts[0]);
        let rrule = RRule::from_str(parts[1])
            .expect("parse rrule")
            .build(dtstart)
            .expect("build rrule");
        let limit: u16 = parts[2].parse().expect("limit");
        let res = rrule.all(limit);
        total += res.dates.len() as i64;
        for dt in &res.dates {
            checksum = mix(checksum, dt_key(dt));
        }
    }
    println!("occurrences={}", total);
    println!("checksum={}", checksum);
}

fn bench_rruleset_window(raw: &str) {
    let mut total = 0i64;
    let mut checksum = 0i64;
    for line in raw.lines() {
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() < 7 {
            continue;
        }
        let dtstart = parse_utc(parts[0]);
        let r1 = RRule::from_str(parts[1])
            .expect("parse r1")
            .validate(dtstart)
            .expect("validate r1");
        let r2 = RRule::from_str(parts[2])
            .expect("parse r2")
            .validate(dtstart)
            .expect("validate r2");
        let mut set = RRuleSet::new(dtstart).rrule(r1).rrule(r2);
        for rd in parts[3].split(',') {
            if !rd.is_empty() {
                set = set.rdate(parse_utc(rd));
            }
        }
        for ex in parts[4].split(',') {
            if !ex.is_empty() {
                set = set.exdate(parse_utc(ex));
            }
        }
        let after = parse_utc(parts[5]);
        let before = parse_utc(parts[6]);
        let set = set.after(after).before(before);
        let res = set.all(10000);
        total += res.dates.len() as i64;
        for dt in &res.dates {
            checksum = mix(checksum, dt.timestamp());
        }
    }
    println!("occurrences={}", total);
    println!("checksum={}", checksum);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: ical-bench-rust <mode> <corpus_path>");
        std::process::exit(1);
    }
    let mode = &args[1];
    let raw = fs::read_to_string(&args[2]).expect("read corpus");
    match mode.as_str() {
        "ics_roundtrip" => bench_ics_roundtrip(&raw),
        "rrule_expand" => bench_rrule_expand(&raw),
        "rruleset_window" => bench_rruleset_window(&raw),
        _ => {
            eprintln!("unknown mode: {}", mode);
            std::process::exit(1);
        }
    }
}
