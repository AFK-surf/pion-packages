// Host-shareable layout: `vec3<f32>` has size 12, so `b` sits at byte offset 12 and `S` is 16 bytes.
struct S { a : vec3<f32>, b : f32 }
@group(0) @binding(0) var<storage, read_write> buf : array<S>;
@compute @workgroup_size(1)
fn cs_main() {
  buf[0].b = 7.0;
  buf[1].a = vec3<f32>(1.0, 2.0, 3.0);
}
