# `template`

Pure-Pion Jinja2 / [MiniJinja](https://github.com/mitsuhiko/minijinja)-compatible template engine (`v0.1.0`) for AI agent prompt rendering, reports/notifications, and HTML/XML auto-escaping SSR.

- **Zero C dependencies / zero `World` dependency** — compiles and runs identically on Native (`debug` & `--release`) and `wasm32` (`debug` & `--release`), verified **283 / 283 byte-identical with 0 Wasm32 traps** across the differential audit corpus.
- **Pre-compiled AST & streaming `StringBuilder` output** — templates are parsed once into a compact AST (`Environment::add_template` / `Template`) and rendered directly into a `StringBuilder` with explicit `Result[String, TemplateError]` error handling.
- **Full Jinja2 / MiniJinja core feature set** (**45 / 45** compliance & security unit tests + **29 / 29** red-team audit tests passing, **251 / 283** byte-identical agreement against Rust `minijinja =3.1.0`):
  - **Syntax & whitespace**: `{{ ... }}`, `{% ... %}`, `{# ... #}`, whitespace trimming (`{{-`, `-}}`, `{%-`, `-%}`, `{#-`, `-#}`), `{% raw %}...{% endraw %}`, `keep_trailing_newline`, `trim_blocks`, `lstrip_blocks`, string escapes (including `\uXXXX` + UTF-16 surrogate pairs and `\xHH`), int/hex/octal/binary/128-bit integer/float/bool/none literals, Python-style `True`/`False`/`None` display and single-quoted container repr.
  - **Expressions**: checked 128-bit integer promotion (`+`, `-`, `*`, `//`, `%`, `**`, unary `-`, zero silent wrap, zero `INT64_MIN // -1` Wasm32 trap), float `//`/`%`/`**`, chained comparisons (`a < b < c` short-circuiting), short-circuit logic (`and`, `or`, `not`), membership (`in`, `not in`), tests with parenthesized or bare arguments (`9 is divisibleby 3`), ternary (`a if c else b`), safe-preserving string concatenation (`~`, `+`), UTF-8 codepoint indexing & slicing (`a[1:3]`, `a[::2]`, `a[::-1]`), attribute & numeric-index access (`users.0.name`), list/dict/tuple literals, standalone `eval_expr`.
  - **Control flow**: `if`/`elif`/`else`, `for` (with `loop.index`, `index0`, `revindex`, `revindex0`, `first`, `last`, `length`, `depth`, `depth0`, `previtem`, `nextitem`, `loop.cycle(...)`, `for ... if` filter, `for ... else`, strict tuple unpacking), `set` (inline, tuple unpacking `{% set a, b = ... %}`, block `{% set x %}...{% endset %}`, namespace mutation `{% set ns.total = ... %}`), `with`, `filter` block, `autoescape` block, `do`, built-in `range` (lazy O(1) memory), `dict(base, k=v)`, `namespace`.
  - **Template reuse**: multi-level & conditional `extends` + `block` (duplicate block rejected) + `super()` + child top-level `set` visible in blocks, `include` (single name or fallback list, `ignore missing`), `macro` (strict arity & keyword checks, defaults, kwargs, `{% call %}` / `caller()`), `import ... as ...` (exporting both macros and variables with cycle detection), `from ... import ... as ...`.
  - **Built-in filters (41+)**: `upper`, `lower`, `title`, `capitalize`, `trim`, `replace`, `default`/`d`, `length`/`count` (UTF-8 codepoints), `first`, `last`, `join(d, attribute=)`, `split(pat, maxsplit=)`, `sort(reverse, case_sensitive, attribute)` (**O(N log N)** stable merge sort, case-insensitive default, mixed-type total order), `reverse` (UTF-8 safe), `unique(case_sensitive, attribute)` (**O(N)** hash-bucketed), `map`, `select`, `reject`, `selectattr`, `rejectattr`, `slice`, `batch`, `abs` (128-bit safe), `round(precision, method='common'|'ceil'|'floor')` (exact half-to-even via Dekker residual, int-preserving, zero Wasm32 float->int trap), `int(default, base)`, `float(default)`, `string`, `bool`, `list`, `items`, `dictsort`, `min`, `max`, `tojson` (HTML-safe `< > & '` escaping + MiniJinja default spacing), `escape`/`e`, `safe`, `indent`, `wordcount`, `urlencode` (strings & maps), `attr`, `sum(attribute, start)` — plus custom `add_filter`, `add_test`, `add_function`, `add_global`.
  - **Built-in tests (27+)**: `defined`, `undefined`, `none`, `boolean`, `true`, `false`, `integer`, `float`, `number`, `string`, `safe`/`escaped`, `sequence`, `mapping`, `iterable`, `odd`, `even`, `lower`, `upper`, `divisibleby`, `startingwith`, `endingwith`, `in`, `eq`/`equalto`, `ne`, `lt`/`lessthan`, `le`, `gt`/`greaterthan`, `ge`, `sameas`, `filter`, `test`.
  - **Auto-escaping & undefined behavior**: `AutoEscape::Html` (escaping `&`, `<`, `>`, `"`, `'`, `/`), `AutoEscape::Json`, `AutoEscape::None`, automatic extension detection (`.html`/`.htm`/`.xml`/`.xhtml`/`.svg` -> `Html`, `.json` -> `Json`), `Value::safe` taint propagation through `~`, `+`, `upper`/`lower`/`title`/`capitalize`/`trim`/`reverse`/`indent`, `replace`, `join`, `{% filter %}`, `{% set %}...{% endset %}`, and macro returns, `UndefinedBehavior::Lenient` & `UndefinedBehavior::Strict`.
- **Hardened Red-Team Security Defenses (62 / 62 DoS matrix: 0 SIGSEGV, 0 SIGABRT, 0 OOM, 0 timeout, 0 Wasm32 trap)**:
  - HTML-safe `|tojson` escapes `<`, `>`, `&`, `'` to `\u003c`, `\u003e`, `\u0026`, `\u0027`, preventing `</script>` and single-quoted attribute XSS breakouts.
  - Cycle detection for `extends`, `include`, and `import` chains (`ErrorKind::RecursionLimit` / `ErrorKind::BadInclude`).
  - `max_depth` (default `64`) bounds nested blocks, parentheses, lists/dicts, runtime-constructed nested containers, AND expression chains (`+`, `~`, `and`/`or`, `not`, unary `-`, `**`, `|filter`, `.attr`), eliminating native stack overflows and Wasm32 call-stack traps.
  - `fuel` execution step budget (default `10,000,000`) charged on loops, macros, list concatenation/repetition, `sort`, `unique`, `batch`, `slice`, `join`, `map`, `select`, and `sum` (`ErrorKind::FuelExhausted`).
  - `max_output_bytes` (default `16 MiB`) enforced before allocation across output writes, `~`, `+`, `*`, `|replace`, `|indent`, `|join`, `|batch` fill, `|slice`, and `Seq + Seq` (`ErrorKind::OutputLimitExceeded`).
  - Zero hardware traps on Wasm32: `INT64_MIN // -1`, `INT64_MIN % -1`, and extreme `|round(1000000)` are handled cleanly in software.
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
pionc test --json -p template_redteam_audit packages/template/audit

# Full red-team audit (29 tests, 283-case diff, wasm32 parity, 62 DoS cases, 8 adversarial benches)
sh packages/template/audit/run_audit.sh all

# Native & Wasm32 smoke (debug + release)
pionc run packages/template/wasm_smoke
pionc build --release -o /private/tmp/template_smoke packages/template/wasm_smoke && /private/tmp/template_smoke
pionc build --target wasm32 -o /private/tmp/template_smoke_dbg.wasm packages/template/wasm_smoke
pionc run --target wasm32 packages/template/wasm_smoke
pionc build --release --target wasm32 -o /private/tmp/template_smoke_rel.wasm packages/template/wasm_smoke
pionc run --release --target wasm32 packages/template/wasm_smoke
```

## Head-to-Head Benchmark

Benchmarked via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte identity) on `Darwin arm64` against **Rust `minijinja =3.1.0`** (`--release`, `opt-level = 3`, `lto = "thin"`, `codegen-units = 1`, features `["builtins", "json", "preserve_order"]`, without `speedups` SIMD `v_htmlescape`).

### Standard Workloads (`sh packages/template/bench/run_bench.sh`)

#### Bench 1: HTML Page SSR (`extends` + `block` + `super()` + `for` 20 rows + HTML auto-escape + filters, 10,000 renders, 23.77 MB output)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_minijinja`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 156.054 | 151.756 | 163.427 | 152.32 | 15605.36 | 2.50 MiB | **0.77x** |
| `rust_minijinja` | 119.374 | 118.096 | 128.775 | 199.12 | 11937.37 | 3.08 MiB | 1.00x (baseline) |

_SHA-256 verified identical: `e4fc33828ccace7ee949020a4217baa4ddde3f1f54a4c1d0e4085d3695ee1b39`._

#### Bench 2: AI Agent Prompt Rendering (conditionals + tool list + HTML-safe `tojson(indent=2)` + `join` + `default`, 20,000 renders, 9.14 MB output)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_minijinja`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 69.348 | 67.615 | 75.506 | 131.80 | 3467.40 | 2.41 MiB | **1.39x** |
| `rust_minijinja` | 96.668 | 93.433 | 98.112 | 94.55 | 4833.41 | 2.88 MiB | 1.00x (baseline) |

_SHA-256 verified identical: `ed6753c873c8a3aeace7d3ceb6df3ce580c9d238f3e45261441a2f6907135a0a`._

#### Bench 3: Compile + Render End-to-End (parse & compile 3 templates with `extends` + `include` + `for` + HTML escape, 2,000 iterations, 938 KB output)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_minijinja`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 25.865 | 23.871 | 26.727 | 36.27 | 12932.44 | 2.30 MiB | **1.52x** |
| `rust_minijinja` | 39.368 | 37.992 | 40.312 | 23.83 | 19683.79 | 3.12 MiB | 1.00x (baseline) |

_SHA-256 verified identical: `1561f2114958a0d8e74a73a6d50ccf3a69514b983377865297dfef8698fa5b63`._

### Adversarial Workloads (`sh packages/template/audit/run_audit.sh bench`, SHA-256 verified)

| Workload | `pion` median | `rust_minijinja` median | Speedup (vs `rust_minijinja`) |
| --- | ---: | ---: | ---: |
| `bench_set_concat_20k` (`ns.s ~ 'x'`) | 18.87 ms | 54.55 ms | **2.89x** |
| `bench_unique_20k` (`range(20000)\|unique`) | 10.95 ms | 15.96 ms | **1.46x** (was 738.4 ms / 0.026x) |
| `bench_macro_50k` | 29.98 ms | 30.71 ms | **1.02x** |
| `bench_html_escape_50k` | 31.19 ms | 25.39 ms | **0.81x** |
| `bench_filters_50k` | 54.00 ms | 43.52 ms | **0.81x** |
| `bench_loop_200k` | 36.79 ms | 24.73 ms | **0.67x** |
| `bench_sort_20k` (reversed `\|sort`) | 13.50 ms | 9.10 ms | **0.67x** (was 1757.8 ms / 0.005x) |
| `bench_attr_lookup_100k` | 56.65 ms | 30.91 ms | **0.55x** |

### Honest Performance Analysis

- **Where `template` (Pion) leads**:
  - **Prompt rendering (`1.39x`) & Compile+Render (`1.52x`)**: Direct `StringBuilder` HTML-safe JSON serialization and single-pass recursive-descent AST compilation have lower compile and allocation overhead than MiniJinja's bytecode compiler + serde layer.
  - **`bench_set_concat_20k` (`2.89x`) & `bench_unique_20k` (`1.46x`)**: O(N) hash-bucketed `|unique` and lightweight string concatenation beat Rust `minijinja`'s `Value` hashing/cloning overhead.
  - **Memory footprint**: Consistently lower peak RSS across standard workloads (`2.30–2.50 MiB` vs `2.88–3.12 MiB`).
- **Where Rust `minijinja` leads**:
  - **Render-heavy tight loops & attribute lookups (`0.55x–0.81x`)**: MiniJinja's flat bytecode VM and hash-indexed object lookups have better cache locality and dispatch efficiency than Pion's tree-walking AST evaluator and linear map/filter scan. Note also that the Rust baseline is built without MiniJinja's optional `speedups` SIMD `v_htmlescape` feature.

## Known P2 Differences vs Rust `minijinja =3.1.0` (32 / 283 differential cases)

All P0 security/crash/DoS defects and all P1 semantic defects have been resolved. The remaining 32 differences out of 283 differential cases are documented P2 feature/formatting gaps:

- **Not yet implemented P2 syntax/features**: `{% for ... recursive %}` / `loop(...)`, `loop.changed(...)`, `{% break %}` / `{% continue %}` (`loop_controls`), `self.<block>()`, `{%+` / `+%}` whitespace preservation modifiers, `|format`, `|pprint`, `debug` global, macro `.name` / `.arguments` attributes.
- **Formatting / repr differences**: tuples render as lists (`[1, 2]` vs `(1, 2)`, affecting `|items` and `|dictsort` repr); large/small floats use scientific notation (`1e+20`, `1.5e-07`) vs MiniJinja's fixed decimal (`100000000000000000000.0`, `0.00000015`); `-0.0` prints as `0.0` in some paths.
- **Minor operator/edge differences**: `-2 ** 2` and `2 ** 3 ** 2` follow Python/Jinja2 precedence (`-4` / `512`) rather than MiniJinja (`4` / `64`); `1 + 2 ~ 3` follows Jinja2 precedence (`33`); `|title` word-boundary rules and `{% raw %}` inner whitespace trim differ slightly; bool arithmetic (`true + 1`) and `in` on `none` differ; custom `add_filter` / `add_test` / `add_function` callbacks receive positional `Array[Value]` arguments.
