#!/usr/bin/env python3
"""Generate realistic WGSL shader corpus (PBR + Compute Reduce + Particle Sim) in output dir."""
import os
import sys

PBR_WGSL = """\
struct Camera {
  view_proj : mat4x4<f32>,
  eye_pos : vec4<f32>,
}

struct Material {
  base_color : vec4<f32>,
  metallic_roughness : vec4<f32>,
  emissive : vec4<f32>,
}

struct Light {
  direction : vec4<f32>,
  color_intensity : vec4<f32>,
}

struct VsIn {
  @location(0) pos : vec3<f32>,
  @location(1) normal : vec3<f32>,
  @location(2) uv : vec2<f32>,
}

struct VsOut {
  @builtin(position) clip_pos : vec4<f32>,
  @location(0) world_pos : vec3<f32>,
  @location(1) normal : vec3<f32>,
  @location(2) uv : vec2<f32>,
}

@group(0) @binding(0) var<uniform> cam : Camera;
@group(0) @binding(1) var<uniform> mat : Material;
@group(0) @binding(2) var<uniform> sun : Light;
@group(1) @binding(0) var albedo_tex : texture_2d<f32>;
@group(1) @binding(1) var linear_samp : sampler;

const PI : f32 = 3.14159265;

fn fresnel_schlick(cos_theta : f32, f0 : vec3<f32>) -> vec3<f32> {
  let m = clamp(1.0 - cos_theta, 0.0, 1.0);
  let m2 = m * m;
  return f0 + (vec3<f32>(1.0, 1.0, 1.0) - f0) * (m2 * m2 * m);
}

fn distribution_ggx(ndoth : f32, roughness : f32) -> f32 {
  let a = roughness * roughness;
  let a2 = a * a;
  let denom = ndoth * ndoth * (a2 - 1.0) + 1.0;
  return a2 / max(PI * denom * denom, 0.0001);
}

fn geometry_schlick(ndotv : f32, roughness : f32) -> f32 {
  let r = roughness + 1.0;
  let k = (r * r) / 8.0;
  return ndotv / max(ndotv * (1.0 - k) + k, 0.0001);
}

@vertex
fn vs_main(in : VsIn) -> VsOut {
  var out : VsOut;
  out.clip_pos = cam.view_proj * vec4<f32>(in.pos, 1.0);
  out.world_pos = in.pos;
  out.normal = normalize(in.normal);
  out.uv = in.uv;
  return out;
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
  let tex_col = textureSample(albedo_tex, linear_samp, in.uv);
  let albedo = tex_col.rgb * mat.base_color.rgb;
  let metallic = clamp(mat.metallic_roughness.x, 0.0, 1.0);
  let roughness = clamp(mat.metallic_roughness.y, 0.05, 1.0);
  let n = normalize(in.normal);
  let v = normalize(cam.eye_pos.xyz - in.world_pos);
  let l = normalize(-sun.direction.xyz);
  let h = normalize(v + l);
  let ndotl = max(dot(n, l), 0.0);
  let ndotv = max(dot(n, v), 0.001);
  let ndoth = max(dot(n, h), 0.0);
  let hdotv = max(dot(h, v), 0.0);
  let f0 = mix(vec3<f32>(0.04, 0.04, 0.04), albedo, metallic);
  let f = fresnel_schlick(hdotv, f0);
  let ndf = distribution_ggx(ndoth, roughness);
  let g = geometry_schlick(ndotv, roughness) * geometry_schlick(ndotl, roughness);
  let spec = (ndf * g * f) / max(4.0 * ndotv * ndotl, 0.001);
  let kd = (vec3<f32>(1.0, 1.0, 1.0) - f) * (1.0 - metallic);
  let radiance = sun.color_intensity.rgb * sun.color_intensity.w;
  let lo = (kd * albedo / PI + spec) * radiance * ndotl;
  let ambient = albedo * 0.08 + mat.emissive.rgb;
  let color = ambient + lo;
  let mapped = color / (color + vec3<f32>(1.0, 1.0, 1.0));
  return vec4<f32>(mapped, tex_col.a * mat.base_color.a);
}
"""

REDUCE_WGSL = """\
struct ReduceConfig {
  count : u32,
  stride : u32,
}

@group(0) @binding(0) var<uniform> cfg : ReduceConfig;
@group(0) @binding(1) var<storage, read> src_vals : array<f32>;
@group(0) @binding(2) var<storage, read_write> dst_vals : array<f32>;
var<workgroup> tile : array<f32, 64>;

@compute @workgroup_size(64, 1, 1)
fn reduce_main(
  @builtin(global_invocation_id) gid : vec3<u32>,
  @builtin(local_invocation_id) lid : vec3<u32>,
  @builtin(workgroup_id) wid : vec3<u32>,
) {
  let idx = gid.x;
  var acc : f32 = 0.0;
  if idx < cfg.count {
    acc = src_vals[idx];
  }
  tile[lid.x] = acc;
  workgroupBarrier();
  var step_size : u32 = 32u;
  while step_size > 0u {
    if lid.x < step_size {
      tile[lid.x] = tile[lid.x] + tile[lid.x + step_size];
    }
    workgroupBarrier();
    step_size = step_size >> 1u;
  }
  if lid.x == 0u {
    dst_vals[wid.x] = tile[0];
  }
}
"""

PARTICLE_WGSL = """\
struct SimParams {
  dt : f32,
  gravity : f32,
  damping : f32,
  count : u32,
  mode : u32,
}

struct Particle {
  pos : vec4<f32>,
  vel : vec4<f32>,
}

@group(0) @binding(0) var<uniform> params : SimParams;
@group(0) @binding(1) var<storage, read_write> particles : array<Particle>;

fn hash_u32(x_in : u32) -> u32 {
  var x = x_in;
  x = x ^ (x >> 16u);
  x = x * 0x7feb352du;
  x = x ^ (x >> 15u);
  x = x * 0x846ca68bu;
  x = x ^ (x >> 16u);
  return x;
}

@compute @workgroup_size(64, 1, 1)
fn step_particles(@builtin(global_invocation_id) gid : vec3<u32>) {
  let idx = gid.x;
  if idx >= params.count {
    return;
  }
  var p = particles[idx];
  var force = vec3<f32>(0.0, -params.gravity, 0.0);
  switch params.mode {
    case 1u: {
      let h = hash_u32(idx);
      let swirl = f32(h & 255u) / 255.0 - 0.5;
      force.x = force.x + swirl * 2.0;
    }
    case 2u: {
      let radial = normalize(p.pos.xyz + vec3<f32>(0.0001, 0.0, 0.0));
      force = force - radial * 1.5;
    }
    default: {
      force.z = force.z + sin(p.pos.x) * 0.25;
    }
  }
  p.vel = vec4<f32>((p.vel.xyz + force * params.dt) * params.damping, p.vel.w);
  p.pos = vec4<f32>(p.pos.xyz + p.vel.xyz * params.dt, p.pos.w + params.dt);
  if p.pos.y < 0.0 {
    p.pos.y = 0.0;
    p.vel.y = abs(p.vel.y) * 0.75;
  }
  particles[idx] = p;
}
"""


def main() -> int:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-wgsl-bench"
    os.makedirs(out_dir, exist_ok=True)
    files = [
        ("pbr.wgsl", PBR_WGSL),
        ("compute_reduce.wgsl", REDUCE_WGSL),
        ("particles.wgsl", PARTICLE_WGSL),
    ]
    total = 0
    for name, content in files:
        path = os.path.join(out_dir, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        total += len(content.encode("utf-8"))
    print(total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
