# Red-team audit: `packages/cli` (`feat/pkg-cli` @ `d65ed21`)

**Compared against:** Rust `clap =4.5.32` (main reference), Go `spf13/pflag v1.0.6`, and the real `bash 5.3.20` / `zsh 5.9` completion runtimes. `fish` is not installed on the audit host, so the fish findings are static.
**Toolchain:** `pionc 0.1.0` (`AFK-surf/pion@81b8fb0`), cargo 1.100, go 1.27.3, node 24.22.2, macOS arm64.
**Reproduce:** `sh packages/cli/audit/run_audit.sh [tests diff typed shell wasm dos bench]`. Everything is written to `/private/tmp/pion-cli-audit`. The script exits 1 while the defects below exist.

## Verdict

The parser core is fast and memory-safe. On fair benchmarks it is still 4.8–7.9× faster than clap, it never crashed or trapped, and native and wasm32 gave byte-identical results in all four build modes. **The shell completion generator is not safe to ship.**

- **9 P0 findings.** Each one either runs attacker-controlled text as shell code or produces a script the shell cannot parse.
- **9 P1 findings.** Wrong parse results, behaviour that silently ignores input, and broken UTF-8 handling.
- **9 P2 findings.**
- **6 semantic divergences from clap** (`div_`). Some of these are better than clap. Each one needs a decision.
- **9 control probes passed** (`ctl_`). In those areas Pion matches clap or does better.

`redteam_test.pion`: 57 tests in the run, 31 FAILED (25 `p*`, 6 `div_`) and 26 passed (9 `ctl_` plus the package's 17 existing tests). Differential run: 54 of 149 argv/env cases differ from clap. Typed getters: 15 of 54 values differ from Rust `str::parse`.

## P0: shell completion runs injected code or produces invalid scripts

Root cause: `completion.pion` has five escapers, and each is applied in a context it does not cover:

- `escape_posix_sq` escapes only `'`.
- `escape_bash_token` keeps `; > < | & ( )`.
- Short flags are written with `write_char(ch)` and no escaping at all.
- All five escapers rebuild strings byte by byte, so UTF-8 is also broken (P1-3).

Evidence: `run_audit.sh shell` writes each script to a scratch directory and runs `bash -n` / `zsh -n` on it. It then either sources the script and calls the completion function the way readline does, or, for zsh, presses a real TAB in an interactive `zsh -i` (zle + compsys) driven through `zsh/zpty` (`tools/zsh_complete.zsh`). A `PWNED_*` file appearing in the scratch directory proves the code ran.

| # | Input under attacker control | Shell | Trigger | Real-shell result | Test |
|---|---|---|---|---|---|
| P0-1 | `possible_values(["$(touch X)", "`touch Y`"])` | bash | TAB on the flag's value. `compgen -W` expands its word list. | **EXECUTED** (both files created) | `p0_bash_possible_values_command_substitution` |
| P0-2 | same | zsh | TAB on the value. `_arguments` runs `eval ws\=\( "${action[2,-2]}" \)` (`/usr/share/zsh/5.9/functions/_arguments:435`). | **EXECUTED** under real zle | `p0_zsh_possible_values_eval` |
| P0-3 | same | fish | TAB. `complete -a` arguments are expanded at completion time (`$(...)`, fish ≥ 3.4). | static: emitted verbatim | `p0_fish_possible_values_command_substitution` |
| P0-4 | command name `app;>PWNED` | bash, fish | **Sourcing** the script: `complete -F _app__PWNED app;>PWNED`, `complete -c app;>PWNED` | **EXECUTED on source** (bash) | `p0_bash_command_name_injection_on_source`, `p0_fish_command_name_and_long_flag_injection_on_source` |
| P0-5 | long flag `x)>PWNED;;y` (+ possible values) | bash | TAB after `--x`. The name closes the `case "$prev"` pattern. | **EXECUTED** | `p0_bash_long_flag_case_pattern_injection` |
| P0-6 | long flag `x;>PWNED` | fish | sourcing: `complete -c app -l x;>PWNED` | static | (same fish test) |
| P0-7 | subcommand name `a)>PWNED;;b` | zsh | TAB after `app a `. The name closes the `case "$line[1]"` pattern. | **EXECUTED** under real zle | `p0_zsh_subcommand_case_pattern_injection` |
| P0-8 | `.short('\'')` | zsh, fish | `'-'[...]'` / `-s '` | `zsh -n`: `unmatched '` | `p0_short_flag_quote_breaks_zsh_and_fish_syntax` |
| P0-9 | `.short(')')` + possible values | bash | `        -))` case arm | `bash -n`: `syntax error near unexpected token ')'` | `p0_short_flag_paren_breaks_bash_syntax` |

Threat model: completion scripts are generated from command definitions. Those definitions are often built from plugin manifests, config files, or the `possible_values` of dynamic enums. The README promises "injection-safe escaping". `clap_complete` escapes `$`, `` ` ``, `(`, `)`, spaces, `:` and `[]` in zsh value lists, and builds identifiers from validated names.

Control: metacharacters that appear only in help, about or value_name text **are** handled correctly. `bash -n` and `zsh -n` pass, and sourcing plus TAB creates no file (`ctl_description_metacharacters_escaped`).

## P1: correctness

| # | Finding | Repro | clap 4.5.32 | Pion | Test |
|---|---|---|---|---|---|
| P1-1 | **Non-ASCII short flags can never match.** The cluster loop reads UTF-8 *bytes* (`code_unit_at`) and looks them up in a table keyed by *code point*. `.short('é')` validates and shows in help, but is unreachable. | `-é`, `-vé` | `uni=true` | `unexpected argument '-Ã'` | `p1_non_ascii_short_flag_unreachable` |
| P1-2 | The unknown-short error is built from a single byte, so it shows mojibake. | `-ü` | `'-ü'` | `'-Ã'` | `p1_unknown_non_ascii_short_error_is_mojibake` |
| P1-3 | **All UTF-8 in completion scripts is double-encoded.** Every escaper does `c.unsafe_to_char()` per byte. | help `héllo 😀 世界` | n/a | `hÃÂ©llo Ã°ÂÂÂ Ã¤Â¸ÂÃ§ÂÂ` (zsh, fish) | `p1_completion_double_encodes_utf8` |
| P1-4 | The help placeholder `to_ascii_upper` has the same per-byte re-encoding. | id `fichier_é` | `<FICHIER_É>` | contains `Ã` | `p1_help_placeholder_double_encodes_utf8` |
| P1-5 | **A default value satisfies `requires`** (`seen_source != 0` also covers `DefaultValue`). | `a.requires("b")`, `b.default_value`; `--a` | `MissingRequiredArgument` | Ok | `p1_requires_satisfied_by_default_value` |
| P1-6 | **`allow_hyphen_values` is a no-op.** The field is never read in `parse.pion`. Every option consumes the next token, even a defined flag, `--help` or `--`. | `--num --flag`, `-o --help`, `--output --` | `a value is required` | value `--flag` / `--help` / `--` | `p1_allow_hyphen_values_is_a_noop_options_swallow_flags` |
| P1-7 | An inline `=VALUE` on Count, SetFalse or negative flags is silently dropped. | `--verbose=garbage`, `--no-color=x` | `unexpected value` | Ok (`verbose=1`) | `p1_inline_value_on_count_and_negative_flags_silently_ignored` |
| P1-8 | **No `help` subcommand**, so `app help run` *runs* `run` and stores `help` in the positional. | `help run` | DisplayHelp for `app run` | `Ok(subcommand=run)` | `p1_help_subcommand_executes_target` |
| P1-9 | **`get_double` is not correctly rounded.** It sums digits in doubles and scales with repeated `*10` and `/10`. | see `[typed]` | exact | `f64::MAX` → `…fff9`; `2^63-1` → `0x43e0000000000001`; `MIN_POSITIVE` → `…0003`; `2.5e-8` off by 2 ULP | `p1_get_double_not_correctly_rounded` |

## P2

| # | Finding | Test / evidence |
|---|---|---|
| P2-1 | Subcommand help shows `Usage: run` instead of `Usage: app run` (clap prints `app deep a b`), and it does not list inherited global options. | `p2_subcommand_help_loses_parent_path_and_globals`; diff #130–132 |
| P2-2 | `--help=foo` gives "unexpected argument '--help' … did you mean '--help'?", suggesting the flag it just rejected. | `p2_help_with_inline_value_suggests_itself` |
| P2-3 | The suggestion threshold is 2 for tokens of 5 bytes or less, so `deep zz` suggests `a`, and any short typo "matches" any short subcommand. clap gives no tip. | `p2_suggestion_noise_for_short_names`; diff #146 |
| P2-4 | Completions omit global args inside subcommands (bash, zsh and fish). `app run <TAB>` offers `--local -h --help` and no `--global-opt`. | `p2_completion_omits_global_args_in_subcommands`; shell stage |
| P2-5 | Names that sanitize to the same identifier (`a-b` and `a_b`) collide. zsh defines `_app__a_b` twice, so in `app a-b --on<TAB>` it completes `--only-a_b`. bash keeps two `app__a_b)` arms, so `app a_b <TAB>` gets `--only-ab`. | `p2_completion_identifier_collision`; shell stage |
| P2-6 | A possible value containing a space or parentheses is split or lost: zsh `(two words (x))` gives `two` and `words`, and drops `(x)`. bash also splits `two words`. | `p2_completion_possible_value_with_space_is_split`; shell stage |
| P2-7 | The bash walker appends **every** non-dash word to the subcommand path, so `app --out file <TAB>` returns nothing. `clap_complete` only advances on known subcommand names. | shell stage (`COMPREPLY:` empty) |
| P2-8 | `conflicts_with(self)` is accepted at definition time, and then every use fails ("'a' cannot be used with 'a'"). clap debug-asserts on this. | `p2_self_conflict_not_rejected_at_definition` |
| P2-9 | **The builders are O(N²).** `Command::arg`, `subcommand`, `alias` and `Arg::conflicts_with`/`requires` copy the whole array on every call. 32k chained `.arg()` calls take **3.29 s** vs clap's 12.6 ms, and 64k take **15.1 s** vs 0.02 s. `.args(list)` is linear, at 18 ms vs 19 ms. | `[dos]` and `[bench]` ADV `build_args`/`build_subs`: 0.02× |

## Semantic divergences from clap (`div_*`; each needs a decision, not necessarily a bug)

| Behaviour | clap 4.5.32 | pflag 1.0.6 | Pion | Comment |
|---|---|---|---|---|
| `-3`, `-3.14`, `-1e5`, `-.5` as positionals | error (needs `allow_negative_numbers`) | error | accepted | More permissive than both references. Document it, or make it opt-in. |
| Repeated single-value option or SetTrue (`-o a -o b`, `-ff`) | error "cannot be used multiple times" | last wins | last wins | Matches pflag. The README claims clap alignment. |
| `--flag=true/1/yes`; env bool `1/0/yes/no/on/off/TRUE` | error (SetTrue takes no value; env accepts only `true`/`false`) | `=true/1` ok, `yes` error | all accepted | Lenient. `--secret=no` sets it to false. |
| Global Count across levels (`-v run -v`) | 1 at every level | n/a | 2 | **Pion is arguably better** (clap overwrites). |
| Subcommand depth | 1,000 levels parse | n/a | > 64 rejected as `InvalidDefinition` | Safe by design; documented constant. |
| `get_double("inf"/"NaN"/"infinity")` | accepted | accepted | rejected | |

Divergences where **Pion is better than clap** (kept as `ctl_` tests):
- `--cfg c run --x` with `x.requires("cfg")` (a global): clap 4.5.32 wrongly reports MissingRequired, and Pion accepts it.
- Hidden args are never suggested. clap suggests the hidden `--secret` for `--secre`.

## Controls that passed (`ctl_*` plus the differential's matching rows)

Pion matches clap in all of these cases:
- `--` handling, and `-o=` / `-o ""` / `-o=x` / `-oé` / `-o😀`.
- Clustering (`-vf5`, `-vh` and `-hv` give help, `-foo` = `-f -o o`), and `--=` / `--=x` errors.
- `value_delimiter` edge cases (`""`, `a,`, `a,,b`, `,`), and env `APP_TAGS` splitting.
- Empty env `APP_NAME=""` (the env value wins over the default in **both**), and env conflicts (`APP_D=true`/`false` with `--c` give a conflict in both).
- Possible values (case-sensitive), and typo suggestions for `--outptu`, `--ouput`, `--Output`, `--éutput` and `--outpüt`.
- Version scoping, Int and Int64 bounds (`±2^31`, `±2^63`, `+1`, `01`, leading space, `0x10`, `1_000`), and rejection of cyclic and self `requires`.
- No hang on a 1 MB unknown flag, and an error rather than a crash on a 1,000-level tree.

## Wasm32: 4-mode check (`[wasm]`)

The same probe binary was run in four modes: native release, native debug, wasm32 release and wasm32 debug, the wasm builds executed with `node ~/.pion/share/pion/pion_wasm_rt.mjs`. It covered 20 workloads: the full 149-case differential, typed getters, 12 completion scripts, subcommand help, and depth 64 / 1000, 100k-token, 1 MB-flag and completion DoS inputs. All 20 were **4/4 byte-identical with 0 traps**.

## DoS and complexity (`[dos]`, single run, wall ms)

| Workload | Pion | clap |
|---|---|---|
| 32,000 chained `.arg()` (P2-9) | **3292** | 12.6 |
| 16,000 chained `.subcommand()` | **952** | 7.1 |
| 32,000 args via `.args(list)` + one parse | 18.3 | 19.1 |
| 1 MB unknown long flag | 6.9 | 170.6 |
| 20 candidates with 4 KB names + 4 KB typo (DL is O(n²) per candidate, Jaro in clap) | **542** | 165 |
| 3,000 options × 1,000 typos | 732 | 1856 |
| 1,000,000 argv tokens | 32 | 381 (clap's Count saturates at 255) |
| completion scripts for 16,000 options (3 shells) | 32 | n/a |

## Benchmark fairness (`[bench]`, `scripts/bench_compare.py --warmup 1 --rounds 5`, SHA-256 gated)

Problems with the upstream `bench/`:
1. **W1 clap pays a `Command::clone()` on every parse**, while Pion reuses a precompiled `CompiledCommand`. clap has `try_get_matches_from_mut(&mut cmd)`. Removing the clone cuts clap from 3060 ms to 1627 ms, so the published gap is inflated **1.9×**.
2. **W3 clap clones and renders the full styled error string**, while Pion reads `UnknownArgument(_, Some(sug))` directly. clap exposes `ContextKind::SuggestedArg` for the same structured access.
3. Neither workload measures the cold path, which is what a real CLI process pays: build the command and parse once.

Fair rerun (`audit/bench/{pion,rust}`; the clap side `include!`s `bench/rust/src/main.rs` verbatim):

| Workload | Pion | clap (fair) | clap (upstream bench) | Pion vs fair clap |
|---|---|---|---|---|
| W1 50k parses, precompiled | 205 ms | 1627 ms (`_mut`, no clone) | 3060 ms | **7.9×** (upstream claimed ~15×) |
| W1 cold: build + parse per op | 949 ms | 4511 ms | n/a | **4.8×** |
| W3 typo + help, both rendering the error string | 79 ms | 448 ms (`SuggestedArg`, no clone) | 819 ms | **5.6×** |
| ADV 16k chained `.arg()` | 628 ms | 12.6 ms | n/a | **0.02×** |
| ADV 16k chained `.subcommand()` | 691 ms | 12.7 ms | n/a | **0.02×** |
| ADV 16k `.args(list)` + parse | 17.4 ms | 16.9 ms | n/a | 0.97× |
| ADV 3k options × 1k typos | 647 ms | 1527 ms | n/a | 2.4× |
| ADV 1 MB unknown flag | 11.5 ms | 117 ms | n/a | 10.2× |
| ADV 4 KB-name typo suggestion | 472 ms | 152 ms | n/a | **0.32×** |

Conclusion: Pion's normal-path lead over clap is real, but about half of the published W1 and W3 margin came from the clap side's clones. Pion loses badly on chained-builder construction (quadratic) and on long-name suggestions.

## Files

- `redteam_test.pion`: 40 audit tests (`p0_`/`p1_`/`p2_`/`div_` currently FAIL; `ctl_` PASS).
- `probe/`: a Pion driver with `diff`, `typed`, `compl`, `help` and `dos` modes. Its output format is shared with the oracles.
- `oracle/rust`: clap 4.5.32 (`env` and `string` features). `oracle/go`: pflag 1.0.6 (basic spec and typed only).
- `tools/gen_cases.py`: the 149 argv/env cases and 55 typed values. `tools/compare.py` runs the differential. `tools/zsh_complete.zsh` presses a real zle TAB through zsh/zpty.
- `bench/pion`, `bench/rust`: the fairness modes `w1_cold`, `w3_render`, `w1_mut` and `w3_ctx`.
- `run_audit.sh`: runs all stages.
