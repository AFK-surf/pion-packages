use minijinja::{context, Environment};

fn main() {
    let mut env = Environment::new();
    let prompt_tpl = "System: You are {{ agent.name }} (mode={{ agent.mode|default('balanced') }}).\n{% if agent.strict %}Follow all constraints strictly.\n{% endif %}Capabilities: {{ capabilities|join(', ') }}.\nTools ({{ tools|length }}):\n{% for tool in tools %}- {{ loop.index }}. {{ tool.name }}: {{ tool.desc }} | schema={{ tool.schema|tojson(indent=2) }}\n{% endfor %}User: {{ query }}";
    env.add_template("prompt.txt", prompt_tpl).unwrap();
    let tpl = env.get_template("prompt.txt").unwrap();

    let ctx = context!(
        agent => context!(
            name => "PionCoder",
            strict => true,
        ),
        capabilities => vec!["code-search", "shell", "patch", "test"],
        tools => vec![
            context!(
                name => "read_file",
                desc => "Read a file from workspace",
                schema => context!(
                    path => "string",
                    limit => 800,
                ),
            ),
            context!(
                name => "edit_file",
                desc => "Apply a targeted replacement",
                schema => context!(
                    path => "string",
                    atomic => true,
                ),
            ),
            context!(
                name => "run_test",
                desc => "Execute package test suite",
                schema => context!(
                    pkg => "string",
                    jobs => 4,
                ),
            ),
        ],
        query => "Optimize the template AST evaluator hot path.",
    );

    let iters = 20000usize;
    let mut total_bytes = 0u64;
    let mut last = String::new();
    for r in 0..iters {
        let out = tpl.render(&ctx).unwrap();
        total_bytes += out.len() as u64;
        if r == iters - 1 {
            last = out;
        }
    }

    println!("iters={}", iters);
    println!("total_bytes={}", total_bytes);
    println!("{}", last);
}
