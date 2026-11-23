// Identifiers that are legal in WGSL but keywords / types / macros in Metal C++.
struct device { constant : f32, thread : f32 }
@group(0) @binding(0) var<storage, read_write> half : array<f32>;
fn kernel(float : f32, int : f32) -> f32 { return float + int; }
@compute @workgroup_size(1)
fn cs_main() {
  var threadgroup : device;
  threadgroup.constant = 1.0;
  threadgroup.thread = 2.0;
  let uint = kernel(threadgroup.constant, threadgroup.thread);
  let char = uint * 2.0;
  half[0] = char;
}
