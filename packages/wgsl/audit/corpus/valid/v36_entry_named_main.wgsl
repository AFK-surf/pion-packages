// Entry point and helper functions with C-reserved / MSL-reserved names.
fn sample(x : f32) -> f32 { return x; }
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1)
fn main() {
  o[0] = sample(1.0);
}
