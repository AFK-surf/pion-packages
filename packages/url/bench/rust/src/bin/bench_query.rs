use std::env;
use std::fs;
use url::form_urlencoded;

fn main() {
    let args: Vec<String> = env::args().collect();
    let path = args
        .get(1)
        .map(String::as_str)
        .unwrap_or("/tmp/pion-url-bench/queries_100k.txt");
    let content = fs::read_to_string(path).expect("failed to read input file");
    let lines: Vec<&str> = content.lines().filter(|l| !l.is_empty()).collect();

    let mut count: i64 = 0;
    let mut total_bytes: i64 = 0;
    let mut hash: i64 = 0;
    let mut first_out = String::new();
    let mut last_out = String::new();

    for _round in 0..2 {
        for &line in &lines {
            let mut pairs: Vec<(String, String)> = form_urlencoded::parse(line.as_bytes())
                .map(|(k, v)| (k.into_owned(), v.into_owned()))
                .collect();
            pairs.retain(|(k, _)| k != "drop");
            // set("v", "2")
            let mut found = false;
            pairs.retain_mut(|(k, v)| {
                if k == "v" {
                    if !found {
                        *v = "2".to_owned();
                        found = true;
                        true
                    } else {
                        false
                    }
                } else {
                    true
                }
            });
            if !found {
                pairs.push(("v".to_owned(), "2".to_owned()));
            }
            pairs.push(("extra".to_owned(), "ok".to_owned()));
            pairs.sort_by(|a, b| a.0.encode_utf16().cmp(b.0.encode_utf16()));

            let mut ser = form_urlencoded::Serializer::new(String::new());
            for (k, v) in &pairs {
                ser.append_pair(k, v);
            }
            let s = ser.finish();
            if count == 0 {
                first_out = s.clone();
            }
            last_out = s.clone();
            count += 1;
            total_bytes += s.len() as i64;
            for &b in s.as_bytes() {
                hash = (hash * 131 + b as i64) % 1_000_000_007;
            }
        }
    }

    println!("count={count}");
    println!("total_bytes={total_bytes}");
    println!("hash={hash}");
    println!("first={first_out}");
    println!("last={last_out}");
}
