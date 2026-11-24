use std::env;
use std::fs;
use std::hint::black_box;
use std::path::Path;

fn compile_msl(src: &str) -> Result<(usize, usize, u32, bool), String> {
    let module = naga::front::wgsl::parse_str(src).map_err(|e| e.emit_to_string(src))?;
    let mut validator = naga::valid::Validator::new(
        naga::valid::ValidationFlags::all(),
        naga::valid::Capabilities::all(),
    );
    let info = validator.validate(&module).map_err(|e| format!("{:?}", e))?;
    let msl_opts = naga::back::msl::Options::default();
    let pipe_opts = naga::back::msl::PipelineOptions::default();
    let (msl_src, _) =
        naga::back::msl::write_string(&module, &info, &msl_opts, &pipe_opts)
            .map_err(|e| format!("{:?}", e))?;
    let entries = module.entry_points.len();
    let bindings = module
        .global_variables
        .iter()
        .filter(|(_, g)| g.binding.is_some())
        .count();
    let wg_x = module
        .entry_points
        .first()
        .map(|ep| {
            if ep.stage == naga::ShaderStage::Compute {
                ep.workgroup_size[0]
            } else {
                0
            }
        })
        .unwrap_or(0);
    let ok = black_box(msl_src).contains("#include <metal_stdlib>");
    Ok((entries, bindings, wg_x, ok))
}

fn compile_glsl(src: &str, stage: naga::ShaderStage, entry: &str, version: naga::back::glsl::Version) -> Result<bool, String> {
    let module = naga::front::wgsl::parse_str(src).map_err(|e| e.emit_to_string(src))?;
    let mut validator = naga::valid::Validator::new(
        naga::valid::ValidationFlags::all(),
        naga::valid::Capabilities::all(),
    );
    let info = validator.validate(&module).map_err(|e| format!("{:?}", e))?;
    let opts = naga::back::glsl::Options {
        version,
        writer_flags: naga::back::glsl::WriterFlags::empty(),
        binding_map: Default::default(),
        zero_initialize_workgroup_memory: false,
    };
    let pipe = naga::back::glsl::PipelineOptions {
        shader_stage: stage,
        entry_point: entry.to_string(),
        multiview: None,
    };
    let mut buf = String::new();
    let mut writer = naga::back::glsl::Writer::new(
        &mut buf,
        &module,
        &info,
        &opts,
        &pipe,
        naga::proc::BoundsCheckPolicies::default(),
    )
    .map_err(|e| format!("{:?}", e))?;
    writer.write().map_err(|e| format!("{:?}", e))?;
    Ok(black_box(buf).starts_with("#version "))
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let dir = args.get(1).map(|s| s.as_str()).unwrap_or("/tmp/pion-wgsl-bench");
    let iters: usize = args
        .get(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(200);

    let pbr_src = fs::read_to_string(Path::new(dir).join("pbr.wgsl")).expect("read pbr.wgsl");
    let red_src = fs::read_to_string(Path::new(dir).join("compute_reduce.wgsl"))
        .expect("read compute_reduce.wgsl");
    let part_src =
        fs::read_to_string(Path::new(dir).join("particles.wgsl")).expect("read particles.wgsl");

    let mut entries_total: usize = 0;
    let mut bindings_total: usize = 0;
    let mut wg_x_total: u64 = 0;
    let mut msl_ok: usize = 0;
    let mut glsl_ok: usize = 0;

    let es300 = naga::back::glsl::Version::Embedded {
        version: 300,
        is_webgl: true,
    };
    let gl450 = naga::back::glsl::Version::Desktop(450);

    for _ in 0..iters {
        let (e1, b1, _, ok1) = compile_msl(&pbr_src).expect("pbr msl");
        entries_total += e1;
        bindings_total += b1;
        if ok1 {
            msl_ok += 1;
        }
        if compile_glsl(&pbr_src, naga::ShaderStage::Vertex, "vs_main", es300).expect("pbr vs glsl")
        {
            glsl_ok += 1;
        }
        if compile_glsl(&pbr_src, naga::ShaderStage::Fragment, "fs_main", es300)
            .expect("pbr fs glsl")
        {
            glsl_ok += 1;
        }

        let (e2, b2, w2, ok2) = compile_msl(&red_src).expect("reduce msl");
        entries_total += e2;
        bindings_total += b2;
        wg_x_total += w2 as u64;
        if ok2 {
            msl_ok += 1;
        }
        if compile_glsl(&red_src, naga::ShaderStage::Compute, "reduce_main", gl450)
            .expect("reduce glsl")
        {
            glsl_ok += 1;
        }

        let (e3, b3, w3, ok3) = compile_msl(&part_src).expect("particles msl");
        entries_total += e3;
        bindings_total += b3;
        wg_x_total += w3 as u64;
        if ok3 {
            msl_ok += 1;
        }
        if compile_glsl(&part_src, naga::ShaderStage::Compute, "step_particles", gl450)
            .expect("particles glsl")
        {
            glsl_ok += 1;
        }
    }

    println!("iters={}", iters);
    println!("entries={}", entries_total);
    println!("bindings={}", bindings_total);
    println!("wg_x_sum={}", wg_x_total);
    println!("msl_ok={}", msl_ok);
    println!("glsl_ok={}", glsl_ok);
}
