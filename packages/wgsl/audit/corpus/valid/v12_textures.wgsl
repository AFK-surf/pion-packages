// Texture builtins beyond the 2D happy path.
@group(0) @binding(0) var t2 : texture_2d<f32>;
@group(0) @binding(1) var t3 : texture_3d<f32>;
@group(0) @binding(2) var tarr : texture_2d_array<f32>;
@group(0) @binding(3) var tc : texture_cube<f32>;
@group(0) @binding(4) var s : sampler;
@group(0) @binding(5) var st : texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(6) var td : texture_depth_2d;
@group(0) @binding(7) var sc : sampler_comparison;
@fragment
fn fs_main(@location(0) uv : vec2<f32>) -> @location(0) vec4<f32> {
  let d3 : vec3<u32> = textureDimensions(t3);
  let a = textureSample(tarr, s, uv, 1);
  let b = textureSample(tc, s, vec3<f32>(uv, 1.0));
  let c = textureLoad(t3, vec3<i32>(0, 0, 0), 0);
  let e = textureSampleGrad(t2, s, uv, vec2<f32>(0.0), vec2<f32>(0.0));
  let f = textureGather(0, t2, s, uv);
  let n = textureNumLevels(t2);
  let dc = textureSampleCompareLevel(td, sc, uv, 0.5);
  textureStore(st, vec2<i32>(0, 0), a);
  return a + b + c + e + f + vec4<f32>(f32(d3.x + n), dc, 0.0, 0.0);
}
