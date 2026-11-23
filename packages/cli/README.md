# `cli` — Pure Pion Declarative CLI Parser, Help Formatter & Shell Completion Generator

Pure Pion, zero-`World`, zero-dependency, `Send`-safe command-line argument and subcommand parser modeled after Rust [`clap`](https://github.com/clap-rs/clap) (builder API) and Go [`spf13/pflag`](https://github.com/spf13/pflag).

Accepts `args : Array[String]` and optional `env : Map[String, String]` as pure data inputs so CLI behavior is 100% deterministic and testable on both Native and `wasm32`.

## Features

- **Full POSIX / GNU Flag Syntax**:
  - Long flags: `--output file`, `--output=file`, `--output=` (empty value)
  - Short flags: `-o file`, `-ofile` (attached), `-o=file` (GNU/`pflag`-style equals)
  - Short boolean clustering (`-abc`), counting (`-vvv`, `ArgAction::Count`), and cluster-ending value flags (`-abofoo`, `-abo foo`, `-abo=foo`)
  - Negative boolean flags (`Arg::new("color").long("color").negative("no-color").action(ArgAction::SetTrue)`) and `ArgAction::SetFalse`
  - Repeatable arguments (`ArgAction::Append`, e.g. `-I a -I b`) with optional `value_delimiter(',')`
  - Single dash `-` treated as positional stdin argument or option value; double dash `--` terminates option parsing completely (everything after `--`, including `--help` and `-x`, is treated as positional)
  - Negative numbers (`-5`, `-10`, `-3.14`) accepted as option values (`-n -5`, `--offset=-10`) and positional arguments without being misparsed as unknown short flags
- **Positionals & Subcommand Trees**:
  - Required, optional, and variadic (`multiple(true)`) positional arguments
  - Arbitrarily nested subcommands (`git remote add origin url`, bounded by `MAX_SUBCOMMAND_DEPTH = 64`)
  - Global flags (`global(true)`) accepted at parent or any descendant subcommand level and propagated bidirectionally across `ArgMatches`
  - Subcommand aliases (`alias` / `aliases`, resolved to canonical name), `default_subcommand`, and `subcommand_required`
- **Constraints, Environment Fallback & Typed Getters**:
  - Strict value precedence: **`CLI > env > default`** (tracked via `value_source(id) -> Option[ValueSource]`)
  - `possible_values` allowlist validation, symmetric `conflicts_with` (triggered only on explicit CLI/env values, never spurious defaults), `requires` dependencies, and `required` enforcement
  - Typed accessors with exact overflow/syntax checks: `get_string`, `get_many`, `get_flag`, `get_count`, `get_int`, `get_int64`, `get_double`, `get_bool`
- **Automatic Help, Version & Typo Suggestions**:
  - Built-in `-h`/`--help` and `-V`/`--version` return structured `Err(CliError::DisplayHelp(String))` / `Err(CliError::DisplayVersion(String))` (never calls `exit()`)
  - Column-aligned compact (`-h`) and detailed (`--help`, showing `long_about`, `long_help`, `[env: ...]`, `[default: ...]`, `[possible values: ...]`) help text; `hide(true)` omits flags/subcommands from help, suggestions, and completions
  - Unknown flags and subcommands compute **Damerau-Levenshtein (OSA)** edit distance (with O(1) length-difference pruning against overlong inputs) and suggest `"did you mean '--output'?"`
- **Shell Completion Scripts**:
  - `generate_completions(cmd, Shell::Bash | Shell::Zsh | Shell::Fish)` emits completion scripts with subcommands, long/short/negative flags, `possible_values`, and injection-safe escaping of quotes, newlines, colons, brackets, and shell metacharacters
- **Precompiled Hot Path & Safety**:
  - `Command::compile()` pre-validates definitions (duplicate flags/IDs/aliases, `MAX_SUBCOMMAND_DEPTH`, 3-color DFS cycle detection for `requires`) and builds O(1) lookup tables (128-entry ASCII `FixedArray[Int]` for short flags + flat parse-state arrays) for linear O(N) parsing across 50k–100k+ argument batches
- **Dual Target**: Native + `wasm32` (`packages/cli/wasm_smoke`).

## Quick Start

```pion
import "cli"

let app = cli::Command::new("demo")
  .version("1.0.0")
  .about("Example CLI")
  .arg(cli::Arg::new("verbose").short('v').long("verbose").action(cli::ArgAction::Count).global(true))
  .arg(cli::Arg::new("output").short('o').long("output").env("DEMO_OUT").default_value("out.txt"))
  .subcommand(
    cli::Command::new("run")
      .about("Run workload")
      .arg(cli::Arg::new("target").required(true)),
  )

match app.parse(["-vv", "run", "job-1"]) {
  Ok(m) => {
    let v = m.get_count("verbose") // 2
    let sub = m.subcommand_matches("run")
    ...
  }
  Err(cli::CliError::DisplayHelp(txt)) => ...
  Err(cli::CliError::DisplayVersion(ver)) => ...
  Err(err) => ... // cli::cli_error_to_string(err)
}
```

## Verification

```sh
pionc fmt --check packages/cli
pionc check --json packages/cli
pionc test --json packages/cli
pionc build -o /private/tmp/cli-smoke/smoke_debug packages/cli/wasm_smoke
pionc build --release -o /private/tmp/cli-smoke/smoke_release packages/cli/wasm_smoke
pionc build --target wasm32 -o /private/tmp/cli-smoke/smoke_debug.wasm packages/cli/wasm_smoke
pionc build --target wasm32 --release -o /private/tmp/cli-smoke/smoke_release.wasm packages/cli/wasm_smoke
node "$HOME/.pion/share/pion/pion_wasm_rt.mjs" /private/tmp/cli-smoke/smoke_debug.wasm
node "$HOME/.pion/share/pion/pion_wasm_rt.mjs" /private/tmp/cli-smoke/smoke_release.wasm
```

## Head-to-Head Benchmarks (`Darwin arm64`, `--warmup 1 --rounds 5`)

Measured via `sh packages/cli/bench/run_bench.sh` using `scripts/bench_compare.py` (strictly interleaved rounds, mandatory byte-identical stdout SHA-256 verification across all implementations):

- **Pion**: `packages/cli` (`pionc build --release`, precompiled `CompiledCommand`)
- **Rust**: `clap = "=4.5.32"` (`features = ["suggestions", "usage", "help", "error-context"]`, `cargo build --release`)
- **Go**: `github.com/spf13/pflag v1.0.6` (`go build`)

### W1: Complex CLI (30 Options + 5-Level Subcommand) × 50,000 Parses

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_clap`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 198.846 | 176.033 | 308.399 | 3976.93 | 1.94 MiB | 14.48x |
| `rust_clap` | 2880.160 | 1938.051 | 4999.441 | 57603.19 | 3.03 MiB | 1.00x (baseline) |
| `go_pflag` | 302.830 | 253.811 | 516.880 | 6056.60 | 16.50 MiB | 9.51x |

_SHA-256 verified identical across all implementations and rounds: `77494c5de5dede8eafd6b0d39b6df2500dea64184b2685fb02b72be7c4ddeb36`._

### W2: 100k-Arg Batch (Short Clustering + Repeated Append + `--` Terminator)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_clap`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 11.569 | 10.848 | 11.789 | 115.69 | 4.78 MiB | 3.89x |
| `rust_clap` | 45.055 | 42.907 | 48.950 | 450.55 | 45.58 MiB | 1.00x (baseline) |
| `go_pflag` | 13.582 | 12.486 | 14.590 | 135.82 | 10.28 MiB | 3.32x |

_SHA-256 verified identical across all implementations and rounds: `b83a9179ea608dbf1a8cfaab9274634be69bc0249e0da4a65b327edb524699c9`._

### W3: Typo Suggestion + Help Rendering (20,000 ops, Pion vs Rust `clap`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_clap`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 69.625 | 68.383 | 72.855 | 3481.27 | 2.02 MiB | 8.91x |
| `rust_clap` | 620.544 | 608.200 | 664.191 | 31027.22 | 3.17 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `27bb597df1373cec45fce02623cc473dd3417a75b082e219db750b1b25dd96e4`._

### Honest Benchmark Notes & Scope Boundaries

- **Why Pion is faster on W1–W3**: `CompiledCommand` precompiles the command tree once into O(1) ASCII short-flag `FixedArray[Int]` lookup tables and `Map` indices, and parses into flat per-argument state arrays without cloning the command graph on every invocation. By contrast, Rust `clap` requires cloning `Command` per `try_get_matches_from` call and constructs rich styled error/context structures (`StyledStr`, ANSI styling), while Go `spf13/pflag` allocates a fresh `FlagSet` per parse and manages Go reflection/pointer bindings.
- **Methodology parity notes**:
  - **W1 (`go_pflag`)**: `spf13/pflag` is a flag parser without a built-in subcommand router, so the Go harness uses a thin 5-level subcommand dispatch paired with two `pflag.FlagSet` instances (root + leaf).
  - **W2 (`rust_clap`)**: `clap::ArgAction::Count` stores a saturating `u8` (capped at 255), so to match the exact `30,000` `-v` count across 10,000 `-vvv` tokens, the Rust harness uses `ArgAction::Append` with `num_args(0).default_missing_value("1")` and `args_override_self(true)`.
  - **W3 (2-way)**: `spf13/pflag` does not provide built-in typo suggestions, so W3 compares Pion directly against Rust `clap` (`suggestions` + `help` features enabled).
- **Scope**: `packages/cli` intentionally has zero `World` / OS / TTY dependencies (no ANSI terminal width probing or automatic `std::process::exit`); callers pass `world_args(world)` / env maps explicitly and decide how to print or exit on `DisplayHelp` / `DisplayVersion`.
