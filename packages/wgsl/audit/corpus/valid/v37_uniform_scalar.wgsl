// Non-struct uniform and storage bindings used as values.
@group(0) @binding(0) var<uniform> gain : f32;
@group(0) @binding(1) var<uniform> tint : vec4<f32>;
@group(0) @binding(2) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1)
fn cs_main() {
  o[0] = gain * tint.x;
}
