// Two outputs of one entry point at the same @location.
struct O { @location(0) a : vec4<f32>, @location(0) b : vec4<f32> }
@fragment fn fs_main() -> O { var o : O; return o; }
