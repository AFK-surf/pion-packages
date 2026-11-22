// Shared deterministic generators for the red-team differential oracle.
// The Pion driver (`audit/driver`) implements the exact same functions so that
// both sides see byte-identical inputs.

pub fn splitmix64(x: u64) -> u64 {
    let x = x.wrapping_add(0x9E3779B97F4A7C15);
    let mut z = x;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
    z ^ (z >> 31)
}

const SIGNED_EDGES: [u64; 6] = [
    0x7FFF_FFFF_FFFF_FFFF,
    0x8000_0000_0000_0000,
    0,
    u64::MAX,
    0x7FFF_FFFF_FFFF_FFFE,
    0x8000_0000_0000_0001,
];

/// Deterministic (hi, lo) generator for sort distributions.
pub fn gen_pair(kind: &str, i: u64, n: u64, seed: u64) -> (u64, u64) {
    let r1 = splitmix64(seed.wrapping_mul(1_000_003).wrapping_add(i.wrapping_mul(2)));
    let r2 = splitmix64(seed.wrapping_mul(1_000_003).wrapping_add(i.wrapping_mul(2) + 1));
    match kind {
        "random" => (r1, r2),
        "equal" => (0xDEAD_BEEF_0000_0001, 0x8000_0000_0000_0000),
        "sorted" => (i, i),
        "reverse" => (u64::MAX - i, u64::MAX - i),
        "lo64" => (0x0123_4567_89AB_CDEF, r2),
        "lastbyte" => (0x0123_4567_89AB_CDEF, 0xFEDC_BA98_7654_3200 | (r2 & 0xFF)),
        "signed" => (SIGNED_EDGES[(r1 % 6) as usize], SIGNED_EDGES[(r2 % 6) as usize]),
        "dup33" => {
            let g = i / 33;
            (splitmix64(seed ^ g), splitmix64(g.wrapping_add(0x5555)))
        }
        // 33 elements per group sharing a 15-byte prefix, differing only in the last byte
        "deep33" => {
            let g = i / 33;
            (splitmix64(seed ^ g), (splitmix64(g) & !0xFF) | (i % 33))
        }
        "sawtooth" => ((i % 257) << 56, n - i),
        _ => panic!("unknown kind {kind}"),
    }
}

pub fn fnv_pairs(pairs: &[(u64, u64)]) -> u64 {
    let mut h: u64 = 14695981039346656037;
    for (hi, lo) in pairs {
        for b in hi.to_be_bytes().iter().chain(lo.to_be_bytes().iter()) {
            h = (h ^ (*b as u64)).wrapping_mul(1099511628211);
        }
    }
    h
}
