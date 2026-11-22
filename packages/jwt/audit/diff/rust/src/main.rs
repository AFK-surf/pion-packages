//! Red-team differential oracle (Rust side): RustCrypto sha2/hmac, base64 (strict
//! URL_SAFE_NO_PAD) and jsonwebtoken 12.0.0. Same CLI/output contract as the Pion oracle.
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use hmac::{Hmac, KeyInit, Mac};
use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde_json::{json, Value};
use sha2::{Digest, Sha256, Sha384, Sha512};
use std::{env, fs, process};

fn hx(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push_str(&format!("{:02x}", x));
    }
    s
}

fn unhex(s: &str) -> Vec<u8> {
    let b = s.as_bytes();
    (0..b.len() / 2)
        .map(|i| u8::from_str_radix(std::str::from_utf8(&b[2 * i..2 * i + 2]).unwrap(), 16).unwrap())
        .collect()
}

fn alg_of(s: &str) -> Algorithm {
    match s {
        "HS384" => Algorithm::HS384,
        "HS512" => Algorithm::HS512,
        _ => Algorithm::HS256,
    }
}

fn validation(alg: Algorithm) -> Validation {
    // Align with Pion Validation::new: nothing required, exp+nbf checked, no leeway, aud unchecked.
    let mut v = Validation::new(alg);
    v.required_spec_claims.clear();
    v.leeway = 0;
    v.validate_exp = true;
    v.validate_nbf = true;
    v.validate_aud = false;
    v
}

fn verdict(alg: Algorithm, key: &[u8], tok: &[u8]) -> String {
    let tok = match std::str::from_utf8(tok) {
        Ok(t) => t,
        Err(_) => return "ERR".into(),
    };
    let dk = match DecodingKey::from_secret(key) {
        Ok(k) => k,
        Err(_) => return "ERR".into(),
    };
    match decode::<Value>(tok, &dk, &validation(alg)) {
        Ok(td) => match td.claims.get("sub") {
            Some(Value::String(s)) => format!("OK sub={}", hx(s.as_bytes())),
            _ => "OK sub=-".into(),
        },
        Err(_) => "ERR".into(),
    }
}

fn hmac_hex<M: Mac + KeyInit>(key: &[u8], data: &[u8]) -> String {
    let mut m = <M as KeyInit>::new_from_slice(key).unwrap();
    m.update(data);
    hx(&m.finalize().into_bytes())
}

fn run_line(line: &str) -> String {
    let f: Vec<&str> = line.split('\t').collect();
    let res = match f[0] {
        "H256" => hx(&Sha256::digest(unhex(f[2]))),
        "H384" => hx(&Sha384::digest(unhex(f[2]))),
        "H512" => hx(&Sha512::digest(unhex(f[2]))),
        "M256" => hmac_hex::<Hmac<Sha256>>(&unhex(f[2]), &unhex(f[3])),
        "M384" => hmac_hex::<Hmac<Sha384>>(&unhex(f[2]), &unhex(f[3])),
        "M512" => hmac_hex::<Hmac<Sha512>>(&unhex(f[2]), &unhex(f[3])),
        "B64E" => URL_SAFE_NO_PAD.encode(unhex(f[2])),
        "B64D" => match URL_SAFE_NO_PAD.decode(unhex(f[2])) {
            Ok(b) => format!("OK {}", hx(&b)),
            Err(_) => "ERR".into(),
        },
        "JWTV" => verdict(alg_of(f[2]), &unhex(f[3]), &unhex(f[4])),
        _ => "UNKNOWN_OP".into(),
    };
    format!("{}\t{}", f[1], res)
}

fn emit(label: &str, alg_s: &str, key: &[u8], hdr: &Header, claims: &Value) {
    match encode(hdr, claims, &EncodingKey::from_secret(key).unwrap()) {
        Ok(t) => println!("JWTV\t{}\t{}\t{}\t{}", label, alg_s, hx(key), hx(t.as_bytes())),
        Err(e) => eprintln!("encode failed: {}: {}", label, e),
    }
}

fn run_sign() {
    let key = b"red-team-audit-secret-key-0123456789abcdef";
    let subjects = [
        "alice", "用户-é-😀", "quote\"back\\slash", "ctl\u{0001}\t\n\r\u{001f}", "line\u{2028}sep",
        "/solidus/", "",
    ];
    for (i, sub) in subjects.iter().enumerate() {
        for alg_s in ["HS256", "HS384", "HS512"] {
            let claims = json!({
                "iss": "https://issuer.example/é", "sub": sub, "aud": ["api", "β-svc"],
                "exp": 4000000000u64, "nbf": 1000000000u64, "iat": 1000000000u64,
                "jti": format!("jti-{}", i),
                "nested": {"k": [1, 2.5, null, true, {"z": "ü"}], "neg": i64::MIN},
                "role": "admin", "f": 0.1
            });
            emit(&format!("rust_sign/sub{}/{}", i, alg_s), alg_s, key, &Header::new(alg_of(alg_s)), &claims);
        }
    }
    let long_key: Vec<u8> = (0..300).map(|j| ((j * 7 + 3) & 255) as u8).collect();
    for alg_s in ["HS256", "HS384", "HS512"] {
        let mut h = Header::new(alg_of(alg_s));
        h.kid = Some("kid-ключ".into());
        emit(&format!("rust_sign/longkey/{}", alg_s), alg_s, &long_key,
             &h, &json!({"sub": "long-key", "aud": "api", "exp": 4000000000u64}));
    }
    // Valid JSON integers outside i64 (e.g. u64 ids) in a custom claim.
    emit("rust_sign/custom_u64_max", "HS256", key, &Header::new(Algorithm::HS256),
         &json!({"sub": "u64", "exp": 4000000000u64, "id": u64::MAX}));
    // RFC 7519 NumericDate may be non-integer; jsonwebtoken happily signs one.
    emit("rust_sign/exp_fractional", "HS256", key, &Header::new(Algorithm::HS256),
         &json!({"sub": "frac", "exp": 4000000000.5f64}));
}

fn run_bench(path: &str, iters: usize) {
    let content = fs::read_to_string(path).expect("read");
    let mut items = Vec::new();
    for line in content.lines().filter(|l| !l.is_empty()) {
        let f: Vec<&str> = line.split('\t').collect();
        let alg = alg_of(f[2]);
        let key = DecodingKey::from_secret(&unhex(f[3])).unwrap();
        let tok = String::from_utf8(unhex(f[4])).unwrap();
        items.push((validation(alg), key, tok));
    }
    let (mut ok, mut err) = (0usize, 0usize);
    for _ in 0..iters {
        for (v, k, t) in &items {
            match decode::<Value>(t, k, v) {
                Ok(_) => ok += 1,
                Err(_) => err += 1,
            }
        }
    }
    println!("tokens={}\niters={}\nok={}\nerr={}", items.len(), iters, ok, err);
}

fn run_parse(path: &str, iters: usize) {
    let content = fs::read_to_string(path).expect("read");
    let pays: Vec<Vec<u8>> = content
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| {
            let t = unhex(l.split('\t').nth(4).unwrap());
            let t = String::from_utf8(t).unwrap();
            t.split('.').nth(1).unwrap().as_bytes().to_vec()
        })
        .collect();
    let (mut ok, mut err) = (0usize, 0usize);
    for _ in 0..iters {
        for p in &pays {
            match URL_SAFE_NO_PAD.decode(p) {
                Ok(raw) => match serde_json::from_slice::<Value>(&raw) {
                    Ok(_) => ok += 1,
                    Err(_) => err += 1,
                },
                Err(_) => err += 1,
            }
        }
    }
    println!("tokens={}\niters={}\nok={}\nerr={}", pays.len(), iters, ok, err);
}

fn main() {
    let a: Vec<String> = env::args().collect();
    match a.get(1).map(|s| s.as_str()) {
        Some("vectors") => {
            let content = fs::read_to_string(&a[2]).expect("read");
            let mut out = String::new();
            for line in content.lines().filter(|l| !l.is_empty()) {
                out.push_str(&run_line(line));
                out.push('\n');
            }
            print!("{}", out);
        }
        Some("sign") => run_sign(),
        Some("bench") => run_bench(&a[2], a[3].parse().unwrap()),
        Some("parse") => run_parse(&a[2], a[3].parse().unwrap()),
        _ => {
            eprintln!("usage: oracle_rust vectors <file> | sign | bench <file> <iters>");
            process::exit(2);
        }
    }
}
