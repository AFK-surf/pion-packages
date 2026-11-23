//! Rust reference oracle for the `packages/json` red-team audit.
//!
//! serde_json =1.0.145 (`arbitrary_precision` + `preserve_order`) decides accept/reject and the
//! value tree; every number literal is then classified into the *documented* Pion number model
//! (`Int` if a pure integer literal fits i64, `BigNum(raw)` if it does not or if a fraction/exponent
//! literal overflows binary64, otherwise `Float` correctly rounded by Rust `str::parse::<f64>`).
//! Output lines use the exact dump format of `audit/driver` so `tools/compare.py` can diff them.
use serde_json::Value;
use std::io::Write;

fn unhex(h: &str) -> Vec<u8> {
    (0..h.len() / 2).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap()).collect()
}
fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02x}", x)).collect()
}

fn dump_num(raw: &str, out: &mut String) {
    let is_int = !raw.contains(['.', 'e', 'E']);
    if is_int {
        match raw.parse::<i64>() {
            Ok(v) => out.push_str(&format!("i{}", v)),
            Err(_) => out.push_str(&format!("b{}", raw)),
        }
    } else {
        let d: f64 = raw.parse().unwrap();
        if d.is_infinite() {
            out.push_str(&format!("b{}", raw));
        } else {
            out.push_str(&format!("d{:016x}", d.to_bits()));
        }
    }
}

fn dump(v: &Value, out: &mut String) {
    // iterative to survive deep inputs
    enum T<'a> { V(&'a Value), S(&'static str) }
    let mut st = vec![T::V(v)];
    while let Some(t) = st.pop() {
        match t {
            T::S(s) => out.push_str(s),
            T::V(v) => match v {
                Value::Null => out.push('n'),
                Value::Bool(b) => out.push(if *b { 't' } else { 'f' }),
                Value::Number(n) => dump_num(&n.to_string(), out),
                Value::String(s) => { out.push('s'); out.push_str(&hex(s.as_bytes())); out.push(';') }
                Value::Array(a) => {
                    out.push('[');
                    st.push(T::S("]"));
                    for (i, x) in a.iter().enumerate().rev() {
                        st.push(T::V(x));
                        if i > 0 { st.push(T::S(",")); }
                    }
                }
                Value::Object(o) => {
                    out.push('{');
                    st.push(T::S("}"));
                    let items: Vec<_> = o.iter().collect();
                    for (i, (k, x)) in items.iter().enumerate().rev() {
                        st.push(T::V(x));
                        // key printed eagerly via leaked string (oracle is short-lived)
                        let ks: &'static str = Box::leak(format!("{}{}:", if i > 0 { "," } else { "" }, hex(k.as_bytes())).into_boxed_str());
                        st.push(T::S(ks));
                    }
                }
            },
        }
    }
}

fn parse_line(bytes: &[u8]) -> String {
    match serde_json::from_slice::<Value>(bytes) {
        Ok(v) => { let mut s = String::new(); dump(&v, &mut s); s }
        Err(_) => "ERR".to_string(),
    }
}

// ---- replica of packages/json/src/object_index.pion hashing (for the HashDoS generator) ----
fn mix64(x: u64) -> u64 {
    let mut z = x.wrapping_add(0x9E3779B97F4A7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
    z ^ (z >> 31)
}
fn seed_from_str(s: &[u8]) -> u64 {
    let n = s.len();
    let mut h = mix64(0x243F6A8885A308D3 ^ (n as u64).wrapping_mul(0xD6E8FEB86659FD93));
    if n > 0 {
        h = mix64(h ^ s[0] as u64);
        h = mix64(h ^ s[n >> 1] as u64);
        h = mix64(h ^ s[n - 1] as u64);
    }
    h
}
fn hash_str_seeded(s: &[u8], seed: u64) -> u64 {
    let n = s.len();
    let mut h = seed ^ (n as u64).wrapping_mul(0x9E3779B97F4A7C15);
    let mut i = 0;
    while i + 4 <= n {
        let w = s[i] as u64 | (s[i + 1] as u64) << 8 | (s[i + 2] as u64) << 16 | (s[i + 3] as u64) << 24;
        h = (h ^ w).wrapping_mul(0xBF58476D1CE4E5B9);
        h ^= h >> 27;
        i += 4;
    }
    while i < n {
        h = (h ^ s[i] as u64).wrapping_mul(0x94D049BB133111EB);
        h ^= h >> 31;
        i += 1;
    }
    h = (h ^ (h >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    h = (h ^ (h >> 27)).wrapping_mul(0x94D049BB133111EB);
    h ^= h >> 31;
    if h == 0 { 1 } else { h }
}
/// Final capacity of the parser's `ObjIndexBuilder` (starts at 32, grows before an insert when len*8 >= cap*5).
fn final_cap(n: usize) -> u64 {
    let mut cap = 32usize;
    for len in 0..n { if len * 8 >= cap * 5 { cap <<= 1; } }
    cap as u64
}
const KEYLEN: usize = 16; // "k" + 15 base-36 chars; entry = "\"" key "\":0," = 21 bytes
fn key_of(mut c: u64) -> [u8; KEYLEN] {
    const A: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut k = [b'0'; KEYLEN];
    k[0] = b'k';
    for j in (1..KEYLEN).rev() { k[j] = A[(c % 36) as usize]; c /= 36; }
    k
}
/// `{` + `pad` spaces + N entries + `}`, with `pad` chosen so the middle byte is the fixed `0`
/// of an entry: then the per-document seed is known before any key is chosen.
fn layout(n: usize) -> (usize, usize) {
    for pad in 0..64 {
        let total = 1 + pad + 21 * n - 1 + 1;
        let mid = total >> 1;
        if mid > pad && (mid - 1 - pad) % 21 == 19 { return (pad, total); }
    }
    unreachable!()
}
fn write_doc(path: &str, keys: &[[u8; KEYLEN]], pad: usize) {
    let mut d = Vec::with_capacity(keys.len() * 21 + pad + 2);
    d.push(b'{');
    d.extend(std::iter::repeat(b' ').take(pad));
    for (i, k) in keys.iter().enumerate() {
        if i > 0 { d.push(b','); }
        d.push(b'"'); d.extend_from_slice(k); d.extend_from_slice(b"\":0");
    }
    d.push(b'}');
    std::fs::write(path, &d).unwrap();
}
fn hashgen(n: usize, evil: &str, benign: &str) {
    let (pad, total) = layout(n);
    let mut probe = vec![b'0'; total];
    probe[0] = b'{'; probe[total - 1] = b'}';
    let seed = seed_from_str(&probe); // only n, first, middle ('0') and last byte matter
    let mask = final_cap(n) - 1;
    let threads = std::thread::available_parallelism().map(|x| x.get()).unwrap_or(4).min(16) as u64;
    let per = (n as u64 + threads - 1) / threads;
    let hs: Vec<_> = (0..threads).map(|t| std::thread::spawn(move || {
        let mut out = Vec::new();
        let mut c = t << 48;
        while (out.len() as u64) < per {
            let k = key_of(c);
            if hash_str_seeded(&k, seed) & mask == 0 { out.push(k); }
            c += 1;
        }
        out
    })).collect();
    let mut keys: Vec<[u8; KEYLEN]> = hs.into_iter().flat_map(|h| h.join().unwrap()).collect();
    keys.truncate(n);
    write_doc(evil, &keys, pad);
    let check = std::fs::read(evil).unwrap();
    assert_eq!(seed_from_str(&check), seed, "layout must pin the parser seed");
    let benign_keys: Vec<_> = (0..n as u64).map(|i| key_of(i.wrapping_mul(0x9E3779B97F4A7C15) >> 8)).collect();
    write_doc(benign, &benign_keys, pad);
    println!("hashgen n={} cap={} seed={:016x} pad={}", n, mask + 1, seed, pad);
}

/// `adv wide <file> <lookups>`: parse a wide object, look up `lookups` present keys (stdout identical to Pion driver).
fn adv(args: &[String]) {
    let text = std::fs::read(&args[3]).unwrap();
    let v: Value = serde_json::from_slice(&text).unwrap();
    let o = v.as_object().unwrap();
    let keys: Vec<&String> = o.keys().collect();
    let lookups: usize = args[4].parse().unwrap();
    let mut hits = 0usize;
    let mut j = 0usize;
    for _ in 0..lookups {
        j = (j * 31 + 7) % keys.len();
        if o.get(keys[j].as_str()).is_some() { hits += 1; }
    }
    println!("keys={} hits={}", o.len(), hits);
}

/// `adv without <file>`: remove every other key of a wide object (stdout identical to the Pion driver).
fn without(args: &[String]) {
    let text = std::fs::read(&args[3]).unwrap();
    let v: Value = serde_json::from_slice(&text).unwrap();
    let o = v.as_object().unwrap();
    let drop: std::collections::HashSet<&String> = o.keys().step_by(2).collect();
    let kept: serde_json::Map<String, Value> =
        o.iter().filter(|(k, _)| !drop.contains(k)).map(|(k, v)| (k.clone(), v.clone())).collect();
    println!("kept={}", kept.len());
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut out = std::io::BufWriter::new(std::io::stdout().lock());
    match args[1].as_str() {
        "parse" => {
            for line in std::fs::read_to_string(&args[2]).unwrap().lines() {
                let hexpart = line.split('\t').next().unwrap();
                writeln!(out, "{}", parse_line(&unhex(hexpart))).unwrap();
            }
        }
        "ptr" => {
            for line in std::fs::read_to_string(&args[2]).unwrap().lines() {
                let mut it = line.split('\t');
                let doc = unhex(it.next().unwrap());
                let p = String::from_utf8(unhex(it.next().unwrap())).unwrap();
                let v: Value = serde_json::from_slice(&doc).unwrap();
                match v.pointer(&p) {
                    Some(x) => { let mut s = String::new(); dump(x, &mut s); writeln!(out, "{}", s).unwrap() }
                    None => writeln!(out, "NONE").unwrap(),
                }
            }
        }
        "hashgen" => hashgen(args[2].parse().unwrap(), &args[3], &args[4]),
        "adv" if args[2] == "without" => without(&args),
        "adv" => adv(&args),
        m => panic!("unknown mode {}", m),
    }
}
