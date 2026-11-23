#!/bin/sh
# Red-team audit of packages/ssh @ 81a2816: one command reproduces every number in REPORT.md.
#
#   sh packages/ssh/audit/run_audit.sh [all|build|tests|diff|wasm|interop|sshd|dos|bench]
#
# Pion `packages/ssh` vs Go golang.org/x/crypto/ssh v0.38.0 vs the system OpenSSH (ssh-keygen(1), and
# sshd(8) run unprivileged on 127.0.0.1:$SSHD_PORT, default 22999).
# Needs: pionc ($HOME/.pion/bin), node (wasm32 runtime), go, python3, ssh-keygen, sshd.
# Every build artefact and generated corpus goes to $AUDIT_OUT (default /tmp/rt-ssh-audit), never into the
# git worktree; wasm32 builds use their own clean PION_CACHE_DIR.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SSH_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SSH_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/tmp/rt-ssh-audit}
BIN="$OUT/bin"
WHAT=${1:-all}
N_MUTANTS=${N_MUTANTS:-10000}
SEED=${SEED:-4253}
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:/usr/local/go/bin:/opt/homebrew/bin:$PATH"
mkdir -p "$BIN"

step() { printf '\n==== %s ====\n' "$*"; }
now() { python3 -c 'import time; print(time.time())'; }

build() {
  step "build: pion oracle (native debug/release + wasm32 debug/release, clean PION_CACHE_DIR for wasm32) + go oracle"
  pionc build --release -o "$BIN/oracle_pion" "$AUDIT_DIR/oracle"
  pionc build -o "$BIN/oracle_pion_debug" "$AUDIT_DIR/oracle"
  rm -rf "$OUT/pion-cache-wasm"
  PION_CACHE_DIR="$OUT/pion-cache-wasm" pionc build --release --target wasm32 -o "$BIN/oracle_pion.wasm" "$AUDIT_DIR/oracle"
  PION_CACHE_DIR="$OUT/pion-cache-wasm" pionc build --target wasm32 -o "$BIN/oracle_pion_debug.wasm" "$AUDIT_DIR/oracle"
  rm -rf "$OUT/go-build" && cp -R "$AUDIT_DIR/diff/go" "$OUT/go-build"
  (cd "$OUT/go-build" && go build -o "$BIN/oracle_go" .)
}

run_tests() {
  step "pionc test packages/ssh (original suite must stay green)"
  (cd "$SSH_DIR" && pionc test --json . > "$OUT/orig_tests.json" 2>"$OUT/orig_tests.stderr") || true
  python3 - "$OUT/orig_tests.json" <<'EOF'
import json, sys
t = open(sys.argv[1]).read(); d = json.loads(t[t.find('{"ok"'):])
mine = [x for x in d["tests"] if x.get("pkg", "ssh") == "ssh"]
print("packages/ssh: %d/%d passed (all packages incl. deps: %d/%d)" % (
    sum(x["ok"] for x in mine), len(mine), sum(x["ok"] for x in d["tests"]), len(d["tests"])))
EOF
  step "pionc test audit/redteam_test.pion (p0_/p1_/p2_ FAIL = evidence; control_* must PASS)"
  # pionc exits non-zero when a test fails; that is the expected outcome here.
  (cd "$SSH_DIR" && pionc test --json audit > "$OUT/tests.json" 2> "$OUT/tests.stderr") || true
  python3 - "$OUT/tests.json" "$OUT/tests.stderr" <<'EOF'
import json, re, sys
t = open(sys.argv[1]).read(); d = json.loads(t[t.find('{"ok"'):])
why = {}
for m in re.finditer(r"redteam_test\.pion:(\d+): (.*)", open(sys.argv[2]).read()):
    why[int(m.group(1))] = m.group(2)
mine = [x for x in d["tests"] if x["name"].startswith(("p0_", "p1_", "p2_", "control_"))]
fails = [x for x in mine if not x["ok"]]
ctl = [x for x in mine if x["name"].startswith("control_")]
print("audit tests=%d  findings FAIL=%d (p0=%d p1=%d p2=%d)  controls PASS=%d/%d" % (
    len(mine), len(fails), *(sum(x["name"].startswith(p) for x in fails) for p in ("p0_", "p1_", "p2_")),
    sum(x["ok"] for x in ctl), len(ctl)))
for x in mine:
    print(("PASS " if x["ok"] else "FAIL ") + x["name"])
print("assertion messages:")
for line, msg in sorted(why.items()):
    print("  redteam_test.pion:%d: %s" % (line, msg))
bad = [x["name"] for x in ctl if not x["ok"]] + [x["name"] for x in mine if x["ok"] and not x["name"].startswith("control_")]
if bad:
    print("UNEXPECTED: " + ", ".join(bad)); sys.exit(1)
EOF
}

run_diff() {
  step "differential: Pion vs Go x/crypto/ssh over targeted vectors + $N_MUTANTS seeded mutants (seed $SEED)"
  python3 "$AUDIT_DIR/diff/gen_corpus.py" "$AUDIT_DIR/vectors" "$OUT/corpus.tsv" "$N_MUTANTS" "$SEED"
  "$BIN/oracle_pion" vectors "$OUT/corpus.tsv" > "$OUT/pion.txt"
  "$BIN/oracle_go" vectors "$OUT/corpus.tsv" > "$OUT/go.txt"
  python3 "$AUDIT_DIR/diff/compare.py" "$OUT/corpus.tsv" "$OUT/pion.txt" "$OUT/go.txt"
}

run_wasm() {
  step "4-mode consistency: native release/debug + wasm32 release/debug (node) over the whole corpus"
  [ -f "$OUT/corpus.tsv" ] || python3 "$AUDIT_DIR/diff/gen_corpus.py" "$AUDIT_DIR/vectors" "$OUT/corpus.tsv" "$N_MUTANTS" "$SEED"
  rc=0
  "$BIN/oracle_pion" vectors "$OUT/corpus.tsv" > "$OUT/m_native_rel.txt" || rc=$?
  "$BIN/oracle_pion_debug" vectors "$OUT/corpus.tsv" > "$OUT/m_native_dbg.txt" || rc=$?
  node "$WASM_RT" "$BIN/oracle_pion.wasm" vectors "$OUT/corpus.tsv" > "$OUT/m_wasm_rel.txt" || rc=$?
  node "$WASM_RT" "$BIN/oracle_pion_debug.wasm" vectors "$OUT/corpus.tsv" > "$OUT/m_wasm_dbg.txt" || rc=$?
  for f in m_native_rel m_native_dbg m_wasm_rel m_wasm_dbg; do
    printf '  %-14s lines=%-6s sha256=%s\n' "$f" "$(wc -l < "$OUT/$f.txt" | tr -d ' ')" "$(shasum -a 256 "$OUT/$f.txt" | cut -c1-16)"
  done
  n=$(for f in m_native_rel m_native_dbg m_wasm_rel m_wasm_dbg; do shasum -a 256 < "$OUT/$f.txt"; done | sort -u | wc -l | tr -d ' ')
  echo "  distinct outputs: $n (1 = byte-identical), non-zero exits: $rc"
  step "4-mode consistency of the DoS shapes (crash = finding)"
  for spec in "kh_star 20000" "negkh 100000" "ak_opts 50000" "principals 20000" "namelist 1" "namelist 100"; do
    # shellcheck disable=SC2086
    set -- $spec
    line=""
    for m in native_rel native_dbg wasm_rel wasm_dbg; do
      case $m in
        native_rel) cmd="$BIN/oracle_pion" ;;
        native_dbg) cmd="$BIN/oracle_pion_debug" ;;
        wasm_rel) cmd="node $WASM_RT $BIN/oracle_pion.wasm" ;;
        wasm_dbg) cmd="node $WASM_RT $BIN/oracle_pion_debug.wasm" ;;
      esac
      r=0; o=$($cmd dos "$1" "$2" 2>&1) || r=$?
      line="$line $m[rc=$r $(printf '%s' "$o" | shasum -a 256 | cut -c1-8)]"
    done
    printf '  %-18s%s\n' "$spec" "$line"
  done
}

run_interop() {
  step "interop with ssh-keygen: SSHSIG both directions, openssh-key-v1 re-encode"
  I="$OUT/interop" && rm -rf "$I" && mkdir -p "$I"
  for k in ca_ed p256 ca_rsa; do cp "$AUDIT_DIR/vectors/$k" "$I/$k"; chmod 600 "$I/$k"; done
  cp "$AUDIT_DIR/vectors/msg" "$I/msg"
  cd "$I"
  for k in ca_ed p256 ca_rsa; do
    for h in sha256 sha512; do
      "$BIN/oracle_pion" sshsig_sign $k git msg $h > pion_$k.$h.sig || true
      r=$(ssh-keygen -Y check-novalidate -n git -s pion_$k.$h.sig < msg 2>&1 | head -1 | cut -c1-60)
      printf '  pion  sign %-6s %-6s -> ssh-keygen check-novalidate: %s\n' $k $h "$r"
      ssh-keygen -q -Y sign -f $k -n git -O hashalg=$h msg 2>/dev/null && mv msg.sig kg_$k.$h.sig
      printf '  keygen sign %-6s %-6s -> pion sshsig_verify: %s\n' $k $h "$("$BIN/oracle_pion" sshsig_verify kg_$k.$h.sig git msg | cut -c1-60)"
    done
    ssh-keygen -q -Y sign -f $k -n git msg 2>/dev/null && mv msg.sig kg_$k.default.sig
    printf '  keygen sign %-6s (defaults) -> pion sshsig_verify: %s\n' $k "$("$BIN/oracle_pion" sshsig_verify kg_$k.default.sig git msg | cut -c1-60)"
    "$BIN/oracle_pion" reencode $k > re_$k && chmod 600 re_$k
    if [ "$(ssh-keygen -y -f re_$k 2>&1 | cut -d' ' -f1-2)" = "$(ssh-keygen -y -f $k | cut -d' ' -f1-2)" ]; then
      printf '  reencode %-6s -> ssh-keygen -y: same public key\n' $k
    else
      printf '  reencode %-6s -> ssh-keygen -y: MISMATCH\n' $k
    fi
  done
  cd "$OUT"
}

run_sshd() {
  step "real sshd(8) oracle (unprivileged, 127.0.0.1:${SSHD_PORT:-22999})"
  sh "$AUDIT_DIR/sshd_oracle.sh" "$BIN/oracle_pion" "$OUT"
}

run_dos() {
  step "complexity bombs: Pion (native release) vs Go knownhosts vs OpenSSH ssh-keygen -F, pattern ('a*' x n)+'b' vs 'a' x 4n"
  for n in 8 10 11; do
    t0=$(now); "$BIN/oracle_go" dos kh_star $n >/dev/null; t1=$(now)
    python3 -c "import sys;n=int(sys.argv[1]);print('a*'*n+'b ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHiojgVRI/bzT9/KdnJv9QzVjj6cRUQldIZUq76+c0ib')" $n > "$OUT/kh_star"
    h=$(python3 -c "import sys;print('a'*4*int(sys.argv[1]))" $n)
    t2=$(now); ssh-keygen -F "$h" -f "$OUT/kh_star" >/dev/null 2>&1 || true; t3=$(now)
    t4=$(now); "$BIN/oracle_pion" dos kh_star $n >/dev/null; t5=$(now)
    python3 -c "import sys;a=list(map(float,sys.argv[2:]));print('  n=%-6s go %8.3fs   ssh-keygen %8.3fs   pion %8.3fs'%(sys.argv[1],a[1]-a[0],a[3]-a[2],a[5]-a[4]))" $n $t0 $t1 $t2 $t3 $t4 $t5
  done
  for n in 2000 20000; do
    t0=$(now); "$BIN/oracle_pion" dos kh_star $n >/dev/null; t1=$(now)
    python3 -c "import sys;print('  n=%-6s go (skipped: exponential)  ssh-keygen (skipped)  pion %8.3fs'%(sys.argv[1],float(sys.argv[3])-float(sys.argv[2])))" $n $t0 $t1
  done
  step "linear-size bombs (Pion native release)"
  for spec in "negkh 100000" "ak_opts 50000" "principals 20000"; do
    # shellcheck disable=SC2086
    set -- $spec
    t0=$(now); o=$("$BIN/oracle_pion" dos "$1" "$2"); t1=$(now)
    python3 -c "import sys;print('  %-60s %8.3fs'%(sys.argv[1],float(sys.argv[3])-float(sys.argv[2])))" "$o" $t0 $t1
  done
}

run_bench() {
  step "missing bench dimensions: SSHSIG verify with RSA-2048 (rsa-sha2-256) / P-256 / Ed25519, Pion vs Go"
  # Same work on both sides: armor decode + SSHSIG parse + key parse + hash + signature verify, n times.
  for spec in "rsa2048 sig_rsa256.sig 200" "p256 sig_p256.sig 500" "ed25519 sig_ed.sig 500"; do
    # shellcheck disable=SC2086
    set -- $spec
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "SSHSIG verify $1 x$3" \
      --impl "pion=$BIN/oracle_pion bench_sshsig $AUDIT_DIR/vectors/$2 $AUDIT_DIR/vectors/msg $3" \
      --impl "go_x_crypto_ssh=$BIN/oracle_go bench_sshsig $AUDIT_DIR/vectors/$2 $AUDIT_DIR/vectors/msg $3" \
      --baseline go_x_crypto_ssh --warmup 1 --rounds "${BENCH_ROUNDS:-5}" --ops "$3" \
      --md-out "$OUT/bench_$1.md" --json-out "$OUT/bench_$1.json" >/dev/null
    cat "$OUT/bench_$1.md"
  done
  step "load during the run (bench numbers are only comparable on an idle machine)"
  uptime
}

case "$WHAT" in
  all) build; run_tests; run_diff; run_wasm; run_interop; run_sshd; run_dos; run_bench ;;
  build) build ;;
  tests) run_tests ;;
  diff) run_diff ;;
  wasm) run_wasm ;;
  interop) run_interop ;;
  sshd) run_sshd ;;
  dos) run_dos ;;
  bench) run_bench ;;
  *) echo "usage: $0 [all|build|tests|diff|wasm|interop|sshd|dos|bench]" >&2; exit 2 ;;
esac
