use clap::{Arg, ArgAction, Command};
use std::env;

fn build_complex_cli() -> Command {
    let mut root = Command::new("cloudctl")
        .version("1.0.0")
        .about("Cloud cluster management CLI")
        .arg(
            Arg::new("verbose")
                .short('v')
                .long("verbose")
                .action(ArgAction::Count)
                .global(true)
                .help("Increase verbosity"),
        )
        .arg(
            Arg::new("region")
                .short('r')
                .long("region")
                .default_value("us-east-1")
                .global(true)
                .help("Cloud region"),
        )
        .arg(
            Arg::new("output")
                .short('o')
                .long("output")
                .default_value("text")
                .help("Output format"),
        )
        .arg(
            Arg::new("config")
                .short('c')
                .long("config")
                .default_value("config.toml")
                .help("Config path"),
        )
        .arg(
            Arg::new("format")
                .short('f')
                .long("format")
                .default_value("json")
                .help("Payload format"),
        );

    const STR_IDS: [&str; 10] = [
        "str0", "str1", "str2", "str3", "str4", "str5", "str6", "str7", "str8", "str9",
    ];
    const STR_LONGS: [&str; 10] = [
        "str-0", "str-1", "str-2", "str-3", "str-4", "str-5", "str-6", "str-7", "str-8", "str-9",
    ];
    const STR_DEFS: [&str; 10] = [
        "def0", "def1", "def2", "def3", "def4", "def5", "def6", "def7", "def8", "def9",
    ];
    for i in 0..10 {
        root = root.arg(
            Arg::new(STR_IDS[i])
                .long(STR_LONGS[i])
                .default_value(STR_DEFS[i])
                .help("String option"),
        );
    }
    const FLAG_IDS: [&str; 10] = [
        "flag0", "flag1", "flag2", "flag3", "flag4", "flag5", "flag6", "flag7", "flag8", "flag9",
    ];
    const FLAG_LONGS: [&str; 10] = [
        "flag-0", "flag-1", "flag-2", "flag-3", "flag-4", "flag-5", "flag-6", "flag-7", "flag-8",
        "flag-9",
    ];
    for j in 0..10 {
        root = root.arg(
            Arg::new(FLAG_IDS[j])
                .long(FLAG_LONGS[j])
                .action(ArgAction::SetTrue)
                .help("Boolean flag"),
        );
    }
    const NUM_IDS: [&str; 5] = ["num0", "num1", "num2", "num3", "num4"];
    const NUM_LONGS: [&str; 5] = ["num-0", "num-1", "num-2", "num-3", "num-4"];
    for k in 0..5 {
        root = root.arg(
            Arg::new(NUM_IDS[k])
                .long(NUM_LONGS[k])
                .default_value("10")
                .help("Numeric option"),
        );
    }

    let scale = Command::new("scale")
        .about("Scale node pool")
        .arg(
            Arg::new("replicas")
                .short('n')
                .long("replicas")
                .default_value("3")
                .help("Desired replicas"),
        )
        .arg(
            Arg::new("dry_run")
                .long("dry-run")
                .action(ArgAction::SetTrue)
                .help("Dry run"),
        )
        .arg(Arg::new("target").required(true).help("Target pool name"));

    let pool = Command::new("pool")
        .about("Manage node pools")
        .subcommand(scale);
    let node = Command::new("node")
        .about("Manage nodes")
        .subcommand(pool);
    let cluster = Command::new("cluster")
        .about("Manage clusters")
        .subcommand(node);
    let cloud = Command::new("cloud")
        .about("Manage cloud resources")
        .subcommand(cluster);

    let mut full = root
        .subcommand(cloud)
        .subcommand(Command::new("status").about("Show status"))
        .subcommand(Command::new("login").about("Authenticate"))
        .subcommand(Command::new("deploy").about("Deploy workload"))
        .subcommand(Command::new("logs").about("Stream logs"));
    full.build();
    full
}

fn bench_w1() {
    let base_cmd = build_complex_cli();
    let samples: [&[&str]; 5] = [
        &[
            "cloudctl", "-vv", "--region", "ap-northeast-1", "--str-0=alpha", "--flag-2", "cloud",
            "cluster", "node", "pool", "scale", "-n", "12", "--dry-run", "pool-a",
        ],
        &[
            "cloudctl", "--region=eu-west-1", "-v", "--str-0", "beta", "--flag-0", "--flag-5",
            "cloud", "cluster", "node", "pool", "scale", "--replicas=8", "pool-b",
        ],
        &[
            "cloudctl", "--str-0=gamma", "cloud", "cluster", "node", "pool", "scale", "-vvv", "-n",
            "5", "pool-c",
        ],
        &[
            "cloudctl", "-r", "us-west-2", "--flag-2", "--num-0=42", "cloud", "cluster", "node",
            "pool", "scale", "-n", "1", "pool-d",
        ],
        &[
            "cloudctl", "-v", "--str-0=delta", "cloud", "cluster", "node", "pool", "scale",
            "--replicas", "16", "--region=cn-shanghai", "pool-e",
        ],
    ];

    let mut ops: i64 = 0;
    let mut sum_replicas: i64 = 0;
    let mut sum_verbose: i64 = 0;
    let mut sum_str_len: i64 = 0;

    for _ in 0..10000 {
        for sample in &samples {
            let m = base_cmd
                .clone()
                .try_get_matches_from(sample.iter().copied())
                .expect("w1 parse");
            sum_verbose += m.get_count("verbose") as i64;
            sum_str_len += m.get_one::<String>("region").unwrap().len() as i64;
            sum_str_len += m.get_one::<String>("str0").unwrap().len() as i64;
            if m.get_flag("flag2") {
                sum_str_len += 1;
            }
            let m1 = m.subcommand_matches("cloud").unwrap();
            let m2 = m1.subcommand_matches("cluster").unwrap();
            let m3 = m2.subcommand_matches("node").unwrap();
            let m4 = m3.subcommand_matches("pool").unwrap();
            let m5 = m4.subcommand_matches("scale").unwrap();
            let rep: i64 = m5.get_one::<String>("replicas").unwrap().parse().unwrap();
            sum_replicas += rep;
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

fn bench_w2() {
    let mut argv: Vec<String> = Vec::with_capacity(100001);
    argv.push("batch".to_string());
    for _ in 0..10000 {
        argv.push("-abc".to_string());
    }
    for _ in 0..10000 {
        argv.push("-vvv".to_string());
    }
    for k in 0..15000 {
        argv.push("-I".to_string());
        argv.push(format!("dir_{}", k));
    }
    argv.push("--".to_string());
    for p in 0..49999 {
        match p % 3 {
            0 => argv.push("--help".to_string()),
            1 => argv.push("-x".to_string()),
            _ => argv.push(format!("file_{}", p)),
        }
    }

    // Note: clap ArgAction::Count uses u8 and saturates at 255; use Append + default_missing_value to count 30,000 exact occurrences.
    let mut cmd_exact = Command::new("batch")
        .args_override_self(true)
        .arg(Arg::new("a").short('a').action(ArgAction::SetTrue))
        .arg(Arg::new("b").short('b').action(ArgAction::SetTrue))
        .arg(Arg::new("c").short('c').action(ArgAction::SetTrue))
        .arg(
            Arg::new("verbose")
                .short('v')
                .action(ArgAction::Append)
                .num_args(0)
                .default_missing_value("1"),
        )
        .arg(
            Arg::new("include")
                .short('I')
                .long("include")
                .action(ArgAction::Append),
        )
        .arg(Arg::new("files").action(ArgAction::Append));
    cmd_exact.build();

    let m = cmd_exact
        .try_get_matches_from(argv.iter().map(|s| s.as_str()))
        .expect("w2 parse");

    let a_bit = if m.get_flag("a") { 1 } else { 0 };
    let b_bit = if m.get_flag("b") { 1 } else { 0 };
    let c_bit = if m.get_flag("c") { 1 } else { 0 };
    let v_cnt = m
        .get_many::<String>("verbose")
        .map(|it| it.len())
        .unwrap_or(0);
    let inc_len = m
        .get_many::<String>("include")
        .map(|it| it.len())
        .unwrap_or(0);
    let pos_len = m
        .get_many::<String>("files")
        .map(|it| it.len())
        .unwrap_or(0);

    println!("mode=w2");
    println!("tokens={}", argv.len() - 1);
    println!("a={} b={} c={}", a_bit, b_bit, c_bit);
    println!("verbose={}", v_cnt);
    println!("includes={}", inc_len);
    println!("positionals={}", pos_len);
}

fn bench_w3() {
    let base_cmd = build_complex_cli();
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
            if let Err(err) = base_cmd.clone().try_get_matches_from(args.iter().copied()) {
                let rendered = err.to_string();
                if rendered.contains(expected) {
                    typo_hits += 1;
                }
            }
        }
    }

    let mut help_ok = 0usize;
    for _ in 0..10000 {
        let mut c = base_cmd.clone();
        let txt = c.render_help().to_string();
        if txt.contains("Usage:") {
            help_ok += 1;
        }
    }

    println!("mode=w3");
    println!("ops=20000");
    println!("typo_hits={}", typo_hits);
    println!("help_ok={}", help_ok);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: cli_bench_rust <w1|w2|w3>");
        std::process::exit(1);
    }
    match args[1].as_str() {
        "w1" => bench_w1(),
        "w2" => bench_w2(),
        "w3" => bench_w3(),
        other => {
            eprintln!("unknown mode: {}", other);
            std::process::exit(1);
        }
    }
}
