// Helper function reads a module-scope uniform (ubiquitous in real shaders).
struct Camera { view_proj : mat4x4<f32>, eye : vec4<f32> }
@group(0) @binding(0) var<uniform> cam : Camera;
fn to_clip(p : vec3<f32>) -> vec4<f32> {
  return cam.view_proj * vec4<f32>(p, 1.0);
}
@vertex
fn vs_main(@location(0) pos : vec3<f32>) -> @builtin(position) vec4<f32> {
  return to_clip(pos);
}
