#!/usr/bin/env python3
"""Rewrite a copy of bench/rust (W3 hand-written trie) to use another HashMap hasher.

usage: rust_hasher_variant.py <siphash|foldhash|fnv> <copied_rust_dir>
  siphash  : unchanged (std RandomState, SipHash-1-3, as committed in bench/rust)
  foldhash : foldhash 0.2.0 fast::RandomState (seeded, DoS-resistant like Pion's runtime Map)
  fnv      : unseeded FNV-1a (fast, NOT DoS-resistant; upper bound only)
"""
import os
import sys

kind, d = sys.argv[1], sys.argv[2]
src = os.path.join(d, "src", "main.rs")
t = open(src).read()
if kind == "siphash":
    sys.exit(0)
if kind == "foldhash":
    with open(os.path.join(d, "Cargo.toml"), "a") as f:
        f.write('foldhash = "=0.2.0"\n')
    alias = "type HashMap<K, V> = std::collections::HashMap<K, V, foldhash::fast::RandomState>;"
elif kind == "fnv":
    alias = """use std::hash::{BuildHasherDefault, Hasher};
#[derive(Default)]
struct Fnv(u64);
impl Hasher for Fnv {
    fn finish(&self) -> u64 { self.0 }
    fn write(&mut self, b: &[u8]) {
        let mut h = if self.0 == 0 { 0xcbf29ce484222325 } else { self.0 };
        for &x in b { h ^= x as u64; h = h.wrapping_mul(0x100000001b3); }
        self.0 = h;
    }
}
type HashMap<K, V> = std::collections::HashMap<K, V, BuildHasherDefault<Fnv>>;"""
else:
    sys.exit("unknown variant " + kind)
t = t.replace("use std::collections::HashMap;", alias)
t = t.replace("seen_gen: HashMap::with_capacity(64)",
              "seen_gen: HashMap::with_capacity_and_hasher(64, Default::default())")
open(src, "w").write(t)
