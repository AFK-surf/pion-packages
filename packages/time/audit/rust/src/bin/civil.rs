use jiff::civil::Date;
use jiff::tz::Offset;
use jiff::{Span, Timestamp};

fn main() {
    let ops: i64 = 2_000_000;
    let epoch = Date::constant(1970, 1, 1);
    let mut acc_ymd: i64 = 0;
    let mut acc_iwd: i64 = 0;
    let mut acc_ed: i64 = 0;

    for i in 0..ops {
        let day = ((i * 2_654_435_761) % 1_000_001) - 500_000;
        let delta = ((i % 731) - 365) as i32;
        let d0 = Offset::UTC
            .to_datetime(Timestamp::from_second(day * 86_400).unwrap())
            .date();
        let iwd = d0.iso_week_date();
        let d1 = d0.checked_add(Span::new().days(delta)).unwrap();
        let ed1 = d1.since(epoch).unwrap().get_days() as i64;

        acc_ymd += (d0.year() as i64) * 10_000 + (d0.month() as i64) * 100 + (d0.day() as i64);
        let wd1 = iwd.weekday().to_monday_one_offset() as i64;
        acc_iwd += (iwd.year() as i64) * 1_000 + (iwd.week() as i64) * 10 + wd1;
        acc_ed += ed1;
    }

    println!("ops={ops}");
    println!("acc_ymd={acc_ymd}");
    println!("acc_iwd={acc_iwd}");
    println!("acc_ed={acc_ed}");
}
