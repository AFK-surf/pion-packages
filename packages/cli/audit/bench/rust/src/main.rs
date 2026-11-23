//! Fairness-audit clap modes. The upstream bench file is `include!`d verbatim, so `build_complex_cli`,
//! the samples and the clap feature set are byte-identical to `bench/rust` (d65ed21).
//! - `w1_mut`  : upstream w1 without the per-parse `Command::clone()` (`try_get_matches_from_mut`).
//! - `w1_cold` : build the command + parse per op (cold path; compare with Pion `w1_cold`).
//! - `w3_ctx`  : upstream w3 without clones, reading the suggestion from the structured error context
//!               (`ContextKind::SuggestedArg`) instead of rendering the message; help via `&mut` render.
#[allow(dead_code)]
mod upstream {
    include!("../../../../bench/rust/src/main.rs");

    use clap::error::{ContextKind, ContextValue};

    const SAMPLES: [&[&str]; 5] = [
        &["cloudctl", "-vv", "--region", "ap-northeast-1", "--str-0=alpha", "--flag-2", "cloud", "cluster", "node", "pool", "scale", "-n", "12", "--dry-run", "pool-a"],
        &["cloudctl", "--region=eu-west-1", "-v", "--str-0", "beta", "--flag-0", "--flag-5", "cloud", "cluster", "node", "pool", "scale", "--replicas=8", "pool-b"],
        &["cloudctl", "--str-0=gamma", "cloud", "cluster", "node", "pool", "scale", "-vvv", "-n", "5", "pool-c"],
        &["cloudctl", "-r", "us-west-2", "--flag-2", "--num-0=42", "cloud", "cluster", "node", "pool", "scale", "-n", "1", "pool-d"],
        &["cloudctl", "-v", "--str-0=delta", "cloud", "cluster", "node", "pool", "scale", "--replicas", "16", "--region=cn-shanghai", "pool-e"],
    ];

    fn w1_with(mut get: impl FnMut(&[&str]) -> clap::ArgMatches) {
        let (mut ops, mut sum_replicas, mut sum_verbose, mut sum_str_len) = (0i64, 0i64, 0i64, 0i64);
        for _ in 0..10000 {
            for sample in &SAMPLES {
                let m = get(sample);
                sum_verbose += m.get_count("verbose") as i64;
                sum_str_len += m.get_one::<String>("region").unwrap().len() as i64;
                sum_str_len += m.get_one::<String>("str0").unwrap().len() as i64;
                if m.get_flag("flag2") {
                    sum_str_len += 1;
                }
                let m5 = m.subcommand_matches("cloud").unwrap().subcommand_matches("cluster").unwrap()
                    .subcommand_matches("node").unwrap().subcommand_matches("pool").unwrap()
                    .subcommand_matches("scale").unwrap();
                sum_replicas += m5.get_one::<String>("replicas").unwrap().parse::<i64>().unwrap();
                sum_str_len += m5.get_one::<String>("target").unwrap().len() as i64;
                ops += 1;
            }
        }
        println!("mode=w1");
        println!("ops={}", ops);
        println!("sum_replicas={}", sum_replicas);
        println!("sum_verbose={}", sum_verbose);
        println!("sum_str_len={}", sum_str_len);
    }

    pub fn w1_mut() {
        let mut cmd = build_complex_cli();
        w1_with(|s| cmd.try_get_matches_from_mut(s.iter().copied()).expect("w1 parse"));
    }

    pub fn w1_cold() {
        w1_with(|s| build_complex_cli().try_get_matches_from(s.iter().copied()).expect("w1 parse"));
    }

    pub fn w3_ctx() {
        let mut cmd = build_complex_cli();
        let typos: [(&[&str], &str); 5] = [
            (&["cloudctl", "--outptu"], "--output"),
            (&["cloudctl", "--confgi"], "--config"),
            (&["cloudctl", "--verbsoe"], "--verbose"),
            (&["cloudctl", "--fromat"], "--format"),
            (&["cloudctl", "--regino"], "--region"),
        ];
        let mut typo_hits = 0usize;
        for _ in 0..2000 {
            for (args, expected) in &typos {
                if let Err(err) = cmd.try_get_matches_from_mut(args.iter().copied()) {
                    if let Some(ContextValue::String(s)) = err.get(ContextKind::SuggestedArg) {
                        if s == expected {
                            typo_hits += 1;
                        }
                    }
                }
            }
        }
        let mut help_ok = 0usize;
        for _ in 0..10000 {
            if cmd.render_help().to_string().contains("Usage:") {
                help_ok += 1;
            }
        }
        println!("mode=w3");
        println!("ops=20000");
        println!("typo_hits={}", typo_hits);
        println!("help_ok={}", help_ok);
    }
}

fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("w1_mut") => upstream::w1_mut(),
        Some("w1_cold") => upstream::w1_cold(),
        Some("w3_ctx") => upstream::w3_ctx(),
        _ => std::process::exit(1),
    }
}
