//! Rust `y-octo` (--release) side of the red-team workloads (see bench/pion_bench/src/main.pion for the spec).
use y_octo::{Doc, DocOptions, Text};

struct Rng(u32);
impl Rng {
    fn next(&mut self) -> u32 {
        self.0 = self.0.wrapping_mul(1664525).wrapping_add(1013904223);
        self.0 >> 1
    }
}

const L: &[u8] = b"abcdefghijklmnopqrstuvwxyz";

fn new_t(id: u64) -> (Doc, Text) {
    let d = Doc::with_options(DocOptions {
        client_id: id,
        ..DocOptions::default()
    });
    let t = d.get_or_create_text("text").unwrap();
    (d, t)
}

fn len(t: &Text) -> u32 {
    t.len() as u32
}

fn ins(t: &mut Text, i: u32, s: &str) {
    t.insert(i as u64, s).unwrap();
}

fn del(t: &mut Text, i: u32, n: u32) {
    t.remove(i as u64, n as u64).unwrap();
}

fn w_text(ops: u32) -> String {
    let mut rng = Rng(123456789);
    let (_d, mut t) = new_t(1);
    let words = ["a", "the ", "pion ", "crdt ", "x", "yjs ", "fast ", "sync "];
    let mut cursor = 0u32;
    for _ in 0..ops {
        let r = rng.next();
        let cur = len(&t);
        let mode = r % 20;
        if mode < 12 || cur == 0 {
            if cursor > cur {
                cursor = cur;
            }
            let w = words[((r >> 4) % 8) as usize];
            ins(&mut t, cursor, w);
            cursor += w.len() as u32;
        } else if mode < 17 {
            let pos = (r >> 5) % (cur + 1);
            let w = words[((r >> 12) % 8) as usize];
            ins(&mut t, pos, w);
            cursor = pos + w.len() as u32;
        } else {
            let pos = (r >> 5) % cur;
            let max_d = cur - pos;
            let dl = 1 + ((r >> 12) % 4);
            del(&mut t, pos, dl.min(max_d));
            cursor = pos;
        }
    }
    t.to_string()
}

fn w_append(n: u32) -> String {
    let (_d, mut t) = new_t(1);
    for i in 0..n {
        let c = L[(i % 26) as usize] as char;
        ins(&mut t, i, c.encode_utf8(&mut [0; 4]));
    }
    t.to_string()
}

fn w_tomb(n: u32) -> String {
    let mut rng = Rng(987654321);
    let (_d, mut t) = new_t(1);
    for i in 0..n {
        let c = L[(i % 26) as usize] as char;
        ins(&mut t, i, c.encode_utf8(&mut [0; 4]));
    }
    for p in (0..n).rev() {
        if p % 2 == 1 {
            del(&mut t, p, 1);
        }
    }
    for _ in 0..n / 5 {
        let pos = rng.next() % (len(&t) + 1);
        ins(&mut t, pos, "X");
    }
    t.to_string()
}

fn unhex(h: &str) -> String {
    String::from_utf8(
        (0..h.len() / 2)
            .map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap())
            .collect(),
    )
    .unwrap()
}

fn load(f: &str) -> Vec<(u32, u32, String)> {
    std::fs::read_to_string(f)
        .unwrap()
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| {
            let p: Vec<&str> = l.split(' ').collect();
            (
                p[0].parse().unwrap(),
                p[1].parse().unwrap(),
                unhex(p.get(2).copied().unwrap_or("")),
            )
        })
        .collect()
}

fn replay(ops: &[(u32, u32, String)]) -> (Doc, Text) {
    let (d, mut t) = new_t(1);
    for (p, dl, s2) in ops {
        if *dl > 0 {
            del(&mut t, *p, *dl);
        }
        if !s2.is_empty() {
            ins(&mut t, *p, s2);
        }
    }
    (d, t)
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let mode = a[1].as_str();
    if mode == "size" {
        let trace_path = if a.len() >= 5 { &a[4] } else { &a[2] };
        let ops = load(trace_path);
        let (d, _) = replay(&ops);
        let u = d.encode_update_v1().unwrap();
        println!("{}", u.len());
        return;
    }
    let (n, iters): (u32, u32) = (a[2].parse().unwrap(), a[3].parse().unwrap());
    let mut out = String::new();
    if mode == "trace" || mode == "remote" {
        if mode == "remote" {
            let h = std::fs::read_to_string(&a[4]).unwrap();
            let h = h.trim();
            let u: Vec<u8> = (0..h.len() / 2)
                .map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap())
                .collect();
            for _ in 0..iters {
                let mut r = Doc::with_options(DocOptions {
                    client_id: 2,
                    ..DocOptions::default()
                });
                r.apply_update_from_binary_v1(&u).unwrap();
                let t = r.get_or_create_text("text").unwrap();
                out = t.to_string();
            }
            println!("{} len={}", mode, out.len());
            println!("{}", out);
            return;
        }
        let ops = load(&a[4]);
        for _ in 0..iters {
            let (_d, t) = replay(&ops);
            out = t.to_string();
        }
    } else {
        for _ in 0..iters {
            out = match mode {
                "text" => w_text(n),
                "append" => w_append(n),
                _ => w_tomb(n),
            };
        }
    }
    println!("{} len={}", mode, out.len());
    println!("{}", out);
}
