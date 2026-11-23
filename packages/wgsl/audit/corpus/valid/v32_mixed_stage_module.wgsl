// One module with a vertex entry and a compute entry using workgroup memory and a storage buffer.
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
var<workgroup> scratch : array<f32, 64>;
@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> @builtin(position) vec4<f32> {
  return vec4<f32>(f32(vi), 0.0, 0.0, 1.0);
}
@compute @workgroup_size(64)
fn cs_main(@builtin(local_invocation_index) li : u32) {
  scratch[li] = f32(li);
  workgroupBarrier();
  o[li] = scratch[63u - li];
}
