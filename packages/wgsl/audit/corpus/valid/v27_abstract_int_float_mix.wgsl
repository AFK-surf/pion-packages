// Abstract-int literals in f32 contexts and inferred `let` types.
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@group(0) @binding(1) var<storage, read_write> u : array<u32>;
@compute @workgroup_size(4)
fn cs_main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let x : f32 = 1.0;
  let y = o[0] * 2;
  let idx = gid.x;
  let v = vec3<f32>(1.0, 2.0, 3.0);
  let w = v * 2.0;
  u[idx] = idx + 1u;
  o[idx] = x + y + w.z;
}
