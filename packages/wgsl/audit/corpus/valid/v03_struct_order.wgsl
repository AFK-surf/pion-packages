// Struct `Outer` uses `Inner` which is declared later; alias refers to a later struct.
alias OuterAlias = Outer;
struct Outer { a : Inner, b : f32 }
struct Inner { x : vec2<f32> }
@group(0) @binding(0) var<storage, read_write> buf : array<OuterAlias, 4>;
@compute @workgroup_size(1)
fn cs_main() {
  buf[0].a.x = vec2<f32>(1.0, 2.0);
}
