// Storage struct with a trailing runtime-sized array (the canonical WGSL particle buffer).
struct Particle { pos : vec4<f32>, vel : vec4<f32> }
struct Particles { count : u32, items : array<Particle> }
@group(0) @binding(0) var<storage, read_write> ps : Particles;
@compute @workgroup_size(64)
fn cs_main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let i = gid.x;
  if i >= ps.count { return; }
  ps.items[i].pos = ps.items[i].pos + ps.items[i].vel;
}
