//! Differential oracle for packages/decimal: Rust `rust_decimal =1.37.2`.
//!
//! Protocol (shared with ../probe/src/main.pion, one output line per input line):
//!   input  : `OP<TAB>arg<TAB>arg...`
//!            decimal args = 32 hex chars of the raw 16-byte `[flags, lo, mid, hi]` little-endian
//!            wire format (always a canonical flags word: sign + scale <= 28);
//!            string args  = hex of the UTF-8 bytes.
//!   output : `D <flags><lo><mid><hi> <to_string>` (4 x %08x words) | `B 0|1` | `I <i64>` | `U <u64>`
//!            | `F <f64 bits %016x>` | `H <32 hex serialize bytes>` | `NONE` (checked op returned None /
//!            Option::None) | `E <OVF|UNF|SCALE n|STR|CONV>` | `PANIC` (rust_decimal panicked).
use rust_decimal::prelude::*;
use rust_decimal::{Error, RoundingStrategy};
use std::io::{BufRead, BufWriter, Write};
use std::panic::{catch_unwind, AssertUnwindSafe};

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap())
        .collect()
}

fn dec_arg(s: &str) -> Decimal {
    let b = unhex(s);
    let mut a = [0u8; 16];
    a.copy_from_slice(&b);
    Decimal::deserialize(a)
}

fn str_arg(s: &str) -> String {
    String::from_utf8(unhex(s)).expect("corpus strings are valid UTF-8")
}

fn fmt_dec(d: &Decimal) -> String {
    let b = d.serialize();
    let w = |i: usize| u32::from_le_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]]);
    format!("D {:08x}{:08x}{:08x}{:08x} {}", w(0), w(4), w(8), w(12), d)
}

fn fmt_err(e: &Error) -> String {
    match e {
        Error::ExceedsMaximumPossibleValue | Error::LessThanMinimumPossibleValue => "E OVF".into(),
        Error::Underflow => "E UNF".into(),
        Error::ScaleExceedsMaximumPrecision(n) => format!("E SCALE {}", n),
        Error::ErrorString(_) => "E STR".into(),
        Error::ConversionTo(_) => "E CONV".into(),
    }
}

fn res(r: Result<Decimal, Error>) -> String {
    match r {
        Ok(d) => fmt_dec(&d),
        Err(e) => fmt_err(&e),
    }
}

fn opt(r: Option<Decimal>) -> String {
    match r {
        Some(d) => fmt_dec(&d),
        None => "NONE".into(),
    }
}

fn strategy(code: &str) -> RoundingStrategy {
    match code {
        "0" => RoundingStrategy::MidpointNearestEven,
        "1" => RoundingStrategy::MidpointAwayFromZero,
        "2" => RoundingStrategy::MidpointTowardZero,
        "3" => RoundingStrategy::ToZero,
        "4" => RoundingStrategy::AwayFromZero,
        "5" => RoundingStrategy::ToNegativeInfinity,
        _ => RoundingStrategy::ToPositiveInfinity,
    }
}

pub fn eval(line: &str) -> String {
    let f: Vec<&str> = line.split('\t').collect();
    let a = || dec_arg(f[1]);
    let b = || dec_arg(f[2]);
    let n = |i: usize| -> u32 { f[i].parse().unwrap() };
    match f[0] {
        "FS" => res(Decimal::from_str(&str_arg(f[1]))),
        "FSX" => res(Decimal::from_str_exact(&str_arg(f[1]))),
        "SCI" => res(Decimal::from_scientific(&str_arg(f[1]))),
        "RADIX" => res(Decimal::from_str_radix(&str_arg(f[1]), n(2))),
        "NEW" => res(Decimal::try_new(f[1].parse().unwrap(), n(2))),
        "ADD" => opt(a().checked_add(b())),
        "SUB" => opt(a().checked_sub(b())),
        "MUL" => opt(a().checked_mul(b())),
        "DIV" => opt(a().checked_div(b())),
        "REM" => opt(a().checked_rem(b())),
        "CMP" => format!("I {}", a().cmp(&b()) as i8),
        "RDS" => fmt_dec(&a().round_dp_with_strategy(n(2), strategy(f[3]))),
        "RND" => fmt_dec(&a().round()),
        "RDP" => fmt_dec(&a().round_dp(n(2))),
        "NORM" => fmt_dec(&a().normalize()),
        "TRUNC" => fmt_dec(&a().trunc()),
        "TRUNCS" => fmt_dec(&a().trunc_with_scale(n(2))),
        "FRACT" => fmt_dec(&a().fract()),
        "FLOOR" => fmt_dec(&a().floor()),
        "CEIL" => fmt_dec(&a().ceil()),
        "ABS" => fmt_dec(&a().abs()),
        "NEG" => fmt_dec(&-a()),
        "ISINT" => format!("B {}", a().is_integer() as u8),
        "RESCALE" => {
            let mut d = a();
            d.rescale(n(2));
            fmt_dec(&d)
        }
        "SETSCALE" => {
            let mut d = a();
            match d.set_scale(n(2)) {
                Ok(()) => fmt_dec(&d),
                Err(e) => fmt_err(&e),
            }
        }
        "SQRT" => opt(a().sqrt()),
        "POWI" => opt(a().checked_powi(f[2].parse().unwrap())),
        "POWU" => opt(a().checked_powu(f[2].parse().unwrap())),
        "SER" => {
            let s: String = a().serialize().iter().map(|x| format!("{:02x}", x)).collect();
            format!("H {}", s)
        }
        "DES" => {
            let b = unhex(f[1]);
            let mut arr = [0u8; 16];
            arr.copy_from_slice(&b);
            fmt_dec(&Decimal::deserialize(arr))
        }
        "TOI64" => match a().to_i64() {
            Some(v) => format!("I {}", v),
            None => "NONE".into(),
        },
        "TOU64" => match a().to_u64() {
            Some(v) => format!("U {}", v),
            None => "NONE".into(),
        },
        "TOF64" => match a().to_f64() {
            Some(v) => format!("F {:016x}", v.to_bits()),
            None => "NONE".into(),
        },
        op => panic!("unknown op {}", op),
    }
}

fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let args: Vec<String> = std::env::args().collect();
    let file = std::fs::File::open(&args[1]).expect("open corpus");
    let out = std::io::stdout();
    let mut w = BufWriter::new(out.lock());
    for line in std::io::BufReader::new(file).lines() {
        let line = line.unwrap();
        if line.is_empty() {
            continue;
        }
        let r = catch_unwind(AssertUnwindSafe(|| eval(&line))).unwrap_or_else(|_| "PANIC".into());
        writeln!(w, "{}", r).unwrap();
    }
}
