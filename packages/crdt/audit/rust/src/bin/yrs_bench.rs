//! Rust `yrs` (--release) side of the red-team workloads (see bench/pion_bench/src/main.pion for the spec).
use yrs::updates::decoder::Decode;
use yrs::{Doc, GetString, OffsetKind, Options, ReadTxn, StateVector, Text, TextRef, Transact, Update};

struct Rng(u32);
impl Rng { fn next(&mut self) -> u32 { self.0 = self.0.wrapping_mul(1664525).wrapping_add(1013904223); self.0 >> 1 } }
const L: &[u8] = b"abcdefghijklmnopqrstuvwxyz";
fn new_t(id: u64) -> (Doc, TextRef) {
    let d = Doc::with_options(Options { client_id: yrs::block::ClientID::new(id), offset_kind: OffsetKind::Utf16, ..Options::default() });
    let t = d.get_or_insert_text("text");
    (d, t)
}
fn len(d: &Doc, t: &TextRef) -> u32 { t.len(&d.transact()) }
fn ins(d: &Doc, t: &TextRef, i: u32, s: &str) { t.insert(&mut d.transact_mut(), i, s) }
fn del(d: &Doc, t: &TextRef, i: u32, n: u32) { t.remove_range(&mut d.transact_mut(), i, n) }
fn s(d: &Doc, t: &TextRef) -> String { t.get_string(&d.transact()) }
fn w_text(ops: u32) -> String {
    let mut rng = Rng(123456789);
    let (d, t) = new_t(1);
    let words = ["a", "the ", "pion ", "crdt ", "x", "yjs ", "fast ", "sync "];
    let mut cursor = 0u32;
    for _ in 0..ops {
        let r = rng.next(); let cur = len(&d, &t); let mode = r % 20;
        if mode < 12 || cur == 0 { if cursor > cur { cursor = cur } let w = words[((r >> 4) % 8) as usize]; ins(&d, &t, cursor, w); cursor += w.len() as u32; }
        else if mode < 17 { let pos = (r >> 5) % (cur + 1); let w = words[((r >> 12) % 8) as usize]; ins(&d, &t, pos, w); cursor = pos + w.len() as u32; }
        else { let pos = (r >> 5) % cur; let max_d = cur - pos; let dl = 1 + ((r >> 12) % 4); del(&d, &t, pos, dl.min(max_d)); cursor = pos; }
    }
    s(&d, &t)
}
fn w_append(n: u32) -> String { let (d, t) = new_t(1); for i in 0..n { let c = L[(i % 26) as usize] as char; ins(&d, &t, i, c.encode_utf8(&mut [0; 4])); } s(&d, &t) }
fn w_tomb(n: u32) -> String {
    let mut rng = Rng(987654321); let (d, t) = new_t(1);
    for i in 0..n { let c = L[(i % 26) as usize] as char; ins(&d, &t, i, c.encode_utf8(&mut [0; 4])); }
    for p in (0..n).rev() { if p % 2 == 1 { del(&d, &t, p, 1) } }
    for _ in 0..n / 5 { let pos = rng.next() % (len(&d, &t) + 1); ins(&d, &t, pos, "X"); }
    s(&d, &t)
}
fn unhex(h: &str) -> String { String::from_utf8((0..h.len() / 2).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap()).collect()).unwrap() }
fn load(f: &str) -> Vec<(u32, u32, String)> {
    std::fs::read_to_string(f).unwrap().lines().filter(|l| !l.is_empty()).map(|l| { let p: Vec<&str> = l.split(' ').collect(); (p[0].parse().unwrap(), p[1].parse().unwrap(), unhex(p.get(2).copied().unwrap_or(""))) }).collect()
}
fn replay(ops: &[(u32, u32, String)]) -> (Doc, TextRef) {
    let (d, t) = new_t(1);
    for (p, dl, s2) in ops { if *dl > 0 { del(&d, &t, *p, *dl) } if !s2.is_empty() { ins(&d, &t, *p, s2) } }
    (d, t)
}
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (mode, n, iters): (&str, u32, u32) = (&a[1], a[2].parse().unwrap(), a[3].parse().unwrap());
    let mut out = String::new();
    if mode == "trace" || mode == "remote" {
        if mode == "remote" {
            let h = std::fs::read_to_string(&a[4]).unwrap();
            let h = h.trim();
            let u: Vec<u8> = (0..h.len() / 2).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap()).collect();
            for _ in 0..iters { let (r, t) = new_t(2); r.transact_mut().apply_update(Update::decode_v1(&u).unwrap()).unwrap(); out = s(&r, &t); }
            println!("{} len={}", mode, out.len());
            println!("{}", out);
            return;
        }
        let ops = load(&a[4]);
        if mode == "trace" { for _ in 0..iters { let (d, t) = replay(&ops); out = s(&d, &t); } }
        else {
            let (d, _) = replay(&ops);
            let u = d.transact().encode_state_as_update_v1(&StateVector::default());
            for _ in 0..iters { let (r, t) = new_t(2); r.transact_mut().apply_update(Update::decode_v1(&u).unwrap()).unwrap(); out = s(&r, &t); }
        }
    } else {
        for _ in 0..iters { out = match mode { "text" => w_text(n), "append" => w_append(n), _ => w_tomb(n) }; }
    }
    println!("{} len={}", mode, out.len());
    println!("{}", out);
}
