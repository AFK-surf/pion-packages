// Shadowing a module-scope name inside a function and nested shadowing.
const k : f32 = 1.0;
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1)
fn cs_main() {
  let k = 2.0;
  {
    let k = 3.0;
    o[0] = k;
  }
  o[1] = k;
}
