// `discard` is only valid in the fragment stage, also through a called helper.
fn kill() { discard; }
@vertex fn vs_main() -> @builtin(position) vec4<f32> { kill(); return vec4<f32>(0.0); }
