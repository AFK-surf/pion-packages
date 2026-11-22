//! Differential probe: reference behaviour of BurntSushi/jiff for every case in cases/differential.tsv.
//! Output: `kind\tinput\tRESULT` where RESULT is `OK ...` / `ERR` (optionally `canon || display`).
use jiff::civil::{Date, DateTime};
use jiff::tz::Offset;
use jiff::{SignedDuration, Span, Timestamp};
use std::io::{BufRead, Write};

fn norm(ts: Timestamp) -> (i64, i32) {
    let mut s = ts.as_second();
    let mut n = ts.subsec_nanosecond();
    if n < 0 {
        s -= 1;
        n += 1_000_000_000;
    }
    (s, n)
}

fn fmt_ts(ts: Timestamp) -> String {
    let (s, n) = norm(ts);
    format!("OK {s} {n}")
}

fn span_canon(sp: &Span) -> String {
    let t: i128 = sp.get_hours() as i128 * 3_600_000_000_000
        + sp.get_minutes() as i128 * 60_000_000_000
        + sp.get_seconds() as i128 * 1_000_000_000
        + sp.get_milliseconds() as i128 * 1_000_000
        + sp.get_microseconds() as i128 * 1_000
        + sp.get_nanoseconds() as i128;
    let sign = sp.signum();
    format!(
        "OK {} {} {} {} {} {}",
        if sign < 0 { "-" } else { "+" },
        sp.get_years().abs(),
        sp.get_months().abs(),
        sp.get_weeks().abs(),
        sp.get_days().abs(),
        t.abs()
    )
}

fn date_s(d: Date) -> String {
    format!("OK {d}")
}

fn run(kind: &str, input: &str) -> String {
    let w: Vec<&str> = input.split(' ').collect();
    let p64 = |i: usize| w.get(i).and_then(|x| x.parse::<i64>().ok());
    match kind {
        "ts" => match input.parse::<Timestamp>() {
            Ok(ts) => fmt_ts(ts),
            Err(_) => "ERR".into(),
        },
        "tsfmt" => {
            let (Some(s), Some(n), Some(o)) = (p64(0), p64(1), p64(2)) else { return "BADCASE".into() };
            let Ok(ts) = Timestamp::new(s, n as i32) else { return "ERR".into() };
            let Ok(off) = Offset::from_seconds(o as i32) else { return "ERR".into() };
            format!("OK {}", ts.display_with_offset(off))
        }
        "tsadd" => {
            let (Some(s), Some(n), Some(ds), Some(dn)) = (p64(0), p64(1), p64(2), p64(3)) else { return "BADCASE".into() };
            let Ok(ts) = Timestamp::new(s, n as i32) else { return "ERR".into() };
            let d = SignedDuration::new(ds, dn as i32);
            match ts.checked_add(d) {
                Ok(t) => fmt_ts(t),
                Err(_) => "ERR".into(),
            }
        }
        "sdur" => {
            // ISO 8601 parse only (jiff's FromStr also accepts the "friendly" format; we use the temporal parser explicitly).
            match jiff::fmt::temporal::SpanParser::new().parse_duration(input) {
                Ok(d) => format!("OK {} {} || {}", d.as_secs(), d.subsec_nanos(), d),
                Err(_) => "ERR".into(),
            }
        }
        "sdfmt" => {
            let (Some(s), Some(n)) = (p64(0), p64(1)) else { return "BADCASE".into() };
            format!("OK {}", SignedDuration::new(s, n as i32))
        }
        "span" => match jiff::fmt::temporal::SpanParser::new().parse_span(input) {
            Ok(sp) => format!("{} || {}", span_canon(&sp), sp),
            Err(_) => "ERR".into(),
        },
        "http" | "r2822" => match jiff::fmt::rfc2822::parse(input) {
            Ok(z) => {
                let (s, _) = norm(z.timestamp());
                if kind == "http" {
                    format!("OK {s}")
                } else {
                    format!("OK {s} {}", z.offset().seconds())
                }
            }
            Err(_) => "ERR".into(),
        },
        "date" => match input.parse::<Date>() {
            Ok(d) => date_s(d),
            Err(_) => "ERR".into(),
        },
        "dt" => match input.parse::<DateTime>() {
            Ok(d) => format!("OK {d}"),
            Err(_) => "ERR".into(),
        },
        "addm" | "addy" | "addd" => {
            let Ok(d) = w[0].parse::<Date>() else { return "BADCASE".into() };
            let Some(n) = p64(1) else { return "BADCASE".into() };
            let sp = match kind {
                "addm" => Span::new().try_months(n),
                "addy" => Span::new().try_years(n),
                _ => Span::new().try_days(n),
            };
            match sp.and_then(|sp| d.checked_add(sp)) {
                Ok(r) => date_s(r),
                Err(_) => "ERR".into(),
            }
        }
        "until" => {
            let (Ok(a), Ok(b)) = (w[0].parse::<Date>(), w[1].parse::<Date>()) else { return "BADCASE".into() };
            match a.until(b) {
                Ok(sp) => format!("OK {}", sp.get_days()),
                Err(_) => "ERR".into(),
            }
        }
        "dtadd" => {
            let Ok(d) = w[0].parse::<DateTime>() else { return "BADCASE".into() };
            let (Some(ds), Some(dn)) = (p64(1), p64(2)) else { return "BADCASE".into() };
            match d.checked_add(SignedDuration::new(ds, dn as i32)) {
                Ok(r) => format!("OK {r}"),
                Err(_) => "ERR".into(),
            }
        }
        _ => "BADCASE".into(),
    }
}

fn civil_all() {
    // Every day in -9999-01-01..=9999-12-31: epoch-day, Y-M-D, ISO week date, weekday, day-of-year.
    let out = std::io::stdout();
    let mut out = std::io::BufWriter::new(out.lock());
    let epoch = Date::constant(1970, 1, 1);
    let mut d = Date::MIN;
    let mut ed: i64 = epoch.until(d).unwrap().get_days() as i64;
    loop {
        let w = d.iso_week_date();
        writeln!(
            out,
            "{ed} {d} {}{:04}-W{:02}-{} {}",
            if w.year() < 0 { "-" } else { "" },
            w.year().unsigned_abs(),
            w.week(),
            w.weekday().to_monday_one_offset(),
            d.day_of_year()
        )
        .unwrap();
        if d == Date::MAX {
            break;
        }
        d = d.tomorrow().unwrap();
        ed += 1;
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(|s| s.as_str()) == Some("--civil-all") {
        civil_all();
        return;
    }
    let path = args.get(1).expect("usage: probe <cases.tsv> | --civil-all");
    let f = std::fs::File::open(path).unwrap();
    let out = std::io::stdout();
    let mut out = out.lock();
    for line in std::io::BufReader::new(f).lines() {
        let line = line.unwrap();
        let Some((k, input)) = line.split_once('\t') else { continue };
        writeln!(out, "{k}\t{input}\t{}", run(k, input)).unwrap();
    }
}
