// Module-scope private and workgroup variables referenced from helpers.
var<private> seed : u32 = 7u;
var<workgroup> tile : array<f32, 64>;
fn rnd() -> u32 { seed = seed * 1664525u + 1013904223u; return seed; }
fn store(i : u32, v : f32) { tile[i] = v; }
@compute @workgroup_size(64)
fn cs_main(@builtin(local_invocation_index) li : u32) {
  store(li, f32(rnd()));
}
