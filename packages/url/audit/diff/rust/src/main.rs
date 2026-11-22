//! Differential oracle driver for `packages/url` red-team audit.
//! Protocol: one case per input line, TAB-separated fields, each field is the
//! lowercase hex encoding of its UTF-8 bytes (`~` = None). Output: one line per
//! case, TAB-separated hex fields. Must stay byte-identical with audit/diff/pion.
use std::io::{self, BufRead, BufWriter, Write};
use url::{quirks, Url};

fn unhex(s: &str) -> Option<String> {
    if s == "~" {
        return None;
    }
    let b: Vec<u8> = (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap())
        .collect();
    Some(String::from_utf8(b).expect("utf8"))
}

fn hex(s: &str) -> String {
    let mut o = String::with_capacity(s.len() * 2);
    for b in s.bytes() {
        o.push_str(&format!("{:02x}", b));
    }
    o
}

fn dump(u: &Url) -> Vec<String> {
    vec![
        "OK".into(),
        quirks::href(u).into(),
        quirks::protocol(u).into(),
        quirks::username(u).into(),
        quirks::password(u).into(),
        quirks::host(u).into(),
        quirks::hostname(u).into(),
        quirks::port(u).into(),
        quirks::pathname(u).into(),
        quirks::search(u).into(),
        quirks::hash(u).into(),
        quirks::origin(u),
        if u.cannot_be_a_base() { "opaque".into() } else { "base".into() },
    ]
}

fn setter(u: &mut Url, name: &str, v: Option<String>) -> &'static str {
    let s = v.clone().unwrap_or_default();
    let ok = match name {
        // WHATWG / DOM (quirks) setters
        "protocol" => quirks::set_protocol(u, &s).is_ok(),
        "username" => quirks::set_username(u, &s).is_ok(),
        "password" => quirks::set_password(u, &s).is_ok(),
        "host" => quirks::set_host(u, &s).is_ok(),
        "hostname" => quirks::set_hostname(u, &s).is_ok(),
        "port" => quirks::set_port(u, &s).is_ok(),
        "pathname" => {
            quirks::set_pathname(u, &s);
            true
        }
        "search" => {
            quirks::set_search(u, &s);
            true
        }
        "hash" => {
            quirks::set_hash(u, &s);
            true
        }
        "href" => quirks::set_href(u, &s).is_ok(),
        // rust-url native API setters
        "set_scheme" => u.set_scheme(&s).is_ok(),
        "set_username" => u.set_username(&s).is_ok(),
        "set_password" => u.set_password(v.as_deref()).is_ok(),
        "set_host" => u.set_host(v.as_deref()).is_ok(),
        "set_port" => match v {
            None => u.set_port(None).is_ok(),
            Some(p) => match p.parse::<u16>() {
                Ok(n) => u.set_port(Some(n)).is_ok(),
                Err(_) => false,
            },
        },
        "set_path" => {
            u.set_path(&s);
            true
        }
        "set_query" => {
            u.set_query(v.as_deref());
            true
        }
        "set_fragment" => {
            u.set_fragment(v.as_deref());
            true
        }
        _ => panic!("unknown setter {name}"),
    };
    if ok {
        "SETOK"
    } else {
        "SETERR"
    }
}

fn run(f: &[Option<String>]) -> Vec<String> {
    let op = f[0].as_deref().unwrap();
    // L<op>: run <op> but only emit each output field's byte length (compact
    // output for the adversarial performance workloads).
    if let Some(inner) = op.strip_prefix('L') {
        return run_op(inner, f).iter().map(|x| x.len().to_string()).collect();
    }
    run_op(op, f)
}

fn run_op(op: &str, f: &[Option<String>]) -> Vec<String> {
    let a = |i: usize| -> &str { f.get(i).and_then(|x| x.as_deref()).unwrap_or("") };
    match op {
        "P" => match Url::parse(&a(1)) {
            Ok(u) => dump(&u),
            Err(_) => vec!["ERR".into()],
        },
        "J" => match Url::parse(&a(1)) {
            Ok(b) => match b.join(&a(2)) {
                Ok(u) => dump(&u),
                Err(_) => vec!["ERR".into()],
            },
            Err(_) => vec!["BASEERR".into()],
        },
        "S" => match Url::parse(&a(1)) {
            Ok(mut u) => {
                // any number of (setter, value) pairs follow
                let mut out = vec![];
                let mut i = 2;
                while i < f.len() {
                    let v = f.get(i + 1).cloned().flatten();
                    out.push(setter(&mut u, &a(i), v).to_string());
                    i += 2;
                }
                let mut d = dump(&u);
                out.append(&mut d);
                out
            }
            Err(_) => vec!["BASEERR".into()],
        },
        // R: serialization round-trip. parse (or join onto base) -> href1 -> parse(href1) -> href2
        "R" => {
            let u = match &f[1] {
                None => Url::parse(&a(2)),
                Some(b) => match Url::parse(b) {
                    Ok(b) => b.join(&a(2)),
                    Err(_) => return vec!["BASEERR".into()],
                },
            };
            match u {
                Err(_) => vec!["ERR".into()],
                Ok(u) => match Url::parse(u.as_str()) {
                    Ok(v) => {
                        let mut o = vec!["OK".into()];
                        o.extend(dump(&u).into_iter().skip(1));
                        o.extend(dump(&v).into_iter().skip(1));
                        o
                    }
                    Err(_) => vec!["REPARSE-ERR".into(), u.as_str().into()],
                },
            }
        }
        // H / JH: parse (or join) and return only the serialization (perf workloads)
        "H" => vec![Url::parse(a(1)).map(|u| u.into()).unwrap_or_else(|_| "ERR".into())],
        "JH" => match Url::parse(a(1)) {
            Ok(b) => vec![b.join(a(2)).map(|u| u.into()).unwrap_or_else(|_| "ERR".into())],
            Err(_) => vec!["BASEERR".into()],
        },
        // N: no-op (measures driver I/O + hex decoding overhead for the perf workloads)
        "N" => vec!["0".into()],
        "A" => vec![quirks::domain_to_ascii(a(1))],
        "U" => vec![quirks::domain_to_unicode(&a(1))],
        "D" => vec![percent_encoding::percent_decode_str(&a(1))
            .decode_utf8_lossy()
            .into_owned()],
        "Q" => {
            let pairs: Vec<(String, String)> = form_urlencoded::parse(a(1).as_bytes())
                .map(|(k, v)| (k.into_owned(), v.into_owned()))
                .collect();
            let mut out = vec![pairs.len().to_string()];
            for (k, v) in &pairs {
                out.push(k.clone());
                out.push(v.clone());
            }
            let mut ser = form_urlencoded::Serializer::new(String::new());
            for (k, v) in &pairs {
                ser.append_pair(k, v);
            }
            out.push(ser.finish());
            out
        }
        // M: URLSearchParams mutation script. f[1] = query, then ops:
        //   "d" name | "s" name value | "a" name value | "sort" | "g" name | "h" name
        "M" => {
            let mut pairs: Vec<(String, String)> = form_urlencoded::parse(a(1).as_bytes())
                .map(|(k, v)| (k.into_owned(), v.into_owned()))
                .collect();
            let mut out = vec![];
            let mut i = 2;
            while i < f.len() {
                match a(i) {
                    "d" => {
                        let n = a(i + 1);
                        pairs.retain(|(k, _)| *k != n);
                        i += 2;
                    }
                    "s" => {
                        let (n, v) = (a(i + 1), a(i + 2));
                        let mut found = false;
                        pairs.retain_mut(|(k, val)| {
                            if *k == n {
                                if found {
                                    return false;
                                }
                                *val = v.to_string();
                                found = true;
                            }
                            true
                        });
                        if !found {
                            pairs.push((n.to_string(), v.to_string()));
                        }
                        i += 3;
                    }
                    "a" => {
                        pairs.push((a(i + 1).to_string(), a(i + 2).to_string()));
                        i += 3;
                    }
                    "sort" => {
                        // WHATWG: stable sort by UTF-16 code units of the name
                        pairs.sort_by(|x, y| x.0.encode_utf16().cmp(y.0.encode_utf16()));
                        i += 1;
                    }
                    "g" => {
                        let n = a(i + 1);
                        out.push(match pairs.iter().find(|(k, _)| *k == n) {
                            Some((_, v)) => v.clone(),
                            None => "<none>".into(),
                        });
                        i += 2;
                    }
                    "h" => {
                        let n = a(i + 1);
                        out.push(pairs.iter().any(|(k, _)| *k == n).to_string());
                        i += 2;
                    }
                    o => panic!("unknown M op {o}"),
                }
            }
            let mut ser = form_urlencoded::Serializer::new(String::new());
            for (k, v) in &pairs {
                ser.append_pair(k, v);
            }
            out.push(pairs.len().to_string());
            out.push(ser.finish());
            out
        }
        _ => panic!("unknown op {op}"),
    }
}

fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut w = BufWriter::new(stdout.lock());
    for line in stdin.lock().lines() {
        let line = line.unwrap();
        if line.is_empty() {
            continue;
        }
        let f: Vec<Option<String>> = line.split('\t').map(unhex).collect();
        // rust-url itself can panic on some setter chains: record it instead of aborting.
        let out = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(&f))) {
            Ok(o) => o,
            Err(_) => vec!["RUST-PANIC".to_string()],
        };
        let enc: Vec<String> = out.iter().map(|s| hex(s)).collect();
        writeln!(w, "{}", enc.join("\t")).unwrap();
    }
}
