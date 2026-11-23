#!/bin/sh
# RT-vcard DoS / complexity probes and benchmark blind spots.
# usage: dos.sh <pion_driver> <go_oracle> <work_dir>
# Prints one line per probe; exit 1 iff a gated probe fails:
#   G1  D1 Quoted-Printable soft breaks: 1.2 MB input must parse in < 1.5 s (linear target ~20 ms)
#   G2  D6 64 MiB input accepted by VCardLimits::default() must not trap wasm32 (OOM)
#   G3  D2/D3/D4/D5 must keep their expected result and finish in < 3 s each (controls)
set -u
PION=$1; GO=$2; W=$3
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
D=$W/dos; mkdir -p "$D"
python3 "$AUDIT_DIR/diff/gen_dos.py" "$D"
FAIL=0

# measure <label> <cmd...>: sets REAL (s), RSS (MiB), OUT (first 70 bytes of stdout), RC
measure() {
  label=$1; shift
  /usr/bin/time -l "$@" > "$D/out.txt" 2> "$D/time.txt"
  RC=$?
  REAL=$(awk '/ real /{print $1}' "$D/time.txt" | head -1)
  RSS=$(awk '/maximum resident/{printf "%.1f", $1/1048576}' "$D/time.txt" | head -1)
  OUT=$(head -c 70 "$D/out.txt" | tr '\n' ' ')
  printf '  %-26s rc=%s real=%6ss peakRSS=%8s MiB  -> %s\n' "$label" "$RC" "$REAL" "$RSS" "$OUT"
}
lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 < b+0)}'; }

echo "== D1 Quoted-Printable soft breaks: whole line re-copied per '=CRLF' (parser.pion:234-236, 258-260) =="
for n in 37500 75000 150000 300000; do
  measure "pion d1_qp_$n" "$PION" parse "$D/d1_qp_$n.vcf"
  [ "$n" = 300000 ] && P_QP=$REAL
  measure "go   d1_qp_$n" "$GO" parse "$D/d1_qp_$n.vcf"
done
if lt "$P_QP" 1.5; then echo "  G1 PASS ($P_QP s)"; else echo "  G1 FAIL: 1.2 MB QP property took $P_QP s (quadratic)"; FAIL=1; fi

echo "== D2-D5 linear controls / limits =="
check() { # label expect-prefix file mode
  measure "$1" "$PION" "$4" "$3"
  case $OUT in
    "$2"*) if lt "$REAL" 3; then :; else echo "  G3 FAIL: $1 too slow"; FAIL=1; fi ;;
    *) echo "  G3 FAIL: $1 expected '$2'"; FAIL=1 ;;
  esac
}
check "pion d2_fold_200k" "OK cards=1 props=3" "$D/d2_fold_200k.vcf" parse
check "pion d3_props_50k" "ERR LimitExceeded" "$D/d3_props_50k.vcf" parse
check "pion d4_params_50k" "ERR LimitExceeded" "$D/d4_params_50k.vcf" parse
check "pion d5_photo_8m(decode)" "OK photo_bytes=8847360" "$D/d5_photo_8m.vcf" media
measure "go   d2_fold_200k" "$GO" parse "$D/d2_fold_200k.vcf"

echo "== D6 memory amplification: minimal properties within every default limit =="
measure "pion native d6_amp_16m" "$PION" parse "$D/d6_amp_16m.vcf"
measure "go   d6_amp_16m" "$GO" parse "$D/d6_amp_16m.vcf"
measure "pion native d6_amp_64m" "$PION" parse "$D/d6_amp_64m.vcf"
export PION_CACHE_DIR=$W/pion-cache-wasm
measure "pion wasm32-rel d6_amp_64m" pionc run --release --target wasm32 "$AUDIT_DIR/driver" -- parse "$D/d6_amp_64m.vcf"
if [ "$RC" = 0 ] && { case $OUT in "OK "*|"ERR LimitExceeded"*) true ;; *) false ;; esac; }; then
  echo "  G2 PASS"
else
  echo "  G2 FAIL: wasm32 rc=$RC: $(grep -m1 -E 'Error|trap|panic' "$D/time.txt" "$D/out.txt" | head -c 160)"
  FAIL=1
fi

echo "== B1-B4 benchmark blind spots (parse only, informative) =="
for b in b1_wide_cards b2_heavy_fold b3_escape_dense b4_qp_v21; do
  measure "pion $b" "$PION" parse "$D/$b.vcf"
  measure "go   $b" "$GO" parse "$D/$b.vcf"
done
exit $FAIL
