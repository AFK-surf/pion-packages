#!/bin/sh
# Red-team audit runner for packages/cli (feat/pkg-cli d65ed21).
#   Pion `cli` (native debug/release + wasm32 debug/release)
#   vs Rust `clap =4.5.32` (oracle/rust)  vs Go `spf13/pflag v1.0.6` (oracle/go)
#   + real `bash` (>= 4) / `zsh` (5.9) completion runtimes (bash -n, zsh -n, source + TAB via zsh/zpty).
#
#   sh packages/cli/audit/run_audit.sh                 # all stages
#   sh packages/cli/audit/run_audit.sh shell diff      # selected stages
# Stages: tests diff typed shell wasm dos bench
# Needs: pionc (~/.pion/bin), cargo (clap 4.5.32 in ~/.cargo or crates.io), go, node, python3, bash, zsh.
# Everything is written to $AUDIT_OUT (default /private/tmp/pion-cli-audit); the worktree stays clean.
# Exit status: 0 only if no DEFECT / divergence / UNEXPECTED was found (non-zero while the audited defects exist).
set -u
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
O="${AUDIT_OUT:-/private/tmp/pion-cli-audit}"
B="$O/bin"
RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
STAGES="${*:-tests diff typed shell wasm dos bench}"
want() { case " $STAGES " in *" $1 "*) return 0 ;; esac; return 1; }
hdr() { printf '\n==> %s\n' "$*"; }
STATUS=0
mkdir -p "$B" "$O/c" "$O/shell"
BASH5=$(command -v bash)
case "$("$BASH5" -c 'echo ${BASH_VERSINFO[0]}')" in [4-9]) ;; *) BASH5=/opt/homebrew/bin/bash ;; esac

hdr "toolchain"
pionc --version; cargo --version; go version; node --version; "$BASH5" --version | head -1; zsh --version

hdr "build: probe (native release/debug, wasm32 release/debug), clap oracle, pflag oracle"
for p in "$AUDIT_DIR" "$AUDIT_DIR/probe" "$AUDIT_DIR/bench/pion"; do
  pionc fmt --check "$p" >/dev/null || { echo "fmt --check failed: $p"; STATUS=1; }
  pionc check --json "$p" >/dev/null || { echo "check failed: $p"; STATUS=1; }
done
pionc build --release -o "$B/probe" "$AUDIT_DIR/probe" || exit 2
pionc build -o "$B/probe_dbg" "$AUDIT_DIR/probe" || exit 2
pionc build --release --target wasm32 -o "$B/probe.wasm" "$AUDIT_DIR/probe" || exit 2
pionc build --target wasm32 -o "$B/probe_dbg.wasm" "$AUDIT_DIR/probe" || exit 2
CARGO_TARGET_DIR="$O/rust-target" cargo build -q --release --manifest-path "$AUDIT_DIR/oracle/rust/Cargo.toml" || exit 2
CLAP="$O/rust-target/release/cli_audit_oracle"
(cd "$AUDIT_DIR/oracle/go" && GOFLAGS=-mod=mod go build -o "$B/go_oracle" .) || exit 2
python3 "$AUDIT_DIR/tools/gen_cases.py" "$O/c"

if want tests; then
  hdr "[tests] redteam_test.pion: p0_/p1_/p2_/div_ FAIL while the defect/divergence exists; ctl_ must PASS"
  pionc test "$AUDIT_DIR" >"$O/test.txt" 2>&1
  grep -E '^test cli_audit::' "$O/test.txt" | sed 's/^test cli_audit:://'
  grep -E '^test result' "$O/test.txt"
  if grep -E '^test cli_audit::ctl_.*FAILED' "$O/test.txt"; then echo "UNEXPECTED: control test failed"; fi
  grep -qE '^test cli_audit::.* FAILED' "$O/test.txt" && STATUS=1
fi

if want diff; then
  hdr "[diff] $(wc -l <"$O/c/cases.tsv" | tr -d ' ') argv/env cases: Pion vs clap 4.5.32 (pflag 1.0.6 shown for the 'basic' spec)"
  "$B/probe" diff "$O/c/cases.tsv" >"$O/pion.out"
  "$CLAP" diff "$O/c/cases.tsv" >"$O/clap.out"
  "$B/go_oracle" diff "$O/c/cases.tsv" >"$O/pflag.out"
  python3 "$AUDIT_DIR/tools/compare.py" "$O/c/cases.json" "$O/pion.out" "$O/clap.out" "$O/pflag.out" | tee "$O/diff.txt"
  grep -q 'RESULT: PASS' "$O/diff.txt" || STATUS=1
fi

if want typed; then
  hdr "[typed] get_int / get_int64 / get_double vs Rust str::parse (pflag ParseInt base 0 / ParseFloat for context)"
  "$B/probe" typed "$O/c/typed.txt" >"$O/t_pion.out"
  "$CLAP" typed "$O/c/typed.txt" >"$O/t_rust.out"
  "$B/go_oracle" typed "$O/c/typed.txt" >"$O/t_go.out"
  n=$(paste -d'|' "$O/t_pion.out" "$O/t_rust.out" | awk -F'|' '$1!=$2' | wc -l | tr -d ' ')
  paste -d'|' "$O/t_pion.out" "$O/t_rust.out" | awk -F'|' '$1!=$2 {print "  pion: "$1"\n  rust: "$2}'
  echo "typed: $n/$(wc -l <"$O/t_pion.out" | tr -d ' ') values differ from Rust"
  [ "$n" = 0 ] || STATUS=1
fi

if want shell; then
  hdr "[shell] hostile definitions -> bash -n / zsh -n, then source + complete in a scratch dir; any PWNED_* file = code execution"
  S="$O/shell"
  rm -rf "$S"; mkdir -p "$S"
  for spec in pv_cmdsub cmdname longcase fishlong short_quote short_paren subcase pv_space desc_safe utf8 global collide; do
    for sh in bash zsh fish; do "$B/probe" compl "$sh" "$spec" >"$S/$spec.$sh"; done
    for sh in bash zsh; do
      if [ "$sh" = bash ]; then "$BASH5" -n "$S/$spec.bash" 2>"$S/$spec.bash.n"; else zsh -n "$S/$spec.zsh" 2>"$S/$spec.zsh.n"; fi
      if [ -s "$S/$spec.$sh.n" ]; then echo "  SYNTAX-ERROR  $sh  $spec: $(head -1 "$S/$spec.$sh.n")"; STATUS=1; fi
    done
  done
  pw() { # $1=label $2=dir
    f=$(cd "$2" && ls PWNED_* 2>/dev/null | tr '\n' ' ')
    if [ -n "$f" ]; then echo "  EXECUTED      $1 -> created: $f"; STATUS=1; else echo "  ok            $1"; fi
  }
  # bash: source (load-time) and call the completion function like readline does on TAB
  bash_tab() { # $1=spec $2..=COMP_WORDS (last one is the word being completed)
    spec=$1; shift; d=$(mktemp -d "$S/run.XXXXXX")
    words=""; for w in "$@"; do words="$words '$w'"; done
    (cd "$d" && "$BASH5" -c ". '$S/$spec.bash'; COMP_WORDS=($words); COMP_CWORD=\$((\${#COMP_WORDS[@]}-1)); fn=\$(complete -p | sed -n 's/.*-F \([^ ]*\).*/\1/p' | head -1); \$fn; printf '%s\n' \"\${COMPREPLY[@]}\" >COMPREPLY.txt" 2>/dev/null)
    pw "bash  $spec  TAB after: $*" "$d"
    echo "                COMPREPLY: $(tr '\n' ' ' <"$d/COMPREPLY.txt" 2>/dev/null)"
  }
  zsh_tab() { # $1=spec $2=typed line; real zle + compsys TAB through zsh/zpty
    d=$(mktemp -d "$S/zrun.XXXXXX"); sed '$d' "$S/$1.zsh" >"$d/_app.zsh"
    timeout 30 zsh -f "$AUDIT_DIR/tools/zsh_complete.zsh" "$d/_app.zsh" "$d" "$2" >"$d/screen.txt" 2>&1
    pw "zsh   $1  TAB after: '$2'" "$d"
    echo "                screen: $(tail -2 "$d/screen.txt" | tr '\n' ' ' | cut -c1-120)"
  }
  bash_tab pv_cmdsub app --mode ''
  bash_tab cmdname app ''
  bash_tab longcase app --x ''
  bash_tab pv_space app --mode ''
  bash_tab desc_safe app ''
  bash_tab desc_safe app --out ''
  bash_tab desc_safe app --out file ''   # expected the option list; P2: option values are walked as subcommands
  bash_tab desc_safe app run ''
  bash_tab global app run ''   # expected to include --global-opt (clap_complete propagates globals)
  bash_tab collide app a-b ''
  bash_tab collide app a_b ''   # expected --only-a_b; P2 collision gives --only-ab
  zsh_tab pv_cmdsub 'app --mode '
  zsh_tab subcase 'app a '
  zsh_tab pv_space 'app --mode '
  zsh_tab desc_safe 'app --out '
  zsh_tab desc_safe 'app run '
  zsh_tab collide 'app a-b --on'   # expected --only-ab; P2 collision offers --only-a_b
  echo "  fish (not installed here; static): injected lines:"
  grep -n -E 'PWNED|-s '"'"'$' "$S"/*.fish | grep -v desc_safe | sed 's/^/    /'
  echo "  UTF-8 round trip (expected 'héllo 😀 世界'):"
  for sh in bash zsh fish; do grep -h -o 'h.\{1,12\}llo[^]'"'"']*' "$S/utf8.$sh" | head -1 | sed "s/^/    $sh: /"; done
fi

if want wasm; then
  hdr "[wasm] native debug/release + wasm32 debug/release (node) must be byte-identical, 0 traps"
  run4() {
    tag=$1; shift
    "$B/probe" "$@" >"$O/w_${tag}_nrel.txt" 2>"$O/w_${tag}_nrel.err" || echo "  native-release exit $? on $tag"
    "$B/probe_dbg" "$@" >"$O/w_${tag}_ndbg.txt" 2>"$O/w_${tag}_ndbg.err" || echo "  native-debug exit $? on $tag"
    node "$RT" "$B/probe.wasm" "$@" >"$O/w_${tag}_wrel.txt" 2>"$O/w_${tag}_wrel.err" || echo "  wasm32-release exit $? on $tag"
    node "$RT" "$B/probe_dbg.wasm" "$@" >"$O/w_${tag}_wdbg.txt" 2>"$O/w_${tag}_wdbg.err" || echo "  wasm32-debug exit $? on $tag"
    u=$(shasum -a 256 "$O"/w_${tag}_*.txt | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
    tr=$(cat "$O"/w_${tag}_*.err | grep -ci 'trap\|unreachable\|RuntimeError' || true)
    if [ "$u" = 1 ] && [ "$tr" = 0 ]; then echo "  $tag: 4/4 identical ($(wc -c <"$O/w_${tag}_nrel.txt" | tr -d ' ') bytes), 0 traps"
    else echo "  $tag: DIFFERENT across modes or trapped ($tr)"; shasum -a 256 "$O"/w_${tag}_*.txt; STATUS=1; fi
  }
  run4 diff diff "$O/c/cases.tsv"
  run4 typed typed "$O/c/typed.txt"
  for sh in bash zsh fish; do for spec in pv_cmdsub desc_safe utf8 collide; do run4 "compl_${sh}_$spec" compl "$sh" "$spec"; done; done
  run4 help_sub help sub
  run4 dos_deep dos deep 64
  run4 dos_deep65 dos deep 1000
  run4 dos_typo_long dos typo_long 100000
  run4 dos_many dos many_args 100000
  run4 dos_compl dos compl 500
fi

if want dos; then
  hdr "[dos] scaling of adversarial workloads (wall ms, single run; Pion vs clap)"
  ms() { python3 - "$@" <<'PY'
import subprocess, sys, time
t = time.perf_counter(); out = subprocess.run(sys.argv[1:], capture_output=True, text=True).stdout.strip().splitlines()
print(f"{(time.perf_counter() - t) * 1000:9.1f} ms  {(out or ['?'])[0][:60]}")
PY
  }
  for w in "build_args 4000" "build_args 8000" "build_args 16000" "build_args 32000" "build_subs 16000" \
           "build_parse 32000" "typo_long 1000000" "typo_longcand 2000" "typo_longcand 4000" "typo_many 3000" \
           "deep 64" "deep 1000" "many_args 1000000" "help_long 5000"; do
    printf '  %-22s pion %s\n' "$w" "$(ms "$B/probe" dos $w)"
    printf '  %-22s clap %s\n' "" "$(ms "$CLAP" dos $w)"
  done
  for n in 1000 4000 16000; do printf '  %-22s pion %s\n' "compl $n" "$(ms "$B/probe" dos compl $n)"; done
fi

if want bench; then
  hdr "[bench] fairness of bench/ W1/W3 + adversarial workloads (scripts/bench_compare.py, warmup 1, rounds 5, SHA-256 gated)"
  pionc build --release -o "$B/pion_bench" "$PKG_DIR/bench/pion_bench" || exit 2
  pionc build --release -o "$B/pion_fair" "$AUDIT_DIR/bench/pion" || exit 2
  CARGO_TARGET_DIR="$O/rust-up-target" cargo build -q --release --manifest-path "$PKG_DIR/bench/rust/Cargo.toml" || exit 2
  CARGO_TARGET_DIR="$O/rust-bench-target" cargo build -q --release --manifest-path "$AUDIT_DIR/bench/rust/Cargo.toml" || exit 2
  UP="$O/rust-up-target/release/cli_bench_rust"
  RF="$O/rust-bench-target/release/cli_audit_bench_rust"
  mkdir -p "$O/bench"
  bc() { t=$1; shift; python3 "$ROOT_DIR/scripts/bench_compare.py" --title "$t" --warmup 1 --rounds 5 --baseline rust_clap "$@" \
           --md-out "$O/bench/$(echo "$t" | tr -c 'A-Za-z0-9\n' '_').md" | grep -E '^\||SHA|mismatch' || STATUS=1; }
  bc "W1 upstream vs no-clone clap" --ops 50000 --impl "pion=$B/pion_bench w1" --impl "rust_clap=$RF w1_mut" --impl "rust_clap_clone=$UP w1"
  bc "W1 cold build+parse per op" --ops 50000 --impl "pion=$B/pion_fair w1_cold" --impl "rust_clap=$RF w1_cold"
  bc "W3 rendered vs structured" --ops 20000 --impl "pion=$B/pion_fair w3_render" --impl "pion_struct=$B/pion_bench w3" \
     --impl "rust_clap=$RF w3_ctx" --impl "rust_clap_clone=$UP w3"
  for w in "build_args 16000" "build_subs 16000" "build_parse 16000" "typo_many 3000" "typo_long 1000000" "typo_longcand 4000"; do
    bc "ADV $w" --impl "pion=$B/probe dos $w" --impl "rust_clap=$CLAP dos $w"
  done
fi

hdr "git status (must be clean apart from audit/ sources)"
(cd "$ROOT_DIR" && git status --porcelain --ignored)
echo
[ "$STATUS" = 0 ] && echo "AUDIT RESULT: clean" || echo "AUDIT RESULT: DEFECTS PRESENT (exit 1)"
exit "$STATUS"
