use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};
use std::env;
use std::fs;

const KEY: &[u8] = b"pion-jwt-benchmark-secret-key-2026-0123456789abcdef";

#[derive(Serialize, Deserialize)]
struct BenchClaims {
    iss: String,
    sub: String,
    aud: String,
    exp: i64,
    nbf: i64,
    iat: i64,
    jti: String,
}

fn fnv1a_update(mut h: u64, s: &str) -> u64 {
    for &b in s.as_bytes() {
        h = (h ^ (b as u64)).wrapping_mul(1099511628211);
    }
    h
}

fn run_sign(count: usize) {
    let enc_key = EncodingKey::from_secret(KEY).expect("encoding key");
    let mut hdr256 = Header::new(Algorithm::HS256);
    hdr256.typ = None;
    let mut hdr512 = Header::new(Algorithm::HS512);
    hdr512.typ = None;

    let mut hash: u64 = 14695981039346656037;
    let mut total_bytes: i64 = 0;
    let mut first = String::new();
    let mut second = String::new();
    let mut last = String::new();

    for i in 0..count {
        let is_256 = (i & 1) == 0;
        let claims = BenchClaims {
            iss: "https://auth.pion.dev".to_string(),
            sub: format!("user-{}", i),
            aud: "api-gateway".to_string(),
            exp: 2000000000 + (i % 3600) as i64,
            nbf: 1700000000,
            iat: 1700000000,
            jti: format!("tok-{}", i),
        };
        let tok = encode(if is_256 { &hdr256 } else { &hdr512 }, &claims, &enc_key)
            .expect("encode failed");
        total_bytes += tok.len() as i64;
        hash = fnv1a_update(hash, &tok);
        if i == 0 {
            first = tok;
        } else if i == 1 {
            second = tok;
        } else if i == count - 1 {
            last = tok;
        }
    }

    println!("mode=sign");
    println!("count={}", count);
    println!("total_bytes={}", total_bytes);
    println!("hash={}", hash);
    println!("first={}", first);
    println!("second={}", second);
    println!("last={}", last);
}

fn run_verify(path: &str) {
    let content = fs::read_to_string(path).expect("failed to read corpus");
    let dec_key = DecodingKey::from_secret(KEY).expect("decoding key");

    let mut v256 = Validation::new(Algorithm::HS256);
    v256.leeway = 0;
    v256.validate_exp = true;
    v256.validate_nbf = true;
    v256.set_required_spec_claims(&["exp", "nbf", "iss", "aud"]);
    v256.set_issuer(&["https://auth.pion.dev"]);
    v256.set_audience(&["api-gateway"]);

    let mut v512 = Validation::new(Algorithm::HS512);
    v512.leeway = 0;
    v512.validate_exp = true;
    v512.validate_nbf = true;
    v512.set_required_spec_claims(&["exp", "nbf", "iss", "aud"]);
    v512.set_issuer(&["https://auth.pion.dev"]);
    v512.set_audience(&["api-gateway"]);

    let mut count: usize = 0;
    let mut ok_count: usize = 0;
    let mut exp_sum: i64 = 0;
    let mut hash: u64 = 14695981039346656037;

    for line in content.lines() {
        if line.len() <= 4 {
            continue;
        }
        let is_256 = line.as_bytes()[0] == b'2';
        let tok = &line[4..];
        count += 1;
        let td = decode::<BenchClaims>(tok, &dec_key, if is_256 { &v256 } else { &v512 })
            .expect("verify failed");
        ok_count += 1;
        exp_sum += td.claims.exp;
        hash = fnv1a_update(hash, &td.claims.sub);
        hash = fnv1a_update(hash, &td.claims.jti);
    }

    println!("mode=verify");
    println!("count={}", count);
    println!("ok={}", ok_count);
    println!("exp_sum={}", exp_sum);
    println!("hash={}", hash);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mode = args.get(1).map(|s| s.as_str()).unwrap_or("sign");
    match mode {
        "sign" => run_sign(50000),
        "verify" => {
            let path = args
                .get(2)
                .map(|s| s.as_str())
                .unwrap_or("/tmp/pion-jwt-bench/tokens_50000.txt");
            run_verify(path);
        }
        _ => {
            eprintln!("usage: jwt-bench-rust [sign|verify <path>]");
            std::process::exit(1);
        }
    }
}
