# `template`

Pure-Pion Jinja2 / [MiniJinja](https://github.com/mitsuhiko/minijinja)-compatible template engine (`v0.1.0`) for AI agent prompt rendering, reports/notifications, and HTML/XML auto-escaping SSR.

- **Zero C dependencies / zero `World` dependency** — compiles and runs identically on Native (`debug` & `--release`) and `wasm32` (`debug` & `--release`).
- **Pre-compiled AST & streaming `StringBuilder` output** — templates are parsed once into a compact AST (`Environment::add_template` / `Template`) and rendered directly into a `StringBuilder` with explicit `Result[String, TemplateError]` error handling.
- **Full Jinja2 / MiniJinja core feature set** (**41 / 41** compliance & red-team tests passing):
  - **Syntax & whitespace**: `{{ ... }}`, `{% ... %}`, `{# ... #}`, whitespace trimming (`{{-`, `-}}`, `{%-`, `-%}`, `{#-`, `-#}`), `{% raw %}...{% endraw %}`, `keep_trailing_newline`, `trim_blocks`, `lstrip_blocks`, string escapes, int/hex/octal/binary/float/bool/none literals.
  - **Expressions**: arithmetic (`+`, `-`, `*`, `/`, `//`, `%`, `**`, unary `+`/`-`), comparisons (`==`, `!=`, `<`, `<=`, `>`, `>=`), short-circuit logic (`and`, `or`, `not`), membership (`in`, `not in`), tests (`is`, `is not`), ternary (`a if c else b`), string concatenation (`~`), indexing & slicing (`a[1:3]`, `a[::2]`, `a[::-1]`), attribute access, list & dict literals, standalone `eval_expr`.
  - **Control flow**: `if`/`elif`/`else`, `for` (with `loop.index`, `index0`, `revindex`, `revindex0`, `first`, `last`, `length`, `depth`, `depth0`, `previtem`, `nextitem`, `loop.cycle(...)`, `for ... if` filter, `for ... else`, tuple unpacking `for k, v in dict|items`), `set` (inline, block `{% set x %}...{% endset %}`, namespace attribute mutation `{% set ns.total = ... %}`), `with`, `filter` block, `autoescape` block, `do`, built-in `range` (lazy O(1) memory), `dict`, `namespace`.
  - **Template reuse**: multi-level `extends` + `block` + `super()`, `include` (including `ignore missing`), `macro` (positional, default, and keyword arguments, plus `{% call %}` / `caller()`), `import ... as ...`, `from ... import ... as ...`.
  - **Built-in filters (38+)**: `upper`, `lower`, `title`, `capitalize`, `trim`, `replace`, `default`/`d`, `length`/`count`, `first`, `last`, `join`, `split`, `sort`, `reverse`, `unique`, `map`, `select`, `reject`, `selectattr`, `rejectattr`, `slice`, `batch`, `abs`, `round`, `int`, `float`, `string`, `bool`, `list`, `items`, `tojson`, `escape`/`e`, `safe`, `indent`, `wordcount`, `urlencode`, `attr`, `sum` — plus custom `add_filter`, `add_test`, `add_function`, `add_global`.
  - **Built-in tests (25+)**: `defined`, `undefined`, `none`, `boolean`, `true`, `false`, `integer`, `float`, `number`, `string`, `safe`/`escaped`, `sequence`, `mapping`, `iterable`, `odd`, `even`, `lower`, `upper`, `divisibleby`, `startingwith`, `endingwith`, `in`, `eq`/`equalto`, `ne`, `lt`/`lessthan`, `le`, `gt`/`greaterthan`, `ge`, `sameas`.
  - **Auto-escaping & undefined behavior**: `AutoEscape::Html` (matching MiniJinja's `&`, `<`, `>`, `"`, `'`, `/` escaping), `AutoEscape::Json`, `AutoEscape::None`, automatic extension detection (`.html`/`.htm`/`.xml`/`.xhtml`/`.svg` → `Html`, `.json` → `Json`), `Value::safe` / `|safe` / `|escape` double-escape prevention, `UndefinedBehavior::Lenient` & `UndefinedBehavior::Strict`.
- **Day-1 Red-Team Security Defenses**:
  - Cycle detection for `extends` and `include` chains (`ErrorKind::RecursionLimit`).
  - `max_depth` protection against recursive macros and deeply nested blocks/expressions (default: `64`).
  - `fuel` execution step budget preventing infinite loops and huge `range(100000000)` DoS (`ErrorKind::FuelExhausted`, lazy `Range` avoids upfront allocation).
  - `max_output_bytes` memory-bomb protection checked before output writes and string/list repetition (`{{ 'a' * 10000000 }}` → `ErrorKind::OutputLimitExceeded`).
  - 1-based line and column tracking on both compile-time and runtime errors.

## Quickstart

```pion
import "template"

fn example() -> Result[String, template::TemplateError] {
  let env = template::Environment::new()
  env.set_auto_escape(template::AutoEscape::Html)
  match env.add_template("base.html", "<h1>{% block title %}App{% endblock %}</h1>{% block body %}{% endblock %}") {
    Ok(()) => ()
    Err(e) => return Err(e)
  }
  match env.add_template(
    "page.html",
    "{% extends 'base.html' %}{% block title %}{{ super() }} - {{ title }}{% endblock %}{% block body %}<p>{{ msg }}</p>{% endblock %}",
  ) {
    Ok(()) => ()
    Err(e) => return Err(e)
  }
  let ctx = template::Value::from_map([
    ("title", template::Value::from_string("Hello <World>")),
    ("msg", template::Value::safe("<b>Trusted</b>")),
  ])
  env.render_template("page.html", ctx)
}
```

### Security Limits for Untrusted Templates

```pion
let env = template::Environment::new()
env.set_max_depth(32)
env.set_fuel(Some(100000L))
env.set_max_output_bytes(1048576) // 1 MiB
env.set_undefined_behavior(template::UndefinedBehavior::Strict)
```

## Verification

```sh
pionc fmt --check packages/template
pionc check --json packages/template
pionc test --json packages/template

# Native & Wasm32 smoke (debug + release)
pionc run packages/template/wasm_smoke
pionc build --release -o /private/tmp/template_smoke packages/template/wasm_smoke && /private/tmp/template_smoke
pionc build --target wasm32 -o /private/tmp/template_smoke_dbg.wasm packages/template/wasm_smoke
pionc run --target wasm32 packages/template/wasm_smoke
pionc build --release --target wasm32 -o /private/tmp/template_smoke_rel.wasm packages/template/wasm_smoke
pionc run --release --target wasm32 packages/template/wasm_smoke
```

## Head-to-Head Benchmark

Benchmarked via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte identity) on `Darwin arm64` against **Rust `minijinja 3.1.0`** (`--release`, `opt-level = 3`, `lto = "thin"`, `codegen-units = 1`, features `["builtins", "json", "preserve_order"]`).

Run locally with:

```sh
sh packages/template/bench/run_bench.sh
```

### Bench 1: HTML Page SSR (`extends` + `block` + `super()` + `for` 20 rows + HTML auto-escape + filters, 10,000 renders, 23.77 MB output)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_minijinja`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 179.179 | 174.366 | 187.387 | 132.66 | 17917.95 | 2.38 MiB | **0.81x** |
| `rust_minijinja` | 145.515 | 140.957 | 147.779 | 163.35 | 14551.52 | 3.06 MiB | 1.00x (baseline) |

_SHA-256 verified identical: `e4fc33828ccace7ee949020a4217baa4ddde3f1f54a4c1d0e4085d3695ee1b39`._

### Bench 2: AI Agent Prompt Rendering (conditionals + tool list + `tojson(indent=2)` + `join` + `default`, 20,000 renders, 9.14 MB output)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_minijinja`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 71.291 | 70.802 | 75.108 | 128.21 | 3564.55 | 2.30 MiB | **1.68x** |
| `rust_minijinja` | 119.490 | 112.435 | 122.150 | 76.49 | 5974.51 | 2.89 MiB | 1.00x (baseline) |

_SHA-256 verified identical: `ed6753c873c8a3aeace7d3ceb6df3ce580c9d238f3e45261441a2f6907135a0a`._

### Bench 3: Compile + Render End-to-End (parse & compile 3 templates with `extends` + `include` + `for` + HTML escape, 2,000 iterations, 938 KB output)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_minijinja`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 33.950 | 29.058 | 34.427 | 27.63 | 16975.19 | 2.23 MiB | **1.59x** |
| `rust_minijinja` | 54.036 | 48.269 | 57.340 | 17.36 | 27018.10 | 3.11 MiB | 1.00x (baseline) |

_SHA-256 verified identical: `1561f2114958a0d8e74a73a6d50ccf3a69514b983377865297dfef8698fa5b63`._

### Honest Performance Analysis

- **Where `template` (Pion) leads**:
  - **AI Agent Prompt rendering (`1.68x`)**: Pion's direct `StringBuilder` JSON serializer (`write_json_value`) and low-overhead `Value` representation avoid serde/dynamic-object overhead on repeated prompt rendering.
  - **Compile + Render End-to-End (`1.59x`)**: Single-pass lexer and direct recursive-descent AST compilation have lower compile-time overhead than MiniJinja's bytecode compiler + optimizer pass.
  - **Memory footprint**: Lower peak RSS across all three workloads (`2.23–2.38 MiB` vs `2.89–3.11 MiB`).
- **Where Rust `minijinja` leads**:
  - **HTML Page SSR (`0.81x`)**: On render-heavy loops with pre-compiled templates, MiniJinja's flat bytecode VM has better instruction-cache locality and less dispatch overhead than Pion's tree-walking AST evaluator.

## Known Differences vs Upstream MiniJinja

- `|tojson` with no arguments emits compact JSON (`{"a":1,"b":2}`); `|tojson(indent=2)` matches Rust `minijinja 3.1.0` byte-for-byte.
- `Value::from_map` preserves key insertion order unconditionally (equivalent to MiniJinja's `preserve_order` feature).
- Custom `add_filter` / `add_test` / `add_function` callbacks currently receive positional arguments (`Array[Value]`); built-in filters and macros support both positional and keyword arguments.
