use glsl::parser::Parse;
use glsl::syntax::{
    ArraySpecifierDimension, Declaration, Expr, ExternalDeclaration, LayoutQualifierSpec,
    Preprocessor, PreprocessorVersionProfile, StorageQualifier, TranslationUnit, TypeQualifierSpec,
    TypeSpecifierNonArray,
};
use std::env;
use std::fs;

#[derive(Clone)]
struct VarInfo {
    name: String,
    glsl_type: String,
    array_size: i32,
    location: i32,
}

fn type_spec_name(ts: &TypeSpecifierNonArray) -> String {
    match ts {
        TypeSpecifierNonArray::Void => "void".into(),
        TypeSpecifierNonArray::Bool => "bool".into(),
        TypeSpecifierNonArray::Int => "int".into(),
        TypeSpecifierNonArray::UInt => "uint".into(),
        TypeSpecifierNonArray::Float => "float".into(),
        TypeSpecifierNonArray::Double => "double".into(),
        TypeSpecifierNonArray::Vec2 => "vec2".into(),
        TypeSpecifierNonArray::Vec3 => "vec3".into(),
        TypeSpecifierNonArray::Vec4 => "vec4".into(),
        TypeSpecifierNonArray::BVec2 => "bvec2".into(),
        TypeSpecifierNonArray::BVec3 => "bvec3".into(),
        TypeSpecifierNonArray::BVec4 => "bvec4".into(),
        TypeSpecifierNonArray::IVec2 => "ivec2".into(),
        TypeSpecifierNonArray::IVec3 => "ivec3".into(),
        TypeSpecifierNonArray::IVec4 => "ivec4".into(),
        TypeSpecifierNonArray::UVec2 => "uvec2".into(),
        TypeSpecifierNonArray::UVec3 => "uvec3".into(),
        TypeSpecifierNonArray::UVec4 => "uvec4".into(),
        TypeSpecifierNonArray::Mat2 => "mat2".into(),
        TypeSpecifierNonArray::Mat3 => "mat3".into(),
        TypeSpecifierNonArray::Mat4 => "mat4".into(),
        TypeSpecifierNonArray::Mat23 => "mat2x3".into(),
        TypeSpecifierNonArray::Mat24 => "mat2x4".into(),
        TypeSpecifierNonArray::Mat32 => "mat3x2".into(),
        TypeSpecifierNonArray::Mat34 => "mat3x4".into(),
        TypeSpecifierNonArray::Mat42 => "mat4x2".into(),
        TypeSpecifierNonArray::Mat43 => "mat4x3".into(),
        TypeSpecifierNonArray::Sampler2D => "sampler2D".into(),
        TypeSpecifierNonArray::SamplerCube => "samplerCube".into(),
        TypeSpecifierNonArray::Sampler3D => "sampler3D".into(),
        TypeSpecifierNonArray::Sampler2DArray => "sampler2DArray".into(),
        TypeSpecifierNonArray::Sampler2DShadow => "sampler2DShadow".into(),
        TypeSpecifierNonArray::SamplerCubeShadow => "samplerCubeShadow".into(),
        TypeSpecifierNonArray::Sampler2DArrayShadow => "sampler2DArrayShadow".into(),
        TypeSpecifierNonArray::ISampler2D => "isampler2D".into(),
        TypeSpecifierNonArray::ISampler3D => "isampler3D".into(),
        TypeSpecifierNonArray::ISamplerCube => "isamplerCube".into(),
        TypeSpecifierNonArray::ISampler2DArray => "isampler2DArray".into(),
        TypeSpecifierNonArray::USampler2D => "usampler2D".into(),
        TypeSpecifierNonArray::USampler3D => "usampler3D".into(),
        TypeSpecifierNonArray::USamplerCube => "usamplerCube".into(),
        TypeSpecifierNonArray::USampler2DArray => "usampler2DArray".into(),
        TypeSpecifierNonArray::TypeName(tn) => tn.0.clone(),
        TypeSpecifierNonArray::Struct(st) => st
            .name
            .as_ref()
            .map(|n| n.0.clone())
            .unwrap_or_else(|| "struct".into()),
        other => format!("{:?}", other),
    }
}

fn is_sampler_type(t: &str) -> bool {
    matches!(
        t,
        "sampler2D"
            | "samplerCube"
            | "sampler3D"
            | "sampler2DArray"
            | "sampler2DShadow"
            | "samplerCubeShadow"
            | "sampler2DArrayShadow"
            | "isampler2D"
            | "isampler3D"
            | "isamplerCube"
            | "isampler2DArray"
            | "usampler2D"
            | "usampler3D"
            | "usamplerCube"
            | "usampler2DArray"
    )
}

fn eval_arr_dim(dim: &ArraySpecifierDimension) -> i32 {
    match dim {
        ArraySpecifierDimension::ExplicitlySized(expr) => match expr.as_ref() {
            Expr::IntConst(v) => *v,
            Expr::UIntConst(v) => *v as i32,
            _ => -1,
        },
        ArraySpecifierDimension::Unsized => -1,
    }
}

fn format_vars(vars: &[VarInfo]) -> String {
    let mut s = format!("{}:", vars.len());
    for (i, v) in vars.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(&v.name);
        s.push(':');
        s.push_str(&v.glsl_type);
        if v.array_size > 0 {
            s.push_str(&format!("[{}]", v.array_size));
        }
        if v.location >= 0 {
            s.push_str(&format!("@{}", v.location));
        }
    }
    s
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: rust_glsl_bench <vert|frag> <shader_path> <iters>");
        std::process::exit(1);
    }
    let is_vertex = args[1] == "vert";
    let path = &args[2];
    let iters: usize = args[3].parse().expect("invalid iters");
    let source = fs::read_to_string(path).expect("failed to read shader");

    let mut version = "es100";
    let mut attributes: Vec<VarInfo> = Vec::new();
    let mut uniforms: Vec<VarInfo> = Vec::new();
    let mut varyings: Vec<VarInfo> = Vec::new();
    let mut outputs: Vec<VarInfo> = Vec::new();
    let mut extensions: Vec<String> = Vec::new();
    let mut uses_frag_color = false;
    let mut uses_frag_data = false;

    for _ in 0..iters {
        let tu = TranslationUnit::parse(&source).expect("glsl parse failed");
        let mut out_glsl = String::with_capacity(source.len());
        glsl::transpiler::glsl::show_translation_unit(&mut out_glsl, &tu);

        version = "es100";
        attributes.clear();
        uniforms.clear();
        varyings.clear();
        outputs.clear();
        extensions.clear();

        for ext in &tu.0 {
            match ext {
                ExternalDeclaration::Preprocessor(pp) => match pp {
                    Preprocessor::Version(v) => {
                        if v.version == 300
                            && matches!(v.profile, Some(PreprocessorVersionProfile::ES))
                        {
                            version = "es300";
                        }
                    }
                    Preprocessor::Extension(e) => {
                        let name = match &e.name {
                            glsl::syntax::PreprocessorExtensionName::All => "all".to_string(),
                            glsl::syntax::PreprocessorExtensionName::Specific(s) => s.clone(),
                        };
                        if !extensions.contains(&name) {
                            extensions.push(name);
                        }
                    }
                    _ => {}
                },
                ExternalDeclaration::Declaration(decl) => match decl {
                    Declaration::InitDeclaratorList(list) => {
                        let mut storage: Option<&str> = None;
                        let mut location: i32 = -1;
                        if let Some(q) = &list.head.ty.qualifier {
                            for spec in &q.qualifiers.0 {
                                match spec {
                                    TypeQualifierSpec::Storage(sq) => match sq {
                                        StorageQualifier::Attribute => storage = Some("attribute"),
                                        StorageQualifier::Varying => storage = Some("varying"),
                                        StorageQualifier::Uniform => storage = Some("uniform"),
                                        StorageQualifier::In => storage = Some("in"),
                                        StorageQualifier::Out => storage = Some("out"),
                                        _ => {}
                                    },
                                    TypeQualifierSpec::Layout(lq) => {
                                        for ls in &lq.ids.0 {
                                            if let LayoutQualifierSpec::Identifier(id, Some(expr)) = ls {
                                                if id.0 == "location" {
                                                    if let Expr::IntConst(v) = expr.as_ref() {
                                                        location = *v;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    _ => {}
                                }
                            }
                        }
                        if let Some(st) = storage {
                            let ty_name = type_spec_name(&list.head.ty.ty.ty);
                            let type_arr = list
                                .head
                                .ty
                                .ty
                                .array_specifier
                                .as_ref()
                                .and_then(|a| a.dimensions.0.first())
                                .map(eval_arr_dim)
                                .unwrap_or(0);

                            let mut push_var = |name: String, arr: i32| {
                                let info = VarInfo {
                                    name,
                                    glsl_type: ty_name.clone(),
                                    array_size: arr,
                                    location,
                                };
                                if st == "uniform" {
                                    uniforms.push(info);
                                } else if version == "es100" {
                                    if st == "attribute" {
                                        attributes.push(info);
                                    } else if st == "varying" {
                                        varyings.push(info);
                                    }
                                } else if is_vertex {
                                    if st == "in" {
                                        attributes.push(info);
                                    } else if st == "out" {
                                        varyings.push(info);
                                    }
                                } else if st == "in" {
                                    varyings.push(info);
                                } else if st == "out" {
                                    outputs.push(info);
                                }
                            };

                            if let Some(name) = &list.head.name {
                                let arr = list
                                    .head
                                    .array_specifier
                                    .as_ref()
                                    .and_then(|a| a.dimensions.0.first())
                                    .map(eval_arr_dim)
                                    .unwrap_or(type_arr);
                                push_var(name.0.clone(), arr);
                            }
                            for tail in &list.tail {
                                let arr = tail
                                    .ident
                                    .array_spec
                                    .as_ref()
                                    .and_then(|a| a.dimensions.0.first())
                                    .map(eval_arr_dim)
                                    .unwrap_or(type_arr);
                                push_var(tail.ident.ident.0.clone(), arr);
                            }
                        }
                    }
                    Declaration::Block(blk) => {
                        let mut is_uniform = false;
                        for spec in &blk.qualifier.qualifiers.0 {
                            if matches!(spec, TypeQualifierSpec::Storage(StorageQualifier::Uniform)) {
                                is_uniform = true;
                            }
                        }
                        if is_uniform {
                            uniforms.push(VarInfo {
                                name: blk.name.0.clone(),
                                glsl_type: "uniform_block".to_string(),
                                array_size: 0,
                                location: -1,
                            });
                        }
                    }
                    _ => {}
                },
                _ => {}
            }
        }
        uses_frag_color = !is_vertex && out_glsl.contains("gl_FragColor");
        uses_frag_data = !is_vertex && out_glsl.contains("gl_FragData");
    }

    let samplers: Vec<VarInfo> = uniforms
        .iter()
        .filter(|u| is_sampler_type(&u.glsl_type))
        .cloned()
        .collect();

    println!("iters={}", iters);
    println!(
        "stage={} version={}",
        if is_vertex { "vertex" } else { "fragment" },
        version
    );
    println!("attributes={}", format_vars(&attributes));
    println!("uniforms={}", format_vars(&uniforms));
    println!("varyings={}", format_vars(&varyings));
    println!("outputs={}", format_vars(&outputs));
    println!("samplers={}", format_vars(&samplers));
    println!("extensions={}:{}", extensions.len(), extensions.join(","));
    println!("frag_color={} frag_data={}", uses_frag_color, uses_frag_data);
}
