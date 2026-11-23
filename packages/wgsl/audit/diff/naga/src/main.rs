//! Rust `naga =24.0.0` oracle for the packages/wgsl red-team audit.
//!   wgsl_audit_naga classify <list> <out>      one line per file: `<path> ACCEPT` | `<path> REJECT <first error line>`
//!   wgsl_audit_naga msl <in.wgsl> <out.metal>  naga MSL (control for the Metal compiler judge)
//!   wgsl_audit_naga glsl <in.wgsl> <entry> <out.glsl>  naga GLSL (ES 300 for vertex/fragment, 450 for compute)
use std::fs;
use std::io::Write;

fn front(src: &str) -> Result<(naga::Module, naga::valid::ModuleInfo), String> {
    let module = naga::front::wgsl::parse_str(src).map_err(|e| e.emit_to_string(src))?;
    let mut v = naga::valid::Validator::new(
        naga::valid::ValidationFlags::all(),
        naga::valid::Capabilities::all(),
    );
    let info = v.validate(&module).map_err(|e| format!("{:?}", e.into_inner()))?;
    Ok((module, info))
}

fn first_line(s: &str) -> String {
    s.lines().find(|l| !l.trim().is_empty()).unwrap_or("").chars().take(160).collect()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(|s| s.as_str()) {
        Some("classify") => {
            let list = fs::read_to_string(&args[2]).expect("list");
            let mut out = String::new();
            for path in list.lines().filter(|l| !l.is_empty()) {
                let bytes = fs::read(path).unwrap_or_default();
                let line = match String::from_utf8(bytes) {
                    Err(_) => "REJECT invalid UTF-8".to_string(),
                    Ok(src) => match std::panic::catch_unwind(|| front(&src)) {
                        Ok(Ok(_)) => "ACCEPT".to_string(),
                        Ok(Err(e)) => format!("REJECT {}", first_line(&e)),
                        Err(_) => "REJECT naga-panic".to_string(),
                    },
                };
                out.push_str(&format!("{} {}\n", path, line));
            }
            fs::File::create(&args[3]).unwrap().write_all(out.as_bytes()).unwrap();
        }
        Some("msl") => {
            let src = fs::read_to_string(&args[2]).expect("read");
            let (module, info) = match front(&src) {
                Ok(x) => x,
                Err(e) => {
                    println!("REJECT {}", first_line(&e));
                    std::process::exit(1)
                }
            };
            let mut opts = naga::back::msl::Options::default();
            opts.lang_version = (2, 4);
            opts.fake_missing_bindings = false;
            // Same slot map as packages/wgsl (`group * 8 + binding`) so the GPU judge can bind both outputs
            // identically; runtime-array sizes go to buffer 30 (one u32 per runtime-sized binding).
            let mut resources = naga::back::msl::BindingMap::new();
            for (_, g) in module.global_variables.iter() {
                if let Some(rb) = &g.binding {
                    let slot = (rb.group * 8 + rb.binding) as u8;
                    let mut t = naga::back::msl::BindTarget::default();
                    t.mutable = true;
                    match module.types[g.ty].inner {
                        naga::TypeInner::Image { .. } => t.texture = Some(slot),
                        naga::TypeInner::Sampler { .. } => {
                            t.sampler = Some(naga::back::msl::BindSamplerTarget::Resource(slot))
                        }
                        _ => t.buffer = Some(slot),
                    }
                    resources.insert(rb.clone(), t);
                }
            }
            for ep in module.entry_points.iter() {
                opts.per_entry_point_map.insert(
                    ep.name.clone(),
                    naga::back::msl::EntryPointResources {
                        resources: resources.clone(),
                        push_constant_buffer: None,
                        sizes_buffer: Some(30),
                    },
                );
            }
            let pipe = naga::back::msl::PipelineOptions::default();
            match naga::back::msl::write_string(&module, &info, &opts, &pipe) {
                Ok((s, _)) => {
                    fs::write(&args[3], s).unwrap();
                    println!("OK");
                }
                Err(e) => {
                    println!("BACKEND {:?}", e);
                    std::process::exit(2)
                }
            }
        }
        Some("glsl") => {
            let src = fs::read_to_string(&args[2]).expect("read");
            let (module, info) = match front(&src) {
                Ok(x) => x,
                Err(e) => {
                    println!("REJECT {}", first_line(&e));
                    std::process::exit(1)
                }
            };
            let entry = &args[3];
            let ep = module.entry_points.iter().find(|e| &e.name == entry).expect("entry");
            let version = if ep.stage == naga::ShaderStage::Compute {
                naga::back::glsl::Version::Desktop(450)
            } else {
                naga::back::glsl::Version::Embedded { version: 300, is_webgl: false }
            };
            let opts = naga::back::glsl::Options {
                version,
                writer_flags: naga::back::glsl::WriterFlags::empty(),
                binding_map: Default::default(),
                zero_initialize_workgroup_memory: true,
            };
            let pipe = naga::back::glsl::PipelineOptions {
                shader_stage: ep.stage,
                entry_point: entry.clone(),
                multiview: None,
            };
            let mut buf = String::new();
            let r = naga::back::glsl::Writer::new(&mut buf, &module, &info, &opts, &pipe, naga::proc::BoundsCheckPolicies::default())
                .and_then(|mut w| w.write().map(|_| ()));
            match r {
                Ok(()) => {
                    fs::write(&args[4], buf).unwrap();
                    println!("OK");
                }
                Err(e) => {
                    println!("BACKEND {:?}", e);
                    std::process::exit(2)
                }
            }
        }
        Some("stages") => {
            // Stage split of the bench workload: how much of naga's time is parsing alone.
            let dir = std::path::Path::new(&args[2]);
            let iters: usize = args[3].parse().unwrap();
            let srcs: Vec<String> = ["pbr.wgsl", "compute_reduce.wgsl", "particles.wgsl"]
                .iter()
                .map(|f| fs::read_to_string(dir.join(f)).unwrap())
                .collect();
            let t0 = std::time::Instant::now();
            for _ in 0..iters {
                for s in &srcs {
                    std::hint::black_box(naga::front::wgsl::parse_str(s).unwrap());
                }
            }
            let parse = t0.elapsed().as_secs_f64() * 1e3;
            let t1 = std::time::Instant::now();
            for _ in 0..iters {
                for s in &srcs {
                    std::hint::black_box(front(s).unwrap());
                }
            }
            let pv = t1.elapsed().as_secs_f64() * 1e3;
            println!("naga parse_only_ms={:.1} parse_validate_ms={:.1} (x{} over pbr+reduce+particles, one pass each)", parse, pv, iters);
        }
        _ => {
            eprintln!("usage: classify <list> <out> | msl <in> <out> | glsl <in> <entry> <out>");
            std::process::exit(2)
        }
    }
}
