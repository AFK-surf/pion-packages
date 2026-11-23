//! Rust `clap =4.5.32` oracle for the `packages/cli` red-team differential.
//! Prints exactly the same canonical line format as `audit/probe` (Pion).
use clap::error::ErrorKind;
use clap::parser::ValueSource;
use clap::{Arg, ArgAction, ArgMatches, Command};
use std::env;
use std::fs;

fn spec_basic() -> Command {
    Command::new("app")
        .arg(Arg::new("verbose").short('v').long("verbose").action(ArgAction::Count))
        .arg(Arg::new("output").short('o').long("output"))
        .arg(Arg::new("pattern").short('p').long("pattern").allow_hyphen_values(true))
        .arg(Arg::new("num").short('n').long("num"))
        .arg(Arg::new("flag").short('f').long("flag").action(ArgAction::SetTrue))
        .arg(Arg::new("five").short('5').action(ArgAction::SetTrue))
        .arg(Arg::new("list").short('l').long("list").action(ArgAction::Append).value_delimiter(','))
        .arg(Arg::new("mode").short('m').long("mode").value_parser(["fast", "slow"]))
        .arg(Arg::new("uni").short('é').action(ArgAction::SetTrue))
        .arg(Arg::new("secret").long("secret").action(ArgAction::SetTrue).hide(true))
        .arg(Arg::new("files").action(ArgAction::Append))
}

fn spec_env() -> Command {
    Command::new("app")
        .arg(Arg::new("color").long("color").action(ArgAction::SetTrue).env("APP_COLOR"))
        .arg(Arg::new("name").long("name").env("APP_NAME").default_value("dflt"))
        .arg(Arg::new("tags").long("tags").action(ArgAction::Append).value_delimiter(',').env("APP_TAGS"))
        .arg(Arg::new("a").long("a").action(ArgAction::SetTrue).requires("b"))
        .arg(Arg::new("b").long("b").default_value("x"))
        .arg(Arg::new("c").long("c").action(ArgAction::SetTrue).conflicts_with("d"))
        .arg(Arg::new("d").long("d").action(ArgAction::SetTrue).env("APP_D"))
        .arg(Arg::new("e").long("e").requires("name"))
}

fn spec_sub() -> Command {
    Command::new("app")
        .version("1.0")
        .about("Root")
        .arg(Arg::new("verbose").short('v').long("verbose").action(ArgAction::Count).global(true))
        .arg(Arg::new("cfg").long("cfg").global(true))
        .arg(Arg::new("pos"))
        .subcommand(
            Command::new("run")
                .about("Run")
                .arg(Arg::new("x").long("x").action(ArgAction::SetTrue).requires("cfg"))
                .arg(Arg::new("out").short('o').long("out")),
        )
        .subcommand(
            Command::new("deep").about("Deep").subcommand(
                Command::new("a").subcommand(
                    Command::new("b").arg(Arg::new("z").long("z").action(ArgAction::SetTrue)),
                ),
            ),
        )
}

fn ids_for(spec: &str, sub: &str) -> Vec<&'static str> {
    match (spec, sub) {
        ("basic", _) => vec![
            "verbose:C", "output:V", "pattern:V", "num:V", "flag:F", "five:F", "list:V", "mode:V",
            "uni:F", "secret:F", "files:V",
        ],
        ("env", _) => vec!["color:F", "name:V", "tags:V", "a:F", "b:V", "c:F", "d:F", "e:V"],
        (_, "") => vec!["verbose:C", "cfg:V", "pos:V"],
        (_, "run") => vec!["verbose:C", "cfg:V", "x:F", "out:V"],
        (_, "b") => vec!["verbose:C", "cfg:V", "z:F"],
        _ => vec!["verbose:C", "cfg:V"],
    }
}

fn esc(out: &mut String, s: &[u8]) {
    for &b in s {
        if b < 0x21 || b > 0x7e || b == b'\\' || b == b',' || b == b'[' || b == b']' || b == b'=' {
            out.push_str(&format!("\\x{:02x}", b));
        } else {
            out.push(b as char);
        }
    }
}

fn unhex(h: &str) -> Vec<u8> {
    (0..h.len() / 2).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap()).collect()
}

fn write_matches(out: &mut String, spec: &str, sub: &str, m: &ArgMatches) {
    for spec_id in ids_for(spec, sub) {
        let (id, kind) = spec_id.split_once(':').unwrap();
        match kind {
            "C" => out.push_str(&format!(" {}={}", id, m.get_count(id))),
            "F" => out.push_str(&format!(" {}={}", id, m.get_flag(id))),
            _ => {
                if let Some(vs) = m.get_raw(id) {
                    out.push_str(&format!(" {}=[", id));
                    for (k, v) in vs.enumerate() {
                        if k > 0 {
                            out.push(',');
                        }
                        esc(out, v.as_encoded_bytes());
                    }
                    out.push_str("]@");
                    out.push_str(match m.value_source(id) {
                        Some(ValueSource::CommandLine) => "cli",
                        Some(ValueSource::EnvVariable) => "env",
                        Some(ValueSource::DefaultValue) => "default",
                        _ => "?",
                    });
                }
            }
        }
    }
    if let Some((name, sm)) = m.subcommand() {
        out.push_str(&format!(" sub={} {{", name));
        write_matches(out, spec, name, sm);
        out.push_str(" }");
    }
}

fn suggestion(rendered: &str) -> String {
    for key in ["a similar argument exists: '", "a similar subcommand exists: '", "some similar subcommands exist: '", "some similar arguments exist: '"] {
        if let Some(p) = rendered.find(key) {
            let rest = &rendered[p + key.len()..];
            if let Some(e) = rest.find('\'') {
                let mut o = String::new();
                esc(&mut o, rest[..e].as_bytes());
                return o;
            }
        }
    }
    "-".to_string()
}

fn write_err(out: &mut String, e: &clap::Error) {
    let rendered = e.render().to_string();
    match e.kind() {
        ErrorKind::DisplayHelp | ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand => {
            out.push_str("HELP ");
            let u = rendered.lines().find(|l| l.starts_with("Usage:")).unwrap_or("<no usage>");
            esc(out, u.as_bytes());
        }
        ErrorKind::DisplayVersion => {
            out.push_str("VERSION ");
            esc(out, rendered.as_bytes());
        }
        ErrorKind::UnknownArgument => out.push_str(&format!("ERR unknown_argument sug={}", suggestion(&rendered))),
        ErrorKind::InvalidSubcommand => out.push_str(&format!("ERR invalid_subcommand sug={}", suggestion(&rendered))),
        ErrorKind::InvalidValue | ErrorKind::NoEquals | ErrorKind::ValueValidation | ErrorKind::TooManyValues
        | ErrorKind::TooFewValues | ErrorKind::WrongNumberOfValues => out.push_str("ERR invalid_value"),
        ErrorKind::ArgumentConflict => out.push_str("ERR argument_conflict"),
        ErrorKind::MissingRequiredArgument => out.push_str("ERR missing_required"),
        ErrorKind::MissingSubcommand => out.push_str("ERR missing_subcommand"),
        k => out.push_str(&format!("ERR other_{:?}", k)),
    }
}

fn run_diff(path: &str) {
    let content = fs::read_to_string(path).unwrap();
    let mut out = String::new();
    let all_env = ["APP_COLOR", "APP_NAME", "APP_TAGS", "APP_D"];
    for (n, line) in content.split('\n').enumerate() {
        if line.is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        let spec = f[0];
        for k in all_env {
            env::remove_var(k);
        }
        if !f[1].is_empty() {
            let kvs = String::from_utf8(unhex(f[1])).unwrap();
            for kv in kvs.split('\x1f') {
                let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
                env::set_var(k, v);
            }
        }
        let mut argv: Vec<std::ffi::OsString> = vec!["app".into()];
        for a in &f[2..] {
            argv.push(String::from_utf8(unhex(a)).unwrap().into());
        }
        let cmd = match spec {
            "basic" => spec_basic(),
            "env" => spec_env(),
            _ => spec_sub(),
        };
        out.push_str(&format!("{}\t", n));
        match cmd.try_get_matches_from(argv) {
            Ok(m) => {
                out.push_str("OK");
                write_matches(&mut out, spec, "", &m);
            }
            Err(e) => write_err(&mut out, &e),
        }
        out.push('\n');
    }
    print!("{}", out);
}

fn run_typed(path: &str) {
    let content = fs::read_to_string(path).unwrap();
    let mut out = String::new();
    for line in content.split('\n') {
        if line.is_empty() {
            continue;
        }
        let raw = unhex(line);
        let s = String::from_utf8(raw.clone()).unwrap();
        out.push('[');
        esc(&mut out, &raw);
        out.push_str("] i32=");
        out.push_str(&s.parse::<i32>().map(|v| v.to_string()).unwrap_or("ERR".into()));
        out.push_str(" i64=");
        out.push_str(&s.parse::<i64>().map(|v| v.to_string()).unwrap_or("ERR".into()));
        out.push_str(" f64=");
        out.push_str(&match s.parse::<f64>() {
            Ok(d) if d.is_nan() => "NaN".to_string(),
            Ok(d) => format!("{:016x}", d.to_bits()),
            Err(_) => "ERR".to_string(),
        });
        out.push('\n');
    }
    print!("{}", out);
}

fn run_dos(w: &str, n: usize) {
    match w {
        "build_args" => {
            let mut c = Command::new("big");
            for i in 0..n {
                c = c.arg(Arg::new(format!("o{}", i)).long(format!("opt-{}", i)));
            }
            println!("args={}", c.get_arguments().count());
        }
        "build_subs" => {
            let mut c = Command::new("big");
            for i in 0..n {
                c = c.subcommand(Command::new(format!("s{}", i)));
            }
            println!("subs={}", c.get_subcommands().count());
        }
        "build_parse" => {
            let mut c = Command::new("big");
            for i in 0..n {
                c = c.arg(Arg::new(format!("o{}", i)).long(format!("opt-{}", i)));
            }
            let flag = format!("--opt-{}", n - 1);
            match c.try_get_matches_from(["big", flag.as_str(), "v"]) {
                Ok(m) => println!("ok={}", m.get_one::<String>(&format!("o{}", n - 1)).unwrap()),
                Err(_) => println!("err"),
            }
        }
        "typo_many" => {
            let mut c = Command::new("big");
            for i in 0..n {
                c = c.arg(Arg::new(format!("o{}", i)).long(format!("option-name-{}", i)));
            }
            c.build();
            let mut hits = 0;
            for r in 0..1000 {
                let bad = format!("--optoin-name-{}", r % n);
                if let Err(e) = c.try_get_matches_from_mut(["big", bad.as_str()]) {
                    if e.kind() == ErrorKind::UnknownArgument && suggestion(&e.render().to_string()) != "-" {
                        hits += 1;
                    }
                }
            }
            println!("hits={}", hits);
        }
        "typo_long" => {
            let mut c = Command::new("big");
            for i in 0..30 {
                c = c.arg(Arg::new(format!("o{}", i)).long(format!("opt-{}", i)));
            }
            let bad = format!("--{}", "x".repeat(n));
            match c.try_get_matches_from(["big", bad.as_str()]) {
                Err(e) if e.kind() == ErrorKind::UnknownArgument => println!("len={}", bad.len()),
                _ => println!("?"),
            }
        }
        "typo_longcand" => {
            let mut c = Command::new("big");
            for i in 0..20 {
                c = c.arg(Arg::new(format!("o{}", i)).long(format!("{}{}", "a".repeat(n), i)));
            }
            let bad = format!("--{}0", "b".repeat(n));
            match c.try_get_matches_from(["big", bad.as_str()]) {
                Err(e) => {
                    let s = suggestion(&e.render().to_string());
                    println!("sug={}", if s == "-" { 1 } else { s.len() });
                }
                _ => println!("?"),
            }
        }
        "deep" => {
            let mut c = Command::new(format!("l{}", n));
            for d in (0..n).rev() {
                c = Command::new(format!("l{}", d)).subcommand(c);
            }
            let mut argv = vec!["l0".to_string()];
            for k in 1..=n {
                argv.push(format!("l{}", k));
            }
            match c.try_get_matches_from(argv) {
                Ok(_) => println!("ok"),
                Err(e) => println!("{}", e),
            }
        }
        "many_args" => {
            let c = Command::new("bulk")
                .arg(Arg::new("v").short('v').action(ArgAction::Count))
                .arg(Arg::new("files").action(ArgAction::Append));
            let mut argv = vec!["bulk".to_string()];
            for i in 0..n {
                argv.push(if i % 2 == 0 { "-v".to_string() } else { format!("f{}", i) });
            }
            match c.try_get_matches_from(argv) {
                Ok(m) => println!("v={}", m.get_count("v")),
                Err(_) => println!("err"),
            }
        }
        "help_long" => {
            let mut c = Command::new("big");
            for i in 0..n {
                c = c.arg(
                    Arg::new(format!("o{}", i))
                        .long(format!("opt-{}", i))
                        .help(format!("Option {}", i))
                        .env(format!("ENV_{}", i))
                        .default_value("d")
                        .value_parser(["d", "e", "f"]),
                );
            }
            println!("len={}", c.render_long_help().to_string().len());
        }
        _ => std::process::exit(2),
    }
}

fn main() {
    let a: Vec<String> = env::args().collect();
    match a.get(1).map(|s| s.as_str()) {
        Some("diff") => run_diff(&a[2]),
        Some("typed") => run_typed(&a[2]),
        Some("dos") => run_dos(&a[2], a[3].parse().unwrap()),
        _ => std::process::exit(1),
    }
}
