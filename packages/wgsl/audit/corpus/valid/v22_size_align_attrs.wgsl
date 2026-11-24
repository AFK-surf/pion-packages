// @size changes the host-visible layout: `b` sits at byte offset 20 and S is 24 bytes.
struct S { @size(20) a : f32, b : f32 }
@group(0) @binding(0) var<storage, read_write> buf : array<S>;
@compute @workgroup_size(1)
fn cs_main() {
  buf[0].b = 5.0;
}
