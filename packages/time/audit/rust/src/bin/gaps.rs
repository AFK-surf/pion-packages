//! Functional-gap evidence: core jiff features for which packages/time has NO API at all.
//! Each line prints what jiff computes; `grep` in run_audit.sh shows Pion has no counterpart.
use jiff::civil::{date, DateTime};
use jiff::tz::{Disambiguation, TimeZone};
use jiff::{RoundMode, Timestamp, TimestampRound, ToSpan, Unit, Zoned};

fn main() -> Result<(), jiff::Error> {
    let ny = TimeZone::get("America/New_York")?;
    // 1. IANA tz + DST gap (spring forward): 02:30 does not exist.
    let gap: DateTime = "2024-03-10T02:30".parse()?;
    for d in [Disambiguation::Compatible, Disambiguation::Earlier, Disambiguation::Later] {
        println!("gap   {:?}: {}", d, ny.to_ambiguous_zoned(gap).disambiguate(d)?);
    }
    println!("gap   Reject: {}", ny.to_ambiguous_zoned(gap).disambiguate(Disambiguation::Reject).is_err());
    // 2. DST fold (fall back): 01:30 happens twice.
    let fold: DateTime = "2024-11-03T01:30".parse()?;
    for d in [Disambiguation::Earlier, Disambiguation::Later] {
        println!("fold  {:?}: {}", d, ny.to_ambiguous_zoned(fold).disambiguate(d)?);
    }
    // 3. RFC 9557 round trip with a real time zone.
    let z: Zoned = "2024-03-09T12:00-05:00[America/New_York]".parse()?;
    let next = z.checked_add(1.day())?;
    println!("rfc9557 +1 day across DST: {} (elapsed {})", next, next.duration_since(&z));
    // 4. Offset conflict detection in RFC 9557 strings.
    println!("offset conflict rejected: {}", "2024-07-01T12:00-05:00[America/New_York]".parse::<Zoned>().is_err());
    // 5. POSIX TZ strings.
    let posix = TimeZone::posix("EST5EDT,M3.2.0,M11.1.0")?;
    println!("posix  EST5EDT 2024-07-01T12:00Z -> {}", Timestamp::from_second(1719835200)?.to_zoned(posix));
    // 6. Calendar Span arithmetic with clamping + largest-unit difference.
    println!("span   2024-01-31 + 1 month = {}", date(2024, 1, 31).checked_add(1.month())?);
    println!("span   2020-02-29 until 2025-01-15 (largest=year) = {}",
        date(2020, 2, 29).until((Unit::Year, date(2025, 1, 15)))?);
    // 7. Rounding.
    let ts: Timestamp = "2024-06-01T12:34:56.789Z".parse()?;
    println!("round  {} -> 15-minute HalfExpand: {}", ts,
        ts.round(TimestampRound::new().smallest(Unit::Minute).increment(15).mode(RoundMode::HalfExpand))?);
    // 8. strftime / strptime.
    println!("strftime: {}", jiff::fmt::strtime::format("%A, %B %-d, %Y at %H:%M %Z", &z)?);
    let parsed = jiff::fmt::strtime::parse("%d/%m/%Y %H:%M", "31/12/2024 23:05")?.to_datetime()?;
    println!("strptime: {}", parsed);
    // 9. System tz + TZif binary loading.
    let tz = TimeZone::get("Australia/Lord_Howe")?;
    println!("tzif   Lord_Howe 2024-01-01T00:00Z offset: {}", tz.to_offset(Timestamp::from_second(1704067200)?));
    Ok(())
}
